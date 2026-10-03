import Metal
import XCTest

@testable import Metaliquartz

final class LiveSessionTests: XCTestCase {
    func testVersionOneDocumentsWithoutLiveSettingsRemainReadable() throws {
        let original = CompositionFile.empty(now: Date(timeIntervalSince1970: 1_000))
        let encoded = try CompositionCodec.encode(original)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["liveSession"] = nil
        let legacyVersionOne = try JSONSerialization.data(withJSONObject: object)

        let decoded = try CompositionCodec.decode(legacyVersionOne)

        XCTAssertNil(decoded.liveSession)
        XCTAssertEqual(decoded.graph, original.graph)
    }

    func testLiveSettingsPublishedParametersAndPresetsRoundTrip() throws {
        var composition = CompositionFile.empty(now: Date(timeIntervalSince1970: 1_000))
        let number = try XCTUnwrap(
            PatchRegistry.definition(for: "\(PatchRegistry.namespace).number")
        ).makeNode(at: .zero)
        let published = PublishedParameterRecord(
            id: UUID(),
            name: "Intensity",
            nodeID: number.id,
            parameterKey: "value",
            minimum: -2,
            maximum: 3,
            smoothing: 0.25
        )
        composition.graph.nodes = [number]
        composition.liveSession = LiveSessionSettings(
            outputDisplayID: 42,
            outputResolution: LiveOutputResolution.ultraHD.rawValue
        )
        composition.publishedParameters = [published]
        composition.presets = [
            PresetRecord(
                id: UUID(),
                name: "Peak",
                values: [published.id: .number(2.5)]
            )
        ]

        let decoded = try CompositionCodec.decode(CompositionCodec.encode(composition))

        XCTAssertEqual(decoded, composition)
    }

    func testPublishedMappingClampsAndScalesNormalizedValues() {
        let parameter = PublishedParameterRecord(
            id: UUID(),
            name: "Mapped",
            nodeID: NodeID(),
            parameterKey: "value",
            minimum: -1,
            maximum: 3,
            smoothing: 0
        )

        XCTAssertEqual(
            PublishedParameterMapper.mappedValue(normalizedValue: -2, parameter: parameter),
            -1
        )
        XCTAssertEqual(
            PublishedParameterMapper.mappedValue(normalizedValue: 0.5, parameter: parameter),
            1
        )
        XCTAssertEqual(
            PublishedParameterMapper.mappedValue(normalizedValue: 4, parameter: parameter),
            3
        )
    }

    func testPublishedParameterSmoothingIsFrameRateIndependent() {
        let parameter = PublishedParameterRecord(
            id: UUID(),
            name: "Smooth",
            nodeID: NodeID(),
            parameterKey: "value",
            minimum: 0,
            maximum: 1,
            smoothing: 1
        )
        let smoother = PublishedParameterSmoother()

        XCTAssertEqual(smoother.value(for: parameter, target: 0, deltaTime: 0), 0)
        XCTAssertEqual(
            smoother.value(for: parameter, target: 1, deltaTime: 1),
            1 - exp(-1),
            accuracy: 0.000_001
        )
    }

    func testRecoverySnapshotRoundTripsPackageContents() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "MetaliquartzRecoveryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: directory) }
        var composition = CompositionFile.empty(now: Date(timeIntervalSince1970: 1_000))
        composition.metadata.title = "Recovered Stage"
        let original = CompositionDocument(
            composition: composition,
            assets: ["frame.bin": Data([1, 2, 3])]
        )

        let url = try ProjectRecoveryStore.save(original, directory: directory)
        let restored = try ProjectRecoveryStore.load(
            compositionID: composition.metadata.id,
            directory: directory
        )

        XCTAssertTrue(fileManager.fileExists(atPath: url.path))
        XCTAssertEqual(restored.composition, original.composition)
        XCTAssertEqual(restored.assets, original.assets)
    }

    @MainActor
    func testDiagnosticsTrackFramesDropsTexturesAndNodeErrors() {
        let diagnostics = RenderDiagnosticsModel()
        let nodeID = NodeID()

        diagnostics.record(
            frameInterval: 1.0 / 60.0,
            cpuMilliseconds: 2,
            gpuMilliseconds: 5,
            dropped: true,
            texturePool: TexturePoolStats(totalAllocated: 7, available: 3),
            nodeErrors: [nodeID: "Shader failed"]
        )

        XCTAssertEqual(diagnostics.snapshot.totalFrames, 1)
        XCTAssertEqual(diagnostics.snapshot.droppedFrames, 1)
        XCTAssertEqual(diagnostics.snapshot.texturePool.inUse, 4)
        XCTAssertEqual(diagnostics.snapshot.nodeErrors[nodeID], "Shader failed")
        diagnostics.reset()
        XCTAssertEqual(diagnostics.snapshot, RenderDiagnosticsSnapshot())
    }

    func testOutputResolutionDimensionsAreStable() {
        XCTAssertEqual(LiveOutputResolution.hd.size, CGSize(width: 1_280, height: 720))
        XCTAssertEqual(LiveOutputResolution.fullHD.size, CGSize(width: 1_920, height: 1_080))
        XCTAssertEqual(LiveOutputResolution.ultraHD.size, CGSize(width: 3_840, height: 2_160))
    }

    @MainActor
    func testFullscreenStatePreservesRequestedOutputConfiguration() {
        var composition = CompositionFile.empty()
        composition.metadata.title = "Stage Output"
        let state = FullscreenOutputState(
            composition: composition,
            assets: ["test.bin": Data([1])],
            transport: PlaybackTransportState(isPlaying: false),
            resolution: .ultraHD
        )

        XCTAssertEqual(state.composition.metadata.title, "Stage Output")
        XCTAssertEqual(state.assets["test.bin"], Data([1]))
        XCTAssertFalse(state.transport.isPlaying)
        XCTAssertEqual(state.resolution, .ultraHD)
    }
}
