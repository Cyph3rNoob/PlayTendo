import CoreVideo
import MetalKit
import SwiftUI

/// Affiche l'image du jeu avec Metal. La vue occupe exactement la zone de l'écran affiché.
/// `source` choisit la partie de l'image à dessiner (de 0 à 1) : la DS en utilise deux,
/// une par écran, pour pouvoir les placer et les dimensionner librement.
struct GameScreen: UIViewRepresentable {
    let frameBuffer: FrameBuffer
    var source = CGRect(x: 0, y: 0, width: 1, height: 1)

    func makeCoordinator() -> GameRenderer {
        GameRenderer(frameBuffer: frameBuffer)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.isUserInteractionEnabled = false
        view.backgroundColor = .black
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.source = source
    }
}

final class GameRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice?
    private let frameBuffer: FrameBuffer
    private let queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?
    private var texture: MTLTexture?
    private var lastSequence: UInt64 = 0
    /// Images 3D : tampon partagé avec OpenGL ES, lu directement par Metal.
    private var textureCache: CVMetalTextureCache?
    private var hardwareTexture: CVMetalTexture?
    /// Partie du tampon occupée par l'image (de 0 à 1) et sens vertical.
    private var region = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var flipped = false
    var source = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Ce qui a été affiché la dernière fois : sans changement, inutile de redessiner.
    private var drawnSize = CGSize.zero
    private var drawnSource = CGRect.null

    init(frameBuffer: FrameBuffer) {
        self.frameBuffer = frameBuffer
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        super.init()
        guard let device, let library = device.makeDefaultLibrary() else { return }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "gameVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "gameFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: samplerDescriptor)
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let updated = uploadLatestFrame()
        // Rien de nouveau (jeu en pause, même image, jeu à 30 images/s) : l'écran garde l'image déjà
        // affichée, sans réveiller la puce graphique.
        guard updated || view.drawableSize != drawnSize || source != drawnSource else { return }
        guard let queue, let pipeline, let sampler,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }

        if let texture {
            let size = SIMD2<Float>(Float(texture.width), Float(texture.height))
            // Zone affichée = la partie demandée (un écran de DS…) de la zone occupée par l'image.
            let shownRect = CGRect(x: region.minX + source.minX * region.width,
                                   y: region.minY + source.minY * region.height,
                                   width: source.width * region.width, height: source.height * region.height)
            let shown = SIMD2<Float>(size.x * Float(shownRect.width), size.y * Float(shownRect.height))
            let drawableSize = view.drawableSize
            let scale = max(1, floor(min(Float(drawableSize.width) / shown.x, Float(drawableSize.height) / shown.y)))
            var uniforms = [SIMD4<Float>(size.x, size.y, scale, flipped ? 1 : 0),
                            SIMD4<Float>(Float(shownRect.minX), Float(shownRect.minY),
                                         Float(shownRect.width), Float(shownRect.height))]
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride * 2, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
        drawnSize = view.drawableSize
        drawnSource = source
    }

    /// Prépare la dernière image du jeu si elle est nouvelle. Renvoie vrai dans ce cas.
    private func uploadLatestFrame() -> Bool {
        var updated = false
        frameBuffer.withFrame(newerThan: lastSequence) { frame in
            switch frame.content {
            case .software(let pixels, let pitch):
                hardwareTexture = nil
                // Nouvelle texture si la taille change, ou si l'on sort d'une image 3D (tampon partagé).
                if texture == nil || texture!.width != frame.width || texture!.height != frame.height
                    || texture!.iosurface != nil {
                    makeTexture(width: frame.width, height: frame.height)
                }
                texture?.replace(region: MTLRegionMake2D(0, 0, frame.width, frame.height),
                                 mipmapLevel: 0, withBytes: pixels, bytesPerRow: pitch)
                region = CGRect(x: 0, y: 0, width: 1, height: 1)
                flipped = false
            case .hardware(let buffer, let isFlipped):
                guard let textureCache else { return }
                let bufferWidth = CVPixelBufferGetWidth(buffer)
                let bufferHeight = CVPixelBufferGetHeight(buffer)
                var metalTexture: CVMetalTexture?
                CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, buffer, nil,
                                                          .bgra8Unorm, bufferWidth, bufferHeight, 0, &metalTexture)
                guard let metalTexture, let shared = CVMetalTextureGetTexture(metalTexture) else { return }
                hardwareTexture = metalTexture
                texture = shared
                region = CGRect(x: 0, y: 0, width: CGFloat(frame.width) / CGFloat(bufferWidth),
                                height: CGFloat(frame.height) / CGFloat(bufferHeight))
                flipped = isFlipped
            }
            lastSequence = frame.sequence
            updated = true
        }
        return updated
    }

    private func makeTexture(width: Int, height: Int) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        texture = device?.makeTexture(descriptor: descriptor)
    }
}
