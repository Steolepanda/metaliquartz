import SwiftUI
import XCTest

@testable import Metaliquartz

final class CompositionModelTests: XCTestCase {
    func testCompositionRoundTripPreservesGraphAndEditorLayout() throws {
        let output = PortRecord(
            id: PortID(),
            key: "image",
            name: "Image",
            direction: .output,
            dataType: .image
        )
        let input = PortRecord(
            id: PortID(),
            key: "image",
            name: "Image",
            direction: .input,
            dataType: .image
        )
        let source = NodeRecord(
            patchType: "test.source",
            name: "Source",
            position: CanvasPoint(x: 125.25, y: -42.5),
            ports: [output],
            configuration: ["unknownFutureField": .array([.number(3), .string("kept")])]
        )
        let outputNode = NodeRecord(
            patchType: "test.output",
            name: "Output",
            position: CanvasPoint(x: 480, y: 90),
            ports: [input]
        )
        var original = CompositionFile.empty(now: Date(timeIntervalSince1970: 1_000))
        original.graph = GraphRecord(
            nodes: [source, outputNode],
            connections: [
                ConnectionRecord(
                    outputNodeID: source.id,
                    outputPortID: output.id,
                    inputNodeID: outputNode.id,
                    inputPortID: input.id
                )
            ]
        )
        original.editorState = EditorStateRecord(
            viewport: CanvasViewport(origin: CanvasPoint(x: 14.5, y: -8), zoom: 1.75),
            selectedNodeIDs: [source.id]
        )

        let decoded = try CompositionCodec.decode(CompositionCodec.encode(original))

        XCTAssertEqual(decoded, original)
    }

    func testLegacyVersionZeroMigratesToCurrentVersion() throws {
        let data = Data(#"{"version":0,"title":"Legacy Stage","nodes":[],"connections":[]}"#.utf8)

        let migrated = try CompositionCodec.decode(data)

        XCTAssertEqual(migrated.version, CompositionFile.currentVersion)
        XCTAssertEqual(migrated.metadata.title, "Legacy Stage")
        XCTAssertEqual(migrated.graph, .empty)
    }

    func testNewerVersionIsRejected() throws {
        let data = Data(
            #"{"format":"com.steolepanda.metaliquartz.composition","version":99}"#.utf8
        )

        XCTAssertThrowsError(try CompositionCodec.decode(data)) { error in
            XCTAssertEqual(error as? CompositionCodingError, .unsupportedVersion(99))
        }
    }

    func testDocumentPackageContainsCanonicalDirectoriesAndRoundTrips() throws {
        let original = CompositionDocument(
            assets: ["image.png": Data([1, 2, 3])],
            shaders: ["effect.metal": Data("shader".utf8)],
            thumbnail: Data([4, 5, 6])
        )

        let wrapper = try original.makePackageWrapper()
        let children = try XCTUnwrap(wrapper.fileWrappers)

        XCTAssertNotNil(children["composition.json"])
        XCTAssertNotNil(children["Assets"])
        XCTAssertNotNil(children["Shaders"])
        XCTAssertNotNil(children["Thumbnail.png"])
        let decoded = try CompositionDocument(packageWrapper: wrapper)
        XCTAssertEqual(decoded.composition, original.composition)
        XCTAssertEqual(decoded.assets, original.assets)
        XCTAssertEqual(decoded.shaders, original.shaders)
        XCTAssertEqual(decoded.thumbnail, original.thumbnail)
    }

    func testValidatorRejectsMultipleConnectionsToOneInput() {
        let outputA = port(direction: .output, type: .number)
        let outputB = port(direction: .output, type: .number)
        let input = port(direction: .input, type: .number)
        let sourceA = node(name: "A", ports: [outputA])
        let sourceB = node(name: "B", ports: [outputB])
        let destination = node(name: "Destination", ports: [input])
        let graph = GraphRecord(
            nodes: [sourceA, sourceB, destination],
            connections: [
                connection(from: sourceA, port: outputA, to: destination, port: input),
                connection(from: sourceB, port: outputB, to: destination, port: input),
            ]
        )

        XCTAssertTrue(GraphValidator.validate(graph).contains(.inputAlreadyConnected(input.id)))
    }

    func testValidatorRejectsTypeMismatchAndOrdinaryCycle() {
        let firstInput = port(direction: .input, type: .number)
        let firstOutput = port(direction: .output, type: .number)
        let secondInput = port(direction: .input, type: .number)
        let secondOutput = port(direction: .output, type: .number)
        let imageInput = port(direction: .input, type: .image)
        let first = node(name: "First", ports: [firstInput, firstOutput, imageInput])
        let second = node(name: "Second", ports: [secondInput, secondOutput])
        let graph = GraphRecord(
            nodes: [first, second],
            connections: [
                connection(from: first, port: firstOutput, to: second, port: secondInput),
                connection(from: second, port: secondOutput, to: first, port: firstInput),
                connection(from: second, port: secondOutput, to: first, port: imageInput),
            ]
        )
        let issues = GraphValidator.validate(graph)

        XCTAssertTrue(issues.contains(.cycleDetected))
        XCTAssertTrue(issues.contains(.typeMismatch(output: .number, input: .image)))
    }

    func testFeedbackOutputFormsAValidFrameBoundary() {
        let feedbackInput = port(direction: .input, type: .image)
        let feedbackOutput = port(direction: .output, type: .image)
        let effectInput = port(direction: .input, type: .image)
        let effectOutput = port(direction: .output, type: .image)
        let feedback = NodeRecord(
            patchType: "com.steolepanda.metaliquartz.feedback",
            name: "Feedback",
            ports: [feedbackInput, feedbackOutput]
        )
        let effect = node(name: "Effect", ports: [effectInput, effectOutput])
        let graph = GraphRecord(
            nodes: [feedback, effect],
            connections: [
                connection(from: feedback, port: feedbackOutput, to: effect, port: effectInput),
                connection(from: effect, port: effectOutput, to: feedback, port: feedbackInput),
            ]
        )

        XCTAssertFalse(GraphValidator.validate(graph).contains(.cycleDetected))
    }

    private func port(direction: PortDirection, type: PortDataType) -> PortRecord {
        PortRecord(
            id: PortID(), key: UUID().uuidString, name: "Port", direction: direction, dataType: type
        )
    }

    private func node(name: String, ports: [PortRecord]) -> NodeRecord {
        NodeRecord(patchType: "test.\(name.lowercased())", name: name, ports: ports)
    }

    private func connection(
        from outputNode: NodeRecord,
        port outputPort: PortRecord,
        to inputNode: NodeRecord,
        port inputPort: PortRecord
    ) -> ConnectionRecord {
        ConnectionRecord(
            outputNodeID: outputNode.id,
            outputPortID: outputPort.id,
            inputNodeID: inputNode.id,
            inputPortID: inputPort.id
        )
    }
}
