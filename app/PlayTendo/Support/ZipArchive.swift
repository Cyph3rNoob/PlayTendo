import Compression
import Foundation

/// Lecteur ZIP minimal (méthodes « stockée » et « deflate »), avec décompression en
/// flux pour ne jamais charger un gros fichier entier en mémoire.
struct ZipArchive {
    struct Entry {
        let path: String
        let method: UInt16
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
    }

    enum ZipError: LocalizedError {
        case notAZip, unsupported(String), corrupted

        var errorDescription: String? {
            switch self {
            case .notAZip: "Ce fichier n'est pas une archive ZIP valide."
            case .unsupported(let what): "Archive ZIP non prise en charge (\(what))."
            case .corrupted: "Archive ZIP endommagée."
            }
        }
    }

    let url: URL
    let entries: [Entry]

    init(url: URL) throws {
        self.url = url
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        let tailSize = min(fileSize, 65_557)
        try handle.seek(toOffset: fileSize - tailSize)
        let tail = handle.readData(ofLength: Int(tailSize))
        guard let eocd = Self.lastIndex(of: 0x0605_4B50, in: tail) else { throw ZipError.notAZip }

        let entryCount = Int(tail.uint16(at: eocd + 10))
        let directorySize = Int(tail.uint32(at: eocd + 12))
        let directoryOffset = UInt64(tail.uint32(at: eocd + 16))
        if directoryOffset == 0xFFFF_FFFF { throw ZipError.unsupported("ZIP64") }

        try handle.seek(toOffset: directoryOffset)
        let directory = handle.readData(ofLength: directorySize)
        var entries: [Entry] = []
        var offset = 0
        for _ in 0..<entryCount {
            guard offset + 46 <= directory.count, directory.uint32(at: offset) == 0x0201_4B50 else { throw ZipError.corrupted }
            let flags = directory.uint16(at: offset + 8)
            let method = directory.uint16(at: offset + 10)
            let compressed = UInt64(directory.uint32(at: offset + 20))
            let uncompressed = UInt64(directory.uint32(at: offset + 24))
            let nameLength = Int(directory.uint16(at: offset + 28))
            let extraLength = Int(directory.uint16(at: offset + 30))
            let commentLength = Int(directory.uint16(at: offset + 32))
            let localOffset = UInt64(directory.uint32(at: offset + 42))
            guard offset + 46 + nameLength <= directory.count else { throw ZipError.corrupted }
            let nameData = directory.subdata(in: (offset + 46)..<(offset + 46 + nameLength))
            let name = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? "?"
            offset += 46 + nameLength + extraLength + commentLength

            if name.hasSuffix("/") || name.hasPrefix("__MACOSX/") { continue }
            if flags & 1 != 0 { throw ZipError.unsupported("archive chiffrée") }
            if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF { throw ZipError.unsupported("ZIP64") }
            entries.append(Entry(path: name, method: method, compressedSize: compressed,
                                 uncompressedSize: uncompressed, localHeaderOffset: localOffset))
        }
        self.entries = entries
    }

    func extract(_ entry: Entry, to destination: URL) throws {
        guard entry.method == 0 || entry.method == 8 else { throw ZipError.unsupported("méthode \(entry.method)") }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        try input.seek(toOffset: entry.localHeaderOffset)
        let header = input.readData(ofLength: 30)
        guard header.count == 30, header.uint32(at: 0) == 0x0403_4B50 else { throw ZipError.corrupted }
        let skip = UInt64(header.uint16(at: 26)) + UInt64(header.uint16(at: 28))
        try input.seek(toOffset: entry.localHeaderOffset + 30 + skip)

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        var success = false
        defer {
            try? output.close()
            if !success { try? FileManager.default.removeItem(at: destination) }
        }

        let chunkSize = 1 << 20
        var remaining = Int(entry.compressedSize)
        if entry.method == 0 {
            while remaining > 0 {
                let chunk = input.readData(ofLength: min(remaining, chunkSize))
                guard !chunk.isEmpty else { throw ZipError.corrupted }
                output.write(chunk)
                remaining -= chunk.count
            }
            success = true
            return
        }

        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ZipError.corrupted
        }
        defer { compression_stream_destroy(streamPointer) }

        let outBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { outBuffer.deallocate() }
        let empty = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { empty.deallocate() }

        var finished = false
        while !finished {
            let chunk = remaining > 0 ? input.readData(ofLength: min(remaining, chunkSize)) : Data()
            if remaining > 0 && chunk.isEmpty { throw ZipError.corrupted }
            remaining -= chunk.count
            let isLast = remaining == 0
            try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                streamPointer.pointee.src_ptr = UnsafePointer(raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(empty))
                streamPointer.pointee.src_size = raw.count
                var idleRounds = 0
                while true {
                    streamPointer.pointee.dst_ptr = outBuffer
                    streamPointer.pointee.dst_size = chunkSize
                    let flags = isLast ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                    let status = compression_stream_process(streamPointer, flags)
                    let produced = chunkSize - streamPointer.pointee.dst_size
                    if produced > 0 { output.write(Data(bytes: outBuffer, count: produced)) }
                    switch status {
                    case COMPRESSION_STATUS_END:
                        finished = true
                        return
                    case COMPRESSION_STATUS_OK:
                        if streamPointer.pointee.src_size == 0 && produced < chunkSize {
                            if !isLast { return }
                            idleRounds += 1
                            if idleRounds > 4 { throw ZipError.corrupted }
                        }
                    default:
                        throw ZipError.corrupted
                    }
                }
            }
        }
        success = true
    }

    private static func lastIndex(of signature: UInt32, in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        var index = data.count - 22
        while index >= 0 {
            if data.uint32(at: index) == signature { return index }
            index -= 1
        }
        return nil
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        let start = startIndex + offset
        return UInt16(self[start]) | UInt16(self[start + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        return UInt32(self[start]) | UInt32(self[start + 1]) << 8 | UInt32(self[start + 2]) << 16 | UInt32(self[start + 3]) << 24
    }
}
