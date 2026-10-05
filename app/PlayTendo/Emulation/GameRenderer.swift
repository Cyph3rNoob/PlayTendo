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
    var source = CGRect(x: 0, y: 0, width: 1, height: 1)

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
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        uploadLatestFrame()
        guard let queue, let pipeline, let sampler,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }

        if let texture {
            let size = SIMD2<Float>(Float(texture.width), Float(texture.height))
            let shown = SIMD2<Float>(size.x * Float(source.width), size.y * Float(source.height))
            let drawableSize = view.drawableSize
            let scale = max(1, floor(min(Float(drawableSize.width) / shown.x, Float(drawableSize.height) / shown.y)))
            var uniforms = [SIMD4<Float>(size.x, size.y, scale, 0),
                            SIMD4<Float>(Float(source.minX), Float(source.minY), Float(source.width), Float(source.height))]
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride * 2, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    private func uploadLatestFrame() {
        frameBuffer.withFrame(newerThan: lastSequence) { frame in
            if texture == nil || texture!.width != frame.width || texture!.height != frame.height {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm, width: frame.width, height: frame.height, mipmapped: false)
                descriptor.usage = .shaderRead
                texture = device?.makeTexture(descriptor: descriptor)
            }
            texture?.replace(region: MTLRegionMake2D(0, 0, frame.width, frame.height),
                             mipmapLevel: 0, withBytes: frame.pixels, bytesPerRow: frame.pitch)
            lastSequence = frame.sequence
        }
    }
}
