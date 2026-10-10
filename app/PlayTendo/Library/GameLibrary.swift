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
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                                                  options: [.skipsHiddenFiles]) else { return [] }
        var files: [URL] = []
#if PLAYTENDO_VITA
        var vitaFolders: [URL] = []
#endif
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isRegularFile == true {
                if moveIfPS2BIOS(url) { continue }
#if PLAYTENDO_VITA
                if moveIfVitaFirmware(url) { continue }
#endif
                files.append(url)
            }
#if PLAYTENDO_VITA
            // Jeu PS Vita extrait de la console (« PCSA00011 », avec sce_sys/param.sfo) : le dossier entier est le jeu.
            if values?.isDirectory == true, VitaGame.isGameFolder(url) {
                vitaFolders.append(url)
                enumerator.skipDescendants()
            }
#endif
        }

        // Les .cue listés dans un .m3u ne sont pas affichés séparément.
        var hidden = Set<String>()
        for playlist in files where playlist.pathExtension.lowercased() == "m3u" {
            for entry in referencedFiles(of: playlist) { hidden.insert(entry.path) }
        }

        let found = files.compactMap { url -> Game? in
            guard let system = GameSystem.detect(url),
                  !hidden.contains(url.standardizedFileURL.path) else { return nil }
            return Game(url: url, system: system)
        }
#if PLAYTENDO_VITA
        // PS Vita : les jeux installés dont l'original n'est plus dans Jeux (retiré après l'installation).
        let vitaOriginals = vitaFolders + files.filter { $0.pathExtension.lowercased() == "vpk" }
        let originalIDs = Set(vitaOriginals.compactMap(VitaGame.titleID(of:)))
        let installed = VitaGame.installedGames().filter { url in
            VitaGame.titleID(of: url).map { !originalIDs.contains($0) } ?? false
        }
        let all = found + (vitaFolders + installed).map { Game(url: $0, system: .vita) }
#else
        let all = found
#endif
        // Noms des sauvegardes, avant que les jeux soient affichés (deux jeux du même nom dans deux dossiers).
        Paths.assignFileNames(to: all)
        return all.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    // MARK: Import

    func importFiles(_ urls: [URL]) {
        Task.detached(priority: .userInitiated) {
            var imported = 0
            var present = 0
            var skipped: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    switch try Self.importFile(url) {
                    case .added(let count): imported += count
                    case .alreadyThere: present += 1
                    case .unsupported: skipped.append(url.lastPathComponent)
                    }
                } catch {
                    PTLogLine("Import impossible de \(url.lastPathComponent) : \(error.localizedDescription)")
                    skipped.append(url.lastPathComponent)
                }
            }
            var parts: [String] = []
            if imported > 0 { parts.append(imported == 1 ? "1 fichier ajouté" : "\(imported) fichiers ajoutés") }
            if present > 0 {
                parts.append(imported == 0 && skipped.isEmpty ? "Déjà dans la bibliothèque"
                             : present == 1 ? "1 déjà présent" : "\(present) déjà présents")
            }
            if !skipped.isEmpty {
                parts.append(imported == 0 && present == 0 ? "Aucun fichier reconnu"
                             : "\(skipped.count) ignoré(s) (format non reconnu)")
            }
            let summary = parts.isEmpty ? "Aucun fichier reconnu" : parts.joined(separator: ", ")
            await MainActor.run {
                self.message = summary
                self.refresh()
            }
        }
    }

    private enum ImportResult {
        case added(Int)
        /// Déjà dans Jeux (ou BIOS), sous-dossiers compris : rien n'est copié.
        case alreadyThere
        case unsupported
    }

    /// Copie un fichier dans Jeux (ou BIOS), en décompressant les .zip.
    nonisolated private static func importFile(_ url: URL) throws -> ImportResult {
        let ext = url.pathExtension.lowercased()
        if ext == "zip" {
            let archive = try ZipArchive(url: url)
            var count = 0
            for entry in archive.entries {
                let name = (entry.path as NSString).lastPathComponent
                guard let destination = destination(forFileNamed: name) else { continue }
                let target = uniqueURL(destination)
                try archive.extract(entry, to: target)
                moveIfPS2BIOS(target)
                count += 1
            }
            return count > 0 ? .added(count) : .unsupported
        }
        guard let destination = destination(forFileNamed: url.lastPathComponent) else { return .unsupported }
        // Comparaison des chemins réels : l'app Fichiers peut donner « /private/var/… » pour « /var/… ».
        let folder = destination.deletingLastPathComponent().resolvingSymlinksInPath().path + "/"
        if url.resolvingSymlinksInPath().path.hasPrefix(folder) {
            return .alreadyThere
        }
        let target = uniqueURL(destination)
        try FileManager.default.copyItem(at: url, to: target)
        moveIfPS2BIOS(target)
        return .added(1)
    }

    /// Un BIOS PS2 (nom variable, reconnu à son contenu) arrivé dans Jeux est rangé dans BIOS.
    @discardableResult
    nonisolated private static func moveIfPS2BIOS(_ url: URL) -> Bool {
        guard GameSystem.isPS2BIOS(url) else { return false }
        let target = Paths.bios.appendingPathComponent(url.lastPathComponent)
        let manager = FileManager.default
        try? manager.removeItem(at: target)
        do {
            try manager.moveItem(at: url, to: target)
            PTLogLine("BIOS PS2 rangé dans BIOS : \(url.lastPathComponent)")
            return true
        } catch {
            PTLogLine("BIOS PS2 \(url.lastPathComponent) : rangement impossible (\(error.localizedDescription))")
            return false
        }
    }

#if PLAYTENDO_VITA
    /// Un fichier de mise à jour PS Vita (.PUP) arrivé dans Jeux est rangé dans BIOS, où le moteur le cherche.
    @discardableResult
    nonisolated private static func moveIfVitaFirmware(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "pup", VitaGame.isFirmware(url) else { return false }
        let target = Paths.bios.appendingPathComponent(url.lastPathComponent)
        let manager = FileManager.default
        try? manager.removeItem(at: target)
        do {
            try manager.moveItem(at: url, to: target)
            PTLogLine("Firmware PS Vita rangé dans BIOS : \(url.lastPathComponent)")
            return true
        } catch {
            PTLogLine("Firmware PS Vita \(url.lastPathComponent) : rangement impossible (\(error.localizedDescription))")
            return false
        }
    }
#endif

    nonisolated private static func destination(forFileNamed name: String) -> URL? {
        let lower = name.lowercased()
        if GameSystem.biosFileNames.contains(lower) {
            return Paths.bios.appendingPathComponent(lower)
        }
        let ext = (lower as NSString).pathExtension
#if PLAYTENDO_VITA
        // Firmware PS Vita (PSVUPDAT.PUP, polices PSP2UPDAT.PUP) : nom gardé tel quel.
        if ext == "pup" { return Paths.bios.appendingPathComponent(name) }
#endif
        // BIOS PS2 au format « .ROM0 » (les « .BIN » sont reconnus à leur contenu, après la copie).
        if ext == "rom0" { return Paths.bios.appendingPathComponent(name) }
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

    /// Supprime le jeu avec ses fichiers associés (pistes .bin d'un .cue, disques d'un .m3u). Un jeu PS Vita est
    /// aussi désinstallé de la mémoire de la console. Les sauvegardes sont conservées.
    func delete(_ game: Game) {
#if PLAYTENDO_VITA
        if game.system == .vita, let titleID = VitaGame.titleID(of: game.url) {
            VitaGame.uninstall(titleID: titleID)
        }
#endif
        for file in Self.files(of: game) {
            try? FileManager.default.removeItem(at: file)
        }
#if PLAYTENDO_VITA
        if game.system == .vita {
            VitaGame.removeEmptyAppFolder(containing: game.url)
        }
#endif
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
