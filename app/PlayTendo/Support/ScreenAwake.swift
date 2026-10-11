import UIKit

/// Garde l'écran allumé tant qu'au moins une raison le demande : une partie en cours, ou l'import d'un gros jeu
/// (l'iPhone verrouillé suspendrait l'app au milieu de la décompression).
@MainActor
enum ScreenAwake {
    enum Reason {
        case playing, importing
    }

    private static var reasons = Set<Reason>()

    static func hold(_ reason: Reason) {
        reasons.insert(reason)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    static func release(_ reason: Reason) {
        reasons.remove(reason)
        UIApplication.shared.isIdleTimerDisabled = !reasons.isEmpty
    }
}
