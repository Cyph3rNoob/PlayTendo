import Foundation
import UIKit

/// Fait tourner un jeu : charge le moteur, cadence les images, le son et gère les sauvegardes.
/// Le moteur vit sur son propre thread ; l'interface lui envoie des commandes.
/// La PS2 et la GameCube/Wii ont leur propre moteur (`ExternalEngine`) qui cadence, dessine et joue le son
/// lui-même : la session le pilote seulement (voir `runExternal`).
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
    @Published var toast: String?
    /// PS2, GameCube/Wii : vue Metal où le moteur dessine, placée par l'écran de jeu.
    @Published private(set) var engineView: UIView?

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
    private var lastSavedRAM: Data?
    /// N64 : moteur à recharger à la reprise (réglages d'image lus seulement au démarrage d'un jeu).
    private var coreReloadRequested = false

    init(game: Game) {
        self.game = game
        ring = PTAudioRingCreate(48_000)
        hasSaveState = FileManager.default.fileExists(atPath: Paths.stateFile(for: game).path)
    }

    deinit {
        PTAudioRingDestroy(ring)
    }

    // MARK: Commandes (thread principal)

    func start() {
        guard thread == nil else { return }
        var external: ExternalEngine?
        do {
            switch game.system {
            case .ps2: external = try Self.loadPS2Engine()
            case .gameCube, .wii: external = try Self.loadDolphinEngine()
            default: break
            }
        } catch {
            fail(error.localizedDescription)
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
        perform { [self] in persistSaveRAM() }
    }

    func resume() {
        guard state == .paused else { return }
        condition.lock()
        pauseRequested = false
        condition.signal()
        condition.unlock()
        state = .running
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

    /// PS2 : applique la résolution et le lissage choisis dans le menu pause (PS2Settings).
    func applyPS2Image() {
        perform { [self] in Self.applyPS2Image(to: external as? PTPS2Engine) }
    }

    private static func applyPS2Image(to engine: PTPS2Engine?) {
        engine?.setImageUpscale(PS2Settings.resolution.rawValue, smoothing: PS2Settings.smoothing == .on)
    }

    /// Réglages que le moteur ne lit qu'au démarrage du jeu (image N64) : à la reprise, le moteur est rechargé avec
    /// eux, la partie étant gardée par une sauvegarde rapide.
    func requestCoreReload() {
        perform { [self] in coreReloadRequested = true }
    }

    /// GameCube/Wii : applique la résolution et le lissage choisis dans le menu pause (DolphinSettings).
    func applyDolphinImage() {
        perform { [self] in Self.applyDolphinImage(to: external as? PTDolphinEngine) }
    }

    private static func applyDolphinImage(to engine: PTDolphinEngine?) {
        engine?.setImageScale(Int32(DolphinSettings.resolution.rawValue), smoothing: DolphinSettings.smoothing == .on)
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
                    saveEngineThumbnail(external)
                    DispatchQueue.main.async { self.hasSaveState = true }
                    showToast("Partie sauvegardée")
                } else {
                    PTLogLine("\(game.system.shortName) : sauvegarde rapide impossible (\(external.lastError() ?? "raison inconnue"))")
                    showToast("Échec de la sauvegarde")
                }
            }
            return
        }
        perform { [self] in
            guard let data = core?.saveState() else {
                showToast("Ce jeu ne permet pas la sauvegarde rapide")
                return
            }
            do {
                let packed = Self.packState(data)
                try packed.write(to: Paths.stateFile(for: game), options: .atomic)
                PTLogLine(packed.count == data.count ? "Sauvegarde rapide : \(data.count / 1024) Ko (gardée brute)"
                          : "Sauvegarde rapide : \(data.count / 1024) Ko, \(packed.count / 1024) Ko une fois compressée")
                saveThumbnail()
                DispatchQueue.main.async { self.hasSaveState = true }
                showToast("Partie sauvegardée")
            } catch {
                showToast("Échec de la sauvegarde")
            }
        }
    }

    func loadState() {
        if let external {
            perform { [self] in
                if external.loadState(fromPath: Paths.stateFile(for: game).path) {
                    PTLogLine("\(game.system.shortName) : sauvegarde rapide chargée")
                    showToast("Sauvegarde chargée")
                } else {
                    PTLogLine("\(game.system.shortName) : chargement impossible (\(external.lastError() ?? "raison inconnue"))")
                    showToast("Impossible de charger la sauvegarde")
                }
            }
            return
        }
        perform { [self] in
            guard let file = try? Data(contentsOf: Paths.stateFile(for: game)),
                  let data = Self.unpackState(file),
                  core?.loadState(data) == true else {
                PTLogLine("Sauvegarde rapide illisible")
                showToast("Impossible de charger la sauvegarde")
                return
            }
            PTLogLine("Sauvegarde rapide chargée (\(file.starts(with: Self.compressedStateMagic) ? "compressée" : "brute"))")
            showToast("Sauvegarde chargée")
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

    func toggleFastForward() {
        isFastForwarding.toggle()
        let enabled = isFastForwarding
        perform { [self] in
            fastForward = enabled
            external?.setTurbo(enabled)
        }
    }

    func nextDisk() {
        perform { [self] in
            guard let core, core.switchToNextDisk() else { return }
            let info = DiskInfo(current: Int(core.currentDiskIndex) + 1, count: Int(core.diskCount))
            DispatchQueue.main.async { self.diskInfo = info }
            showToast("Disque \(info.current) inséré")
        }
    }

    // MARK: Entrées (n'importe quel thread)

    func setButton(_ button: PTButton, pressed: Bool, port: UInt32 = 0) {
        if let external {
            external.setButton(button.rawValue, pressed: pressed)
            return
        }
        core?.setButton(button, pressed: pressed, port: port)
    }

    func setAnalog(stick: UInt32, x: Float, y: Float, port: UInt32 = 0) {
        if let external {
            external.setStick(Int32(stick), x: max(-1, min(1, x)), y: max(-1, min(1, y)))
            return
        }
        core?.setAnalogStick(stick, x: Self.axis(x), y: Self.axis(y), port: port)
    }

    /// Position normalisée (0…1) dans l'image du jeu. Wiimote : le pointeur reste où le doigt l'a laissé.
    func setPointer(x: CGFloat, y: CGFloat, pressed: Bool) {
        if let external {
            (external as? PTDolphinEngine)?.setPointerX(Float(x * 2 - 1), y: Float(y * 2 - 1))
            return
        }
        let px = Int16(max(-32767, min(32767, (x * 2 - 1) * 32767)))
        let py = Int16(max(-32767, min(32767, (y * 2 - 1) * 32767)))
        core?.setPointerX(px, y: py, pressed: pressed)
    }

    func clearInput() {
        if let external {
            for button in 0..<16 { external.setButton(button, pressed: false) }
            external.setStick(0, x: 0, y: 0)
            external.setStick(1, x: 0, y: 0)
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
            self.toast = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                if self.toast == text { self.toast = nil }
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
        let handlers = stopHandlers
        stopHandlers.removeAll()
        handlers.forEach { $0() }
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
            fail("Moteurs introuvables dans l'app.")
            return
        }
        let corePath = "\(frameworks)/\(system.coreName).framework/\(system.coreName)"

        var core: PTCore
        do {
            core = try loadCore(path: corePath)
        } catch {
            fail(error.localizedDescription)
            return
        }

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
            if jit { showToast("Mode turbo (JIT) actif") }
        }

        let clock = MachClock()
        let audioTarget = core.sampleRate * 0.05 // 50 ms de son d'avance
        // Démarre avec un peu d'avance pour remplir le tampon audio.
        var deadline = clock.now - 0.05
        var lastAutoSave = clock.now
        var clockReset = false
        var wasPaused = false

        while true {
            condition.lock()
            while pauseRequested && !stopRequested && pendingCommands.isEmpty {
                condition.wait()
            }
            let commands = pendingCommands
            pendingCommands.removeAll()
            let stop = stopRequested
            let paused = pauseRequested
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
                        audio.stop()
                        self.audio = nil
                        self.core = nil
                        fail("Le jeu n'a pas pu redémarrer avec les nouveaux réglages d'image.")
                        return
                    }
                    core = reloaded
                }
                deadline = clock.now - 0.05
            }

            let steps = fastForward ? 3 : 1
            for _ in 0..<steps { core.runFrame() }
            if core.shutdownRequested { break }

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
            } else if now - deadline > 0.25 {
                deadline = now
            }

            if now - lastAutoSave > 30 {
                persistSaveRAM()
                lastAutoSave = now
            }
        }

        persistSaveRAM()
        saveThumbnail()
        core.unloadGame()
        audio.stop()
        self.audio = nil
        self.core = nil
        DispatchQueue.main.async {
            self.state = .stopped
            self.finishStop()
        }
    }

    /// Charge le moteur libretro et le jeu (thread d'émulation), avec la mémoire de sauvegarde de la cartouche.
    private func loadCore(path: String) throws -> PTCore {
        let system = game.system
        let core = try PTCore(libraryPath: path)
        core.allowsJIT = JITManager.benefits(system)
        core.prefersVulkan = system == .n3ds
        let frameBuffer = self.frameBuffer
        let ring = self.ring
        core.videoHandler = { pixels, width, height, pitch, format in
            frameBuffer.store(pixels, width: Int(width), height: Int(height), pitch: pitch, format: format)
        }
        core.hardwareVideoHandler = { buffer, width, height, flipped in
            frameBuffer.storeHardware(buffer, width: Int(width), height: Int(height), flipped: flipped)
        }
        core.audioHandler = { [unowned self] samples, frames in
            if !self.fastForward { PTAudioRingWrite(ring, samples, frames) }
        }

        condition.lock()
        let options = system.coreOptions.merging(optionOverrides) { $1 }
        condition.unlock()
        try core.loadGame(atPath: game.url.path,
                          systemDirectory: Paths.systemDirectory(for: system).path,
                          saveDirectory: Paths.coreSaveDirectory(for: system).path,
                          options: options)
        self.core = core

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
            if let state, !core.loadState(state) {
                PTLogLine("Rechargement du moteur : la partie n'a pas pu être reprise")
            }
            PTLogLine(String(format: "Moteur rechargé avec les nouveaux réglages d'image en %.1f s", clock.now - start))
            showToast("Image appliquée")
            return core
        } catch {
            PTLogLine("Rechargement du moteur impossible : \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Moteurs autonomes (PS2, GameCube/Wii)

    /// Charge le moteur PS2 à la première partie PS2 (thread principal), puis le garde.
    private static func loadPS2Engine() throws -> PTPS2Engine {
        if let engine = PTPS2Engine.loaded { return engine }
        guard let frameworks = Bundle.main.privateFrameworksPath else {
            throw NSError(domain: "PlayTendo", code: 2, userInfo: [NSLocalizedDescriptionKey: "Moteurs introuvables dans l'app."])
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
            throw NSError(domain: "PlayTendo", code: 2, userInfo: [NSLocalizedDescriptionKey: "Moteurs introuvables dans l'app."])
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

    /// Pilote une partie PS2 ou GameCube/Wii : démarrage, pause, commandes du menu et arrêt. Le moteur a ses
    /// propres threads ; celui-ci se contente de suivre son état et de lui passer les commandes.
    private func runExternal(_ engine: ExternalEngine) {
        let name = game.system.shortName
        if let ps2 = engine as? PTPS2Engine {
            guard let bios = ps2.pickBIOS() else {
                fail("Aucun BIOS PS2 trouvé. Copie le BIOS de ta PS2 (fichier .bin de 4 Mo, « SCPH-… ») dans le dossier "
                     + "BIOS de PlayTendo, avec l'app Fichiers.")
                return
            }
            PTLogLine("PS2 : lancement de \(game.url.lastPathComponent) avec le BIOS \(bios)")
            Self.applyPS2Image(to: ps2)
        } else {
            releasePS2Memory()
            PTLogLine("\(name) : lancement de \(game.url.lastPathComponent)")
            Self.applyDolphinImage(to: engine as? PTDolphinEngine)
        }

        // La vue Metal doit être à l'écran, à sa taille, avant le démarrage : le moteur y crée son image.
        let clock = MachClock()
        let viewDeadline = clock.now + 3
        while clock.now < viewDeadline,
              !DispatchQueue.main.sync(execute: { engine.renderView.window != nil && engine.renderView.bounds.width > 0 }) {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard engine.boot(path: game.url.path, jit: PTJITIsActive()) else {
            fail(engine.lastError() ?? "Le jeu n'a pas pu démarrer.")
            return
        }

        let bootStart = clock.now
        var started = false       // le jeu a tourné au moins une fois
        var seenActivity = false  // le thread de la console a pris la demande
        var enginePaused = false
        var failure: String?
        var aspect: CGFloat = 4.0 / 3.0

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
                    let jit = PTJITIsActive()
#if targetEnvironment(simulator)
                    PTLogLine(jit ? "\(name) : code dans la réserve JIT de l'app" : "\(name) : sans la réserve JIT de l'app")
#else
                    PTLogLine(jit ? "\(name) : mode turbo (JIT) utilisé" : "\(name) : sans JIT, interpréteur (très lent)")
#endif
                    if jit { showToast("Mode turbo (JIT) actif") }
                    DispatchQueue.main.async { self.state = .running }
                } else if engineState == .stopped && (seenActivity || clock.now - bootStart > 20) {
                    failure = engine.lastError() ?? "La console n'a pas pu démarrer le jeu."
                    break
                }
                continue
            }
            if engineState == .stopped {
                failure = engine.lastError() ?? "La console s'est arrêtée."
                break
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
        }

        if started && failure == nil { saveEngineThumbnail(engine) }
        engine.stop()
        let stopDeadline = clock.now + 15
        while engine.engineState != .stopped && clock.now < stopDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if engine.engineState != .stopped { PTLogLine("\(name) : la console ne s'est pas arrêtée à temps") }
        if let failure {
            PTLogLine("\(name) : \(failure)")
            fail("La \(game.system.name) s'est arrêtée : \(failure)")
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
        writeThumbnail(UIImage(cgImage: image))
    }

    /// PS2, GameCube/Wii : le moteur dessine lui-même, l'image vient de sa capture.
    private func saveEngineThumbnail(_ engine: ExternalEngine) {
        guard let image = engine.snapshot() else {
            PTLogLine("\(game.system.shortName) : vignette impossible à capturer")
            return
        }
        writeThumbnail(image)
    }

    private func writeThumbnail(_ image: UIImage) {
        guard let png = image.pngData() else { return }
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
