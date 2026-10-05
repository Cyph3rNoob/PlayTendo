import Compression
import Foundation
import zlib

/// Ce qui permet de retrouver un jeu dans la base : l'empreinte CRC32 du fichier (cartouches) et les
/// identifiants inscrits dans le jeu lui-même (code de cartouche, numéro de disque).
struct GameKeys {
    var crcs: [UInt32] = []
    var serials: [String] = []
}

/// Lit les clés d'identification d'un jeu. Ne lit que quelques octets pour les disques (PS1, PSP) et
/// la DS ; les autres cartouches, petites, sont relues en entier pour calculer leur empreinte.
enum GameIdentifier {
    /// Au-delà, on ne calcule pas d'empreinte (trop long à relire sur l'iPhone).
    private static let maxHashedSize = 96 << 20

    static func keys(for url: URL, system: GameSystem) -> GameKeys {
        switch system {
        case .psx: return GameKeys(serials: discSerial(url, system: system).map { [$0] } ?? [])
        case .psp: return GameKeys(serials: discSerial(url, system: system).map { [$0] } ?? [])
        default: return cartridgeKeys(url, system: system)
        }
    }

    // MARK: Cartouches

    private static func cartridgeKeys(_ url: URL, system: GameSystem) -> GameKeys {
        var keys = GameKeys()
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return keys }

        if system == .nds {
            // Code du jeu dans l'en-tête (« IRBF » pour Pokémon Noire, version française).
            if let header = read(url, offset: 0x0C, count: 4), let code = ascii(header) { keys.serials.append(code) }
            guard size <= maxHashedSize else { return keys }
        }
        guard size <= maxHashedSize, var data = try? Data(contentsOf: url, options: .alwaysMapped) else { return keys }

        switch system {
        case .nes:
            keys.crcs.append(crc32(data))                    // la base contient les deux versions
            if data.starts(with: [0x4E, 0x45, 0x53, 0x1A]), data.count > 16 {
                let trainer = data[data.startIndex + 6] & 0x04 != 0 ? 512 : 0
                keys.crcs.append(crc32(data.dropFirst(16 + trainer)))
            } else if data.starts(with: [0x46, 0x44, 0x53, 0x1A]), data.count > 16 {
                keys.crcs.append(crc32(data.dropFirst(16)))  // disquette Famicom avec en-tête
            }
        case .snes:
            keys.crcs.append(crc32(data))
            if data.count % 1024 == 512 { keys.crcs.append(crc32(data.dropFirst(512))) }   // en-tête de copieur
        case .n64:
            data = Self.bigEndianN64(data)
            keys.crcs.append(crc32(data))
            // Identifiant de la cartouche : « N » + 2 lettres + région (« NALP »).
            if data.count > 0x40, let code = ascii(data.subdata(in: 0x3B..<0x3F)) { keys.serials.append(code) }
        case .gba:
            keys.crcs.append(crc32(data))
            if data.count > 0xB0, let code = ascii(data.subdata(in: 0xAC..<0xB0)) { keys.serials.append(code) }
        default:
            keys.crcs.append(crc32(data))
        }
        return keys
    }

    /// Les ROM N64 existent en trois ordres d'octets ; la base utilise l'ordre « .z64 ».
    private static func bigEndianN64(_ data: Data) -> Data {
        guard data.count >= 4, data.count % 4 == 0 else { return data }
        let magic = data.prefix(4)
        var bytes = [UInt8](data)
        if magic == Data([0x37, 0x80, 0x40, 0x12]) {          // .v64 : octets échangés deux à deux
            for i in stride(from: 0, to: bytes.count, by: 2) { bytes.swapAt(i, i + 1) }
        } else if magic == Data([0x40, 0x12, 0x37, 0x80]) {   // .n64 : mots de 4 octets inversés
            for i in stride(from: 0, to: bytes.count, by: 4) {
                bytes.swapAt(i, i + 3)
                bytes.swapAt(i + 1, i + 2)
            }
        } else {
            return data
        }
        return Data(bytes)
    }

    private static func crc32<D: DataProtocol>(_ data: D) -> UInt32 {
        var crc: uLong = 0
        for region in data.regions {
            region.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {                    // zlib compte en UInt32
                    let chunk = min(raw.count - offset, 1 << 30)
                    crc = zlib.crc32(crc, raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: Bytef.self), uInt(chunk))
                    offset += chunk
                }
            }
        }
        return UInt32(truncatingIfNeeded: crc)
    }

    // MARK: Disques (PS1, PSP)

    /// Identifiant du disque, sans tiret : « UCES01401 », « SCES02380 ».
    private static func discSerial(_ url: URL, system: GameSystem) -> String? {
        switch url.pathExtension.lowercased() {
        case "m3u":
            // Premier disque de la liste.
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let first = text.components(separatedBy: .newlines)
                      .map({ $0.trimmingCharacters(in: .whitespaces) })
                      .first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) else { return nil }
            return discSerial(url.deletingLastPathComponent().appendingPathComponent(first), system: system)
        case "cue":
            guard let bin = cueDataTrack(url), let reader = ImageReader(url: bin) else { return nil }
            return ps1Serial(ISO9660(reader: reader))
        case "iso", "bin", "img":
            guard let reader = ImageReader(url: url) else { return nil }
            let iso = ISO9660(reader: reader)
            return system == .psp ? pspSerial(iso) : ps1Serial(iso)
        case "cso":
            guard let reader = CSOReader(url: url) else { return nil }
            return pspSerial(ISO9660(reader: reader))
        case "pbp":
            return pbpSerial(url)
        default:
            return nil                                         // .chd (compressé) : reconnu par son nom
        }
    }

    /// PS1 : SYSTEM.CNF contient « BOOT = cdrom:\SLES_123.45;1 ».
    private static func ps1Serial(_ iso: ISO9660) -> String? {
        guard let data = iso.file("SYSTEM.CNF"), let text = String(data: data, encoding: .ascii),
              let match = text.range(of: #"[A-Z]{4}[_-]?[0-9]{3}\.?[0-9]{2}"#, options: .regularExpression)
        else { return nil }
        return cleanSerial(String(text[match]))
    }

    /// PSP : UMD_DATA.BIN commence par « UCES-01401| », sinon PARAM.SFO donne DISC_ID.
    private static func pspSerial(_ iso: ISO9660) -> String? {
        if let data = iso.file("UMD_DATA.BIN"), let text = String(data: data.prefix(32), encoding: .ascii),
           let first = text.split(separator: "|").first, first.count >= 9 {
            return cleanSerial(String(first))
        }
        if let sfo = iso.file("PSP_GAME/PARAM.SFO") { return sfoDiscID(sfo) }
        return nil
    }

    /// EBOOT.PBP (jeux PSP téléchargés, ou PS1 convertis) : PARAM.SFO est le premier élément.
    private static func pbpSerial(_ url: URL) -> String? {
        guard let header = read(url, offset: 0, count: 40), header.starts(with: [0x00, 0x50, 0x42, 0x50]) else { return nil }
        let start = Int(le32(header, 8)), end = Int(le32(header, 12))
        guard end > start, end - start < 65536, let sfo = read(url, offset: UInt64(start), count: end - start) else { return nil }
        return sfoDiscID(sfo)
    }

    /// Lit la clé DISC_ID d'un fichier PARAM.SFO.
    private static func sfoDiscID(_ sfo: Data) -> String? {
        guard sfo.count > 20, sfo.starts(with: [0x00, 0x50, 0x53, 0x46]) else { return nil }
        let keyTable = Int(le32(sfo, 8)), dataTable = Int(le32(sfo, 12)), count = Int(le32(sfo, 16))
        for i in 0..<min(count, 64) {
            let entry = 20 + i * 16
            guard entry + 16 <= sfo.count else { break }
            let keyOffset = keyTable + Int(le16(sfo, entry))
            let length = Int(le32(sfo, entry + 4)), dataOffset = dataTable + Int(le32(sfo, entry + 12))
            guard keyOffset < sfo.count, dataOffset + length <= sfo.count,
                  let key = cString(sfo, at: keyOffset), key == "DISC_ID" else { continue }
            return cString(sfo, at: dataOffset).map(cleanSerial)
        }
        return nil
    }

    /// Première piste de données d'un .cue (« FILE "Jeu (Track 1).bin" BINARY »).
    private static func cueDataTrack(_ cue: URL) -> URL? {
        guard let text = (try? String(contentsOf: cue, encoding: .utf8)) ?? (try? String(contentsOf: cue, encoding: .isoLatin1)),
              let line = text.components(separatedBy: .newlines).first(where: { $0.uppercased().contains("FILE") }),
              let open = line.firstIndex(of: "\""), let close = line.lastIndex(of: "\""), open < close
        else { return nil }
        return cue.deletingLastPathComponent().appendingPathComponent(String(line[line.index(after: open)..<close]))
    }

    // MARK: Outils

    static func cleanSerial(_ serial: String) -> String {
        String(serial.uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII })
    }

    private static func ascii(_ data: Data) -> String? {
        guard data.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) }) else { return nil }
        return String(data: data, encoding: .ascii)
    }

    private static func cString(_ data: Data, at offset: Int) -> String? {
        guard offset < data.count else { return nil }
        let bytes = data[(data.startIndex + offset)...].prefix { $0 != 0 }
        return String(data: Data(bytes), encoding: .utf8)
    }

    static func le16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) | UInt16(data[data.startIndex + offset + 1]) << 8
    }

    static func le32(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[data.startIndex + offset + $1]) << (8 * UInt32($1)) }
    }

    static func read(_ url: URL, offset: UInt64, count: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.read(upToCount: count),
              data.count == count else { return nil }
        return data
    }
}

// MARK: - Lecture d'images de disque

/// Lit des secteurs de 2048 octets dans une image de disque.
protocol SectorReader {
    func sectors(_ first: Int, count: Int) -> Data?
}

/// Image « .iso » (secteurs de 2048 octets) ou « .bin » brute de CD (2352 octets, données décalées).
struct ImageReader: SectorReader {
    let url: URL
    let sectorSize: Int
    let dataOffset: Int

    init?(url: URL) {
        self.url = url
        // Secteur brut de CD : 12 octets de synchronisation (00 FF … FF 00), puis le mode (octet 15).
        if let raw = GameIdentifier.read(url, offset: 16 * 2352, count: 16),
           raw.prefix(12) == Data([0x00] + [UInt8](repeating: 0xFF, count: 10) + [0x00]) {
            sectorSize = 2352
            dataOffset = raw[15] == 2 ? 24 : 16
        } else {
            sectorSize = 2048
            dataOffset = 0
        }
    }

    func sectors(_ first: Int, count: Int) -> Data? {
        if sectorSize == 2048 {
            return GameIdentifier.read(url, offset: UInt64(first) * 2048, count: count * 2048)
        }
        var data = Data()
        for sector in first..<(first + count) {
            guard let chunk = GameIdentifier.read(url, offset: UInt64(sector) * UInt64(sectorSize) + UInt64(dataOffset),
                                                  count: 2048) else { return nil }
            data.append(chunk)
        }
        return data
    }
}

/// Image PSP compressée « .cso » : blocs compressés (deflate) indexés en tête de fichier.
struct CSOReader: SectorReader {
    let url: URL
    private let blockSize: Int
    private let align: Int
    private let index: [UInt32]

    init?(url: URL) {
        guard let header = GameIdentifier.read(url, offset: 0, count: 24), header.prefix(4) == Data("CISO".utf8) else { return nil }
        self.url = url
        let total = Int(GameIdentifier.le32(header, 8)) | Int(GameIdentifier.le32(header, 12)) << 32
        blockSize = Int(GameIdentifier.le32(header, 16))
        align = Int(header[21])
        guard blockSize > 0, blockSize <= 1 << 20 else { return nil }
        let blocks = (total + blockSize - 1) / blockSize
        guard blocks > 0, blocks < 1 << 24, let table = GameIdentifier.read(url, offset: 24, count: (blocks + 1) * 4) else { return nil }
        index = (0...blocks).map { GameIdentifier.le32(table, $0 * 4) }
    }

    func sectors(_ first: Int, count: Int) -> Data? {
        var out = Data()
        var position = first * 2048
        let end = (first + count) * 2048
        while position < end {
            let block = position / blockSize
            guard block + 1 < index.count, let data = self.block(block) else { return nil }
            let start = position - block * blockSize
            let take = min(end - position, blockSize - start)
            out.append(data.subdata(in: start..<(start + take)))
            position += take
        }
        return out
    }

    private func block(_ number: Int) -> Data? {
        let raw = index[number], next = index[number + 1]
        let start = UInt64(raw & 0x7FFF_FFFF) << align, stop = UInt64(next & 0x7FFF_FFFF) << align
        guard stop > start, let compressed = GameIdentifier.read(url, offset: start, count: Int(stop - start)) else { return nil }
        if raw & 0x8000_0000 != 0 { return compressed.prefix(blockSize) }   // bloc non compressé
        var output = Data(count: blockSize)
        let written = output.withUnsafeMutableBytes { out in
            compressed.withUnsafeBytes { input in
                compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, blockSize,
                                          input.bindMemory(to: UInt8.self).baseAddress!, compressed.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        return written == blockSize ? output : nil
    }
}

/// Système de fichiers ISO 9660 (CD et UMD) : juste de quoi lire un fichier par son chemin.
struct ISO9660 {
    let reader: SectorReader

    func file(_ path: String) -> Data? {
        guard let volume = reader.sectors(16, count: 1), volume.count == 2048,
              volume.subdata(in: 1..<6) == Data("CD001".utf8) else { return nil }
        var extent = Int(GameIdentifier.le32(volume, 156 + 2))
        var size = Int(GameIdentifier.le32(volume, 156 + 10))
        let parts = path.uppercased().split(separator: "/")
        for (index, part) in parts.enumerated() {
            guard let entry = find(String(part), extent: extent, size: size) else { return nil }
            if index == parts.count - 1 {
                guard entry.size < 1 << 22 else { return nil }
                return reader.sectors(entry.extent, count: (entry.size + 2047) / 2048)?.prefix(entry.size)
            }
            extent = entry.extent
            size = entry.size
        }
        return nil
    }

    private func find(_ name: String, extent: Int, size: Int) -> (extent: Int, size: Int)? {
        guard size > 0, size < 1 << 20, let directory = reader.sectors(extent, count: (size + 2047) / 2048) else { return nil }
        var offset = 0
        while offset < min(size, directory.count) {
            let length = Int(directory[offset])
            if length == 0 {
                offset = (offset / 2048 + 1) * 2048                // les entrées ne chevauchent pas deux secteurs
                continue
            }
            guard offset + length <= directory.count, length > 33 else { break }
            let nameLength = Int(directory[offset + 32])
            if offset + 33 + nameLength <= directory.count,
               var entryName = String(data: directory.subdata(in: (offset + 33)..<(offset + 33 + nameLength)), encoding: .ascii) {
                if let semicolon = entryName.firstIndex(of: ";") { entryName = String(entryName[..<semicolon]) }
                if entryName.uppercased() == name {
                    return (Int(GameIdentifier.le32(directory, offset + 2)), Int(GameIdentifier.le32(directory, offset + 10)))
                }
            }
            offset += length
        }
        return nil
    }
}
