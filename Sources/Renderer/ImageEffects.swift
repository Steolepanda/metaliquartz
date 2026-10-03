import CoreImage
import Foundation
@preconcurrency import Metal
import simd

@MainActor
enum CustomShaderCompiler {
    static func diagnostic(for source: String) -> String? {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return "Metal is unavailable on this Mac."
        }
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            guard library.makeFunction(name: "mqFragment") != nil else {
                return "The shader must define a fragment function named mqFragment."
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

@MainActor
final class CustomShaderPipelineCache {
    private let device: MTLDevice
    private let vertexFunction: MTLFunction
    private var pipelines: [NodeID: MTLRenderPipelineState] = [:]
    private var attemptedSources: [NodeID: String] = [:]
    private(set) var diagnostics: [NodeID: String] = [:]

    init(device: MTLDevice, defaultLibrary: MTLLibrary) throws {
        self.device = device
        guard let vertex = defaultLibrary.makeFunction(name: "previewVertex") else {
            throw MetalPreviewRendererError.shaderFunctionUnavailable("previewVertex")
        }
        vertexFunction = vertex
    }

    func pipeline(nodeID: NodeID, source: String) -> MTLRenderPipelineState? {
        if attemptedSources[nodeID] == source { return pipelines[nodeID] }
        attemptedSources[nodeID] = source
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            guard let fragment = library.makeFunction(name: "mqFragment") else {
                diagnostics[nodeID] = "The shader must define mqFragment."
                return pipelines[nodeID]
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Metaliquartz Custom Shader Pipeline"
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .rgba16Float
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            pipelines[nodeID] = pipeline
            diagnostics[nodeID] = nil
            return pipeline
        } catch {
            diagnostics[nodeID] = error.localizedDescription
            return pipelines[nodeID]
        }
    }
}

@MainActor
final class MetalImageEffects {
    struct ShaderFrameUniforms {
        var time: Float
        var deltaTime: Float
        var resolution: SIMD2<Float>
        var frameIndex: UInt32
    }

    let shaderCache: CustomShaderPipelineCache
    private let texturePool: TexturePool
    private let context: CIContext
    private let colorSpace: CGColorSpace
    private let sampler: MTLSamplerState

    init(
        device: MTLDevice,
        defaultLibrary: MTLLibrary,
        texturePool: TexturePool
    ) throws {
        self.texturePool = texturePool
        guard let linearColorSpace = CGColorSpace(name: CGColorSpace.linearSRGB) else {
            throw MetalPreviewRendererError.commandQueueUnavailable
        }
        colorSpace = linearColorSpace
        context = CIContext(
            mtlDevice: device,
            options: [
                .workingColorSpace: linearColorSpace,
                .outputColorSpace: linearColorSpace,
                .cacheIntermediates: false,
            ]
        )
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToZero
        samplerDescriptor.tAddressMode = .clampToZero
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw MetalPreviewRendererError.commandQueueUnavailable
        }
        self.sampler = sampler
        shaderCache = try CustomShaderPipelineCache(
            device: device,
            defaultLibrary: defaultLibrary
        )
    }

    func encodeColorControls(
        source: MTLTexture,
        parameters: [String: ParameterValue],
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        guard let image = ciImage(source) else { return nil }
        let output = image.applyingFilter(
            "CIColorControls",
            parameters: [
                kCIInputSaturationKey: parameters.number("saturation", default: 1),
                kCIInputBrightnessKey: parameters.number("brightness"),
                kCIInputContrastKey: parameters.number("contrast", default: 1),
            ]
        )
        return render(
            output.cropped(to: image.extent), sizeOf: source, commandBuffer: commandBuffer)
    }

    func encodeColorInvert(
        source: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        guard let image = ciImage(source) else { return nil }
        let output = image.applyingFilter("CIColorInvert")
        return render(
            output.cropped(to: image.extent), sizeOf: source, commandBuffer: commandBuffer
        )
    }

    func encodeLinearGradient(
        parameters: [String: ParameterValue],
        width: Int,
        height: Int,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        let image = CIFilter(
            name: "CILinearGradient",
            parameters: [
                "inputPoint0": CIVector(
                    x: parameters.number("point0X"),
                    y: parameters.number("point0Y")
                ),
                "inputPoint1": CIVector(
                    x: parameters.number("point1X", default: 200),
                    y: parameters.number("point1Y", default: 200)
                ),
                "inputColor0": parameters.ciColor("color1", fallback: CIColor.white),
                "inputColor1": parameters.ciColor("color2", fallback: CIColor.black),
            ]
        )?.outputImage
        guard let image else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        return render(
            image.cropped(to: bounds),
            width: width,
            height: height,
            commandBuffer: commandBuffer
        )
    }

    func encodeSolidColor(
        color: ParameterValue,
        width: Int,
        height: Int,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        let ciColor: CIColor
        if case .color(let red, let green, let blue, let alpha) = color {
            ciColor = CIColor(
                red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue),
                alpha: CGFloat(alpha)
            )
        } else {
            ciColor = .clear
        }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        return render(
            CIImage(color: ciColor).cropped(to: bounds),
            width: width,
            height: height,
            commandBuffer: commandBuffer
        )
    }

    func encodeRenderGradient(
        parameters: [String: ParameterValue],
        width: Int,
        height: Int,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        let angle = parameters.number("angle") * .pi / 180
        let distance = Double(max(width, height))
        let centerX = Double(width) / 2
        let centerY = Double(height) / 2
        let directionX = cos(angle) * distance / 2
        let directionY = sin(angle) * distance / 2
        let firstParameters: [String: ParameterValue] = [
            "point0X": .number(centerX - directionX),
            "point0Y": .number(centerY - directionY),
            "point1X": .number(centerX),
            "point1Y": .number(centerY),
            "color1": parameters["color1"] ?? .color(red: 1, green: 1, blue: 1, alpha: 1),
            "color2": parameters["color2"] ?? .color(red: 0.5, green: 0.5, blue: 0.5, alpha: 1),
        ]
        let secondParameters: [String: ParameterValue] = [
            "point0X": .number(centerX),
            "point0Y": .number(centerY),
            "point1X": .number(centerX + directionX),
            "point1Y": .number(centerY + directionY),
            "color1": parameters["color2"] ?? .color(red: 0.5, green: 0.5, blue: 0.5, alpha: 1),
            "color2": parameters["color3"] ?? .color(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        guard
            let first = encodeLinearGradient(
                parameters: firstParameters,
                width: width,
                height: height,
                commandBuffer: commandBuffer
            ),
            let second = encodeLinearGradient(
                parameters: secondParameters,
                width: width,
                height: height,
                commandBuffer: commandBuffer
            ),
            let output = encodeBlend(
                background: first,
                foreground: second,
                parameters: ["mode": .string("normal"), "opacity": .number(1)],
                commandBuffer: commandBuffer
            )
        else { return nil }
        let pool = texturePool
        commandBuffer.addCompletedHandler { _ in
            pool.recycle(first)
            pool.recycle(second)
        }
        return output
    }

    func encodeBlur(
        source: MTLTexture,
        parameters: [String: ParameterValue],
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        guard let image = ciImage(source) else { return nil }
        let output = image.clampedToExtent().applyingFilter(
            "CIGaussianBlur",
            parameters: [kCIInputRadiusKey: parameters.number("radius", default: 10)]
        )
        return render(
            output.cropped(to: image.extent), sizeOf: source, commandBuffer: commandBuffer)
    }

    func encodeGlow(
        source: MTLTexture,
        parameters: [String: ParameterValue],
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        guard let image = ciImage(source) else { return nil }
        let output = image.applyingFilter(
            "CIBloom",
            parameters: [
                kCIInputRadiusKey: parameters.number("radius", default: 12),
                kCIInputIntensityKey: parameters.number("intensity", default: 0.8),
            ]
        )
        return render(
            output.cropped(to: image.extent), sizeOf: source, commandBuffer: commandBuffer)
    }

    func encodeBlend(
        background: MTLTexture,
        foreground: MTLTexture,
        parameters: [String: ParameterValue],
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        guard let backgroundImage = ciImage(background),
            let foregroundImage = ciImage(foreground)
        else { return nil }
        let opacity = parameters.number("opacity", default: 1)
        let fadedForeground = foregroundImage.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)
            ]
        )
        let filterName: String
        switch parameters.string("mode", default: "normal") {
        case "add": filterName = "CIAdditionCompositing"
        case "screen": filterName = "CIScreenBlendMode"
        case "multiply": filterName = "CIMultiplyBlendMode"
        default: filterName = "CISourceOverCompositing"
        }
        let output = fadedForeground.applyingFilter(
            filterName,
            parameters: [kCIInputBackgroundImageKey: backgroundImage]
        )
        return render(
            output.cropped(to: backgroundImage.extent),
            sizeOf: background,
            commandBuffer: commandBuffer
        )
    }

    func encodeDisplace(
        source: MTLTexture,
        displacement: MTLTexture,
        parameters: [String: ParameterValue],
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        guard let sourceImage = ciImage(source), let displacementImage = ciImage(displacement)
        else { return nil }
        let output = sourceImage.applyingFilter(
            "CIDisplacementDistortion",
            parameters: [
                "inputDisplacementImage": displacementImage,
                kCIInputScaleKey: parameters.number("scale", default: 40),
            ]
        )
        return render(
            output.cropped(to: sourceImage.extent),
            sizeOf: source,
            commandBuffer: commandBuffer
        )
    }

    func encodeCustomShader(
        node: NodeRecord,
        source: MTLTexture,
        frame: FrameContext,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        guard case .string(let shaderSource) = node.parameters["shaderSource"],
            let pipeline = shaderCache.pipeline(nodeID: node.id, source: shaderSource),
            let output = texturePool.acquire(
                width: source.width,
                height: source.height,
                pixelFormat: .rgba16Float
            )
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
        var uniforms = ShaderFrameUniforms(
            time: Float(frame.time),
            deltaTime: Float(frame.deltaTime),
            resolution: SIMD2(Float(source.width), Float(source.height)),
            frameIndex: UInt32(truncatingIfNeeded: frame.frameIndex)
        )
        let declarations = CustomShaderSource.parameterDeclarations(in: shaderSource)
        var userParameters = SIMD4<Float>(repeating: 0)
        for (index, declaration) in declarations.enumerated() {
            userParameters[index] = Float(
                node.parameters.number(declaration.key, default: declaration.defaultValue)
            )
        }
        encoder.label = "Custom Metal Shader Encoder"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<ShaderFrameUniforms>.stride,
            index: 0
        )
        encoder.setFragmentBytes(
            &userParameters,
            length: MemoryLayout<SIMD4<Float>>.stride,
            index: 1
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return output
    }

    private func ciImage(_ texture: MTLTexture) -> CIImage? {
        CIImage(mtlTexture: texture, options: [.colorSpace: colorSpace])
    }

    private func render(
        _ image: CIImage,
        sizeOf source: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        guard
            let output = texturePool.acquire(
                width: source.width,
                height: source.height,
                pixelFormat: .rgba16Float
            )
        else { return nil }
        context.render(
            image,
            to: output,
            commandBuffer: commandBuffer,
            bounds: CGRect(x: 0, y: 0, width: source.width, height: source.height),
            colorSpace: colorSpace
        )
        return output
    }

    private func render(
        _ image: CIImage,
        width: Int,
        height: Int,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        guard
            let output = texturePool.acquire(
                width: max(1, width),
                height: max(1, height),
                pixelFormat: .rgba16Float
            )
        else { return nil }
        context.render(
            image,
            to: output,
            commandBuffer: commandBuffer,
            bounds: CGRect(x: 0, y: 0, width: max(1, width), height: max(1, height)),
            colorSpace: colorSpace
        )
        return output
    }
}

extension Dictionary where Key == String, Value == ParameterValue {
    fileprivate func number(_ key: String, default fallback: Double = 0) -> Double {
        guard case .number(let value) = self[key] else { return fallback }
        return value
    }

    fileprivate func string(_ key: String, default fallback: String = "") -> String {
        guard case .string(let value) = self[key] else { return fallback }
        return value
    }

    fileprivate func ciColor(_ key: String, fallback: CIColor) -> CIColor {
        guard case .color(let red, let green, let blue, let alpha) = self[key] else {
            return fallback
        }
        return CIColor(
            red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue),
            alpha: CGFloat(alpha)
        )
    }
}
