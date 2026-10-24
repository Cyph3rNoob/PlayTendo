import Foundation

/// Téléchargements plafonnés (audit de sécurité du 2026-10-24) : jaquettes, fiches, codes de triche. Un serveur piégé ou
/// détourné ne peut pas faire remplir la mémoire par une réponse sans fin, et rien ne part ailleurs qu'en https (une
/// adresse venue d'une réponse pourrait sinon être « file:// » et faire lire un fichier de l'appareil).
enum CappedDownload {
    struct Refused: Error {}

    /// Jaquettes : bien plus que la plus grosse attendue (≈ 2 Mo).
    static let imageLimit = 20 << 20
    /// Réponses des API (JSON) et listes de codes (la plus grosse, CheatDatabase.txt, fait 6,4 Mo).
    static let textLimit = 16 << 20

    /// Réponse lue en entier, `limit` octets au plus ; au-delà, ou hors https, `Refused`.
    static func data(for request: URLRequest, session: URLSession = .shared, limit: Int) async throws -> (Data, URLResponse) {
        guard request.url?.scheme?.lowercased() == "https" else { throw Refused() }
        let (bytes, response) = try await session.bytes(for: request)
        guard response.expectedContentLength <= Int64(limit) else {
            bytes.task.cancel()
            throw Refused()
        }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in bytes {
            guard data.count < limit else {
                bytes.task.cancel()
                throw Refused()
            }
            data.append(byte)
        }
        return (data, response)
    }

    /// Adresse en https sur l'un de ces sites (ou l'un de leurs sous-domaines).
    static func isSecure(_ url: URL, on hosts: [String]) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
