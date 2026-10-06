import Foundation

@MainActor
final class GameLibrary: ObservableObject {
    @Published private(set) var games: [Game] = []
    @Published var message: String?

    init() {
        refresh()
    }

    func games(for system: GameSystem) -> [Game] {
        games.filter { $0.system == system }
    }

    func refresh() {
        Task.detached(priority: .userInitiated) {
            let found = Self.scan(Paths.games)
            await MainActor.run { self.games = found }
        }
    }

    nonisolated private static func scan(_ root: URL) -> [Game] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                  options: [.skipsHiddenFiles]) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.append(url)
            }
        }

        // Les .cue listés dans un .m3u ne sont pas affichés séparément.
        var hidden = Set<String>()
        for playlist in files where playlist.pathExtension.lowercased() == "m3u" {
            for entry in referencedFiles(of: playlist) { hidden.insert(entry.path) }
        }

        return files.compactMap { url -> Game? in
            guard let system = GameSystem.detect(url),
                  !hidden.contains(url.standardizedFileURL.path) else { return nil }
            return Game(url: url, system: system)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    // MARK: Import

    func importFiles(_ urls: [URL]) {
        Task.detached(priority: .userInitiated) {
            var imported = 0
            var skipped: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let count = try Self.importFile(url)
                    if count == 0 { skipped.append(url.lastPathComponent) }
                    imported += count
                } catch {
                    PTLogLine("Import impossible de \(url.lastPathComponent) : \(error.localizedDescription)")
                    skipped.append(url.lastPathComponent)
                }
            }
            let summary: String
            if imported > 0 && skipped.isEmpty {
                summary = imported == 1 ? "1 fichier ajouté" : "\(imported) fichiers ajoutés"
            } else if imported > 0 {
                summary = "\(imported) ajouté(s), \(skipped.count) ignoré(s) (format non reconnu)"
            } else {
                summary = "Aucun fichier reconnu"
            }
            await MainActor.run {
                self.message = summary
                self.refresh()
            }
        }
    }

    /// Copie un fichier dans Jeux (ou BIOS), en décompressant les .zip. Renvoie le nombre de fichiers ajoutés.
    nonisolated private static func importFile(_ url: URL) throws -> Int {
        let ext = url.pathExtension.lowercased()
        if ext == "zip" {
            let archive = try ZipArchive(url: url)
            var count = 0
            for entry in archive.entries {
                let name = (entry.path as NSString).lastPathComponent
                guard let destination = destination(forFileNamed: name) else { continue }
                try archive.extract(entry, to: uniqueURL(destination))
                count += 1
            }
            return count
        }
        guard let destination = destination(forFileNamed: url.lastPathComponent) else { return 0 }
        let manager = FileManager.default
        if url.standardizedFileURL.deletingLastPathComponent() == destination.deletingLastPathComponent() {
            return 0
        }
        let target = uniqueURL(destination)
        try manager.copyItem(at: url, to: target)
        return 1
    }

    nonisolated private static func destination(forFileNamed name: String) -> URL? {
        let lower = name.lowercased()
        if GameSystem.biosFileNames.contains(lower) {
            return Paths.bios.appendingPathComponent(lower)
        }
        let ext = (lower as NSString).pathExtension
        guard GameSystem.forExtension(ext) != nil || GameSystem.companionExtensions.contains(ext) else { return nil }
        return Paths.games.appendingPathComponent(name)
    }

    /// Évite d'écraser un fichier existant : « Jeu.gba » → « Jeu 2.gba ».
    nonisolated private static func uniqueURL(_ url: URL) -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return url }
        // Les BIOS et pistes de CD gardent leur nom exact (ils sont référencés par leur nom).
        let ext = url.pathExtension.lowercased()
        if url.deletingLastPathComponent() == Paths.bios || GameSystem.companionExtensions.contains(ext) {
            try? manager.removeItem(at: url)
            return url
        }
        let base = url.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) \(index).\(url.pathExtension)")
            if !manager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    // MARK: Suppression

    /// Supprime le jeu avec ses fichiers associés (pistes .bin d'un .cue, disques d'un .m3u).
    /// Les sauvegardes sont conservées.
    func delete(_ game: Game) {
        for file in Self.files(of: game) {
            try? FileManager.default.removeItem(at: file)
        }
        games.removeAll { $0.id == game.id }
    }

    /// Le fichier du jeu suivi des fichiers qu'il référence, à condition qu'ils soient dans Jeux et
    /// qu'aucun autre jeu du même dossier ne s'en serve.
    nonisolated static func files(of game: Game) -> [URL] {
        let main = game.url.standardizedFileURL
        var result = [main]
        var queue = referencedFiles(of: main)
        while let file = queue.first, result.count < 64 {
            queue.removeFirst()
            guard !result.contains(file) else { continue }
            result.append(file)
            queue += referencedFiles(of: file)
        }
        let root = Paths.games.resolvingSymlinksInPath().path + "/"
        let manager = FileManager.default
        let usedElsewhere = otherReferences(near: main, excluding: Set(result))
        return [main] + result.dropFirst().filter { file in
            file.resolvingSymlinksInPath().path.hasPrefix(root) && manager.fileExists(atPath: file.path)
                && !usedElsewhere.contains(file)
        }
    }

    /// Fichiers cités par un .cue (« FILE "piste.bin" BINARY ») ou un .m3u (un disque par ligne).
    nonisolated static func referencedFiles(of url: URL) -> [URL] {
        let ext = url.pathExtension.lowercased()
        guard ext == "cue" || ext == "m3u",
              let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1))
        else { return [] }
        let folder = url.deletingLastPathComponent()
        var names: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if ext == "m3u" {
                if !line.isEmpty && !line.hasPrefix("#") { names.append(line) }
            } else if line.uppercased().hasPrefix("FILE ") {
                if let open = line.firstIndex(of: "\""), let close = line.lastIndex(of: "\""), open < close {
                    names.append(String(line[line.index(after: open)..<close]))
                } else if let name = line.split(separator: " ").dropFirst().first {
                    names.append(String(name))
                }
            }
        }
        return names.map { folder.appendingPathComponent($0).standardizedFileURL }
    }

    /// Fichiers cités par les autres .cue et .m3u du dossier (à ne pas supprimer).
    nonisolated private static func otherReferences(near url: URL, excluding: Set<URL>) -> Set<URL> {
        let folder = url.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var used = Set<URL>()
        for entry in entries.map(\.standardizedFileURL) where !excluding.contains(entry) {
            used.formUnion(referencedFiles(of: entry))
        }
        return used
    }
}
