// Commandes sur Mac : clavier et souris (l'écran tactile de la DS se touche en cliquant). Les manettes passent par
// GamepadManager, comme sur iPhone.
#if os(macOS)
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Ce qu'une touche du clavier fait en jeu. Chaque commande a ses touches, changeables dans Réglages › Clavier.
enum KeyCommand: String, CaseIterable, Identifiable {
    case a, b, x, y, l, r, l2, r2, start, select, home
    /// Croix des consoles sans stick.
    case up, down, left, right
    /// Consoles à stick : stick gauche, croix et stick droit (boutons C de la N64, C-Stick de la GameCube et de la 3DS).
    case stickUp, stickDown, stickLeft, stickRight
    case padUp, padDown, padLeft, padRight
    case cUp, cDown, cLeft, cRight
    case menu

    var id: String { rawValue }

    /// Consoles où la commande agit : la même touche peut servir à la croix des consoles sans stick et au stick des
    /// autres (les flèches, au départ).
    private enum Scope { case all, withoutStick, withStick }

    private var scope: Scope {
        switch self {
        case .up, .down, .left, .right: .withoutStick
        case .stickUp, .stickDown, .stickLeft, .stickRight, .padUp, .padDown, .padLeft, .padRight,
             .cUp, .cDown, .cLeft, .cRight: .withStick
        default: .all
        }
    }

    /// Deux commandes qui peuvent agir dans la même partie ne partagent pas une touche.
    func sharesConsoles(with other: KeyCommand) -> Bool {
        scope == .all || other.scope == .all || scope == other.scope
    }

    func isActive(for scheme: ControlScheme) -> Bool {
        switch scope {
        case .all: true
        case .withoutStick: !scheme.hasAnalogStick
        case .withStick: scheme.hasAnalogStick
        }
    }

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
        case .start: .button(.start)
        case .select: .button(.select)
        // R3 : HOME de la Wiimote.
        case .home: .button(.r3)
        case .up, .padUp: .button(.up)
        case .down, .padDown: .button(.down)
        case .left, .padLeft: .button(.left)
        case .right, .padRight: .button(.right)
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

    /// Touches d'origine, par position (même place sur un clavier AZERTY et QWERTY : la touche « A » d'un QWERTY est
    /// le « Q » d'un AZERTY). Disposition classique des émulateurs (RetroArch).
    var defaultKeys: [Int] {
        switch self {
        case .a: [kVK_ANSI_X]
        case .b: [kVK_ANSI_Z]
        case .x: [kVK_ANSI_S]
        case .y: [kVK_ANSI_A]
        case .l: [kVK_ANSI_Q]
        case .r: [kVK_ANSI_W]
        case .l2: [kVK_ANSI_E]
        case .r2: [kVK_ANSI_R]
        case .start: [kVK_Return, kVK_ANSI_KeypadEnter]
        // Maj de droite aussi, comme dans RetroArch.
        case .select: [kVK_Delete, kVK_RightShift]
        case .home: [kVK_Tab]
        // Flèches : la croix ; pour les consoles à stick, le stick gauche (la croix passe alors sur T F G H).
        case .up, .stickUp: [kVK_UpArrow]
        case .down, .stickDown: [kVK_DownArrow]
        case .left, .stickLeft: [kVK_LeftArrow]
        case .right, .stickRight: [kVK_RightArrow]
        case .padUp: [kVK_ANSI_T]
        case .padDown: [kVK_ANSI_G]
        case .padLeft: [kVK_ANSI_F]
        case .padRight: [kVK_ANSI_H]
        case .cUp: [kVK_ANSI_I]
        case .cDown: [kVK_ANSI_K]
        case .cLeft: [kVK_ANSI_J]
        case .cRight: [kVK_ANSI_L]
        case .menu: [kVK_Escape]
        }
    }

    /// Flèche d'une commande de direction (« ↑ »), pour les Réglages.
    var arrow: String? {
        switch self {
        case .up, .stickUp, .padUp, .cUp: "↑"
        case .down, .stickDown, .padDown, .cDown: "↓"
        case .left, .stickLeft, .padLeft, .cLeft: "←"
        case .right, .stickRight, .padRight, .cRight: "→"
        default: nil
        }
    }
}

/// Touches choisies pour chaque commande (Réglages › Clavier), gardées dans les réglages de l'app. Seules les
/// commandes changées y sont écrites : les autres gardent leurs touches d'origine.
@MainActor
final class KeyBindings: ObservableObject {
    static let shared = KeyBindings()
    private static let storageKey = "touchesClavierMac"

    @Published private(set) var keys: [KeyCommand: [Int]]

    private init() {
        var keys = Dictionary(uniqueKeysWithValues: KeyCommand.allCases.map { ($0, $0.defaultKeys) })
        if let saved = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: [Int]] {
            for (name, codes) in saved {
                if let command = KeyCommand(rawValue: name) { keys[command] = codes }
            }
        }
        self.keys = keys
    }

    var isCustomized: Bool { KeyCommand.allCases.contains { keys[$0] != $0.defaultKeys } }

    /// Commande de cette touche pour la console en cours, ou nil.
    func command(for keyCode: Int, scheme: ControlScheme) -> KeyCommand? {
        KeyCommand.allCases.first { $0.isActive(for: scheme) && keys[$0, default: []].contains(keyCode) }
    }

    /// Commande qui garde cette touche quelle que soit celle qu'on change : le menu pause (sans touche, on ne
    /// pourrait plus quitter une partie au clavier).
    func isMenuKey(_ keyCode: Int) -> Bool { keys[.menu, default: []].contains(keyCode) }

    /// Donne `keyCode` à `command` (à la place de ses touches), et la retire aux commandes qui agissent dans les mêmes
    /// parties.
    func assign(_ keyCode: Int, to command: KeyCommand) {
        for other in KeyCommand.allCases where other != command && other.sharesConsoles(with: command) {
            keys[other]?.removeAll { $0 == keyCode }
        }
        keys[command] = [keyCode]
        save()
    }

    func resetAll() {
        keys = Dictionary(uniqueKeysWithValues: KeyCommand.allCases.map { ($0, $0.defaultKeys) })
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    func label(for command: KeyCommand) -> String {
        let codes = keys[command, default: []]
        return codes.isEmpty ? "—" : codes.map(KeyboardMap.label).joined(separator: " ")
    }

    private func save() {
        var changed: [String: [Int]] = [:]
        for command in KeyCommand.allCases where keys[command] != command.defaultKeys {
            changed[command.rawValue] = keys[command] ?? []
        }
        UserDefaults.standard.set(changed, forKey: Self.storageKey)
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
        KeyBindings.shared.command(for: keyCode, scheme: scheme)?.action
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

    /// Ce que font les boutons sur les consoles où ils changent de nom (Réglages › Clavier), d'après les touches
    /// choisies.
    @MainActor static var consoleNotes: [(String, String)] {
        let bindings = KeyBindings.shared
        func keys(_ commands: KeyCommand...) -> String { commands.map(bindings.label).joined(separator: "  ") }
#if PLAYTENDO_VITA
        let touchScreens = tr("Écran tactile (DS, 3DS, PS Vita)")
#else
        let touchScreens = tr("Écran tactile (DS, 3DS)")
#endif
        return [
            (tr("A, B, Z (N64)"), keys(.b, .y, .l2)),
            (tr("A, B, X, Y (GameCube)"), keys(.b, .y, .a, .x)),
            (tr("Z, L, R (GameCube)"), keys(.r, .l2, .r2)),
            (tr("Viser, A, B (Wii)"), tr("souris, clic, clic droit")),
            (tr("1, 2, secouer (Wii)"), keys(.y, .x, .r)),
            (tr("C, Z du Nunchuk, HOME (Wii)"), keys(.l, .l2, .home)),
            (touchScreens, tr("clic")),
        ]
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
