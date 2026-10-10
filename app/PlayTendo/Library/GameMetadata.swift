import ImageIO
import SwiftUI
import UIKit

/// Ce que l'app sait de chaque jeu au-delà du fichier : son nom officiel (reconnu dans la base),
/// sa jaquette (téléchargée chez libretro) et la date de la dernière partie.
@MainActor
final class GameMetadata: ObservableObject {
    struct Info: Codable, Equatable {
        var name: String?
        var size: Int64
        var modified: Double
        /// Dernière recherche de jaquette restée sans résultat (on réessaie au bout d'une semaine).
        var coverMissing: Double?
    }

    @Published private(set) var infos: [String: Info] = [:]
    /// Change quand la jaquette d'un jeu arrive (clé du jeu → compteur) : seule sa carte la recharge.
    @Published private(set) var coverRevisions: [String: Int] = [:]
    @Published private(set) var lastPlayed: [String: Double] = [:]

    private var running = false
    private var queued: [Game]?

    private static let infosFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Bibliotheque/infos.json")
    private static let lastPlayedKey = "dernieresParties"

    init() {
        if let data = try? Data(contentsOf: Self.infosFile),
           let saved = try? JSONDecoder().decode([String: Info].self, from: data) {
            infos = saved
        }
        lastPlayed = UserDefaults.standard.dictionary(forKey: Self.lastPlayedKey) as? [String: Double] ?? [:]
    }

    // MARK: Lecture

    func officialName(for game: Game) -> String? { infos[game.key]?.name }

    func coverRevision(for game: Game) -> Int { coverRevisions[game.key] ?? 0 }

    func display(for game: Game) -> GameDisplay { GameDisplay(game: game, officialName: officialName(for: game)) }

    func coverFile(for game: Game) -> URL? {
        guard let name = officialName(for: game) else { return nil }
        let url = Self.coverURL(name: name, system: game.system)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Jeux joués récemment, du plus récent au plus ancien.
    func recentGames(in games: [Game], limit: Int = 8) -> [Game] {
        games.filter { lastPlayed[$0.key] != nil }
            .sorted { (lastPlayed[$0.key] ?? 0) > (lastPlayed[$1.key] ?? 0) }
            .prefix(limit).map { $0 }
    }

    func lastPlayedDate(for game: Game) -> Date? {
        lastPlayed[game.key].map { Date(timeIntervalSince1970: $0) }
    }

    // MARK: Mise à jour

    func markPlayed(_ game: Game) {
        lastPlayed[game.key] = Date().timeIntervalSince1970
        UserDefaults.standard.set(lastPlayed, forKey: Self.lastPlayedKey)
    }

    /// Relance la recherche de jaquette d'un jeu (menu « Actualiser la jaquette »).
    func retryCover(for game: Game) {
        if let name = officialName(for: game) {
            let file = Self.coverURL(name: name, system: game.system)
            try? FileManager.default.removeItem(at: file)
            CoverImages.forget(file)
        }
        infos[game.key]?.coverMissing = nil
        coverRevisions[game.key, default: 0] += 1
        update([game], force: true)
    }

    /// Reconnaît les nouveaux jeux puis télécharge les jaquettes manquantes, en arrière-plan.
    func update(_ games: [Game], force: Bool = false) {
        if running {
            queued = (queued ?? []) + games
            return
        }
        running = true
        let known = infos
        Task.detached(priority: .utility) {
            var found: [String: Info] = [:]
            for game in games {
                let values = try? game.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = Int64(values?.fileSize ?? 0)
                let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                if !force, let info = known[game.key], info.size == size, info.modified == modified { continue }
                let name: String?
                if game.system == .vita {
                    // PS Vita : pas de base de jeux ; le nom vient de la fiche du jeu (param.sfo) et son icône sert
                    // de jaquette.
                    name = VitaGame.title(of: game.url)
                    if let name, let icon = VitaGame.icon(of: game.url) {
                        let file = Self.coverURL(name: name, system: game.system)
                        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? icon.write(to: file, options: .atomic)
                    }
                } else {
                    let keys = GameIdentifier.keys(for: game.url, system: game.system)
                    name = GameDatabase.shared(for: game.system)?.identify(keys: keys, fileName: game.baseName)
                }
                PTLogLine("Jeu reconnu : \(game.url.lastPathComponent) → \(name ?? "inconnu")")
                found[game.key] = Info(name: name, size: size, modified: modified, coverMissing: nil)
            }
            await self.merge(found)
            await self.downloadCovers(for: games)
            await self.finish()
        }
    }

    private func merge(_ found: [String: Info]) {
        guard !found.isEmpty else { return }
        infos.merge(found) { $1 }
        save()
    }

    private func finish() {
        running = false
        if let next = queued {
            queued = nil
            update(next)
        }
    }

    private func save() {
        let url = Self.infosFile
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(infos).write(to: url, options: .atomic)
    }

    // MARK: Jaquettes

    private func downloadCovers(for games: [Game]) async {
        let week: Double = 7 * 24 * 3600
        let now = Date().timeIntervalSince1970
        var wanted: [(key: String, name: String, system: GameSystem)] = []
        var seen = Set<String>()
        for game in games {
            guard let info = infos[game.key], let name = info.name, coverFile(for: game) == nil,
                  now - (info.coverMissing ?? 0) > week, seen.insert("\(game.system.rawValue)/\(name)").inserted else { continue }
            wanted.append((game.key, name, game.system))
        }
        // Trois téléchargements à la fois.
        for batch in stride(from: 0, to: wanted.count, by: 3) {
            let slice = wanted[batch..<min(batch + 3, wanted.count)]
            let results = await withTaskGroup(of: (String, CoverResult).self) { group in
                for item in slice {
                    group.addTask { (item.key, await Self.fetchCover(name: item.name, system: item.system)) }
                }
                var results: [(String, CoverResult)] = []
                for await result in group { results.append(result) }
                return results
            }
            for (key, result) in results {
                switch result {
                case .saved:
                    // Tous les fichiers du même jeu (même nom officiel) profitent de la jaquette.
                    let name = infos[key]?.name
                    for game in games where infos[game.key]?.name == name {
                        coverRevisions[game.key, default: 0] += 1
                    }
                case .missing: infos[key]?.coverMissing = now
                case .offline: break                          // on réessaiera au prochain lancement
                }
            }
            save()
        }
    }

    private enum CoverResult: Sendable { case saved, missing, offline }

    /// Cherche la jaquette sous le nom exact, puis sous les noms des autres régions.
    nonisolated private static func fetchCover(name: String, system: GameSystem) async -> CoverResult {
        let candidates = [name] + (GameDatabase.shared(for: system)?.alternatives(to: name).prefix(3) ?? [])
        for candidate in candidates {
            guard let url = remoteCoverURL(name: candidate, system: system) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("PlayTendo", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { return .offline }
                if http.statusCode == 404 { continue }
                guard http.statusCode == 200, UIImage(data: data) != nil else { return .offline }
                let file = coverURL(name: name, system: system)
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
                PTLogLine("Jaquette téléchargée : \(candidate)")
                return .saved
            } catch {
                return .offline
            }
        }
        PTLogLine("Pas de jaquette chez libretro pour : \(name)")
        return .missing
    }

    /// Adresse de la jaquette chez libretro : certains caractères du nom y sont remplacés par « _ ».
    nonisolated private static func remoteCoverURL(name: String, system: GameSystem) -> URL? {
        let file = String(name.map { "&*/:`<>?\\|\"".contains($0) ? "_" : $0 }) + ".png"
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/+&;=")
        guard let directory = system.libretroName.addingPercentEncoding(withAllowedCharacters: allowed),
              let encoded = file.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://thumbnails.libretro.com/\(directory)/Named_Boxarts/\(encoded)")
    }

    nonisolated static func coverURL(name: String, system: GameSystem) -> URL {
        let safe = String(name.map { "/:\\".contains($0) ? "_" : $0 })
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jaquettes/\(system.folderName)/\(safe).png")
    }
}

/// Titre affiché : nom officiel découpé (« God of War » / « Ghost of Sparta », région « Europe »),
/// ou à défaut le nom du fichier nettoyé.
struct GameDisplay {
    let title: String
    let subtitle: String?
    let region: String?

    init(game: Game, officialName: String?) {
        let source = officialName ?? game.baseName.replacingOccurrences(of: "_", with: " ")
        var title = GameDatabase.title(of: source)
        if title.isEmpty { title = source }
        // « Legend of Zelda, The - … » → « The Legend of Zelda ».
        var subtitle: String?
        if let dash = title.range(of: " - ") {
            subtitle = String(title[dash.upperBound...])
            title = String(title[..<dash.lowerBound])
        }
        for article in ["The", "A", "An", "Le", "La", "Les"] where title.hasSuffix(", \(article)") {
            title = "\(article) \(title.dropLast(article.count + 2))"
        }
        // Nom de fichier non reconnu : on garde le titre entier sur une ligne.
        if officialName == nil, let rest = subtitle {
            self.title = "\(title) \(rest)"
            self.subtitle = nil
        } else {
            self.title = title
            self.subtitle = subtitle
        }
        if let open = source.firstIndex(of: "("), let close = source[open...].firstIndex(of: ")") {
            let tag = source[source.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            region = tag.isEmpty ? nil : tag
        } else {
            region = nil
        }
    }
}

/// Images des jaquettes et vignettes, réduites et gardées en mémoire.
enum CoverImages {
    private static let cache = NSCache<NSString, UIImage>()
    private static let sizes = [24, 600, 700]

    private static func key(_ url: URL, _ maxPixel: Int) -> NSString { "\(url.path)#\(maxPixel)" as NSString }

    static func load(_ url: URL, maxPixel: Int = 700) async -> UIImage? {
        if let image = cache.object(forKey: key(url, maxPixel)) { return image }
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: cgImage)
        }.value
        if let image { cache.setObject(image, forKey: key(url, maxPixel)) }
        return image
    }

    static func forget(_ url: URL) {
        for size in sizes { cache.removeObject(forKey: key(url, size)) }
    }
}
