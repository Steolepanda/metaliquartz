import MetalKit
import XCTest

@testable import Metaliquartz

@MainActor
final class GeometryRendererTests: XCTestCase {
    func testGeometryPatchDefinitionsExposeTypedImagePortsAndControls() throws {
        let suffixes = ["sprite", "mesh-displacement", "point-grid", "line-grid"]

        for suffix in suffixes {
            let definition = try XCTUnwrap(
                PatchRegistry.definition(for: "\(PatchRegistry.namespace).\(suffix)")
            )
            XCTAssertTrue(
                definition.ports.contains {
                    $0.direction == .input && $0.dataType == .image
                }
            )
            XCTAssertTrue(
                definition.ports.contains {
                    $0.direction == .output && $0.dataType == .image
                }
            )
            XCTAssertTrue(definition.parameters.contains { $0.key == "resolution" })
            XCTAssertTrue(definition.parameters.contains { $0.key == "tint" })
        }
    }

    func testGeometryPipelinesCompile() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: .main)
        let pool = TexturePool(device: device)

        let renderer = try GeometryRenderer(device: device, library: library, texturePool: pool)

        XCTAssertEqual(renderer.spritePipeline.label, "Metaliquartz Sprite Pipeline")
        XCTAssertEqual(renderer.meshPipeline.label, "Metaliquartz Mesh Displacement Pipeline")
        XCTAssertEqual(renderer.pointPipeline.label, "Metaliquartz Point Grid Pipeline")
        XCTAssertEqual(renderer.linePipeline.label, "Metaliquartz Line Grid Pipeline")
    }

    func testGeometryRenderersProduceStableGPUCoverage() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: .main)
        let imageRenderer = try MetalImageRenderer(device: device, library: library)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let source = try makeSolidRedTexture(device: device, width: 64, height: 64)
        let cases: [(String, PatchExecutorKind, Int, Int)] = [
            ("sprite", .sprite, 4_096, 0),
            ("mesh-displacement", .meshDisplacement, 2_304, 150),
            ("point-grid", .pointGrid, 3_136, 200),
            ("line-grid", .lineGrid, 2_304, 150),
        ]

        for (suffix, kind, expectedLitPixels, tolerance) in cases {
            var node = definition(suffix).makeNode(at: .zero)
            node.parameters["columns"] = .number(8)
            node.parameters["rows"] = .number(8)
            node.parameters["pointSize"] = .number(8)
            node.parameters["lineSize"] = .number(3)
            node.parameters["displacement"] = .number(0.4)
            let target = try makePreviewTarget(device: device, width: 64, height: 64)
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            let output = try XCTUnwrap(
                imageRenderer.geometryRenderer.encode(
                    kind: kind,
                    node: node,
                    source: source,
                    commandBuffer: commandBuffer
                )
            )
            imageRenderer.encodePreview(
                source: output,
                target: target,
                drawableSize: CGSize(width: 64, height: 64),
                commandBuffer: commandBuffer
            )
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()

            XCTAssertEqual(commandBuffer.status, .completed)
            let litPixels = redPixelCount(texture: target)
            XCTAssertEqual(
                litPixels,
                expectedLitPixels,
                accuracy: tolerance,
                "\(suffix) GPU coverage changed beyond its golden-image tolerance."
            )
            imageRenderer.texturePool.recycle(output)
        }
    }

    func testAllGeometryRenderersSubmitAt1080p() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: .main)
        let pool = TexturePool(device: device)
        let renderer = try GeometryRenderer(device: device, library: library, texturePool: pool)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let source = try makeSolidRedTexture(device: device, width: 64, height: 64)
        let cases: [(String, PatchExecutorKind)] = [
            ("sprite", .sprite),
            ("mesh-displacement", .meshDisplacement),
            ("point-grid", .pointGrid),
            ("line-grid", .lineGrid),
        ]
        var outputs: [MTLTexture] = []

        for (suffix, kind) in cases {
            var node = definition(suffix).makeNode(at: .zero)
            node.parameters["resolution"] = .string("1920×1080")
            node.parameters["columns"] = .number(16)
            node.parameters["rows"] = .number(9)
            let output = try XCTUnwrap(
                renderer.encode(
                    kind: kind,
                    node: node,
                    source: source,
                    commandBuffer: commandBuffer
                )
            )
            XCTAssertEqual(output.width, 1_920)
            XCTAssertEqual(output.height, 1_080)
            outputs.append(output)
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        XCTAssertEqual(commandBuffer.status, .completed)
        outputs.forEach(pool.recycle)
    }

    private func redPixelCount(texture: MTLTexture) -> Int {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(
            &bytes,
            bytesPerRow: texture.width * 4,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
        return stride(from: 2, to: bytes.count, by: 4).count { bytes[$0] > 48 }
    }

    private func makeSolidRedTexture(
        device: MTLDevice,
        width: Int,
        height: Int
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = 255
            pixels[index + 3] = 255
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: width * 4
        )
        return texture
    }

    private func makePreviewTarget(
        device: MTLDevice,
        width: Int,
        height: Int
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: width,
            height: height,
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
