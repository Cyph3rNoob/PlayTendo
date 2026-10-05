import Accelerate
import Foundation
import os

/// Dernière image produite par le moteur, partagée entre le thread d'émulation
/// (qui écrit) et l'affichage Metal (qui lit). Toutes les images sont converties en
/// BGRA 8 bits : c'est le seul format accepté par toutes les puces graphiques Apple.
final class FrameBuffer: @unchecked Sendable {
    struct Frame {
        let pixels: UnsafeRawPointer
        let width: Int
        let height: Int
        let pitch: Int
        let sequence: UInt64
    }

    private let lock = OSAllocatedUnfairLock()
    private var storage: UnsafeMutableRawPointer?
    private var capacity = 0
    private var width = 0
    private var height = 0
    private var sequence: UInt64 = 0

    deinit {
        storage?.deallocate()
    }

    func store(_ pixels: UnsafeRawPointer, width: Int, height: Int, pitch: Int, format: PTPixelFormat) {
        lock.lock()
        defer { lock.unlock() }

        let outputPitch = width * 4
        let needed = outputPitch * height
        if needed > capacity {
            storage?.deallocate()
            storage = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
            capacity = needed
        }
        guard let storage else { return }

        var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: pixels), height: vImagePixelCount(height),
                                   width: vImagePixelCount(width), rowBytes: pitch)
        var destination = vImage_Buffer(data: storage, height: vImagePixelCount(height),
                                        width: vImagePixelCount(width), rowBytes: outputPitch)
        switch format {
        case .xrgb8888:
            // En mémoire : B, G, R, X — exactement l'ordre BGRA.
            if pitch == outputPitch {
                storage.copyMemory(from: pixels, byteCount: needed)
            } else {
                for y in 0..<height {
                    (storage + y * outputPitch).copyMemory(from: pixels + y * pitch, byteCount: outputPitch)
                }
            }
        case .rgb565:
            vImageConvert_RGB565toBGRA8888(255, &source, &destination, vImage_Flags(kvImageNoFlags))
        case .xrgb1555:
            vImageConvert_ARGB1555toARGB8888(&source, &destination, vImage_Flags(kvImageNoFlags))
            let toBGRA: [UInt8] = [3, 2, 1, 0]
            vImagePermuteChannels_ARGB8888(&destination, &destination, toBGRA, vImage_Flags(kvImageNoFlags))
        @unknown default:
            return
        }

        self.width = width
        self.height = height
        sequence &+= 1
    }

    /// Donne accès à la dernière image si elle est plus récente que `sequence`.
    func withFrame(newerThan lastSequence: UInt64, _ body: (Frame) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard let storage, sequence != lastSequence, width > 0, height > 0 else { return }
        body(Frame(pixels: UnsafeRawPointer(storage), width: width, height: height, pitch: width * 4,
                   sequence: sequence))
    }

    /// Copie de la dernière image en RGBA 8 bits (pour les vignettes).
    func snapshotRGBA() -> (data: Data, width: Int, height: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard let storage, width > 0, height > 0 else { return nil }
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            let input = storage.assumingMemoryBound(to: UInt8.self)
            let output = raw.bindMemory(to: UInt8.self)
            for i in 0..<(width * height) {
                output[i * 4] = input[i * 4 + 2]
                output[i * 4 + 1] = input[i * 4 + 1]
                output[i * 4 + 2] = input[i * 4]
                output[i * 4 + 3] = 255
            }
        }
        return (data, width, height)
    }
}
