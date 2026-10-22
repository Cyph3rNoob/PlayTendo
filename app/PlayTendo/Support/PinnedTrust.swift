import CryptoKit
import Foundation
import Security

/// Épinglage du certificat d'un service qui reçoit une clé de PlayTendo (SteamGridDB, ScreenScraper) : en plus de la
/// vérification normale du système, la chaîne du certificat doit mener à l'une des autorités racines attendues. Un
/// serveur intermédiaire installé pour espionner les échanges (avec son propre certificat racine) est refusé : la clé
/// ne lui est jamais envoyée.
final class PinnedTrust: NSObject, URLSessionDelegate {
    /// Let's Encrypt (racines ISRG). Empreintes = SHA-256 de la clé publique (SecKeyCopyExternalRepresentation),
    /// calculées sur leurs certificats publiés (letsencrypt.org/certs, vérifiées le 2026-10-22).
    static let isrgRootX1 = "9Fk6HgfMnM7/vtnBHcUhg1b3gU2bIpSd50XmKZkMbGA="
    static let isrgRootX2 = "+QHt0j1IgBr88CsiSG197KRsbAlprQDohcvoe1Za45Y="
    static let isrgRootYE = "o8gmWo6hTNA1Y/ybI8g6rlbzT1YElMY4ivrLbjg5fyE="
    static let isrgRootYR = "3udbYNAibUAofT8NAf6ktVK0UZSjEhF99kRyhtyJ2yM="

    private let service: String
    private let pins: Set<String>

    init(service: String, pins: Set<String>) {
        self.service = service
        self.pins = pins
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.cancelAuthenticationChallenge, nil) }
        guard SecTrustEvaluateWithError(trust, nil),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              chain.contains(where: isPinned) else {
            PTLogLine("\(service) : certificat du serveur non reconnu, connexion refusée (clé non envoyée)")
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }

    private func isPinned(_ certificate: SecCertificate) -> Bool {
        guard let key = SecCertificateCopyKey(certificate),
              let raw = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return false }
        return pins.contains(Data(SHA256.hash(data: raw)).base64EncodedString())
    }
}
