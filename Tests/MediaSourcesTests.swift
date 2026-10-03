import CoreVideo
import Metal
import XCTest

@testable import Metaliquartz

final class MediaSourcesTests: XCTestCase {
    func testEmbeddedMovieCacheUsesStableAssetURL() throws {
        let assetID = UUID()
        let data = Data([1, 2, 3, 4])

        let first = try EmbeddedMediaCache.fileURL(
            assetID: assetID,
            filename: "clip.mov",
            data: data
        )
        let second = try EmbeddedMediaCache.fileURL(
            assetID: assetID,
            filename: "renamed.mov",
            data: data
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.pathExtension, "mov")
        XCTAssertEqual(try Data(contentsOf: first), data)
    }

    func testPixelBufferBridgesToMetalWithoutCopyingDimensions() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            32,
            18,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
            ] as CFDictionary,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let converter = PixelBufferTextureConverter(device: device)

        let frame = try XCTUnwrap(converter.makeTexture(from: try XCTUnwrap(pixelBuffer)))

        XCTAssertEqual(frame.texture.width, 32)
        XCTAssertEqual(frame.texture.height, 18)
        XCTAssertEqual(frame.texture.pixelFormat, .bgra8Unorm)
    }

    func testMovieAndCameraDefinitionsExposeImageOutputs() throws {
        let movie = try XCTUnwrap(
            PatchRegistry.definition(for: "\(PatchRegistry.namespace).movie-file")
        )
        let camera = try XCTUnwrap(
            PatchRegistry.definition(for: "\(PatchRegistry.namespace).camera")
        )

        XCTAssertEqual(movie.executorKind, .movieImage)
        XCTAssertEqual(camera.executorKind, .cameraImage)
        XCTAssertEqual(movie.ports.first?.dataType, .image)
        XCTAssertEqual(camera.ports.first?.dataType, .image)
        XCTAssertTrue(
            movie.parameters.contains { schema in
                if case .asset(_, _, .movie) = schema { return true }
                return false
            })
    }
}
