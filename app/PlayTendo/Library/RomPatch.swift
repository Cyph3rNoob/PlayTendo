import Foundation
import os

/// Patchs de romhacks (.ips, .bps, .ups) posés dans Jeux : chacun devient un jeu à part (sa jaquette, ses
/// sauvegardes), joué en appliquant le patch au jeu d'origine au lancement. La copie patchée va dans Caches, le jeu
/// d'origine reste intact (et peut servir à plusieurs patchs). Un BPS ou un UPS trouve son jeu d'origine par la taille
/// et l'empreinte CRC32 inscrites dedans ; un IPS, qui n'en a pas, par le nom : le jeu dont le nom commence le sien
/// (« Super Mario World (USA) » pour « Super Mario World (USA) Kaizo.ips »).
enum RomPatch {
    static let extensions: Set<String> = ["ips", "bps", "ups"]
    /// Consoles à cartouche : le jeu entier tient en mémoire, le patch s'applique d'un coup.
    static let systems: Set<GameSystem> = [.nes, .snes, .n64, .gb, .gbc, .gba, .nds]
    /// Plus gros jeu patché accepté (une ROM DS fait au plus 512 Mo) et plus gros patch : au-delà, le fichier est piégé
    /// ou abîmé, refusé au lieu d'épuiser la mémoire (audit de sécurité du 2026-10-24).
    private static let maxGameSize = 512 << 20
    private static let maxPatchSize = 256 << 20

    enum Failure: LocalizedError {
        case unreadable
        /// Le patch est fait pour une autre version du jeu (empreinte différente).
        case wrongSource
        case damaged

        var errorDescription: String? {
            switch self {
            case .unreadable: tr("Patch ou jeu d'origine illisible.")
            case .wrongSource: tr("Ce patch est fait pour une autre version du jeu d'origine.")
            case .damaged: tr("Patch abîmé : le jeu obtenu n'est pas celui attendu.")
            }
        }
    }

    // MARK: Jeu d'origine

    /// Un jeu par patch dont le jeu d'origine est dans Jeux. Ceux qui n'en ont pas sont notés dans le journal (une fois
    /// par patch et par lancement de l'app).
    static func games(for patches: [URL], among games: [Game]) -> [Game] {
        guard !patches.isEmpty else { return [] }
        let bases = games.filter { systems.contains($0.system) && $0.patchBase == nil }
        var cache = BaseCache.load()
        var result: [Game] = []
        for patch in patches {
            if let base = cache.base(of: patch, among: bases) {
                result.append(Game(url: patch, system: base.system, patchBase: base.url))
            } else if unmatchedLogged.withLock({ $0.insert(patch.path).inserted }) {
                PTLogLine("Patch sans son jeu d'origine dans Jeux : \(patch.lastPathComponent)")
            }
        }
        cache.save()
        return result
    }

    private static let unmatchedLogged = OSAllocatedUnfairLock(initialState: Set<String>())

    /// Jeu d'origine d'un patch : BPS et UPS par taille et empreinte, IPS par le nom.
    fileprivate static func findBase(of patch: URL, among bases: [Game]) -> Game? {
        guard let expected = expectedSource(of: patch) else {
            let name = patch.deletingPathExtension().lastPathComponent.lowercased()
            return bases.filter { name.hasPrefix($0.baseName.lowercased()) }
                .max { $0.baseName.count < $1.baseName.count }
        }
        for base in bases {
            guard let size = (try? base.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                  size == expected.size || (base.system == .snes && size == expected.size + 512),
                  let data = try? Data(contentsOf: base.url, options: .alwaysMapped) else { continue }
            if sources(data, system: base.system).contains(where: { GameIdentifier.crc32($0) == expected.crc }) {
                return base
            }
        }
        return nil
    }

    /// Taille et empreinte du jeu d'origine inscrites dans un BPS ou un UPS (nil pour un IPS).
    private static func expectedSource(of url: URL) -> (size: Int, crc: UInt32)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = [UInt8](handle.readData(ofLength: 16))
        guard head.count >= 5, ["BPS1", "UPS1"].contains(String(decoding: head.prefix(4), as: UTF8.self)),
              let end = try? handle.seekToEnd(), end >= 16, (try? handle.seek(toOffset: end - 12)) != nil else { return nil }
        let footer = [UInt8](handle.readData(ofLength: 4))
        var reader = Reader(bytes: head, offset: 4)
        guard footer.count == 4, let size = reader.number() else { return nil }
        return (size, littleEndian(footer, at: 0))
    }

    /// Le jeu d'origine tel que les patchs l'attendent : ROM N64 dans l'ordre « .z64 » ; ROM SNES avec, puis sans son
    /// en-tête de copieur de 512 octets.
    private static func sources(_ data: Data, system: GameSystem) -> [Data] {
        switch system {
        case .n64: [GameIdentifier.bigEndianN64(data)]
        case .snes where data.count % 1024 == 512: [data, Data(data.dropFirst(512))]
        default: [data]
        }
    }

    // MARK: Lancement

    /// Le jeu patché, prêt à lancer : refait seulement si le patch ou le jeu d'origine ont changé depuis.
    static func prepare(_ game: Game) throws -> URL {
        guard let base = game.patchBase else { return game.url }
        let ext = game.system == .n64 ? "z64" : base.pathExtension
        let name = String(game.key.map { "/:\\".contains($0) ? "_" : $0 })
        let output = folder.appendingPathComponent("\(name).\(ext)")
        let manager = FileManager.default
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
        }
        if manager.fileExists(atPath: output.path), modified(output) > max(modified(game.url), modified(base)) {
            return output
        }
        let patchSize = (try? game.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard patchSize <= maxPatchSize, let patch = try? Data(contentsOf: game.url),
              let original = try? Data(contentsOf: base, options: .alwaysMapped),
              original.count <= maxGameSize else { throw Failure.unreadable }
        var lastError = Failure.wrongSource
        for source in sources(original, system: game.system) {
            do {
                let patched = try apply(patch, to: source)
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                try patched.write(to: output, options: .atomic)
                PTLogLine("Patch appliqué : \(game.url.lastPathComponent) sur \(base.lastPathComponent)")
                return output
            } catch let failure as Failure {
                lastError = failure
            }
        }
        throw lastError
    }

    private static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("RomsPatchees")
    }

    // MARK: Formats

    /// Le jeu patché. BPS et UPS vérifient l'empreinte du jeu d'origine et celle du résultat.
    static func apply(_ patch: Data, to source: Data) throws -> Data {
        let bytes = [UInt8](patch)
        let original = [UInt8](source)
        switch String(decoding: bytes.prefix(5), as: UTF8.self) {
        case "PATCH": return Data(try applyIPS(bytes, to: original))
        case let magic where magic.hasPrefix("BPS1"): return Data(try applyBPS(bytes, to: original))
        case let magic where magic.hasPrefix("UPS1"): return Data(try applyUPS(bytes, to: original))
        default: throw Failure.unreadable
        }
    }

    /// IPS : blocs « adresse (3 octets), taille (2), données », ou taille 0 puis « nombre (2), octet » répété ; « EOF »
    /// à la fin, suivi parfois de la taille finale (3 octets).
    private static func applyIPS(_ patch: [UInt8], to source: [UInt8]) throws -> [UInt8] {
        var output = source
        var position = 5
        func value(_ count: Int) throws -> Int {
            guard position + count <= patch.count else { throw Failure.damaged }
            defer { position += count }
            return patch[position..<position + count].reduce(0) { $0 << 8 | Int($1) }
        }
        func reserve(_ end: Int) {
            if output.count < end { output += [UInt8](repeating: 0, count: end - output.count) }
        }
        while true {
            if position + 3 <= patch.count, patch[position..<position + 3].elementsEqual("EOF".utf8) {
                position += 3
                if position + 3 <= patch.count { output = Array(output.prefix(try value(3))) }
                return output
            }
            let offset = try value(3)
            let count = try value(2)
            if count == 0 {
                let repeated = try value(2)
                let byte = UInt8(try value(1))
                reserve(offset + repeated)
                output.replaceSubrange(offset..<offset + repeated, with: repeatElement(byte, count: repeated))
            } else {
                guard position + count <= patch.count else { throw Failure.damaged }
                reserve(offset + count)
                output.replaceSubrange(offset..<offset + count, with: patch[position..<position + count])
                position += count
            }
        }
    }

    /// BPS : tailles, puis actions (copier du jeu d'origine au même endroit, données du patch, copie depuis ailleurs
    /// dans le jeu d'origine ou dans le résultat), puis trois empreintes (origine, résultat, patch).
    private static func applyBPS(_ patch: [UInt8], to source: [UInt8]) throws -> [UInt8] {
        guard patch.count >= 19 else { throw Failure.damaged }
        let end = patch.count - 12
        guard GameIdentifier.crc32(source) == littleEndian(patch, at: end) else { throw Failure.wrongSource }
        var reader = Reader(bytes: patch, offset: 4)
        guard let sourceSize = reader.number(), let targetSize = reader.number(), let metadata = reader.number(),
              sourceSize == source.count, targetSize <= maxGameSize, metadata <= end else { throw Failure.damaged }
        reader.offset += metadata
        var target = [UInt8](repeating: 0, count: targetSize)
        var written = 0, sourceOffset = 0, targetOffset = 0
        while reader.offset < end {
            guard let action = reader.number() else { throw Failure.damaged }
            let length = action >> 2 + 1
            guard written + length <= targetSize else { throw Failure.damaged }
            switch action & 3 {
            case 0:     // même endroit du jeu d'origine
                guard written + length <= source.count else { throw Failure.damaged }
                target.replaceSubrange(written..<written + length, with: source[written..<written + length])
            case 1:     // données du patch
                guard reader.offset + length <= end else { throw Failure.damaged }
                target.replaceSubrange(written..<written + length, with: patch[reader.offset..<reader.offset + length])
                reader.offset += length
            case 2:     // ailleurs dans le jeu d'origine
                guard let jump = reader.number() else { throw Failure.damaged }
                sourceOffset += (jump & 1 == 1 ? -1 : 1) * (jump >> 1)
                guard sourceOffset >= 0, sourceOffset + length <= source.count else { throw Failure.damaged }
                target.replaceSubrange(written..<written + length, with: source[sourceOffset..<sourceOffset + length])
                sourceOffset += length
            default:    // plus haut dans le résultat (octet par octet : les deux zones peuvent se chevaucher)
                guard let jump = reader.number() else { throw Failure.damaged }
                targetOffset += (jump & 1 == 1 ? -1 : 1) * (jump >> 1)
                guard targetOffset >= 0, targetOffset < written else { throw Failure.damaged }
                for index in 0..<length { target[written + index] = target[targetOffset + index] }
                targetOffset += length
            }
            written += length
        }
        guard GameIdentifier.crc32(target) == littleEndian(patch, at: end + 4) else { throw Failure.damaged }
        return target
    }

    /// UPS : tailles, puis « saut, octets à combiner (XOR) jusqu'à un 0 », puis trois empreintes.
    private static func applyUPS(_ patch: [UInt8], to source: [UInt8]) throws -> [UInt8] {
        guard patch.count >= 18 else { throw Failure.damaged }
        let end = patch.count - 12
        guard GameIdentifier.crc32(source) == littleEndian(patch, at: end) else { throw Failure.wrongSource }
        var reader = Reader(bytes: patch, offset: 4)
        guard let sourceSize = reader.number(), let targetSize = reader.number(),
              sourceSize == source.count, targetSize <= maxGameSize else { throw Failure.damaged }
        var target = Array(source.prefix(targetSize))
        if target.count < targetSize { target += [UInt8](repeating: 0, count: targetSize - target.count) }
        var offset = 0
        while reader.offset < end {
            guard let skip = reader.number(), skip <= maxGameSize else { throw Failure.damaged }
            offset += skip
            while reader.offset < end {
                let byte = patch[reader.offset]
                reader.offset += 1
                if offset < targetSize { target[offset] ^= byte }
                offset += 1
                if byte == 0 { break }
            }
        }
        guard GameIdentifier.crc32(target) == littleEndian(patch, at: end + 4) else { throw Failure.damaged }
        return target
    }

    private static func littleEndian(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }

    /// Nombres des BPS et UPS : 7 bits par octet, le dernier marqué par le bit fort.
    private struct Reader {
        let bytes: [UInt8]
        var offset: Int

        /// nil si le nombre dépasse ce qu'un Int peut contenir (patch piégé) : jamais de plantage par débordement.
        mutating func number() -> Int? {
            var value = 0, shift = 1
            while offset < bytes.count {
                let byte = Int(bytes[offset])
                offset += 1
                let (part, overflow1) = (byte & 0x7F).multipliedReportingOverflow(by: shift)
                let (sum, overflow2) = value.addingReportingOverflow(part)
                guard !overflow1, !overflow2 else { return nil }
                value = sum
                if byte & 0x80 != 0 { return value }
                let (next, overflow3) = shift.multipliedReportingOverflow(by: 128)
                let (total, overflow4) = value.addingReportingOverflow(next)
                guard !overflow3, !overflow4 else { return nil }
                shift = next
                value = total
            }
            return nil
        }
    }
}

/// Jeu d'origine de chaque patch, retenu avec la taille et la date du patch : une relecture de Jeux ne recalcule pas
/// les empreintes (une ROM N64 fait jusqu'à 64 Mo).
private struct BaseCache: Codable {
    struct Entry: Codable {
        let size: Int
        let modified: Double
        let base: String
    }

    private var entries: [String: Entry] = [:]
    private var used = Set<String>()
    private var changed = false

    private static let file = Paths.support.appendingPathComponent("Bibliotheque/patchs.json")

    private enum CodingKeys: String, CodingKey { case entries }

    static func load() -> BaseCache {
        guard let data = try? Data(contentsOf: file),
              let cache = try? JSONDecoder().decode(BaseCache.self, from: data) else { return BaseCache() }
        return cache
    }

    mutating func base(of patch: URL, among bases: [Game]) -> Game? {
        let path = patch.standardizedFileURL.path
        used.insert(path)
        let values = try? patch.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? -1
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        if let entry = entries[path], entry.size == size, entry.modified == modified,
           let base = bases.first(where: { $0.url.standardizedFileURL.path == entry.base }) {
            return base
        }
        // Pas encore trouvé (ou jeu d'origine parti) : cherché de nouveau ; rien n'est retenu s'il manque.
        guard let base = RomPatch.findBase(of: patch, among: bases) else { return nil }
        entries[path] = Entry(size: size, modified: modified, base: base.url.standardizedFileURL.path)
        changed = true
        return base
    }

    mutating func save() {
        let before = entries.count
        entries = entries.filter { used.contains($0.key) }
        guard changed || entries.count != before else { return }
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: Self.file, options: .atomic)
    }
}
