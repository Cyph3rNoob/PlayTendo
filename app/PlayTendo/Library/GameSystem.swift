import SwiftUI

enum Brand: String {
    case nintendo = "Nintendo"
    case sony = "Sony"
}

/// Disposition des boutons tactiles propre à chaque console.
enum ControlScheme {
    case nes
    case snes
    case nintendo64
    case gameBoy
    case gameBoyAdvance
    case nintendoDS
    case playStation
    case psp

    var hasShoulders: Bool { ![.nes, .gameBoy].contains(self) }
    var hasSecondShoulders: Bool { self == .playStation }
    var hasFourFaceButtons: Bool { [.snes, .nintendoDS, .playStation, .psp].contains(self) }
    var usesPlayStationSymbols: Bool { self == .playStation || self == .psp }
    var usesTouchScreen: Bool { self == .nintendoDS }
    /// Stick analogique virtuel (N64, PSP).
    var hasAnalogStick: Bool { self == .nintendo64 || self == .psp }
    var hasSelect: Bool { self != .nintendo64 }
    /// N64 : gâchette Z et boutons C jaunes (envoyés au stick analogique droit).
    var isNintendo64: Bool { self == .nintendo64 }
    /// En paysage, l'image peut prendre toute la hauteur avec les boutons par-dessus (réglage du menu).
    var canFillScreen: Bool { self == .psp }
}

enum GameSystem: String, CaseIterable, Identifiable, Codable {
    case nes, snes, n64, gb, gbc, gba, nds, psx, psp

    var id: String { rawValue }

    var name: String {
        switch self {
        case .nes: "Nintendo NES"
        case .snes: "Super Nintendo"
        case .n64: "Nintendo 64"
        case .gb: "Game Boy"
        case .gbc: "Game Boy Color"
        case .gba: "Game Boy Advance"
        case .nds: "Nintendo DS"
        case .psx: "PlayStation"
        case .psp: "PlayStation Portable"
        }
    }

    var shortName: String {
        switch self {
        case .nes: "NES"
        case .snes: "SNES"
        case .n64: "N64"
        case .gb: "GB"
        case .gbc: "GBC"
        case .gba: "GBA"
        case .nds: "DS"
        case .psx: "PS1"
        case .psp: "PSP"
        }
    }

    var brand: Brand { self == .psx || self == .psp ? .sony : .nintendo }

    /// Extensions affichées dans la bibliothèque. « .pbp » et « .iso » existent pour la PS1
    /// comme pour la PSP : `detect(_:)` tranche en lisant le début du fichier.
    var extensions: Set<String> {
        switch self {
        case .nes: ["nes", "fds", "unf", "unif"]
        case .snes: ["sfc", "smc"]
        case .n64: ["n64", "z64", "v64"]
        case .gb: ["gb"]
        case .gbc: ["gbc"]
        case .gba: ["gba"]
        case .nds: ["nds"]
        case .psx: Self.psxExtensions
        case .psp: Self.pspExtensions
        }
    }

    #if DEBUG
    /// En test, les programmes « .exe » (PS1) et « .prx »/« .elf » (PSP) sont aussi acceptés.
    private static let psxExtensions: Set<String> = ["cue", "chd", "pbp", "m3u", "exe"]
    private static let pspExtensions: Set<String> = ["iso", "cso", "pbp", "prx", "elf"]
    #else
    private static let psxExtensions: Set<String> = ["cue", "chd", "pbp", "m3u"]
    private static let pspExtensions: Set<String> = ["iso", "cso", "pbp"]
    #endif

    /// Nom du framework du moteur embarqué dans l'app.
    var coreName: String {
        switch self {
        case .nes: "mesen"
        case .snes: "bsnes"
        case .n64: "mupen64plus_next"
        case .gb, .gbc, .gba: "mgba"
        case .nds: "melondsds"
        case .psx: "pcsx_rearmed"
        case .psp: "ppsspp"
        }
    }

    var engineName: String {
        switch self {
        case .nes: "Mesen"
        case .snes: "bsnes"
        case .n64: "Mupen64Plus-Next"
        case .gb, .gbc, .gba: "mGBA"
        case .nds: "melonDS DS"
        case .psx: "PCSX-ReARMed"
        case .psp: "PPSSPP"
        }
    }

    /// Nom de la console chez libretro (dossiers des jaquettes).
    var libretroName: String {
        switch self {
        case .nes: "Nintendo - Nintendo Entertainment System"
        case .snes: "Nintendo - Super Nintendo Entertainment System"
        case .n64: "Nintendo - Nintendo 64"
        case .gb: "Nintendo - Game Boy"
        case .gbc: "Nintendo - Game Boy Color"
        case .gba: "Nintendo - Game Boy Advance"
        case .nds: "Nintendo - Nintendo DS"
        case .psx: "Sony - PlayStation"
        case .psp: "Sony - PlayStation Portable"
        }
    }

    /// Sous-dossier de Documents/Sauvegardes.
    var folderName: String {
        switch self {
        case .nes: "NES"
        case .snes: "SNES"
        case .n64: "N64"
        case .gb: "GB"
        case .gbc: "GBC"
        case .gba: "GBA"
        case .nds: "DS"
        case .psx: "PS1"
        case .psp: "PSP"
        }
    }

    var controls: ControlScheme {
        switch self {
        case .nes: .nes
        case .snes: .snes
        case .n64: .nintendo64
        case .gb, .gbc: .gameBoy
        case .gba: .gameBoyAdvance
        case .nds: .nintendoDS
        case .psx: .playStation
        case .psp: .psp
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
                // Écrans toujours rendus empilés ; l'app découpe et place ensuite chacun d'eux.
                "melonds_screen_layout1": "top-bottom",
                "melonds_screen_gap": "0",
            ]
        case .psx:
            ["pcsx_rearmed_drc": "disabled"]
        case .n64:
            // Sans JIT (iOS) : interpréteur « en cache » ; rendu 3D GLideN64 en OpenGL ES.
            [
                "mupen64plus-cpucore": "cached_interpreter",
                "mupen64plus-rdp-plugin": "gliden64",
                "mupen64plus-rsp-plugin": "hle",
            ]
        case .psp:
            // Avec la réserve JIT de l'app : recompilation (JIT) ; sinon l'interpréteur « IR », le plus
            // rapide sans recompilation. Résolution et lissage des textures : réglages de l'utilisateur.
            [
                "ppsspp_cpu_core": PTJITIsActive() ? "JIT" : "IR JIT",
                "ppsspp_backend": "opengl",
                // Aucun accès réseau (jeu en ligne) : évite toute demande d'autorisation d'iOS.
                "ppsspp_enable_wlan": "disabled",
                "ppsspp_enable_upnp": "disabled",
            ].merging(PSPSettings.coreOptions) { $1 }
        default:
            [:]
        }
    }

    /// Ordre d'affichage dans la bibliothèque.
    static let displayOrder: [GameSystem] = [.nes, .snes, .n64, .gb, .gbc, .gba, .nds, .psx, .psp]

    static func forExtension(_ ext: String) -> GameSystem? {
        let ext = ext.lowercased()
        return displayOrder.first { $0.extensions.contains(ext) }
    }

    /// Console d'un fichier : d'après l'extension, en lisant le début du fichier pour les
    /// formats partagés entre PS1 et PSP.
    static func detect(_ url: URL) -> GameSystem? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pbp":
            return pbpIsPlayStation1(url) ? .psx : .psp
        case "iso":
            return isoSystem(url) ?? .psp
        default:
            return forExtension(ext)
        }
    }

    /// Un EBOOT.PBP de jeu PS1 contient une image disque « PSISOIMG » / « PSTITLEIMG ».
    private static func pbpIsPlayStation1(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        let header = handle.readData(ofLength: 40)
        guard header.count == 40, header.prefix(4) == Data([0, 0x50, 0x42, 0x50]) else { return true }
        let psarOffset = header.subdata(in: 36..<40).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard (try? handle.seek(toOffset: UInt64(psarOffset))) != nil else { return true }
        let magic = String(decoding: handle.readData(ofLength: 10), as: UTF8.self)
        return magic.hasPrefix("PSISOIMG") || magic.hasPrefix("PSTITLEIMG")
    }

    /// Identifiant système du volume ISO 9660 : « PSP GAME » ou « PLAYSTATION ».
    private static func isoSystem(_ url: URL) -> GameSystem? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Secteurs de 2048 octets (image classique) puis de 2352 octets (image brute).
        for offset: UInt64 in [0x8000, 16 * 2352 + 24] {
            guard (try? handle.seek(toOffset: offset)) != nil else { continue }
            let descriptor = handle.readData(ofLength: 40)
            guard descriptor.count == 40, descriptor.subdata(in: 1..<6) == Data("CD001".utf8) else { continue }
            let systemID = String(decoding: descriptor.subdata(in: 8..<40), as: UTF8.self)
            if systemID.hasPrefix("PSP GAME") { return .psp }
            if systemID.hasPrefix("PLAYSTATION") { return .psx }
        }
        return nil
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
