import Foundation

/// Réglages d'image de la N64, communs à tous les jeux : choisis dans le menu pause (résolution et format ; pas de
/// lissage : le FXAA de GLideN64 floutait aussi les textes, retiré à la demande de l'utilisateur). Le moteur
/// (Mupen64Plus-Next, GLideN64) ne les lit qu'au démarrage d'un jeu : la session recharge alors le moteur avec une sauvegarde rapide
/// (`EmulatorSession.requestCoreReload`), sans que la partie soit perdue.
enum N64Settings {
    /// Taille de l'image rendue, en multiple de la N64 (320×240). x2 (640×480) par défaut, comme avant ce réglage.
    /// En 16:9, les tailles proposées par le moteur les plus proches (640×360 à 1920×1080).
    enum Resolution: Int, CaseIterable, Identifiable {
        case x1 = 1, x2, x3, x4

        var id: Int { rawValue }
        var label: String { "x\(rawValue)" }

        func coreValue(wide: Bool) -> String {
            guard wide else { return "\(320 * rawValue)x\(240 * rawValue)" }
            return ["640x360", "960x540", "1280x720", "1920x1080"][rawValue - 1]
        }

        func size(wide: Bool) -> String { coreValue(wide: wide).replacingOccurrences(of: "x", with: "×") }
    }

    /// Format de l'image : 4:3 d'origine, ou 16:9 « ajusté » de GLideN64 (la 3D est dessinée plus large, on voit plus
    /// de décor ; selon les jeux, des éléments 2D peuvent être étirés ou mal placés).
    enum Format: Int, CaseIterable, Identifiable {
        case standard = 0, wide

        var id: Int { rawValue }
        var label: String { self == .standard ? "4:3" : "16:9" }
    }

    static let resolutionKey = "resolutionN64"
    static let formatKey = "formatN64"
    /// Accessoire branché sur la manette : Controller Pak (sauvegardes de certains jeux, par défaut) ou Rumble Pak
    /// (vibrations). Une seule place, comme sur la vraie manette ; pris au lancement d'un jeu.
    static let rumblePakKey = "rumblePakN64"

    static var rumblePak: Bool { UserDefaults.standard.bool(forKey: rumblePakKey) }

    static var resolution: Resolution {
        Resolution(rawValue: UserDefaults.standard.integer(forKey: resolutionKey)) ?? .x2
    }

    static var format: Format {
        Format(rawValue: UserDefaults.standard.integer(forKey: formatKey)) ?? .standard
    }

    /// Réglages correspondants du moteur.
    static var coreOptions: [String: String] {
        let wide = format == .wide
        return [
            "mupen64plus-aspect": wide ? "16:9 adjusted" : "4:3",
            "mupen64plus-43screensize": resolution.coreValue(wide: false),
            "mupen64plus-169screensize": resolution.coreValue(wide: true),
            "mupen64plus-FXAA": "0",
            "mupen64plus-pak1": rumblePak ? "rumble" : "memory",
        ]
    }
}
