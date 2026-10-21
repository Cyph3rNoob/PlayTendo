import Foundation
#if os(iOS)
import UIKit
#endif

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

    /// Une lecture de Jeux à la fois : deux en même temps rangeaient le même BIOS PS2 et pouvaient l'effacer (audit du
    /// 2026-10-20). Une demande pendant une lecture en relance une seule à la fin.
    private var scanning = false
    private var rescanRequested = false

    func refresh() {
        guard !scanning else {
            rescanRequested = true
            return
        }
        scanning = true
        Task.detached(priority: .userInitiated) {
            let found = Self.scan(Paths.games)
            await MainActor.run {
                self.scanning = false
                if self.rescanRequested {
                    self.rescanRequested = false
                    self.refresh()
                }
                self.games = found
                if let pending = self.pendingLaunch {
                    let path = pending.resolvingSymlinksInPath().path
                    if let game = found.first(where: { game in
                        ([game.url] + game.discs).contains { $0.resolvingSymlinksInPath().path == path }
                    }) {
                        self.pendingLaunch = nil
                        self.gameToLaunch = game
                    }
                }
            }
        }
    }

    nonisolated private static func scan(_ root: URL) -> [Game] {
        removeEmptyFoldersOnce(in: root)
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
            // Un DLC ou une mise à jour n'est pas un jeu : installé au prochain lancement du sien (EmulatorSession).
            if values?.isDirectory == true, VitaGame.isGameFolder(url) {
                if VitaGame.kind(of: url) == .game { vitaFolders.append(url) }
                enumerator.skipDescendants()
            }
#endif
        }

        // Les .cue listés dans un .m3u ne sont pas affichés séparément.
        var hidden = Set<String>()
        for playlist in files where playlist.pathExtension.lowercased() == "m3u" {
            for entry in referencedFiles(of: playlist) { hidden.insert(entry.path) }
        }

        let found = groupDiscs(files.compactMap { url -> Game? in
            guard let system = GameSystem.detect(url),
                  !hidden.contains(url.standardizedFileURL.path) else { return nil }
#if PLAYTENDO_VITA
            if system == .vita, VitaGame.kind(of: url) != .game { return nil }
#endif
            return Game(url: url, system: system)
        })
#if PLAYTENDO_VITA
        // PS Vita : les jeux installés dont l'original n'est plus dans Jeux (retiré après l'installation).
        let vitaOriginals = vitaFolders + found.filter { $0.system == .vita }.map(\.url)
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

    /// Consoles dont le moteur sait changer de disque en cours de partie (menu pause › DISQUE).
    nonisolated private static let multiDiscSystems: Set<GameSystem> = [.psx, .gameCube]

    /// Mention du disque dans un nom de fichier : « (Disc 2) », « (Disque 2) », « (CD 2) », « (Disc 2 of 3) ».
    nonisolated private static let discTag = try! NSRegularExpression(
        pattern: #"\s*[\(\[](?:disc|disk|disque|cd)\s*(\d+)(?:\s*(?:of|sur|/)\s*\d+)?[\)\]]"#,
        options: [.caseInsensitive])

    /// Jeux en plusieurs disques rangés dans le même dossier (« Metal Gear Solid - The Twin Snakes (Europe) (Disc 1) »
    /// et « (Disc 2) ») : un seul jeu, lancé sur son premier disque, les autres choisis depuis le menu pause.
    /// GameCube : le moteur passe aussi tout seul au disque suivant quand le jeu le demande.
    nonisolated private static func groupDiscs(_ games: [Game]) -> [Game] {
        var result: [Game] = []
        var groups: [String: [(number: Int, game: Game)]] = [:]
        for game in games {
            let name = game.baseName
            let range = NSRange(name.startIndex..., in: name)
            guard multiDiscSystems.contains(game.system),
                  let match = discTag.firstMatch(in: name, range: range),
                  let numberRange = Range(match.range(at: 1), in: name),
                  let number = Int(name[numberRange]) else {
                result.append(game)
                continue
            }
            let base = discTag.stringByReplacingMatches(in: name, range: range, withTemplate: "").lowercased()
            let key = "\(game.system.rawValue)|\(game.url.deletingLastPathComponent().standardizedFileURL.path)|\(base)"
            groups[key, default: []].append((number, game))
        }
        for discs in groups.values {
            // Un seul fichier par numéro (« (Disc 1).iso » et « (Disc 1).rvz » : le premier trouvé).
            var seen = Set<Int>()
            let sorted = discs.sorted { $0.number < $1.number }.filter { seen.insert($0.number).inserted }
            if sorted.count < 2 {
                result += discs.map(\.game)
                continue
            }
            let first = sorted[0].game
            result.append(Game(url: first.url, system: first.system, discs: sorted.map(\.game.url)))
            result += discs.map(\.game).filter { game in !sorted.contains { $0.game.id == game.id } }
        }
        return result
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
    /// Fichiers de jeu ajoutés (ou déjà là) par l'import en cours, et lancement demandé à la fin (jeu ouvert depuis le
    /// Finder).
    private var importGameFiles: [URL] = []
    private var launchAfterImport = false
    /// Fichier du jeu à lancer dès que la bibliothèque relue le contient (ses sauvegardes viennent de cette lecture).
    private var pendingLaunch: URL?
    /// Jeu à lancer : celui ouvert depuis le Finder, une fois ajouté (la bibliothèque le démarre puis remet nil).
    @Published var gameToLaunch: Game?
#if os(iOS)
    private var importBackgroundTask = UIBackgroundTaskIdentifier.invalid
#endif
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

    /// `launch` : jeu ouvert depuis le Finder ; s'il n'y a qu'un jeu dans ce qui est ajouté, il est lancé ensuite.
    func importFiles(_ urls: [URL], launch: Bool = false) {
        guard !urls.isEmpty else { return }
        if launch { launchAfterImport = true }
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
#if os(iOS)
        importBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Import de jeux") { [weak self] in
            cancel.cancel()
            MainActor.assumeIsolated { self?.endImportBackgroundTask() }
        }
#endif
        Task.detached(priority: .userInitiated) { [self] in
            await runImports(cancel: cancel)
        }
    }

    func cancelImport() {
        importCancel.cancel()
        importCancelRequested = true
    }

    nonisolated private func runImports(cancel: ImportCancel) async {
        Self.removeLeftoverStaging()
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
        case .added(let count, let files):
            importAdded += count
            importGameFiles += files
        case .alreadyThere(let files):
            importPresent += 1
            importGameFiles += files
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
        if launchAfterImport && !cancelled { pendingLaunch = Self.singleGame(in: importGameFiles) }
        launchAfterImport = false
        importGameFiles = []

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
#if os(iOS)
        guard importBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(importBackgroundTask)
        importBackgroundTask = .invalid
#endif
    }

    /// Le fichier du jeu à lancer parmi ces fichiers, s'il n'y a qu'un jeu : une liste .m3u plutôt que ses disques, un
    /// .cue plutôt que ses pistes (qui ne sont pas des jeux).
    private static func singleGame(in files: [URL]) -> URL? {
        var games = Set(files.map(\.standardizedFileURL)).filter { GameSystem.detect($0) != nil }
        if games.count > 1 {
            for preferred in ["m3u", "cue"] {
                let kept = games.filter { $0.pathExtension.lowercased() == preferred }
                if !kept.isEmpty {
                    games = kept
                    break
                }
            }
        }
        return games.count == 1 ? games.first : nil
    }

    private enum ImportResult {
        /// Nombre de fichiers écrits ; ceux restés dans Jeux (un BIOS part dans BIOS).
        case added(Int, [URL])
        /// Déjà dans Jeux (ou BIOS), sous-dossiers compris, ou même nom et même taille : rien n'est copié.
        case alreadyThere([URL])
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
#if PLAYTENDO_VITA
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            return try importVitaFolder(url, stats: &stats, update: update)
        }
#endif
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
            return .alreadyThere([url])
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
        if isSameFile(destination, size: size) { return .alreadyThere([destination]) }
        guard let target = uniqueURL(destination) else { throw ImportError.nameTaken(destination.lastPathComponent) }
        let name = target.lastPathComponent
        try PTFileCopy.copyItem(at: url, to: target) { copied, total in update(.copying, name, copied, total) }
        stats.written = max(size, 0)
        stats.files = 1
        return .added(1, moveIfPS2BIOS(target) ? [] : [target])
    }

#if PLAYTENDO_VITA
    /// Dossier glissé (sur Mac surtout, sans app Fichiers) : les jeux, DLC et mises à jour PS Vita extraits de la console
    /// (dossier avec sce_sys/param.sfo), le dossier lui-même ou jusqu'à trois niveaux dessous (« VitaiOS/app/PCSA00011 »,
    /// « addcont/PCSA00011/<DLC> »), et les .PUP et .vpk qu'il contient. Copie du système : sur le même disque (APFS), un clone immédiat qui ne prend pas de place.
    nonisolated private static func importVitaFolder(_ url: URL, stats: inout ImportStats,
                                                     update: ImportUpdate) throws -> ImportResult {
        stats.format = "dossier"
        var folders: [URL] = []
        var files: [URL] = []
        var rePatches: [URL] = []
        collectVitaContent(url, depth: 0, folders: &folders, files: &files, rePatches: &rePatches)
        let manager = FileManager.default
        let games = Paths.games.resolvingSymlinksInPath().path + "/"
        var added = 0
        var kept: [URL] = []
        var present: [URL] = []
        for folder in folders {
            if folder.resolvingSymlinksInPath().path.hasPrefix(games) {
                present.append(folder)
                continue
            }
            let target = Paths.games.appendingPathComponent(folder.lastPathComponent)
            if manager.fileExists(atPath: target.path), VitaGame.identity(of: target) == VitaGame.identity(of: folder) {
                present.append(target)
                continue
            }
            let destination = uniqueFolderURL(named: folder.lastPathComponent)
            guard update(.copying, folder.lastPathComponent, 0, 0) else { throw PTArchiveError(.cancelled) }
            try manager.copyItem(at: folder, to: destination)
            stats.files += 1
            added += 1
            kept.append(destination)
        }
        // rePatch : remplace celui du même jeu déjà dans Jeux (le plus récent compte).
        for rePatch in rePatches {
            let target = Paths.games.appendingPathComponent("rePatch/\(rePatch.lastPathComponent)", isDirectory: true)
            if rePatch.resolvingSymlinksInPath().path.hasPrefix(games) {
                present.append(rePatch)
                continue
            }
            guard update(.copying, "rePatch \(rePatch.lastPathComponent)", 0, 0) else { throw PTArchiveError(.cancelled) }
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
            try manager.copyItem(at: rePatch, to: target)
            stats.files += 1
            added += 1
        }
        for file in files {
            switch try importFile(file, stats: &stats, update: update) {
            case .added(let count, let urls):
                added += count
                kept += urls
            case .alreadyThere(let urls):
                present += urls
            default:
                break
            }
        }
        if added > 0 { return .added(added, kept) }
        return present.isEmpty ? .unsupported : .alreadyThere(present)
    }

    nonisolated private static func collectVitaContent(_ url: URL, depth: Int, folders: inout [URL], files: inout [URL],
                                                       rePatches: inout [URL]) {
        if VitaGame.isGameFolder(url) {
            folders.append(url)
            return
        }
        // Dossier rePatch : un sous-dossier par jeu (« rePatch/PCSE00428 »).
        if url.lastPathComponent.lowercased() == "repatch" {
            let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                                         options: [.skipsHiddenFiles])) ?? []
            rePatches += entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            return
        }
        guard depth < 3,
              let entries = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                                         options: [.skipsHiddenFiles]) else { return }
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                collectVitaContent(entry, depth: depth + 1, folders: &folders, files: &files, rePatches: &rePatches)
            } else if ["pup", "vpk"].contains(entry.pathExtension.lowercased()) {
                files.append(entry)
            }
        }
    }
#endif

    /// Décompresse chaque jeu, BIOS ou piste de l'archive ; le reste est sauté. Les BIOS vont dans BIOS. Les autres
    /// fichiers passent par un dossier caché de Jeux, puis : un seul fichier va à la racine de Jeux ; plusieurs, ou des
    /// pistes de CD (.bin…), restent ensemble dans un dossier au nom de l'archive, avec ses sous-dossiers (un .cue ou
    /// un .m3u y retrouve ses fichiers). Avant, tout allait à la racine de Jeux et la piste « Track 01.bin » d'un autre
    /// jeu était écrasée (audit du 2026-10-20). Une erreur ou une annulation ne laisse rien de cette archive dans Jeux.
    nonisolated private static func importArchive(_ url: URL, stats: inout ImportStats,
                                                  update: ImportUpdate) throws -> ImportResult {
        let archive = try PTArchiveReader(url: url)
        let manager = FileManager.default
        let staging = Paths.games.appendingPathComponent("\(stagingPrefix)\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: staging) }
        let folderName = folderName(forArchive: url)
        var added = 0
        var present = 0
        var hasCIA = false
        var files: [URL] = []
        /// Fichiers décompressés dans `staging` (chemins dans l'archive), à mettre à leur place à la fin.
        var staged: [String] = []
        while try archive.nextEntry() {
            stats.format = archive.formatName
            let name = (archive.entryPath as NSString).lastPathComponent
            if stats.entries.count < 8 { stats.entries.append(name) }
            if (name as NSString).pathExtension.lowercased() == "cia" { hasCIA = true }
            // Fichiers cachés du Mac (« __MACOSX/…/._Jeu.bin ») : pas des jeux.
            guard let relative = safeRelativePath(archive.entryPath),
                  let destination = destination(forFileNamed: name) else { continue }
            let toBIOS = destination.deletingLastPathComponent() == Paths.bios
            // Déjà là (même nom, même taille) : à la racine de Jeux, ou rangé par un import précédent de cette archive.
            let candidates = toBIOS ? [destination]
                : [destination, Paths.games.appendingPathComponent(relative),
                   Paths.games.appendingPathComponent(folderName).appendingPathComponent(relative)]
            if let existing = candidates.first(where: { isSameFile($0, size: archive.entrySize) }) {
                present += 1
                files.append(existing)
                continue
            }
            let size = max(archive.entrySize, 0)
            try checkFreeSpace(for: size)
            let target: URL
            if toBIOS {
                // Un BIOS remplace celui du même nom (uniqueURL ne renvoie jamais nil dans BIOS).
                guard let bios = uniqueURL(destination) else { continue }
                target = bios
            } else {
                target = staging.appendingPathComponent(relative)
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            let fileName = target.lastPathComponent
            guard update(.extracting, fileName, 0, size) else { throw PTArchiveError(.cancelled) }
            var written: Int64 = 0
            try archive.extractEntry(to: target) { done in
                written = done
                return update(.extracting, fileName, done, size)
            }
            stats.written += written
            stats.files += 1
            added += 1
            if !toBIOS && !moveIfPS2BIOS(target) { staged.append(relative) }
        }
        if !staged.isEmpty { files += try placeStaged(staged, from: staging, folderName: folderName) }
        if added > 0 { return .added(added, files) }
        if present > 0 { return .alreadyThere(files) }
        return hasCIA ? .cia3DS : .noGame
    }

    /// Début du nom du dossier caché où une archive est décompressée (Jeux/.import-…).
    nonisolated private static let stagingPrefix = ".import-"

    /// Dossiers d'import laissés par une app arrêtée en pleine décompression : effacés au début de l'import suivant.
    nonisolated private static func removeLeftoverStaging() {
        let manager = FileManager.default
        for name in (try? manager.contentsOfDirectory(atPath: Paths.games.path)) ?? [] where name.hasPrefix(stagingPrefix) {
            try? manager.removeItem(at: Paths.games.appendingPathComponent(name))
        }
    }

    /// Chemin d'un fichier dans l'archive, sans « .. » ni dossier caché (jamais hors du dossier où elle est
    /// décompressée). Nil pour les fichiers cachés du Mac (« __MACOSX », « ._Jeu.bin »).
    nonisolated private static func safeRelativePath(_ path: String) -> String? {
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        guard let last = parts.last, !last.hasPrefix("._"), !parts.contains("__MACOSX") else { return nil }
        // Un dossier caché (« .quelquechose ») deviendrait invisible dans Jeux : son nom perd ses points de tête.
        return parts.map { part in
            let visible = part.drop(while: { $0 == "." })
            return visible.isEmpty ? "_" : String(visible)
        }.joined(separator: "/")
    }

    /// Nom du dossier d'un jeu tiré d'une archive : celui de l'archive, sans son extension ni points de tête.
    nonisolated private static func folderName(forArchive url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent.drop(while: { $0 == "." })
        return name.isEmpty ? "Jeu" : String(name)
    }

    /// Met à leur place dans Jeux les fichiers décompressés dans `staging` ; renvoie leurs adresses finales.
    nonisolated private static func placeStaged(_ relatives: [String], from staging: URL,
                                                folderName: String) throws -> [URL] {
        let manager = FileManager.default
        let together = relatives.count > 1
            || relatives.contains { GameSystem.companionExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
        guard together else {
            // Un seul fichier (cas le plus courant) : à la racine de Jeux, comme avant.
            let source = staging.appendingPathComponent(relatives[0])
            guard let target = uniqueURL(Paths.games.appendingPathComponent(source.lastPathComponent)) else {
                throw ImportError.nameTaken(source.lastPathComponent)
            }
            try manager.moveItem(at: source, to: target)
            return [target]
        }
        // Tout dans un seul dossier en tête de l'archive (« Jeu/… ») : c'est lui qui devient le dossier du jeu.
        let tops = Set(relatives.map { $0.split(separator: "/").first.map(String.init) ?? $0 })
        let single = tops.count == 1 && relatives.allSatisfy { $0.contains("/") } ? tops.first : nil
        let source = single.map { staging.appendingPathComponent($0, isDirectory: true) } ?? staging
        let target = uniqueFolderURL(named: single ?? folderName)
        try manager.moveItem(at: source, to: target)
        let prefix = single.map { $0.count + 1 } ?? 0
        return relatives.map { target.appendingPathComponent(String($0.dropFirst(prefix))) }
    }

    /// Dossier « Nom » dans Jeux, ou « Nom 2 »… s'il existe déjà (jamais coupé à un point, rien n'est effacé).
    nonisolated private static func uniqueFolderURL(named name: String) -> URL {
        var candidate = Paths.games.appendingPathComponent(name, isDirectory: true)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = Paths.games.appendingPathComponent("\(name) \(index)", isDirectory: true)
            index += 1
        }
        return candidate
    }

    /// Un fichier du même nom et de la même taille est déjà là : c'est le même jeu, il n'est pas ajouté une 2e fois.
    nonisolated private static func isSameFile(_ url: URL, size: Int64) -> Bool {
        guard size > 0, let existing = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        else { return false }
        return existing.int64Value == size
    }

    private enum ImportError: LocalizedError {
        case notEnoughSpace(needed: Int64, free: Int64)
        /// Une piste de CD (.bin…) du même nom, mais différente, est déjà dans Jeux (celle d'un autre jeu).
        case nameTaken(String)

        var errorDescription: String? {
            switch self {
            case .notEnoughSpace(let needed, let free):
                let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                return "pas assez de place (il faut \(format(needed)), il reste \(format(free)))"
            case .nameTaken(let name):
                return "un autre fichier « \(name) » est déjà dans Jeux"
            }
        }

        /// Pour l'utilisateur, dans la langue de l'interface.
        var shown: String {
            switch self {
            case .notEnoughSpace(let needed, let free):
                tr("pas assez de place (il faut \(AppLanguage.bytes(needed)), il reste \(AppLanguage.bytes(free)))")
            case .nameTaken(let name):
                tr("un autre fichier « \(name) » est déjà dans Jeux (celui d'un autre jeu ?). Importe ce jeu dans une archive .zip : il aura son propre dossier.")
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
        do {
            try moveToBIOS(url)
            PTLogLine("BIOS PS2 rangé dans BIOS : \(url.lastPathComponent)")
            return true
        } catch {
            PTLogLine("BIOS PS2 \(url.lastPathComponent) : rangement impossible (\(error.localizedDescription))")
            return false
        }
    }

    /// Range `url` dans BIOS sous son nom, à la place d'un fichier du même nom s'il y en a un. Rien n'est effacé avant
    /// le déplacement : si le fichier vient d'être rangé ailleurs (import et lecture de Jeux en même temps), le
    /// déplacement échoue simplement. Avant, le fichier de BIOS était effacé d'abord, et un BIOS rangé au même moment
    /// par l'autre fil disparaissait (audit du 2026-10-20 : 8 pertes sur 1 200 essais).
    nonisolated private static func moveToBIOS(_ url: URL) throws {
        let target = Paths.bios.appendingPathComponent(url.lastPathComponent)
        let manager = FileManager.default
        if manager.fileExists(atPath: target.path) {
            _ = try manager.replaceItemAt(target, withItemAt: url)
        } else {
            try manager.moveItem(at: url, to: target)
        }
    }

    /// Une fois (2026-10-12) : les dossiers vides restés dans Jeux, laissés par les jeux PS Vita installés ou supprimés
    /// avant que l'app retire elle-même les dossiers devenus vides (« app ( Little Big Planet ) »…). Sans entrer dans
    /// les jeux PS Vita en dossier.
    nonisolated private static func removeEmptyFoldersOnce(in root: URL) {
        let key = "dossiersVidesRetires"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                  options: [.skipsHiddenFiles]) else { return }
        var folders: [URL] = []
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
#if PLAYTENDO_VITA
            if VitaGame.isGameFolder(url) {
                enumerator.skipDescendants()
                continue
            }
#endif
            folders.append(url)
        }
        // Les plus profonds d'abord : un dossier qui ne contenait que des dossiers vides le devient à son tour.
        for folder in folders.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            guard let rest = try? manager.contentsOfDirectory(atPath: folder.path), rest.allSatisfy({ $0.hasPrefix(".") }),
                  (try? manager.removeItem(at: folder)) != nil else { continue }
            PTLogLine("Dossier vide retiré de Jeux : \(folder.lastPathComponent)")
        }
    }

#if PLAYTENDO_VITA
    /// Un fichier de mise à jour PS Vita (.PUP) arrivé dans Jeux est rangé dans BIOS, où le moteur le cherche.
    @discardableResult
    nonisolated private static func moveIfVitaFirmware(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "pup", VitaGame.isFirmware(url) else { return false }
        do {
            try moveToBIOS(url)
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

    /// Évite d'écraser un fichier existant : « Jeu.gba » → « Jeu 2.gba ». Un BIOS remplace celui du même nom. Une piste
    /// de CD (.bin…) garde son nom exact (son .cue la cite) : si une autre du même nom est déjà dans Jeux, nil (avant,
    /// elle était effacée, alors qu'elle pouvait être celle d'un autre jeu : audit du 2026-10-20).
    nonisolated private static func uniqueURL(_ url: URL) -> URL? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension.lowercased()
        if url.deletingLastPathComponent() == Paths.bios {
            try? manager.removeItem(at: url)
            return url
        }
        if GameSystem.companionExtensions.contains(ext) { return nil }
        let base = url.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            // Sans extension (dossier d'un jeu PS Vita) : « PCSH00250 2 », sans point final.
            let name = url.pathExtension.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(url.pathExtension)"
            let candidate = url.deletingLastPathComponent().appendingPathComponent(name)
            if !manager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    // MARK: Suppression

    /// Supprime le jeu avec ses fichiers associés (pistes .bin d'un .cue, disques d'un .m3u). Un jeu PS Vita est
    /// aussi désinstallé de la mémoire de la console. Les sauvegardes sont conservées.
    /// `removingSaves` : PS Vita, ses sauvegardes partent aussi (choisi dans la confirmation).
    func delete(_ game: Game, removingSaves: Bool = false) {
#if PLAYTENDO_VITA
        if game.system == .vita, let titleID = VitaGame.titleID(of: game.url) {
            VitaGame.uninstall(titleID: titleID,
                               removingSavesIn: removingSaves ? VitaGame.saveFolderName(of: game.url) : nil)
            // Ses DLC et mises à jour pas encore installés (dans Jeux), et son rePatch, partent avec lui.
            for addon in VitaGame.pendingAddons(for: titleID) {
                try? FileManager.default.removeItem(at: addon.url)
                VitaGame.removeEmptyFolders(containing: addon.url)
            }
            if let rePatch = VitaGame.rePatchFolder(for: titleID) {
                try? FileManager.default.removeItem(at: rePatch)
                VitaGame.removeEmptyFolders(containing: rePatch)
            }
        }
#endif
        for file in Self.files(of: game) {
            try? FileManager.default.removeItem(at: file)
        }
        // Dossier du jeu devenu vide (jeu tiré d'une archive, jeu PS Vita extrait d'une console…).
        Self.removeEmptyFolders(containing: game.url)
        games.removeAll { $0.id == game.id }
    }

    /// Dossiers de Jeux devenus vides après le départ d'un jeu (« app » extrait d'une Vita, dossier d'une archive…) :
    /// retirés en remontant, jamais le dossier Jeux lui-même.
    nonisolated static func removeEmptyFolders(containing file: URL) {
        let games = Paths.games.resolvingSymlinksInPath().path + "/"
        var folder = file.deletingLastPathComponent()
        while folder.resolvingSymlinksInPath().path.hasPrefix(games),
              let rest = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
              rest.allSatisfy({ $0.hasPrefix(".") }),
              (try? FileManager.default.removeItem(at: folder)) != nil {
            PTLogLine("Dossier vide retiré de Jeux : \(folder.lastPathComponent)")
            folder = folder.deletingLastPathComponent()
        }
    }

    /// Le fichier du jeu suivi des fichiers qu'il référence, à condition qu'ils soient dans Jeux et
    /// qu'aucun autre jeu du même dossier ne s'en serve.
    nonisolated static func files(of game: Game) -> [URL] {
        let main = game.url.standardizedFileURL
        var result = [main]
        // Jeu en plusieurs disques : les autres disques partent avec lui.
        var queue = referencedFiles(of: main) + game.discs.dropFirst().map(\.standardizedFileURL)
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
