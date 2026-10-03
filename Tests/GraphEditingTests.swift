import XCTest

@testable import Metaliquartz

final class GraphEditingTests: XCTestCase {
    func testRemovingNodeAlsoRemovesAttachedConnectionsAndCanUndo() {
        let source = definition("image-file").makeNode(at: .zero)
        let destination = definition("preview-output").makeNode(
            at: CanvasPoint(x: 300, y: 0)
        )
        let connection = ConnectionRecord(
            outputNodeID: source.id,
            outputPortID: source.ports[0].id,
            inputNodeID: destination.id,
            inputPortID: destination.ports[0].id
        )
        var graph = GraphRecord(nodes: [source, destination], connections: [connection])

        let inverse = GraphCommand.removeNodes([source.id]).apply(to: &graph)
        XCTAssertEqual(graph.nodes, [destination])
        XCTAssertTrue(graph.connections.isEmpty)

        inverse.apply(to: &graph)
        XCTAssertEqual(graph, GraphRecord(nodes: [source, destination], connections: [connection]))
    }

    func testAddingConnectionReplacesExistingInputConnection() {
        let first = definition("image-file").makeNode(at: .zero)
        let second = definition("image-file").makeNode(at: .zero)
        let output = definition("preview-output").makeNode(at: .zero)
        let oldConnection = connection(from: first, to: output)
        let replacement = connection(from: second, to: output)
        var graph = GraphRecord(
            nodes: [first, second, output],
            connections: [oldConnection]
        )

        GraphCommand.addConnection(replacement).apply(to: &graph)

        XCTAssertEqual(graph.connections, [replacement])
        XCTAssertTrue(GraphValidator.validate(graph).isEmpty)
    }

    func testClipboardDuplicatesIDsAndInternalConnections() throws {
        let source = definition("image-file").makeNode(
            at: CanvasPoint(x: 10, y: 20)
        )
        let output = definition("preview-output").makeNode(
            at: CanvasPoint(x: 200, y: 20)
        )
        let edge = connection(from: source, to: output)
        let graph = GraphRecord(nodes: [source, output], connections: [edge])

        let payload = GraphClipboardPayload.selection(
            from: graph,
            nodeIDs: [source.id, output.id]
        )
        let encoded = try JSONEncoder().encode(payload)
        let duplicate = try JSONDecoder().decode(GraphClipboardPayload.self, from: encoded)
            .duplicated()

        XCTAssertEqual(duplicate.nodes.count, 2)
        XCTAssertEqual(duplicate.connections.count, 1)
        XCTAssertNotEqual(duplicate.nodes[0].id, source.id)
        XCTAssertEqual(duplicate.nodes[0].position, CanvasPoint(x: 42, y: 52))
        XCTAssertTrue(
            GraphValidator.validate(
                GraphRecord(nodes: duplicate.nodes, connections: duplicate.connections)
            ).isEmpty)
    }

    private func connection(from source: NodeRecord, to output: NodeRecord) -> ConnectionRecord {
        ConnectionRecord(
            outputNodeID: source.id,
            outputPortID: source.ports.first { $0.direction == .output }!.id,
            inputNodeID: output.id,
            inputPortID: output.ports.first { $0.direction == .input }!.id
        )
    }

    private func definition(_ suffix: String) -> PatchDefinition {
        PatchRegistry.definition(for: "\(PatchRegistry.namespace).\(suffix)")!
    }
}
