// PS Vita : compilé seulement avec PLAYTENDO_VITA (PLAYTENDO_VITA=1 zsh scripts/build_app.sh).
#if PLAYTENDO_VITA
import Foundation

/// Réglages de la PS Vita, communs à tous les jeux : choisis dans le menu pause, appliqués au prochain lancement d'un jeu
/// (Vita3K ne les lit qu'au démarrage, et n'a pas de sauvegarde rapide pour relancer le jeu sans perdre la partie).
enum VitaSettings {
    /// Précision du rendu (demandée le 2026-10-08 : couleurs fausses dans Gravity Rush, sols rouge vif, murs verts).
    /// Haute = « high-accuracy » de Vita3K (lecture exacte de l'image en cours par les shaders, sans le raccourci
    /// « texture viewport ») et synchronisation des surfaces : plus juste, plus lente.
    enum Accuracy: Int, CaseIterable, Identifiable {
        case normal = 0, high

        var id: Int { rawValue }
        var label: String { self == .normal ? "Normale" : "Haute" }
    }

    static let accuracyKey = "precisionVita"

    static var accuracy: Accuracy {
        Accuracy(rawValue: UserDefaults.standard.integer(forKey: accuracyKey)) ?? .normal
    }
}
#endif
