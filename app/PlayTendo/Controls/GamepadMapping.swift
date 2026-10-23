import Foundation

/// Bouton d'une manette, par sa place (une manette Nintendo donne ses boutons par lettre : GamepadManager les remet à
/// leur place). Menu pause › Commandes › Touches de la manette : chaque console choisit ce que fait chacun.
enum GamepadInput: String, CaseIterable, Codable {
    case south, east, west, north, l1, r1, l2, r2, l3, r3, start, select

    var title: String {
        switch self {
        case .south: tr("Bouton du bas")
        case .east: tr("Bouton de droite")
        case .west: tr("Bouton de gauche")
        case .north: tr("Bouton du haut")
        case .l1: "L1 · LB · L"
        case .r1: "R1 · RB · R"
        case .l2: "L2 · LT · ZL"
        case .r2: "R2 · RT · ZR"
        case .l3: tr("Clic du stick gauche")
        case .r3: tr("Clic du stick droit")
        case .start: "Start · Menu · +"
        case .select: "Select · Options · −"
        }
    }

    /// Ce qui est écrit dessus selon la manette (PlayStation · Xbox · Switch).
    var detail: String? {
        switch self {
        case .south: "✕ · A · B"
        case .east: "○ · B · A"
        case .west: "□ · X · Y"
        case .north: "△ · Y · X"
        case .l3: "L3"
        case .r3: "R3"
        default: nil
        }
    }

    /// Bouton de l'app fait d'origine : par position (celui du bas = B, de droite = A, comme une manette Nintendo),
    /// sauf sur GameCube, Wii et N64 avec une manette Nintendo, où chaque bouton fait sa lettre (`letters`).
    func defaultButton(letters: NintendoLetters, nintendoPad: Bool) -> PTButton {
        let place = nintendoPad ? letters : .samePlace
        switch self {
        case .south: return place.b
        case .east: return place.a
        case .west: return place.y
        case .north: return place.x
        case .l1: return .l
        case .r1: return .r
        case .l2: return .l2
        case .r2: return .r2
        case .l3: return .l3
        case .r3: return .r3
        case .start: return .start
        case .select: return .select
        }
    }
}

/// Touches de la manette changées pour une console : bouton de l'app fait par un bouton de la manette, -1 pour rien ;
/// ceux qui n'y sont pas gardent leur bouton d'origine. Gardées par console (`ControlScheme.keyboardID`).
struct GamepadMapping: Equatable {
    var changes: [GamepadInput: Int] = [:]

    func button(for input: GamepadInput, default fallback: PTButton) -> PTButton? {
        guard let value = changes[input] else { return fallback }
        return value < 0 ? nil : PTButton(rawValue: value)
    }

    private static func key(_ scheme: ControlScheme) -> String { "touchesManette.\(scheme.keyboardID)" }

    static func load(for scheme: ControlScheme) -> GamepadMapping {
        let stored = UserDefaults.standard.dictionary(forKey: key(scheme)) as? [String: Int] ?? [:]
        var mapping = GamepadMapping()
        for (name, value) in stored {
            if let input = GamepadInput(rawValue: name) { mapping.changes[input] = value }
        }
        return mapping
    }

    static func save(_ mapping: GamepadMapping, for scheme: ControlScheme) {
        if mapping.changes.isEmpty {
            UserDefaults.standard.removeObject(forKey: key(scheme))
        } else {
            UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: mapping.changes.map { ($0.key.rawValue, $0.value) }),
                                      forKey: key(scheme))
        }
    }
}

extension ControlScheme {
    /// Nom des touches de cette console dans les réglages de l'app (ne pas changer : les touches choisies y sont
    /// rangées).
    var keyboardID: String {
        switch self {
        case .nes: "nes"
        case .snes: "snes"
        case .nintendo64: "n64"
        case .gameBoy: "gb"
        case .gameBoyAdvance: "gba"
        case .nintendoDS: "nds"
        case .nintendo3DS: "3ds"
        case .playStation: "ps1"
        case .psp: "psp"
        case .playStation2: "ps2"
        case .gameCube: "gamecube"
        case .wiimote: "wii"
#if PLAYTENDO_VITA
        case .psVita: "vita"
#endif
        }
    }

    /// Nom court de la console (pastilles de Réglages › Clavier).
    var keyboardName: String {
        switch self {
        case .nes: "NES"
        case .snes: "SNES"
        case .nintendo64: "N64"
        case .gameBoy: "GB / GBC"
        case .gameBoyAdvance: "GBA"
        case .nintendoDS: "DS"
        case .nintendo3DS: "3DS"
        case .playStation: "PS1"
        case .psp: "PSP"
        case .playStation2: "PS2"
        case .gameCube: "GameCube"
        case .wiimote: "Wii"
#if PLAYTENDO_VITA
        case .psVita: "PS Vita"
#endif
        }
    }

    /// Boutons de la console qu'un bouton de la manette peut faire, avec leur nom (numéros RetroPad des boutons
    /// tactiles : par position, N64, GameCube et Wii ont leur A en bas). NES, Super Nintendo, Game Boy, GBA : la
    /// gâchette L2 fait le retour en arrière (EmulatorView).
    var gamepadTargets: [(name: String, button: PTButton)] {
        let abxy: [(String, PTButton)] = [("A", .a), ("B", .b), ("X", .x), ("Y", .y)]
        let playStation: [(String, PTButton)] = [("✕", .b), ("○", .a), ("□", .y), ("△", .x)]
        let start: (String, PTButton) = ("Start", .start)
        let select: (String, PTButton) = ("Select", .select)
        let rewind: (String, PTButton) = (tr("Retour arrière (maintenu)"), .l2)
        let targets: [(String, PTButton)]
        switch self {
        case .nes, .gameBoy:
            targets = [("A", .a), ("B", .b), start, select, rewind]
        case .snes:
            targets = abxy + [("L", .l), ("R", .r), start, select, rewind]
        case .nintendoDS:
            targets = abxy + [("L", .l), ("R", .r), start, select]
        case .gameBoyAdvance:
            targets = [("A", .a), ("B", .b), ("L", .l), ("R", .r), start, select, rewind]
        case .nintendo3DS:
            targets = abxy + [("L", .l), ("R", .r), ("ZL", .l2), ("ZR", .r2), start, select]
        case .nintendo64:
            targets = [("A", .b), ("B", .y), ("Z", .l2), ("L", .l), ("R", .r), start]
        case .playStation:
            targets = playStation + [("L1", .l), ("R1", .r), ("L2", .l2), ("R2", .r2), ("L3", .l3), ("R3", .r3), start, select]
        case .psp:
            targets = playStation + [("L", .l), ("R", .r), start, select]
        case .playStation2:
            targets = playStation + [("L1", .l), ("R1", .r), ("L2", .l2), ("R2", .r2), ("L3", .l3), ("R3", .r3), start, select]
        case .gameCube:
            targets = [("A", .b), ("B", .y), ("X", .a), ("Y", .x), ("Z", .r), ("L", .l2), ("R", .r2), start]
        case .wiimote:
            targets = [("A", .b), ("B", .a), ("1", .y), ("2", .x), ("−", .select), ("+", .start), ("HOME", .r3),
                       (tr("C (Nunchuk)"), .l), (tr("Z (Nunchuk)"), .l2), (tr("Secouer"), .r)]
#if PLAYTENDO_VITA
        case .psVita:
            targets = playStation + [("L", .l), ("R", .r), start, select]
#endif
        }
        return targets.map { (name: $0.0, button: $0.1) }
    }

    /// Nom du bouton de la console fait par ce bouton de l'app, ou nil s'il ne fait rien sur cette console.
    func gamepadTargetName(_ button: PTButton) -> String? {
        gamepadTargets.first { $0.button == button }?.name
    }
}
