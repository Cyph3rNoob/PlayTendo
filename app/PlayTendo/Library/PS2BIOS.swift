import Foundation

/// BIOS PS2 de l'utilisateur (Réglages › BIOS PS2) : ceux du dossier BIOS, leur région et leur version lues dans le
/// fichier, celui que le moteur PS2 prendra, et l'import d'un nouveau directement dans BIOS.
enum PS2BIOS {
    struct Info: Identifiable, Equatable, Sendable {
        let url: URL
        /// « Europe · v2.00 », ou nil si la version n'a pas pu être lue.
        let summary: String?

        var id: String { url.lastPathComponent }
        var fileName: String { url.lastPathComponent }
    }

    enum ImportResult: Sendable {
        case added(Info)
        /// Le même BIOS (même contenu) est déjà dans BIOS, sous ce nom.
        case alreadyThere(String)
        case notBIOS
        case failed(String)
    }

    /// Extensions que le moteur PS2 regarde dans le dossier BIOS (PTPS2Host).
    private static let extensions: Set<String> = ["bin", "rom", "rom0"]

    /// BIOS PS2 du dossier BIOS, dans l'ordre où le moteur les essaie.
    static func installed() -> [Info] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.bios, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { GameSystem.isPS2BIOS($0) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .map { Info(url: $0, summary: GameIdentifier.read($0, offset: 0, count: 1 << 20).flatMap(summary(of:))) }
    }

    /// BIOS que la PS2 prendra : celui retenu dans ses réglages s'il est encore là, sinon le premier (comme PTPS2Host).
    static func inUse(among list: [Info]) -> Info? {
        if let chosen = chosenFileName(), let info = list.first(where: { $0.fileName == chosen }) { return info }
        return list.first
    }

    /// Valeur « BIOS » de la partie [Filenames] des réglages du moteur PS2.
    private static func chosenFileName() -> String? {
        guard let text = try? String(contentsOf: Paths.ps2Engine.appendingPathComponent("PCSX2-iOS.ini"), encoding: .utf8)
        else { return nil }
        var section = ""
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                section = trimmed
            } else if section == "[Filenames]", let equal = trimmed.firstIndex(of: "="),
                      trimmed[..<equal].trimmingCharacters(in: .whitespaces) == "BIOS" {
                let value = trimmed[trimmed.index(after: equal)...].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    // MARK: Version

    /// Région et version d'après le fichier ROMVER de la ROM (« 0200EC20040614 » → « Europe · v2.00 »). Le répertoire
    /// ROMDIR commence par l'entrée RESET ; chaque entrée fait 16 octets (nom sur 10, puis tailles) et les fichiers se
    /// suivent dans la ROM à partir du début, alignés sur 16 octets (lecture de BiosTools.cpp de PCSX2).
    static func summary(of data: Data) -> String? {
        let bytes = [UInt8](data.prefix(1 << 20))          // ROMVER est au début de la ROM
        let reset = Array("RESET".utf8) + [0]
        var entry = stride(from: 0, through: min(bytes.count, 512 << 10) - 16, by: 16)
            .first { Array(bytes[$0..<$0 + 6]) == reset }
        var offset = 0
        while let current = entry, current + 16 <= bytes.count {
            let name = bytes[current..<current + 10]
            guard name.first != 0, let end = name.firstIndex(of: 0) else { return nil }
            let size = Int(bytes[current + 12]) | Int(bytes[current + 13]) << 8
                | Int(bytes[current + 14]) << 16 | Int(bytes[current + 15]) << 24
            if String(decoding: name[..<end], as: UTF8.self) == "ROMVER" {
                guard offset + 14 <= bytes.count else { return nil }
                return describe(romver: Array(bytes[offset..<offset + 14]))
            }
            offset += (size + 15) & ~15
            entry = current + 16
        }
        return nil
    }

    private static func describe(romver: [UInt8]) -> String? {
        guard romver.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        let text = String(decoding: romver, as: UTF8.self)
        let characters = Array(text)
        guard let major = Int(String(characters[0..<2])) else { return nil }
        let minor = String(characters[2..<4])
        let zone: String
        switch characters[4] {
        case "J": zone = tr("Japon")
        case "A": zone = tr("Amérique")
        case "E": zone = "Europe"
        case "H": zone = tr("Asie")
        case "C": zone = tr("Chine")
        case "T": zone = tr("Kit de développement")
        case "X": zone = "Test"
        case "P": zone = tr("Sans région")
        default: zone = String(characters[4])
        }
        return "\(zone) · v\(major).\(minor)"
    }

    // MARK: Import

    /// Range dans BIOS le BIOS PS2 choisi par l'utilisateur (n'importe quel nom ; dans une archive .zip, .7z ou .rar,
    /// le premier BIOS trouvé). Rien n'est copié si ce n'en est pas un ou s'il est déjà là.
    static func importFile(_ url: URL) -> ImportResult {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let found: (name: String, data: Data)?
        do {
            if GameLibrary.archiveExtensions.contains(url.pathExtension.lowercased()) {
                found = try firstBIOS(inArchive: url)
            } else {
                let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                guard size == 4 << 20 || size == 8 << 20 else { return .notBIOS }
                let data = try Data(contentsOf: url)
                found = GameSystem.isPS2BIOS(head: data, size: data.count) ? (url.lastPathComponent, data) : nil
            }
        } catch {
            return .failed(error.localizedDescription)
        }
        guard let found else { return .notBIOS }

        for existing in installed() {
            if let data = try? Data(contentsOf: existing.url, options: .mappedIfSafe), data == found.data {
                return .alreadyThere(existing.fileName)
            }
        }
        // Nom gardé ; extension .bin ajoutée si le moteur ne regarderait pas ce fichier.
        var name = found.name
        if !extensions.contains((name as NSString).pathExtension.lowercased()) { name += ".bin" }
        let target = uniqueURL(for: name)
        do {
            try FileManager.default.createDirectory(at: Paths.bios, withIntermediateDirectories: true)
            try found.data.write(to: target, options: .atomic)
        } catch {
            return .failed(error.localizedDescription)
        }
        let info = Info(url: target, summary: summary(of: found.data))
        PTLogLine("BIOS PS2 importé : \(info.fileName) (\(info.summary ?? "version inconnue"))")
        return .added(info)
    }

    /// Premier fichier de l'archive qui est un BIOS PS2 (seuls ceux de 4 ou 8 Mo sont lus).
    private static func firstBIOS(inArchive url: URL) throws -> (name: String, data: Data)? {
        let archive = try PTArchiveReader(url: url)
        while try archive.nextEntry() {
            guard [-1, 4 << 20, 8 << 20].contains(archive.entrySize),
                  let data = try? archive.readEntry(withLimit: 8 << 20),
                  GameSystem.isPS2BIOS(head: data, size: data.count) else { continue }
            return ((archive.entryPath as NSString).lastPathComponent, data)
        }
        return nil
    }

    /// « nom.bin », ou « nom 2.bin »… si un autre fichier porte déjà ce nom.
    private static func uniqueURL(for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var url = Paths.bios.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = Paths.bios.appendingPathComponent("\(base) \(number).\(ext)")
            number += 1
        }
        return url
    }
}
