// PS Vita : compilé seulement avec PLAYTENDO_VITA (par défaut dans scripts/build_app.sh).
#if PLAYTENDO_VITA
import Foundation

/// Réglages d'image de la PS Vita, communs à tous les jeux : choisis dans le menu pause, appliqués au prochain
/// lancement d'un jeu (Vita3K ne lit sa résolution qu'au démarrage, et n'a pas de sauvegarde rapide pour relancer le
/// jeu sans perdre la partie).
enum VitaSettings {
    /// Définition de rendu interne de Vita3K (« resolution multiplier »), en multiple de l'écran de la Vita (960×544).
    /// iPhone et iPad : jusqu'à x2 (déjà 4 fois plus de pixels, la Vita prend beaucoup de mémoire) ; Mac : jusqu'à x4.
    enum Resolution: Int, CaseIterable, Identifiable {
#if os(macOS)
        case x1 = 1, x2, x3, x4
#else
        case x1 = 1, x2
#endif

        var id: Int { rawValue }
        var label: String { "x\(rawValue)" }
        var size: String { "\(960 * rawValue)×\(544 * rawValue)" }

        /// x1 sur iPhone et iPad, x2 sur Mac.
        static var standard: Resolution {
#if os(macOS)
            .x2
#else
            .x1
#endif
        }
    }

    static let resolutionKey = "resolutionVita"

    static var resolution: Resolution {
        Resolution(rawValue: UserDefaults.standard.integer(forKey: resolutionKey)) ?? .standard
    }
}
#endif
