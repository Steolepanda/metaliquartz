import Foundation
import MetalKit

@MainActor
protocol FrameRendering: AnyObject {
    func drawFrame(in view: MTKView)
    func resizeDrawable(to size: CGSize)
}

enum MetalPreviewRendererError: LocalizedError {
    case commandQueueUnavailable
    case shaderFunctionUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .commandQueueUnavailable:
            "Metal could not create a command queue."
        case .shaderFunctionUnavailable(let name):
            "The Metal shader function \(name) could not be loaded."
        }
    }
}

@MainActor
final class MetalPreviewRenderer: NSObject, FrameRendering, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState
    let imageRenderer: MetalImageRenderer
    private weak var diagnostics: RenderDiagnosticsModel?

    private let startTime = ProcessInfo.processInfo.systemUptime
    private var previousFrameTime: TimeInterval?
    private var frameIndex: UInt64 = 0

    init(view: MTKView, diagnostics: RenderDiagnosticsModel? = nil) throws {
        guard let device = view.device else {
            throw MetalPreviewRendererError.commandQueueUnavailable
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalPreviewRendererError.commandQueueUnavailable
        }

        let library = try device.makeDefaultLibrary(bundle: .main)
        guard let vertexFunction = library.makeFunction(name: "previewVertex") else {
            throw MetalPreviewRendererError.shaderFunctionUnavailable("previewVertex")
        }
        guard let fragmentFunction = library.makeFunction(name: "previewFragment") else {
            throw MetalPreviewRendererError.shaderFunctionUnavailable("previewFragment")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Metaliquartz Preview Pipeline"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat

        self.device = device
        self.commandQueue = commandQueue
        pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        imageRenderer = try MetalImageRenderer(device: device, library: library)
        self.diagnostics = diagnostics
        super.init()
    }

    func update(
        composition: CompositionFile,
        assets: [String: Data],
        transport: PlaybackTransportState
    ) {
        imageRenderer.update(composition: composition, assets: assets, transport: transport)
    }

    func draw(in view: MTKView) {
        drawFrame(in: view)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        resizeDrawable(to: size)
    }

    func drawFrame(in view: MTKView) {
        let cpuStart = ProcessInfo.processInfo.systemUptime
        guard let drawable = view.currentDrawable,
            let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let frame = FrameContext(
            time: now - startTime,
            deltaTime: previousFrameTime.map { now - $0 } ?? 0,
            frameIndex: frameIndex
        )
        previousFrameTime = now
        frameIndex &+= 1
        let renderedGraph = imageRenderer.encodeFrame(
            target: drawable.texture,
            drawableSize: view.drawableSize,
            commandBuffer: commandBuffer,
            frame: frame
        )

        if !renderedGraph {
            guard let renderPassDescriptor = view.currentRenderPassDescriptor,
                let encoder = commandBuffer.makeRenderCommandEncoder(
                    descriptor: renderPassDescriptor
                )
            else { return }

            var elapsedTime = Float(ProcessInfo.processInfo.systemUptime - startTime)

            encoder.label = "Animated Gradient Encoder"
            encoder.setRenderPipelineState(pipelineState)
            encoder.setFragmentBytes(
                &elapsedTime,
                length: MemoryLayout<Float>.stride,
                index: 0
            )
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        commandBuffer.label = "Metaliquartz Preview Frame"
        commandBuffer.present(drawable)
        if let diagnostics {
            let cpuMilliseconds =
                (ProcessInfo.processInfo.systemUptime - cpuStart) * 1_000
            let frameInterval = frame.deltaTime
            let dropped = frame.frameIndex > 0 && frameInterval > (1.0 / 50.0)
            let textureStats = imageRenderer.texturePool.stats()
            let nodeErrors = imageRenderer.imageEffects.shaderCache.diagnostics.merging(
                imageRenderer.integrationDiagnostics,
                uniquingKeysWith: { _, integrationError in integrationError }
            )
            commandBuffer.addCompletedHandler { [weak diagnostics] completedBuffer in
                let gpuMilliseconds =
                    max(0, completedBuffer.gpuEndTime - completedBuffer.gpuStartTime) * 1_000
                Task { @MainActor in
                    diagnostics?.record(
                        frameInterval: frameInterval,
                        cpuMilliseconds: cpuMilliseconds,
                        gpuMilliseconds: gpuMilliseconds,
                        dropped: dropped,
                        texturePool: textureStats,
                        nodeErrors: nodeErrors
                    )
                }
            }
        }
        commandBuffer.commit()
    }

    func resizeDrawable(to size: CGSize) {
        // The full-screen triangle adapts to the drawable automatically.
    }
}
