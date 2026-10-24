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
    /// 3DS : deux écrans (celui du haut plus large), stick circulaire au-dessus de la croix, A B X Y, L R ZL ZR,
    /// stick C (New 3DS), HOME.
    case nintendo3DS
    case playStation
    case psp
    case playStation2
    case gameCube
    /// Wii : Wiimote + Nunchuk (le choix « GameCube » d'un jeu Wii prend `gameCube`).
    case wiimote
#if PLAYTENDO_VITA
    /// PS Vita : comme la PSP avec un stick droit ; toucher l'image = écran tactile avant.
    case psVita
#endif

    /// PS Vita (seulement dans une app compilée avec elle : PLAYTENDO_VITA, par défaut dans scripts/build_app.sh).
    var isPSVita: Bool {
#if PLAYTENDO_VITA
        self == .psVita
#else
        false
#endif
    }

    var hasShoulders: Bool { ![.nes, .gameBoy].contains(self) }
    var hasSecondShoulders: Bool { [.playStation, .playStation2, .nintendo3DS].contains(self) }
    var hasFourFaceButtons: Bool { [.snes, .nintendoDS, .nintendo3DS, .playStation, .psp, .playStation2].contains(self) || isPSVita }
    var usesPlayStationSymbols: Bool { [.playStation, .psp, .playStation2].contains(self) || isPSVita }
    var usesTouchScreen: Bool { self == .nintendoDS || self == .nintendo3DS }
    /// 3DS : écran du haut en 5:3 (400×240), celui du bas en 4:3 (320×240), centré sous lui dans l'image du moteur.
    var isNintendo3DS: Bool { self == .nintendo3DS }
    /// Stick analogique virtuel (N64, PSP, PS2, GameCube, Nunchuk de la Wii, PS Vita).
    var hasAnalogStick: Bool { [.nintendo64, .psp, .playStation2, .gameCube, .wiimote, .nintendo3DS].contains(self) || isPSVita }
    /// Second stick (droit) : PS2, PS Vita, stick C de la GameCube et de la New 3DS.
    var hasRightStick: Bool { [.playStation2, .gameCube, .nintendo3DS].contains(self) || isPSVita }
    /// À gauche, le stick en haut et une petite croix dessous (N64, GameCube, Wii, 3DS) ; sinon l'inverse.
    var stickAboveDPad: Bool { [.nintendo64, .gameCube, .wiimote, .nintendo3DS].contains(self) }
    var hasSelect: Bool { self != .nintendo64 && self != .gameCube }
    /// N64 : gâchette Z et boutons C jaunes (envoyés au stick analogique droit).
    var isNintendo64: Bool { self == .nintendo64 }
    /// GameCube (et Wii, avec la manette GameCube) : gros A vert, B rouge, X et Y, gâchettes L, R et Z.
    var isGameCube: Bool { self == .gameCube }
    /// Wiimote + Nunchuk : A, B, 1, 2, −, HOME, +, croix ; C et Z du Nunchuk, « secouer » ; on vise en touchant
    /// l'image du jeu.
    var isWiimote: Bool { self == .wiimote }
    /// Toucher l'image du jeu sert de pointeur (Wiimote) ou d'écran tactile avant (PS Vita). La DS a son propre écran
    /// tactile (`usesTouchScreen`).
    var usesPointer: Bool { self == .wiimote || isPSVita }
    /// En paysage, l'image peut prendre toute la hauteur avec les boutons par-dessus (menu pause › IMAGE › TAILLE) :
    /// toutes les consoles à un seul écran.
    var canFillScreen: Bool { !usesTouchScreen }

    /// Manette Nintendo (Switch Pro, Joy-Con) : boutons de l'app faits par ses A, B, X, Y. Par défaut ceux à la même
    /// place (les bonnes lettres sur NES, Super Nintendo, Game Boy, DS, 3DS ; la croix en bas sur les consoles Sony).
    /// GameCube, Wii et N64 ont leur A en bas, comme le A d'une manette Xbox : avec une manette Nintendo, chaque bouton
    /// fait plutôt la lettre écrite dessus, comme sur Switch Online (demandé le 2026-10-07).
    var nintendoLetters: NintendoLetters {
        switch self {
        // A, B, X, Y du jeu (N64 : A et B seulement, ses boutons C sont sur le stick droit).
        case .gameCube, .nintendo64: NintendoLetters(a: .b, b: .y, x: .a, y: .x)
        // A, B (la gâchette), 2 (bouton du haut de l'app), 1 (bouton de gauche).
        case .wiimote: NintendoLetters(a: .b, b: .a, x: .x, y: .y)
        default: .samePlace
        }
    }
}

/// Boutons de l'app (RetroPad) faits par les boutons A, B, X, Y d'une manette Nintendo.
struct NintendoLetters: Equatable {
    var a, b, x, y: PTButton

    /// Même place : A à droite, B en bas, X en haut, Y à gauche.
    static let samePlace = NintendoLetters(a: .a, b: .b, x: .x, y: .y)
}

enum GameSystem: String, CaseIterable, Identifiable, Codable {
    case nes, snes, n64, gb, gbc, gba, nds, n3ds, psx, psp, ps2, gameCube, wii
#if PLAYTENDO_VITA
    /// PS Vita (Vita3K) : mise de côté le 2026-10-10 (rendu trop abîmé sur les puces Apple), remise le 2026-10-12
    /// (mémoire mappée : Gravity Rush jouable) ; seulement dans une app compilée avec elle (PLAYTENDO_VITA, par
    /// défaut dans scripts/build_app.sh).
    case vita
#endif

    var id: String { rawValue }

    /// Consoles de salon : une deuxième manette y joue le joueur 2 (sur les consoles portables, elle joue aussi le
    /// joueur 1).
    var supportsTwoPlayers: Bool { [.nes, .snes, .n64, .psx, .ps2, .gameCube, .wii].contains(self) }

    /// Console encore peu stable, signalée « EXPÉRIMENTAL » (filtre de la bibliothèque, À propos, présentation).
    var isExperimental: Bool { isVita }

    /// PS Vita (toujours faux dans une app compilée sans elle).
    var isVita: Bool {
#if PLAYTENDO_VITA
        self == .vita
#else
        false
#endif
    }

    var name: String {
        switch self {
        case .nes: "Nintendo NES"
        case .snes: "Super Nintendo"
        case .n64: "Nintendo 64"
        case .gb: "Game Boy"
        case .gbc: "Game Boy Color"
        case .gba: "Game Boy Advance"
        case .nds: "Nintendo DS"
        case .n3ds: "Nintendo 3DS"
        case .psx: "PlayStation"
        case .psp: "PlayStation Portable"
        case .ps2: "PlayStation 2"
        case .gameCube: "GameCube"
        case .wii: "Wii"
#if PLAYTENDO_VITA
        case .vita: "PlayStation Vita"
#endif
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
        case .n3ds: "3DS"
        case .psx: "PS1"
        case .psp: "PSP"
        case .ps2: "PS2"
        case .gameCube: "GC"
        case .wii: "Wii"
#if PLAYTENDO_VITA
        case .vita: "Vita"
#endif
        }
    }

    var brand: Brand { [.psx, .psp, .ps2].contains(self) || isVita ? .sony : .nintendo }

    /// Extensions affichées dans la bibliothèque. Certaines servent à plusieurs consoles (« .iso » : PS1, PSP,
    /// PS2, GameCube, Wii ; « .chd » : PS1, PS2 ; « .cso » : PSP, PS2 ; « .rvz »… : GameCube, Wii) :
    /// `detect(_:)` tranche en lisant le disque.
    var extensions: Set<String> {
        switch self {
        case .nes: ["nes", "fds", "unf", "unif"]
        case .snes: ["sfc", "smc"]
        case .n64: ["n64", "z64", "v64"]
        case .gb: ["gb"]
        case .gbc: ["gbc"]
        case .gba: ["gba"]
        case .nds: ["nds"]
        // Jeux décryptés (Azahar ne lit plus les jeux cryptés) ; pas de .cia dans la version libretro.
        case .n3ds: ["3ds", "cci", "cxi", "3dsx", "zcci", "zcxi", "z3dsx"]
        case .psx: Self.psxExtensions
        case .psp: Self.pspExtensions
        case .ps2: ["iso", "chd", "cso"]
        case .gameCube: ["iso", "gcm", "rvz", "wia", "ciso", "gcz"]
        case .wii: ["iso", "wbfs", "rvz", "wia", "ciso", "gcz"]
#if PLAYTENDO_VITA
        // Archive .vpk ; un dossier extrait d'une Vita (avec sce_sys/param.sfo) est aussi un jeu (GameLibrary).
        case .vita: ["vpk"]
#endif
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
        // Game Boy et Game Boy Color : Gambatte (câble link entre deux appareils, LinkCable) ; GBA : mGBA.
        case .gb, .gbc: "gambatte"
        case .gba: "mgba"
        case .nds: "melondsds"
        case .n3ds: "azahar"
        case .psx: "pcsx_rearmed"
        case .psp: "ppsspp"
        case .ps2: "PS2Core"
        case .gameCube, .wii: "DolphinCore"
#if PLAYTENDO_VITA
        case .vita: "VitaCore"
#endif
        }
    }

    var engineName: String {
        switch self {
        case .nes: "Mesen"
        case .snes: "bsnes"
        case .n64: "Mupen64Plus-Next"
        case .gb, .gbc: "Gambatte"
        case .gba: "mGBA"
        case .nds: "melonDS DS"
        case .n3ds: "Azahar"
        case .psx: "PCSX-ReARMed"
        case .psp: "PPSSPP"
        case .ps2: "ARMSX2 (PCSX2)"
        case .gameCube, .wii: "DolphiniOS (Dolphin)"
#if PLAYTENDO_VITA
        case .vita: "Vita3K"
#endif
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
        case .n3ds: "Nintendo - Nintendo 3DS"
        case .psx: "Sony - PlayStation"
        case .psp: "Sony - PlayStation Portable"
        case .ps2: "Sony - PlayStation 2"
        case .gameCube: "Nintendo - GameCube"
        case .wii: "Nintendo - Wii"
#if PLAYTENDO_VITA
        case .vita: "Sony - PlayStation Vita"
#endif
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
        case .n3ds: "3DS"
        case .psx: "PS1"
        case .psp: "PSP"
        case .ps2: "PS2"
        case .gameCube: "GameCube"
        case .wii: "Wii"
#if PLAYTENDO_VITA
        case .vita: "Vita"
#endif
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
        case .n3ds: .nintendo3DS
        case .psx: .playStation
        case .psp: .psp
        case .ps2: .playStation2
        case .gameCube: .gameCube
        // Wii : Wiimote + Nunchuk par défaut ; la manette GameCube se choisit par jeu dans le menu pause
        // (`DolphinSettings.controller(for:)`).
        case .wii: .wiimote
#if PLAYTENDO_VITA
        case .vita: .psVita
#endif
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
                // États affichés en surimpression par le moteur, renvoyés à chaque image (« Layout 1/1 » ~80 fois par
                // seconde) : l'app ne les montre pas, ils ne faisaient que remplir le journal.
                "melonds_show_current_layout": "disabled",
                "melonds_show_mic_state": "disabled",
                "melonds_show_camera_state": "disabled",
                "melonds_show_lid_state": "disabled",
                "melonds_show_sensor_reading": "disabled",
            ].merging(DSSettings.coreOptions) { $1 }
        case .n3ds:
            // Vulkan (MoltenVK) : le seul rendu matériel du moteur sur iPhone et sur Mac. Écrans toujours rendus
            // empilés (le bas centré sous le haut) ; l'app découpe et place ensuite chacun d'eux. Stick droit = stick C
            // seulement (pas de pointeur : on touche l'écran du bas). Recompilateur : sur iPhone si la réserve JIT de
            // l'app est prête (le moteur vérifie aussi GET_JIT_CAPABLE), toujours sur Mac (MAP_JIT).
            [
                "citra_graphics_api": "Vulkan",
                "citra_layout_option": "default",
                "citra_swap_screen": "Top",
                "citra_analog_function": "c_stick",
                "citra_enable_mouse_touchscreen": "disabled",
                "citra_enable_touch_touchscreen": "enabled",
                "citra_use_cpu_jit": "enabled",
                "citra_use_shader_jit": "enabled",
                "citra_language_value": "French",
            ].merging(N3DSSettings.coreOptions) { $1 }
        case .psx:
            ["pcsx_rearmed_drc": "disabled"].merging(PS1Settings.coreOptions) { $1 }
        case .n64:
            // Sans JIT (iOS) : interpréteur « en cache » ; rendu 3D GLideN64 en OpenGL ES.
            [
                "mupen64plus-cpucore": "cached_interpreter",
                "mupen64plus-rdp-plugin": "gliden64",
                "mupen64plus-rsp-plugin": "hle",
            ].merging(N64Settings.coreOptions) { $1 }
        case .psp:
            // Avec la réserve JIT de l'app : recompilation (JIT) ; sinon l'interpréteur « IR », le plus
            // rapide sans recompilation. Résolution et lissage des textures : réglages de l'utilisateur.
            [
                "ppsspp_cpu_core": PTJITIsActive() ? "JIT" : "IR JIT",
                // iPhone : « opengl » = OpenGL ES. Mac : « auto » = l'OpenGL « core » que propose l'app (avec « opengl »,
                // PPSSPP y demanderait l'ancien OpenGL, absent du Mac).
                "ppsspp_backend": Self.pspBackend,
                // Aucun accès réseau (jeu en ligne) : évite toute demande d'autorisation d'iOS.
                "ppsspp_enable_wlan": "disabled",
                "ppsspp_enable_upnp": "disabled",
                // Codes de triche (CWCheat) : lus par PPSSPP seulement si activés.
                "ppsspp_cheats": "enabled",
            ].merging(PSPSettings.coreOptions) { $1 }
        default:
            [:]
        }
    }

    private static var pspBackend: String {
#if os(iOS)
        "opengl"
#else
        "auto"
#endif
    }

    /// Ordre d'affichage dans la bibliothèque et la présentation (choisi par l'utilisateur le 2026-10-07) : Nintendo de
    /// salon, portables Nintendo, puis Sony.
#if PLAYTENDO_VITA
    static let displayOrder: [GameSystem] = [.nes, .snes, .n64, .gameCube, .wii, .gb, .gbc, .gba, .nds, .n3ds, .psx, .ps2, .psp, .vita]
#else
    static let displayOrder: [GameSystem] = [.nes, .snes, .n64, .gameCube, .wii, .gb, .gbc, .gba, .nds, .n3ds, .psx, .ps2, .psp]
#endif

    /// Bibliothèque et présentation : le Game Boy et la Game Boy Color forment une seule catégorie « GB/C » (demandé
    /// le 2026-10-07). Pour le moteur, les sauvegardes, la reconnaissance et les jaquettes, ce restent deux consoles.
    var libraryGroup: GameSystem { self == .gbc ? .gb : self }
    /// Les catégories de la bibliothèque, dans l'ordre (sans la Game Boy Color, rangée avec le Game Boy).
    static let libraryGroups = displayOrder.filter { $0 != .gbc }
    /// Les consoles d'une catégorie.
    var groupMembers: [GameSystem] { self == .gb ? [.gb, .gbc] : [self] }

    static func forExtension(_ ext: String) -> GameSystem? {
        let ext = ext.lowercased()
        return displayOrder.first { $0.extensions.contains(ext) }
    }

    /// Console d'un fichier : d'après l'extension, en lisant le début du fichier pour les
    /// formats partagés entre consoles Sony.
    static func detect(_ url: URL) -> GameSystem? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pbp":
            return pbpIsPlayStation1(url) ? .psx : .psp
        case "iso":
            return isoSystem(url) ?? nintendoDiscSystem(url) ?? .psp
        case "gcm", "rvz", "wia", "wbfs", "ciso", "gcz":
            return nintendoDiscSystem(url)
        case "cso":
            return CSOReader(url: url).flatMap { volumeSystem(ISO9660(reader: $0)) } ?? .psp
        case "chd":
            return chdIsDVD(url) ? .ps2 : .psx
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

    /// Image .iso (secteurs de 2048 octets) ou brute (2352 octets).
    private static func isoSystem(_ url: URL) -> GameSystem? {
        ImageReader(url: url).flatMap { volumeSystem(ISO9660(reader: $0)) }
    }

    /// Identifiant système du volume ISO 9660 : « PSP GAME », ou « PLAYSTATION » pour la PS1 comme pour la PS2.
    /// Dans ce cas, SYSTEM.CNF tranche : « BOOT2 = cdrom0:\… » (PS2) ou « BOOT = cdrom:\… » (PS1).
    private static func volumeSystem(_ iso: ISO9660) -> GameSystem? {
        guard let volume = iso.reader.sectors(16, count: 1), volume.count == 2048,
              volume.subdata(in: 1..<6) == Data("CD001".utf8) else { return nil }
        let systemID = String(decoding: volume.subdata(in: 8..<40), as: UTF8.self)
        if systemID.hasPrefix("PSP GAME") { return .psp }
        guard systemID.hasPrefix("PLAYSTATION") else { return nil }
        guard let config = iso.file("SYSTEM.CNF") else { return .psx }
        return String(decoding: config, as: UTF8.self).uppercased().contains("BOOT2") ? .ps2 : .psx
    }

    /// Disque GameCube ou Wii, d'après les nombres magiques de son en-tête (ou le type d'un .gcz).
    private static func nintendoDiscSystem(_ url: URL) -> GameSystem? {
        if url.pathExtension.lowercased() == "gcz" {
            // En-tête GCZ : 0xB10BC001 puis le type (0 GameCube, 1 Wii), petit-boutistes.
            guard let header = GameIdentifier.read(url, offset: 0, count: 8),
                  GameIdentifier.le32(header, 0) == 0xB10BC001 else { return nil }
            return GameIdentifier.le32(header, 4) == 1 ? .wii : .gameCube
        }
        guard let header = GameIdentifier.nintendoDiscHeader(url) else { return nil }
        return GameIdentifier.isWiiDisc(header) ? .wii : .gameCube
    }

    /// .chd : image de DVD (secteurs de 2048 octets) = PS2 ; image de CD (2352 + 96 octets) = PS1.
    /// (Les rares jeux PS2 sur CD en .chd sont donc vus comme PS1 : les mettre en .iso.)
    private static func chdIsDVD(_ url: URL) -> Bool {
        // En-tête CHD v5 : « MComprHD », version (octets 12-15), taille d'unité (octets 60-63), gros-boutiste.
        guard let header = GameIdentifier.read(url, offset: 0, count: 64), header.prefix(8) == Data("MComprHD".utf8),
              header[header.startIndex + 15] == 5 else { return false }
        let unit = header.subdata(in: 60..<64).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return unit == 2048
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

    /// BIOS PS2 (noms variés, « SCPH-70004_BIOS_V12_EUR_200.BIN »…) : reconnu à son contenu. Un BIOS PS2
    /// fait 4 Mo (8 Mo pour certains modèles) et commence par le répertoire « RESET » / « ROMDIR » de sa ROM.
    static func isPS2BIOS(_ url: URL) -> Bool {
        guard ["bin", "rom", "rom0"].contains(url.pathExtension.lowercased()),
              let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size == 4 << 20 || size == 8 << 20,
              let head = GameIdentifier.read(url, offset: 0, count: 64 << 10) else { return false }
        return isPS2BIOS(head: head, size: size)
    }

    /// Même vérification sur le début du fichier (`head`, au moins 64 Ko) et sa taille.
    static func isPS2BIOS(head: Data, size: Int) -> Bool {
        (size == 4 << 20 || size == 8 << 20)
            && head.prefix(64 << 10).range(of: Data("RESET".utf8)) != nil
            && head.prefix(64 << 10).range(of: Data("ROMVER".utf8)) != nil
    }
}
