import Foundation

/// Image de la DS (essai du 2026-10-11) : rendu OpenGL de melonDS adapté à l'OpenGL ES de l'iPhone (ds/PTGLESCompat),
/// réglé dans le menu pause et gardé pour tous les jeux DS. La 3D est dessinée plus finement ; les décors et personnages
/// en 2D gardent leurs pixels d'origine. Le moteur applique le changement dès la reprise.
enum DSSettings {
    /// Définition de rendu, en multiple de l'écran de la DS (256×192, pour chacun des deux écrans).
    enum Resolution: Int, CaseIterable, Identifiable {
        case x1 = 1, x2, x3, x4

        var id: Int { rawValue }
        var label: String { "x\(rawValue)" }
        var size: String { "\(256 * rawValue)×\(192 * rawValue)" }
    }

    static let resolutionKey = "resolutionDS"

    /// x2 par défaut pendant l'essai.
    static var resolution: Resolution {
        Resolution(rawValue: UserDefaults.standard.integer(forKey: resolutionKey)) ?? .x2
    }

    /// Le rendu OpenGL (définition au choix) n'est pas encore dans le moteur DS du Mac : rendu logiciel, en 256×192.
    static var isAvailable: Bool {
#if os(iOS)
        true
#else
        false
#endif
    }

    /// Réglages correspondants du moteur melonDS DS.
    static var coreOptions: [String: String] {
        guard isAvailable else { return ["melonds_render_mode": "software"] }
        return [
            "melonds_render_mode": "opengl",
            "melonds_opengl_resolution": "\(resolution.rawValue)",
        ]
    }
}
