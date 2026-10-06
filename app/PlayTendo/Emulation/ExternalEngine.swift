import UIKit

/// État d'un moteur autonome.
enum ExternalEngineState {
    case stopped, starting, running, paused
}

/// Moteur qui cadence, dessine et joue le son lui-même (PS2, GameCube/Wii) : la session le pilote seulement
/// (`EmulatorSession.runExternal`). Chargé à la première partie, gardé jusqu'à la fermeture de l'app.
protocol ExternalEngine: AnyObject {
    var renderView: UIView { get }
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
    func snapshot() -> UIImage?
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
}

extension PTDolphinEngine: ExternalEngine {
    var engineState: ExternalEngineState {
        switch state {
        case PTDolphinStateRunning: .running
        case PTDolphinStatePaused: .paused
        case PTDolphinStateStarting: .starting
        default: .stopped
        }
    }

    func boot(path: String, jit: Bool) -> Bool { bootGame(atPath: path, jit: jit) }
    func snapshot() -> UIImage? { nil }
}
