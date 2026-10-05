import Foundation
import os

/// Dernière image produite par le moteur, partagée entre le thread d'émulation
/// (qui écrit) et l'affichage Metal (qui lit).
final class FrameBuffer: @unchecked Sendable {
    struct Frame {
        let pixels: UnsafeRawPointer
        let width: Int
        let height: Int
        let pitch: Int
        let format: PTPixelFormat
        let sequence: UInt64
    }

    private let lock = OSAllocatedUnfairLock()
    private var storage: UnsafeMutableRawPointer?
    private var capacity = 0
    private var width = 0
    private var height = 0
    private var pitch = 0
    private var format: PTPixelFormat = .rgb565
    private var sequence: UInt64 = 0

    deinit {
        storage?.deallocate()
    }

    func store(_ pixels: UnsafeRawPointer, width: Int, height: Int, pitch: Int, format: PTPixelFormat) {
        lock.lock()
        defer { lock.unlock() }

        // Le format 0RGB1555 n'existe pas côté Metal : on le convertit en RGB565.
        let outputFormat: PTPixelFormat = format == .xrgb1555 ? .rgb565 : format
        let bytesPerPixel = outputFormat == .xrgb8888 ? 4 : 2
        let outputPitch = width * bytesPerPixel
        let needed = outputPitch * height
        if needed > capacity {
            storage?.deallocate()
            storage = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
            capacity = needed
        }
        guard let storage else { return }

        if format == .xrgb1555 {
            for y in 0..<height {
                let source = (pixels + y * pitch).assumingMemoryBound(to: UInt16.self)
                let destination = (storage + y * outputPitch).assumingMemoryBound(to: UInt16.self)
                for x in 0..<width {
                    let p = source[x]
                    let r = (p >> 10) & 0x1F
                    let g = (p >> 5) & 0x1F
                    let b = p & 0x1F
                    destination[x] = (r << 11) | (((g << 1) | (g >> 4)) << 5) | b
                }
            }
        } else if pitch == outputPitch {
            storage.copyMemory(from: pixels, byteCount: needed)
        } else {
            for y in 0..<height {
                (storage + y * outputPitch).copyMemory(from: pixels + y * pitch, byteCount: outputPitch)
            }
        }

        self.width = width
        self.height = height
        self.pitch = outputPitch
        self.format = outputFormat
        sequence &+= 1
    }

    /// Donne accès à la dernière image si elle est plus récente que `sequence`.
    func withFrame(newerThan lastSequence: UInt64, _ body: (Frame) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard let storage, sequence != lastSequence, width > 0, height > 0 else { return }
        body(Frame(pixels: UnsafeRawPointer(storage), width: width, height: height, pitch: pitch,
                   format: format, sequence: sequence))
    }

    /// Copie de la dernière image en RGBA 8 bits (pour les vignettes).
    func snapshotRGBA() -> (data: Data, width: Int, height: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard let storage, width > 0, height > 0 else { return nil }
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let o = (y * width + x) * 4
                    if format == .xrgb8888 {
                        let p = (storage + y * pitch).assumingMemoryBound(to: UInt32.self)[x]
                        out[o] = UInt8((p >> 16) & 0xFF)
                        out[o + 1] = UInt8((p >> 8) & 0xFF)
                        out[o + 2] = UInt8(p & 0xFF)
                    } else {
                        let p = (storage + y * pitch).assumingMemoryBound(to: UInt16.self)[x]
                        out[o] = UInt8(((p >> 11) & 0x1F) * 255 / 31)
                        out[o + 1] = UInt8(((p >> 5) & 0x3F) * 255 / 63)
                        out[o + 2] = UInt8((p & 0x1F) * 255 / 31)
                    }
                    out[o + 3] = 255
                }
            }
        }
        return (data, width, height)
    }
}
