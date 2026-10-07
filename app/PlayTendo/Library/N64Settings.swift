import Foundation

/// Réglages d'image de la N64, communs à tous les jeux : choisis dans le menu pause. Le moteur (Mupen64Plus-Next,
/// GLideN64) ne les lit qu'au démarrage d'un jeu : la session recharge alors le moteur avec une sauvegarde rapide
/// (`EmulatorSession.requestCoreReload`), sans que la partie soit perdue.
enum N64Settings {
    /// Taille de l'image rendue, en multiple de la N64 (320×240). x2 (640×480) par défaut, comme avant ce réglage.
    enum Resolution: Int, CaseIterable, Identifiable {
        case x1 = 1, x2, x3, x4

        var id: Int { rawValue }
        var label: String { "x\(rawValue)" }
        var size: String { "\(320 * rawValue)×\(240 * rawValue)" }
        var coreValue: String { "\(320 * rawValue)x\(240 * rawValue)" }
    }

    /// Lissage des bords en escalier (FXAA de GLideN64), comme pour la PS2 et la GameCube.
    enum Smoothing: Int, CaseIterable, Identifiable {
        case off = 0, on

        var id: Int { rawValue }
        var label: String { self == .off ? "Non" : "Oui" }
    }

    static let resolutionKey = "resolutionN64"
    static let smoothingKey = "lissageN64"

    static var resolution: Resolution {
        Resolution(rawValue: UserDefaults.standard.integer(forKey: resolutionKey)) ?? .x2
    }

    static var smoothing: Smoothing {
        Smoothing(rawValue: UserDefaults.standard.integer(forKey: smoothingKey)) ?? .off
    }

    /// Réglages correspondants du moteur.
    static var coreOptions: [String: String] {
        [
            "mupen64plus-43screensize": resolution.coreValue,
            "mupen64plus-FXAA": smoothing == .on ? "1" : "0",
        ]
    }
}
