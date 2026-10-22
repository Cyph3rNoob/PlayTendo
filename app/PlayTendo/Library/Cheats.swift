import Foundation

/// Code de triche d'un jeu (menu pause › Codes de triche), gardé pour ce jeu.
struct Cheat: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var code: String
    var enabled = true
    /// GameCube, Wii : Action Replay ou Gecko (en clair, les deux se ressemblent). Nil ailleurs.
    var kind: Kind?

    enum Kind: String, Codable {
        case actionReplay, gecko
    }
}

/// Codes de triche : consoles qui les lisent, formats acceptés, mise au format de chaque moteur, et fichier où ils
/// sont gardés (Bibliotheque/codes.json, par jeu).
enum Cheats {
    /// Consoles dont le moteur applique les codes : moteurs libretro (retro_cheat_set ; la 3DS par une retouche
    /// d'Azahar), PS2 (fichier .pnach) et GameCube, Wii (Dolphin). Pas la PS Vita : Vita3K n'a pas de codes.
    static func supported(_ system: GameSystem) -> Bool {
        [.nes, .snes, .gb, .gbc, .gba, .n64, .psx, .nds, .psp, .n3ds, .ps2, .gameCube, .wii].contains(system)
    }

    /// GameCube, Wii : il faut dire si le code est Action Replay ou Gecko.
    static func hasKinds(_ system: GameSystem) -> Bool {
        system == .gameCube || system == .wii
    }

    /// Formats acceptés, montrés sous le champ du code.
    static func formats(for system: GameSystem, kind: Cheat.Kind? = nil) -> String {
        switch system {
        case .n3ds: return tr("Gateway (Action Replay 3DS), par paires (ex. 12345678 00000063).")
        case .ps2: return tr("Lignes .pnach (patch=1,EE,…) ou codes RAW non chiffrés, par paires (ex. 2034A6B8 0000270F). Les codes chiffrés (CodeBreaker, Action Replay MAX) ne marchent pas : prends leur version RAW.")
        case .gameCube, .wii:
            return kind == .gecko ? tr("Gecko, par paires (ex. 04123456 00000063).")
                                  : tr("Action Replay chiffré (ex. 0QR2-KK7T-1DC4X) ou en clair, par paires.")
        default: break
        }
        return switch system {
        case .nes: tr("Game Genie (6 ou 8 lettres, ex. SXIOPO) ou Pro Action Rocky (8 chiffres).")
        case .snes: tr("Game Genie avec son tiret (ex. DD32-6DAD) ou Pro Action Replay (8 chiffres, ex. 7E0DBE05).")
        case .gb, .gbc: tr("Game Genie (ex. 00A-17B-C49) ou GameShark (8 chiffres, ex. 010238CD).")
        case .gba: tr("GameShark, Action Replay ou CodeBreaker, par paires (ex. 82025D80 0063).")
        case .n64: tr("GameShark, par paires (ex. 8033B21E 0008).")
        case .psx: tr("GameShark, par paires (ex. 800A1234 0063).")
        case .nds: tr("Action Replay, par paires de 8 chiffres (ex. 02000300 00000063).")
        case .psp: tr("CWCheat, lignes _L (ex. _L 0x2012345A 0x0000270F).")
        default: ""
        }
    }

    /// Codes à envoyer au moteur : ceux qui sont activés, mis à son format.
    static func engineCodes(for cheats: [Cheat], system: GameSystem) -> [String] {
        cheats.filter(\.enabled).flatMap { parts(of: $0.code, system: system, kind: $0.kind) ?? [] }
    }

    /// PS2 : le fichier .pnach des codes activés (vide : aucun).
    static func pnach(for cheats: [Cheat]) -> String {
        engineCodes(for: cheats, system: .ps2).joined(separator: "\n")
    }

    /// GameCube, Wii : les codes activés, Action Replay d'un côté et Gecko de l'autre, séparés par une ligne vide.
    static func dolphin(for cheats: [Cheat], system: GameSystem) -> (actionReplay: String, gecko: String) {
        let active = cheats.filter(\.enabled)
        func codes(_ kind: Cheat.Kind) -> String {
            active.filter { ($0.kind ?? .actionReplay) == kind }
                .compactMap { parts(of: $0.code, system: system, kind: kind)?.first }
                .joined(separator: "\n\n")
        }
        return (codes(.actionReplay), codes(.gecko))
    }

    /// Morceaux à envoyer au moteur pour ce code (un appel à retro_cheat_set chacun), ou nil si ce n'est pas un format
    /// de la console. Le texte collé peut tenir sur plusieurs lignes, avec des espaces ou des « + » entre les morceaux.
    static func parts(of code: String, system: GameSystem, kind: Cheat.Kind? = nil) -> [String]? {
        switch system {
        case .ps2: return pnachLines(code).map { [$0] }
        case .gameCube, .wii: return dolphinLines(code, kind: kind ?? .actionReplay).map { [$0] }
        default: break
        }
        var text = code
        if system == .psp {
            // CWCheat : seules les lignes « _L » sont des codes (« _S », « _G », « _C0 Nom » : jeu et nom du code).
            let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            let codeLines = lines.filter { $0.uppercased().hasPrefix("_L") }
            if !codeLines.isEmpty { text = codeLines.map { String($0.dropFirst(2)) }.joined(separator: " ") }
        }
        let tokens = text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "+")))
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        switch system {
        case .nes:
            // Mesen : un code par appel, en majuscules ; aussi ses codes « adresse:valeur » et « adresse?test:valeur ».
            let codes = tokens.map { $0.uppercased().replacingOccurrences(of: "-", with: "") }
            let pattern = "[APZLGITYEOXUKSVN]{6}|[APZLGITYEOXUKSVN]{8}|[0-9A-F]{8}|[0-9A-F]{4}:[0-9A-F]{2}|[0-9A-F]{4}\\?[0-9A-F]{2}:[0-9A-F]{2}"
            return codes.allSatisfy { matches($0, pattern) } ? codes : nil
        case .snes:
            // bsnes : un code par appel, en minuscules (il refuse « A » à « F »).
            let codes = tokens.map { $0.lowercased() }
            let pattern = "[0-9a-f]{4}-[0-9a-f]{4}|[0-9a-f]{8}|[0-9a-f]{6}=[0-9a-f]{2}|[0-9a-f]{6}=[0-9a-f]{2}\\?[0-9a-f]{2}"
            return codes.allSatisfy { matches($0, pattern) } ? codes : nil
        case .gb, .gbc:
            // mGBA : les morceaux d'un code séparés par « + ».
            let codes = tokens.map { $0.uppercased() }
            let pattern = "[0-9A-F]{3}-[0-9A-F]{3}(-[0-9A-F]{3})?|[0-9A-F]{8}"
            return codes.allSatisfy { matches($0, pattern) } ? [codes.joined(separator: "+")] : nil
        case .gba:
            return pairs(tokens, first: "[0-9A-Fa-f]{8}", second: "[0-9A-Fa-f]{4}|[0-9A-Fa-f]{8}")
        case .n64, .psx:
            return pairs(tokens, first: "[0-9A-Fa-f]{8}", second: "[0-9A-Fa-f]{4}")
        case .nds:
            return pairs(tokens, first: "[0-9A-Fa-f]{8}", second: "[0-9A-Fa-f]{8}")
        case .psp:
            return pairs(tokens, first: "0[xX][0-9A-Fa-f]{8}", second: "0[xX][0-9A-Fa-f]{8}")
        case .n3ds:
            // Azahar (codes Gateway) : une paire par ligne.
            return pairs(tokens, first: "[0-9A-Fa-f]{8}", second: "[0-9A-Fa-f]{8}")?
                .map { pairLines($0) }
        default:
            return nil
        }
    }

    /// « A B C D » → « A B » puis « C D » sur la ligne suivante.
    private static func pairLines(_ joined: String) -> String {
        let tokens = joined.split(separator: " ")
        return stride(from: 0, to: tokens.count, by: 2).map { "\(tokens[$0]) \(tokens[$0 + 1])" }.joined(separator: "\n")
    }

    /// PS2 : lignes .pnach gardées telles quelles, paires RAW mises au format .pnach (écriture « extended », comme
    /// PCSX2 pour les codes RAW) ; titres « [Nom] », commentaires et lignes d'infos ignorés. Nil si une ligne n'est
    /// ni l'un ni l'autre.
    private static func pnachLines(_ code: String) -> String? {
        var lines: [String] = []
        for raw in code.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if line.isEmpty || line.hasPrefix("//") || line.hasPrefix("[")
                || ["comment=", "author=", "description=", "gametitle="].contains(where: lower.hasPrefix) {
                continue
            }
            if lower.hasPrefix("patch=") {
                let pattern = "PATCH=[0-9]+,(EE|IOP),[0-9A-F]{8},(BYTE|SHORT|WORD|DOUBLE|EXTENDED|BESHORT|BEWORD|BEDOUBLE|BYTES),[0-9A-F]+"
                guard matches(line.uppercased().replacingOccurrences(of: " ", with: ""), pattern) else { return nil }
                lines.append(line.replacingOccurrences(of: " ", with: ""))
                continue
            }
            let tokens = line.components(separatedBy: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "+")))
                .filter { !$0.isEmpty }
            guard let joined = pairs(tokens, first: "[0-9A-Fa-f]{8}", second: "[0-9A-Fa-f]{8}")?.first else { return nil }
            let words = joined.split(separator: " ")
            for index in stride(from: 0, to: words.count, by: 2) {
                lines.append("patch=1,EE,\(words[index].uppercased()),extended,\(words[index + 1].uppercased())")
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// GameCube, Wii : une instruction par ligne. Action Replay : chiffré (« XXXX-XXXX-XXXXX », déchiffré par Dolphin)
    /// ou en clair (paires) ; Gecko : paires.
    private static func dolphinLines(_ code: String, kind: Cheat.Kind) -> String? {
        let tokens = code.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "+")))
            .filter { !$0.isEmpty }.map { $0.uppercased() }
        guard !tokens.isEmpty else { return nil }
        if kind == .actionReplay, tokens.allSatisfy({ matches($0, "[0-9A-Z]{4}-[0-9A-Z]{4}-[0-9A-Z]{5}") }) {
            return tokens.joined(separator: "\n")
        }
        return pairs(tokens, first: "[0-9A-F]{8}", second: "[0-9A-F]{8}").map { pairLines($0[0]) }
    }

    /// Codes en paires « adresse valeur » (GameShark, Action Replay, CWCheat) : envoyés d'un bloc, séparés par une
    /// seule espace (PCSX-ReARMed compte les séparateurs pour retrouver les paires).
    private static func pairs(_ tokens: [String], first: String, second: String) -> [String]? {
        guard tokens.count % 2 == 0 else { return nil }
        for (index, token) in tokens.enumerated() where !matches(token, index % 2 == 0 ? first : second) {
            return nil
        }
        return [tokens.joined(separator: " ")]
    }

    private static func matches(_ token: String, _ pattern: String) -> Bool {
        token.range(of: "^(\(pattern))$", options: .regularExpression) != nil
    }

    // MARK: Fichier

    private static let file = Paths.support.appendingPathComponent("Bibliotheque/codes.json")

    private static func all() -> [String: [Cheat]] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: [Cheat]].self, from: data)) ?? [:]
    }

    static func load(for game: Game) -> [Cheat] {
        all()[game.key] ?? []
    }

    static func save(_ cheats: [Cheat], for game: Game) {
        var all = all()
        all[game.key] = cheats.isEmpty ? nil : cheats
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(all).write(to: file, options: .atomic)
    }
}
