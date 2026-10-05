import GameController

/// Manettes Bluetooth (Xbox, PlayStation, MFi…). La disposition suit la position des
/// boutons : celui du bas = B, celui de droite = A, comme sur une manette Nintendo.
final class GamepadManager: ObservableObject {
    @Published private(set) var isConnected = false
    /// Vrai dès qu'on se sert de la manette ; les boutons tactiles se cachent alors.
    @Published private(set) var isActive = false

    var onButton: ((PTButton, Bool) -> Void)?
    var onAnalog: ((UInt32, Float, Float) -> Void)?
    var onMenu: (() -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var dpadState: Set<PTButton> = []
    private var stickState: Set<PTButton> = []
    private var directions: Set<PTButton> = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        })
        refresh()
        #if DEBUG
        // Tests dans le simulateur : un fichier Documents/PTGamepad simule une manette en cours d'utilisation.
        if FileManager.default.fileExists(atPath: Paths.documents.appendingPathComponent("PTGamepad").path) {
            isActive = true
        }
        #endif
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// L'écran a été touché : on réaffiche les boutons tactiles.
    func deactivate() {
        if isActive { isActive = false }
    }

    private func markActive() {
        if !isActive { isActive = true }
    }

    private func refresh() {
        let controller = GCController.controllers().first { $0.extendedGamepad != nil }
        isConnected = controller != nil
        if !isConnected { isActive = false }
        if let controller, let pad = controller.extendedGamepad {
            PTLogLine("Manette détectée : \(controller.vendorName ?? "sans nom")")
            bind(pad)
        }
    }

    private func bind(_ pad: GCExtendedGamepad) {
        func map(_ input: GCControllerButtonInput?, _ button: PTButton) {
            input?.pressedChangedHandler = { [weak self] _, _, pressed in
                if pressed { self?.markActive() }
                self?.onButton?(button, pressed)
            }
        }
        map(pad.buttonA, .b)
        map(pad.buttonB, .a)
        map(pad.buttonX, .y)
        map(pad.buttonY, .x)
        map(pad.leftShoulder, .l)
        map(pad.rightShoulder, .r)
        map(pad.leftTrigger, .l2)
        map(pad.rightTrigger, .r2)
        map(pad.leftThumbstickButton, .l3)
        map(pad.rightThumbstickButton, .r3)
        map(pad.buttonMenu, .start)
        map(pad.buttonOptions, .select)

        pad.dpad.valueChangedHandler = { [weak self] _, x, y in
            if x != 0 || y != 0 { self?.markActive() }
            self?.dpadState = Self.directions(x: x, y: y, threshold: 0.5)
            self?.updateDirections()
        }
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            if abs(x) > 0.5 || abs(y) > 0.5 { self?.markActive() }
            self?.onAnalog?(0, x, -y)
            self?.stickState = Self.directions(x: x, y: y, threshold: 0.5)
            self?.updateDirections()
        }
        pad.rightThumbstick.valueChangedHandler = { [weak self] _, x, y in
            self?.onAnalog?(1, x, -y)
        }
        if let home = pad.buttonHome {
            home.preferredSystemGestureState = .disabled
            home.pressedChangedHandler = { [weak self] _, _, pressed in
                if pressed { self?.onMenu?() }
            }
        }
    }

    private static func directions(x: Float, y: Float, threshold: Float) -> Set<PTButton> {
        var result = Set<PTButton>()
        if x > threshold { result.insert(.right) }
        if x < -threshold { result.insert(.left) }
        if y > threshold { result.insert(.up) }
        if y < -threshold { result.insert(.down) }
        return result
    }

    private func updateDirections() {
        let now = dpadState.union(stickState)
        for button in directions.subtracting(now) { onButton?(button, false) }
        for button in now.subtracting(directions) { onButton?(button, true) }
        directions = now
    }
}
