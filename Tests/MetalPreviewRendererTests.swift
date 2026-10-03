import MetalKit
import XCTest

@testable import Metaliquartz

@MainActor
final class MetalPreviewRendererTests: XCTestCase {
    func testAppleSiliconMacProvidesMetalDevice() {
        XCTAssertNotNil(MTLCreateSystemDefaultDevice())
    }

    func testPreviewShadersAreIncludedInDefaultLibrary() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: .main)

        XCTAssertNotNil(library.makeFunction(name: "previewVertex"))
        XCTAssertNotNil(library.makeFunction(name: "previewFragment"))
    }

    func testRendererCreatesCommandQueueAndPipeline() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm_srgb

        let renderer = try MetalPreviewRenderer(view: view)

        XCTAssertTrue(renderer.device === device)
        XCTAssertEqual(renderer.pipelineState.label, "Metaliquartz Preview Pipeline")
    }
}
