import CoreHaptics
import GameController

/// Vibrations de la manette (Réglages) : activées par défaut.
enum RumbleSettings {
    static let key = "vibrationsManette"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}

/// Manettes Bluetooth (Xbox, PlayStation, Switch, MFi…). La disposition suit la position des
/// boutons : celui du bas = B, celui de droite = A, comme sur une manette Nintendo. Sauf une manette Nintendo sur
/// GameCube, Wii et N64 : chaque bouton y fait sa lettre (`nintendoLetters`).
final class GamepadManager: ObservableObject {
    @Published private(set) var isConnected = false
    /// Vrai dès qu'on se sert de la manette ; les boutons tactiles se cachent alors.
    @Published private(set) var isActive = false
    /// La manette branchée est une manette Nintendo (Switch Pro, Joy-Con).
    @Published private(set) var isNintendoPad = false

    var onButton: ((PTButton, Bool) -> Void)?
    var onAnalog: ((UInt32, Float, Float) -> Void)?
    var onMenu: (() -> Void)?
    /// Le stick gauche appuie aussi sur la croix (consoles sans stick analogique).
    var stickMovesDPad = true
    /// Boutons de l'app faits par les A, B, X, Y d'une manette Nintendo, selon la console
    /// (`ControlScheme.nintendoLetters`).
    var nintendoLetters = NintendoLetters.samePlace {
        didSet {
            // Seule une manette Nintendo est concernée : elle est rebranchée avec les nouveaux boutons.
            guard nintendoLetters != oldValue, let controller = Self.currentController,
                  Self.reportsNintendoLabels(controller) else { return }
            releaseAll()
            refresh()
        }
    }

    /// Touches changées pour la console en cours (menu pause › Commandes › Touches de la manette).
    var mapping = GamepadMapping() {
        didSet {
            guard mapping != oldValue else { return }
            releaseAll()
            refresh()
        }
    }

    private var observers: [NSObjectProtocol] = []
    /// Vibrations : moteur de vibrations de la manette et lecteur d'une vibration continue dont on règle la force
    /// (tout sur `hapticQueue`).
    private let hapticQueue = DispatchQueue(label: "PlayTendo.vibrations")
    private var hapticController: GCController?
    private var hapticEngine: CHHapticEngine?
    private var hapticPlayer: CHHapticAdvancedPatternPlayer?
    private var hapticPlaying = false
    private var hapticIntensity: Float = 0
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
        let controller = Self.currentController
        isConnected = controller != nil
        isNintendoPad = controller.map(Self.reportsNintendoLabels) ?? false
        hapticQueue.async { [weak self] in
            guard let self, hapticController !== controller else { return }
            stopHaptics()
            hapticController = controller
        }
        if !isConnected { isActive = false }
        if let controller, let pad = controller.extendedGamepad {
            let nintendo = Self.reportsNintendoLabels(controller)
            let layout = nintendoLetters == .samePlace ? "remis par position" : "chacun fait sa lettre"
            PTLogLine("Manette détectée : \(controller.vendorName ?? "sans nom") (\(controller.productCategory))"
                      + (nintendo ? ", boutons Nintendo \(layout)" : ""))
            bind(pad, nintendoLabels: nintendo)
        }
    }

    private static var currentController: GCController? {
        GCController.controllers().first { $0.extendedGamepad != nil }
    }

    /// Manettes Nintendo (Switch Pro, Joy-Con, manettes Switch Online) : iOS donne leurs boutons par lettre (`buttonA` =
    /// le A, à droite), alors que pour les autres `buttonA` est le bouton du bas.
    private static func reportsNintendoLabels(_ controller: GCController) -> Bool {
        let names = controller.productCategory + " " + (controller.vendorName ?? "")
        return ["Switch", "Joy-Con", "Nintendo"].contains { names.localizedCaseInsensitiveContains($0) }
    }

    private func bind(_ pad: GCExtendedGamepad, nintendoLabels: Bool) {
        // Chaque bouton fait celui choisi pour la console, sinon celui d'origine ; « Rien » : il ne fait plus rien.
        func map(_ input: GCControllerButtonInput?, _ place: GamepadInput) {
            guard let button = mapping.button(for: place, default: place.defaultButton(letters: nintendoLetters,
                                                                                       nintendoPad: nintendoLabels)) else {
                input?.pressedChangedHandler = nil
                return
            }
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
        // Par défaut, bouton du bas → B, de droite → A, de gauche → Y, du haut → X (PlayStation : croix, rond, carré,
        // triangle). iOS donne les boutons d'une manette Nintendo par lettre (A à droite) : remis à leur place.
        if nintendoLabels {
            map(pad.buttonA, .east)
            map(pad.buttonB, .south)
            map(pad.buttonX, .north)
            map(pad.buttonY, .west)
        } else {
            map(pad.buttonA, .south)
            map(pad.buttonB, .east)
            map(pad.buttonX, .west)
            map(pad.buttonY, .north)
        }
        map(pad.leftShoulder, .l1)
        map(pad.rightShoulder, .r1)
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

    // MARK: Vibrations

    /// Pendant une partie : les vibrations des moteurs (PTRumble) font vibrer la manette (joueur 1).
    func listenToRumble() {
        PTRumbleSetHandler { [weak self] port, strong, weak in
            guard port == 0 else { return }
            self?.rumble(strong: strong, weak: weak)
        }
    }

    /// Menu pause : la vibration en cours s'arrête (le jeu ne la coupera pas lui-même).
    func stopRumble() {
        rumble(strong: 0, weak: 0)
    }

    /// Fin de partie : plus de vibrations.
    func stopListeningToRumble() {
        PTRumbleSetHandler(nil)
        stopRumble()
    }

    private func rumble(strong: Float, weak: Float) {
        // Une seule vibration par manette : le gros moteur, ou le petit un peu moins fort.
        let intensity = min(1, max(strong, weak * 0.7))
        hapticQueue.async { [weak self] in self?.applyRumble(intensity) }
    }

    /// Règle la force de la vibration (fil `hapticQueue`) ; arrêtée sous 2 %.
    private func applyRumble(_ intensity: Float) {
        let on = intensity > 0.02 && RumbleSettings.enabled
        guard on != hapticPlaying || (on && abs(intensity - hapticIntensity) > 0.03) else { return }
        hapticIntensity = intensity
        guard on else {
            try? hapticPlayer?.stop(atTime: CHHapticTimeImmediate)
            hapticPlaying = false
            return
        }
        do {
            if hapticPlayer == nil {
                guard let engine = hapticController?.haptics?.createEngine(withLocality: .default) else { return }
                engine.playsHapticsOnly = true
                engine.stoppedHandler = { [weak self] _ in
                    self?.hapticQueue.async { self?.forgetHaptics() }
                }
                engine.resetHandler = { [weak self] in
                    self?.hapticQueue.async { self?.forgetHaptics() }
                }
                try engine.start()
                let event = CHHapticEvent(eventType: .hapticContinuous,
                                          parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                                                       CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3)],
                                          relativeTime: 0, duration: 30)
                let player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
                player.loopEnabled = true
                hapticEngine = engine
                hapticPlayer = player
            }
            try hapticPlayer?.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
                                                                       value: intensity, relativeTime: 0)],
                                             atTime: CHHapticTimeImmediate)
            if !hapticPlaying {
                try hapticPlayer?.start(atTime: CHHapticTimeImmediate)
                hapticPlaying = true
            }
        } catch {
            PTLogLine("Vibrations de la manette impossibles : \(error.localizedDescription)")
            stopHaptics()
        }
    }

    /// Arrête et oublie le moteur de vibrations (manette changée, erreur) — fil `hapticQueue`.
    private func stopHaptics() {
        try? hapticPlayer?.stop(atTime: CHHapticTimeImmediate)
        hapticEngine?.stop()
        forgetHaptics()
    }

    private func forgetHaptics() {
        hapticPlayer = nil
        hapticEngine = nil
        hapticPlaying = false
        hapticIntensity = 0
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
