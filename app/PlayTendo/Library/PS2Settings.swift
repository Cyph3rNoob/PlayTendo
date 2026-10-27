import Foundation

/// Image de la PS2, réglée dans le menu pause et gardée pour tous les jeux PS2 (le moteur la garde aussi dans
/// ses propres réglages).
enum PS2Settings {
    /// Définition de rendu, en multiple de celle de la PS2 (640×448 pour la plupart des jeux). Chaque cran
    /// demande nettement plus au processeur graphique : x1 par défaut, comme ARMSX2.
    enum Resolution: Int, CaseIterable, Identifiable {
        case x1 = 1, x2, x3, x4

        var id: Int { rawValue }
        var label: String { "x\(rawValue)" }
        var detail: String {
            switch self {
            case .x1: tr("origine")
            case .x2: "≈ 720p"
            case .x3: "≈ 1080p"
            case .x4: "≈ 1440p"
            }
        }
    }

    /// Lissage des bords en escalier (FXAA), peu coûteux.
    enum Smoothing: Int, CaseIterable, Identifiable {
        case off = 0, on

        var id: Int { rawValue }
        var label: String { self == .off ? tr("Non") : tr("Oui") }
    }

    /// Format : 16:9 active les correctifs « écran large » fournis avec le moteur (environ 4 150 jeux). Le jeu calcule
    /// alors une image plus large, sans déformation ; un jeu sans correctif reste en 4:3.
    enum Format: Int, CaseIterable, Identifiable {
        case standard = 0, wide

        var id: Int { rawValue }
        var label: String { self == .standard ? "4:3" : "16:9" }
    }

    static let resolutionKey = "resolutionPS2"
    /// Démarrage rapide : le jeu démarre sans le logo et le son de la PS2 (Réglages › BIOS et firmwares). Activé par défaut ; quelques
    /// rares jeux veulent le vrai démarrage de la console.
    static let fastBootKey = "demarrageRapidePS2"

    static var fastBoot: Bool { UserDefaults.standard.object(forKey: fastBootKey) as? Bool ?? true }
    static let smoothingKey = "lissagePS2"
    static let formatKey = "formatPS2"

    static var resolution: Resolution {
        Resolution(rawValue: UserDefaults.standard.integer(forKey: resolutionKey)) ?? .x1
    }

    static var smoothing: Smoothing {
        Smoothing(rawValue: UserDefaults.standard.integer(forKey: smoothingKey)) ?? .off
    }

    static var format: Format {
        Format(rawValue: UserDefaults.standard.integer(forKey: formatKey)) ?? .standard
    }
}
