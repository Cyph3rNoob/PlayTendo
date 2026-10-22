import Foundation

/// Code de triche d'un jeu (menu pause › Codes de triche), gardé pour ce jeu.
struct Cheat: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var code: String
    var enabled = true
}

/// Codes de triche : consoles qui les lisent, formats acceptés, mise au format de chaque moteur, et fichier où ils
/// sont gardés (Bibliotheque/codes.json, par jeu).
enum Cheats {
    /// Consoles dont le moteur applique les codes (retro_cheat_set). Pas la 3DS (Azahar ne les lit pas), ni les moteurs
    /// autonomes PS2, GameCube, Wii et PS Vita.
    static func supported(_ system: GameSystem) -> Bool {
        [.nes, .snes, .gb, .gbc, .gba, .n64, .psx, .nds, .psp].contains(system)
    }

    /// Formats acceptés, montrés sous le champ du code.
    static func formats(for system: GameSystem) -> String {
        switch system {
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
        cheats.filter(\.enabled).flatMap { parts(of: $0.code, system: system) ?? [] }
    }

    /// Morceaux à envoyer au moteur pour ce code (un appel à retro_cheat_set chacun), ou nil si ce n'est pas un format
    /// de la console. Le texte collé peut tenir sur plusieurs lignes, avec des espaces ou des « + » entre les morceaux.
    static func parts(of code: String, system: GameSystem) -> [String]? {
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
        default:
            return nil
        }
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
