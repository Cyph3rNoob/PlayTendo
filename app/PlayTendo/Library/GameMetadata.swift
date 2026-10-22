import ImageIO
import SwiftUI

/// Ce que l'app sait de chaque jeu au-delà du fichier : son nom officiel (reconnu dans la base),
/// sa jaquette (boîte 3D de ScreenScraper, sinon libretro, sinon SteamGridDB) et la date de la dernière partie.
@MainActor
final class GameMetadata: ObservableObject {
    struct Info: Codable, Equatable {
        var name: String?
        var size: Int64
        var modified: Double
        /// Dernière recherche de jaquette restée sans résultat (on réessaie au bout d'une semaine).
        var coverMissing: Double?
        /// ScreenScraper a déjà répondu pour ce jeu (boîte trouvée ou introuvable) : une jaquette venue d'ailleurs
        /// n'est plus remplacée.
        var screenScraperTried: Bool?
    }

    @Published private(set) var infos: [String: Info] = [:]
    /// Change quand la jaquette d'un jeu arrive (clé du jeu → compteur) : seule sa carte la recharge.
    @Published private(set) var coverRevisions: [String: Int] = [:]
    @Published private(set) var lastPlayed: [String: Double] = [:]
    /// Jeux favoris (clés des jeux) : en tête de leur console, filtre ★ de la bibliothèque.
    @Published private(set) var favorites: Set<String> = []
    /// Change quand des noms officiels changent (jeux reconnus) : la bibliothèque re-range alors ses listes.
    @Published private(set) var namesVersion = 0
    @Published private(set) var details: [String: GameDetails] = [:]

    private var running = false
    private var queued: [Game]?
    /// Jeux de la file à reconnaître de nouveau même sans changement (« Actualiser la jaquette »).
    private var queuedForced = Set<String>()

    private static let infosFile = Paths.support
        .appendingPathComponent("Bibliotheque/infos.json")
    /// Fiches des jeux (ScreenScraper), par console et nom officiel : partagées par les fichiers du même jeu.
    private static let detailsFile = Paths.support
        .appendingPathComponent("Bibliotheque/fiches.json")
    private static let lastPlayedKey = "dernieresParties"
    private static let favoritesKey = "favoris"
    private static let steamGridTriedKey = "jaquettesSteamGridDBEssayees"
    private static let screenScraperTriedKey = "jaquettesScreenScraperEssayees"
    /// Jaquettes déjà téléchargées mises en boîte 3D (plates) ou débarrassées de leurs bords transparents (2026-10-22).
    private static let boxesKey = "jaquettesEnBoites3D"
#if PLAYTENDO_VITA
    /// Jaquettes PS Vita cherchées (2026-10-12) : avant, l'icône du jeu était rangée comme jaquette, sous le titre de
    /// la fiche (« GRAVITY RUSH »). Effacées une fois ; les jeux sont reconnus de nouveau sous leur nouveau nom.
    private static let vitaCoversKey = "jaquettesVitaCherchees"
#endif

    init() {
        if let data = try? Data(contentsOf: Self.infosFile),
           let saved = try? JSONDecoder().decode([String: Info].self, from: data) {
            infos = saved
        }
#if PLAYTENDO_VITA
        if !UserDefaults.standard.bool(forKey: Self.vitaCoversKey) {
            try? FileManager.default.removeItem(at: Self.coverFolder(for: .vita))
            UserDefaults.standard.set(true, forKey: Self.vitaCoversKey)
        }
#endif
        lastPlayed = UserDefaults.standard.dictionary(forKey: Self.lastPlayedKey) as? [String: Double] ?? [:]
        favorites = Set(UserDefaults.standard.stringArray(forKey: Self.favoritesKey) ?? [])
        if let data = try? Data(contentsOf: Self.detailsFile),
           let saved = try? JSONDecoder().decode([String: GameDetails].self, from: data) {
            details = saved
        }
        forgetMissingGames()
    }

    // MARK: Fiches

    private static func detailsKey(name: String, system: GameSystem) -> String { "\(system.rawValue)/\(name)" }

    /// Fiche du jeu, si elle est déjà connue.
    func details(for game: Game) -> GameDetails? {
        guard let name = officialName(for: game) else { return nil }
        return details[Self.detailsKey(name: name, system: game.system)]
    }

    enum DetailsState { case ready, missing, offline }

    /// Fiche du jeu : déjà là, ou demandée à ScreenScraper (fiche ouverte avant que sa jaquette vienne de lui).
    func loadDetails(for game: Game) async -> DetailsState {
        if details(for: game) != nil { return .ready }
        guard let name = officialName(for: game), ScreenScraper.isAvailable else { return .missing }
        let system = game.system
        let file = game.url
        let result = await Task.detached(priority: .userInitiated) {
            await ScreenScraper.details(officialName: name, system: system, file: file)
        }.value
        switch result {
        case .found(let found):
            storeDetails(found, name: name, system: system)
            return .ready
        case .missing: return .missing
        case .offline: return .offline
        }
    }

    private func storeDetails(_ found: GameDetails, name: String, system: GameSystem) {
        details[Self.detailsKey(name: name, system: system)] = found
        let url = Self.detailsFile
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(details).write(to: url, options: .atomic)
    }

    /// Les fiches et dates de partie des jeux qui ne sont plus dans Jeux (supprimés, déplacés, renommés) sont oubliées.
    /// Rien n'est oublié si aucun jeu connu n'est trouvé (dossier Jeux illisible à ce moment-là, par prudence).
    private func forgetMissingGames() {
        let manager = FileManager.default
        func exists(_ key: String) -> Bool {
#if PLAYTENDO_VITA
            // Jeu PS Vita installé dont l'original a quitté Jeux : sa clé ne correspond à aucun fichier de Jeux.
            if key.hasPrefix("app/") { return true }
#endif
            return manager.fileExists(atPath: Paths.games.appendingPathComponent(key).path)
        }
        let keys = Set(infos.keys).union(lastPlayed.keys)
        let missing = keys.filter { !exists($0) }
        guard !missing.isEmpty, missing.count < keys.count else { return }
        for key in missing {
            infos[key] = nil
            lastPlayed[key] = nil
            favorites.remove(key)
        }
        save()
        UserDefaults.standard.set(Array(favorites), forKey: Self.favoritesKey)
        UserDefaults.standard.set(lastPlayed, forKey: Self.lastPlayedKey)
        PTLogLine("Bibliothèque : \(missing.count) fiche(s) de jeux disparus oubliée(s)")
    }

    // MARK: Lecture

    func officialName(for game: Game) -> String? { infos[game.key]?.name }

    /// Nom officiel d'après la base de la console (identifiants lus dans le jeu, sinon nom du fichier).
    nonisolated private static func identify(_ game: Game) -> String? {
        let keys = GameIdentifier.keys(for: game.url, system: game.system)
        return GameDatabase.shared(for: game.system)?.identify(keys: keys, fileName: game.baseName)
    }

    func coverRevision(for game: Game) -> Int { coverRevisions[game.key] ?? 0 }

    func display(for game: Game) -> GameDisplay { GameDisplay(game: game, officialName: officialName(for: game)) }

    func coverFile(for game: Game) -> URL? {
        guard let name = officialName(for: game) else { return nil }
        let url = Self.coverURL(name: name, system: game.system)
        if FileManager.default.fileExists(atPath: url.path) { return url }
#if PLAYTENDO_VITA
        // PS Vita sans vraie jaquette (pas encore trouvée, ou introuvable) : l'icône du jeu.
        if game.system == .vita {
            let icon = Self.vitaIconURL(name: name)
            if FileManager.default.fileExists(atPath: icon.path) { return icon }
        }
#endif
        return nil
    }

    /// Jeux joués récemment, du plus récent au plus ancien.
    func recentGames(in games: [Game], limit: Int = 8) -> [Game] {
        games.filter { lastPlayed[$0.key] != nil }
            .sorted { (lastPlayed[$0.key] ?? 0) > (lastPlayed[$1.key] ?? 0) }
            .prefix(limit).map { $0 }
    }

    func lastPlayedDate(for game: Game) -> Date? {
        lastPlayed[game.key].map { Date(timeIntervalSince1970: $0) }
    }

    // MARK: Mise à jour

    func isFavorite(_ game: Game) -> Bool { favorites.contains(game.key) }

    func toggleFavorite(_ game: Game) {
        if favorites.remove(game.key) == nil { favorites.insert(game.key) }
        UserDefaults.standard.set(Array(favorites), forKey: Self.favoritesKey)
    }

    func markPlayed(_ game: Game) {
        lastPlayed[game.key] = Date().timeIntervalSince1970
        UserDefaults.standard.set(lastPlayed, forKey: Self.lastPlayedKey)
    }

    /// Relance la recherche de jaquette d'un jeu (menu « Actualiser la jaquette »).
    func retryCover(for game: Game) {
        if let name = officialName(for: game) {
            let file = Self.coverURL(name: name, system: game.system)
            try? FileManager.default.removeItem(at: file)
            CoverImages.forget(file)
        }
        infos[game.key]?.coverMissing = nil
        infos[game.key]?.screenScraperTried = nil
        coverRevisions[game.key, default: 0] += 1
        update([game], force: true)
    }

    /// Reconnaît les nouveaux jeux puis télécharge les jaquettes manquantes, en arrière-plan. `force` : reconnus de
    /// nouveau même sans changement.
    func update(_ games: [Game], force: Bool = false) {
        update(games, forced: force ? Set(games.map(\.key)) : [])
    }

    private func update(_ games: [Game], forced: Set<String>) {
        if running {
            queued = (queued ?? []) + games
            queuedForced.formUnion(forced)
            return
        }
        running = true
        let known = infos
        Task.detached(priority: .utility) {
            var found: [String: Info] = [:]
            for game in games {
                let values = try? game.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = Int64(values?.fileSize ?? 0)
                let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
#if PLAYTENDO_VITA
                // PS Vita : pas de base de jeux ; le nom vient de la fiche du jeu (param.sfo), relue à chaque fois (un
                // dossier ne change ni de taille ni de date quand son contenu change). Son icône sert de jaquette en
                // attendant une vraie, ou à défaut.
                let vitaName = game.system == .vita ? VitaGame.officialName(of: game.url) : nil
                let unchanged: Bool
                if game.system == .vita {
                    unchanged = known[game.key]?.name == vitaName
                        && vitaName.map { FileManager.default.fileExists(atPath: Self.vitaIconURL(name: $0).path) } == true
                } else {
                    unchanged = known[game.key].map { $0.size == size && $0.modified == modified } == true
                }
                if !forced.contains(game.key), unchanged {
                    continue
                }
#else
                if !forced.contains(game.key), let info = known[game.key], info.size == size, info.modified == modified {
                    continue
                }
#endif
                let name: String?
#if PLAYTENDO_VITA
                if game.system == .vita {
                    name = vitaName
                    if let name, let icon = VitaGame.icon(of: game.url) {
                        let file = Self.vitaIconURL(name: name)
                        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? icon.write(to: file, options: .atomic)
                    }
                } else {
                    name = Self.identify(game)
                }
#else
                name = Self.identify(game)
#endif
                PTLogLine("Jeu reconnu : \(game.url.lastPathComponent) → \(name ?? "inconnu")")
                found[game.key] = Info(name: name, size: size, modified: modified, coverMissing: nil,
                                       screenScraperTried: nil)
            }
            await self.merge(found)
            await self.downloadCovers(for: games)
            await self.finish()
        }
    }

    private func merge(_ found: [String: Info]) {
        guard !found.isEmpty else { return }
        infos.merge(found) { $1 }
        namesVersion += 1
        save()
    }

    private func finish() {
        running = false
        if let next = queued {
            let forced = queuedForced
            queued = nil
            queuedForced = []
            update(next, forced: forced)
        }
    }

    private func save() {
        let url = Self.infosFile
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(infos).write(to: url, options: .atomic)
    }

    // MARK: Jaquettes

    private func downloadCovers(for games: [Game]) async {
        await convertExistingCovers(for: games)
        let week: Double = 7 * 24 * 3600
        let now = Date().timeIntervalSince1970
        // Source nouvelle (SteamGridDB, puis ScreenScraper) : les jeux restés sans jaquette sont recherchés de
        // nouveau, une fois.
        for (available, key) in [(SteamGridDB.isAvailable, Self.steamGridTriedKey),
                                 (ScreenScraper.isAvailable, Self.screenScraperTriedKey)]
            where available && !UserDefaults.standard.bool(forKey: key) {
            for gameKey in infos.keys where infos[gameKey]?.coverMissing != nil {
                infos[gameKey]?.coverMissing = nil
            }
            UserDefaults.standard.set(true, forKey: key)
        }
        // Jeux sans jaquette ; et, ScreenScraper étant prioritaire, ceux dont la jaquette vient d'une autre source et
        // qu'il n'a pas encore vus (`replacing` : seul ScreenScraper est interrogé, l'ancienne jaquette reste sinon).
        var wanted: [(key: String, name: String, system: GameSystem, file: URL, replacing: Bool)] = []
        var seen = Set<String>()
        for game in games {
            guard let info = infos[game.key], let name = info.name,
                  seen.insert("\(game.system.rawValue)/\(name)").inserted else { continue }
            let hasCover = FileManager.default.fileExists(atPath: Self.coverURL(name: name, system: game.system).path)
            if !hasCover, now - (info.coverMissing ?? 0) > week {
                wanted.append((game.key, name, game.system, game.url, false))
            } else if hasCover, ScreenScraper.isAvailable, info.screenScraperTried != true {
                wanted.append((game.key, name, game.system, game.url, true))
            }
        }
        // Trois recherches à la fois (ScreenScraper, lui, en traite une à la fois).
        for batch in stride(from: 0, to: wanted.count, by: 3) {
            let slice = wanted[batch..<min(batch + 3, wanted.count)]
            let results = await withTaskGroup(of: (Int, CoverOutcome).self) { group in
                for (index, item) in zip(slice.indices, slice) {
                    group.addTask {
                        (index, await Self.fetchCover(name: item.name, system: item.system, file: item.file,
                                                      onlyScreenScraper: item.replacing))
                    }
                }
                var results: [(Int, CoverOutcome)] = []
                for await result in group { results.append(result) }
                return results
            }
            for (index, outcome) in results {
                let item = wanted[index]
                if outcome.screenScraperAnswered { infos[item.key]?.screenScraperTried = true }
                if let found = outcome.details { storeDetails(found, name: item.name, system: item.system) }
                switch outcome.result {
                case .saved:
                    CoverImages.forget(Self.coverURL(name: item.name, system: item.system))
                    // Tous les fichiers du même jeu (même nom officiel) profitent de la jaquette.
                    for game in games where infos[game.key]?.name == item.name {
                        coverRevisions[game.key, default: 0] += 1
                    }
                case .missing:
                    if !item.replacing { infos[item.key]?.coverMissing = now }
                case .offline:
                    break                          // on réessaiera au prochain lancement
                }
            }
            save()
        }
    }

    private enum CoverResult: Sendable { case saved, missing, offline }

    private struct CoverOutcome: Sendable {
        var result: CoverResult
        /// ScreenScraper a répondu (boîte trouvée ou jeu introuvable chez lui) : inutile de le redemander.
        var screenScraperAnswered = false
        /// Fiche du jeu, venue avec la réponse de ScreenScraper.
        var details: GameDetails?
    }

    /// Cherche la jaquette : boîte 3D chez ScreenScraper d'abord ; sinon chez libretro sous le nom exact puis sous les
    /// noms des autres régions ; sinon chez SteamGridDB. `onlyScreenScraper` : le jeu a déjà une jaquette d'ailleurs,
    /// seul ScreenScraper peut la remplacer.
    nonisolated private static func fetchCover(name: String, system: GameSystem, file: URL,
                                               onlyScreenScraper: Bool) async -> CoverOutcome {
        var outcome = CoverOutcome(result: .missing)
        if ScreenScraper.isAvailable {
            switch await ScreenScraper.cover(officialName: name, system: system, file: file) {
            case .found(let data, let description, let is3D, let details):
                let box = is3D ? BoxArt.trimmed(data) : BoxArt.make(from: data, system: system, title: spineTitle(name))
                guard write(box ?? data, name: name, system: system) else { return CoverOutcome(result: .offline) }
                PTLogLine("Jaquette téléchargée sur ScreenScraper (\(description)) : \(name)")
                return CoverOutcome(result: .saved, screenScraperAnswered: true, details: details)
            case .missing(let details):
                outcome.screenScraperAnswered = true
                outcome.details = details
                if onlyScreenScraper { PTLogLine("Pas de boîte chez ScreenScraper, jaquette gardée : \(name)") }
            case .offline:
                if onlyScreenScraper { return CoverOutcome(result: .offline) }
            }
        }
        if onlyScreenScraper { return outcome }

        let candidates = [name] + (GameDatabase.shared(for: system)?.alternatives(to: name).prefix(3) ?? [])
        for candidate in candidates {
            guard let url = remoteCoverURL(name: candidate, system: system) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("PlayTendo", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { outcome.result = .offline; return outcome }
                if http.statusCode == 404 { continue }
                guard http.statusCode == 200, ImageCoding.isImage(data),
                      write(boxed(data, name: name, system: system), name: name, system: system)
                else { outcome.result = .offline; return outcome }
                PTLogLine("Jaquette téléchargée chez libretro : \(candidate)")
                outcome.result = .saved
                return outcome
            } catch {
                outcome.result = .offline
                return outcome
            }
        }
        // Source de secours, si l'app a été compilée avec la clé SteamGridDB.
        switch await SteamGridDB.cover(for: name) {
        case .found(let data, let gameName):
            guard write(boxed(data, name: name, system: system), name: name, system: system)
            else { outcome.result = .offline; return outcome }
            PTLogLine("Jaquette téléchargée sur SteamGridDB (« \(gameName) ») : \(name)")
            outcome.result = .saved
            return outcome
        case .offline:
            outcome.result = .offline
            return outcome
        case .missing:
            break
        }
        let sources = (ScreenScraper.isAvailable ? ["ScreenScraper"] : []) + ["libretro"]
            + (SteamGridDB.isAvailable ? ["SteamGridDB"] : [])
        PTLogLine("Pas de jaquette (\(sources.joined(separator: ", "))) pour : \(name)")
        return outcome
    }

    /// Jaquette plate mise en boîte 3D (BoxArt), comme celles de ScreenScraper.
    nonisolated private static func boxed(_ data: Data, name: String, system: GameSystem) -> Data {
        BoxArt.make(from: data, system: system, title: spineTitle(name)) ?? data
    }

    /// Titre écrit sur la tranche : sans région ni version (« Legend of Zelda, The - … » → « The Legend of Zelda … »).
    nonisolated private static func spineTitle(_ name: String) -> String { SteamGridDB.searchTitle(name) }

    /// Une fois : les jaquettes déjà là deviennent des boîtes 3D (plates) ou perdent leurs bords transparents (boîtes de
    /// ScreenScraper), pour que toutes celles d'une console aient la même forme.
    private func convertExistingCovers(for games: [Game]) async {
        guard !UserDefaults.standard.bool(forKey: Self.boxesKey) else { return }
        // Tous les fichiers du dossier Jaquettes (pas seulement les jeux de cette mise à jour) ; les icônes PS Vita,
        // rangées dans un sous-dossier, restent telles quelles.
        let (converted, total) = await Task.detached(priority: .utility) { () -> (Int, Int) in
            var converted = 0
            var total = 0
            for system in GameSystem.allCases {
                let folder = Self.coverFolder(for: system)
                let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                for file in files where file.pathExtension == "png" {
                    total += 1
                    guard let data = try? Data(contentsOf: file) else { continue }
                    let title = Self.spineTitle(file.deletingPathExtension().lastPathComponent)
                    let box = BoxArt.isFlat(data) ? BoxArt.make(from: data, system: system, title: title)
                                                  : BoxArt.trimmed(data)
                    if let box, (try? box.write(to: file, options: .atomic)) != nil {
                        converted += 1
                        CoverImages.forget(file)
                    }
                }
            }
            return (converted, total)
        }.value
        for game in games { coverRevisions[game.key, default: 0] += 1 }
        UserDefaults.standard.set(true, forKey: Self.boxesKey)
        PTLogLine("Jaquettes mises en boîte 3D : \(converted) sur \(total)")
    }

    nonisolated private static func write(_ data: Data, name: String, system: GameSystem) -> Bool {
        let file = coverURL(name: name, system: system)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: file, options: .atomic)) != nil
    }

    /// Adresse de la jaquette chez libretro : certains caractères du nom y sont remplacés par « _ ».
    nonisolated private static func remoteCoverURL(name: String, system: GameSystem) -> URL? {
        let file = String(name.map { "&*/:`<>?\\|\"".contains($0) ? "_" : $0 }) + ".png"
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/+&;=")
        guard let directory = system.libretroName.addingPercentEncoding(withAllowedCharacters: allowed),
              let encoded = file.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://thumbnails.libretro.com/\(directory)/Named_Boxarts/\(encoded)")
    }

    nonisolated static func coverURL(name: String, system: GameSystem) -> URL {
        coverFolder(for: system).appendingPathComponent("\(safeFileName(name)).png")
    }

    nonisolated private static func coverFolder(for system: GameSystem) -> URL {
        Paths.support.appendingPathComponent("Jaquettes/\(system.folderName)", isDirectory: true)
    }

    nonisolated private static func safeFileName(_ name: String) -> String {
        String(name.map { "/:\\".contains($0) ? "_" : $0 })
    }

#if PLAYTENDO_VITA
    /// Icône d'un jeu PS Vita (icon0.png de sa fiche), rangée à part de sa vraie jaquette.
    nonisolated private static func vitaIconURL(name: String) -> URL {
        coverFolder(for: .vita).appendingPathComponent("Icones/\(safeFileName(name)).png")
    }
#endif
}

/// Titre affiché : nom officiel découpé (« God of War » / « Ghost of Sparta », région « Europe »),
/// ou à défaut le nom du fichier nettoyé.
struct GameDisplay {
    let title: String
    let subtitle: String?
    let region: String?

    init(game: Game, officialName: String?) {
        let source = officialName ?? game.baseName.replacingOccurrences(of: "_", with: " ")
        var title = GameDatabase.title(of: source)
        if title.isEmpty { title = source }
        // « Legend of Zelda, The - … » → « The Legend of Zelda ».
        var subtitle: String?
        if let dash = title.range(of: " - ") {
            subtitle = String(title[dash.upperBound...])
            title = String(title[..<dash.lowerBound])
        }
        for article in ["The", "A", "An", "Le", "La", "Les"] where title.hasSuffix(", \(article)") {
            title = "\(article) \(title.dropLast(article.count + 2))"
        }
        // Nom de fichier non reconnu : on garde le titre entier sur une ligne.
        if officialName == nil, let rest = subtitle {
            self.title = "\(title) \(rest)"
            self.subtitle = nil
        } else {
            self.title = title
            self.subtitle = subtitle
        }
        if let open = source.firstIndex(of: "("), let close = source[open...].firstIndex(of: ")") {
            let tag = source[source.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            region = tag.isEmpty ? nil : tag
        } else {
            region = nil
        }
    }
}

/// Images des jaquettes et vignettes, réduites et gardées en mémoire.
enum CoverImages {
    /// Images décodées gardées en mémoire, au plus ~150 Mo (une grosse bibliothèque ne remplit plus la mémoire : les
    /// moins récentes sont oubliées, puis relues au besoin).
    private static let cache: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.totalCostLimit = 150 << 20
        return cache
    }()
    private static let sizes = [600, 700]
    /// Au plus quatre jaquettes décodées à la fois : en défilant vite, les cartes déjà sorties de l'écran ne passent
    /// plus devant celles qui y entrent.
    private static let decoding = DecodeSlots(count: 4)

    private static func key(_ url: URL, _ maxPixel: Int) -> NSString { "\(url.path)#\(maxPixel)" as NSString }

    static func load(_ url: URL, maxPixel: Int = 700) async -> PlatformImage? {
        if let image = cache.object(forKey: key(url, maxPixel)) { return image }
        await decoding.acquire()
        defer { Task { await decoding.release() } }
        // Carte sortie de l'écran pendant l'attente : rien à décoder.
        if Task.isCancelled { return nil }
        if let image = cache.object(forKey: key(url, maxPixel)) { return image }
        let decoded = await Task.detached(priority: .userInitiated) { () -> (PlatformImage, Int)? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return (PlatformImage.make(cgImage), cgImage.bytesPerRow * cgImage.height)
        }.value
        guard let (image, bytes) = decoded else { return nil }
        cache.setObject(image, forKey: key(url, maxPixel), cost: bytes)
        return image
    }

    private actor DecodeSlots {
        private var free: Int
        private var waiting: [CheckedContinuation<Void, Never>] = []

        init(count: Int) { free = count }

        func acquire() async {
            if free > 0 {
                free -= 1
            } else {
                await withCheckedContinuation { waiting.append($0) }
            }
        }

        func release() {
            if waiting.isEmpty {
                free += 1
            } else {
                waiting.removeFirst().resume()
            }
        }
    }

    /// L'image si elle est déjà en mémoire (sans attendre), sinon nil.
    static func cached(_ url: URL, maxPixel: Int = 700) -> PlatformImage? {
        cache.object(forKey: key(url, maxPixel))
    }

    static func forget(_ url: URL) {
        for size in sizes { cache.removeObject(forKey: key(url, size)) }
    }
}
