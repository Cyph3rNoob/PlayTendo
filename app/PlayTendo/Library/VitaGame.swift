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

    /// Fichier du jeu : lu dans le dossier, ou extrait du .vpk.
    private static func file(_ path: String, of url: URL) -> Data? {
        if url.pathExtension.lowercased() != "vpk" {
            return try? Data(contentsOf: url.appendingPathComponent(path))
        }
        guard let archive = try? ZipArchive(url: url),
              let entry = archive.entries.first(where: { $0.path.lowercased() == path }),
              entry.uncompressedSize < 16 << 20 else { return nil }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (try? archive.extract(entry, to: temporary)) != nil else { return nil }
        return try? Data(contentsOf: temporary)
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
