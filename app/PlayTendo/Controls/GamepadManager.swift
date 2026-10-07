import GameController

/// Manettes Bluetooth (Xbox, PlayStation, Switch, MFi…). La disposition suit la position des
/// boutons : celui du bas = B, celui de droite = A, comme sur une manette Nintendo.
final class GamepadManager: ObservableObject {
    @Published private(set) var isConnected = false
    /// Vrai dès qu'on se sert de la manette ; les boutons tactiles se cachent alors.
    @Published private(set) var isActive = false

    var onButton: ((PTButton, Bool) -> Void)?
    var onAnalog: ((UInt32, Float, Float) -> Void)?
    var onMenu: (() -> Void)?
    /// Le stick gauche appuie aussi sur la croix (consoles sans stick analogique).
    var stickMovesDPad = true

    private var observers: [NSObjectProtocol] = []
    /// Boutons enfoncés en ce moment (hors directions), à relâcher si la manette disparaît.
    private var heldButtons: Set<PTButton> = []
    private var dpadState: Set<PTButton> = []
    private var stickState: Set<PTButton> = []
    private var directions: Set<PTButton> = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            // Sans cela, un bouton tenu au moment de la déconnexion resterait enfoncé dans le jeu.
            self?.releaseAll()
            self?.refresh()
        })
        refresh()
        #if DEBUG
        // Tests dans le simulateur : un fichier Documents/PTGamepad simule une manette en cours d'utilisation.
        if FileManager.default.fileExists(atPath: Paths.documents.appendingPathComponent("PTGamepad").path) {
            isConnected = true
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
        #if DEBUG
        // Tests dans le simulateur : il annonce toujours une manette virtuelle « Gamepad ». Un fichier
        // Documents/PTSansManette la fait ignorer, pour voir l'app comme sur un iPhone sans manette.
        if FileManager.default.fileExists(atPath: Paths.documents.appendingPathComponent("PTSansManette").path) {
            isConnected = false
            isActive = false
            return
        }
        #endif
        let controller = GCController.controllers().first { $0.extendedGamepad != nil }
        isConnected = controller != nil
        if !isConnected { isActive = false }
        if let controller, let pad = controller.extendedGamepad {
            let nintendo = Self.reportsNintendoLabels(controller)
            PTLogLine("Manette détectée : \(controller.vendorName ?? "sans nom") (\(controller.productCategory))"
                      + (nintendo ? ", boutons Nintendo remis par position" : ""))
            bind(pad, nintendoLabels: nintendo)
        }
    }

    /// Manettes Nintendo (Switch Pro, Joy-Con, manettes Switch Online) : iOS donne leurs boutons par lettre (`buttonA` =
    /// le A, à droite), alors que pour les autres `buttonA` est le bouton du bas.
    private static func reportsNintendoLabels(_ controller: GCController) -> Bool {
        let names = controller.productCategory + " " + (controller.vendorName ?? "")
        return ["Switch", "Joy-Con", "Nintendo"].contains { names.localizedCaseInsensitiveContains($0) }
    }

    private func bind(_ pad: GCExtendedGamepad, nintendoLabels: Bool) {
        func map(_ input: GCControllerButtonInput?, _ button: PTButton) {
            input?.pressedChangedHandler = { [weak self] _, _, pressed in
                guard let self else { return }
                if pressed {
                    markActive()
                    heldButtons.insert(button)
                } else {
                    heldButtons.remove(button)
                }
                onButton?(button, pressed)
            }
        }
        // Bouton du bas → B, de droite → A, de gauche → Y, du haut → X (PlayStation : croix, rond, carré, triangle).
        if nintendoLabels {
            map(pad.buttonB, .b)
            map(pad.buttonA, .a)
            map(pad.buttonY, .y)
            map(pad.buttonX, .x)
        } else {
            map(pad.buttonA, .b)
            map(pad.buttonB, .a)
            map(pad.buttonX, .y)
            map(pad.buttonY, .x)
        }
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
            guard let self else { return }
            self.stickState = self.stickMovesDPad ? Self.directions(x: x, y: y, threshold: 0.5) : []
            self.updateDirections()
        }
        pad.rightThumbstick.valueChangedHandler = { [weak self] _, x, y in
            if abs(x) > 0.5 || abs(y) > 0.5 { self?.markActive() }
            self?.onAnalog?(1, x, -y)
        }
        if let home = pad.buttonHome {
            home.preferredSystemGestureState = .disabled
            home.pressedChangedHandler = { [weak self] _, _, pressed in
                if pressed { self?.onMenu?() }
            }
        }
    }

    /// Relâche tout ce que la manette tenait : boutons, directions et sticks.
    private func releaseAll() {
        for button in heldButtons { onButton?(button, false) }
        heldButtons.removeAll()
        dpadState.removeAll()
        stickState.removeAll()
        updateDirections()
        onAnalog?(0, 0, 0)
        onAnalog?(1, 0, 0)
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
