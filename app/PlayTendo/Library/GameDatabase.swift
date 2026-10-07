import Foundation
import os

/// Jeux connus d'une console, d'après No-Intro (cartouches) et Redump (disques), embarqués dans
/// l'app (Bases/<CONSOLE>.tsv, fabriqués par scripts/build_game_db.py). Le nom officiel d'un jeu
/// est aussi le nom de sa jaquette chez libretro.
final class GameDatabase: @unchecked Sendable {
    private var names: [String] = []
    private var byCRC: [UInt32: Int] = [:]
    private var bySerial: [String: [Int]] = [:]
    /// Mots du titre (sans les mentions entre parenthèses) → jeux, indexés par le premier mot.
    private var titles: [String: [(words: [String], index: Int)]] = [:]

    private static let lock = OSAllocatedUnfairLock<[GameSystem: GameDatabase]>(initialState: [:])

    static func shared(for system: GameSystem) -> GameDatabase? {
        if let database = lock.withLock({ $0[system] }) { return database }
        guard let url = Bundle.main.url(forResource: system.folderName, withExtension: "tsv", subdirectory: "Bases"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let database = GameDatabase(text: text)
        lock.withLock { $0[system] = database }
        return database
    }

    private init(text: String) {
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            let index = names.count
            let name = String(fields[0])
            names.append(name)
            for crc in fields[1].split(separator: ",") {
                if let value = UInt32(crc, radix: 16), byCRC[value] == nil { byCRC[value] = index }
            }
            for serial in fields[2].split(separator: ",") {
                bySerial[String(serial), default: []].append(index)
            }
            for words in Self.titleVariants(name) where !words.isEmpty {
                titles[words[0], default: []].append((words, index))
            }
        }
    }

    // MARK: Recherche

    /// Nom officiel du jeu : d'abord par empreinte, puis par identifiant, enfin par le nom du fichier.
    func identify(keys: GameKeys, fileName: String) -> String? {
        for crc in keys.crcs {
            if let index = byCRC[crc] { return names[index] }
        }
        let hints = Self.regionHints(fileName)
        let revision = Self.revisionTag(fileName)
        for serial in keys.serials {
            if var candidates = bySerial[serial], !candidates.isEmpty {
                // Même code pour plusieurs versions (3DS : « (Rev 1) ») : celle que nomme le fichier d'abord.
                if let revision {
                    let same = candidates.filter { names[$0].lowercased().contains(revision) }
                    if !same.isEmpty { candidates = same }
                }
                return names[best(candidates, hints: hints)]
            }
        }
        return match(fileName: fileName, hints: hints)
    }

    /// Autres noms du même jeu (autres régions), du plus probable au moins probable : utile quand
    /// libretro n'a pas de jaquette pour la version exacte.
    func alternatives(to name: String) -> [String] {
        let words = Self.words(Self.title(of: name))
        guard let first = words.first, let candidates = titles[first] else { return [] }
        let same = candidates.filter { $0.words == words && names[$0.index] != name }.map(\.index)
        let hints = Self.regionHints(name)
        return Array(Set(same)).sorted { score(names[$0], hints: hints) > score(names[$1], hints: hints) }.map { names[$0] }
    }

    /// Le titre officiel le plus long dont les mots commencent le nom du fichier
    /// (« God_of_War_-_Ghost_of_Sparta_EUR_PSP » → « God of War - Ghost of Sparta (Europe) »).
    private func match(fileName: String, hints: [String]) -> String? {
        let fileWords = Self.words(Self.title(of: fileName))
        guard let first = fileWords.first, let candidates = titles[first] else { return nil }
        var bestLength = 0
        var found: [Int] = []
        for candidate in candidates where candidate.words.count <= fileWords.count
            && Array(fileWords.prefix(candidate.words.count)) == candidate.words {
            if candidate.words.count > bestLength {
                bestLength = candidate.words.count
                found = [candidate.index]
            } else if candidate.words.count == bestLength {
                found.append(candidate.index)
            }
        }
        // Un seul mot en commun (« Mario ») ne suffit pas, sauf si c'est tout le nom du fichier.
        guard !found.isEmpty, bestLength >= 2 || bestLength == fileWords.count else { return nil }
        return names[best(found, hints: hints)]
    }

    private func best(_ candidates: [Int], hints: [String]) -> Int {
        candidates.max { score(names[$0], hints: hints) < score(names[$1], hints: hints) } ?? candidates[0]
    }

    /// Préfère la région du fichier, sinon France/Europe, puis les versions définitives (pas de démo…).
    private func score(_ name: String, hints: [String]) -> Int {
        let tags = name.lowercased()
        var score = 0
        for (rank, region) in (hints + ["france", "europe", "world", "usa", "japan"]).enumerated() where tags.contains(region) {
            score += 100 - rank * 10
            break
        }
        for unwanted in ["beta", "proto", "demo", "sample", "kiosk", "virtual console", "pirate", "unl", "aftermarket",
                         "legit cia"]
            where tags.contains("(\(unwanted)") || tags.contains(" \(unwanted)") {
            score -= 200
        }
        if tags.contains("(rev") { score -= 5 }
        return score
    }

    // MARK: Texte

    /// Régions citées dans un nom de fichier (« (Europe) », « _EUR_ », « (USA) »…).
    /// « (rev 1) » si le nom du fichier indique une révision.
    private static func revisionTag(_ fileName: String) -> String? {
        guard let range = fileName.lowercased().range(of: #"\(rev ?\d+\)"#, options: .regularExpression) else { return nil }
        return fileName.lowercased()[range].replacingOccurrences(of: "rev", with: "rev ").replacingOccurrences(of: "rev  ", with: "rev ")
    }

    private static func regionHints(_ fileName: String) -> [String] {
        let tokens = Set(fileName.lowercased().split { !$0.isLetter }.map(String.init))
        var hints: [String] = []
        if !tokens.isDisjoint(with: ["france", "fr", "fra", "fre"]) { hints.append("france") }
        if !tokens.isDisjoint(with: ["europe", "eur", "pal", "eu"]) { hints.append("europe") }
        if !tokens.isDisjoint(with: ["usa", "us", "ntsc"]) { hints.append("usa") }
        if !tokens.isDisjoint(with: ["japan", "jpn", "jap", "jp"]) { hints.append("japan") }
        if tokens.contains("world") { hints.append("world") }
        return hints
    }

    /// Titre sans les mentions entre parenthèses ou crochets.
    static func title(of name: String) -> String {
        var result = ""
        var depth = 0
        for character in name {
            if character == "(" || character == "[" { depth += 1 } else if character == ")" || character == "]" { depth = max(0, depth - 1) } else if depth == 0 { result.append(character) }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Mots en minuscules sans accents ni ponctuation (« Pokémon: Rouge_Feu » → pokemon rouge feu).
    static func words(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// No-Intro écrit « Legend of Zelda, The - … » : on accepte aussi « The Legend of Zelda - … ».
    private static func titleVariants(_ name: String) -> [[String]] {
        let title = Self.title(of: name)
        var variants = [words(title)]
        for article in ["The", "A", "An", "Le", "La", "Les", "Der", "Die", "Das"] {
            let marker = ", \(article)"
            guard let range = title.range(of: marker) else { continue }
            let rest = title[range.upperBound...]
            guard rest.isEmpty || rest.hasPrefix(" ") else { continue }
            variants.append(words("\(article) \(title[..<range.lowerBound])\(rest)"))
        }
        return variants
    }
}
