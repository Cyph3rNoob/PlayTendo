import Foundation

/// Démarre l'extension d'aide PlayTendoJIT (PlugIns/PlayTendoJIT.appex) et lui envoie une demande.
///
/// L'extension est « classique » et démarrée par l'API privée NSExtension (comme LiveContainer et
/// Madeira), en la cherchant par l'identifiant qu'elle a dans cette installation : AltStore renomme
/// l'app et l'extension (il y ajoute l'identifiant de l'équipe), et cette recherche le suit.
/// Demande et réponse voyagent dans le `userInfo` d'un NSExtensionItem (clés : voir JITHelper.swift).
@MainActor
enum JITHelperClient {
    static let fileName = "PlayTendoJIT.appex"

    /// Demandes en cours, gardées en vie jusqu'à leur réponse.
    private static var running: [ObjectIdentifier: AnyObject] = [:]

    /// Identifiant de l'extension dans cette installation, lu dans son Info.plist (nil si absente).
    static var identifier: String? {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent(fileName) else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    static func send(_ request: [String: Any]) async throws -> [String: Any] {
        guard let identifier else {
            throw JITManager.Failure(message: "L'aide JIT manque dans cette installation. Réinstalle PlayTendo et garde ses extensions si AltStore te le demande.")
        }
        if NSClassFromString("NSExtension") == nil {
            dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW)
        }
        guard let extensionClass = NSClassFromString("NSExtension") else {
            throw JITManager.Failure(message: "iOS ne fournit pas l'outil nécessaire pour démarrer l'aide JIT.")
        }
        let factory = unsafeBitCast(extensionClass as AnyObject, to: ExtensionClassShim.self)
        let found: AnyObject
        do {
            found = try factory.extension(withIdentifier: identifier)
        } catch {
            throw JITManager.Failure(message: "Aide JIT introuvable (\(identifier)) : \(error.localizedDescription)")
        }
        let shim = unsafeBitCast(found, to: ExtensionShim.self)
        let key = ObjectIdentifier(found)
        running[key] = found
        defer { running[key] = nil }

        return try await withCheckedThrowingContinuation { continuation in
            // Les blocs arrivent sur n'importe quel fil : seule la première réponse compte.
            let once = Once()
            func finish(_ result: Result<[String: Any], Error>) {
                if once.claim() { continuation.resume(with: result) }
            }
            shim.setRequestCompletionBlock { _, items in
                let info = (items?.first as? NSExtensionItem)?.userInfo ?? [:]
                var response: [String: Any] = [:]
                for (key, value) in info { if let key = key as? String { response[key] = value } }
                finish(.success(response))
            }
            shim.setRequestCancellationBlock { _, error in
                finish(.failure(JITManager.Failure(message: "L'aide JIT s'est arrêtée : \(error?.localizedDescription ?? "demande annulée").")))
            }
            shim.setRequestInterruptionBlock { _ in
                finish(.failure(JITManager.Failure(message: "L'aide JIT s'est arrêtée brusquement. Réessaie.")))
            }
            let item = NSExtensionItem()
            item.userInfo = request
            shim.beginExtensionRequest(withInputItems: [item]) { uuid in
                if uuid == nil {
                    finish(.failure(JITManager.Failure(message: "L'aide JIT n'a pas démarré. Réinstalle PlayTendo et garde ses extensions si AltStore te le demande.")))
                } else {
                    PTLogLine("JIT : aide démarrée (\(request["operation"] as? String ?? "?"))")
                }
            }
        }
    }
}

/// Garantit qu'une seule réponse est rendue, quel que soit le fil qui la donne.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

// API privée NSExtension (ExtensionFoundation).
@objc private protocol ExtensionClassShim {
    @objc(extensionWithIdentifier:error:)
    func `extension`(withIdentifier identifier: String) throws -> AnyObject
}

@objc private protocol ExtensionShim {
    @objc(beginExtensionRequestWithInputItems:completion:)
    func beginExtensionRequest(withInputItems items: [Any], completion: @escaping (NSUUID?) -> Void)
    @objc(setRequestCompletionBlock:)
    func setRequestCompletionBlock(_ block: @escaping (NSUUID?, [Any]?) -> Void)
    @objc(setRequestCancellationBlock:)
    func setRequestCancellationBlock(_ block: @escaping (NSUUID?, NSError?) -> Void)
    @objc(setRequestInterruptionBlock:)
    func setRequestInterruptionBlock(_ block: @escaping (NSUUID?) -> Void)
}
