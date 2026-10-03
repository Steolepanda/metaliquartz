import AppKit
import XCTest

@testable import Metaliquartz

final class AlphaHardeningTests: XCTestCase {
    func testApplicationHealthDetectsUncleanLaunchAndExportsLog() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertFalse(try ApplicationHealthStore.beginLaunch(directory: directory))
        ApplicationHealthStore.endLaunch(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("running-999999.marker"))
        XCTAssertTrue(try ApplicationHealthStore.beginLaunch(directory: directory))
        ApplicationHealthStore.record(
            category: "test",
            message: "Recoverable test failure",
            directory: directory
        )

        let report = ApplicationHealthStore.diagnosticReport(directory: directory)
        XCTAssertTrue(report.contains("Previous launch did not shut down cleanly"))
        XCTAssertTrue(report.contains("Recoverable test failure"))

        ApplicationHealthStore.endLaunch(directory: directory)
        XCTAssertFalse(try ApplicationHealthStore.beginLaunch(directory: directory))
        ApplicationHealthStore.endLaunch(directory: directory)
    }

    func testCorruptedPackagesProvideActionableErrors() throws {
        let missingComposition = FileWrapper(directoryWithFileWrappers: [:])
        XCTAssertThrowsError(try CompositionDocument(packageWrapper: missingComposition)) { error in
            guard case CompositionDocumentError.missingComposition = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertNotNil((error as? LocalizedError)?.recoverySuggestion)
        }

        let invalidJSON = FileWrapper(regularFileWithContents: Data("not json".utf8))
        let corrupt = FileWrapper(
            directoryWithFileWrappers: ["composition.json": invalidJSON]
        )
        XCTAssertThrowsError(try CompositionDocument(packageWrapper: corrupt)) { error in
            guard case CompositionDocumentError.unreadableComposition = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testBundledSampleCompositionsAreValidAndRoundTrip() throws {
        XCTAssertGreaterThanOrEqual(SampleCompositionLibrary.samples.count, 2)
        for sample in SampleCompositionLibrary.samples {
            XCTAssertTrue(
                GraphValidator.validate(sample.composition.graph).isEmpty,
                "\(sample.title) contains an invalid graph"
            )
            let package = try sample.document.makePackageWrapper()
            let restored = try CompositionDocument(packageWrapper: package)
            XCTAssertEqual(restored.composition, sample.composition)
        }
    }

    func testRecoverySnapshotsCanBeEnumeratedAndRemoved() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = CompositionDocument()

        let url = try ProjectRecoveryStore.save(document, directory: directory)
        XCTAssertEqual(
            ProjectRecoveryStore.availableSnapshots(directory: directory).map(
                \.standardizedFileURL),
            [url.standardizedFileURL]
        )
        try ProjectRecoveryStore.remove(
            compositionID: document.composition.metadata.id,
            directory: directory
        )
        XCTAssertTrue(ProjectRecoveryStore.availableSnapshots(directory: directory).isEmpty)
    }

    @MainActor
    func testDiagnosticsCalculateRollingP95AndDropPercentage() {
        let diagnostics = RenderDiagnosticsModel()
        for milliseconds in 1...100 {
            diagnostics.record(
                frameInterval: 1.0 / 60.0,
                cpuMilliseconds: Double(milliseconds),
                gpuMilliseconds: 1,
                dropped: milliseconds == 100,
                texturePool: TexturePoolStats(totalAllocated: 2, available: 1),
                nodeErrors: [:]
            )
        }

        XCTAssertEqual(diagnostics.snapshot.p95FrameMilliseconds, 95)
        XCTAssertEqual(diagnostics.snapshot.droppedFramePercentage, 1, accuracy: 0.000_1)
    }

    @MainActor
    func testCanvasPublishesKeyboardAccessibilitySummary() throws {
        let node = try XCTUnwrap(
            PatchRegistry.definition(for: "\(PatchRegistry.namespace).number")
        ).makeNode(at: .zero)
        let canvas = GraphCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        canvas.update(
            graph: GraphRecord(nodes: [node], connections: []),
            editorState: .default,
            macros: []
        )

        XCTAssertEqual(canvas.accessibilityRole(), .group)
        XCTAssertTrue((canvas.accessibilityValue() as? String)?.contains("1 patches") == true)
        XCTAssertNotNil(canvas.accessibilityHelp())
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "MetaliquartzAlphaTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}
