// Commandes sur Mac : clavier et souris (l'écran tactile de la DS se touche en cliquant). Les manettes passent par
// GamepadManager, comme sur iPhone.
#if os(macOS)
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Ce qu'une touche du clavier fait en jeu. Chaque console a ses touches (Réglages › Clavier, ou menu pause › Touches
/// clavier) ; seule la touche du menu pause est commune à toutes.
enum KeyCommand: String, CaseIterable, Identifiable {
    case a, b, x, y, l, r, l2, r2, l3, r3, start, select
    /// Croix.
    case up, down, left, right
    /// Stick gauche, et stick droit (boutons C de la N64, C-Stick de la GameCube et de la 3DS).
    case stickUp, stickDown, stickLeft, stickRight
    case cUp, cDown, cLeft, cRight
    case menu

    var id: String { rawValue }

    var action: KeyboardMap.Action {
        switch self {
        case .a: .button(.a)
        case .b: .button(.b)
        case .x: .button(.x)
        case .y: .button(.y)
        case .l: .button(.l)
        case .r: .button(.r)
        case .l2: .button(.l2)
        case .r2: .button(.r2)
        case .l3: .button(.l3)
        // R3 : aussi HOME de la Wiimote.
        case .r3: .button(.r3)
        case .start: .button(.start)
        case .select: .button(.select)
        case .up: .button(.up)
        case .down: .button(.down)
        case .left: .button(.left)
        case .right: .button(.right)
        case .stickUp: .stick(0, .up)
        case .stickDown: .stick(0, .down)
        case .stickLeft: .stick(0, .left)
        case .stickRight: .stick(0, .right)
        case .cUp: .stick(1, .up)
        case .cDown: .stick(1, .down)
        case .cLeft: .stick(1, .left)
        case .cRight: .stick(1, .right)
        case .menu: .menu
        }
    }

    /// Touches d'origine sur cette console, par position (même place sur un clavier AZERTY et QWERTY : la touche
    /// « A » d'un QWERTY est le « Q » d'un AZERTY). Disposition classique des émulateurs (RetroArch).
    func defaultKeys(for scheme: ControlScheme) -> [Int] {
        // Consoles à stick : les flèches font le stick gauche, la croix passe sur T F G H.
        let stick = scheme.hasAnalogStick
        switch self {
        case .a: return [kVK_ANSI_X]
        case .b: return [kVK_ANSI_Z]
        case .x: return [kVK_ANSI_S]
        case .y: return [kVK_ANSI_A]
        case .l: return [kVK_ANSI_Q]
        case .r: return [kVK_ANSI_W]
        case .l2: return [kVK_ANSI_E]
        case .r2: return [kVK_ANSI_R]
        case .l3: return [kVK_Shift]
        case .r3: return [kVK_Tab]
        case .start: return [kVK_Return, kVK_ANSI_KeypadEnter]
        // Maj de droite aussi, comme dans RetroArch.
        case .select: return [kVK_Delete, kVK_RightShift]
        case .up: return [stick ? kVK_ANSI_T : kVK_UpArrow]
        case .down: return [stick ? kVK_ANSI_G : kVK_DownArrow]
        case .left: return [stick ? kVK_ANSI_F : kVK_LeftArrow]
        case .right: return [stick ? kVK_ANSI_H : kVK_RightArrow]
        case .stickUp: return [kVK_UpArrow]
        case .stickDown: return [kVK_DownArrow]
        case .stickLeft: return [kVK_LeftArrow]
        case .stickRight: return [kVK_RightArrow]
        case .cUp: return [kVK_ANSI_I]
        case .cDown: return [kVK_ANSI_K]
        case .cLeft: return [kVK_ANSI_J]
        case .cRight: return [kVK_ANSI_L]
        case .menu: return [kVK_Escape]
        }
    }

    /// Flèche d'une commande de direction (« ↑ »), à côté de sa touche.
    var arrow: String? {
        switch self {
        case .up, .stickUp, .cUp: "↑"
        case .down, .stickDown, .cDown: "↓"
        case .left, .stickLeft, .cLeft: "←"
        case .right, .stickRight, .cRight: "→"
        default: nil
        }
    }
}

/// Une ligne des réglages du clavier : un bouton de la console, ou les quatre directions d'une croix ou d'un stick.
struct KeyboardRow: Identifiable {
    let name: String
    let commands: [KeyCommand]

    var id: String { commands.map(\.rawValue).joined(separator: "-") }
    var isDirections: Bool { commands.count > 1 }
}

/// Touches du clavier propres à chaque console. Le Game Boy et la Game Boy Color partagent les leurs (mêmes
/// commandes) ; un jeu Wii joué avec la manette GameCube prend celles de la GameCube.
extension ControlScheme {
    /// Consoles présentes dans l'app, dans l'ordre de la bibliothèque (choix de la console dans Réglages › Clavier).
    static var keyboardSchemes: [ControlScheme] {
        var schemes: [ControlScheme] = []
        for system in GameSystem.displayOrder where EmulatorSession.engineInstalled(for: system) {
            if !schemes.contains(system.controls) { schemes.append(system.controls) }
        }
        return schemes
    }

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

    /// Nom du bouton que fait cette commande sur la console (« Stick droit → », « ✕ »), pour les messages.
    func keyboardLabel(for command: KeyCommand) -> String {
        if command == .menu { return tr("Menu pause") }
        guard let row = keyboardRows.first(where: { $0.commands.contains(command) }) else { return command.rawValue }
        guard row.isDirections, let arrow = command.arrow else { return row.name }
        return "\(row.name) \(arrow)"
    }

    /// Les commandes de la console, avec le nom de ses boutons. Les numéros RetroPad sont ceux des boutons tactiles
    /// (ControlLayout) : par position, comme une manette Xbox (N64, GameCube, Wii : A = bouton du bas).
    var keyboardRows: [KeyboardRow] {
        func button(_ name: String, _ command: KeyCommand) -> KeyboardRow { KeyboardRow(name: name, commands: [command]) }
        let dpad = KeyboardRow(name: tr("Croix"), commands: [.up, .down, .left, .right])
        let stickCommands: [KeyCommand] = [.stickUp, .stickDown, .stickLeft, .stickRight]
        let rightCommands: [KeyCommand] = [.cUp, .cDown, .cLeft, .cRight]
        let stick = KeyboardRow(name: tr("Stick"), commands: stickCommands)
        let leftStick = KeyboardRow(name: tr("Stick gauche"), commands: stickCommands)
        let rightStick = KeyboardRow(name: tr("Stick droit"), commands: rightCommands)
        let abxy = [button("A", .a), button("B", .b), button("X", .x), button("Y", .y)]
        let playStation = [button("✕", .b), button("○", .a), button("□", .y), button("△", .x)]
        let start = button("Start", .start)
        let select = button("Select", .select)
        switch self {
        case .nes, .gameBoy:
            return [dpad, button("A", .a), button("B", .b), start, select]
        case .snes, .nintendoDS:
            return [dpad] + abxy + [button("L", .l), button("R", .r), start, select]
        case .gameBoyAdvance:
            return [dpad, button("A", .a), button("B", .b), button("L", .l), button("R", .r), start, select]
        case .nintendo3DS:
            return [stick, dpad] + abxy
                + [button("L", .l), button("R", .r), button("ZL", .l2), button("ZR", .r2), start, select,
                   KeyboardRow(name: "C-Stick", commands: rightCommands)]
        case .nintendo64:
            return [stick, dpad, button("A", .b), button("B", .y), button("Z", .l2), button("L", .l), button("R", .r),
                    start, KeyboardRow(name: tr("Boutons C"), commands: rightCommands)]
        case .playStation:
            return [dpad] + playStation
                + [button("L1", .l), button("R1", .r), button("L2", .l2), button("R2", .r2), start, select]
        case .psp:
            return [stick, dpad] + playStation + [button("L", .l), button("R", .r), start, select]
        case .playStation2:
            return [leftStick, dpad] + playStation
                + [button("L1", .l), button("R1", .r), button("L2", .l2), button("R2", .r2), button("L3", .l3),
                   button("R3", .r3), start, select, rightStick]
        case .gameCube:
            return [stick, dpad, button("A", .b), button("B", .y), button("X", .a), button("Y", .x), button("Z", .r),
                    button("L", .l2), button("R", .r2), start, KeyboardRow(name: tr("Stick C"), commands: rightCommands)]
        case .wiimote:
            return [KeyboardRow(name: tr("Stick du Nunchuk"), commands: stickCommands), dpad,
                    button("A", .b), button("B", .a), button("1", .y), button("2", .x), button("−", .select),
                    button("+", .start), button("HOME", .r3), button(tr("C (Nunchuk)"), .l),
                    button(tr("Z (Nunchuk)"), .l2), button(tr("Secouer"), .r)]
#if PLAYTENDO_VITA
        case .psVita:
            return [leftStick, dpad] + playStation + [button("L", .l), button("R", .r), start, select, rightStick]
#endif
        }
    }

    /// Ce que fait la souris sur cette console, ou nil.
    var mouseNote: (action: String, effect: String)? {
        if isWiimote { return (tr("Viser, A, B"), tr("souris, clic, clic droit")) }
        if usesTouchScreen || isPSVita { return (tr("Écran tactile"), tr("clic")) }
        return nil
    }
}

/// Touches choisies pour chaque console, gardées dans les réglages de l'app : seules celles changées y sont écrites,
/// les autres restent celles d'origine. La touche du menu pause est commune à toutes les consoles et passe avant les
/// leurs (une touche qui la devient ne fait plus rien d'autre).
@MainActor
final class KeyBindings: ObservableObject {
    static let shared = KeyBindings()
    private static let storageKey = "touchesClavierConsoles"
    private static let menuStorageKey = "touchesClavierMenu"

    /// Touches changées : console (`ControlScheme.keyboardID`) → commande → touches.
    @Published private var changed: [String: [String: [Int]]]
    @Published private var menuKeys: [Int]

    /// État des touches avant un changement (pour l'annuler).
    struct Snapshot {
        fileprivate let changed: [String: [String: [Int]]]
        fileprivate let menuKeys: [Int]
    }

    private init() {
        let defaults = UserDefaults.standard
        changed = defaults.dictionary(forKey: Self.storageKey) as? [String: [String: [Int]]] ?? [:]
        menuKeys = defaults.array(forKey: Self.menuStorageKey) as? [Int] ?? KeyCommand.menu.defaultKeys(for: .nes)
        // Touches communes à toutes les consoles (avant le 2026-10-13) : remplacées par celles de chaque console.
        defaults.removeObject(forKey: "touchesClavierMac")
    }

    func keys(for command: KeyCommand, on scheme: ControlScheme) -> [Int] {
        if command == .menu { return menuKeys }
        let keys = changed[scheme.keyboardID]?[command.rawValue] ?? command.defaultKeys(for: scheme)
        return keys.filter { !menuKeys.contains($0) }
    }

    /// Commande de cette touche sur cette console, ou nil.
    func command(for keyCode: Int, on scheme: ControlScheme) -> KeyCommand? {
        if menuKeys.contains(keyCode) { return .menu }
        return scheme.keyboardRows.lazy.flatMap(\.commands).first { self.keys(for: $0, on: scheme).contains(keyCode) }
    }

    /// Touche du menu pause : elle ne peut être donnée à une autre commande (sans elle, on ne pourrait plus quitter
    /// une partie au clavier).
    func isMenuKey(_ keyCode: Int) -> Bool { menuKeys.contains(keyCode) }

    /// Donne `keyCode` à `command` sur cette console (à la place de ses touches) et la retire à ses autres commandes.
    /// Renvoie les commandes de la console qui l'avaient.
    @discardableResult
    func assign(_ keyCode: Int, to command: KeyCommand, on scheme: ControlScheme) -> [KeyCommand] {
        let others = scheme.keyboardRows.flatMap(\.commands).filter { $0 != command }
        let losers = others.filter { keys(for: $0, on: scheme).contains(keyCode) }
        if command == .menu {
            // Toutes les consoles : la touche du menu pause passe avant les leurs.
            menuKeys = [keyCode]
        } else {
            var table = changed[scheme.keyboardID] ?? [:]
            for other in losers {
                table[other.rawValue] = keys(for: other, on: scheme).filter { $0 != keyCode }
            }
            table[command.rawValue] = [keyCode]
            // Seules les touches différentes de celles d'origine sont gardées.
            changed[scheme.keyboardID] = table.filter { name, keys in
                KeyCommand(rawValue: name).map { keys != $0.defaultKeys(for: scheme) } ?? false
            }
        }
        save()
        return losers
    }

    func snapshot() -> Snapshot { Snapshot(changed: changed, menuKeys: menuKeys) }

    func restore(_ snapshot: Snapshot) {
        changed = snapshot.changed
        menuKeys = snapshot.menuKeys
        save()
    }

    /// Touches de cette console ou du menu pause changées.
    func isCustomized(_ scheme: ControlScheme) -> Bool {
        !(changed[scheme.keyboardID]?.isEmpty ?? true) || menuKeys != KeyCommand.menu.defaultKeys(for: scheme)
    }

    /// Touches d'origine pour cette console et le menu pause.
    func reset(_ scheme: ControlScheme) {
        changed[scheme.keyboardID] = nil
        menuKeys = KeyCommand.menu.defaultKeys(for: scheme)
        save()
    }

    func label(for command: KeyCommand, on scheme: ControlScheme) -> String {
        let codes = keys(for: command, on: scheme)
        return codes.isEmpty ? "—" : codes.map(KeyboardMap.label).joined(separator: " ")
    }

    private func save() {
        let defaults = UserDefaults.standard
        let kept = changed.filter { !$0.value.isEmpty }
        if kept.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else {
            defaults.set(kept, forKey: Self.storageKey)
        }
        if menuKeys == KeyCommand.menu.defaultKeys(for: .nes) {
            defaults.removeObject(forKey: Self.menuStorageKey)
        } else {
            defaults.set(menuKeys, forKey: Self.menuStorageKey)
        }
    }
}

enum KeyboardMap {
    enum Action: Hashable {
        case button(PTButton)
        /// Stick 0 (gauche) ou 1 (droit), direction.
        case stick(Int, CDirection)
        case menu
    }

    /// Touches de modification utilisables comme bouton (⌘ reste aux raccourcis du Mac, ⇪ et fn ne se tiennent pas),
    /// avec leur bit « côté gauche ou droit » dans les drapeaux de l'évènement.
    static let modifierKeys: [Int: UInt] = [
        kVK_Shift: 0x02, kVK_RightShift: 0x04,
        kVK_Control: 0x01, kVK_RightControl: 0x2000,
        kVK_Option: 0x20, kVK_RightOption: 0x40,
    ]

    @MainActor static func action(for keyCode: Int, scheme: ControlScheme) -> Action? {
        KeyBindings.shared.command(for: keyCode, on: scheme)?.action
    }

    /// Nom de la touche sur le clavier de l'utilisateur (« W » pour la touche Z d'un QWERTY sur un AZERTY).
    static func label(_ keyCode: Int) -> String {
        switch keyCode {
        case kVK_Return: return "↩"
        case kVK_ANSI_KeypadEnter: return tr("Entrée (pavé)")
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Tab: return "⇥"
        case kVK_Space: return tr("Espace")
        case kVK_Escape: return tr("Échap")
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_Shift: return tr("⇧ gauche")
        case kVK_RightShift: return tr("⇧ droite")
        case kVK_Control: return tr("⌃ gauche")
        case kVK_RightControl: return tr("⌃ droite")
        case kVK_Option: return tr("⌥ gauche")
        case kVK_RightOption: return tr("⌥ droite")
        default:
            if let number = functionKeys.firstIndex(of: keyCode) { return "F\(number + 1)" }
            let character = typedCharacter(keyCode)?.uppercased() ?? "?"
            return keypadKeys.contains(keyCode) ? tr("\(character) (pavé)") : character
        }
    }

    private static let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                       kVK_F11, kVK_F12]
    private static let keypadKeys: Set<Int> = [
        kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5,
        kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9, kVK_ANSI_KeypadDecimal,
        kVK_ANSI_KeypadPlus, kVK_ANSI_KeypadMinus, kVK_ANSI_KeypadMultiply, kVK_ANSI_KeypadDivide,
        kVK_ANSI_KeypadEquals, kVK_ANSI_KeypadClear,
    ]

    /// Caractère que tape cette touche avec la disposition de clavier choisie dans macOS.
    private static func typedCharacter(_ keyCode: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length,
                                  &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}

/// Calque invisible posé sur l'écran de jeu : lit le clavier (il prend le focus de la fenêtre) et la souris (écran
/// tactile de la DS et de la PS Vita, pointeur de la Wiimote).
final class MacInputView: NSView {
    var layout = ControlLayout()
    var scheme: ControlScheme = .nes
    var onButton: ((PTButton, Bool) -> Void)?
    var onAnalog: ((UInt32, CGFloat, CGFloat) -> Void)?
    var onPointer: ((CGPoint, Bool) -> Void)?
    var onMenu: (() -> Void)?
    /// Appelé à chaque touche du clavier (la manette n'est plus « en cours d'utilisation »).
    var onKeyboard: (() -> Void)?

    private var heldKeys: [UInt16: KeyboardMap.Action] = [:]
    private var pointerDown = false
    /// Wii : boutons tenus par la souris (clic = A, clic droit = B).
    private var mouseButtons: Set<PTButton> = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        NotificationCenter.default.removeObserver(self)
        if let window {
            // Fenêtre quittée (autre app, autre fenêtre) : les touches tenues ne reviendraient jamais.
            NotificationCenter.default.addObserver(self, selector: #selector(releaseAll),
                                                   name: NSWindow.didResignKeyNotification, object: window)
        }
    }

    override func resignFirstResponder() -> Bool {
        releaseAll()
        return super.resignFirstResponder()
    }

    // MARK: Clavier

    override func keyDown(with event: NSEvent) {
        // Raccourcis du Mac (⌘Q, ⌃⌘F…) : laissés aux menus. ⌃, ⌥ et ⇧ peuvent être des boutons (Réglages › Clavier).
        guard !event.modifierFlags.contains(.command) else {
            super.keyDown(with: event)
            return
        }
        guard let action = KeyboardMap.action(for: Int(event.keyCode), scheme: scheme) else { return }
        if event.isARepeat { return }
        onKeyboard?()
        // On joue au clavier : la flèche de la souris disparaît jusqu'à ce qu'elle bouge.
        NSCursor.setHiddenUntilMouseMoves(true)
        if action == .menu {
            onMenu?()
            return
        }
        heldKeys[event.keyCode] = action
        apply(action)
    }

    override func keyUp(with event: NSEvent) {
        guard let action = heldKeys.removeValue(forKey: event.keyCode) else { return }
        apply(action)
    }

    /// Touches de modification choisies comme boutons (au départ, Maj de droite = Select, comme dans RetroArch) :
    /// macOS ne les envoie qu'ici, enfoncées ou relâchées, chaque côté reconnu à son bit.
    override func flagsChanged(with event: NSEvent) {
        let keyCode = Int(event.keyCode)
        guard let side = KeyboardMap.modifierKeys[keyCode] else { return }
        let pressed = event.modifierFlags.rawValue & side != 0
        if pressed {
            guard heldKeys[event.keyCode] == nil, let action = KeyboardMap.action(for: keyCode, scheme: scheme) else { return }
            onKeyboard?()
            if action == .menu {
                onMenu?()
                return
            }
            heldKeys[event.keyCode] = action
            apply(action)
        } else if let action = heldKeys.removeValue(forKey: event.keyCode) {
            apply(action)
        }
    }

    /// Applique l'état d'une action d'après les touches tenues (deux touches peuvent faire le même bouton).
    private func apply(_ action: KeyboardMap.Action) {
        switch action {
        case .button(let button):
            onButton?(button, heldKeys.values.contains(.button(button)) || mouseButtons.contains(button))
        case .stick(let index, _):
            let held = Set(heldKeys.values)
            let x = (held.contains(.stick(index, .right)) ? 1.0 : 0) - (held.contains(.stick(index, .left)) ? 1.0 : 0)
            let y = (held.contains(.stick(index, .down)) ? 1.0 : 0) - (held.contains(.stick(index, .up)) ? 1.0 : 0)
            onAnalog?(UInt32(index), x, y)
        case .menu:
            break
        }
    }

    @objc func releaseAll() {
        let actions = Set(heldKeys.values)
        heldKeys.removeAll()
        actions.forEach(apply)
        for button in mouseButtons { onButton?(button, false) }
        mouseButtons.removeAll()
        if pointerDown {
            pointerDown = false
            onPointer?(.zero, false)
        }
    }

    // MARK: Souris

    /// Wii : la souris vise. PS Vita : comme la DS, un clic touche l'écran tactile (toute l'image).
    private var aimsWithMouse: Bool { scheme == .wiimote }

    /// Wii : la souris vise sans cliquer (le pointeur suit la flèche au-dessus de l'image).
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard aimsWithMouse else { return }
        let point = convert(event.locationInWindow, from: nil)
        if layout.touchScreen?.frame.contains(point) == true { sendPointer(point, pressed: false) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if aimsWithMouse {
            // Wiimote : clic = A (envoyé sur B, le bouton du bas, comme ses autres commandes).
            pressMouseButton(.b, true)
            sendPointer(point, pressed: false)
            return
        }
        guard let touchScreen = layout.touchScreen, touchScreen.frame.contains(point) else { return }
        pointerDown = true
        sendPointer(point, pressed: true)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if aimsWithMouse {
            sendPointer(point, pressed: false)
            return
        }
        guard pointerDown else { return }
        sendPointer(point, pressed: true)
    }

    override func mouseUp(with event: NSEvent) {
        if aimsWithMouse {
            pressMouseButton(.b, false)
            return
        }
        guard pointerDown else { return }
        pointerDown = false
        sendPointer(convert(event.locationInWindow, from: nil), pressed: false)
    }

    /// Wiimote : clic droit = B (la gâchette, envoyée sur A).
    override func rightMouseDown(with event: NSEvent) {
        guard aimsWithMouse else { return super.rightMouseDown(with: event) }
        pressMouseButton(.a, true)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard aimsWithMouse else { return super.rightMouseUp(with: event) }
        pressMouseButton(.a, false)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard aimsWithMouse else { return }
        sendPointer(convert(event.locationInWindow, from: nil), pressed: false)
    }

    private func pressMouseButton(_ button: PTButton, _ pressed: Bool) {
        if pressed {
            mouseButtons.insert(button)
        } else {
            mouseButtons.remove(button)
        }
        // Une touche du clavier peut tenir le même bouton.
        onButton?(button, pressed || heldKeys.values.contains(.button(button)))
    }

    /// Comme le doigt sur iPhone : la position reste dans l'écran tactile même si la souris en sort, puis elle est
    /// convertie dans l'image complète du jeu (les deux écrans empilés), que le moteur attend.
    private func sendPointer(_ point: CGPoint, pressed: Bool) {
        guard let touchScreen = layout.touchScreen, touchScreen.frame.width > 0, touchScreen.frame.height > 0 else { return }
        let frame = touchScreen.frame
        let u = min(max((point.x - frame.minX) / frame.width, 0), 0.999)
        let v = min(max((point.y - frame.minY) / frame.height, 0), 0.999)
        let source = touchScreen.source
        onPointer?(CGPoint(x: source.minX + u * source.width, y: source.minY + v * source.height), pressed)
    }
}

/// Pont SwiftUI → AppKit pour le calque clavier et souris.
struct MacInput: NSViewRepresentable {
    let layout: ControlLayout
    let scheme: ControlScheme
    let session: EmulatorSession
    let onMenu: () -> Void
    var onKeyboard: () -> Void = {}

    func makeNSView(context: Context) -> MacInputView {
        let view = MacInputView()
        view.onButton = { [session] button, pressed in session.setButton(button, pressed: pressed) }
        view.onAnalog = { [session] stick, x, y in session.setAnalog(stick: stick, x: Float(x), y: Float(y)) }
        view.onPointer = { [session] point, pressed in session.setPointer(x: point.x, y: point.y, pressed: pressed) }
        return view
    }

    func updateNSView(_ view: MacInputView, context: Context) {
        view.scheme = scheme
        view.layout = layout
        view.onMenu = onMenu
        view.onKeyboard = onKeyboard
        // Le clavier va au jeu, même si un champ de la bibliothèque (recherche) l'avait avant.
        DispatchQueue.main.async {
            if let window = view.window, window.firstResponder !== view { window.makeFirstResponder(view) }
        }
    }

    static func dismantleNSView(_ view: MacInputView, coordinator: ()) {
        view.releaseAll()
        NotificationCenter.default.removeObserver(view)
    }
}
#endif
