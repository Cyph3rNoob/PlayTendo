import Foundation

/// Codes de triche à télécharger (menu pause › Codes de triche › Codes disponibles). NES, SNES, Game Boy, GBA, N64,
/// DS, PS1, PSP : base libretro-database (dossier cht, licence CC BY-SA 4.0), un fichier par jeu et par appareil
/// (« (Game Genie) », « (Code Breaker) »…). GameCube, Wii : codes fournis avec Dolphin (dans l'app) et base Gecko en
/// ligne codes.rc24.xyz (celle de Dolphin). PS2 : collection pcsx2_cheats_collection (celle d'ARMSX2, par version
/// exacte), sinon base de CheatDevicePS2 (GPL-3.0) par le titre. Tous arrivent coupés ; ceux qu'un moteur ne lit pas
/// sont écartés.
enum CheatLibrary {
    struct Download {
        var cheats: [Cheat] = []
        /// Codes dans un format que le moteur ne lit pas (chiffrés, avec « ???? » à remplacer…), écartés.
        var skipped = 0
        /// Codes trouvés pour une autre version du jeu (autre région) : ils peuvent ne pas marcher.
        var otherVersion: String?
        /// Remarque à montrer avec le résultat (PS2 : codes faits pour une autre version, sans doute).
        var note: String?
    }

    enum Failure: Error {
        /// Nom officiel ou numéro du jeu inconnus : impossible de trouver ses codes.
        case unknownGame
        case offline
    }

    static func isAvailable(for system: GameSystem) -> Bool {
        libretroFolder(system) != nil || [.gameCube, .wii, .ps2].contains(system)
    }

    /// Codes trouvés pour ce jeu (pas encore ajoutés à ses codes). PS2 : `ps2Identity` = numéro et CRC du jeu en cours,
    /// donnés par le moteur.
    static func download(for game: Game, officialName: String?,
                         ps2Identity: (serial: String, crc: UInt32)? = nil) async throws -> Download {
        switch game.system {
        case .gameCube, .wii:
            return try await dolphinCodes(for: game)
        case .ps2:
            return try await ps2Codes(officialName: officialName, identity: ps2Identity)
        default:
            return try await libretroCodes(for: game, officialName: officialName)
        }
    }

    // MARK: libretro-database

    private static let repository = "libretro/libretro-database"

    static func libretroFolder(_ system: GameSystem) -> String? {
        switch system {
        case .nes: "Nintendo - Nintendo Entertainment System"
        case .snes: "Nintendo - Super Nintendo Entertainment System"
        case .gb: "Nintendo - Game Boy"
        case .gbc: "Nintendo - Game Boy Color"
        case .gba: "Nintendo - Game Boy Advance"
        case .n64: "Nintendo - Nintendo 64"
        case .nds: "Nintendo - Nintendo DS"
        case .psx: "Sony - PlayStation"
        case .psp: "Sony - PlayStation Portable"
        default: nil
        }
    }

    private static func libretroCodes(for game: Game, officialName: String?) async throws -> Download {
        guard let folder = libretroFolder(game.system) else { return Download() }
        let serial = game.system == .psp ? GameIdentifier.keys(for: game.url, system: .psp).serials.first : nil
        guard officialName != nil || serial != nil else { throw Failure.unknownGame }
        let files = try await listing(folder: folder)
        let match = matchingFiles(files, officialName: officialName, serial: serial, system: game.system)
        guard !match.files.isEmpty else { return Download() }
        var download = Download(otherVersion: match.otherVersion)
        for file in match.files {
            let path = "cht/\(folder)/\(file)"
            guard let text = try await fetchText("https://raw.githubusercontent.com/\(repository)/master/\(escape(path))") else {
                continue
            }
            let device = splitDevice(String(file.dropLast(4))).device
            let parsed = parseCHT(text, system: game.system, source: device.map { "libretro · \($0)" } ?? "libretro")
            download.cheats += parsed.cheats
            download.skipped += parsed.skipped
        }
        return download
    }

    /// Fichiers .cht d'une console (une requête à l'API de GitHub, gardée une semaine : elle en permet 60 par heure).
    private static func listing(folder: String) async throws -> [String] {
        let cache = cacheDirectory.appendingPathComponent("\(folder).json")
        let saved = (try? Data(contentsOf: cache)).flatMap { try? JSONDecoder().decode(Listing.self, from: $0) }
        if let saved, Date().timeIntervalSince(saved.date) < 7 * 24 * 3600 { return saved.files }
        let url = "https://api.github.com/repos/\(repository)/git/trees/master:\(escape("cht/\(folder)"))"
        guard let data = try? await fetch(url),
              let tree = try? JSONDecoder().decode(Tree.self, from: data) else {
            // Hors ligne ou trop de demandes : l'ancienne liste fait l'affaire.
            if let saved { return saved.files }
            throw Failure.offline
        }
        let files = tree.tree.map(\.path).filter { $0.hasSuffix(".cht") }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Listing(date: Date(), files: files)).write(to: cache, options: .atomic)
        return files
    }

    private struct Listing: Codable {
        let date: Date
        let files: [String]
    }

    private struct Tree: Decodable {
        struct Entry: Decodable { let path: String }
        let tree: [Entry]
    }

    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CodesDeTriche")
    }

    /// Appareils nommés en fin de fichier (« … (USA) (Game Genie).cht »). « Rumbles » : vibrations de RetroArch, pas
    /// des codes.
    private static let devices: Set<String> = [
        "game genie", "gameshark", "game shark", "gameshark sp", "action replay", "pro action replay", "code breaker",
        "codebreaker", "xploder", "game buster", "rumbles", "diff", "diff2", "duckstation", "retroarch",
    ]

    /// « Nom (USA) (Game Genie) » → (« Nom (USA) », « Game Genie »).
    static func splitDevice(_ stem: String) -> (base: String, device: String?) {
        var base = stem
        var device: String?
        while let range = base.range(of: #"\s*\(([^()]*)\)$"#, options: .regularExpression) {
            let tag = base[range].trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
            guard devices.contains(tag.lowercased()) else { break }
            if device == nil, !["diff", "diff2"].contains(tag.lowercased()) { device = tag }
            base.removeSubrange(range)
        }
        return (base, device)
    }

    /// Fichiers du jeu : même nom officiel (PSP : même numéro), sinon le même titre dans une autre version.
    static func matchingFiles(_ files: [String], officialName: String?, serial: String?,
                              system: GameSystem) -> (files: [String], otherVersion: String?) {
        let usable = files.filter { !$0.lowercased().contains("(rumbles)") }
        if system == .psp, let serial {
            let wanted = normalizedSerial(serial)
            let found = usable.filter { file in
                file.matches(of: #/\[([A-Z]{4})-?(\d{5})\]/#).contains { normalizedSerial(String($0.output.0)) == wanted }
            }
            if !found.isEmpty { return (found, nil) }
        }
        guard let officialName else { return ([], nil) }
        // Disques PS1 : les codes valent pour tous les disques (« (Disc 1) » n'est pas dans le nom du fichier).
        let name = normalized(officialName.replacingOccurrences(of: #"\s*\(Disc \d+\)"#, with: "", options: .regularExpression))
        let exact = usable.filter { normalized(splitDevice(String($0.dropLast(4))).base) == name }
        if !exact.isEmpty { return (exact, nil) }
        // Autre version (autre région, nommage d'avant No-Intro « (U) ») : celle dont les mentions ressemblent le plus.
        let title = titleOnly(officialName)
        var byBase: [String: [String]] = [:]
        for file in usable {
            let base = splitDevice(String(file.dropLast(4))).base
            let fileTitle = system == .psp ? titleOnly(base.replacingOccurrences(of: #"\s*\[.*$"#, with: "", options: .regularExpression))
                                           : titleOnly(base)
            if fileTitle == title { byBase[base, default: []].append(file) }
        }
        let tags = Set(officialName.lowercased().matches(of: #/\(([^()]*)\)/#).flatMap {
            $0.output.1.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        })
        let best = byBase.keys.max { a, b in
            let score = { (base: String) in
                base.lowercased().matches(of: #/\(([^()]*)\)/#).flatMap {
                    $0.output.1.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                }.filter(tags.contains).count
            }
            return (score(a), b) < (score(b), a)
        }
        guard let best else { return ([], nil) }
        // Même région (« (Europe) » pour « (Europe) (En,Fr,De) », « (France) » pour « (France) (NDSi Enhanced) ») :
        // c'est le même jeu, sans avertissement.
        let ownRegions = regions(officialName), fileRegions = regions(best)
        let sameRegion = !ownRegions.isDisjoint(with: fileRegions) || fileRegions.contains("world") || ownRegions.contains("world")
        return (byBase[best] ?? [], sameRegion ? nil : best)
    }

    private static let regionNames: Set<String> = [
        "world", "usa", "europe", "japan", "france", "germany", "spain", "italy", "netherlands", "sweden", "australia",
        "asia", "korea", "china", "taiwan", "hong kong", "brazil", "canada", "uk", "russia", "scandinavia",
        "u", "e", "j", "f", "g",
    ]

    /// Régions citées entre parenthèses (« (USA, Europe) » → usa, europe ; nommage d'avant « (U) » → usa).
    private static func regions(_ name: String) -> Set<String> {
        let short = ["u": "usa", "e": "europe", "j": "japan", "f": "france", "g": "germany"]
        let tags = name.lowercased().matches(of: #/\(([^()]*)\)/#).flatMap {
            $0.output.1.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return Set(tags.filter(regionNames.contains).map { short[$0] ?? $0 })
    }

    private static func normalizedSerial(_ serial: String) -> String {
        serial.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Titre sans mentions entre parenthèses ni ponctuation (« Super Mario 64 (U) » → « super mario 64 »).
    private static func titleOnly(_ name: String) -> String {
        let bare = name.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        return String(bare.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ").joined(separator: " ")
    }

    /// Fichier .cht de RetroArch : « cheatN_desc = "…" », « cheatN_code = "…" ». Les codes que le moteur ne lit pas
    /// sont comptés à part ; les codes « maîtres » passent en tête.
    static func parseCHT(_ text: String, system: GameSystem, source: String) -> (cheats: [Cheat], skipped: Int) {
        var descriptions: [Int: String] = [:]
        var codes: [Int: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let equal = line.firstIndex(of: "="),
                  let match = line[..<equal].trimmingCharacters(in: .whitespaces).wholeMatch(of: #/cheat(\d+)_(desc|code)/#),
                  let index = Int(match.output.1) else { continue }
            var value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            value = value.replacingOccurrences(of: "\\\"", with: "\"").trimmingCharacters(in: .whitespaces)
            if match.output.2 == "desc" { descriptions[index] = value } else { codes[index] = value }
        }
        var cheats: [Cheat] = []
        var skipped = 0
        for index in codes.keys.sorted() {
            // Lignes de titre (« ___[>>> Fixes <<<]___ ») : un code tout à zéro, sans effet.
            guard let code = codes[index], !code.isEmpty, !isEmptyCode(code) else { continue }
            guard Cheats.parts(of: code, system: system) != nil else {
                skipped += 1
                continue
            }
            let name = descriptions[index].flatMap { $0.isEmpty ? nil : $0 } ?? "Code \(index + 1)"
            cheats.append(Cheat(name: name, code: code, enabled: false, source: source))
        }
        return (cheats.filter(\.isMaster) + cheats.filter { !$0.isMaster }, skipped)
    }

    // MARK: PS2

    /// D'abord la collection d'ARMSX2 (fichiers .pnach rangés par numéro et CRC : la version exacte du jeu), sinon la
    /// base de CheatDevicePS2 cherchée par le titre (versions américaines seulement).
    private static func ps2Codes(officialName: String?, identity: (serial: String, crc: UInt32)?) async throws -> Download {
        if let identity {
            let crc = String(format: "%08X", identity.crc)
            for file in ["\(identity.serial)_\(crc).pnach", "\(crc).pnach"] {
                let url = "https://raw.githubusercontent.com/xs1l3n7x/pcsx2_cheats_collection/main/cheats/\(escape(file))"
                if let text = try await fetchText(url) {
                    let parsed = parsePnach(text, source: "PCSX2 · xs1l3n7x")
                    if !parsed.cheats.isEmpty { return Download(cheats: parsed.cheats, skipped: parsed.skipped) }
                }
            }
        }
        guard let officialName else { throw Failure.unknownGame }
        let base = try await cheatDeviceDatabase()
        guard let found = cheatDeviceGame(in: base, officialName: officialName) else { return Download() }
        var download = Download(cheats: found.cheats, skipped: found.skipped)
        // La base ne contient que des versions américaines.
        if !regions(officialName).contains("usa") { download.note = tr("Codes de la base CheatDevicePS2 pour « \(found.title) », faits pour la version américaine : certains peuvent ne pas marcher avec la tienne.") }
        return download
    }

    /// Types de codes que PCSX2 sait faire (Patch.cpp, « extended ») : 0 à 7, D et E. Les autres (codes « maîtres »
    /// 9 et F des boîtiers de triche…) sont retirés.
    private static func ps2Supported(_ address: Substring) -> Bool {
        guard let first = address.first?.uppercased() else { return false }
        return "01234567DE".contains(first)
    }

    /// Fichier .pnach : un code par « [Nom] » (les groupes du même nom qui se suivent n'en font qu'un), lignes « patch= »
    /// gardées seulement si PCSX2 sait les faire.
    static func parsePnach(_ text: String, source: String) -> (cheats: [Cheat], skipped: Int) {
        var groups: [(name: String, lines: [String])] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if groups.last?.name != name { groups.append((name, [])) }
            } else if line.lowercased().hasPrefix("patch=") {
                if groups.isEmpty { groups.append((tr("Codes"), [])) }
                let fields = line.split(separator: ",")
                if fields.count >= 5, ps2Supported(fields[2].trimmingCharacters(in: .whitespaces)[...]) {
                    groups[groups.count - 1].lines.append(line)
                } else {
                    groups[groups.count - 1].lines.append("")
                }
            }
        }
        var cheats: [Cheat] = []
        var skipped = 0
        for group in groups {
            let lines = group.lines.filter { !$0.isEmpty }
            let cheat = Cheat(name: group.name, code: lines.joined(separator: "\n"), enabled: false, source: source)
            if lines.isEmpty || cheat.isMaster || Cheats.parts(of: cheat.code, system: .ps2) == nil {
                skipped += 1
            } else {
                cheats.append(cheat)
            }
        }
        return (cheats, skipped)
    }

    /// Base de CheatDevicePS2 (github.com/root670/CheatDevicePS2, CheatDatabase.txt, GPL-3.0) : téléchargée la première
    /// fois (6,4 Mo), gardée un mois.
    private static func cheatDeviceDatabase() async throws -> String {
        let cache = cacheDirectory.appendingPathComponent("CheatDevicePS2.txt")
        let date = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let date, Date().timeIntervalSince(date) < 30 * 24 * 3600, let text = try? String(contentsOf: cache, encoding: .utf8) {
            return text
        }
        let url = "https://raw.githubusercontent.com/root670/CheatDevicePS2/master/CheatDatabase.txt"
        if let data = try? await fetch(url), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: cache, options: .atomic)
            return text
        }
        if let text = try? String(contentsOf: cache, encoding: .utf8) { return text }
        throw Failure.offline
    }

    /// Le jeu dans la base (titre entre guillemets, puis ses codes jusqu'au titre suivant), cherché par son titre sans
    /// région, ponctuation ni petits mots (« Shadow of the Colossus » = « Shadow Of Colossus ») ; sinon le seul titre
    /// qui le prolonge (« Burnout Revenge » → « Burnout-Revenge-Battle Racing Ignited »).
    static func cheatDeviceGame(in base: String, officialName: String) -> (title: String, cheats: [Cheat], skipped: Int)? {
        func key(_ name: String) -> String {
            titleOnly(name).split(separator: " ").filter { !["the", "a", "an", "and"].contains($0) }.joined(separator: " ")
        }
        let wanted = key(officialName)
        guard !wanted.isEmpty else { return nil }
        let lines = base.split(whereSeparator: \.isNewline)
        var exact: Int?
        var longer: [Int] = []
        for (index, line) in lines.enumerated() where line.hasPrefix("\"") {
            let title = key(line.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")))
            if title == wanted {
                exact = index
                break
            }
            if title.hasPrefix(wanted + " ") { longer.append(index) }
        }
        guard let start = exact ?? (longer.count == 1 ? longer[0] : nil) else { return nil }
        var end = start + 1
        while end < lines.count, !lines[end].hasPrefix("\"") { end += 1 }
        let title = lines[start].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        let parsed = parseCheatDevice(lines[(start + 1)..<end])
        return (title, parsed.cheats, parsed.skipped)
    }

    /// Codes d'un jeu de CheatDevicePS2 : un nom, puis ses lignes « XXXXXXXX YYYYYYYY » ; un nom sans ligne est le titre
    /// d'une partie (« Action Mission Codes »), mis devant les noms suivants.
    static func parseCheatDevice(_ lines: ArraySlice<Substring>) -> (cheats: [Cheat], skipped: Int) {
        var cheats: [Cheat] = []
        var skipped = 0
        var section: String?
        var name: String?
        var codes: [String] = []
        func finish() {
            guard let name, !codes.isEmpty else { return }
            let kept = codes.filter { ps2Supported($0.prefix(8)) }
            let cheat = Cheat(name: section.map { "\($0) › \(name)" } ?? name, code: kept.joined(separator: "\n"),
                              enabled: false, source: "CheatDevicePS2")
            if kept.isEmpty || Cheat(name: name, code: "").isMaster || Cheats.parts(of: cheat.code, system: .ps2) == nil {
                skipped += 1
            } else {
                cheats.append(cheat)
            }
        }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.wholeMatch(of: #/[0-9A-Fa-f]{8} [0-9A-Fa-f]{8}/#) != nil {
                if name != nil { codes.append(line) }
                continue
            }
            if let previous = name, codes.isEmpty {
                section = previous
            } else {
                finish()
            }
            name = line
            codes = []
        }
        finish()
        return (cheats, skipped)
    }

    // MARK: GameCube, Wii

    private static func dolphinCodes(for game: Game) async throws -> Download {
        guard let header = GameIdentifier.nintendoDiscHeader(game.url),
              let id = String(data: header.subdata(in: 0..<6), encoding: .ascii),
              id.allSatisfy({ $0.isLetter || $0.isNumber }) else { throw Failure.unknownGame }
        var download = Download()
        let builtIn = dolphinBuiltIn(id: id, revision: Int(header[7]), system: game.system)
        download.cheats = builtIn.cheats
        download.skipped = builtIn.skipped
        // Base Gecko en ligne : sans connexion, les codes de Dolphin suffisent.
        if let text = try? await fetchText("https://codes.rc24.xyz/txt.php?txt=\(id)") {
            let online = parseGeckoDatabase(text, system: game.system)
            let known = Set(download.cheats.map { codeKey($0.code) })
            download.cheats += online.cheats.filter { !known.contains(codeKey($0.code)) }
            download.skipped += online.skipped
        } else if download.cheats.isEmpty {
            throw Failure.offline
        }
        return download
    }

    /// Codes des réglages de jeux de Dolphin (Sys/GameSettings), dans l'ordre où Dolphin lit ces fichiers.
    static func dolphinBuiltIn(id: String, revision: Int, system: GameSystem) -> (cheats: [Cheat], skipped: Int) {
        guard let frameworks = Bundle.main.privateFrameworksPath,
              let resources = Bundle(path: "\(frameworks)/DolphinCore.framework")?.resourceURL else { return ([], 0) }
        let folder = resources.appendingPathComponent("Sys/GameSettings")
        var cheats: [Cheat] = []
        var skipped = 0
        for file in [String(id.prefix(1)), String(id.prefix(3)), id, "\(id)r\(revision)"] {
            guard let text = try? String(contentsOf: folder.appendingPathComponent("\(file).ini"), encoding: .utf8) else { continue }
            let parsed = parseDolphinINI(text, system: system)
            cheats.removeAll { old in parsed.cheats.contains { $0.name == old.name && $0.kind == old.kind } }
            cheats += parsed.cheats
            skipped += parsed.skipped
        }
        return (cheats, skipped)
    }

    /// Sections [ActionReplay] et [Gecko] d'un fichier de réglages de Dolphin : « $Nom [auteur] », lignes du code,
    /// notes « * ». (Les [OnFrame] sont des retouches d'un autre format, que l'app n'envoie pas.)
    static func parseDolphinINI(_ text: String, system: GameSystem) -> (cheats: [Cheat], skipped: Int) {
        var cheats: [Cheat] = []
        var skipped = 0
        var kind: Cheat.Kind?
        var name: String?
        var lines: [String] = []
        func finish() {
            defer { name = nil; lines = [] }
            guard let kind, let name, !lines.isEmpty else { return }
            let code = lines.joined(separator: "\n")
            guard Cheats.parts(of: code, system: system, kind: kind) != nil else {
                skipped += 1
                return
            }
            cheats.append(Cheat(name: name, code: code, enabled: false, kind: kind, source: "Dolphin"))
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                finish()
                kind = line == "[ActionReplay]" ? .actionReplay : line == "[Gecko]" ? .gecko : nil
            } else if kind != nil, line.hasPrefix("$") {
                finish()
                name = String(line.dropFirst()).replacingOccurrences(of: #"\s*\[[^\]]*\]\s*$"#, with: "", options: .regularExpression)
            } else if kind != nil, name != nil, !line.isEmpty, !line.hasPrefix("*"), !line.hasPrefix("#") {
                lines.append(line)
            }
        }
        finish()
        return (cheats, skipped)
    }

    /// Base Gecko en ligne (format lu par Dolphin, GeckoCodeConfig.cpp) : identifiant, titre, ligne vide, puis des
    /// blocs « Nom [auteur] », lignes « XXXXXXXX YYYYYYYY », notes ; séparés par une ligne vide.
    static func parseGeckoDatabase(_ text: String, system: GameSystem) -> (cheats: [Cheat], skipped: Int) {
        var cheats: [Cheat] = []
        var skipped = 0
        // « \r\n » est un seul caractère pour Swift : découpe sur toute fin de ligne.
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var name: String?
        var codeLines: [String] = []
        var inNotes = false
        func finish() {
            defer { name = nil; codeLines = []; inNotes = false }
            guard let name, !codeLines.isEmpty else { return }
            let code = codeLines.joined(separator: "\n")
            guard Cheats.parts(of: code, system: system, kind: .gecko) != nil else {
                skipped += 1
                return
            }
            cheats.append(Cheat(name: name, code: code, enabled: false, kind: .gecko, source: "Gecko · codes.rc24.xyz"))
        }
        for line in lines.dropFirst(3) {
            if line.isEmpty {
                finish()
            } else if name == nil {
                name = line.replacingOccurrences(of: #"\s*\[[^\]]*\]\s*$"#, with: "", options: .regularExpression)
            } else if !inNotes {
                let parts = line.split(separator: " ")
                if parts.count == 2 && parts.allSatisfy({ $0.count == 8 }) {
                    codeLines.append(line)
                } else {
                    inNotes = true
                }
            }
        }
        finish()
        return (cheats, skipped)
    }

    private static func isEmptyCode(_ code: String) -> Bool {
        codeKey(code.replacingOccurrences(of: "_L", with: "").replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: "0X", with: "")).allSatisfy { $0 == "0" }
    }

    /// Code sans espaces ni casse, pour ne pas ajouter deux fois le même.
    static func codeKey(_ code: String) -> String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: Réseau

    private static func escape(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))) ?? path
    }

    private static func fetch(_ url: String) async throws -> Data? {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("PlayTendo", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return data
        } catch {
            throw Failure.offline
        }
    }

    private static func fetchText(_ url: String) async throws -> String? {
        guard let data = try await fetch(url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}
