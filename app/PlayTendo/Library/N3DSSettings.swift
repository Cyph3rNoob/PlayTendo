import Foundation

/// Réglages d'image de la 3DS, communs à tous les jeux : choisis dans le menu pause, en pleine partie (le moteur
/// les applique dès la reprise).
enum N3DSSettings {
    /// Définition de rendu, en multiple de l'écran du haut (400×240). Au-delà de x3, l'écran de l'iPhone
    /// n'afficherait rien de plus ; sur Mac (fenêtre en plein écran), x4. x1 par défaut.
    enum Resolution: Int, CaseIterable, Identifiable {
#if os(macOS)
        case x1 = 1, x2, x3, x4
#else
        case x1 = 1, x2, x3
#endif

        var id: Int { rawValue }
        var label: String { "x\(rawValue)" }
        var size: String { "\(400 * rawValue)×\(240 * rawValue)" }
    }

    /// Lissage des textures (filtre ScaleForce d'Azahar, par le processeur graphique) : décors moins pixelisés.
    enum Smoothing: Int, CaseIterable, Identifiable {
        case off = 0, on

        var id: Int { rawValue }
        var label: String { self == .off ? tr("Non") : tr("Oui") }
    }

    static let resolutionKey = "resolution3DS"
    static let smoothingKey = "lissage3DS"

    static var resolution: Resolution {
        Resolution(rawValue: UserDefaults.standard.integer(forKey: resolutionKey)) ?? .x1
    }

    static var smoothing: Smoothing {
        Smoothing(rawValue: UserDefaults.standard.integer(forKey: smoothingKey)) ?? .off
    }

    /// Réglages correspondants du moteur Azahar.
    static var coreOptions: [String: String] {
        [
            "citra_resolution_factor": "\(resolution.rawValue)",
            "citra_texture_filter": smoothing == .on ? "ScaleForce" : "none",
        ]
    }
}
