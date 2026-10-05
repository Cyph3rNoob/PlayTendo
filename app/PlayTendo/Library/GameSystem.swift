import SwiftUI

enum Brand: String {
    case nintendo = "Nintendo"
    case sony = "Sony"
}

/// Disposition des boutons tactiles propre à chaque console.
enum ControlScheme {
    case nes
    case snes
    case gameBoy
    case gameBoyAdvance
    case nintendoDS
    case playStation

    var hasShoulders: Bool { self == .snes || self == .gameBoyAdvance || self == .nintendoDS || self == .playStation }
    var hasSecondShoulders: Bool { self == .playStation }
    var hasFourFaceButtons: Bool { self == .snes || self == .nintendoDS || self == .playStation }
    var usesTouchScreen: Bool { self == .nintendoDS }
}

enum GameSystem: String, CaseIterable, Identifiable, Codable {
    case nes, snes, gb, gbc, gba, nds, psx

    var id: String { rawValue }

    var name: String {
        switch self {
        case .nes: "Nintendo NES"
        case .snes: "Super Nintendo"
        case .gb: "Game Boy"
        case .gbc: "Game Boy Color"
        case .gba: "Game Boy Advance"
        case .nds: "Nintendo DS"
        case .psx: "PlayStation"
        }
    }

    var shortName: String {
        switch self {
        case .nes: "NES"
        case .snes: "SNES"
        case .gb: "GB"
        case .gbc: "GBC"
        case .gba: "GBA"
        case .nds: "DS"
        case .psx: "PS1"
        }
    }

    var brand: Brand { self == .psx ? .sony : .nintendo }

    /// Extensions affichées dans la bibliothèque.
    var extensions: Set<String> {
        switch self {
        case .nes: ["nes", "fds", "unf", "unif"]
        case .snes: ["sfc", "smc"]
        case .gb: ["gb"]
        case .gbc: ["gbc"]
        case .gba: ["gba"]
        case .nds: ["nds"]
        case .psx: Self.psxExtensions
        }
    }

    #if DEBUG
    /// En test, les programmes PS1 « .exe » (mini-jeux de test) sont aussi acceptés.
    private static let psxExtensions: Set<String> = ["cue", "chd", "pbp", "m3u", "exe"]
    #else
    private static let psxExtensions: Set<String> = ["cue", "chd", "pbp", "m3u"]
    #endif

    /// Nom du framework du moteur embarqué dans l'app.
    var coreName: String {
        switch self {
        case .nes: "mesen"
        case .snes: "bsnes"
        case .gb, .gbc, .gba: "mgba"
        case .nds: "melondsds"
        case .psx: "pcsx_rearmed"
        }
    }

    var engineName: String {
        switch self {
        case .nes: "Mesen"
        case .snes: "bsnes"
        case .gb, .gbc, .gba: "mGBA"
        case .nds: "melonDS DS"
        case .psx: "PCSX-ReARMed"
        }
    }

    /// Sous-dossier de Documents/Sauvegardes.
    var folderName: String {
        switch self {
        case .nes: "NES"
        case .snes: "SNES"
        case .gb: "GB"
        case .gbc: "GBC"
        case .gba: "GBA"
        case .nds: "DS"
        case .psx: "PS1"
        }
    }

    var controls: ControlScheme {
        switch self {
        case .nes: .nes
        case .snes: .snes
        case .gb, .gbc: .gameBoy
        case .gba: .gameBoyAdvance
        case .nds: .nintendoDS
        case .psx: .playStation
        }
    }

    /// Réglages imposés au moteur (le reste garde ses valeurs par défaut).
    var coreOptions: [String: String] {
        switch self {
        case .nds:
            [
                "melonds_touch_mode": "touch",
                "melonds_show_cursor": "disabled",
                "melonds_number_of_screen_layouts": "1",
                "melonds_screen_gap": "0",
                "melonds_hybrid_ratio": "3",
            ]
        case .psx:
            ["pcsx_rearmed_drc": "disabled"]
        default:
            [:]
        }
    }

    /// DS : disposition des deux écrans. En portrait ils sont empilés ; en paysage, l'écran
    /// principal est en grand à gauche et l'autre, trois fois plus petit, à droite.
    func screenOptions(landscape: Bool, swapped: Bool) -> [String: String] {
        guard self == .nds else { return [:] }
        let layout = landscape
            ? (swapped ? "largescreen-bottom" : "largescreen-top")
            : (swapped ? "bottom-top" : "top-bottom")
        return ["melonds_screen_layout1": layout]
    }

    /// Zone de l'écran tactile dans l'image du jeu (de 0 à 1), nil si la console n'en a pas.
    func touchScreenRect(landscape: Bool, swapped: Bool) -> CGRect? {
        guard self == .nds else { return nil }
        if landscape {
            return swapped
                ? CGRect(x: 0, y: 0, width: 0.75, height: 1)
                : CGRect(x: 0.75, y: 1.0 / 3.0, width: 0.25, height: 1.0 / 3.0)
        }
        return swapped ? CGRect(x: 0, y: 0, width: 1, height: 0.5) : CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
    }

    var colors: [Color] {
        switch self {
        case .nes: [Color(red: 0.78, green: 0.13, blue: 0.16), Color(red: 0.42, green: 0.06, blue: 0.10)]
        case .snes: [Color(red: 0.42, green: 0.33, blue: 0.74), Color(red: 0.20, green: 0.14, blue: 0.42)]
        case .gb: [Color(red: 0.49, green: 0.60, blue: 0.16), Color(red: 0.19, green: 0.29, blue: 0.10)]
        case .gbc: [Color(red: 0.55, green: 0.27, blue: 0.80), Color(red: 0.86, green: 0.25, blue: 0.47)]
        case .gba: [Color(red: 0.27, green: 0.31, blue: 0.75), Color(red: 0.11, green: 0.12, blue: 0.40)]
        case .nds: [Color(red: 0.38, green: 0.45, blue: 0.55), Color(red: 0.15, green: 0.18, blue: 0.24)]
        case .psx: [Color(red: 0.00, green: 0.22, blue: 0.57), Color(red: 0.05, green: 0.07, blue: 0.20)]
        }
    }

    /// Ordre d'affichage dans la bibliothèque.
    static let displayOrder: [GameSystem] = [.nes, .snes, .gb, .gbc, .gba, .nds, .psx]

    static func forExtension(_ ext: String) -> GameSystem? {
        let ext = ext.lowercased()
        return allCases.first { $0.extensions.contains(ext) }
    }

    /// Fichiers acceptés à l'import sans être affichés comme des jeux (pistes de CD…).
    static let companionExtensions: Set<String> = ["bin", "img", "sub", "sbi"]

    /// BIOS reconnus à l'import : ils sont rangés dans Documents/BIOS.
    static let biosFileNames: Set<String> = [
        "scph1001.bin", "scph5500.bin", "scph5501.bin", "scph5502.bin", "scph7001.bin",
        "scph101.bin", "psxonpsp660.bin",
        "bios7.bin", "bios9.bin", "firmware.bin", "dsi_bios7.bin", "dsi_bios9.bin",
        "gba_bios.bin", "gb_bios.bin", "gbc_bios.bin", "sgb_bios.bin", "disksys.rom",
    ]
}
