import Foundation
import notify
#if canImport(StikJIT)
import StikJIT
#endif

// Extension d'aide de PlayTendo (PlugIns/PlayTendoJIT.appex).
//
// Une app ne peut pas attacher un débogueur à elle-même : PlayTendo démarre donc cette extension, qui
// le fait avec StikJIT (passage par LocalDevVPN et le fichier de jumelage). Le script « universal.js »
// répond ensuite aux demandes de PlayTendo (préparer sa réserve de mémoire, puis se détacher).
//
// Demande (userInfo du premier élément) : "operation" = "enable" | "prepare" | "resetDDI",
// "pid" (NSNumber), "pairing" (Data, contenu du fichier de jumelage).
// Réponse (userInfo de l'élément rendu) : "success" (Bool), "message" (String), "txm" (Bool, si connu).
// Étapes signalées à l'app par des notifications Darwin « playtendo.jit.etape.<nom> ».

@objc(PTJITHelperHandler)
final class PTJITHelperHandler: NSObject, NSExtensionRequestHandling {
    /// Une demande à la fois : les fonctions de StikJIT sont bloquantes et doivent rester dans l'ordre.
    private static let queue = DispatchQueue(label: "playtendo.jit-helper")

    func beginRequest(with context: NSExtensionContext) {
        let request = (context.inputItems.first as? NSExtensionItem)?.userInfo ?? [:]
        Self.queue.async {
            let item = NSExtensionItem()
            item.userInfo = Self.handle(request)
            context.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }

    private static func signal(_ step: String) {
        notify_post("playtendo.jit.etape.\(step)")
    }

    private static func handle(_ request: [AnyHashable: Any]) -> [String: Any] {
#if canImport(StikJIT)
        func answer(_ success: Bool, _ message: String) -> [String: Any] {
            var response: [String: Any] = ["success": success, "message": message]
            if let txm = StikJIT.isTXMPresent { response["txm"] = txm }
            return response
        }
        func stage(_ stage: StikJIT.PreparationStage) {
            switch stage {
            case .checkingReachability: signal("connexion")
            case .checkingDDI, .verifyingDDI: signal("verification")
            case .downloadingDDI: signal("telechargement")
            case .mountingDDI: signal("montage")
            case .ready: signal("debogueur")
            @unknown default: break
            }
        }

        let manager = FileManager.default
        // Image disque développeur gardée ici d'une fois sur l'autre (montée jusqu'au redémarrage de l'iPhone).
        let root = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true)
        let paths = DDIPaths.default(in: root)
        let operation = request["operation"] as? String ?? ""

        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            if operation == "resetDDI" {
                try StikJIT.resetCachedDDI(at: paths)
                return answer(true, "Image disque développeur effacée : elle sera retéléchargée.")
            }
            guard let pairing = request["pairing"] as? Data, !pairing.isEmpty else {
                return answer(false, "Le fichier de jumelage n'a pas été transmis.")
            }
            // Copie temporaire, effacée dès la fin de la demande ; son contenu n'est jamais écrit au journal.
            let file = root.appendingPathComponent("jumelage-\(UUID().uuidString).plist")
            try pairing.write(to: file, options: [.atomic, .completeFileProtection])
            defer { try? manager.removeItem(at: file) }

            switch operation {
            case "prepare":
                switch StikJIT.prepareDevice(pairingFile: file, paths: paths, progress: stage) {
                case .ready:
                    return answer(true, "iPhone joignable, image disque développeur prête.")
                case .unreachable(let reason):
                    return answer(false, "iPhone injoignable (LocalDevVPN est-il connecté ?) : \(reason)")
                case .preparationFailed(let reason):
                    return answer(false, "Préparation impossible : \(reason)")
                @unknown default:
                    return answer(false, "Réponse inconnue de StikJIT.")
                }
            case "enable":
                guard let pid = (request["pid"] as? NSNumber)?.int32Value, pid > 0 else {
                    return answer(false, "Processus de PlayTendo inconnu.")
                }
                // Revient quand PlayTendo a préparé sa mémoire et que le débogueur s'est détaché.
                try StikJIT.enableJIT(targetPID: pid, pairingFile: file, ddiPaths: paths,
                                      script: .universal, forceScript: true,
                                      preparationProgress: stage,
                                      progress: { NSLog("[PlayTendoJIT] %@", $0) })
                return answer(true, "Débogueur détaché.")
            default:
                return answer(false, "Demande inconnue : \(operation)")
            }
        } catch {
            return answer(false, error.localizedDescription)
        }
#else
        return ["success": false, "message": "Le JIT intégré ne fonctionne que sur un iPhone."]
#endif
    }
}
