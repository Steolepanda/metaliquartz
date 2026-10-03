import AppKit
import MetalKit
import XCTest

@testable import Metaliquartz

@MainActor
final class MetalImageRendererTests: XCTestCase {
    func testImagePipelinesCompileFromDefaultLibrary() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: .main)

        let renderer = try MetalImageRenderer(device: device, library: library)

        XCTAssertEqual(renderer.transformPipeline.label, "Metaliquartz Transform 2D Pipeline")
        XCTAssertEqual(renderer.previewPipeline.label, "Metaliquartz Texture Preview Pipeline")
    }

    func testTexturePoolReusesMatchingIntermediateTexture() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let pool = TexturePool(device: device)
        let key = TexturePoolKey(width: 64, height: 32, pixelFormat: .rgba16Float)
        let first = try XCTUnwrap(
            pool.acquire(width: key.width, height: key.height, pixelFormat: key.pixelFormat)
        )

        pool.recycle(first)
        XCTAssertEqual(pool.availableCount(for: key), 1)
        let reused = try XCTUnwrap(
            pool.acquire(width: key.width, height: key.height, pixelFormat: key.pixelFormat)
        )

        XCTAssertTrue(first === reused)
        XCTAssertEqual(pool.availableCount(for: key), 0)
    }

    func testIdentityTransformRendersRedTextureIntoPreview() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: .main)
        let renderer = try MetalImageRenderer(device: device, library: library)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let source = try makeRedTexture(device: device)
        let target = try makePreviewTarget(device: device)

        let transformed = try XCTUnwrap(
            renderer.encodeTransform(
                source: source,
                parameters: [
                    "translationX": .number(0),
                    "translationY": .number(0),
                    "scale": .number(1),
                    "rotation": .number(0),
                    "opacity": .number(1),
                ],
                commandBuffer: commandBuffer
            )
        )
        renderer.encodePreview(
            source: transformed,
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
        XCTAssertLessThan(bytes[0], 8)
        XCTAssertLessThan(bytes[1], 8)
        XCTAssertGreaterThan(bytes[2], 245)
        XCTAssertEqual(bytes[3], 255)
        renderer.texturePool.recycle(transformed)
    }

    func testImageTransformPreviewGraphRendersEmbeddedAsset() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: .main)
        let renderer = try MetalImageRenderer(device: device, library: library)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let target = try makePreviewTarget(device: device)
        let assetID = UUID()
        let filename = "red.png"
        var image = definition("image-file").makeNode(at: .zero)
        image.parameters["assetID"] = .string(assetID.uuidString)
        let transform = definition("transform-2d").makeNode(at: .zero)
        let preview = definition("preview-output").makeNode(at: .zero)
        var composition = CompositionFile.empty()
        composition.graph = GraphRecord(
            nodes: [image, transform, preview],
            connections: [
                connect(image, "image", transform, "image"),
                connect(transform, "image", preview, "image"),
            ]
        )
        composition.assets = [
            AssetReference(
                id: assetID,
                filename: filename,
                originalFilename: filename,
                mediaType: AssetMediaKind.image.rawValue
            )
        ]
        renderer.update(
            composition: composition,
            assets: [filename: try makeRedPNGData()],
            transport: PlaybackTransportState()
        )
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())

        XCTAssertTrue(
            renderer.encodeFrame(
                target: target,
                drawableSize: CGSize(width: 2, height: 2),
                commandBuffer: commandBuffer
            )
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
        XCTAssertGreaterThan(bytes[2], 245)
        XCTAssertEqual(bytes[3], 255)
    }

    func testGoldenGradientInvertPreviewChainRendersOnGPU() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: .main)
        let renderer = try MetalImageRenderer(device: device, library: library)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: 4,
            height: 1,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))

        var gradient = definition("qc.linear-gradient").makeNode(at: .zero)
        gradient.parameters["point1X"] = .number(4)
        gradient.parameters["point1Y"] = .number(0)
        let invert = definition("qc.color-invert").makeNode(at: .zero)
        let preview = definition("preview-output").makeNode(at: .zero)
        var composition = CompositionFile.empty()
        composition.graph = GraphRecord(
            nodes: [gradient, invert, preview],
            connections: [
                connect(gradient, "image", invert, "image"),
                connect(invert, "image", preview, "image"),
            ]
        )
        renderer.update(
            composition: composition,
            assets: [:],
            transport: PlaybackTransportState()
        )
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())

        XCTAssertTrue(
            renderer.encodeFrame(
                target: target,
                drawableSize: CGSize(width: 4, height: 1),
                commandBuffer: commandBuffer
            )
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        XCTAssertEqual(commandBuffer.status, .completed)
        var bytes = [UInt8](repeating: 0, count: 16)
        target.getBytes(
            &bytes,
            bytesPerRow: 16,
            from: MTLRegionMake2D(0, 0, 4, 1),
            mipmapLevel: 0
        )
        XCTAssertLessThan(bytes[0], bytes[12])
        XCTAssertGreaterThan(Int(bytes[12]) - Int(bytes[0]), 80)
        XCTAssertEqual(bytes[3], 255)
        XCTAssertEqual(bytes[15], 255)
    }

    func testGoldenAuthoringJourneyPackageRoundTrips() throws {
        var gradient = definition("qc.linear-gradient").makeNode(
            at: CanvasPoint(x: 80, y: 70)
        )
        gradient.parameters["point1X"] = .number(45)
        let invert = definition("qc.color-invert").makeNode(
            at: CanvasPoint(x: 300, y: 70)
        )
        let preview = definition("preview-output").makeNode(
            at: CanvasPoint(x: 520, y: 70)
        )
        var composition = CompositionFile.empty()
        composition.graph = GraphRecord(
            nodes: [gradient, invert, preview],
            connections: [
                connect(gradient, "image", invert, "image"),
                connect(invert, "image", preview, "image"),
            ]
        )

        let reopened = try CompositionDocument(
            packageWrapper: CompositionDocument(composition: composition).makePackageWrapper()
        )

        XCTAssertEqual(reopened.composition.graph.nodes.count, 3)
        XCTAssertEqual(reopened.composition.graph.connections.count, 2)
        XCTAssertEqual(
            reopened.composition.graph.nodes.first { $0.id == gradient.id }?
                .parameters["point1X"],
            .number(45)
        )
    }

    private func makeRedTexture(device: MTLDevice) throws -> MTLTexture {
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

    private func makeRedPNGData() throws -> Data {
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 2,
                pixelsHigh: 2,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 8,
                bitsPerPixel: 32
            )
        )
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for index in stride(from: 0, to: 16, by: 4) {
            pixels[index] = 255
            pixels[index + 1] = 0
            pixels[index + 2] = 0
            pixels[index + 3] = 255
        }
        return try XCTUnwrap(
            bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:])
        )
    }

    private func definition(_ suffix: String) -> PatchDefinition {
        PatchRegistry.definition(for: "\(PatchRegistry.namespace).\(suffix)")!
    }

    private func connect(
        _ outputNode: NodeRecord,
        _ outputKey: String,
        _ inputNode: NodeRecord,
        _ inputKey: String
    ) -> ConnectionRecord {
        ConnectionRecord(
            outputNodeID: outputNode.id,
            outputPortID: outputNode.ports.first {
                $0.key == outputKey && $0.direction == .output
            }!.id,
            inputNodeID: inputNode.id,
            inputPortID: inputNode.ports.first {
                $0.key == inputKey && $0.direction == .input
            }!.id
        )
    }
}
