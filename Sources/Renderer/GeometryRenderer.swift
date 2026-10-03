import Foundation
@preconcurrency import Metal
import simd

@MainActor
final class GeometryRenderer {
    struct Uniforms {
        var gridSize: SIMD2<UInt32>
        var outputSize: SIMD2<Float>
        var displacement: Float
        var pointSize: Float
        var lineSize: Float
        var spriteScale: Float
        var spriteRotation: Float
        var cameraPitch: Float
        var cameraYaw: Float
        var cameraDistance: Float
        var spritePosition: SIMD2<Float>
        var padding: SIMD2<Float> = .zero
        var tint: SIMD4<Float>
    }

    let spritePipeline: MTLRenderPipelineState
    let meshPipeline: MTLRenderPipelineState
    let pointPipeline: MTLRenderPipelineState
    let linePipeline: MTLRenderPipelineState

    private let texturePool: TexturePool
    private let sampler: MTLSamplerState

    init(
        device: MTLDevice,
        library: MTLLibrary,
        texturePool: TexturePool
    ) throws {
        self.texturePool = texturePool
        spritePipeline = try Self.makePipeline(
            device: device,
            library: library,
            vertexName: "spriteGeometryVertex",
            label: "Metaliquartz Sprite Pipeline"
        )
        meshPipeline = try Self.makePipeline(
            device: device,
            library: library,
            vertexName: "meshGeometryVertex",
            label: "Metaliquartz Mesh Displacement Pipeline"
        )
        pointPipeline = try Self.makePipeline(
            device: device,
            library: library,
            vertexName: "pointGeometryVertex",
            label: "Metaliquartz Point Grid Pipeline"
        )
        linePipeline = try Self.makePipeline(
            device: device,
            library: library,
            vertexName: "lineGeometryVertex",
            label: "Metaliquartz Line Grid Pipeline"
        )

        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: descriptor) else {
            throw MetalPreviewRendererError.commandQueueUnavailable
        }
        self.sampler = sampler
    }

    func encode(
        kind: PatchExecutorKind,
        node: NodeRecord,
        source: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        let size = outputSize(parameters: node.parameters, source: source)
        guard
            let output = texturePool.acquire(
                width: size.width,
                height: size.height,
                pixelFormat: .rgba16Float
            ),
            let draw = drawConfiguration(kind: kind, parameters: node.parameters)
        else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            texturePool.recycle(output)
            return nil
        }

        var uniforms = Uniforms(
            gridSize: SIMD2(draw.columns, draw.rows),
            outputSize: SIMD2(Float(size.width), Float(size.height)),
            displacement: Float(node.parameters.number("displacement", default: 0.5)),
            pointSize: Float(node.parameters.number("pointSize", default: 3)),
            lineSize: Float(node.parameters.number("lineSize", default: 1.5)),
            spriteScale: Float(node.parameters.number("scale", default: 1)),
            spriteRotation: Float(node.parameters.number("rotation")),
            cameraPitch: Float(node.parameters.number("cameraPitch")),
            cameraYaw: Float(node.parameters.number("cameraYaw")),
            cameraDistance: Float(node.parameters.number("cameraDistance", default: 2.25)),
            spritePosition: SIMD2(
                Float(node.parameters.number("positionX")),
                Float(node.parameters.number("positionY"))
            ),
            tint: node.parameters.color("tint")
        )
        encoder.label = "\(node.name) Geometry Encoder"
        encoder.setRenderPipelineState(draw.pipeline)
        encoder.setVertexTexture(source, index: 0)
        encoder.setVertexSamplerState(sampler, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: draw.primitive, vertexStart: 0, vertexCount: draw.vertexCount)
        encoder.endEncoding()
        return output
    }

    func outputSize(
        parameters: [String: ParameterValue],
        source: MTLTexture
    ) -> (width: Int, height: Int) {
        switch parameters.string("resolution", default: "source") {
        case "640×360": return (640, 360)
        case "1280×720": return (1280, 720)
        case "1920×1080": return (1920, 1080)
        default: return (source.width, source.height)
        }
    }

    private func drawConfiguration(
        kind: PatchExecutorKind,
        parameters: [String: ParameterValue]
    ) -> (
        pipeline: MTLRenderPipelineState, primitive: MTLPrimitiveType, vertexCount: Int,
        columns: UInt32, rows: UInt32
    )? {
        let columns = UInt32(clamping: Int(parameters.number("columns", default: 64)))
            .clamped(to: 2...256)
        let rows = UInt32(clamping: Int(parameters.number("rows", default: 36)))
            .clamped(to: 2...256)
        switch kind {
        case .sprite, .billboard, .qcSprite:
            return (spritePipeline, .triangle, 6, columns, rows)
        case .meshDisplacement, .cube, .sphere:
            return (
                meshPipeline,
                .triangle,
                Int(columns - 1) * Int(rows - 1) * 6,
                columns,
                rows
            )
        case .pointGrid, .particleSystem:
            let requested =
                kind == .particleSystem
                ? min(100_000, max(0, Int(parameters.number("count", default: 1_000))))
                : Int(columns) * Int(rows)
            return (pointPipeline, .point, requested, columns, rows)
        case .lineGrid:
            return (linePipeline, .triangle, Int(columns - 1) * Int(rows) * 6, columns, rows)
        default:
            return nil
        }
    }

    private static func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertexName: String,
        label: String
    ) throws -> MTLRenderPipelineState {
        guard let vertex = library.makeFunction(name: vertexName) else {
            throw MetalPreviewRendererError.shaderFunctionUnavailable(vertexName)
        }
        guard let fragment = library.makeFunction(name: "geometryFragment") else {
            throw MetalPreviewRendererError.shaderFunctionUnavailable("geometryFragment")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }
}

extension UInt32 {
    fileprivate func clamped(to range: ClosedRange<UInt32>) -> UInt32 {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

extension Dictionary where Key == String, Value == ParameterValue {
    fileprivate func number(_ key: String, default fallback: Double = 0) -> Double {
        guard case .number(let value) = self[key] else { return fallback }
        return value
    }

    fileprivate func string(_ key: String, default fallback: String) -> String {
        guard case .string(let value) = self[key] else { return fallback }
        return value
    }

    fileprivate func color(_ key: String) -> SIMD4<Float> {
        guard case .color(let red, let green, let blue, let alpha) = self[key] else {
            return SIMD4(repeating: 1)
        }
        return SIMD4(Float(red), Float(green), Float(blue), Float(alpha))
    }
}
