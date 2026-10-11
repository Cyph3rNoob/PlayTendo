import Foundation
import UIKit

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

    /// Archives décompressées à l'import (libarchive : PTArchive).
    nonisolated static let archiveExtensions: Set<String> = ["zip", "7z", "rar"]

    /// Avancement de l'import en cours, montré en bas de la bibliothèque.
    struct ImportProgress: Equatable {
        enum Step { case copying, extracting }
        var step: Step
        /// Nom du fichier écrit dans Jeux (celui tiré de l'archive, ou le fichier copié).
        var fileName: String
        var done: Int64 = 0
        /// Taille finale, 0 si inconnue.
        var total: Int64 = 0
        /// Rang du fichier choisi en cours, sur le nombre de fichiers choisis.
        var index: Int
        var count: Int
    }

    @Published private(set) var importProgress: ImportProgress?
    @Published private(set) var importCancelRequested = false
    /// Fichiers non ajoutés au dernier import, chacun avec sa raison (alerte de la bibliothèque).
    @Published var importFailures: [String] = []

    // Import en cours (fil principal) : fichiers en attente et bilan. Un fichier choisi pendant un import passe ensuite.
    private var importQueue: [URL] = []
    private var importRunning = false
    private var importIndex = 0
    private var importCount = 0
    private var importAdded = 0
    private var importPresent = 0
    private var importFailuresPending: [String] = []
    private var importBackgroundTask = UIBackgroundTaskIdentifier.invalid
    private let importCancel = ImportCancel()

    /// Annulation demandée (bouton du bandeau, ou temps en arrière-plan écoulé), lue par le fil de l'import.
    private final class ImportCancel: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
        func reset() { lock.withLock { cancelled = false } }
    }

    private struct QueuedImport {
        let url: URL
        let index: Int
        let count: Int
    }

    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        importQueue += urls
        importCount += urls.count
        guard !importRunning else { return }
        importRunning = true
        importCancel.reset()
        importCancelRequested = false
        // Écran gardé allumé (un gros jeu prend plusieurs minutes), et un peu de temps accordé si l'app passe en
        // arrière-plan ; s'il s'écoule, l'import s'arrête proprement (fichier commencé effacé).
        ScreenAwake.hold(.importing)
        let cancel = importCancel
        importBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Import de jeux") { [weak self] in
            cancel.cancel()
            MainActor.assumeIsolated { self?.endImportBackgroundTask() }
        }
        Task.detached(priority: .userInitiated) { [self] in
            await runImports(cancel: cancel)
        }
    }

    func cancelImport() {
        importCancel.cancel()
        importCancelRequested = true
    }

    nonisolated private func runImports(cancel: ImportCancel) async {
        while let item = await nextImport() {
            let name = item.url.lastPathComponent
            let isArchive = Self.archiveExtensions.contains(item.url.pathExtension.lowercased())
            let post: (ImportProgress) -> Void = { [weak self] progress in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.showImportProgress(progress) } }
            }
            post(ImportProgress(step: isArchive ? .extracting : .copying, fileName: name, index: item.index, count: item.count))
            let update: ImportUpdate = { step, fileName, done, total in
                post(ImportProgress(step: step, fileName: fileName, done: done, total: total,
                                    index: item.index, count: item.count))
                return !cancel.isCancelled
            }

            let scoped = item.url.startAccessingSecurityScopedResource()
            var result: ImportResult?
            var failure: String?
            // Même échec, dans la langue de l'interface (le Journal reste en français).
            var shownFailure: String?
            var stats = ImportStats()
            // Durée réelle et temps de calcul de ce fil (même fil jusqu'à la fin : rien n'est attendu entre les deux) :
            // un calcul bien plus court que la durée veut dire une lecture ou une écriture lentes.
            let start = Date()
            let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            do {
                result = try Self.importFile(item.url, stats: &stats, update: update)
            } catch PTArchiveError.cancelled {
                cancel.cancel()
                failure = "annulé"
            } catch {
                let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
                failure = error.localizedDescription + (detail.map { " [\($0)]" } ?? "")
                shownFailure = ((error as? ImportError)?.shown ?? trMessage(error.localizedDescription))
                    + (detail.map { " [\($0)]" } ?? "")
            }
            let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1e9
            PTLogLine(Self.importLogLine(name: name, from: item.url, stats: stats, result: result, failure: failure,
                                         seconds: Date().timeIntervalSince(start), cpu: cpu))
            if scoped { item.url.stopAccessingSecurityScopedResource() }
            if cancel.isCancelled { shownFailure = nil }
            await recordImport(name: name, result: result, failure: shownFailure)
        }
    }

    /// Fichier suivant de la file, ou fin de l'import (file vide ou annulation) : bilan affiché.
    private func nextImport() -> QueuedImport? {
        guard !importCancel.isCancelled, !importQueue.isEmpty else {
            finishImports()
            return nil
        }
        importIndex += 1
        return QueuedImport(url: importQueue.removeFirst(), index: importIndex, count: importCount)
    }

    private func showImportProgress(_ progress: ImportProgress) {
        guard importRunning else { return }
        importProgress = progress
    }

    private func recordImport(name: String, result: ImportResult?, failure: String?) {
        switch result {
        case .added(let count): importAdded += count
        case .alreadyThere: importPresent += 1
        case .unsupported: importFailuresPending.append(tr("\(name) : format non reconnu"))
        case .noGame: importFailuresPending.append(tr("\(name) : aucun jeu reconnu dans l'archive"))
        case .cia3DS:
            importFailuresPending.append(tr("\(name) : jeu 3DS au format .cia (à installer), pas encore pris en charge ; il faut un .3ds ou .cci décrypté"))
        case nil: if let failure { importFailuresPending.append(tr("\(name) : \(failure)")) }
        }
        // Le jeu ajouté apparaît tout de suite, sans attendre la fin des autres.
        if case .added = result { refresh() }
    }

    private func finishImports() {
        let cancelled = importCancel.isCancelled
        var parts: [String] = []
        if cancelled { parts.append(tr("Import annulé")) }
        if importAdded > 0 { parts.append(importAdded == 1 ? tr("1 fichier ajouté") : tr("\(importAdded) fichiers ajoutés")) }
        if importPresent > 0 {
            parts.append(importAdded == 0 && importFailuresPending.isEmpty && !cancelled ? tr("Déjà dans la bibliothèque")
                         : importPresent == 1 ? tr("1 déjà présent") : tr("\(importPresent) déjà présents"))
        }
        if !parts.isEmpty { message = parts.joined(separator: ", ") }
        importFailures = importFailuresPending

        importRunning = false
        importProgress = nil
        importCancelRequested = false
        importQueue.removeAll()
        importIndex = 0
        importCount = 0
        importAdded = 0
        importPresent = 0
        importFailuresPending = []
        ScreenAwake.release(.importing)
        endImportBackgroundTask()
        refresh()
    }

    private func endImportBackgroundTask() {
        guard importBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(importBackgroundTask)
        importBackgroundTask = .invalid
    }

    private enum ImportResult {
        case added(Int)
        /// Déjà dans Jeux (ou BIOS), sous-dossiers compris, ou même nom et même taille : rien n'est copié.
        case alreadyThere
        case unsupported
        /// Archive lue, mais sans aucun fichier de jeu (ni BIOS) reconnu.
        case noGame
        /// Jeu 3DS au format d'installation .cia (seul ou dans une archive) : le moteur libretro ne l'ouvre pas.
        case cia3DS
    }

    /// Ce qu'a fait l'import d'un fichier, pour le journal.
    private struct ImportStats {
        /// « copie », ou format de l'archive selon libarchive.
        var format = ""
        var written: Int64 = 0
        var files = 0
        /// Premiers fichiers vus dans l'archive (pour comprendre une archive sans jeu reconnu).
        var entries: [String] = []
    }

    /// « Import : Jeu.zip (ZIP 2.0 (deflation), Sur mon iPhone) → 1 fichier, 8,4 Go en 84 s (99 Mo/s ; calcul 31 s) »
    nonisolated private static func importLogLine(name: String, from url: URL, stats: ImportStats, result: ImportResult?,
                                                  failure: String?, seconds: Double, cpu: Double) -> String {
        let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        let origin = [stats.format, place(of: url)].filter { !$0.isEmpty }.joined(separator: ", ")
        var line = "Import : \(name) (\(origin)) → "
        switch result {
        case .added:
            line += stats.files == 1 ? "1 fichier" : "\(stats.files) fichiers"
        case .alreadyThere: line += "déjà présent"
        case .unsupported: line += "format non reconnu"
        case .noGame: line += "aucun jeu reconnu"
        case .cia3DS: line += "jeu 3DS en .cia, non pris en charge"
        case nil: line += "échec : \(failure ?? "?")"
        }
        if stats.written > 0 {
            let speed = seconds > 0 ? Double(stats.written) / seconds / 1e6 : 0
            line += String(format: ", %@ écrits en %.1f s (%.0f Mo/s ; calcul %.1f s)", format(stats.written), seconds, speed, cpu)
        }
        if !stats.entries.isEmpty, result.map({ if case .added = $0 { return false } else { return true } }) ?? true {
            line += " ; contenu : " + stats.entries.joined(separator: ", ")
        }
        return line
    }

    /// Emplacement du fichier choisi, tel que l'app Fichiers le présente.
    nonisolated private static func place(of url: URL) -> String {
        let path = url.resolvingSymlinksInPath().path
        if path.contains("/File Provider Storage/") { return "Sur mon iPhone" }
        if path.contains("/Mobile Documents/") { return "iCloud Drive" }
        if path.hasPrefix(Paths.documents.resolvingSymlinksInPath().path) { return "dossier de PlayTendo" }
        return url.deletingLastPathComponent().path
    }

    /// Avancement d'un fichier : étape, nom, octets écrits, taille finale (0 si inconnue). Renvoie false pour annuler.
    private typealias ImportUpdate = (ImportProgress.Step, String, Int64, Int64) -> Bool

    /// Copie un fichier dans Jeux (ou BIOS), en décompressant les archives.
    nonisolated private static func importFile(_ url: URL, stats: inout ImportStats,
                                               update: ImportUpdate) throws -> ImportResult {
        let ext = url.pathExtension.lowercased()
        if archiveExtensions.contains(ext) {
            return try importArchive(url, stats: &stats, update: update)
        }
        if ext == "cia" { return .cia3DS }
        stats.format = "copie"
        guard let destination = destination(forFileNamed: url.lastPathComponent) else { return .unsupported }
        // Comparaison des chemins réels : l'app Fichiers peut donner « /private/var/… » pour « /var/… ».
        let folder = destination.deletingLastPathComponent().resolvingSymlinksInPath().path + "/"
        if url.resolvingSymlinksInPath().path.hasPrefix(folder) {
            return .alreadyThere
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
        if isSameFile(destination, size: size) { return .alreadyThere }
        let target = uniqueURL(destination)
        let name = target.lastPathComponent
        try PTFileCopy.copyItem(at: url, to: target) { copied, total in update(.copying, name, copied, total) }
        stats.written = max(size, 0)
        stats.files = 1
        moveIfPS2BIOS(target)
        return .added(1)
    }

    /// Décompresse dans Jeux (ou BIOS) chaque jeu, BIOS ou piste de l'archive ; le reste est sauté.
    nonisolated private static func importArchive(_ url: URL, stats: inout ImportStats,
                                                  update: ImportUpdate) throws -> ImportResult {
        let archive = try PTArchiveReader(url: url)
        var added = 0
        var present = 0
        var hasCIA = false
        while try archive.nextEntry() {
            stats.format = archive.formatName
            let name = (archive.entryPath as NSString).lastPathComponent
            if stats.entries.count < 8 { stats.entries.append(name) }
            if (name as NSString).pathExtension.lowercased() == "cia" { hasCIA = true }
            guard let destination = destination(forFileNamed: name) else { continue }
            if isSameFile(destination, size: archive.entrySize) {
                present += 1
                continue
            }
            let size = max(archive.entrySize, 0)
            try checkFreeSpace(for: size)
            let target = uniqueURL(destination)
            let fileName = target.lastPathComponent
            guard update(.extracting, fileName, 0, size) else { throw PTArchiveError(.cancelled) }
            var written: Int64 = 0
            try archive.extractEntry(to: target) { done in
                written = done
                return update(.extracting, fileName, done, size)
            }
            stats.written += written
            stats.files += 1
            moveIfPS2BIOS(target)
            added += 1
        }
        if added > 0 { return .added(added) }
        if present > 0 { return .alreadyThere }
        return hasCIA ? .cia3DS : .noGame
    }

    /// Un fichier du même nom et de la même taille est déjà là : c'est le même jeu, il n'est pas ajouté une 2e fois.
    nonisolated private static func isSameFile(_ url: URL, size: Int64) -> Bool {
        guard size > 0, let existing = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        else { return false }
        return existing.int64Value == size
    }

    private enum ImportError: LocalizedError {
        case notEnoughSpace(needed: Int64, free: Int64)

        var errorDescription: String? {
            switch self {
            case .notEnoughSpace(let needed, let free):
                let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                return "pas assez de place (il faut \(format(needed)), il reste \(format(free)))"
            }
        }

        /// Pour l'utilisateur, dans la langue de l'interface.
        var shown: String {
            switch self {
            case .notEnoughSpace(let needed, let free):
                tr("pas assez de place (il faut \(AppLanguage.bytes(needed)), il reste \(AppLanguage.bytes(free)))")
            }
        }
    }

    /// Refuse d'avance un fichier plus gros que la place libre (sinon l'erreur n'arriverait qu'au bout de la décompression).
    nonisolated private static func checkFreeSpace(for size: Int64) throws {
        guard size > 0,
              let free = try? Paths.games.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage,
              free > 0, size > free else { return }
        throw ImportError.notEnoughSpace(needed: size, free: free)
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
