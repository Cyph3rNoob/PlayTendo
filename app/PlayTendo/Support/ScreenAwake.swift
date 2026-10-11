#if os(iOS)
import UIKit
#else
import IOKit.pwr_mgt
#endif

/// Garde l'écran allumé tant qu'au moins une raison le demande : une partie en cours, ou l'import d'un gros jeu
/// (l'iPhone verrouillé suspendrait l'app au milieu de la décompression ; le Mac mettrait l'écran en veille pendant
/// une partie à la manette).
@MainActor
enum ScreenAwake {
    enum Reason {
        case playing, importing
    }

    private static var reasons = Set<Reason>()
#if os(macOS)
    private static var assertion: IOPMAssertionID = 0
#endif

    static func hold(_ reason: Reason) {
        reasons.insert(reason)
        apply()
    }

    static func release(_ reason: Reason) {
        reasons.remove(reason)
        apply()
    }

    private static func apply() {
#if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = !reasons.isEmpty
#else
        if !reasons.isEmpty && assertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), "PlayTendo" as CFString, &assertion)
        } else if reasons.isEmpty && assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
#endif
    }
}
