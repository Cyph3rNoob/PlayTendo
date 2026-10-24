import CoreVideo
import MetalKit
import os
import SwiftUI

/// Affiche l'image du jeu avec Metal. La vue occupe exactement la zone de l'écran affiché.
/// `source` choisit la partie de l'image à dessiner (de 0 à 1) : la DS en utilise deux,
/// une par écran, pour pouvoir les placer et les dimensionner librement.
/// L'écran n'est dessiné que quand une image arrive ou qu'un réglage change (en pause : jamais, il garde la dernière).
struct GameScreen {
    let frameBuffer: FrameBuffer
    var source = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Lissage des bords (FXAA) avant l'agrandissement (PS1).
    var smoothing = false
    /// Consoles 2D : mode du filtre (FilterSettings.shaderMode) ; 0 = pixels nets.
    var filter = 0

    func makeCoordinator() -> GameRenderer {
        GameRenderer(frameBuffer: frameBuffer)
    }

    private func makeView(_ renderer: GameRenderer) -> MTKView {
#if os(iOS)
        let view = MTKView(frame: .zero, device: renderer.device)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .black
#else
        // Mac : la souris et le clavier sont lus par l'écran de jeu, posé par-dessus.
        let view = PassThroughMTKView(frame: .zero, device: renderer.device)
#endif
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.framebufferOnly = true
        // Pas de rafraîchissement régulier de la vue : GameRenderer dessine lui-même dans sa couche Metal.
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.delegate = renderer
        renderer.attach(view)
        return view
    }

    private func update(_ view: MTKView, _ renderer: GameRenderer) {
        renderer.configure(source: source, smoothing: smoothing, filter: filter, size: view.drawableSize)
    }
}

#if os(iOS)
extension GameScreen: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView { makeView(context.coordinator) }
    func updateUIView(_ view: MTKView, context: Context) { update(view, context.coordinator) }
}
#else
extension GameScreen: NSViewRepresentable {
    func makeNSView(context: Context) -> MTKView { makeView(context.coordinator) }
    func updateNSView(_ view: MTKView, context: Context) { update(view, context.coordinator) }
}

/// Vue Metal qui laisse passer la souris à ce qui est dessous.
final class PassThroughMTKView: MTKView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif

/// Dessine l'image du jeu dans la couche Metal de la vue, sur son propre fil, dès que le moteur la produit
/// (2026-10-25). Avant, la vue attendait son prochain rafraîchissement (jusqu'à 1/60 s) pour dessiner, et l'image ne
/// paraissait qu'au rafraîchissement d'après : une image de décalage en plus entre un bouton et l'écran.
/// Tout le dessin et l'état qui va avec sont sur `renderQueue` ; les réglages arrivent du fil principal par `options`.
final class GameRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    let device: MTLDevice?
    private let frameBuffer: FrameBuffer
    private let queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    /// Lissage : FXAA vers une image intermédiaire à la taille du jeu, ensuite agrandie comme d'habitude.
    private var fxaaPipeline: MTLRenderPipelineState?
    private var smoothedTexture: MTLTexture?
    private var smoothing = false
    private var drawnSmoothing = false
    private var filter = 0
    private var drawnFilter = 0
    private var sampler: MTLSamplerState?
    private var texture: MTLTexture?
    private var lastSequence: UInt64 = 0
    /// Images 3D : tampon partagé avec OpenGL ES, lu directement par Metal.
    private var textureCache: CVMetalTextureCache?
    private var hardwareTexture: CVMetalTexture?
    /// Partie du tampon occupée par l'image (de 0 à 1) et sens vertical.
    private var region = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var flipped = false
    private var source = CGRect(x: 0, y: 0, width: 1, height: 1)

    private struct Options: Equatable {
        var source = CGRect(x: 0, y: 0, width: 1, height: 1)
        var smoothing = false
        var filter = 0
        /// Taille de l'image de la vue, en pixels. Lue sur la vue (fil principal) : sa couche annonce 0×0 tant que
        /// la vue n'a pas dessiné elle-même (MTKView ne la lui donne qu'à ce moment-là).
        var size = CGSize.zero
    }
    /// Réglages voulus (fil principal), repris au début de chaque dessin.
    private let options = OSAllocatedUnfairLock(initialState: Options())
    private let renderQueue = DispatchQueue(label: "PlayTendo écran", qos: .userInteractive)
    /// Un dessin déjà demandé et pas encore commencé : les demandes suivantes s'y fondent (avance rapide ×5, deux
    /// écrans de DS…), il prendra la dernière image.
    private let renderRequested = OSAllocatedUnfairLock(initialState: false)
    private var layer: CAMetalLayer?
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
        frameBuffer.addListener { [weak self] in self?.requestRender() }
    }

    /// Fil principal, à la création de la vue.
    func attach(_ view: MTKView) {
        let layer = view.layer as? CAMetalLayer
        renderQueue.async { self.layer = layer }
        resize(view.drawableSize)
    }

    /// Fil principal : réglages de l'écran ; redessiné s'ils changent (même en pause).
    func configure(source: CGRect, smoothing: Bool, filter: Int, size: CGSize) {
        change { options in
            options.source = source
            options.smoothing = smoothing
            options.filter = filter
            options.size = size
        }
    }

    /// Fil principal : nouvelle taille de la vue.
    private func resize(_ size: CGSize) {
        change { $0.size = size }
    }

    private func change(_ edit: (inout Options) -> Void) {
        let changed = options.withLock { current -> Bool in
            var wanted = current
            edit(&wanted)
            guard wanted != current else { return false }
            current = wanted
            return true
        }
        if changed { requestRender() }
    }

    /// N'importe quel fil (image produite par le moteur, réglage, taille) : un dessin dès que possible.
    func requestRender() {
        let alreadyRequested = renderRequested.withLock { requested -> Bool in
            defer { requested = true }
            return requested
        }
        guard !alreadyRequested else { return }
        renderQueue.async {
            self.renderRequested.withLock { $0 = false }
            self.render()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        resize(size)
    }

    func draw(in view: MTKView) {
        requestRender()
    }

    /// Sur `renderQueue`.
    private func render() {
        let wanted = options.withLock { $0 }
        source = wanted.source
        smoothing = wanted.smoothing
        filter = wanted.filter
        if uploadLatestFrame() { frameNotShown = true }
        guard let layer else { return }
        let drawableSize = wanted.size
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }
        if layer.drawableSize != drawableSize { layer.drawableSize = drawableSize }
        // Rien de nouveau (même image, jeu à 30 images/s) : l'écran garde l'image déjà affichée, sans réveiller la
        // puce graphique.
        guard frameNotShown || drawableSize != drawnSize || source != drawnSource || smoothing != drawnSmoothing
              || filter != drawnFilter
        else { return }
        guard let queue, let pipeline, let sampler,
              let drawable = layer.nextDrawable(),
              let commands = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store

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
            let scale = max(1, floor(min(Float(drawableSize.width) / shown.x, Float(drawableSize.height) / shown.y)))
            var uniforms = [SIMD4<Float>(size.x, size.y, scale, flipped ? 1 : 0),
                            SIMD4<Float>(Float(shownRect.minX), Float(shownRect.minY),
                                         Float(shownRect.width), Float(shownRect.height)),
                            SIMD4<Float>(Float(filter), 0, 0, 0)]
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride * uniforms.count, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
        drawnSize = drawableSize
        drawnSource = source
        drawnSmoothing = smoothing
        drawnFilter = filter
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
                        SIMD4<Float>(Float(rect.minX), Float(rect.minY), Float(rect.width), Float(rect.height)),
                        SIMD4<Float>(0, 0, 0, 0)]
        encoder.setRenderPipelineState(fxaaPipeline)
        encoder.setFragmentTexture(frame, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride * uniforms.count, index: 0)
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
