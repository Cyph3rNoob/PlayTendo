import CoreHaptics
import GameController

/// Vibrations de la manette (Réglages) : activées par défaut.
enum RumbleSettings {
    static let key = "vibrationsManette"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}

/// Manettes Bluetooth (Xbox, PlayStation, Switch, MFi…), deux au plus : la première branchée est le joueur 1, la
/// deuxième le joueur 2 (consoles de salon ; sur une console portable, elle joue aussi le joueur 1). La disposition
/// suit la position des boutons : celui du bas = B, celui de droite = A, comme sur une manette Nintendo. Sauf une
/// manette Nintendo sur GameCube, Wii et N64 : chaque bouton y fait sa lettre (`nintendoLetters`).
final class GamepadManager: ObservableObject {
    @Published private(set) var isConnected = false
    /// Vrai dès qu'on se sert de la manette du joueur 1 ; les boutons tactiles se cachent alors.
    @Published private(set) var isActive = false
    /// La manette du joueur 1 est une manette Nintendo (Switch Pro, Joy-Con).
    @Published private(set) var isNintendoPad = false
    /// Une deuxième manette est branchée.
    @Published private(set) var hasSecondController = false

    /// Bouton RetroPad d'un joueur (0 ou 1), enfoncé ou relâché.
    var onButton: ((Int, PTButton, Bool) -> Void)?
    /// Stick (0 gauche, 1 droit) d'un joueur.
    var onAnalog: ((Int, UInt32, Float, Float) -> Void)?
    var onMenu: (() -> Void)?
    /// Le stick gauche appuie aussi sur la croix (consoles sans stick analogique).
    var stickMovesDPad = true
    /// Boutons de l'app faits par les A, B, X, Y d'une manette Nintendo, selon la console
    /// (`ControlScheme.nintendoLetters`).
    var nintendoLetters = NintendoLetters.samePlace {
        didSet { if nintendoLetters != oldValue { rebind() } }
    }

    /// Touches changées pour la console en cours (menu pause › Commandes › Touches de la manette).
    var mapping = GamepadMapping() {
        didSet { if mapping != oldValue { rebind() } }
    }

    /// La deuxième manette joue le joueur 2 (consoles de salon) ; sinon elle joue aussi le joueur 1.
    var secondControllerIsPlayer2 = true {
        didSet { if secondControllerIsPlayer2 != oldValue { rebind() } }
    }

    private var observers: [NSObjectProtocol] = []
    /// Manettes dans l'ordre où elles ont été branchées (les deux premières jouent).
    private var ordered: [GCController] = []
    /// Joueur de chaque manette qui joue (0 ou 1), dans l'ordre de `ordered`.
    private var slotPlayers: [Int] = []
    /// Ce que chaque manette tient (boutons, directions), à relâcher si elle disparaît.
    private var states = [PadState(), PadState()]

    private struct PadState {
        var held: Set<PTButton> = []
        var dpad: Set<PTButton> = []
        var stick: Set<PTButton> = []
        var directions: Set<PTButton> = []
    }

    /// Vibrations : une par manette qui joue, réglées sur `hapticQueue`.
    private let hapticQueue = DispatchQueue(label: "PlayTendo.vibrations")
    private var haptics: [PadHaptics] = []

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

    private func rebind() {
        releaseAll()
        refresh()
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
        let available = GCController.controllers().filter { $0.extendedGamepad != nil }
        ordered = ordered.filter { old in available.contains { $0 === old } }
            + available.filter { new in !ordered.contains { $0 === new } }
        let playing = Array(ordered.prefix(2))
        isConnected = !playing.isEmpty
        if !isConnected { isActive = false }
        isNintendoPad = playing.first.map(Self.reportsNintendoLabels) ?? false
        if hasSecondController != (playing.count > 1) { hasSecondController = playing.count > 1 }
        slotPlayers = playing.indices.map { $0 == 0 || !secondControllerIsPlayer2 ? 0 : 1 }
        for (slot, controller) in playing.enumerated() {
            guard let pad = controller.extendedGamepad else { continue }
            let player = slotPlayers[slot]
            let nintendo = Self.reportsNintendoLabels(controller)
            controller.playerIndex = player == 0 ? .index1 : .index2
            let layout = nintendoLetters == .samePlace ? "remis par position" : "chacun fait sa lettre"
            PTLogLine("Manette \(slot + 1) (joueur \(player + 1)) : \(controller.vendorName ?? "sans nom") "
                      + "(\(controller.productCategory))" + (nintendo ? ", boutons Nintendo \(layout)" : ""))
            bind(pad, slot: slot, player: player, nintendoLabels: nintendo)
        }
        // Une troisième manette ne fait rien.
        for controller in ordered.dropFirst(2) {
            if let pad = controller.extendedGamepad { unbind(pad) }
            controller.playerIndex = .indexUnset
        }
        let players = slotPlayers
        hapticQueue.async { [weak self] in self?.updateHaptics(playing, players: players) }
    }

    /// Manettes Nintendo (Switch Pro, Joy-Con, manettes Switch Online) : iOS donne leurs boutons par lettre (`buttonA` =
    /// le A, à droite), alors que pour les autres `buttonA` est le bouton du bas.
    private static func reportsNintendoLabels(_ controller: GCController) -> Bool {
        let names = controller.productCategory + " " + (controller.vendorName ?? "")
        return ["Switch", "Joy-Con", "Nintendo"].contains { names.localizedCaseInsensitiveContains($0) }
    }

    private func bind(_ pad: GCExtendedGamepad, slot: Int, player: Int, nintendoLabels: Bool) {
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
                    if player == 0 { markActive() }
                    states[slot].held.insert(button)
                } else {
                    states[slot].held.remove(button)
                }
                onButton?(player, button, pressed)
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
            guard let self else { return }
            if player == 0 && (x != 0 || y != 0) { markActive() }
            states[slot].dpad = Self.directions(x: x, y: y, threshold: 0.5)
            updateDirections(slot: slot, player: player)
        }
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            guard let self else { return }
            if player == 0 && (abs(x) > 0.5 || abs(y) > 0.5) { markActive() }
            onAnalog?(player, 0, x, -y)
            states[slot].stick = stickMovesDPad ? Self.directions(x: x, y: y, threshold: 0.5) : []
            updateDirections(slot: slot, player: player)
        }
        pad.rightThumbstick.valueChangedHandler = { [weak self] _, x, y in
            guard let self else { return }
            if player == 0 && (abs(x) > 0.5 || abs(y) > 0.5) { markActive() }
            onAnalog?(player, 1, x, -y)
        }
        if let home = pad.buttonHome {
            home.preferredSystemGestureState = .disabled
            home.pressedChangedHandler = { [weak self] _, _, pressed in
                if pressed { self?.onMenu?() }
            }
        }
    }

    /// Manette au-delà de la deuxième : plus rien ne passe.
    private func unbind(_ pad: GCExtendedGamepad) {
        for input in [pad.buttonA, pad.buttonB, pad.buttonX, pad.buttonY, pad.leftShoulder, pad.rightShoulder,
                      pad.leftTrigger, pad.rightTrigger, pad.buttonMenu] {
            input.pressedChangedHandler = nil
        }
        for input in [pad.leftThumbstickButton, pad.rightThumbstickButton, pad.buttonOptions, pad.buttonHome] {
            input?.pressedChangedHandler = nil
        }
        pad.dpad.valueChangedHandler = nil
        pad.leftThumbstick.valueChangedHandler = nil
        pad.rightThumbstick.valueChangedHandler = nil
    }

    // MARK: Vibrations

    /// Pendant une partie : les vibrations des moteurs (PTRumble) font vibrer la manette de chaque joueur.
    func listenToRumble() {
        PTRumbleSetHandler { [weak self] port, strong, weak in
            self?.rumble(player: Int(port), strong: strong, weak: weak)
        }
    }

    /// Menu pause : les vibrations en cours s'arrêtent (le jeu ne les coupera pas lui-même).
    func stopRumble() {
        rumble(player: 0, strong: 0, weak: 0)
        rumble(player: 1, strong: 0, weak: 0)
    }

    /// Fin de partie : plus de vibrations.
    func stopListeningToRumble() {
        PTRumbleSetHandler(nil)
        stopRumble()
    }

    private func rumble(player: Int, strong: Float, weak: Float) {
        // Une seule vibration par manette : le gros moteur, ou le petit un peu moins fort.
        let intensity = min(1, max(strong, weak * 0.7))
        hapticQueue.async { [weak self] in
            guard let self else { return }
            for pad in haptics where pad.player == player {
                pad.apply(intensity, queue: hapticQueue)
            }
        }
    }

    /// Une vibration par manette qui joue (fil `hapticQueue`) ; celle d'une manette partie s'arrête.
    private func updateHaptics(_ controllers: [GCController], players: [Int]) {
        var kept: [PadHaptics] = []
        for (index, controller) in controllers.enumerated() {
            let pad = haptics.first { $0.controller === controller } ?? PadHaptics(controller: controller)
            pad.player = index < players.count ? players[index] : 0
            kept.append(pad)
        }
        for pad in haptics where !kept.contains(where: { $0 === pad }) { pad.stop() }
        haptics = kept
    }

    // MARK: Relâcher

    /// Relâche tout ce que les manettes tenaient : boutons, directions et sticks.
    private func releaseAll() {
        for slot in states.indices {
            let player = slot < slotPlayers.count ? slotPlayers[slot] : 0
            for button in states[slot].held { onButton?(player, button, false) }
            states[slot].held.removeAll()
            states[slot].dpad.removeAll()
            states[slot].stick.removeAll()
            updateDirections(slot: slot, player: player)
            onAnalog?(player, 0, 0, 0)
            onAnalog?(player, 1, 0, 0)
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

    private func updateDirections(slot: Int, player: Int) {
        let now = states[slot].dpad.union(states[slot].stick)
        for button in states[slot].directions.subtracting(now) { onButton?(player, button, false) }
        for button in now.subtracting(states[slot].directions) { onButton?(player, button, true) }
        states[slot].directions = now
    }
}

/// Vibration d'une manette : moteur de vibrations et lecteur d'une vibration continue dont on règle la force. Tout
/// sur la file des vibrations de GamepadManager.
private final class PadHaptics {
    let controller: GCController
    var player = 0
    private var engine: CHHapticEngine?
    private var hapticPlayer: CHHapticAdvancedPatternPlayer?
    private var playing = false
    private var intensity: Float = 0

    init(controller: GCController) {
        self.controller = controller
    }

    /// Règle la force ; arrêtée sous 2 % (ou vibrations coupées dans Réglages).
    func apply(_ value: Float, queue: DispatchQueue) {
        let on = value > 0.02 && RumbleSettings.enabled
        guard on != playing || (on && abs(value - intensity) > 0.03) else { return }
        intensity = value
        guard on else {
            try? hapticPlayer?.stop(atTime: CHHapticTimeImmediate)
            playing = false
            return
        }
        do {
            if hapticPlayer == nil {
                guard let engine = controller.haptics?.createEngine(withLocality: .default) else { return }
                engine.playsHapticsOnly = true
                engine.stoppedHandler = { [weak self] _ in queue.async { self?.forget() } }
                engine.resetHandler = { [weak self] in queue.async { self?.forget() } }
                try engine.start()
                let event = CHHapticEvent(eventType: .hapticContinuous,
                                          parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                                                       CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3)],
                                          relativeTime: 0, duration: 30)
                let player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
                player.loopEnabled = true
                self.engine = engine
                hapticPlayer = player
            }
            try hapticPlayer?.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
                                                                       value: value, relativeTime: 0)],
                                             atTime: CHHapticTimeImmediate)
            if !playing {
                try hapticPlayer?.start(atTime: CHHapticTimeImmediate)
                playing = true
            }
        } catch {
            PTLogLine("Vibrations de la manette impossibles : \(error.localizedDescription)")
            stop()
        }
    }

    func stop() {
        try? hapticPlayer?.stop(atTime: CHHapticTimeImmediate)
        engine?.stop()
        forget()
    }

    private func forget() {
        hapticPlayer = nil
        engine = nil
        playing = false
        intensity = 0
    }
}
