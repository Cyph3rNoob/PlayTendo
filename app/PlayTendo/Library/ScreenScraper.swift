import Foundation

/// Source principale des jaquettes : ScreenScraper (screenscraper.fr), qui a des boîtes en 3D pour presque tous les
/// jeux. Ses identifiants développeur sont embarqués masqués dans l'app (PTSecrets, scripts/make_secrets.py) et ne
/// partent que vers ses vrais serveurs (certificat épinglé) ; ils ne sont jamais écrits dans le journal. Sans eux,
/// rien n'est demandé. Règles de ScreenScraper pour une app sans compte membre : une seule demande à la fois,
/// 10 000 demandes et 1 000 jeux introuvables par jour, téléchargements lents (images demandées réduites).
enum ScreenScraper {
    enum Result: Sendable {
        /// Image PNG, ce qu'elle est (« boîte 3D », région), et si elle est déjà en 3D.
        case found(Data, description: String, is3D: Bool)
        /// ScreenScraper a répondu : il n'a pas ce jeu, ou pas de boîte pour lui.
        case missing
        /// Pas de réponse utilisable (réseau, serveur fermé, limite du jour) : on réessaiera plus tard.
        case offline
    }

    static var isAvailable: Bool { credentials != nil && !disabled }

    private static let credentials: (id: String, password: String)? = {
        guard let id = PTScreenScraperDevID(), let password = PTScreenScraperDevPassword() else { return nil }
        return (id, password)
    }()

    private static let softName = "PlayTendo"
    private static let api = "https://api.screenscraper.fr/api2"
    /// Largeur demandée : ScreenScraper réduit l'image lui-même, elle arrive bien plus vite.
    private static let imageWidth = 640

    /// Identifiants refusés ou logiciel bloqué par ScreenScraper : plus rien n'est demandé jusqu'au prochain lancement.
    nonisolated(unsafe) private static var disabled = false
    /// Limite du jour atteinte : pas de demande avant cette date (gardée d'un lancement à l'autre).
    private static let pauseKey = "screenscraperPauseJusqua"

    /// Numéros des consoles chez ScreenScraper (systemesListe.php, vérifiés le 2026-10-22).
    private static func systemID(_ system: GameSystem) -> Int? {
        switch system {
        case .nes: 3
        case .snes: 4
        case .n64: 14
        case .gb: 9
        case .gbc: 10
        case .gba: 12
        case .nds: 15
        case .n3ds: 17
        case .psx: 57
        case .ps2: 58
        case .psp: 61
        case .gameCube: 13
        case .wii: 16
#if PLAYTENDO_VITA
        case .vita: 62
#endif
        }
    }

    // MARK: Jaquette d'un jeu

    /// Boîte 3D du jeu (sinon sa boîte 2D), dans la région du jeu si elle existe. Le jeu est cherché par son nom officiel
    /// (celui des bases No-Intro et Redump, que ScreenScraper connaît), sa taille et son empreinte, puis à défaut par
    /// une recherche sur son titre.
    static func cover(officialName: String, system: GameSystem, file: URL) async -> Result {
        guard let credentials, !disabled, let systemID = systemID(system) else { return .missing }
        if let pause = UserDefaults.standard.object(forKey: pauseKey) as? Date, pause > Date() { return .offline }

        await gate.enter()
        defer { Task { await gate.leave() } }

        var parameters = baseParameters(credentials) + [
            URLQueryItem(name: "systemeid", value: "\(systemID)"),
            URLQueryItem(name: "romnom", value: romName(officialName, file: file)),
            URLQueryItem(name: "romtype", value: romType(system)),
        ]
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        if values?.isRegularFile == true, let size = values?.fileSize {
            parameters.append(URLQueryItem(name: "romtaille", value: "\(size)"))
            if let crc = GameIdentifier.keys(for: file, system: system).crcs.first {
                parameters.append(URLQueryItem(name: "crc", value: String(format: "%08X", crc)))
            }
        }

        var game: GameInfo?
        switch await request(GameInfoResponse.self, endpoint: "jeuInfos.php", parameters: parameters) {
        case .ok(let response): game = response.response.jeu
        case .missing: game = nil
        case .offline: return .offline
        }
        if game == nil {
            // Fichier inconnu de ScreenScraper (copie modifiée, jeu PS Vita) : recherche sur le titre.
            switch await search(title: SteamGridDB.searchTitle(officialName), systemID: systemID, credentials: credentials) {
            case .ok(let found): game = found
            case .missing: return .missing
            case .offline: return .offline
            }
        }
        guard let game, let media = bestBox(in: game.medias ?? [], officialName: officialName),
              var components = URLComponents(string: media.url) else { return .missing }
        components.queryItems = (components.queryItems ?? []).filter { $0.name != "maxwidth" }
            + [URLQueryItem(name: "maxwidth", value: "\(imageWidth)")]
        guard let url = components.url else { return .missing }
        switch await download(url) {
        case .ok(let data):
            let is3D = media.type == "box-3D"
            return .found(data, description: "\(is3D ? "boîte 3D" : "boîte 2D"), \(media.region ?? "?")", is3D: is3D)
        case .missing: return .missing
        case .offline: return .offline
        }
    }

    /// Nom du fichier tel que les bases le connaissent : nom officiel + extension du fichier (« Super Mario World
    /// (Europe) (Rev 1).sfc »).
    private static func romName(_ officialName: String, file: URL) -> String {
        let ext = file.pathExtension
        return ext.isEmpty ? officialName : "\(officialName).\(ext)"
    }

    private static func romType(_ system: GameSystem) -> String {
        switch system {
        case .psx, .ps2, .psp, .gameCube, .wii: "iso"
        default: system.isVita ? "dossier" : "rom"
        }
    }

    // MARK: Choix de l'image

    /// Boîte 3D de la région du jeu, sinon d'une région proche, sinon n'importe laquelle ; à défaut, la boîte 2D.
    private static func bestBox(in medias: [Media], officialName: String) -> Media? {
        let regions = preferredRegions(officialName)
        for type in ["box-3D", "box-2D"] {
            let boxes = medias.filter { $0.type == type && !$0.url.isEmpty }
            guard !boxes.isEmpty else { continue }
            for region in regions {
                if let box = boxes.first(where: { $0.region == region }) { return box }
            }
            return boxes[0]
        }
        return nil
    }

    /// Régions dans l'ordre de préférence, d'après celle du nom officiel (« (Europe) », « (USA) », « (Japan) »…) ;
    /// les jeux européens prennent d'abord la boîte française.
    private static func preferredRegions(_ officialName: String) -> [String] {
        let europe = ["fr", "eu", "wor", "ss", "us", "jp"]
        let tags = officialName.components(separatedBy: CharacterSet(charactersIn: "(),")).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if tags.contains("France") || tags.contains("Europe") { return europe }
        if tags.contains("USA") { return ["us", "wor", "ss", "eu", "fr", "jp"] }
        if tags.contains("Japan") { return ["jp", "wor", "ss", "us", "eu", "fr"] }
        return europe
    }

    // MARK: Recherche par titre

    /// Jeu dont le nom ressemble le plus au titre (au moins 60 % de mots en commun), sinon aucun : une jaquette
    /// absente vaut mieux que celle d'un autre jeu.
    private static func search(title: String, systemID: Int,
                               credentials: (id: String, password: String)) async -> Fetch<GameInfo> {
        guard !title.isEmpty else { return .missing }
        let parameters = baseParameters(credentials) + [
            URLQueryItem(name: "systemeid", value: "\(systemID)"),
            URLQueryItem(name: "recherche", value: title),
        ]
        switch await request(SearchResponse.self, endpoint: "jeuRecherche.php", parameters: parameters) {
        case .ok(let response):
            let wanted = Set(GameDatabase.words(title))
            var best: (game: GameInfo, score: Double)?
            for game in response.response.jeux ?? [] where game.id != nil {
                for name in game.noms ?? [] {
                    let words = Set(GameDatabase.words(name.text))
                    let union = wanted.union(words)
                    guard !union.isEmpty else { continue }
                    let score = Double(wanted.intersection(words).count) / Double(union.count)
                    if score > (best?.score ?? 0) { best = (game, score) }
                }
            }
            guard let best, best.score >= 0.6 else { return .missing }
            return .ok(best.game)
        case .missing: return .missing
        case .offline: return .offline
        }
    }

    // MARK: Échanges avec l'API

    private struct GameInfoResponse: Decodable {
        struct Body: Decodable { let jeu: GameInfo? }
        let response: Body
    }

    private struct SearchResponse: Decodable {
        struct Body: Decodable { let jeux: [GameInfo]? }
        let response: Body
    }

    private struct GameInfo: Decodable {
        let id: String?
        let noms: [Name]?
        let medias: [Media]?
    }

    private struct Name: Decodable {
        let text: String
    }

    private struct Media: Decodable {
        let type: String
        let url: String
        let region: String?
    }

    private enum Fetch<Value> {
        case ok(Value), missing, offline
    }

    private static func baseParameters(_ credentials: (id: String, password: String)) -> [URLQueryItem] {
        [URLQueryItem(name: "devid", value: credentials.id),
         URLQueryItem(name: "devpassword", value: credentials.password),
         URLQueryItem(name: "softname", value: softName),
         URLQueryItem(name: "output", value: "json")]
    }

    /// Session sans cache ni cookies (les adresses contiennent les identifiants), certificat épinglé : Let's Encrypt.
    private static let session = URLSession(configuration: .ephemeral, delegate: PinnedTrust(service: "ScreenScraper", pins: [
        PinnedTrust.isrgRootX1, PinnedTrust.isrgRootX2, PinnedTrust.isrgRootYE, PinnedTrust.isrgRootYR,
    ]), delegateQueue: nil)

    private static func request<Value: Decodable>(_ type: Value.Type, endpoint: String,
                                                  parameters: [URLQueryItem]) async -> Fetch<Value> {
        guard var components = URLComponents(string: "\(api)/\(endpoint)") else { return .missing }
        components.queryItems = parameters
        // « + » doit être codé, sinon le serveur le lit comme une espace (mot de passe, titres).
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { return .missing }
        switch await get(url) {
        case .ok(let data):
            guard let decoded = try? JSONDecoder().decode(Value.self, from: data) else {
                PTLogLine("ScreenScraper : réponse illisible (\(endpoint))")
                return .offline
            }
            return .ok(decoded)
        case .missing: return .missing
        case .offline: return .offline
        }
    }

    private static func download(_ url: URL) async -> Fetch<Data> {
        switch await get(url, timeout: 60) {
        case .ok(let data):
            guard ImageCoding.isImage(data) else { return .missing }
            return .ok(data)
        case .missing: return .missing
        case .offline: return .offline
        }
    }

    /// Une demande, avec les réponses d'erreur de ScreenScraper traduites. Une seule nouvelle tentative quand il dit
    /// que trop de demandes sont en cours.
    private static func get(_ url: URL, timeout: TimeInterval = 30) async -> Fetch<Data> {
        for attempt in 0..<2 {
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.setValue("PlayTendo", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { return .offline }
                switch http.statusCode {
                case 200:
                    return .ok(data)
                case 404:
                    return .missing
                case 401, 403, 426:
                    PTLogLine("ScreenScraper refuse les identifiants embarqués (code \(http.statusCode)) : plus de demande jusqu'au prochain lancement")
                    disabled = true
                    return .offline
                case 429 where attempt == 0:
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                case 430, 431:
                    // Limite du jour : pause jusqu'au lendemain.
                    PTLogLine("ScreenScraper : limite de demandes du jour atteinte, reprise demain")
                    UserDefaults.standard.set(Date().addingTimeInterval(12 * 3600), forKey: pauseKey)
                    return .offline
                default:
                    PTLogLine("ScreenScraper indisponible (code \(http.statusCode))")
                    return .offline
                }
            } catch {
                return .offline
            }
        }
        return .offline
    }

    // MARK: Une demande à la fois

    /// ScreenScraper n'accepte qu'une demande à la fois d'une app sans compte membre : les recherches (plusieurs jeux
    /// en parallèle) attendent leur tour ici.
    private static let gate = Gate()

    private actor Gate {
        private var busy = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func enter() async {
            if busy {
                await withCheckedContinuation { waiting.append($0) }
            } else {
                busy = true
            }
        }

        func leave() {
            if waiting.isEmpty {
                busy = false
            } else {
                waiting.removeFirst().resume()
            }
        }
    }
}
