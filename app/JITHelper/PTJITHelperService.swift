import Foundation

/// Messages transmis en mémoire entre PlayTendo et son extension classique.
/// Le fichier de jumelage n'est jamais écrit dans le conteneur de l'app hôte ni journalisé.
struct PTJITHelperRequest: Codable, Sendable {
    static let itemKey = "com.playtendo.jit-helper.request"

    let action: String
    let targetPID: Int32
    let pairingData: Data?
    let forceScript: Bool
}

struct PTJITHelperResponse: Codable, Sendable {
    static let itemKey = "com.playtendo.jit-helper.response"

    let ok: Bool
    let txm: Bool?
    let error: String?
}
