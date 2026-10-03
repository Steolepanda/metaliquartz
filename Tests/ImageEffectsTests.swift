import MetalKit
import XCTest

@testable import Metaliquartz

@MainActor
final class ImageEffectsTests: XCTestCase {
    func testShaderParameterMetadataIsParsedAndLimitedToFourValues() {
        let source = """
            // mq-parameters: [{"key":"one","name":"One","defaultValue":1,"minimum":0,"maximum":2},{"key":"two","name":"Two","defaultValue":2,"minimum":0,"maximum":3},{"key":"three","name":"Three","defaultValue":3,"minimum":0,"maximum":4},{"key":"four","name":"Four","defaultValue":4,"minimum":0,"maximum":5},{"key":"five","name":"Five","defaultValue":5,"minimum":0,"maximum":6}]
            """

        let parameters = CustomShaderSource.parameterDeclarations(in: source)

        XCTAssertEqual(parameters.map(\.key), ["one", "two", "three", "four"])
        XCTAssertEqual(parameters.last?.maximum, 5)
    }

    func testMalformedShaderRetainsLastValidPipeline() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: .main)
        let cache = try CustomShaderPipelineCache(device: device, defaultLibrary: library)
        let nodeID = NodeID()

        let validPipeline = try XCTUnwrap(
            cache.pipeline(nodeID: nodeID, source: CustomShaderSource.defaultSource)
        )
        let malformedSource = CustomShaderSource.defaultSource.replacingOccurrences(
            of: "mqFragment",
            with: "wrongFragmentName"
        )
        let fallbackPipeline = try XCTUnwrap(
            cache.pipeline(nodeID: nodeID, source: malformedSource)
        )

        XCTAssertTrue(validPipeline === fallbackPipeline)
        XCTAssertNotNil(cache.diagnostics[nodeID])
    }

    func testColorControlsDesaturatesOnGPU() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: .main)
        let renderer = try MetalImageRenderer(device: device, library: library)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let source = try makeSolidRedTexture(device: device)
        let target = try makePreviewTarget(device: device)

        let output = try XCTUnwrap(
            renderer.imageEffects.encodeColorControls(
                source: source,
                parameters: [
                    "saturation": .number(0),
                    "brightness": .number(0),
                    "contrast": .number(1),
                ],
                commandBuffer: commandBuffer
            )
        )
        renderer.encodePreview(
            source: output,
            target: target,
            drawableSize: CGSize(width: 2, height: 2),
            commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        XCTAssertEqual(commandBuffer.status, .completed)
        var bytes = [UInt8](repeating: 0, count: 16)
        target.getBytes(
            &bytes,
            bytesPerRow: 8,
            from: MTLRegionMake2D(0, 0, 2, 2),
            mipmapLevel: 0
        )
        let colorChannels = [bytes[0], bytes[1], bytes[2]]
        XCTAssertGreaterThan(colorChannels.min()!, 30)
        XCTAssertLessThan(
            Int(colorChannels.max()!) - Int(colorChannels.min()!),
            4,
            "A fully desaturated red pixel should have matching RGB channels."
        )
        renderer.texturePool.recycle(output)
    }

    func testColorInvertPreservesAlphaAndInvertsRGBOnGPU() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: .main)
        let renderer = try MetalImageRenderer(device: device, library: library)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let source = try makeSolidRedTexture(device: device)
        let target = try makePreviewTarget(device: device)

        let output = try XCTUnwrap(
            renderer.imageEffects.encodeColorInvert(
                source: source,
                commandBuffer: commandBuffer
            )
        )
        renderer.encodePreview(
            source: output,
            target: target,
            drawableSize: CGSize(width: 2, height: 2),
            commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: 16)
        target.getBytes(
            &bytes,
            bytesPerRow: 8,
            from: MTLRegionMake2D(0, 0, 2, 2),
            mipmapLevel: 0
        )
        XCTAssertGreaterThan(bytes[0], 220)
        XCTAssertGreaterThan(bytes[1], 220)
        XCTAssertLessThan(bytes[2], 20)
        XCTAssertEqual(bytes[3], 255)
        renderer.texturePool.recycle(output)
    }

    func testLinearGradientIsCroppedAtRequestedDestination() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: .main)
        let renderer = try MetalImageRenderer(device: device, library: library)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let target = try makePreviewTarget(device: device)

        let output = try XCTUnwrap(
            renderer.imageEffects.encodeLinearGradient(
                parameters: [
                    "point0X": .number(0), "point0Y": .number(0),
                    "point1X": .number(2), "point1Y": .number(0),
                    "color1": .color(red: 1, green: 1, blue: 1, alpha: 1),
                    "color2": .color(red: 0, green: 0, blue: 0, alpha: 1),
                ],
                width: 2,
                height: 2,
                commandBuffer: commandBuffer
            )
        )
        renderer.encodePreview(
            source: output,
            target: target,
            drawableSize: CGSize(width: 2, height: 2),
            commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: 16)
        target.getBytes(
            &bytes,
            bytesPerRow: 8,
            from: MTLRegionMake2D(0, 0, 2, 2),
            mipmapLevel: 0
        )
        XCTAssertGreaterThan(bytes[0], bytes[4])
        XCTAssertGreaterThan(bytes[1], bytes[5])
        XCTAssertGreaterThan(bytes[2], bytes[6])
        renderer.texturePool.recycle(output)
    }

    func testCustomShaderRoundTripsThroughShadersDirectory() throws {
        var shader = definition("custom-shader").makeNode(at: .zero)
        let source = CustomShaderSource.defaultSource + "\n// package round trip"
        shader.parameters["shaderSource"] = .string(source)
        var composition = CompositionFile.empty()
        composition.graph.nodes = [shader]
        let document = CompositionDocument(composition: composition)

        let wrapper = try document.makePackageWrapper()
        let filename = try XCTUnwrap(shader.configuration["shaderFile"]?.stringValue)
        let shaderData = try XCTUnwrap(
            wrapper.fileWrappers?["Shaders"]?.fileWrappers?[filename]?.regularFileContents
        )
        let jsonData = try XCTUnwrap(
            wrapper.fileWrappers?["composition.json"]?.regularFileContents
        )
        let encodedComposition = try CompositionCodec.decode(jsonData)
        let reopened = try CompositionDocument(packageWrapper: wrapper)

        XCTAssertEqual(String(data: shaderData, encoding: .utf8), source)
        XCTAssertNil(encodedComposition.graph.nodes[0].parameters["shaderSource"])
        XCTAssertEqual(
            reopened.composition.graph.nodes[0].parameters["shaderSource"], .string(source))
    }

    private func makeSolidRedTexture(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb,
            width: 2,
            height: 2,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pixels: [UInt8] = [
            255, 0, 0, 255, 255, 0, 0, 255,
            255, 0, 0, 255, 255, 0, 0, 255,
        ]
        texture.replace(
            region: MTLRegionMake2D(0, 0, 2, 2),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: 8
        )
        return texture
    }

    private func makePreviewTarget(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: 2,
            height: 2,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func definition(_ suffix: String) -> PatchDefinition {
        PatchRegistry.definition(for: "\(PatchRegistry.namespace).\(suffix)")!
    }
}

extension JSONValue {
    fileprivate var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}
