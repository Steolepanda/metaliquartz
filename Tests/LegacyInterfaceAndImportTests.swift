import AppKit
import XCTest

@testable import Metaliquartz

final class LegacyInterfaceAndImportTests: XCTestCase {
    func testInterfacePreferenceRequiresFirstChoiceAndPersistsSelection() throws {
        let suiteName = "LegacyInterfaceAndImportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(InterfacePreference.selectedStyle(in: defaults))
        InterfacePreference.select(.legacy, in: defaults)
        XCTAssertEqual(InterfacePreference.selectedStyle(in: defaults), .legacy)
    }

    func testLegacyPanelsStartDetachedAndVisible() throws {
        let suiteName = "LegacyInterfaceAndImportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(LegacyPanelPreferences.isDocked(.library, defaults: defaults))
        XCTAssertTrue(LegacyPanelPreferences.isVisible(.library, defaults: defaults))

        LegacyPanelPreferences.setDocked(true, panel: .library, defaults: defaults)
        LegacyPanelPreferences.setVisible(false, panel: .library, defaults: defaults)
        XCTAssertTrue(LegacyPanelPreferences.isDocked(.library, defaults: defaults))
        XCTAssertFalse(LegacyPanelPreferences.isVisible(.library, defaults: defaults))
    }

    func testLegacyPanelFrameIsConstrainedToVisibleScreen() {
        let visibleFrame = CGRect(x: 100, y: 200, width: 1_000, height: 700)
        let result = LegacyPanelPreferences.constrainedFrame(
            CGRect(x: -500, y: 2_000, width: 1_400, height: 900),
            to: visibleFrame
        )

        XCTAssertEqual(result, CGRect(x: 116, y: 216, width: 968, height: 668))
    }

    func testImageDropValidationAcceptsPNGAndRejectsArbitraryData() throws {
        let png = try makePNG()

        switch ImageDropResolver.validatedPayload(filename: "test.png", data: png) {
        case .success(let payload):
            XCTAssertEqual(payload.filename, "test.png")
            XCTAssertEqual(payload.data, png)
        case .failure(let error):
            XCTFail(error.failure.reason)
        }

        switch ImageDropResolver.validatedPayload(
            filename: "not-an-image.bin",
            data: Data([1, 2, 3])
        ) {
        case .success:
            XCTFail("Arbitrary data should not validate as an image")
        case .failure(let error):
            XCTAssertEqual(error.failure.filename, "not-an-image.bin")
        }
    }

    func testMultiImageDropCreatesThreeColumnLayoutAndSelectsAffectedNodes() throws {
        let payloads = (1...4).map {
            ImageImportPayload(filename: "image-\($0).png", data: Data([$0]))
        }
        let document = CompositionDocument()

        let result = try XCTUnwrap(
            ImageImportMutation.apply(
                payloads: payloads,
                to: document,
                at: .root,
                dropPoint: CanvasPoint(x: 40, y: 70),
                targetNodeID: nil
            )
        )

        XCTAssertEqual(result.document.composition.graph.nodes.count, 4)
        XCTAssertEqual(result.document.composition.assets.count, 4)
        XCTAssertEqual(result.document.assets.count, 4)
        XCTAssertEqual(
            result.document.composition.graph.nodes.map(\.position),
            [
                CanvasPoint(x: 40, y: 70),
                CanvasPoint(x: 262, y: 70),
                CanvasPoint(x: 484, y: 70),
                CanvasPoint(x: 40, y: 196),
            ]
        )
        XCTAssertEqual(
            result.document.composition.editorState.selectedNodeIDs,
            result.affectedNodeIDs
        )
    }

    func testReplacingImageRetainsAssetsStillReferencedByAnotherPatch() throws {
        let definition = try XCTUnwrap(
            PatchRegistry.definition(for: "\(PatchRegistry.namespace).image-file")
        )
        let oldID = UUID()
        let oldFilename = "\(oldID.uuidString)-old.png"
        var first = definition.makeNode(at: CanvasPoint(x: 10, y: 20))
        var second = definition.makeNode(at: CanvasPoint(x: 250, y: 20))
        first.parameters["assetID"] = .string(oldID.uuidString)
        second.parameters["assetID"] = .string(oldID.uuidString)
        var document = CompositionDocument()
        document.composition.graph.nodes = [first, second]
        document.composition.assets = [
            AssetReference(
                id: oldID,
                filename: oldFilename,
                originalFilename: "old.png",
                mediaType: AssetMediaKind.image.rawValue
            )
        ]
        document.assets[oldFilename] = Data([9])

        let result = try XCTUnwrap(
            ImageImportMutation.apply(
                payloads: [ImageImportPayload(filename: "new.png", data: Data([8]))],
                to: document,
                at: .root,
                dropPoint: .zero,
                targetNodeID: first.id
            )
        )

        XCTAssertEqual(result.document.composition.graph.nodes.count, 2)
        XCTAssertEqual(result.document.composition.assets.count, 2)
        XCTAssertEqual(result.document.assets[oldFilename], Data([9]))
        XCTAssertEqual(result.affectedNodeIDs, [first.id])
    }

    func testReplacingLastReferenceRemovesOldEmbeddedAsset() throws {
        let definition = try XCTUnwrap(
            PatchRegistry.definition(for: "\(PatchRegistry.namespace).image-file")
        )
        let oldID = UUID()
        let oldFilename = "\(oldID.uuidString)-old.png"
        var node = definition.makeNode(at: .zero)
        node.parameters["assetID"] = .string(oldID.uuidString)
        var document = CompositionDocument()
        document.composition.graph.nodes = [node]
        document.composition.assets = [
            AssetReference(
                id: oldID,
                filename: oldFilename,
                originalFilename: "old.png",
                mediaType: AssetMediaKind.image.rawValue
            )
        ]
        document.assets[oldFilename] = Data([9])

        let result = try XCTUnwrap(
            ImageImportMutation.apply(
                payloads: [ImageImportPayload(filename: "new.png", data: Data([8]))],
                to: document,
                at: .root,
                dropPoint: .zero,
                targetNodeID: node.id
            )
        )

        XCTAssertNil(result.document.assets[oldFilename])
        XCTAssertFalse(result.document.composition.assets.contains { $0.id == oldID })
        XCTAssertEqual(result.document.composition.assets.count, 1)
    }

    func testImageDropMutatesRequestedMacroWithoutChangingRootGraph() throws {
        let macroID = MacroID()
        var document = CompositionDocument()
        document.composition.macroDefinitions = [
            MacroDefinitionRecord(
                id: macroID,
                name: "Nested",
                graph: .empty,
                editorState: .default,
                ports: []
            )
        ]

        let result = try XCTUnwrap(
            ImageImportMutation.apply(
                payloads: [ImageImportPayload(filename: "macro.png", data: Data([7]))],
                to: document,
                at: .macro(macroID),
                dropPoint: CanvasPoint(x: 90, y: 120),
                targetNodeID: nil
            )
        )

        XCTAssertTrue(result.document.composition.graph.nodes.isEmpty)
        let macro = try XCTUnwrap(result.document.composition.macroDefinition(id: macroID))
        XCTAssertEqual(macro.graph.nodes.count, 1)
        XCTAssertEqual(macro.graph.nodes[0].position, CanvasPoint(x: 90, y: 120))
        XCTAssertEqual(macro.editorState.selectedNodeIDs, result.affectedNodeIDs)
    }

    private func makePNG() throws -> Data {
        let representation = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 2,
                pixelsHigh: 2,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        representation.setColor(.systemBlue, atX: 0, y: 0)
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }
}
