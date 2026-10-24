import Foundation
import SwiftUI

/// Fait tourner un jeu : charge le moteur, cadence les images, le son et gère les sauvegardes.
/// Le moteur vit sur son propre thread ; l'interface lui envoie des commandes.
/// La PS2, la GameCube/Wii et la PS Vita ont leur propre moteur (`ExternalEngine`) qui cadence, dessine et joue le
/// son lui-même : la session le pilote seulement (voir `runExternal`).
///
/// Partage entre threads (d'où `@unchecked Sendable`) : les propriétés publiées ne changent que sur le
/// thread principal ; commandes, pause et réglages passent par `condition` ; le moteur par `coreLock` ;
/// le reste (`audio`, `fastForward`, `lastSavedRAM`) n'est touché que par le thread d'émulation.
final class EmulatorSession: ObservableObject, @unchecked Sendable {
    enum State: Equatable {
        case loading
        case running
        case paused
        case failed(String)
        case stopped
    }

    struct DiskInfo: Equatable {
        let current: Int
        let count: Int
    }

    let game: Game
    let frameBuffer = FrameBuffer()

    @Published private(set) var state: State = .loading
    @Published private(set) var aspectRatio: CGFloat = 4.0 / 3.0
    @Published private(set) var hasSaveState: Bool
    @Published private(set) var diskInfo: DiskInfo?
    @Published private(set) var isFastForwarding = false
    /// Vitesses de l'avance rapide et du retour en arrière (appui long sur leurs boutons du menu pause), gardées pour
    /// tous les jeux.
    @Published private(set) var fastForwardSpeed = EmulatorSession.storedSpeed(EmulatorSession.fastForwardSpeedKey, default: 3)
    @Published private(set) var rewindSpeed = EmulatorSession.storedSpeed(EmulatorSession.rewindSpeedKey, default: 2)
    /// Retour en arrière lancé depuis le menu pause : la partie recule jusqu'à ce qu'on touche l'écran.
    @Published private(set) var isRewindingFromMenu = false
    /// Plus de photo à reprendre : la partie reste à la plus ancienne.
    @Published private(set) var rewindReachedStart = false
    /// RetroAchievements : succès débloqués et total du jeu (nil si le joueur n'est pas connecté ou si le jeu n'en a
    /// pas) ; mode Hardcore en cours (chargement de sauvegarde rapide, retour arrière et triche interdits).
    @Published private(set) var achievementCounts: (unlocked: Int, total: Int)?
    @Published private(set) var achievementsHardcore = false
    /// Codes de triche du jeu (menu pause › Codes de triche), gardés par Cheats.
    @Published private(set) var cheats: [Cheat]
    @Published var toast: String?
    /// Étape longue en cours pendant le chargement (installation du firmware ou d'un jeu PS Vita), montrée sous la roue.
    @Published private(set) var loadingDetail: String?
#if PLAYTENDO_VITA
    /// PS Vita : résolution de la partie en cours (un autre choix ne vaut qu'au prochain lancement).
    @Published private(set) var vitaResolution: VitaSettings.Resolution?
#endif
    /// PS2, GameCube/Wii : vue Metal où le moteur dessine, placée par l'écran de jeu.
    @Published private(set) var engineView: PlatformView?

    private let ring: OpaquePointer
    /// Moteur en cours : écrit par le thread d'émulation, lu aussi par les entrées (écran, manette)
    /// depuis le thread principal, d'où le verrou.
    private let coreLock = NSLock()
    private var runningCore: PTCore?
    private var core: PTCore? {
        get { coreLock.withLock { runningCore } }
        set { coreLock.withLock { runningCore = newValue } }
    }
    private var audio: AudioOutput?
    private var thread: Thread?
    /// Moteur autonome (PS2, GameCube/Wii) : choisi au démarrage (thread principal), jamais changé ensuite.
    private var external: ExternalEngine?
    /// Wii : commandes envoyées à la Wiimote + Nunchuk plutôt qu'à la manette GameCube (thread principal).
    private var wiimote = false

    private let condition = NSCondition()
    private var pendingCommands: [() -> Void] = []
    private var pauseRequested = false
    private var stopRequested = false
    private var stopHandlers: [() -> Void] = []
    /// Réglages du moteur demandés par l'interface (disposition des écrans DS…).
    private var optionOverrides: [String: String] = [:]

    // Uniquement manipulés sur le thread d'émulation.
    private var fastForward = false
    /// Images du moteur par image affichée en avance rapide ; images de jeu reculées par image en retour en arrière.
    private var fastForwardSteps = EmulatorSession.storedSpeed(EmulatorSession.fastForwardSpeedKey, default: 3)
    private var rewindStep = EmulatorSession.storedSpeed(EmulatorSession.rewindSpeedKey, default: 2)
    /// Retour en arrière demandé (menu pause, gâchette L2, Espace sur Mac), sous `condition`.
    private var rewindRequested = false
    /// Partie en train de reculer : son coupé (lu par le moteur, sur son thread).
    private var rewindingNow = false
    private var lastSavedRAM: Data?
    /// Codes de triche au format du moteur, envoyés une fois le jeu lancé (`cheatsSent`) puis à chaque changement.
    private var cheatCodes: [String]
    /// Les mêmes, tels quels, pour les moteurs autonomes (PS2, GameCube, Wii).
    private var cheatList: [Cheat]
    private var cheatsSent = false
    private var cheatFrames = 0
    /// Affichage des performances : images produites par le moteur libretro (écrites par le thread d'émulation).
    private let framesLock = NSLock()
    private var producedFrames: UInt64 = 0
    /// N64 : moteur à recharger à la reprise (réglages d'image lus seulement au démarrage d'un jeu).
    private var coreReloadRequested = false
    /// Partie à reprendre après un rechargement du moteur : Mupen64Plus refuse une sauvegarde rapide avant d'avoir
    /// fait tourner au moins une image, elle est donc rechargée après les premières (essais limités).
    private var pendingReloadState: Data?
    private var pendingReloadAttempts = 0
    /// La partie en attente (`pendingReloadState`) est la reprise automatique du lancement, pas un rechargement.
    private var resuming = false
    /// RetroAchievements suivi pour ce jeu (thread d'émulation) ; reprise automatique gardée de côté en attendant de
    /// savoir si le jeu est en Hardcore (où reprendre une partie sauvegardée est interdit).
    private var achievementsOn = false
    private var heldResumeState: Data?

#if os(macOS)
    /// Partie en cours (thread principal) : arrêtée proprement avant que l'app se ferme (MacAppDelegate).
    nonisolated(unsafe) static weak var active: EmulatorSession?
#endif

    init(game: Game) {
        self.game = game
        ring = PTAudioRingCreate(48_000)
        hasSaveState = FileManager.default.fileExists(atPath: Paths.stateFile(for: game).path)
        let cheats = Cheats.supported(game.system) ? Cheats.load(for: game) : []
        self.cheats = cheats
        cheatList = cheats
        cheatCodes = Cheats.engineCodes(for: cheats, system: game.system)
    }

    deinit {
        PTAudioRingDestroy(ring)
    }

    // MARK: Commandes (thread principal)

    func start() {
        guard thread == nil else { return }
#if os(macOS)
        // Sur Mac, les consoles arrivent étape par étape : sans son moteur dans l'app, un message clair.
        guard Self.engineInstalled(for: game.system) else {
            fail(tr("La \(game.system.name) n'est pas encore disponible sur Mac : elle arrivera dans une prochaine version de PlayTendo."))
            return
        }
        Self.active = self
#endif
        var external: ExternalEngine?
        do {
            switch game.system {
            case .ps2: external = try Self.loadPS2Engine()
            case .gameCube, .wii: external = try Self.loadDolphinEngine()
#if PLAYTENDO_VITA
            case .vita: external = try Self.loadVitaEngine()
#endif
            default: break
            }
        } catch {
            fail(trMessage(error.localizedDescription))
            return
        }
        self.external = external
        (external as? PTDolphinEngine)?.setWiimote(wiimote)
        engineView = external?.renderView
        let thread = Thread {
            if let external { self.runExternal(external) } else { self.run() }
        }
        thread.name = "PlayTendo émulation"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 16 << 20
        self.thread = thread
        thread.start()
    }

    func pause() {
        guard state == .running else { return }
        condition.lock()
        pauseRequested = true
        condition.unlock()
        state = .paused
        perform { [self] in
            persistSaveRAM()
            audio?.pause()
        }
        startAchievementsIdle()
    }

    /// Pendant la pause, la session RetroAchievements reste active (message au serveur de temps en temps).
    private var achievementsIdleTimer: Timer?

    private func startAchievementsIdle() {
        guard achievementCounts != nil else { return }
        refreshAchievementCounts()
        achievementsIdleTimer?.invalidate()
        achievementsIdleTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .paused else { return }
                PTAchievements.shared.idle()
            }
        }
    }

    func resume() {
        guard state == .paused else { return }
        condition.lock()
        pauseRequested = false
        condition.signal()
        condition.unlock()
        state = .running
        achievementsIdleTimer?.invalidate()
        achievementsIdleTimer = nil
        perform { [self] in audio?.start() }
    }

    func stop(then completion: @escaping () -> Void) {
        switch state {
        case .stopped, .failed:
            completion()
            return
        default:
            if thread == nil {
                completion()
                return
            }
        }
        stopHandlers.append(completion)
        condition.lock()
        stopRequested = true
        condition.signal()
        condition.unlock()
    }

    func reset() {
        perform { [self] in
            core?.reset()
            external?.reset()
            if achievementsOn { PTAchievements.shared.reset() }
            // Codes de triche renvoyés au nouveau départ (certains moteurs les oublient).
            cheatsSent = false
            cheatFrames = 0
        }
    }

    /// Affichage des performances : mesures du moteur en cours (nil avant le démarrage).
    func performanceSample() -> EnginePerformance? {
        if let external { return external.performance }
        guard let core else { return nil }
        return EnginePerformance(frames: framesLock.withLock { producedFrames }, nominalFPS: core.framesPerSecond)
    }

    /// Codes de triche changés (ajout, interrupteur, suppression) : gardés, et appliqués tout de suite.
    func setCheats(_ list: [Cheat]) {
        cheats = list
        Cheats.save(list, for: game)
        let codes = Cheats.engineCodes(for: list, system: game.system)
        perform { [self] in
            cheatList = list
            cheatCodes = codes
            if cheatsSent {
                core?.setCheats(codes)
                external?.applyCheats(list, system: game.system)
            }
        }
    }

    /// Change des réglages du moteur, avant ou pendant la partie.
    func applyOptions(_ options: [String: String]) {
        guard !options.isEmpty else { return }
        condition.lock()
        optionOverrides.merge(options) { $1 }
        condition.unlock()
        perform { [self] in core?.updateOptions(options) }
    }

    /// PS2 : applique la résolution, le lissage et le format choisis dans le menu pause (PS2Settings).
    func applyPS2Image() {
        perform { [self] in Self.applyPS2Image(to: external as? PTPS2Engine) }
    }

    private static func applyPS2Image(to engine: PTPS2Engine?) {
        engine?.setImageUpscale(PS2Settings.resolution.rawValue, smoothing: PS2Settings.smoothing == .on,
                                widescreen: PS2Settings.format == .wide)
    }

    /// Réglages que le moteur ne lit qu'au démarrage du jeu (image N64) : à la reprise, le moteur est rechargé avec
    /// eux, la partie étant gardée par une sauvegarde rapide.
    func requestCoreReload() {
        perform { [self] in coreReloadRequested = true }
    }

    /// GameCube/Wii : applique la résolution et le lissage choisis dans le menu pause (DolphinSettings).
    func applyDolphinImage() {
        perform { [self] in Self.applyDolphinImage(to: external as? PTDolphinEngine, system: game.system) }
    }

    private static func applyDolphinImage(to engine: PTDolphinEngine?, system: GameSystem) {
        engine?.setImageScale(Int32(DolphinSettings.resolution.rawValue), smoothing: DolphinSettings.smoothing == .on)
        // Écran large forcé : jeux GameCube seulement (les jeux Wii choisissent eux-mêmes).
        engine?.setWidescreen(system == .gameCube && DolphinSettings.format == .wide)
    }

    /// Wii : commandes vers la Wiimote + Nunchuk (vrai) ou vers la manette GameCube. Avant ou pendant la partie.
    func setWiimote(_ enabled: Bool) {
        wiimote = enabled
        (external as? PTDolphinEngine)?.setWiimote(enabled)
    }

    func saveState() {
        if let external {
            perform { [self] in
                if external.saveState(toPath: Paths.stateFile(for: game).path) {
                    PTLogLine("\(game.system.shortName) : sauvegarde rapide écrite")
                    writeAchievementProgress()
                    saveEngineThumbnail(external)
                    DispatchQueue.main.async { self.hasSaveState = true }
                    showToast(tr("Partie sauvegardée"))
                } else {
                    PTLogLine("\(game.system.shortName) : sauvegarde rapide impossible (\(external.lastError() ?? "raison inconnue"))")
                    showToast(tr("Échec de la sauvegarde"))
                }
            }
            return
        }
        perform { [self] in
            guard let data = core?.saveState() else {
                showToast(tr("Ce jeu ne permet pas la sauvegarde rapide"))
                return
            }
            do {
                let packed = Self.packState(data)
                try packed.write(to: Paths.stateFile(for: game), options: .atomic)
                writeAchievementProgress()
                PTLogLine(packed.count == data.count ? "Sauvegarde rapide : \(data.count / 1024) Ko (gardée brute)"
                          : "Sauvegarde rapide : \(data.count / 1024) Ko, \(packed.count / 1024) Ko une fois compressée")
                saveThumbnail()
                DispatchQueue.main.async { self.hasSaveState = true }
                showToast(tr("Partie sauvegardée"))
            } catch {
                showToast(tr("Échec de la sauvegarde"))
            }
        }
    }

    func loadState() {
        guard !achievementsHardcore else { return }
        if let external {
            perform { [self] in
                if external.loadState(fromPath: Paths.stateFile(for: game).path) {
                    PTLogLine("\(game.system.shortName) : sauvegarde rapide chargée")
                    if achievementsOn { PTAchievements.shared.restoreProgress(try? Data(contentsOf: achievementProgressFile)) }
                    showToast(tr("Sauvegarde chargée"))
                } else {
                    PTLogLine("\(game.system.shortName) : chargement impossible (\(external.lastError() ?? "raison inconnue"))")
                    showToast(tr("Impossible de charger la sauvegarde"))
                }
            }
            return
        }
        perform { [self] in
            guard let file = try? Data(contentsOf: Paths.stateFile(for: game)),
                  let data = Self.unpackState(file),
                  core?.loadState(data) == true else {
                PTLogLine("Sauvegarde rapide illisible")
                showToast(tr("Impossible de charger la sauvegarde"))
                return
            }
            PTLogLine("Sauvegarde rapide chargée (\(file.starts(with: Self.compressedStateMagic) ? "compressée" : "brute"))")
            if achievementsOn { PTAchievements.shared.restoreProgress(try? Data(contentsOf: achievementProgressFile)) }
            showToast(tr("Sauvegarde chargée"))
        }
    }

    /// Où en sont les succès RetroAchievements au moment de la sauvegarde rapide (à côté d'elle).
    private var achievementProgressFile: URL { Paths.stateFile(for: game).appendingPathExtension("succes") }

    /// Après une sauvegarde rapide : la progression des succès gardée avec elle (effacée sans succès suivis).
    private func writeAchievementProgress() {
        if achievementsOn, let progress = PTAchievements.shared.progress() {
            try? progress.write(to: achievementProgressFile, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: achievementProgressFile)
        }
    }

    /// Reprise automatique : la partie au moment de quitter, compressée comme une sauvegarde rapide.
    private func writeResume(_ state: Data?) {
        guard let state else { return }
        let packed = Self.packState(state)
        if (try? packed.write(to: Paths.resumeFile(for: game), options: .atomic)) != nil {
            PTLogLine("Reprise automatique gardée (\(packed.count / 1024) Ko)")
        } else {
            PTLogLine("Reprise automatique : écriture impossible")
        }
    }

    /// Les sauvegardes rapides (jusqu'à 75 Mo pour la PSP, presque entièrement vides) sont
    /// compressées en LZFSE et précédées de « PTZ1 ». Les anciennes, brutes, se lisent toujours.
    private static let compressedStateMagic = Data("PTZ1".utf8)

    private static func packState(_ state: Data) -> Data {
        // Gardée brute si la compression n'y gagne rien (3DS : 24 Mo compressés en… 24 Mo).
        guard let compressed = try? (state as NSData).compressed(using: .lzfse),
              compressed.length + compressedStateMagic.count < state.count * 9 / 10 else { return state }
        return compressedStateMagic + (compressed as Data)
    }

    private static func unpackState(_ file: Data) -> Data? {
        guard file.starts(with: compressedStateMagic) else { return file }
        return try? (Data(file.dropFirst(compressedStateMagic.count)) as NSData).decompressed(using: .lzfse) as Data
    }

    /// Consoles qui peuvent reculer : sauvegarde rapide petite et rapide (pas la DS, la 3DS, la PSP, ni les moteurs
    /// autonomes PS2, GameCube, Wii, PS Vita).
    static func supportsRewind(_ system: GameSystem) -> Bool {
        [.nes, .snes, .gb, .gbc, .gba, .n64, .psx].contains(system)
    }

    /// Retour en arrière possible pour ce jeu (console qui sait reculer).
    var rewindAvailable: Bool { Self.supportsRewind(game.system) }

    /// Maintenu : la partie recule. Relâché : elle reprend de là.
    func setRewinding(_ on: Bool) {
        if on && achievementsHardcore { return }
        condition.lock()
        rewindRequested = on
        condition.signal()
        condition.unlock()
    }

    /// Menu pause › Retour arrière : la partie recule (une fois le menu fermé) jusqu'à `stopRewind`.
    func startRewind() {
        guard !achievementsHardcore else { return }
        rewindReachedStart = false
        isRewindingFromMenu = true
        setRewinding(true)
    }

    /// Fin du retour en arrière lancé depuis le menu : la partie reprend de là.
    func stopRewind() {
        guard isRewindingFromMenu else { return }
        isRewindingFromMenu = false
        setRewinding(false)
    }

    func toggleFastForward() {
        isFastForwarding.toggle()
        let enabled = isFastForwarding
        perform { [self] in
            fastForward = enabled
            external?.setSpeed(enabled ? Double(fastForwardSteps) : 1)
        }
    }

    /// Choix proposés pour l'avance rapide et le retour en arrière.
    static let speeds = [2, 3, 4, 5]
    private static let fastForwardSpeedKey = "vitesseAvanceRapide"
    private static let rewindSpeedKey = "vitesseRetourArriere"

    private static func storedSpeed(_ key: String, default value: Int) -> Int {
        let stored = UserDefaults.standard.integer(forKey: key)
        return speeds.contains(stored) ? stored : value
    }

    /// Avance rapide à cette vitesse (gardée pour les prochaines fois), mise en route si elle ne l'était pas.
    func startFastForward(speed: Int) {
        fastForwardSpeed = speed
        UserDefaults.standard.set(speed, forKey: Self.fastForwardSpeedKey)
        isFastForwarding = true
        perform { [self] in
            fastForwardSteps = speed
            fastForward = true
            external?.setSpeed(Double(speed))
        }
    }

    /// Retour en arrière à cette vitesse (gardée pour les prochaines fois), lancé depuis le menu.
    func startRewind(speed: Int) {
        rewindSpeed = speed
        UserDefaults.standard.set(speed, forKey: Self.rewindSpeedKey)
        perform { [self] in rewindStep = speed }
        startRewind()
    }

    /// Met le disque `index` (à partir de 0) : menu pause › DISQUE.
    func selectDisk(_ index: Int) {
        perform { [self] in
            guard let core else {
                // GameCube : le changement est vu par la boucle de runExternal, qui l'annonce.
                _ = external?.changeDisc(to: index)
                return
            }
            guard core.switchToDisk(at: UInt(index)) else { return }
            let info = DiskInfo(current: Int(core.currentDiskIndex) + 1, count: Int(core.diskCount))
            DispatchQueue.main.async { self.diskInfo = info }
            showToast(tr("Disque \(info.current) inséré"))
        }
    }

    // MARK: Entrées (n'importe quel thread)

    func setButton(_ button: PTButton, pressed: Bool, port: UInt32 = 0) {
        if let external {
            external.setButton(button.rawValue, pressed: pressed, player: Int(port))
            return
        }
        core?.setButton(button, pressed: pressed, port: port)
    }

    func setAnalog(stick: UInt32, x: Float, y: Float, port: UInt32 = 0) {
        if let external {
            external.setStick(Int32(stick), x: max(-1, min(1, x)), y: max(-1, min(1, y)), player: Int(port))
            return
        }
        core?.setAnalogStick(stick, x: Self.axis(x), y: Self.axis(y), port: port)
    }

    /// PS2 : numéro et CRC du jeu en cours (codes de triche de cette version exacte).
    var engineGameIdentity: (serial: String, crc: UInt32)? { external?.gameIdentity }

    /// Deuxième manette branchée ou retirée (GameCube, Wii : manette ou Wiimote du joueur 2).
    func setSecondPlayer(_ connected: Bool) {
        external?.setSecondPlayer(connected)
    }

    /// Message bref par-dessus le jeu (manette 2 branchée…).
    func announce(_ text: String) {
        showToast(text)
    }

    /// Position normalisée (0…1) dans l'image du jeu. Wiimote : le pointeur reste où le doigt l'a laissé.
    func setPointer(x: CGFloat, y: CGFloat, pressed: Bool) {
        if let external {
            (external as? PTDolphinEngine)?.setPointerX(Float(x * 2 - 1), y: Float(y * 2 - 1))
#if PLAYTENDO_VITA
            // PS Vita : écran tactile avant (le doigt se lève quand `pressed` passe à faux).
            (external as? PTVitaEngine)?.touchAt(x: Float(x), y: Float(y), pressed: pressed)
#endif
            return
        }
        let px = Int16(max(-32767, min(32767, (x * 2 - 1) * 32767)))
        let py = Int16(max(-32767, min(32767, (y * 2 - 1) * 32767)))
        core?.setPointerX(px, y: py, pressed: pressed)
    }

    func clearInput() {
        if let external {
            for player in 0..<2 {
                for button in 0..<16 { external.setButton(button, pressed: false, player: player) }
                external.setStick(0, x: 0, y: 0, player: player)
                external.setStick(1, x: 0, y: 0, player: player)
            }
#if PLAYTENDO_VITA
            (external as? PTVitaEngine)?.touchAt(x: 0, y: 0, pressed: false)
#endif
            return
        }
        core?.clearInput()
    }

    private static func axis(_ value: Float) -> Int16 {
        Int16(max(-32767, min(32767, value * 32767)))
    }

    // MARK: Thread d'émulation

    private func perform(_ command: @escaping () -> Void) {
        condition.lock()
        pendingCommands.append(command)
        condition.signal()
        condition.unlock()
    }

    /// Message bref affiché par-dessus le jeu.
    private func showToast(_ text: String) {
        DispatchQueue.main.async {
            if self.toast == nil {
                self.presentToast(text)
            } else if self.toast != text, self.pendingToasts.last != text {
                // Déjà un message à l'écran (« Partie reprise » et RetroAchievements arrivent ensemble) : il attend
                // son tour au lieu de le remplacer. Au plus trois en attente.
                self.pendingToasts.append(text)
                if self.pendingToasts.count > 3 { self.pendingToasts.removeFirst() }
            }
        }
    }

    /// Messages en attente (thread principal), montrés l'un après l'autre.
    private var pendingToasts: [String] = []

    /// Thread principal : un message, le temps de le lire (plus long pour un long message), puis le suivant.
    private func presentToast(_ text: String) {
        toast = text
        let duration = min(4, max(1.6, Double(text.count) * 0.05))
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard self.toast == text else { return }
            self.toast = nil
            guard !self.pendingToasts.isEmpty else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard self.toast == nil, !self.pendingToasts.isEmpty else { return }
                self.presentToast(self.pendingToasts.removeFirst())
            }
        }
    }

    private func fail(_ message: String) {
        PTLogLine("Erreur : \(message)")
        DispatchQueue.main.async {
            self.state = .failed(message)
            self.finishStop()
        }
    }

    private func finishStop() {
#if os(macOS)
        if Self.active === self { Self.active = nil }
#endif
        let handlers = stopHandlers
        stopHandlers.removeAll()
        handlers.forEach { $0() }
    }

    /// Le moteur de cette console est dans l'app (sur Mac, les consoles arrivent étape par étape).
    static func engineInstalled(for system: GameSystem) -> Bool {
        installedEngines.contains(system.coreName)
    }

    /// Moteurs présents dans l'app (ils ne changent pas tant qu'elle est ouverte).
    private static let installedEngines: Set<String> = {
        guard let frameworks = Bundle.main.privateFrameworksPath else { return [] }
        return Set(GameSystem.allCases.map(\.coreName).filter {
            FileManager.default.fileExists(atPath: "\(frameworks)/\($0).framework/\($0)")
        })
    }()

    /// Réserve JIT sans assez de place d'un seul tenant (ne devrait plus arriver : voir PT_JIT_SMALL dans PTJIT.m).
    private static var jitFullMessage: String {
        tr("la mémoire du mode turbo est encore occupée par une autre console. Ferme PlayTendo (fais-la glisser vers le haut dans le sélecteur d'apps), puis relance-la.")
    }

    /// Après une partie PS2, sa console en veille garde des Go d'adresses réservées (dont celles que la PSP veut
    /// pour sa mémoire : « Memory init failed ») et sa part de la réserve JIT : on l'arrête avant une autre console.
    private func releasePS2Memory() {
        if let ps2 = PTPS2Engine.loaded, ps2.state == PTPS2StateStopped {
            ps2.releaseMemory()
            PTLogLine("PS2 : console en veille arrêtée (mémoire rendue pour \(game.system.shortName))")
        }
    }

    private func run() {
        let system = game.system
        releasePS2Memory()
        guard let frameworks = Bundle.main.privateFrameworksPath else {
            fail(tr("Moteurs introuvables dans l'app."))
            return
        }
        let corePath = "\(frameworks)/\(system.coreName).framework/\(system.coreName)"

        var core: PTCore
        do {
            core = try loadCore(path: corePath)
        } catch {
            fail(trMessage(error.localizedDescription))
            return
        }

        // Reprise automatique : la partie laissée en quittant, rechargée après les premières images (comme après un
        // rechargement du moteur : certains moteurs refusent une sauvegarde rapide avant d'avoir tourné).
        if let file = try? Data(contentsOf: Paths.resumeFile(for: game)), let state = Self.unpackState(file) {
            pendingReloadState = state
            pendingReloadAttempts = 0
            resuming = true
        }

        startAchievements(core: core)

        let audio = AudioOutput(sampleRate: core.sampleRate, ring: ring)
        audio.start()
        self.audio = audio

        var currentAspect = core.aspectRatio
        let initialAspect = CGFloat(currentAspect)
        let disks = core.diskCount > 1 ? DiskInfo(current: Int(core.currentDiskIndex) + 1, count: Int(core.diskCount)) : nil
        DispatchQueue.main.async {
            self.aspectRatio = initialAspect
            self.diskInfo = disks
            self.state = .running
        }
        if JITManager.benefits(system) {
            let jit = PTJITIsActive()
            PTLogLine(jit ? "Mode turbo (JIT) utilisé" : "Sans JIT : interpréteur")
#if os(iOS)
            // Sur Mac, le turbo est toujours là : rien à signaler.
            if jit { showToast(tr("Mode turbo (JIT) actif")) }
#endif
        }

        let clock = MachClock()
        let audioTarget = core.sampleRate * 0.05 // 50 ms de son d'avance
        // Démarre avec un peu d'avance pour remplir le tampon audio.
        var deadline = clock.now - 0.05
        var lastAutoSave = clock.now
        // Retour en arrière : photos de la partie, images depuis la dernière, images de jeu à reculer (la vitesse en
        // ajoute à chaque image affichée ; une photo est reprise chaque fois qu'il y en a assez).
        let rewindEnabled = rewindAvailable
        var rewindBuffer = RewindBuffer()
        var rewindFrame = 0
        var rewindCredit = 0
        var rewindExhausted = false
        var clockReset = false
        var wasPaused = false
        // Mesure de vitesse (journal toutes les 10 s si le jeu n'arrive pas à suivre : son haché, ralentis).
        var statStart = clock.now
        var statFrames = 0
        var statLate = 0
        var statWork = 0.0

        while true {
            condition.lock()
            while pauseRequested && !stopRequested && pendingCommands.isEmpty {
                condition.wait()
            }
            let commands = pendingCommands
            pendingCommands.removeAll()
            let stop = stopRequested
            let paused = pauseRequested
            let rewinding = rewindRequested && rewindEnabled
            condition.unlock()

            for command in commands { command() }
            if stop { break }
            if paused {
                wasPaused = true
                continue
            }
            if wasPaused {
                wasPaused = false
                if coreReloadRequested {
                    coreReloadRequested = false
                    guard let reloaded = reloadCore(core, path: corePath) else {
                        if achievementsOn { PTAchievements.shared.endGame() }
                        audio.stop()
                        self.audio = nil
                        self.core = nil
                        fail(tr("Le jeu n'a pas pu redémarrer avec les nouveaux réglages d'image."))
                        return
                    }
                    core = reloaded
                    if achievementsOn { PTAchievements.shared.attach(reloaded) }
                    cheatsSent = false
                    cheatFrames = 0
                }
                deadline = clock.now - 0.05
                statStart = clock.now
                statFrames = 0
                statLate = 0
                statWork = 0
            }

            let workStart = clock.now
            if rewinding {
                // Retour en arrière : `rewindStep` fois plus vite que le jeu n'avance (photos sautées au besoin), la
                // dernière photo reprise montrée avec une image du moteur, sans le son.
                rewindingNow = true
                rewindCredit += rewindStep
                var target: Data?
                while rewindCredit >= rewindBuffer.interval, let state = rewindBuffer.popLast() {
                    target = state
                    rewindCredit -= rewindBuffer.interval
                }
                if let target {
                    if core.loadState(target) { core.runFrame() }
                } else if rewindCredit >= rewindBuffer.interval {
                    // Plus loin impossible : la partie reste à la plus ancienne photo (annoncé à l'écran).
                    rewindCredit = 0
                    if !rewindExhausted {
                        rewindExhausted = true
                        DispatchQueue.main.async { self.rewindReachedStart = true }
                    }
                }
            } else {
                // Fin d'un retour en arrière : les succès repartent d'un état neutre (pas de faux déblocage).
                if rewindingNow && achievementsOn { PTAchievements.shared.restoreProgress(nil) }
                rewindingNow = false
                rewindCredit = 0
                rewindExhausted = false
                let steps = fastForward ? fastForwardSteps : 1
                for _ in 0..<steps {
                    core.runFrame()
                    if achievementsOn { PTAchievements.shared.doFrame() }
                }
                framesLock.withLock { producedFrames &+= UInt64(steps) }
                // Codes de triche : envoyés après la première image (le moteur a fini de démarrer). La PSP ne sait quel
                // est son jeu qu'une fois démarrée : 5 s (elle relit d'elle-même les codes déjà envoyés une autre fois).
                if !cheatsSent {
                    cheatFrames += 1
                    if cheatFrames >= (game.system == .psp ? 300 : 1) {
                        cheatsSent = true
                        if !cheatCodes.isEmpty { core.setCheats(cheatCodes) }
                    }
                }
                // Photo de la partie pour pouvoir reculer (toutes les `interval` images).
                if rewindEnabled {
                    rewindFrame += 1
                    if rewindFrame >= rewindBuffer.interval, let state = core.saveState() {
                        rewindFrame = 0
                        rewindBuffer.push(state)
                    }
                }
            }
            statWork += clock.now - workStart
            statFrames += 1
            if core.shutdownRequested { break }
            if let state = pendingReloadState {
                pendingReloadAttempts += 1
                if core.loadState(state) {
                    pendingReloadState = nil
                    if resuming {
                        resuming = false
                        if achievementsOn { PTAchievements.shared.restoreProgress(nil) }
                        PTLogLine("Reprise automatique : partie reprise après \(pendingReloadAttempts) image(s)")
                        showToast(tr("Partie reprise"))
                    } else {
                        PTLogLine("Rechargement du moteur : partie reprise après \(pendingReloadAttempts) image(s)")
                        showToast(tr("Image appliquée"))
                    }
                } else if pendingReloadAttempts >= 120 {
                    pendingReloadState = nil
                    if resuming {
                        resuming = false
                        PTLogLine("Reprise automatique : partie illisible, jeu démarré du début")
                        showToast(tr("Reprise impossible : le jeu démarre du début"))
                    } else {
                        PTLogLine("Rechargement du moteur : la partie n'a pas pu être reprise")
                        showToast(tr("Partie non reprise (sauvegarde rapide toujours disponible)"))
                    }
                }
            }

            if core.aspectRatio != currentAspect {
                currentAspect = core.aspectRatio
                let aspect = CGFloat(currentAspect)
                DispatchQueue.main.async { self.aspectRatio = aspect }
            }

            // Cadence : une image tous les 1/fps, légèrement ajustée selon le remplissage
            // du tampon audio pour que le son ne craque jamais (±0,5 %).
            var frameDuration = 1.0 / max(core.framesPerSecond, 1)
            if !fastForward {
                let fill = Double(PTAudioRingFill(ring))
                let correction = max(-1, min(1, (fill - audioTarget) / audioTarget)) * 0.005
                frameDuration *= 1 + correction
            }
            deadline += frameDuration
            let now = clock.now
            if !deadline.isFinite {
                // Sécurité : une valeur impossible (registres écrasés par un moteur) recale l'horloge.
                if !clockReset {
                    PTLogLine("Horloge recalée : valeur de temps impossible après une image")
                    clockReset = true
                }
                deadline = now
            }
            if deadline > now {
                clock.sleep(until: deadline)
            } else {
                if !fastForward { statLate += 1 }
                if now - deadline > 0.25 { deadline = now }
            }
            if now - statStart >= 10 {
                if statLate * 50 > statFrames {
                    PTLogLine(String(format: "Lenteur : %d images en retard sur %d (une image prend %.1f ms en moyenne, il en faut %.1f)",
                                     statLate, statFrames, statWork / Double(max(statFrames, 1)) * 1000,
                                     1000 / max(core.framesPerSecond, 1)))
                }
                statStart = now
                statFrames = 0
                statLate = 0
                statWork = 0
            }

            if now - lastAutoSave > 30 {
                persistSaveRAM()
                lastAutoSave = now
            }
        }

        persistSaveRAM()
        saveThumbnail()
        // Reprise pas encore appliquée (jeu quitté tout de suite) : l'ancienne reste.
        if !(resuming && pendingReloadState != nil) { writeResume(core.saveState()) }
        if achievementsOn { PTAchievements.shared.endGame() }
        core.unloadGame()
        audio.stop()
        self.audio = nil
        self.core = nil
        DispatchQueue.main.async {
            self.state = .stopped
            self.finishStop()
        }
    }

    // MARK: RetroAchievements

    /// Thread d'émulation, jeu chargé : le jeu (fichier lancé, patché pour une romhack) est demandé à RetroAchievements
    /// si le joueur est connecté et que la console a des succès. En Hardcore, la reprise automatique attend la réponse
    /// (reprendre une partie sauvegardée y est interdit).
    private func startAchievements(core: PTCore) {
        let console = PTAchievements.console(forSystem: game.system.shortName)
        guard console != 0, PTAchievements.shared.loggedIn, let path = try? RomPatch.prepare(game).path else { return }
        achievementsOn = true
        if PTAchievements.shared.hardcore, resuming, pendingReloadState != nil {
            heldResumeState = pendingReloadState
            pendingReloadState = nil
            resuming = false
        }
        PTAchievements.shared.beginGame(atPath: path, console: console, core: core) { [weak self] title, unlocked, total, hardcore, _, unknown in
            self?.achievementsLoaded(found: title != nil, unlocked: Int(unlocked), total: Int(total), hardcore: hardcore,
                                     unknown: unknown)
        }
    }

    /// Réponse de RetroAchievements (thread principal). Des codes de triche actifs coupent le Hardcore pour ce jeu.
    /// Version du jeu inconnue chez eux, ou jeu sans succès : dit tout de suite, sinon on attendrait en vain.
    private func achievementsLoaded(found: Bool, unlocked: Int, total: Int, hardcore: Bool, unknown: Bool) {
        var hardcore = hardcore
        if unknown {
            showToast(tr("RetroAchievements ne connaît pas cette version du jeu"))
        } else if found && total == 0 {
            showToast(tr("RetroAchievements : pas encore de succès pour ce jeu"))
        } else if hardcore && cheats.contains(where: \.enabled) {
            PTAchievements.shared.leaveHardcore()
            hardcore = false
            showToast(tr("Hardcore coupé pour ce jeu : des codes de triche sont actifs"))
        } else if found && total > 0 {
            showToast(hardcore ? tr("RetroAchievements : \(unlocked) succès sur \(total) · Hardcore")
                               : tr("RetroAchievements : \(unlocked) succès sur \(total)"))
        }
        achievementsHardcore = hardcore
        achievementCounts = found && total > 0 ? (unlocked, total) : nil
        perform { [self] in
            guard let held = heldResumeState else { return }
            heldResumeState = nil
            if hardcore {
                PTLogLine("Reprise automatique ignorée : Hardcore (RetroAchievements)")
            } else {
                pendingReloadState = held
                pendingReloadAttempts = 0
                resuming = true
            }
        }
    }

    /// Moteur autonome (PS2, GameCube, Wii) : il appelle les succès à chaque image et lit sa mémoire pour eux ; le jeu
    /// est donné par son empreinte (PS2 : par PCSX2 une fois le disque lu ; GameCube/Wii : calculée ici par Dolphin).
    private func startExternalAchievements(_ engine: ExternalEngine, console: UInt32) {
        let reader: PTAchievementReadFunction?
        if let ps2 = engine as? PTPS2Engine {
            reader = ps2.achievementReader
        } else if let dolphin = engine as? PTDolphinEngine {
            reader = dolphin.achievementReader
        } else {
            reader = nil
        }
        guard let reader else { return }
        achievementsOn = true
        PTAchievements.shared.prepareExternalConsole(console, read: reader) { [weak self] title, unlocked, total, hardcore, _, unknown in
            self?.achievementsLoaded(found: title != nil, unlocked: Int(unlocked), total: Int(total), hardcore: hardcore,
                                     unknown: unknown)
        }
        if let ps2 = engine as? PTPS2Engine {
            _ = ps2.setAchievementFrame(PTAchievementsFrame, game: PTAchievementsGameHash)
        } else if let dolphin = engine as? PTDolphinEngine {
            _ = dolphin.setAchievementFrame(PTAchievementsFrame)
            let disc = game.discs.first ?? game.url
            if let hash = dolphin.achievementHash(forPath: disc.path) {
                PTAchievements.shared.loadExternalGameHash(hash)
            } else {
                PTLogLine("RetroAchievements : empreinte du disque impossible (\(disc.lastPathComponent))")
            }
        }
    }

    private func stopExternalAchievements(_ engine: ExternalEngine) {
        if let ps2 = engine as? PTPS2Engine {
            _ = ps2.setAchievementFrame(nil, game: nil)
        } else if let dolphin = engine as? PTDolphinEngine {
            _ = dolphin.setAchievementFrame(nil)
        }
        PTAchievements.shared.endGame()
        achievementsOn = false
    }

    /// Menu pause : compteur des succès à jour.
    func refreshAchievementCounts() {
        guard let counts = achievementCounts else { return }
        achievementCounts = (Int(PTAchievements.shared.unlockedCount()), counts.total)
    }

    /// Charge le moteur libretro et le jeu (thread d'émulation), avec la mémoire de sauvegarde de la cartouche.
    /// RETRO_DEVICE_PSE_DUALSHOCK de PCSX-ReARMed : RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_ANALOG, 1).
    private static let dualShockDevice: UInt32 = ((1 + 1) << 8) | 5

    private func loadCore(path: String) throws -> PTCore {
        let system = game.system
        let core = try PTCore(libraryPath: path)
        core.allowsJIT = JITManager.benefits(system)
        core.prefersVulkan = system == .n3ds
        // PS1 : manette DualShock (vibrations, et sticks pour les jeux qui les lisent) ; elle répond comme une manette
        // simple tant que le jeu ne lui demande rien d'autre.
        if system == .psx { core.controllerDevice = Self.dualShockDevice }
        let frameBuffer = self.frameBuffer
        let ring = self.ring
        core.videoHandler = { pixels, width, height, pitch, format in
            frameBuffer.store(pixels, width: Int(width), height: Int(height), pitch: pitch, format: format)
        }
        core.hardwareVideoHandler = { buffer, width, height, flipped in
            frameBuffer.storeHardware(buffer, width: Int(width), height: Int(height), flipped: flipped)
        }
        core.audioHandler = { [unowned self] samples, frames in
            if !self.fastForward && !self.rewindingNow { PTAudioRingWrite(ring, samples, frames) }
        }

        condition.lock()
        let options = system.coreOptions.merging(optionOverrides) { $1 }
        condition.unlock()
        // Patch de romhack : le jeu patché (refait dans Caches si besoin), pas le .ips/.bps/.ups.
        try core.loadGame(atPath: RomPatch.prepare(game).path,
                          systemDirectory: Paths.systemDirectory(for: system).path,
                          saveDirectory: Paths.coreSaveDirectory(for: system).path,
                          options: options)
        self.core = core
        // Jeu en plusieurs fichiers sans .m3u (disques regroupés par la bibliothèque) : les autres disques sont
        // ajoutés à la liste du moteur, pour le menu pause › DISQUE.
        if game.discs.count > 1 && core.diskCount == 1 {
            for disc in game.discs.dropFirst() where !core.appendDisk(atPath: disc.path) {
                PTLogLine("Disque non ajouté au moteur : \(disc.lastPathComponent)")
                break
            }
        }

        if let data = try? Data(contentsOf: Paths.saveRAMFile(for: game)) {
            core.restoreSaveRAM(data)
        }
        lastSavedRAM = core.saveRAM()
        return core
    }

    /// Recharge le moteur avec les réglages actuels sans perdre la partie : sauvegarde rapide en mémoire, moteur
    /// déchargé puis rechargé, sauvegarde reprise. Nil si le jeu n'a pas pu être rechargé (l'ancien moteur est fermé).
    private func reloadCore(_ old: PTCore, path: String) -> PTCore? {
        let clock = MachClock()
        let start = clock.now
        let state = old.saveState()
        persistSaveRAM()
        self.core = nil
        old.unloadGame()
        do {
            let core = try loadCore(path: path)
            PTLogLine(String(format: "Moteur rechargé avec les nouveaux réglages d'image en %.1f s", clock.now - start))
            // Reprise de la partie après les premières images (voir pendingReloadState).
            pendingReloadState = state
            pendingReloadAttempts = 0
            resuming = false
            if state == nil { showToast(tr("Image appliquée")) }
            return core
        } catch {
            PTLogLine("Rechargement du moteur impossible : \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Moteurs autonomes (PS2, GameCube/Wii, PS Vita)

    /// Charge le moteur PS2 à la première partie PS2 (thread principal), puis le garde.
    private static func loadPS2Engine() throws -> PTPS2Engine {
        if let engine = PTPS2Engine.loaded { return engine }
        guard let frameworks = Bundle.main.privateFrameworksPath else {
            throw NSError(domain: "PlayTendo", code: 2, userInfo: [NSLocalizedDescriptionKey: tr("Moteurs introuvables dans l'app.")])
        }
        let engine = try PTPS2Engine.load(withFrameworkPath: "\(frameworks)/PS2Core.framework/PS2Core",
                                          dataRoot: Paths.ps2Engine.path,
                                          biosDirectory: Paths.bios.path,
                                          memoryCardDirectory: Paths.saveDirectory(for: .ps2).path)
        PTLogLine("PS2 : moteur chargé (journal du moteur : Application Support/Systeme/PS2/logs/emulog.txt)")
        return engine
    }

    /// Charge le moteur GameCube/Wii à la première partie (thread principal), puis le garde.
    private static func loadDolphinEngine() throws -> PTDolphinEngine {
        if let engine = PTDolphinEngine.loaded { return engine }
        guard let frameworks = Bundle.main.privateFrameworksPath else {
            throw NSError(domain: "PlayTendo", code: 2, userInfo: [NSLocalizedDescriptionKey: tr("Moteurs introuvables dans l'app.")])
        }
        let engine = try PTDolphinEngine.load(withFrameworkPath: "\(frameworks)/DolphinCore.framework/DolphinCore",
                                              userDirectory: Paths.dolphinEngine.path,
                                              gameCubeSaveDirectory: Paths.saveDirectory(for: .gameCube).path,
                                              wiiSaveDirectory: Paths.saveDirectory(for: .wii).path)
        PTLogLine("GameCube/Wii : moteur chargé (journal du moteur : Application Support/Systeme/Dolphin/Logs/dolphin.log)")
        var largestBlock: Float = 0
        let fastmem = engine.fastmemAvailable(withLargestBlock: &largestBlock)
        PTLogLine(String(format: "GameCube/Wii : mémoire rapide %@ (plus grand bloc d'adresses libre : %.1f Go)",
                         fastmem ? "oui" : "non", largestBlock))
        return engine
    }

#if PLAYTENDO_VITA
    /// Charge le moteur PS Vita à la première partie Vita (thread principal), puis le garde. Il existe pour iPhone,
    /// iPad et Mac, pas pour le simulateur (son affichage passe par MoltenVK, qui n'y marche pas).
    private static func loadVitaEngine() throws -> PTVitaEngine {
        if let engine = PTVitaEngine.loaded { return engine }
        guard let frameworks = Bundle.main.privateFrameworksPath,
              FileManager.default.fileExists(atPath: "\(frameworks)/VitaCore.framework/VitaCore") else {
            throw NSError(domain: "PlayTendo", code: 2, userInfo: [NSLocalizedDescriptionKey:
                tr("La PS Vita n'est pas dans cette version de l'app (elle marche sur iPhone, iPad et Mac, pas au simulateur).")])
        }
        Paths.prepareVitaEngine()
        let engine = try PTVitaEngine.load(withFrameworkPath: "\(frameworks)/VitaCore.framework/VitaCore",
                                           storageDirectory: Paths.vitaEngine.path)
        PTLogLine("Vita : moteur chargé (journal du moteur : Application Support/Systeme/Vita/vita3k.log)")
        return engine
    }

    /// PS Vita : installe la première fois le firmware (fichiers .PUP du dossier BIOS : PSVUPDAT.PUP, et les polices
    /// PSP2UPDAT.PUP si elles y sont), puis le jeu dans la mémoire de la console (copié et, pour un jeu du commerce,
    /// déchiffré avec sa licence). Renvoie l'identifiant du jeu à démarrer, ou nil (l'erreur est déjà affichée).
    private func prepareVita(_ vita: PTVitaEngine) -> String? {
        // Vita3K n'a pas d'interpréteur : sans la réserve JIT de l'app, aucun jeu ne peut tourner.
        guard PTJITIsActive() else {
            fail(tr("La PS Vita a besoin du mode turbo : sans lui, aucun jeu ne peut démarrer. Vérifie StikDebug et LocalDevVPN (roue dentée de la bibliothèque), puis relance le jeu."))
            return nil
        }
        let clock = MachClock()
        // Installation coupée la dernière fois (app fermée en plein milieu) : la mémoire de la console est peut-être
        // incomplète tout en se croyant à jour, firmware et polices sont réinstallés (VitaFirmware.installWasInterrupted).
        let interrupted = VitaFirmware.installWasInterrupted
        var needsFirmware = !vita.hasFirmware || interrupted
        var needsFonts = !vita.hasFonts || interrupted
        if needsFirmware || needsFonts {
            if interrupted { PTLogLine("Vita : l'installation du firmware avait été interrompue : elle est refaite") }
            VitaFirmware.setInstallInProgress(true)
            let files = VitaGame.firmwareFiles()
            var tried = Set<URL>()
            let install = { (file: URL) -> Bool in
                tried.insert(file)
                let label = file.lastPathComponent.uppercased().contains("PSP2UPDAT")
                    ? tr("Installation des polices de la PS Vita") : tr("Installation du firmware de la PS Vita")
                self.setLoadingDetail("\(label)…")
                let start = clock.now
                if let version = vita.installFirmware(atPath: file.path, progress: { [weak self] progress in
                    self?.setLoadingDetail("\(label)… \(Int(progress * 100)) %")
                }) {
                    VitaGame.markInstalled(file)
                    PTLogLine(String(format: "Vita : %@ installé (version %@) en %.0f s", file.lastPathComponent, version,
                                     clock.now - start))
                    return true
                }
                PTLogLine("Vita : \(file.lastPathComponent) non installé (\(vita.lastError() ?? "raison inconnue"))")
                return false
            }
            for file in files where needsFirmware && !stopRequestedNow {
                if install(file), vita.hasFirmware { needsFirmware = false }
            }
            // Polices : seulement les .PUP jamais installés (PSVUPDAT.PUP ne les a pas, inutile de le refaire), tous
            // après une installation coupée.
            for file in files where needsFonts && !tried.contains(file) && (interrupted || !VitaGame.wasInstalled(file))
                && !stopRequestedNow {
                if install(file), vita.hasFonts { needsFonts = false }
            }
            // Firmware en place : chaque installation est allée au bout (l'arrêt n'est regardé qu'entre deux). Sinon
            // (arrêt demandé avant, ou .PUP impossible à installer), elle reste à refaire au prochain lancement.
            if !needsFirmware { VitaFirmware.setInstallInProgress(false) }
            if stopRequestedNow {
                finishBeforeStart()
                return nil
            }
            guard !needsFirmware else {
                setLoadingDetail(nil)
                fail(tr("Firmware PS Vita introuvable. Copie le fichier PSVUPDAT.PUP (la mise à jour officielle de la console) dans le dossier BIOS de PlayTendo, avec l'app Fichiers."))
                return nil
            }
            if !vita.hasFonts {
                PTLogLine("Vita : polices de la console absentes (PSP2UPDAT.PUP) : certains jeux peuvent ne pas afficher leurs textes")
            }
        }
        guard let titleID = VitaGame.titleID(of: game.url) else {
            setLoadingDetail(nil)
            fail(tr("Ce jeu PS Vita est illisible : son fichier sce_sys/param.sfo est introuvable."))
            return nil
        }
        // rePatch (mod) : ses fichiers peuvent manquer au jeu à l'installation, puis remplacent ceux du jeu installé.
        let rePatch = VitaGame.rePatchFolder(for: titleID)
        if vita.isGameInstalled(titleID) {
            // Original remis (ou gardé d'avant) alors que le jeu est installé : doublon retiré de Jeux.
            VitaGame.removeOriginal(game.url, titleID: titleID)
            installVitaAddons(vita, titleID: titleID)
            applyVitaRePatch(rePatch, titleID: titleID)
            if stopRequestedNow {
                finishBeforeStart()
                return nil
            }
            setLoadingDetail(nil)
            return titleID
        }
        if stopRequestedNow {
            finishBeforeStart()
            return nil
        }
        setLoadingDetail(tr("Installation du jeu (une seule fois)…"))
        let start = clock.now
        if let rePatch { PTLogLine("Vita : rePatch trouvé pour \(titleID) (\(rePatch.path))") }
        vita.setRePatchDirectory(rePatch?.path)
        let installed = vita.installGame(atPath: game.url.path, progress: { [weak self] progress in
            self?.setLoadingDetail(tr("Installation du jeu (une seule fois)… \(Int(progress * 100)) %"))
        })
        vita.setRePatchDirectory(nil)
        guard let installed else {
            setLoadingDetail(nil)
            fail(vita.lastError().map(trMessage) ?? tr("Le jeu n'a pas pu être installé."))
            return nil
        }
        PTLogLine(String(format: "Vita : jeu %@ installé en %.0f s (%@)", installed, clock.now - start, game.url.lastPathComponent))
        // Le jeu tourne depuis sa copie installée : l'original quitte Jeux (sinon il prendrait deux fois sa place).
        VitaGame.removeOriginal(game.url, titleID: installed)
        installVitaAddons(vita, titleID: installed)
        applyVitaRePatch(rePatch, titleID: installed)
        if stopRequestedNow {
            finishBeforeStart()
            return nil
        }
        setLoadingDetail(nil)
        return installed
    }

    /// rePatch après le jeu et ses mises à jour (il remplace aussi leurs fichiers, comme le plugin sur une Vita).
    private func applyVitaRePatch(_ folder: URL?, titleID: String) {
        guard let folder else { return }
        setLoadingDetail(tr("Application du rePatch…"))
        if VitaGame.applyRePatch(folder, titleID: titleID) == nil {
            showToast(tr("Le rePatch n'a pas pu être appliqué (voir le Journal)"))
        }
    }

    /// DLC et mise à jour du jeu rangés dans Jeux : installés dans la mémoire de la console (la mise à jour d'abord),
    /// puis leur original quitte Jeux, comme pour un jeu. Un échec (licence work.bin absente…) n'empêche pas de jouer :
    /// il est noté au Journal et l'original reste dans Jeux.
    private func installVitaAddons(_ vita: PTVitaEngine, titleID: String) {
        var failed = 0
        // Arrêt demandé (écran de chargement) : les suivants attendront le prochain lancement.
        for addon in VitaGame.pendingAddons(for: titleID) where !stopRequestedNow {
            // Mise à jour déjà dans le jeu installé (même version ou plus récente) : rien à réinstaller.
            if addon.isInstalled {
                VitaGame.removeInstalledUpdate(addon)
                continue
            }
            let label = addon.kind == .update ? tr("Installation de la mise à jour \(addon.label)…")
                : tr("Installation du DLC « \(addon.label) »…")
            let what = addon.kind == .update ? "mise à jour \(addon.label)" : "DLC « \(addon.label) »"
            setLoadingDetail(label)
            let clock = MachClock()
            let start = clock.now
            guard vita.installGame(atPath: addon.url.path, progress: { [weak self] progress in
                self?.setLoadingDetail("\(label) \(Int(progress * 100)) %")
            }) != nil else {
                failed += 1
                PTLogLine("Vita : \(what) de \(titleID) non installé(e) (\(vita.lastError() ?? "raison inconnue")) ; original gardé dans Jeux")
                continue
            }
            PTLogLine(String(format: "Vita : %@ de %@ installé(e) en %.0f s (%@)", what, titleID, clock.now - start,
                             addon.url.lastPathComponent))
            if addon.kind == .update {
                // Vita3K l'a fusionnée dans le jeu installé : vérifié par la version, puis l'original quitte Jeux.
                if addon.isInstalled {
                    VitaGame.removeInstalledUpdate(addon)
                } else {
                    PTLogLine("Vita : mise à jour \(addon.label) absente du jeu installé après l'installation ; original gardé dans Jeux")
                }
            } else if let installedURL = addon.installedURL {
                VitaGame.removeOriginal(addon.url, installedAt: installedURL, kept: "le DLC reste installé")
            }
        }
        if failed > 0 {
            showToast(failed == 1 ? tr("Un DLC ou une mise à jour n'a pas pu être installé (voir le Journal)")
                                  : tr("\(failed) DLC ou mises à jour n'ont pas pu être installés (voir le Journal)"))
        }
    }
#endif

    private func setLoadingDetail(_ text: String?) {
        DispatchQueue.main.async { self.loadingDetail = text }
    }

    /// Arrêt demandé pendant le chargement (bouton « Quitter le jeu » de l'écran de chargement) : regardé entre deux
    /// étapes d'un long démarrage (installation PS Vita), qu'on ne peut pas couper au milieu.
    private var stopRequestedNow: Bool {
        condition.lock()
        defer { condition.unlock() }
        return stopRequested
    }

    /// Partie fermée avant d'avoir démarré : retour à la bibliothèque, sans message d'erreur.
    private func finishBeforeStart() {
        PTLogLine("\(game.system.shortName) : jeu fermé pendant le chargement")
        setLoadingDetail(nil)
        DispatchQueue.main.async {
            self.state = .stopped
            self.finishStop()
        }
    }

    /// GameCube/Wii : vérifie la place du recompilateur et règle l'image avant le démarrage. Faux si le jeu ne peut pas
    /// démarrer (l'erreur est déjà affichée).
    private func prepareDolphin(_ engine: ExternalEngine) -> Bool {
        PTLogLine("\(game.system.shortName) : lancement de \(game.url.lastPathComponent)")
#if os(iOS)
        // Le recompilateur de Dolphin prend 256 Mo d'un seul tenant (TOTAL_CODE_SIZE, JitArm64/Jit.cpp) : sans
        // cette place, il écrirait son code dans le vide et l'app planterait. (Mac : Dolphin prend sa mémoire
        // exécutable lui-même, hors de la réserve.)
        if PTJITIsActive() && PTJITLargestFree() < 256 << 20 {
            fail(tr("La \(game.system.name) ne peut pas démarrer : \(Self.jitFullMessage)"))
            return false
        }
#endif
        Self.applyDolphinImage(to: engine as? PTDolphinEngine, system: game.system)
        return true
    }

#if PLAYTENDO_VITA
    /// PS Vita : installe ce qu'il faut puis règle la résolution. Renvoie l'identifiant du jeu à démarrer, ou nil.
    private func vitaBootTitle(_ vita: PTVitaEngine) -> String? {
        PTLogLine("Vita : lancement de \(game.url.lastPathComponent)")
        guard let titleID = prepareVita(vita) else { return nil }
        let resolution = VitaSettings.resolution
        vita.setResolution(Float(resolution.rawValue))
        PTLogLine("Vita : résolution \(resolution.label) (\(resolution.size))")
        DispatchQueue.main.async { self.vitaResolution = resolution }
        return titleID
    }
#endif

    /// Pilote une partie PS2, GameCube/Wii ou PS Vita : démarrage, pause, commandes du menu et arrêt. Le moteur a ses
    /// propres threads ; celui-ci se contente de suivre son état et de lui passer les commandes.
    private func runExternal(_ engine: ExternalEngine) {
        let name = game.system.shortName
#if PLAYTENDO_VITA
        // Ce que le moteur démarre : le fichier du jeu, ou l'identifiant d'un jeu PS Vita installé.
        var bootPath = game.url.path
#else
        let bootPath = game.url.path
#endif
        if let ps2 = engine as? PTPS2Engine {
            guard let bios = ps2.pickBIOS() else {
#if os(iOS)
                fail(tr("Aucun BIOS PS2 trouvé. Importe celui de ta PS2 dans Réglages (roue dentée) › BIOS PS2, ou copie-le (fichier .bin de 4 Mo, « SCPH-… ») dans le dossier BIOS de PlayTendo avec l'app Fichiers."))
#else
                fail(tr("Aucun BIOS PS2 trouvé. Importe celui de ta PS2 dans Réglages › BIOS PS2, ou copie-le (fichier .bin de 4 Mo, « SCPH-… ») dans le dossier BIOS de PlayTendo (Réglages › Dossiers)."))
#endif
                return
            }
            PTLogLine("PS2 : lancement de \(game.url.lastPathComponent) avec le BIOS \(bios)")
            Self.applyPS2Image(to: ps2)
        } else {
            releasePS2Memory()
#if PLAYTENDO_VITA
            if let vita = engine as? PTVitaEngine {
                guard let titleID = vitaBootTitle(vita) else { return }
                bootPath = titleID
            } else if !prepareDolphin(engine) {
                return
            }
#else
            guard prepareDolphin(engine) else { return }
#endif
        }

        // Fermé pendant la préparation (bouton « Quitter le jeu » de l'écran de chargement).
        if stopRequestedNow {
            finishBeforeStart()
            return
        }
        // La vue Metal doit être à l'écran, à sa taille, avant le démarrage : le moteur y crée son image.
        let clock = MachClock()
        let viewDeadline = clock.now + 3
        while clock.now < viewDeadline,
              !DispatchQueue.main.sync(execute: { engine.renderView.window != nil && engine.renderView.bounds.width > 0 }) {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let jitFailures = PTJITFailureCount()
        // RetroAchievements (PS2, GameCube, Wii), branché avant le démarrage : la PS2 donne son jeu dès qu'elle l'a lu.
        let achievementConsole = PTAchievements.console(forSystem: name)
        if achievementConsole != 0, PTAchievements.shared.loggedIn {
            startExternalAchievements(engine, console: achievementConsole)
        }
        // Reprise automatique (pas de PS Vita : pas de sauvegarde rapide) : de préférence, la console démarre directement
        // dessus, sans logo ni son de démarrage ; sinon (moteur d'avant), elle est chargée quelques secondes après.
        // Pas en Hardcore (reprendre une partie sauvegardée y est interdit).
        let resumeFile = Paths.resumeFile(for: game)
        let hardcoreWanted = achievementsOn && PTAchievements.shared.hardcore
        if hardcoreWanted && FileManager.default.fileExists(atPath: resumeFile.path) {
            PTLogLine("\(name) : reprise automatique ignorée (Hardcore, RetroAchievements)")
        }
        let hasResume = !game.system.isVita && !hardcoreWanted && FileManager.default.fileExists(atPath: resumeFile.path)
        let resumedAtBoot = engine.prepareBoot(resume: hasResume ? resumeFile.path : nil)
        // Jeu en plusieurs disques (GameCube) : le moteur les reçoit tous, et passe au suivant quand le jeu le demande.
        let booted = game.discs.count > 1 ? engine.boot(discs: game.discs.map(\.path), jit: PTJITIsActive())
                                          : engine.boot(path: bootPath, jit: PTJITIsActive())
        guard booted else {
            if achievementsOn { stopExternalAchievements(engine) }
            fail(engine.lastError().map(trMessage) ?? tr("Le jeu n'a pas pu démarrer."))
            return
        }

        let bootStart = clock.now
        var started = false       // le jeu a tourné au moins une fois
        var seenActivity = false  // le thread de la console a pris la demande
        var enginePaused = false
        var failure: String?
        var aspect: CGFloat = 4.0 / 3.0
        var shownDisc: Int?
        var resumeAt: Double?     // reprise automatique à charger à ce moment-là
        var cheatsAt: Double?     // codes de triche à donner à ce moment-là

        while true {
            condition.lock()
            if pendingCommands.isEmpty && !stopRequested {
                _ = condition.wait(until: Date().addingTimeInterval(0.1))
            }
            let commands = pendingCommands
            pendingCommands.removeAll()
            let stop = stopRequested
            let paused = pauseRequested
            condition.unlock()

            for command in commands { command() }
            if stop { break }

            let engineState = engine.engineState
            if engineState != .stopped { seenActivity = true }
            if !started {
                if engineState == .running || engineState == .paused {
                    started = true
                    PTLogLine(String(format: "%@ : jeu démarré en %.1f s", name, clock.now - bootStart))
                    // Recompilateur sans place dans la réserve (la PS2 passe alors à l'interpréteur, injouable) :
                    // arrêté, avec le moyen d'y remédier.
                    if PTJITIsActive() && PTJITFailureCount() != jitFailures {
                        failure = Self.jitFullMessage
                        break
                    }
                    let jit = PTJITIsActive()
#if targetEnvironment(simulator)
                    PTLogLine(jit ? "\(name) : code dans la réserve JIT de l'app" : "\(name) : sans la réserve JIT de l'app")
#else
                    PTLogLine(jit ? "\(name) : mode turbo (JIT) utilisé" : "\(name) : sans JIT, interpréteur (très lent)")
#endif
#if os(iOS)
                    if jit { showToast(tr("Mode turbo (JIT) actif")) }
#endif
                    // Reprise automatique (PS2, GameCube, Wii ; la PS Vita n'a pas de sauvegarde rapide) : chargée
                    // quelques secondes après le démarrage, console allumée, derrière l'écran de chargement. Chargée
                    // tout de suite, la PS2 restait sur un écran noir avec le son (son affichage venait d'ouvrir).
                    if resumedAtBoot {
                        if engine.resumeLoaded == false {
                            PTLogLine("\(name) : reprise automatique illisible, jeu démarré du début")
                            showToast(tr("Reprise impossible : le jeu démarre du début"))
                        } else {
                            PTLogLine("\(name) : démarré directement sur la reprise automatique")
                            showToast(tr("Partie reprise"))
                        }
                        DispatchQueue.main.async { self.state = .running }
                    } else if hasResume {
                        resumeAt = clock.now + (game.system == .ps2 ? 4 : 2)
                        setLoadingDetail(tr("Reprise de la partie…"))
                    } else {
                        DispatchQueue.main.async { self.state = .running }
                    }
                } else if engineState == .stopped && (seenActivity || clock.now - bootStart > 20) {
                    failure = engine.lastError().map(trMessage) ?? tr("La console n'a pas pu démarrer le jeu.")
                    break
                }
                continue
            }
            if engineState == .stopped {
                failure = engine.lastError().map(trMessage) ?? tr("La console s'est arrêtée.")
                break
            }
            if let at = resumeAt, clock.now >= at {
                resumeAt = nil
                if engine.loadState(fromPath: Paths.resumeFile(for: game).path) {
                    PTLogLine("\(name) : reprise automatique chargée")
                    showToast(tr("Partie reprise"))
                } else {
                    PTLogLine("\(name) : reprise automatique illisible (\(engine.lastError() ?? "raison inconnue")), jeu démarré du début")
                    showToast(tr("Reprise impossible : le jeu démarre du début"))
                }
                setLoadingDetail(nil)
                DispatchQueue.main.async { self.state = .running }
            }
            // Codes de triche : donnés 3 s après le démarrage (ou après Recommencer), le moteur connaît alors le jeu ;
            // ensuite à chaque changement (setCheats). PS2 sans code : rien à écrire. GameCube, Wii : toujours, ce qui
            // remplace les codes que Dolphin active d'office pour certains jeux.
            if !cheatsSent && cheatsAt == nil && Cheats.supported(game.system) {
                cheatsAt = clock.now + 3
            }
            if let at = cheatsAt, clock.now >= at {
                cheatsAt = nil
                cheatsSent = true
                if game.system != .ps2 || !cheatList.isEmpty {
                    engine.applyCheats(cheatList, system: game.system)
                    PTLogLine("\(name) : \(cheatList.filter(\.enabled).count) code(s) de triche actif(s)")
                }
            }
            if paused != enginePaused {
                // Image de la vignette « Continuer » prise juste avant la pause (GameCube/Wii : en marche seulement).
                if paused { engine.prepareSnapshot() }
                engine.setPaused(paused)
                enginePaused = paused
            }
            // Format de l'image (16:9 dans la plupart des jeux Wii) : l'écran de jeu prend la bonne place.
            if let ratio = engine.imageAspectRatio, abs(ratio - aspect) > 0.01 {
                aspect = ratio
                PTLogLine(String(format: "%@ : image au format %.2f", name, ratio))
                DispatchQueue.main.async { self.aspectRatio = ratio }
            }
            // Disque en cours (le moteur en change tout seul quand le jeu le demande) : menu pause › DISQUE.
            if let disc = engine.currentDisc, disc != shownDisc {
                let info = DiskInfo(current: disc + 1, count: game.discs.count)
                PTLogLine("\(name) : disque \(info.current)/\(info.count)")
                if shownDisc != nil { showToast(tr("Disque \(info.current) inséré")) }
                shownDisc = disc
                DispatchQueue.main.async { self.diskInfo = info }
            }
        }

        if started && failure == nil {
            saveEngineThumbnail(engine)
            if !game.system.isVita {
                let resume = Paths.resumeFile(for: game)
                if engine.saveState(toPath: resume.path) {
                    PTLogLine("\(name) : reprise automatique gardée")
                } else {
                    PTLogLine("\(name) : reprise automatique impossible (\(engine.lastError() ?? "raison inconnue"))")
                }
            }
        }
        if achievementsOn { stopExternalAchievements(engine) }
        engine.stop()
        let stopDeadline = clock.now + 15
        while engine.engineState != .stopped && clock.now < stopDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if engine.engineState != .stopped { PTLogLine("\(name) : la console ne s'est pas arrêtée à temps") }
        if let failure {
            PTLogLine("\(name) : \(failure)")
            fail(tr("La \(game.system.name) s'est arrêtée : \(failure)"))
            return
        }
        PTLogLine("\(name) : jeu fermé")
        DispatchQueue.main.async {
            self.state = .stopped
            self.finishStop()
        }
    }

    private func persistSaveRAM() {
        guard let data = core?.saveRAM(), data != lastSavedRAM else { return }
        do {
            try data.write(to: Paths.saveRAMFile(for: game), options: .atomic)
            lastSavedRAM = data
        } catch {
            PTLogLine("Écriture de la sauvegarde impossible : \(error.localizedDescription)")
        }
    }

    private func saveThumbnail() {
        guard let snapshot = frameBuffer.snapshotRGBA(),
              let provider = CGDataProvider(data: snapshot.data as CFData),
              let image = CGImage(width: snapshot.width, height: snapshot.height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: snapshot.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return }
        writeThumbnail(image)
    }

    /// PS2, GameCube/Wii : le moteur dessine lui-même, l'image vient de sa capture.
    private func saveEngineThumbnail(_ engine: ExternalEngine) {
        guard let image = engine.snapshot() else {
            PTLogLine("\(game.system.shortName) : vignette impossible à capturer")
            return
        }
        guard let cgImage = image.cgImageValue else { return }
        writeThumbnail(cgImage)
    }

    private func writeThumbnail(_ image: CGImage) {
        guard let png = ImageCoding.png(image) else { return }
        try? png.write(to: Paths.thumbnailFile(for: game), options: .atomic)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .thumbnailUpdated, object: self.game.id)
        }
    }
}

extension Notification.Name {
    static let thumbnailUpdated = Notification.Name("PlayTendoThumbnailUpdated")
}

/// Horloge précise basée sur mach_absolute_time.
struct MachClock {
    private let numer: Double
    private let denom: Double

    init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        numer = Double(info.numer)
        denom = Double(info.denom)
    }

    var now: Double {
        Double(mach_absolute_time()) * numer / denom / 1e9
    }

    func sleep(until time: Double) {
        let ticks = time * 1e9 * denom / numer
        guard ticks.isFinite, ticks > 0, ticks < Double(UInt64.max) else { return }
        mach_wait_until(UInt64(ticks))
    }
}

/// Photos de la partie pour le retour en arrière : environ 30 secondes, au plus 128 Mo. L'écart entre deux photos est
/// choisi à la première, d'après sa taille : NES, Game Boy, toutes les 2 images ; PS1, N64, bien plus espacées (le
/// retour se fait alors par à-coups).
struct RewindBuffer {
    private(set) var interval = 2
    private var capacity = 900
    private var states: [Data] = []
    private var sized = false

    private static let seconds = 30
    private static let budget = 128 << 20

    mutating func push(_ state: Data) {
        if !sized {
            sized = true
            let frames = Self.seconds * 60
            let maxStates = max(8, Self.budget / max(state.count, 1))
            interval = max(2, Int((Double(frames) / Double(maxStates)).rounded(.up)))
            capacity = min(maxStates, frames / interval)
            PTLogLine("Retour en arrière : une photo de \(state.count / 1024) Ko toutes les \(interval) images, \(capacity) gardées")
        }
        states.append(state)
        if states.count > capacity { states.removeFirst(states.count - capacity) }
    }

    mutating func popLast() -> Data? { states.popLast() }
}
