// PS Vita : compilé seulement avec PLAYTENDO_VITA (PLAYTENDO_VITA=1 zsh scripts/build_app.sh).
#if PLAYTENDO_VITA
import Foundation

/// Jeux PS Vita : un dossier extrait d'une Vita (« PCSA00011 », avec sce_sys/param.sfo ; un jeu du commerce garde sa
/// licence dans sce_sys/package/work.bin) ou une archive .vpk. Le moteur les installe une fois dans la mémoire de la
/// console avant la première partie (EmulatorSession).
enum VitaGame {
    /// Dossier de jeu extrait : il contient sce_sys/param.sfo.
    static func isGameFolder(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("sce_sys/param.sfo").path)
    }

    /// Fiche du jeu (param.sfo) : identifiant (TITLE_ID), nom (TITLE), version…
    static func parameters(of url: URL) -> [String: String] {
        guard let data = file("sce_sys/param.sfo", of: url) else { return [:] }
        return parseSFO(data)
    }

    static func titleID(of url: URL) -> String? {
        parameters(of: url)["TITLE_ID"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Nom du jeu, sans les symboles de marque (« GRAVITY RUSH™ » → « GRAVITY RUSH »).
    static func title(of url: URL) -> String? {
        guard let title = parameters(of: url)["TITLE"] else { return nil }
        let cleaned = title.replacingOccurrences(of: "™", with: "").replacingOccurrences(of: "®", with: "")
            .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Icône du jeu (sce_sys/icon0.png, 128 × 128).
    static func icon(of url: URL) -> Data? {
        file("sce_sys/icon0.png", of: url)
    }

    // MARK: Jeux installés

    /// Jeux installés dans la mémoire de la console (ux0/app/<identifiant>). Une fois un jeu installé, son original
    /// est retiré du dossier Jeux (demandé le 2026-10-10 : chaque jeu prenait deux fois sa place, et effacer
    /// l'original laissait la copie installée invisible) ; la bibliothèque montre alors la copie installée.
    static var installedAppsFolder: URL {
        Paths.vitaEngine.appendingPathComponent("vita/ux0/app", isDirectory: true)
    }

    static func installedGames() -> [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: installedAppsFolder, includingPropertiesForKeys: nil,
                                                                    options: [.skipsHiddenFiles])) ?? []
        return folders.filter(isGameFolder)
    }

    /// Copie installée (et non original du dossier Jeux).
    static func isInstalledCopy(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().path.hasPrefix(installedAppsFolder.resolvingSymlinksInPath().path + "/")
    }

    /// Désinstalle un jeu (le jeu, ses mises à jour, ses contenus additionnels et sa licence). Ses sauvegardes,
    /// dans ux0/user, restent.
    static func uninstall(titleID: String) {
        guard !titleID.isEmpty, !titleID.contains("/"), !titleID.hasPrefix(".") else { return }
        let ux0 = Paths.vitaEngine.appendingPathComponent("vita/ux0", isDirectory: true)
        for folder in ["app", "patch", "addcont", "license"] {
            try? FileManager.default.removeItem(at: ux0.appendingPathComponent(folder).appendingPathComponent(titleID))
        }
        PTLogLine("Vita : \(titleID) désinstallé (sauvegardes conservées)")
    }

    /// Retire du dossier Jeux l'original d'un jeu installé, si la copie installée est complète (au moins 90 % de
    /// la taille de l'original : une installation interrompue garde son original). Le dossier qui le contenait
    /// (« app » extrait d'une Vita) est retiré aussi s'il ne contient plus rien.
    static func removeOriginal(_ original: URL, titleID: String) {
        let manager = FileManager.default
        let games = Paths.games.resolvingSymlinksInPath().path + "/"
        guard original.resolvingSymlinksInPath().path.hasPrefix(games), manager.fileExists(atPath: original.path) else { return }
        let originalSize = size(of: original)
        let installedSize = size(of: installedAppsFolder.appendingPathComponent(titleID))
        guard installedSize > 0, Double(installedSize) >= Double(originalSize) * 0.9 else {
            PTLogLine(String(format: "Vita : original gardé dans Jeux, copie installée incomplète (%.2f Go sur %.2f Go)",
                             Double(installedSize) / 1e9, Double(originalSize) / 1e9))
            return
        }
        do {
            try manager.removeItem(at: original)
        } catch {
            PTLogLine("Vita : original impossible à retirer de Jeux (\(error.localizedDescription))")
            return
        }
        PTLogLine(String(format: "Vita : original retiré du dossier Jeux (%@, %.2f Go libérés), le jeu reste installé",
                         original.lastPathComponent, Double(originalSize) / 1e9))
        removeEmptyAppFolder(containing: original)
    }

    /// Dossier « app » (celui qu'on obtient en extrayant un jeu d'une Vita) resté vide dans Jeux : retiré. Les
    /// autres dossiers, rangés par l'utilisateur, restent même vides.
    static func removeEmptyAppFolder(containing game: URL) {
        let parent = game.deletingLastPathComponent()
        let games = Paths.games.resolvingSymlinksInPath().path + "/"
        guard parent.lastPathComponent.lowercased() == "app", parent.resolvingSymlinksInPath().path.hasPrefix(games),
              let rest = try? FileManager.default.contentsOfDirectory(atPath: parent.path),
              rest.allSatisfy({ $0.hasPrefix(".") }) else { return }
        try? FileManager.default.removeItem(at: parent)
    }

    /// Taille d'un fichier ou d'un dossier (somme de ses fichiers), en octets.
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return Int64(values.fileSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            if let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    /// Fichier du jeu : lu dans le dossier, ou extrait du .vpk.
    private static func file(_ path: String, of url: URL) -> Data? {
        if url.pathExtension.lowercased() != "vpk" {
            return try? Data(contentsOf: url.appendingPathComponent(path))
        }
        guard let archive = try? PTArchiveReader(url: url) else { return nil }
        while (try? archive.nextEntry()) == true {
            if archive.entryPath.lowercased() == path { return try? archive.readEntry(withLimit: 16 << 20) }
        }
        return nil
    }

    /// Format SFO de Sony : en-tête « \0PSF », table des clés, table des valeurs (texte UTF-8 ou entier).
    static func parseSFO(_ data: Data) -> [String: String] {
        let bytes = [UInt8](data)
        func u16(_ offset: Int) -> Int { offset + 2 <= bytes.count ? Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 : 0 }
        func u32(_ offset: Int) -> Int { offset + 4 <= bytes.count ? u16(offset) | u16(offset + 2) << 16 : 0 }
        guard bytes.count >= 20, bytes[0] == 0, bytes[1] == 0x50, bytes[2] == 0x53, bytes[3] == 0x46 else { return [:] }
        let keyTable = u32(8), dataTable = u32(12), count = u32(16)
        var result: [String: String] = [:]
        for index in 0..<min(count, 256) {
            let entry = 20 + index * 16
            guard entry + 16 <= bytes.count else { break }
            let keyStart = keyTable + u16(entry)
            let format = u16(entry + 2), length = u32(entry + 4), valueStart = dataTable + u32(entry + 12)
            guard keyStart < bytes.count, valueStart + length <= bytes.count else { continue }
            let keyEnd = bytes[keyStart...].firstIndex(of: 0) ?? bytes.count
            let key = String(decoding: bytes[keyStart..<keyEnd], as: UTF8.self)
            if format == 0x0404 {
                result[key] = String(u32(valueStart))
            } else {
                let value = bytes[valueStart..<(valueStart + length)]
                let end = value.firstIndex(of: 0) ?? value.endIndex
                result[key] = String(decoding: value[value.startIndex..<end], as: UTF8.self)
            }
        }
        return result
    }

    // MARK: Firmware

    /// Fichiers de mise à jour officiels (.PUP) du dossier BIOS : le firmware (PSVUPDAT.PUP) d'abord, puis les autres
    /// (paquet de polices PSP2UPDAT.PUP).
    static func firmwareFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.bios, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "pup" && isFirmware($0) }
            .sorted { lhs, rhs in
                let first = lhs.lastPathComponent.uppercased().contains("PSVUPDAT")
                let second = rhs.lastPathComponent.uppercased().contains("PSVUPDAT")
                return first != second ? first : lhs.lastPathComponent < rhs.lastPathComponent
            }
    }

    /// Fichier .PUP de Sony : il commence par « SCEUF ».
    static func isFirmware(_ url: URL) -> Bool {
        GameIdentifier.read(url, offset: 0, count: 5) == Data("SCEUF".utf8)
    }

    /// .PUP déjà installés (nom et taille), notés dans la mémoire de la console : on ne sait ce qu'un .PUP contient
    /// qu'en l'installant (le déchiffrer), et PSVUPDAT.PUP n'a pas les polices → sans cette liste, il était réinstallé
    /// à chaque lancement pour les chercher (5 à 6 s perdues, vu le 2026-10-08). Effacée avec la mémoire de la console.
    private static var installedListURL: URL { Paths.vitaEngine.appendingPathComponent("pup-installes.txt") }

    private static func firmwareKey(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return "\(url.lastPathComponent)|\(size)"
    }

    static func wasInstalled(_ url: URL) -> Bool {
        let list = (try? String(contentsOf: installedListURL, encoding: .utf8)) ?? ""
        return list.split(separator: "\n").contains { $0 == firmwareKey(url) }
    }

    static func markInstalled(_ url: URL) {
        guard !wasInstalled(url) else { return }
        let list = (try? String(contentsOf: installedListURL, encoding: .utf8)) ?? ""
        try? (list + firmwareKey(url) + "\n").write(to: installedListURL, atomically: true, encoding: .utf8)
    }
}
#endif
