import SwiftUI

/// État d'un moteur autonome.
enum ExternalEngineState {
    case stopped, starting, running, paused
}

/// Moteur qui cadence, dessine et joue le son lui-même (PS2, GameCube/Wii, PS Vita) : la session le pilote seulement
/// (`EmulatorSession.runExternal`). Chargé à la première partie, gardé jusqu'à la fermeture de l'app.
protocol ExternalEngine: AnyObject {
    var renderView: PlatformView { get }
    var engineState: ExternalEngineState { get }
    /// Démarre le jeu. `jit` : la réserve JIT de l'app est prête.
    func boot(path: String, jit: Bool) -> Bool
    func setPaused(_ paused: Bool)
    func stop()
    func reset()
    func setTurbo(_ enabled: Bool)
    /// Bouton RetroPad (PTButton).
    func setButton(_ button: Int, pressed: Bool)
    func setStick(_ stick: Int32, x: Float, y: Float)
    /// Sauvegarde et chargement rapides : bloquants, hors du thread principal.
    func saveState(toPath path: String) -> Bool
    func loadState(fromPath path: String) -> Bool
    func lastError() -> String?
    /// Image du jeu pour la vignette « Continuer » (bloquant), ou nil.
    func snapshot() -> PlatformImage?
    /// Appelé juste avant chaque mise en pause, jeu encore en marche (bloquant, court).
    func prepareSnapshot()
    /// Format de l'image du jeu (largeur / hauteur) s'il est connu ; nil : 4:3.
    var imageAspectRatio: CGFloat? { get }
    /// Démarre un jeu en plusieurs disques (le premier, les autres prêts à être changés).
    func boot(discs: [String], jit: Bool) -> Bool
    /// Disque en cours (à partir de 0) d'un jeu démarré avec plusieurs disques, sinon nil.
    var currentDisc: Int? { get }
    /// Met le disque `index` du jeu démarré par `boot(discs:jit:)`. Faux si le moteur ne sait pas.
    func changeDisc(to index: Int) -> Bool
    /// Reprise automatique : le prochain démarrage commence directement sur cette partie (ni logo ni son de démarrage).
    /// Faux si le moteur ne sait pas (la partie est alors chargée quelques secondes après le démarrage).
    func prepareBoot(resume: String?) -> Bool
    /// Après un démarrage sur une reprise : vrai si elle a été chargée, faux si elle était illisible, nil si on ne
    /// sait pas.
    var resumeLoaded: Bool? { get }
    /// Codes de triche du jeu en cours (PS2, GameCube, Wii), appliqués tout de suite. Jeu démarré.
    func applyCheats(_ cheats: [Cheat], system: GameSystem)
}

/// Moteurs sans changement de disque : le premier disque seulement.
extension ExternalEngine {
    func boot(discs: [String], jit: Bool) -> Bool { boot(path: discs[0], jit: jit) }
    var currentDisc: Int? { nil }
    func changeDisc(to index: Int) -> Bool { false }
    func prepareBoot(resume: String?) -> Bool { false }
    var resumeLoaded: Bool? { nil }
    func applyCheats(_ cheats: [Cheat], system: GameSystem) {}
}

extension PTPS2Engine: ExternalEngine {
    var engineState: ExternalEngineState {
        switch state {
        case PTPS2StateRunning: .running
        case PTPS2StatePaused: .paused
        case PTPS2StateStarting: .starting
        default: .stopped
        }
    }

    func boot(path: String, jit: Bool) -> Bool { bootGame(atPath: path) }

    /// Codes de triche : fichier .pnach du jeu (gardé par le moteur pour ses prochains lancements).
    func applyCheats(_ cheats: [Cheat], system: GameSystem) {
        setCheats(Cheats.pnach(for: cheats))
    }

    /// Le démarrage rapide (sans le logo PS2, Réglages) est réglé à chaque démarrage, avec ou sans reprise.
    func prepareBoot(resume: String?) -> Bool {
        setBootState(resume, fastBoot: PS2Settings.fastBoot) && resume != nil
    }

    var resumeLoaded: Bool? {
        switch bootStateResult {
        case 1: true
        case 0: false
        default: nil
        }
    }

    /// La PS2 capture son image même en pause (`snapshot`).
    func prepareSnapshot() {}

    /// 4:3, ou 16:9 quand un correctif écran large est actif (FORMAT du menu pause).
    var imageAspectRatio: CGFloat? {
        let ratio = aspectRatio
        return ratio > 0.5 && ratio < 4 ? CGFloat(ratio) : nil
    }
}

extension PTDolphinEngine: ExternalEngine {
    /// Codes de triche Action Replay et Gecko, remplacés tout de suite.
    func applyCheats(_ cheats: [Cheat], system: GameSystem) {
        let codes = Cheats.dolphin(for: cheats, system: system)
        setCheatsActionReplay(codes.actionReplay, gecko: codes.gecko)
    }

    var engineState: ExternalEngineState {
        switch state {
        case PTDolphinStateRunning: .running
        case PTDolphinStatePaused: .paused
        case PTDolphinStateStarting: .starting
        default: .stopped
        }
    }

    /// Dolphin ne capture une image qu'en marche : elle est prise juste avant chaque pause (menu, arrière-plan),
    /// puis sert à la sauvegarde rapide ou en quittant (toujours faites depuis le menu pause).
    private static let captureURL = FileManager.default.temporaryDirectory.appendingPathComponent("PlayTendo-capture-GC-Wii.png")

    func boot(path: String, jit: Bool) -> Bool {
        try? FileManager.default.removeItem(at: Self.captureURL)
        return bootGame(atPath: path, jit: jit)
    }

    /// GameCube en plusieurs disques : Dolphin passe tout seul au suivant quand le jeu le demande. Moteur d'avant
    /// (sans cette fonction) : le premier disque seulement.
    func boot(discs: [String], jit: Bool) -> Bool {
        try? FileManager.default.removeItem(at: Self.captureURL)
        return bootGame(atPaths: discs, jit: jit)
    }

    var currentDisc: Int? {
        let index = discIndex
        return index >= 0 ? index : nil
    }

    func changeDisc(to index: Int) -> Bool { changeDisc(at: index) }

    func prepareBoot(resume: String?) -> Bool { setBootState(resume) && resume != nil }

    func prepareSnapshot() {
        _ = captureScreen(toPath: Self.captureURL.path)
    }

    func snapshot() -> PlatformImage? {
        guard let image = ImageCoding.load(Self.captureURL), image.width > 0 else { return nil }
        // Capture à la taille de l'écran : réduite à 640 pixels de large, comme les autres vignettes.
        return .make(ImageCoding.resized(image, width: 640))
    }

    var imageAspectRatio: CGFloat? {
        let ratio = aspectRatio
        return ratio > 0.5 && ratio < 4 ? CGFloat(ratio) : nil
    }
}

#if PLAYTENDO_VITA
extension PTVitaEngine: ExternalEngine {
    var engineState: ExternalEngineState {
        switch state {
        case PTVitaStateRunning: .running
        case PTVitaStatePaused: .paused
        case PTVitaStateStarting: .starting
        default: .stopped
        }
    }

    /// Le jeu est d'abord installé dans la mémoire de la console (EmulatorSession.prepareVita) : `path` est alors son
    /// identifiant (« PCSA00011 »). Pas de JIT à choisir : Vita3K n'a que le recompilateur.
    func boot(path: String, jit: Bool) -> Bool { bootTitle(path) }
    /// La Vita n'a pas de bouton « recommencer ».
    func reset() {}
    /// Pas d'avance rapide dans Vita3K.
    func setTurbo(_ enabled: Bool) {}
    /// Vita3K n'a pas de sauvegarde rapide : seules les sauvegardes des jeux existent.
    func saveState(toPath path: String) -> Bool { false }
    func loadState(fromPath path: String) -> Bool { false }
    func snapshot() -> PlatformImage? { nil }
    func prepareSnapshot() {}
    /// Écran de la Vita : 960 × 544.
    var imageAspectRatio: CGFloat? { 960.0 / 544.0 }
}
#endif
