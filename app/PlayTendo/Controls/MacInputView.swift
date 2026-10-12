// Commandes sur Mac : clavier et souris (l'écran tactile de la DS se touche en cliquant). Les manettes passent par
// GamepadManager, comme sur iPhone.
#if os(macOS)
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Touches du clavier, par position (même place sur un clavier AZERTY et QWERTY : la touche « A » d'un QWERTY est
/// le « Q » d'un AZERTY). Disposition classique des émulateurs (RetroArch).
enum KeyboardMap {
    enum Action: Hashable {
        case button(PTButton)
        /// Stick 0 (gauche) ou 1 (droit), direction.
        case stick(Int, CDirection)
        case menu
    }

    /// Touches des boutons, communes à toutes les consoles.
    static let buttons: [(keyCode: Int, button: PTButton)] = [
        (kVK_ANSI_X, .a), (kVK_ANSI_Z, .b), (kVK_ANSI_S, .x), (kVK_ANSI_A, .y),
        (kVK_ANSI_Q, .l), (kVK_ANSI_W, .r), (kVK_ANSI_E, .l2), (kVK_ANSI_R, .r2),
        (kVK_Return, .start), (kVK_ANSI_KeypadEnter, .start), (kVK_Delete, .select),
        // R3 : HOME de la Wiimote.
        (kVK_Tab, .r3),
    ]

    /// Flèches : la croix ; pour les consoles à stick, le stick gauche (la croix passe alors sur T F G H).
    private static let arrows: [(Int, CDirection)] = [
        (kVK_UpArrow, .up), (kVK_DownArrow, .down), (kVK_LeftArrow, .left), (kVK_RightArrow, .right),
    ]
    private static let dpadKeys: [(Int, CDirection)] = [
        (kVK_ANSI_T, .up), (kVK_ANSI_G, .down), (kVK_ANSI_F, .left), (kVK_ANSI_H, .right),
    ]
    private static let rightStickKeys: [(Int, CDirection)] = [
        (kVK_ANSI_I, .up), (kVK_ANSI_K, .down), (kVK_ANSI_J, .left), (kVK_ANSI_L, .right),
    ]

    static func action(for keyCode: Int, scheme: ControlScheme) -> Action? {
        if keyCode == kVK_Escape { return .menu }
        if let entry = buttons.first(where: { $0.keyCode == keyCode }) { return .button(entry.button) }
        if scheme.hasAnalogStick {
            if let (_, direction) = arrows.first(where: { $0.0 == keyCode }) { return .stick(0, direction) }
            if let (_, direction) = dpadKeys.first(where: { $0.0 == keyCode }) { return .button(direction.button) }
            if let (_, direction) = rightStickKeys.first(where: { $0.0 == keyCode }) { return .stick(1, direction) }
            return nil
        }
        if let (_, direction) = arrows.first(where: { $0.0 == keyCode }) { return .button(direction.button) }
        return nil
    }

    /// Nom de la touche sur le clavier de l'utilisateur (« W » pour la touche Z d'un QWERTY sur un AZERTY).
    static func label(_ keyCode: Int) -> String {
        switch keyCode {
        case kVK_Return, kVK_ANSI_KeypadEnter: return "↩"
        case kVK_Delete: return "⌫"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return tr("Échap")
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        default: return typedCharacter(keyCode)?.uppercased() ?? "?"
        }
    }

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

    /// Touches affichées dans les Réglages : (ce que fait la touche, touches).
    static var legend: [(String, String)] {
        func keys(_ button: PTButton) -> String {
            buttons.filter { $0.button == button }.map { label($0.keyCode) }.joined(separator: " ")
        }
        func directions(_ list: [(Int, CDirection)]) -> String { list.map { label($0.0) }.joined(separator: " ") }
        return [
            (tr("Croix"), "← ↑ → ↓"),
            ("A", keys(.a)), ("B", keys(.b)), ("X", keys(.x)), ("Y", keys(.y)),
            ("L", keys(.l)), ("R", keys(.r)), ("L2 / ZL", keys(.l2)), ("R2 / ZR", keys(.r2)),
            ("Start", keys(.start)), ("Select", keys(.select)),
            (tr("Stick gauche (N64, PSP)"), "← ↑ → ↓"),
            (tr("Croix (N64, PSP)"), directions(dpadKeys)),
            (tr("Boutons C (N64)"), directions(rightStickKeys)),
            (tr("A, B, Z (N64)"), [keys(.b), keys(.y), keys(.l2)].joined(separator: " ")),
            (tr("A, B, X, Y (GameCube)"), [keys(.b), keys(.y), keys(.a), keys(.x)].joined(separator: " ")),
            (tr("Z, L, R (GameCube)"), [keys(.r), keys(.l2), keys(.r2)].joined(separator: " ")),
            (tr("Viser, A, B (Wii)"), tr("souris, clic, clic droit")),
            (tr("1, 2, secouer (Wii)"), [keys(.y), keys(.x), keys(.r)].joined(separator: " ")),
            (tr("C, Z du Nunchuk, HOME (Wii)"), [keys(.l), keys(.l2), keys(.r3)].joined(separator: " ")),
            (tr("Menu pause"), label(kVK_Escape)),
            (tr("Écran tactile (DS)"), tr("clic")),
        ]
    }
}

private extension CDirection {
    var button: PTButton {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        }
    }
}

/// Calque invisible posé sur l'écran de jeu : lit le clavier (il prend le focus de la fenêtre) et la souris (écran
/// tactile de la DS, pointeur de la Wiimote).
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
        // Raccourcis du Mac (⌘Q, ⌃⌘F…) : laissés aux menus.
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
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

    /// Maj de droite : Select (comme dans RetroArch).
    override func flagsChanged(with event: NSEvent) {
        guard Int(event.keyCode) == kVK_RightShift else { return }
        let pressed = event.modifierFlags.contains(.shift)
        if pressed {
            heldKeys[event.keyCode] = .button(.select)
            onKeyboard?()
        } else {
            heldKeys[event.keyCode] = nil
        }
        onButton?(.select, pressed)
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

    /// Wii : la souris vise sans cliquer (le pointeur suit la flèche au-dessus de l'image).
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard scheme.usesPointer else { return }
        let point = convert(event.locationInWindow, from: nil)
        if layout.touchScreen?.frame.contains(point) == true { sendPointer(point, pressed: false) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if scheme.usesPointer {
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
        if scheme.usesPointer {
            sendPointer(point, pressed: false)
            return
        }
        guard pointerDown else { return }
        sendPointer(point, pressed: true)
    }

    override func mouseUp(with event: NSEvent) {
        if scheme.usesPointer {
            pressMouseButton(.b, false)
            return
        }
        guard pointerDown else { return }
        pointerDown = false
        sendPointer(convert(event.locationInWindow, from: nil), pressed: false)
    }

    /// Wiimote : clic droit = B (la gâchette, envoyée sur A).
    override func rightMouseDown(with event: NSEvent) {
        guard scheme.usesPointer else { return super.rightMouseDown(with: event) }
        pressMouseButton(.a, true)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard scheme.usesPointer else { return super.rightMouseUp(with: event) }
        pressMouseButton(.a, false)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard scheme.usesPointer else { return }
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
