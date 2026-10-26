#if os(iOS)
import Darwin
import Foundation

/// Selectors used by the system's NSExtension request API. This private entry point is
/// required because ExtensionKit's generated host identifier is not rewritten by sideloaders.
@objc private protocol PTNSExtensionFactory: AnyObject {
    @objc(extensionWithIdentifier:error:)
    func `extension`(withIdentifier identifier: String) throws -> AnyObject
}

@objc private protocol PTNSExtensionRequesting: AnyObject {
    @objc(beginExtensionRequestWithInputItems:completion:)
    func beginExtensionRequest(withInputItems items: [Any], completion: @escaping (NSUUID?) -> Void)

    @objc(pidForRequestIdentifier:)
    func pid(forRequestIdentifier identifier: NSUUID) -> Int32

    @objc(setRequestCompletionBlock:)
    func setRequestCompletionBlock(_ block: @escaping (NSUUID?, [Any]?) -> Void)

    @objc(setRequestCancellationBlock:)
    func setRequestCancellationBlock(_ block: @escaping (NSUUID?, NSError?) -> Void)

    @objc(setRequestInterruptionBlock:)
    func setRequestInterruptionBlock(_ block: @escaping (NSUUID?) -> Void)
}

@MainActor
enum PTStikJITExtensionHost {
    private static let helperFileName = "PlayTendoJITHelper.appex"
    private static var pendingRequests: [UUID: PTStikJITExtensionRequest] = [:]

    /// Reads the identifier SideStore actually installed, including its per-team suffix.
    private static var helperBundleIdentifier: String? {
        guard let helperURL = Bundle.main.builtInPlugInsURL?.appendingPathComponent(helperFileName),
              let helperBundle = Bundle(url: helperURL) else { return nil }
        return helperBundle.bundleIdentifier
    }

    @available(iOS 26.0, *)
    static func perform(action: String,
                        targetPID: Int32,
                        pairingData: Data?,
                        forceScript: Bool) async throws -> PTJITHelperResponse {
        guard let identifier = helperBundleIdentifier else {
            throw failure(1, "L'extension StikJIT de PlayTendo manque dans PlugIns. Réinstalle l'app en conservant ses extensions.")
        }

        if NSClassFromString("NSExtension") == nil {
            dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW)
        }
        guard let extensionClass = NSClassFromString("NSExtension") else {
            throw failure(2, "iOS ne fournit pas l'API d'extension nécessaire à StikJIT.")
        }

        let factory = unsafeBitCast(extensionClass as AnyObject, to: PTNSExtensionFactory.self)
        let extensionObject: AnyObject
        do {
            extensionObject = try factory.extension(withIdentifier: identifier)
        } catch {
            throw failure(3, "Le helper StikJIT (\(identifier)) est introuvable : \(error.localizedDescription)")
        }

        let request = PTJITHelperRequest(action: action,
                                         targetPID: targetPID,
                                         pairingData: pairingData,
                                         forceScript: forceScript)
        let payload = try JSONEncoder().encode(request)

        return try await withCheckedThrowingContinuation { continuation in
            let pending = PTStikJITExtensionRequest(identifier: identifier,
                                                    action: action,
                                                    extensionObject: extensionObject)
            pendingRequests[pending.id] = pending
            pending.begin(payload: payload, continuation: continuation)
        }
    }

    fileprivate static func finished(_ requestID: UUID) {
        pendingRequests.removeValue(forKey: requestID)
    }

    fileprivate static func failure(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "PTStikJITExtensionHost", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@MainActor
private final class PTStikJITExtensionRequest {
    let id = UUID()

    private let identifier: String
    private let action: String
    private let extensionObject: AnyObject
    private let shim: PTNSExtensionRequesting
    private var continuation: CheckedContinuation<PTJITHelperResponse, Error>?

    init(identifier: String, action: String, extensionObject: AnyObject) {
        self.identifier = identifier
        self.action = action
        self.extensionObject = extensionObject
        self.shim = unsafeBitCast(extensionObject, to: PTNSExtensionRequesting.self)
    }

    func begin(payload: Data, continuation: CheckedContinuation<PTJITHelperResponse, Error>) {
        self.continuation = continuation

        shim.setRequestCompletionBlock { [weak self] _, items in
            let data = (items?.first as? NSExtensionItem)?.userInfo?[PTJITHelperResponse.itemKey] as? Data
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.complete(data) }
            }
        }
        shim.setRequestCancellationBlock { [weak self] _, error in
            let reason = error?.localizedDescription ?? "la requête a été annulée"
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finish(.failure(PTStikJITExtensionHost.failure(4, "Le helper StikJIT s'est arrêté : \(reason)")))
                }
            }
        }
        shim.setRequestInterruptionBlock { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finish(.failure(PTStikJITExtensionHost.failure(5, "Le helper StikJIT s'est interrompu. Réessaie.")))
                }
            }
        }

        let item = NSExtensionItem()
        item.userInfo = [PTJITHelperRequest.itemKey: payload]
        shim.beginExtensionRequest(withInputItems: [item]) { [weak self] requestIdentifier in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard let requestIdentifier else {
                        self.finish(.failure(PTStikJITExtensionHost.failure(6, "Le helper StikJIT n'a pas démarré. Réinstalle l'app en conservant ses extensions.")))
                        return
                    }
                    let processID = self.shim.pid(forRequestIdentifier: requestIdentifier)
                    PTLogLine("[jit-helper] \(self.action) : \(self.identifier) démarré (pid \(processID))")
                }
            }
        }
    }

    private func complete(_ data: Data?) {
        guard let data, let response = try? JSONDecoder().decode(PTJITHelperResponse.self, from: data) else {
            finish(.failure(PTStikJITExtensionHost.failure(7, "Le helper StikJIT s'est terminé sans réponse exploitable.")))
            return
        }
        PTLogLine("[jit-helper] \(action) : terminé (succès \(response.ok ? 1 : 0))")
        finish(.success(response))
    }

    private func finish(_ result: Result<PTJITHelperResponse, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        PTStikJITExtensionHost.finished(id)
        continuation.resume(with: result)
    }
}
#endif
