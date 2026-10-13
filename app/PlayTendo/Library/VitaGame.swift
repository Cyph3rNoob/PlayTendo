// PS Vita : compilé seulement avec PLAYTENDO_VITA (par défaut dans scripts/build_app.sh).
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

    /// Nom du jeu, sans les symboles de marque (« GRAVITY RUSH™ » → « GRAVITY RUSH » ; « PlayStation®Vita » →
    /// « PlayStation Vita »).
    static func title(of url: URL) -> String? {
        guard let title = parameters(of: url)["TITLE"] else { return nil }
        let cleaned = title.replacingOccurrences(of: "™", with: " ").replacingOccurrences(of: "®", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ").joined(separator: " ")
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Nom du jeu à la façon des bases de jeux (« Gravity Rush (USA) ») : titre de la fiche, remis en casse de titre
    /// s'il est tout en majuscules, et région d'après l'identifiant. Sert à chercher la jaquette (libretro, puis
    /// SteamGridDB) et à l'affichage (titre et région).
    static func officialName(of url: URL) -> String? {
        guard var title = title(of: url) else { return nil }
        if title == title.uppercased(), title != title.lowercased() { title = title.capitalized }
        guard let region = titleID(of: url).flatMap(region(of:)) else { return title }
        return "\(title) (\(region))"
    }

    /// Région d'un jeu du commerce d'après les 4 premières lettres de son identifiant.
    private static func region(of titleID: String) -> String? {
        switch titleID.prefix(4) {
        case "PCSA", "PCSE": "USA"
        case "PCSB", "PCSF": "Europe"
        case "PCSC", "PCSG": "Japan"
        case "PCSD", "PCSH": "Asia"
        default: nil
        }
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
    /// `saveFolder` (nom donné par saveFolderName, lu avant la désinstallation) : ses sauvegardes sont supprimées
    /// aussi, sauf si un autre jeu installé se sert du même dossier.
    static func uninstall(titleID: String, removingSavesIn saveFolder: String? = nil) {
        guard !titleID.isEmpty, !titleID.contains("/"), !titleID.hasPrefix(".") else { return }
        let manager = FileManager.default
        let ux0 = Paths.vitaEngine.appendingPathComponent("vita/ux0", isDirectory: true)
        var saves = "sauvegardes conservées"
        if let saveFolder {
            let sharing = installedGames().filter { $0.lastPathComponent != titleID && saveFolderName(of: $0) == saveFolder }
            if sharing.isEmpty {
                // Un dossier par compte de la console (« 00 » chez PlayTendo).
                let users = ux0.appendingPathComponent("user", isDirectory: true)
                for user in (try? manager.contentsOfDirectory(atPath: users.path)) ?? [] where !user.hasPrefix(".") {
                    try? manager.removeItem(at: users.appendingPathComponent("\(user)/savedata/\(saveFolder)"))
                }
                saves = "sauvegardes supprimées (\(saveFolder))"
            } else {
                saves = "sauvegardes conservées : \(saveFolder) sert aussi à "
                    + sharing.map(\.lastPathComponent).joined(separator: ", ")
            }
        }
        for folder in ["app", "patch", "addcont", "license"] {
            try? manager.removeItem(at: ux0.appendingPathComponent(folder).appendingPathComponent(titleID))
        }
        PTLogLine("Vita : \(titleID) désinstallé (\(saves))")
    }

    /// Dossier des sauvegardes d'un jeu (ux0/user/00/savedata/…) : INSTALL_DIR_SAVEDATA de sa fiche s'il y en a un
    /// (LittleBigPlanet Marvel, PCSA00549, se sert de PCSA00017), sinon son identifiant, comme Vita3K (sfo.cpp).
    static func saveFolderName(of url: URL) -> String? {
        let parameters = parameters(of: url)
        let name = parameters["INSTALL_DIR_SAVEDATA"].flatMap { $0.isEmpty ? nil : $0 } ?? parameters["TITLE_ID"]
        guard let name, !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { return nil }
        return name
    }

    /// Retire du dossier Jeux l'original d'un jeu installé, si la copie installée est complète (au moins 90 % de
    /// la taille de l'original : une installation interrompue garde son original). Les dossiers qui le contenaient
    /// sont retirés aussi s'ils ne contiennent plus rien.
    static func removeOriginal(_ original: URL, titleID: String) {
        removeOriginal(original, installedAt: installedAppsFolder.appendingPathComponent(titleID), kept: "le jeu reste installé")
    }

    /// Même chose pour un DLC ou une mise à jour (`installed` : sa copie dans la mémoire de la console).
    /// Mise à jour déjà fusionnée dans le jeu installé (Addon.isInstalled) : son original quitte Jeux.
    static func removeInstalledUpdate(_ addon: Addon) {
        let games = Paths.games.resolvingSymlinksInPath().path + "/"
        guard addon.kind == .update, addon.isInstalled, addon.url.resolvingSymlinksInPath().path.hasPrefix(games) else { return }
        let bytes = size(of: addon.url)
        do {
            try FileManager.default.removeItem(at: addon.url)
        } catch {
            PTLogLine("Vita : original impossible à retirer de Jeux (\(error.localizedDescription))")
            return
        }
        PTLogLine(String(format: "Vita : original retiré du dossier Jeux (%@, %.2f Go libérés), la mise à jour %@ est dans le jeu installé",
                         addon.url.lastPathComponent, Double(bytes) / 1e9, addon.label))
        removeEmptyFolders(containing: addon.url)
    }

    static func removeOriginal(_ original: URL, installedAt installed: URL, kept: String) {
        let manager = FileManager.default
        let games = Paths.games.resolvingSymlinksInPath().path + "/"
        guard original.resolvingSymlinksInPath().path.hasPrefix(games), manager.fileExists(atPath: original.path) else { return }
        let originalSize = size(of: original)
        let installedSize = size(of: installed)
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
        PTLogLine(String(format: "Vita : original retiré du dossier Jeux (%@, %.2f Go libérés), %@",
                         original.lastPathComponent, Double(originalSize) / 1e9, kept))
        removeEmptyFolders(containing: original)
    }

    /// Dossiers de Jeux devenus vides après le départ d'un jeu (« app » extrait d'une Vita, « app ( Gravity Rush ) »…) :
    /// retirés en remontant, jamais le dossier Jeux lui-même. Avant le 2026-10-12, seul un dossier nommé « app » l'était.
    static func removeEmptyFolders(containing game: URL) {
        let games = Paths.games.resolvingSymlinksInPath().path + "/"
        var folder = game.deletingLastPathComponent()
        while folder.resolvingSymlinksInPath().path.hasPrefix(games),
              let rest = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
              rest.allSatisfy({ $0.hasPrefix(".") }),
              (try? FileManager.default.removeItem(at: folder)) != nil {
            PTLogLine("Dossier vide retiré de Jeux : \(folder.lastPathComponent)")
            folder = folder.deletingLastPathComponent()
        }
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

    // MARK: DLC et mises à jour

    /// Contenu d'un dossier ou d'un .vpk PS Vita, d'après la catégorie de sa fiche (CATEGORY de param.sfo) : jeu (gd,
    /// gc…), mise à jour (gp) ou DLC (ac). Vita3K installe les deux derniers dans ux0/patch et ux0/addcont.
    enum Kind { case game, update, dlc }

    static func kind(of url: URL) -> Kind { kind(parameters(of: url)) }

    private static func kind(_ parameters: [String: String]) -> Kind {
        let category = parameters["CATEGORY"] ?? ""
        if category.hasPrefix("gp") { return .update }
        if category == "ac" { return .dlc }
        return .game
    }

    /// DLC ou mise à jour rangé dans Jeux, installé au prochain lancement de son jeu.
    struct Addon {
        let url: URL
        let kind: Kind
        let titleID: String
        /// DLC : son nom ; mise à jour : sa version (« 1.01 »).
        let label: String
        /// DLC : sa copie dans la mémoire de la console, une fois installé (vérifie que l'installation est complète).
        /// Mise à jour : nil, Vita3K la fusionne dans le jeu installé (voir isInstalled).
        let installedURL: URL?
        /// Mise à jour : sa version telle qu'écrite dans sa fiche (« 01.15 »).
        let version: String?

        /// Mise à jour déjà dans le jeu installé : Vita3K copie ses fichiers dans ux0/app/<identifiant> puis efface
        /// ux0/patch (io.cpp, copy_path) ; la version du jeu installé est alors au moins la sienne.
        var isInstalled: Bool {
            guard kind == .update, let version,
                  let installed = VitaGame.parameters(of: VitaGame.installedAppsFolder.appendingPathComponent(titleID))["APP_VER"]
            else { return false }
            return VitaGame.compareVersions(installed, version) >= 0
        }
    }

    static func addon(at url: URL) -> Addon? {
        let parameters = parameters(of: url)
        let kind = kind(parameters)
        guard kind != .game, let titleID = parameters["TITLE_ID"], !titleID.isEmpty, !titleID.contains("/"),
              !titleID.hasPrefix(".") else { return nil }
        let ux0 = Paths.vitaEngine.appendingPathComponent("vita/ux0", isDirectory: true)
        if kind == .update {
            return Addon(url: url, kind: kind, titleID: titleID, label: displayVersion(parameters["APP_VER"]) ?? "?",
                         installedURL: nil, version: parameters["APP_VER"])
        }
        // Comme Vita3K (interface.cpp) : ux0/addcont/<identifiant>/<CONTENT_ID sans ses 20 premiers caractères>.
        let content = parameters["CONTENT_ID"] ?? ""
        let folder = content.count > 20 ? String(content.dropFirst(20)) : nil
        let safeFolder = folder.flatMap { $0.contains("/") || $0.hasPrefix(".") ? nil : $0 }
        let name = parameters["TITLE"].map { $0.replacingOccurrences(of: "™", with: " ").replacingOccurrences(of: "®", with: " ")
            .replacingOccurrences(of: "\n", with: " ").split(separator: " ").joined(separator: " ") }
        return Addon(url: url, kind: kind, titleID: titleID, label: name.flatMap { $0.isEmpty ? nil : $0 } ?? folder ?? titleID,
                     installedURL: safeFolder.map { ux0.appendingPathComponent("addcont/\(titleID)/\($0)", isDirectory: true) },
                     version: nil)
    }

    /// DLC et mises à jour rangés dans Jeux (dossiers extraits de la Vita, .vpk), d'un jeu ou de tous. La mise à jour
    /// d'abord : le moteur ne l'installe que si le jeu l'est.
    static func pendingAddons(for titleID: String? = nil) -> [Addon] {
        guard let enumerator = FileManager.default.enumerator(at: Paths.games, includingPropertiesForKeys: [.isDirectoryKey],
                                                              options: [.skipsHiddenFiles]) else { return [] }
        var result: [Addon] = []
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDirectory, isGameFolder(url) {
                enumerator.skipDescendants()
            } else if isDirectory || url.pathExtension.lowercased() != "vpk" {
                continue
            }
            if let addon = addon(at: url), titleID == nil || addon.titleID == titleID { result.append(addon) }
        }
        return result.sorted { ($0.kind == .update ? 0 : 1) < ($1.kind == .update ? 0 : 1) }
    }

    /// Version installée d'un jeu (celle de sa mise à jour s'il en a une) et nombre de ses DLC installés.
    static func installedContent(titleID: String) -> (version: String?, dlcCount: Int) {
        let ux0 = Paths.vitaEngine.appendingPathComponent("vita/ux0", isDirectory: true)
        let version = displayVersion(parameters(of: ux0.appendingPathComponent("patch/\(titleID)"))["APP_VER"])
            ?? displayVersion(parameters(of: installedAppsFolder.appendingPathComponent(titleID))["APP_VER"])
        let dlc = (try? FileManager.default.contentsOfDirectory(atPath: ux0.appendingPathComponent("addcont/\(titleID)").path))?
            .filter { !$0.hasPrefix(".") }.count ?? 0
        return (version, dlc)
    }

    /// Ce qui identifie un contenu (même jeu, même DLC, même version de mise à jour) : sert à ne pas importer deux fois
    /// la même chose.
    static func identity(of url: URL) -> String {
        let parameters = parameters(of: url)
        return ["TITLE_ID", "CATEGORY", "CONTENT_ID", "APP_VER"].map { parameters[$0] ?? "" }.joined(separator: "|")
    }

    // MARK: rePatch

    /// Mod pour le plugin rePatch d'une Vita modifiée : dossier `rePatch/<identifiant>` (n'importe où dans Jeux) dont
    /// les fichiers, déjà déchiffrés, remplacent ceux du jeu (AKIBA'S TRIP « Uncensored », 2026-10-13). Vita3K ne le
    /// gère pas : le moteur accepte qu'un fichier qu'il fournit manque au jeu (PTVitaSetRePatch), puis ses fichiers sont
    /// copiés sur le jeu installé (applyRePatch), à chaque lancement s'ils ont changé. Gardé dans Jeux (copie par
    /// clone : pas de place en plus sur le même disque).
    static func rePatchFolder(for titleID: String) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: Paths.games, includingPropertiesForKeys: [.isDirectoryKey],
                                                              options: [.skipsHiddenFiles]) else { return nil }
        let wanted = titleID.lowercased()
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if isGameFolder(url) {
                enumerator.skipDescendants()
                continue
            }
            if url.lastPathComponent.lowercased() == wanted,
               url.deletingLastPathComponent().lastPathComponent.lowercased() == "repatch" {
                return url
            }
        }
        return nil
    }

    /// Copie les fichiers de rePatch sur le jeu installé (ceux qui ont changé : taille ou date). Renvoie le nombre de
    /// fichiers copiés, ou nil en cas d'échec (noté au Journal).
    @discardableResult
    static func applyRePatch(_ folder: URL, titleID: String) -> Int? {
        let manager = FileManager.default
        let app = installedAppsFolder.appendingPathComponent(titleID, isDirectory: true)
        guard manager.fileExists(atPath: app.path),
              let enumerator = manager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey,
                                                                                          .contentModificationDateKey],
                                                  options: [.skipsHiddenFiles]) else { return nil }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let base = folder.resolvingSymlinksInPath().path + "/"
        var copied = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            let relative = String(file.resolvingSymlinksInPath().path.dropFirst(base.count))
            let target = existingPath(relative, in: app) ?? app.appendingPathComponent(relative)
            if let current = try? target.resourceValues(forKeys: keys), current.fileSize == values.fileSize,
               current.contentModificationDate == values.contentModificationDate {
                continue
            }
            do {
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
                try manager.copyItem(at: file, to: target)
                copied += 1
            } catch {
                PTLogLine("Vita : rePatch de \(titleID), \(relative) non copié (\(error.localizedDescription))")
                return nil
            }
        }
        PTLogLine(copied > 0 ? "Vita : rePatch de \(titleID) appliqué (\(copied) fichier(s) copié(s) sur le jeu installé)"
                             : "Vita : rePatch de \(titleID) déjà appliqué")
        return copied
    }

    /// Fichier du jeu installé qui porte ce chemin sans tenir compte des majuscules (comme sur une Vita), ou nil.
    private static func existingPath(_ relative: String, in root: URL) -> URL? {
        var current = root
        for part in relative.split(separator: "/") {
            let wanted = part.lowercased()
            guard let match = (try? FileManager.default.contentsOfDirectory(atPath: current.path))?
                .first(where: { $0.lowercased() == wanted }) else { return nil }
            current = current.appendingPathComponent(match)
        }
        return current
    }

    /// Version d'un jeu, d'un DLC ou d'une mise à jour d'après sa fiche (« 1.00 »).
    static func version(of url: URL) -> String? { displayVersion(parameters(of: url)["APP_VER"]) }

    /// Compare deux versions « 01.15 » / « 1.2 » nombre par nombre : négatif, 0 ou positif.
    static func compareVersions(_ a: String, _ b: String) -> Int {
        let left = a.split(separator: ".").map { Int($0) ?? 0 }
        let right = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    /// « 01.01 » → « 1.01 ».
    private static func displayVersion(_ version: String?) -> String? {
        guard let version, !version.isEmpty else { return nil }
        let parts = version.split(separator: ".", maxSplits: 1)
        guard let major = parts.first.flatMap({ Int($0) }) else { return version }
        return parts.count > 1 ? "\(major).\(parts[1])" : "\(major)"
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
