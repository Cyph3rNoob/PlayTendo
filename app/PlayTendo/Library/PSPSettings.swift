import Foundation

/// Réglages d'image de la PSP, communs à tous les jeux : choisis dans le menu pause, en pleine partie
/// (le moteur les applique dès la reprise).
enum PSPSettings {
    /// Définition de rendu, en multiple de l'écran de la PSP (480×272). x4 ≈ 1080p ; au-delà, l'écran de
    /// l'iPhone (1284 pixels de haut en paysage) n'afficherait rien de plus.
    enum Resolution: Int, CaseIterable, Identifiable {
        case x1 = 1, x2, x3, x4

        var id: Int { rawValue }
        var label: String { "x\(rawValue)" }
        var size: String { "\(480 * rawValue)×\(272 * rawValue)" }
        var coreValue: String { "\(480 * rawValue)x\(272 * rawValue)" }
    }

    /// Lissage des textures (agrandissement xBRZ par le processeur) : décors moins pixelisés, plus de calcul.
    enum Smoothing: Int, CaseIterable, Identifiable {
        case off = 1, x2, x3, x4

        var id: Int { rawValue }
        var label: String { self == .off ? tr("Non") : "x\(rawValue)" }
        var coreValue: String { self == .off ? "disabled" : "\(rawValue)x" }
    }

    static let resolutionKey = "resolutionPSP"
    static let smoothingKey = "lissageTexturesPSP"

    static var resolution: Resolution {
        get { Resolution(rawValue: UserDefaults.standard.integer(forKey: resolutionKey)) ?? .x2 }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: resolutionKey) }
    }

    static var smoothing: Smoothing {
        get { Smoothing(rawValue: UserDefaults.standard.integer(forKey: smoothingKey)) ?? .off }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: smoothingKey) }
    }

    /// Réglages correspondants du moteur PPSSPP.
    static var coreOptions: [String: String] {
        [
            "ppsspp_internal_resolution": resolution.coreValue,
            "ppsspp_texture_scaling_level": smoothing.coreValue,
        ]
    }
}
