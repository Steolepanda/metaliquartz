import AppKit
import MetalKit
import XCTest

@testable import Metaliquartz

@MainActor
final class FeedbackTests: XCTestCase {
    func testFeedbackIsTheOnlyExplicitCycleBoundary() throws {
        let feedback = definition("feedback").makeNode(at: .zero)
        let blend = definition("blend").makeNode(at: .zero)
        let allowedGraph = GraphRecord(
            nodes: [blend, feedback],
            connections: [
                connect(feedback, "image", blend, "background"),
                connect(blend, "image", feedback, "image"),
            ]
        )

        XCTAssertTrue(feedback.breaksFrameCycle)
        XCTAssertTrue(GraphValidator.validate(allowedGraph).isEmpty)
        XCTAssertEqual(
            try GraphCompiler.compile(allowedGraph).nodes.map(\.nodeID),
            [blend.id, feedback.id]
        )

        let first = definition("transform-2d").makeNode(at: .zero)
        let second = definition("transform-2d").makeNode(at: .zero)
        let accidentalCycle = GraphRecord(
            nodes: [first, second],
            connections: [
                connect(first, "image", second, "image"),
                connect(second, "image", first, "image"),
            ]
        )
        XCTAssertEqual(GraphValidator.validate(accidentalCycle), [.cycleDetected])
    }

    func testFeedbackStoreCopiesReusesResizesAndResetsTextures() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let store = FeedbackTextureStore(device: device)
        let nodeID = NodeID()
        let red = try makeTexture(device: device, width: 2, height: 2, rgba: [255, 0, 0, 255])
        let blue = try makeTexture(device: device, width: 2, height: 2, rgba: [0, 0, 255, 255])

        let firstBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let first = try XCTUnwrap(
            store.capture(nodeID: nodeID, source: red, commandBuffer: firstBuffer)
        )
        firstBuffer.commit()
        firstBuffer.waitUntilCompleted()
        XCTAssertEqual(
            Array(try rgbaBytes(texture: first, queue: queue).prefix(4)),
            [255, 0, 0, 255]
        )

        let secondBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let reused = try XCTUnwrap(
            store.capture(nodeID: nodeID, source: blue, commandBuffer: secondBuffer)
        )
        secondBuffer.commit()
        secondBuffer.waitUntilCompleted()
        XCTAssertTrue(first === reused)
        XCTAssertEqual(
            Array(try rgbaBytes(texture: reused, queue: queue).prefix(4)),
            [0, 0, 255, 255]
        )

        let largerSource = try makeTexture(
            device: device,
            width: 4,
            height: 4,
            rgba: [0, 255, 0, 255]
        )
        let resizeBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let resized = try XCTUnwrap(
            store.capture(nodeID: nodeID, source: largerSource, commandBuffer: resizeBuffer)
        )
        resizeBuffer.commit()
        resizeBuffer.waitUntilCompleted()
        XCTAssertFalse(reused === resized)
        XCTAssertEqual(resized.width, 4)
        XCTAssertEqual(resized.height, 4)

        store.reset()
        XCTAssertEqual(store.retainedTextureCount, 0)
        XCTAssertNil(store.texture(for: nodeID))
    }

    func testFeedbackGraphStartsCleanCapturesAndClears() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: .main)
        let renderer = try MetalImageRenderer(device: device, library: library)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let assetID = UUID()
        let filename = "feedback-red.png"
        var image = definition("image-file").makeNode(at: .zero)
        image.parameters["assetID"] = .string(assetID.uuidString)
        let blend = definition("blend").makeNode(at: .zero)
        var feedback = definition("feedback").makeNode(at: .zero)
        let preview = definition("preview-output").makeNode(at: .zero)
        var composition = CompositionFile.empty()
        composition.graph = GraphRecord(
            nodes: [image, blend, feedback, preview],
            connections: [
                connect(image, "image", blend, "foreground"),
                connect(feedback, "image", blend, "background"),
                connect(blend, "image", feedback, "image"),
                connect(blend, "image", preview, "image"),
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

        let firstTarget = try makePreviewTarget(device: device)
        let firstBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(
            renderer.encodeFrame(
                target: firstTarget,
                drawableSize: CGSize(width: 2, height: 2),
                commandBuffer: firstBuffer
            )
        )
        firstBuffer.commit()
        firstBuffer.waitUntilCompleted()
        XCTAssertGreaterThan(previewBytes(firstTarget)[2], 245)
        XCTAssertEqual(renderer.feedbackStore.retainedTextureCount, 1)

        feedback.parameters["clear"] = .boolean(true)
        composition.graph.nodes[2] = feedback
        renderer.update(
            composition: composition,
            assets: [filename: try makeRedPNGData()],
            transport: PlaybackTransportState()
        )
        let clearTarget = try makePreviewTarget(device: device)
        let clearBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(
            renderer.encodeFrame(
                target: clearTarget,
                drawableSize: CGSize(width: 2, height: 2),
                commandBuffer: clearBuffer
            )
        )
        clearBuffer.commit()
        clearBuffer.waitUntilCompleted()

        XCTAssertGreaterThan(previewBytes(clearTarget)[2], 245)
        XCTAssertEqual(renderer.feedbackStore.retainedTextureCount, 0)
    }

    func testTransportResetClearsFeedbackWithoutChangingTheGraph() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: .main)
        let renderer = try MetalImageRenderer(device: device, library: library)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let feedback = definition("feedback").makeNode(at: .zero)
        var composition = CompositionFile.empty()
        composition.graph.nodes = [feedback]
        renderer.update(
            composition: composition,
            assets: [:],
            transport: PlaybackTransportState()
        )
        let source = try makeTexture(
            device: device,
            width: 2,
            height: 2,
            rgba: [255, 0, 0, 255]
        )
        let captureBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        renderer.feedbackStore.capture(
            nodeID: feedback.id,
            source: source,
            commandBuffer: captureBuffer
        )
        captureBuffer.commit()
        captureBuffer.waitUntilCompleted()
        XCTAssertEqual(renderer.feedbackStore.retainedTextureCount, 1)

        renderer.update(
            composition: composition,
            assets: [:],
            transport: PlaybackTransportState(isPlaying: true, resetToken: 1)
        )

        XCTAssertEqual(renderer.feedbackStore.retainedTextureCount, 0)
    }

    func testFeedbackOutputIsExactlyOneFrameBehindItsInput() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: .main)
        let renderer = try MetalImageRenderer(device: device, library: library)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let redID = UUID()
        let blueID = UUID()
        var image = definition("image-file").makeNode(at: .zero)
        image.parameters["assetID"] = .string(redID.uuidString)
        let feedback = definition("feedback").makeNode(at: .zero)
        let preview = definition("preview-output").makeNode(at: .zero)
        var composition = CompositionFile.empty()
        composition.graph = GraphRecord(
            nodes: [image, feedback, preview],
            connections: [
                connect(image, "image", feedback, "image"),
                connect(feedback, "image", preview, "image"),
            ]
        )
        composition.assets = [
            AssetReference(
                id: redID,
                filename: "red.png",
                originalFilename: "red.png",
                mediaType: AssetMediaKind.image.rawValue
            ),
            AssetReference(
                id: blueID,
                filename: "blue.png",
                originalFilename: "blue.png",
                mediaType: AssetMediaKind.image.rawValue
            ),
        ]
        let assets = [
            "red.png": try makePNGData(red: 255, green: 0, blue: 0),
            "blue.png": try makePNGData(red: 0, green: 0, blue: 255),
        ]
        renderer.update(
            composition: composition,
            assets: assets,
            transport: PlaybackTransportState()
        )

        let seedTarget = try makePreviewTarget(device: device)
        let seedBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertFalse(
            renderer.encodeFrame(
                target: seedTarget,
                drawableSize: CGSize(width: 2, height: 2),
                commandBuffer: seedBuffer
            )
        )
        seedBuffer.commit()
        seedBuffer.waitUntilCompleted()

        image.parameters["assetID"] = .string(blueID.uuidString)
        composition.graph.nodes[0] = image
        renderer.update(
            composition: composition,
            assets: assets,
            transport: PlaybackTransportState()
        )
        let previousFrameTarget = try makePreviewTarget(device: device)
        let previousFrameBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(
            renderer.encodeFrame(
                target: previousFrameTarget,
                drawableSize: CGSize(width: 2, height: 2),
                commandBuffer: previousFrameBuffer
            )
        )
        previousFrameBuffer.commit()
        previousFrameBuffer.waitUntilCompleted()
        let previousFrameBytes = previewBytes(previousFrameTarget)
        XCTAssertGreaterThan(previousFrameBytes[2], 245)
        XCTAssertLessThan(previousFrameBytes[0], 8)

        let currentFrameTarget = try makePreviewTarget(device: device)
        let currentFrameBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(
            renderer.encodeFrame(
                target: currentFrameTarget,
                drawableSize: CGSize(width: 2, height: 2),
                commandBuffer: currentFrameBuffer
            )
        )
        currentFrameBuffer.commit()
        currentFrameBuffer.waitUntilCompleted()
        let currentFrameBytes = previewBytes(currentFrameTarget)
        XCTAssertGreaterThan(currentFrameBytes[0], 245)
        XCTAssertLessThan(currentFrameBytes[2], 8)
    }

    func testRepeatedFeedbackFramesReuseOneRetainedTexture() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let store = FeedbackTextureStore(device: device)
        let nodeID = NodeID()
        let source = try makeTexture(
            device: device,
            width: 64,
            height: 64,
            rgba: [255, 0, 0, 255]
        )
        var firstTexture: MTLTexture?

        for _ in 0..<120 {
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            let texture = try XCTUnwrap(
                store.capture(nodeID: nodeID, source: source, commandBuffer: commandBuffer)
            )
            if let firstTexture {
                XCTAssertTrue(firstTexture === texture)
            } else {
                firstTexture = texture
            }
            commandBuffer.commit()
        }
        let fence = try XCTUnwrap(queue.makeCommandBuffer())
        fence.commit()
        fence.waitUntilCompleted()

        XCTAssertEqual(fence.status, .completed)
        XCTAssertEqual(store.retainedTextureCount, 1)
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
                $0.direction == .output && $0.key == outputKey
            }!.id,
            inputNodeID: inputNode.id,
            inputPortID: inputNode.ports.first {
                $0.direction == .input && $0.key == inputKey
            }!.id
        )
    }

    private func makeTexture(
        device: MTLDevice,
        width: Int,
        height: Int,
        rgba: [UInt8]
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * height * 4)
        for _ in 0..<(width * height) { pixels.append(contentsOf: rgba) }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: width * 4
        )
        return texture
    }

    private func rgbaBytes(texture: MTLTexture, queue: MTLCommandQueue) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        let readback = try XCTUnwrap(texture.device.makeTexture(descriptor: descriptor))
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        encoder.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: .init(x: 0, y: 0, z: 0),
            sourceSize: .init(width: texture.width, height: texture.height, depth: 1),
            to: readback,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: .init(x: 0, y: 0, z: 0)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        readback.getBytes(
            &bytes,
            bytesPerRow: texture.width * 4,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
        return bytes
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

    private func previewBytes(_ texture: MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16)
        texture.getBytes(
            &bytes,
            bytesPerRow: 8,
            from: MTLRegionMake2D(0, 0, 2, 2),
            mipmapLevel: 0
        )
        return bytes
    }

    private func makeRedPNGData() throws -> Data {
        try makePNGData(red: 255, green: 0, blue: 0)
    }

    private func makePNGData(red: UInt8, green: UInt8, blue: UInt8) throws -> Data {
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
            pixels[index] = red
            pixels[index + 1] = green
            pixels[index + 2] = blue
            pixels[index + 3] = 255
        }
        return try XCTUnwrap(
            bitmap.representation(using: .png, properties: [:])
        )
    }
}
