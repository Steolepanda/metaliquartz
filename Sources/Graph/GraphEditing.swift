import Foundation

enum GraphCommand: Sendable {
    case replaceGraph(GraphRecord)
    case addNodes([NodeRecord])
    case removeNodes(Set<NodeID>)
    case moveNodes([NodeID: CanvasPoint])
    case renameNode(NodeID, String)
    case setParameter(nodeID: NodeID, key: String, value: ParameterValue)
    case addConnection(ConnectionRecord)
    case removeConnections(Set<ConnectionID>)

    @discardableResult
    func apply(to graph: inout GraphRecord) -> GraphCommand {
        let inverse = GraphCommand.replaceGraph(graph)
        switch self {
        case .replaceGraph(let replacement):
            graph = replacement
        case .addNodes(let nodes):
            let existingIDs = Set(graph.nodes.map(\.id))
            let additions = nodes.filter { !existingIDs.contains($0.id) }
            graph.nodes.append(contentsOf: additions)
            for node in additions
            where PatchRegistry.definition(for: node.patchType)?.isContainer == true
                && !graph.childGraphs.contains(where: { $0.ownerNodeID == node.id })
            {
                graph.childGraphs.append(
                    ChildGraphRecord(
                        ownerNodeID: node.id,
                        graph: .empty,
                        editorState: .default
                    )
                )
            }
        case .removeNodes(let nodeIDs):
            graph.nodes.removeAll { nodeIDs.contains($0.id) }
            graph.childGraphs.removeAll { nodeIDs.contains($0.ownerNodeID) }
            graph.connections.removeAll {
                nodeIDs.contains($0.outputNodeID) || nodeIDs.contains($0.inputNodeID)
            }
        case .moveNodes(let positions):
            for index in graph.nodes.indices {
                if let position = positions[graph.nodes[index].id] {
                    graph.nodes[index].position = position
                }
            }
        case .renameNode(let nodeID, let name):
            if let index = graph.nodes.firstIndex(where: { $0.id == nodeID }) {
                graph.nodes[index].name = name
            }
        case .setParameter(let nodeID, let key, let value):
            if let index = graph.nodes.firstIndex(where: { $0.id == nodeID }) {
                graph.nodes[index].parameters[key] = value
            }
        case .addConnection(let connection):
            graph.connections.removeAll {
                $0.id == connection.id || $0.inputPortID == connection.inputPortID
            }
            graph.connections.append(connection)
        case .removeConnections(let connectionIDs):
            graph.connections.removeAll { connectionIDs.contains($0.id) }
        }
        return inverse
    }
}

struct GraphClipboardPayload: Codable, Equatable, Sendable {
    var nodes: [NodeRecord]
    var connections: [ConnectionRecord]
    var childGraphs: [ChildGraphRecord]

    init(
        nodes: [NodeRecord],
        connections: [ConnectionRecord],
        childGraphs: [ChildGraphRecord] = []
    ) {
        self.nodes = nodes
        self.connections = connections
        self.childGraphs = childGraphs
    }

    private enum CodingKeys: String, CodingKey {
        case nodes
        case connections
        case childGraphs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try container.decode([NodeRecord].self, forKey: .nodes)
        connections = try container.decode([ConnectionRecord].self, forKey: .connections)
        childGraphs =
            try container.decodeIfPresent(
                [ChildGraphRecord].self, forKey: .childGraphs
            ) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(nodes, forKey: .nodes)
        try container.encode(connections, forKey: .connections)
        try container.encode(childGraphs, forKey: .childGraphs)
    }

    static func selection(from graph: GraphRecord, nodeIDs: Set<NodeID>) -> GraphClipboardPayload {
        GraphClipboardPayload(
            nodes: graph.nodes.filter { nodeIDs.contains($0.id) },
            connections: graph.connections.filter {
                nodeIDs.contains($0.outputNodeID) && nodeIDs.contains($0.inputNodeID)
            },
            childGraphs: graph.childGraphs.filter { nodeIDs.contains($0.ownerNodeID) }
        )
    }

    func duplicated(offset: CanvasPoint = CanvasPoint(x: 32, y: 32)) -> GraphClipboardPayload {
        let duplicate = GraphRecord(
            nodes: nodes,
            connections: connections,
            childGraphs: childGraphs
        ).reidentified(offset: offset)
        return GraphClipboardPayload(
            nodes: duplicate.nodes,
            connections: duplicate.connections,
            childGraphs: duplicate.childGraphs
        )
    }
}

extension GraphRecord {
    func reidentified(
        offset: CanvasPoint = .zero
    ) -> GraphRecord {
        var nodeIDs: [NodeID: NodeID] = [:]
        var portIDs: [PortID: PortID] = [:]
        let copiedNodes = nodes.map { node -> NodeRecord in
            let newNodeID = NodeID()
            nodeIDs[node.id] = newNodeID
            var copy = node
            copy.id = newNodeID
            copy.position.x += offset.x
            copy.position.y += offset.y
            copy.ports = node.ports.map { port in
                var copiedPort = port
                let newPortID = PortID()
                portIDs[port.id] = newPortID
                copiedPort.id = newPortID
                return copiedPort
            }
            return copy
        }
        let copiedConnections = connections.compactMap { connection -> ConnectionRecord? in
            guard
                let outputNodeID = nodeIDs[connection.outputNodeID],
                let outputPortID = portIDs[connection.outputPortID],
                let inputNodeID = nodeIDs[connection.inputNodeID],
                let inputPortID = portIDs[connection.inputPortID]
            else {
                return nil
            }
            return ConnectionRecord(
                outputNodeID: outputNodeID,
                outputPortID: outputPortID,
                inputNodeID: inputNodeID,
                inputPortID: inputPortID
            )
        }
        let copiedChildren = childGraphs.compactMap { child -> ChildGraphRecord? in
            guard let ownerNodeID = nodeIDs[child.ownerNodeID] else { return nil }
            return ChildGraphRecord(
                ownerNodeID: ownerNodeID,
                graph: child.graph.reidentified(),
                editorState: EditorStateRecord(
                    viewport: child.editorState.viewport,
                    selectedNodeIDs: []
                )
            )
        }
        return GraphRecord(
            nodes: copiedNodes,
            connections: copiedConnections,
            childGraphs: copiedChildren
        )
    }
}
