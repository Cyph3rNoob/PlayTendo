import CoreVideo
import MetalKit
import SwiftUI

/// Affiche l'image du jeu avec Metal. La vue occupe exactement la zone de l'écran affiché.
/// `source` choisit la partie de l'image à dessiner (de 0 à 1) : la DS en utilise deux,
/// une par écran, pour pouvoir les placer et les dimensionner librement.
struct GameScreen: UIViewRepresentable {
    let frameBuffer: FrameBuffer
    var source = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Lissage des bords (FXAA) avant l'agrandissement (PS1).
    var smoothing = false

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
        context.coordinator.smoothing = smoothing
    }
}

final class GameRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice?
    private let frameBuffer: FrameBuffer
    private let queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    /// Lissage : FXAA vers une image intermédiaire à la taille du jeu, ensuite agrandie comme d'habitude.
    private var fxaaPipeline: MTLRenderPipelineState?
    private var smoothedTexture: MTLTexture?
    var smoothing = false
    private var drawnSmoothing = false
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
    /// Image reçue mais pas encore affichée (écran pas prêt au moment où elle est arrivée) : affichée au tour suivant,
    /// même si le jeu s'est mis en pause entre-temps.
    private var frameNotShown = false

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
        descriptor.fragmentFunction = library.makeFunction(name: "fxaaFragment")
        fxaaPipeline = try? device.makeRenderPipelineState(descriptor: descriptor)

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
        if uploadLatestFrame() { frameNotShown = true }
        // Rien de nouveau (jeu en pause, même image, jeu à 30 images/s) : l'écran garde l'image déjà
        // affichée, sans réveiller la puce graphique.
        guard frameNotShown || view.drawableSize != drawnSize || source != drawnSource || smoothing != drawnSmoothing
        else { return }
        guard let queue, let pipeline, let sampler,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer() else { return }

        var texture = self.texture
        var shownRect = CGRect.zero
        var flipped = self.flipped
        if let frame = texture {
            // Zone affichée = la partie demandée (un écran de DS…) de la zone occupée par l'image. Image à l'envers
            // (OpenGL) : le shader ne retourne que cette partie, il faut donc la prendre à l'endroit symétrique
            // (sinon les deux écrans de la DS sont échangés).
            let part = flipped ? CGRect(x: source.minX, y: 1 - source.maxY, width: source.width, height: source.height)
                               : source
            shownRect = CGRect(x: region.minX + part.minX * region.width,
                               y: region.minY + part.minY * region.height,
                               width: part.width * region.width, height: part.height * region.height)
            if smoothing, let smoothed = smooth(frame, rect: shownRect, flipped: flipped, commands: commands) {
                texture = smoothed
                shownRect = CGRect(x: 0, y: 0, width: 1, height: 1)
                flipped = false
            }
        }
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }

        if let texture {
            let size = SIMD2<Float>(Float(texture.width), Float(texture.height))
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
        drawnSmoothing = smoothing
        frameNotShown = false
    }

    /// Passe FXAA : la partie affichée de l'image, à sa taille d'origine, lissée dans une image intermédiaire.
    private func smooth(_ frame: MTLTexture, rect: CGRect, flipped: Bool, commands: MTLCommandBuffer) -> MTLTexture? {
        guard let device, let fxaaPipeline, let sampler else { return nil }
        let width = max(1, Int((Double(frame.width) * rect.width).rounded()))
        let height = max(1, Int((Double(frame.height) * rect.height).rounded()))
        if smoothedTexture?.width != width || smoothedTexture?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            smoothedTexture = device.makeTexture(descriptor: descriptor)
        }
        guard let target = smoothedTexture else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var uniforms = [SIMD4<Float>(Float(frame.width), Float(frame.height), 1, flipped ? 1 : 0),
                        SIMD4<Float>(Float(rect.minX), Float(rect.minY), Float(rect.width), Float(rect.height))]
        encoder.setRenderPipelineState(fxaaPipeline)
        encoder.setFragmentTexture(frame, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride * 2, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        return target
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
