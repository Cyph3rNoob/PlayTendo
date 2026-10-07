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
    /// Appelé juste avant chaque mise en pause, jeu encore en marche (bloquant, court).
    func prepareSnapshot()
    /// Format de l'image du jeu (largeur / hauteur) s'il est connu ; nil : 4:3.
    var imageAspectRatio: CGFloat? { get }
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
    /// La PS2 capture son image même en pause (`snapshot`).
    func prepareSnapshot() {}
    var imageAspectRatio: CGFloat? { nil }
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

    /// Dolphin ne capture une image qu'en marche : elle est prise juste avant chaque pause (menu, arrière-plan),
    /// puis sert à la sauvegarde rapide ou en quittant (toujours faites depuis le menu pause).
    private static let captureURL = FileManager.default.temporaryDirectory.appendingPathComponent("PlayTendo-capture-GC-Wii.png")

    func boot(path: String, jit: Bool) -> Bool {
        try? FileManager.default.removeItem(at: Self.captureURL)
        return bootGame(atPath: path, jit: jit)
    }

    func prepareSnapshot() {
        _ = captureScreen(toPath: Self.captureURL.path)
    }

    func snapshot() -> UIImage? {
        guard let image = UIImage(contentsOfFile: Self.captureURL.path), image.size.width > 0 else { return nil }
        // Capture à la taille de l'écran : réduite à 640 points de large, comme les autres vignettes.
        let scale = min(1, 640 / image.size.width)
        guard scale < 1 else { return image }
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    var imageAspectRatio: CGFloat? {
        let ratio = aspectRatio
        return ratio > 0.5 && ratio < 4 ? CGFloat(ratio) : nil
    }
}
