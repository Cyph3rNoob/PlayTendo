import Foundation
import StikJIT

/// StikJIT travaille dans un processus séparé : l'app ne peut pas se déboguer elle-même.
/// Une requête d'extension garde le helper vivant jusqu'à la fin du script de débogage.
@available(iOS 26.0, *)
@objc(PTStikJITHelperHandler)
final class PTStikJITHelperHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let data = (context.inputItems.first as? NSExtensionItem)?.userInfo?[PTJITHelperRequest.itemKey] as? Data
        PTStikJITWork.queue.async {
            let response: PTJITHelperResponse
            if let data, let request = try? JSONDecoder().decode(PTJITHelperRequest.self, from: data) {
                response = PTStikJITWork.perform(request)
            } else {
                response = PTJITHelperResponse(ok: false, txm: nil,
                                               error: "La requête StikJIT est absente ou illisible.")
            }
            let item = NSExtensionItem()
            item.userInfo = [PTJITHelperResponse.itemKey: (try? JSONEncoder().encode(response)) ?? Data()]
            context.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }
}

@available(iOS 26.0, *)
private enum PTJITWorkError: LocalizedError {
    case pairingFileMissing
    case unknownAction

    var errorDescription: String? {
        switch self {
        case .pairingFileMissing: "Le fichier de jumelage est absent ou vide."
        case .unknownAction: "Opération StikJIT inconnue."
        }
    }
}

/// StikJIT bloque pendant le montage du DDI et l'attachement du débogueur ; son travail reste hors du fil système.
@available(iOS 26.0, *)
private enum PTStikJITWork {
    static let queue = DispatchQueue(label: "com.playtendo.app.stikjit", qos: .userInitiated)

    static func perform(_ request: PTJITHelperRequest) -> PTJITHelperResponse {
        do {
            switch request.action {
            case "txm":
                return PTJITHelperResponse(ok: true, txm: StikJIT.isTXMPresent, error: nil)

            case "reset":
                try StikJIT.resetCachedDDI(at: Self.ddiPaths)
                return PTJITHelperResponse(ok: true, txm: nil, error: nil)

            case "prepare", "enable":
                guard let pairingData = request.pairingData, !pairingData.isEmpty else {
                    throw PTJITWorkError.pairingFileMissing
                }

                let temporaryPairingFile = FileManager.default.temporaryDirectory
                    .appendingPathComponent("PlayTendo-StikJIT-\(UUID().uuidString).plist")
                try pairingData.write(to: temporaryPairingFile, options: [.atomic, .completeFileProtection])
                defer { try? FileManager.default.removeItem(at: temporaryPairingFile) }

                if request.action == "prepare" {
                    let readiness = StikJIT.prepareDevice(pairingFile: temporaryPairingFile, paths: Self.ddiPaths)
                    switch readiness {
                    case .ready(let securityState):
                        return PTJITHelperResponse(ok: true, txm: securityState.isTXMPresent, error: nil)
                    case .unreachable(let reason):
                        return PTJITHelperResponse(ok: false, txm: StikJIT.isTXMPresent, error: reason)
                    case .preparationFailed(let reason):
                        return PTJITHelperResponse(ok: false, txm: StikJIT.isTXMPresent, error: reason)
                    @unknown default:
                        return PTJITHelperResponse(ok: false, txm: StikJIT.isTXMPresent,
                                                   error: "StikJIT a renvoyé un état de préparation inconnu.")
                    }
                }

                try StikJIT.enableJIT(targetPID: request.targetPID,
                                      pairingFile: temporaryPairingFile,
                                      ddiPaths: Self.ddiPaths,
                                      script: .universal,
                                      forceScript: request.forceScript)
                return PTJITHelperResponse(ok: true, txm: StikJIT.isTXMPresent, error: nil)

            default:
                throw PTJITWorkError.unknownAction
            }
        } catch {
            return PTJITHelperResponse(ok: false, txm: StikJIT.isTXMPresent, error: error.localizedDescription)
        }
    }

    private static var ddiPaths: DDIPaths {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return DDIPaths.default(in: library.appendingPathComponent("StikJIT", isDirectory: true))
    }
}
