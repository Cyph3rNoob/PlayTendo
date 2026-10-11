import CryptoKit
import UIKit

/// Source de secours des jaquettes : SteamGridDB (images faites par sa communauté, pour Steam), interrogée quand
/// libretro n'a rien. Sa clé d'accès est embarquée masquée dans l'app (PTSecrets, scripts/make_secrets.py) et ne part
/// que vers le vrai serveur de SteamGridDB (certificat épinglé). Sans clé, rien n'est demandé.
enum SteamGridDB {
    enum Result: Sendable {
        /// Image prête à enregistrer, et nom du jeu choisi chez SteamGridDB.
        case found(Data, gameName: String)
        case missing
        case offline
    }

    static let isAvailable = PTSteamGridDBKey() != nil

    private static let api = "https://www.steamgriddb.com/api/v2"

    /// Jaquette « portrait » du jeu dont le nom ressemble le plus au titre officiel, ramenée à 512 pixels de large.
    static func cover(for officialName: String) async -> Result {
        guard isAvailable else { return .missing }
        let title = searchTitle(officialName)
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#&+")
        guard let term = title.addingPercentEncoding(withAllowedCharacters: allowed),
              let searchURL = URL(string: "\(api)/search/autocomplete/\(term)") else { return .missing }
        let games: [Game]
        switch await fetch([Game].self, from: searchURL) {
        case .ok(let found): games = found
        case .missing: return .missing
        case .offline: return .offline
        }
        guard let game = bestMatch(games, for: title),
              let gridsURL = URL(string: "\(api)/grids/game/\(game.id)?dimensions=600x900,342x482,660x930"
                                 + "&types=static&nsfw=false&humor=false") else { return .missing }
        let grids: [Grid]
        switch await fetch([Grid].self, from: gridsURL) {
        case .ok(let found): grids = found
        case .missing: return .missing
        case .offline: return .offline
        }
        // Les grilles arrivent de la mieux notée à la moins bien notée. L'image elle-même est publique (sans clé).
        guard let grid = grids.first(where: { $0.nsfw != true && $0.humor != true }),
              let imageURL = URL(string: grid.url) else { return .missing }
        do {
            let (data, response) = try await URLSession.shared.data(from: imageURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data),
                  let jpeg = resized(image, width: 512).jpegData(compressionQuality: 0.88) else { return .offline }
            return .found(jpeg, gameName: game.name)
        } catch {
            return .offline
        }
    }

    // MARK: Échanges avec l'API

    private struct Response<Value: Decodable>: Decodable {
        let success: Bool
        let data: Value?
    }

    private struct Game: Decodable {
        let id: Int
        let name: String
    }

    private struct Grid: Decodable {
        let url: String
        let nsfw: Bool?
        let humor: Bool?
    }

    private enum Fetch<Value> {
        case ok(Value), missing, offline
    }

    /// Session de l'API : sans cache ni cookies, certificat vérifié par `PinnedTrust`.
    private static let session = URLSession(configuration: .ephemeral, delegate: PinnedTrust(), delegateQueue: nil)

    private static func fetch<Value: Decodable>(_ type: Value.Type, from url: URL) async -> Fetch<Value> {
        guard let key = PTSteamGridDBKey() else { return .missing }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("PlayTendo", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .offline }
            switch http.statusCode {
            case 200: break
            case 404: return .missing
            case 401, 403:
                PTLogLine("SteamGridDB refuse la clé d'accès embarquée (code \(http.statusCode))")
                return .missing
            default: return .offline
            }
            guard let decoded = try? JSONDecoder().decode(Response<Value>.self, from: data), decoded.success,
                  let value = decoded.data else { return .missing }
            return .ok(value)
        } catch {
            return .offline
        }
    }

    /// Épinglage : en plus de la vérification normale d'iOS, la chaîne du certificat doit mener à l'une des autorités
    /// racines publiques que Cloudflare (hébergeur de SteamGridDB) utilise. Un serveur intermédiaire installé pour
    /// espionner les échanges (avec son propre certificat racine) est refusé : la clé ne lui est jamais envoyée.
    private final class PinnedTrust: NSObject, URLSessionDelegate {
        /// SHA-256 de la clé publique (SecKeyCopyExternalRepresentation) des racines, calculé sur leurs certificats.
        private static let pins: Set<String> = [
            "lK8IrGu+Yr3bnuiDnxi5kSkGkcCzXbJlG1jZi2pL6jg=", // GTS Root R1
            "tWqG3lJFDJFwGdbr5vqzUVNHUfrLfXVQabzJcAMpKAQ=", // GTS Root R2
            "cGD/gaVoHDGGoq4fgudPEejOz7QIgWiJuexwqVKO0n8=", // GTS Root R3
            "YSoUL4CBzo5aJ/ES9gSZTsavsgtHsiLLnTG+BKUdork=", // GTS Root R4 (chaîne actuelle, 2026-10-11)
            "Pd4y/8Rwm7Gj/3bTVEH0rn/gXuKK5dYXp1vTbu5r9co=", // GlobalSign Root CA (signe GTS Root R4)
            "9Fk6HgfMnM7/vtnBHcUhg1b3gU2bIpSd50XmKZkMbGA=", // ISRG Root X1 (Let's Encrypt)
            "+QHt0j1IgBr88CsiSG197KRsbAlprQDohcvoe1Za45Y=", // ISRG Root X2 (Let's Encrypt)
            "Hy8S1Obqzk27SZrHbHRALdY2JCu6Dfob7H4xSeHlDFE=", // SSL.com Root Certification Authority ECC
            "3Ih5Szl7yUenUxOk1rFJyZFbhmX4GDHH+feTff87TFM=", // SSL.com Root Certification Authority RSA
            "DfKSu5l3Mdq5eX76p6abH+wW0tz0SnLzXgYuxXtS7aA=", // SSL.com TLS ECC Root CA 2022
            "RfPd63uYzm1+Fe1Uh9qtBun/kl4LgkngHee3WAs6C4M=", // SSL.com TLS RSA Root CA 2022
        ]

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
            async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else { return (.cancelAuthenticationChallenge, nil) }
            guard SecTrustEvaluateWithError(trust, nil),
                  let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  chain.contains(where: Self.isPinned) else {
                PTLogLine("SteamGridDB : certificat du serveur non reconnu, connexion refusée (clé non envoyée)")
                return (.cancelAuthenticationChallenge, nil)
            }
            return (.useCredential, URLCredential(trust: trust))
        }

        private static func isPinned(_ certificate: SecCertificate) -> Bool {
            guard let key = SecCertificateCopyKey(certificate),
                  let raw = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return false }
            return pins.contains(Data(SHA256.hash(data: raw)).base64EncodedString())
        }
    }

    // MARK: Choix du jeu

    /// Titre cherché : sans région ni version, article remis devant, tirets retirés
    /// (« Legend of Zelda, The - A Link to the Past (Europe) » → « The Legend of Zelda A Link to the Past »).
    static func searchTitle(_ officialName: String) -> String {
        var parts = GameDatabase.title(of: officialName).components(separatedBy: " - ")
        for article in ["The", "A", "An"] where parts[0].hasSuffix(", \(article)") {
            parts[0] = "\(article) \(parts[0].dropLast(article.count + 2))"
        }
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Jeu dont les mots ressemblent le plus au titre (au moins 60 % de mots en commun), sinon aucun : une jaquette
    /// absente vaut mieux que celle d'un autre jeu.
    private static func bestMatch(_ games: [Game], for title: String) -> Game? {
        let wanted = Set(GameDatabase.words(title))
        guard !wanted.isEmpty else { return nil }
        var best: (game: Game, score: Double)?
        for game in games {
            let words = Set(GameDatabase.words(game.name))
            let score = Double(wanted.intersection(words).count) / Double(wanted.union(words).count)
            if score > (best?.score ?? 0) { best = (game, score) }
        }
        guard let best, best.score >= 0.6 else { return nil }
        return best.game
    }

    private static func resized(_ image: UIImage, width: CGFloat) -> UIImage {
        guard image.size.width > width else { return image }
        let size = CGSize(width: width, height: (image.size.height * width / image.size.width).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
