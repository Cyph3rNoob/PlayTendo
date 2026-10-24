import Accelerate
import CoreVideo
import Foundation
import os

/// Dernière image produite par le moteur, partagée entre le thread d'émulation
/// (qui écrit) et l'affichage Metal (qui lit).
/// - Images « logicielles » (consoles 2D) : converties en BGRA 8 bits, le seul format accepté
///   par toutes les puces graphiques Apple.
/// - Images 3D (OpenGL ES) : on garde le tampon partagé tel quel, sans aucune copie.
final class FrameBuffer: @unchecked Sendable {
    enum Content {
        case software(pixels: UnsafeRawPointer, pitch: Int)
        /// `width`×`height` en haut à gauche du tampon, à l'envers verticalement si `flipped`.
        case hardware(buffer: CVPixelBuffer, flipped: Bool)
    }

    struct Frame {
        let content: Content
        let width: Int
        let height: Int
        let sequence: UInt64
    }

    private let lock = OSAllocatedUnfairLock()
    private var storage: UnsafeMutableRawPointer?
    private var capacity = 0
    private var hardwareBuffer: CVPixelBuffer?
    private var hardwareFlipped = false
    private var width = 0
    private var height = 0
    private var sequence: UInt64 = 0
    /// Prévenus à chaque nouvelle image (sur le fil d'émulation) : les écrans qui la dessinent.
    private var listeners: [@Sendable () -> Void] = []

    deinit {
        storage?.deallocate()
    }

    func addListener(_ listener: @escaping @Sendable () -> Void) {
        lock.lock()
        listeners.append(listener)
        lock.unlock()
    }

    private func notifyListeners() {
        lock.lock()
        let listeners = self.listeners
        lock.unlock()
        for listener in listeners { listener() }
    }

    func store(_ pixels: UnsafeRawPointer, width: Int, height: Int, pitch: Int, format: PTPixelFormat) {
        defer { notifyListeners() }
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

        hardwareBuffer = nil
        self.width = width
        self.height = height
        sequence &+= 1
    }

    func storeHardware(_ buffer: CVPixelBuffer, width: Int, height: Int, flipped: Bool) {
        defer { notifyListeners() }
        lock.lock()
        defer { lock.unlock() }
        hardwareBuffer = buffer
        hardwareFlipped = flipped
        self.width = width
        self.height = height
        sequence &+= 1
    }

    /// Donne accès à la dernière image si elle est plus récente que `sequence`.
    func withFrame(newerThan lastSequence: UInt64, _ body: (Frame) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard sequence != lastSequence, width > 0, height > 0 else { return }
        if let hardwareBuffer {
            body(Frame(content: .hardware(buffer: hardwareBuffer, flipped: hardwareFlipped),
                       width: width, height: height, sequence: sequence))
        } else if let storage {
            body(Frame(content: .software(pixels: UnsafeRawPointer(storage), pitch: width * 4),
                       width: width, height: height, sequence: sequence))
        }
    }

    /// Copie de la dernière image en RGBA 8 bits (pour les vignettes).
    func snapshotRGBA() -> (data: Data, width: Int, height: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard width > 0, height > 0 else { return nil }
        let base: UnsafeRawPointer
        var pitch = width * 4
        var flipped = false
        if let hardwareBuffer {
            CVPixelBufferLockBaseAddress(hardwareBuffer, .readOnly)
            guard let address = CVPixelBufferGetBaseAddress(hardwareBuffer) else {
                CVPixelBufferUnlockBaseAddress(hardwareBuffer, .readOnly)
                return nil
            }
            base = UnsafeRawPointer(address)
            pitch = CVPixelBufferGetBytesPerRow(hardwareBuffer)
            flipped = hardwareFlipped
        } else if let storage {
            base = UnsafeRawPointer(storage)
        } else {
            return nil
        }
        defer { if let hardwareBuffer { CVPixelBufferUnlockBaseAddress(hardwareBuffer, .readOnly) } }

        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            let output = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                let row = base.advanced(by: (flipped ? height - 1 - y : y) * pitch).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    let o = (y * width + x) * 4
                    output[o] = row[x * 4 + 2]
                    output[o + 1] = row[x * 4 + 1]
                    output[o + 2] = row[x * 4]
                    output[o + 3] = 255
                }
            }
        }
        return (data, width, height)
    }
}
