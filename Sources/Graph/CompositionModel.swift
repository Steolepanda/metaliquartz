import Foundation

struct NodeID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    var description: String { rawValue.uuidString }
}

struct PortID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    var description: String { rawValue.uuidString }
}

struct ConnectionID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    var description: String { rawValue.uuidString }
}

enum PortDataType: String, Codable, CaseIterable, Sendable {
    case number
    case boolean
    case string
    case color
    case image
    case event
}

enum PortDirection: String, Codable, Sendable {
    case input
    case output
}

struct CanvasPoint: Codable, Hashable, Sendable {
    var x: Double
    var y: Double

    static let zero = CanvasPoint(x: 0, y: 0)
}

struct CanvasViewport: Codable, Hashable, Sendable {
    var origin: CanvasPoint
    var zoom: Double

    static let `default` = CanvasViewport(origin: .zero, zoom: 1)
}

enum JSONValue: Codable, Hashable, Sendable {
    case null
    case boolean(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .boolean(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

enum ParameterValue: Codable, Hashable, Sendable {
    case number(Double)
    case boolean(Bool)
    case string(String)
    case color(red: Double, green: Double, blue: Double, alpha: Double)

    private enum CodingKeys: String, CodingKey {
        case type
        case value
        case red
        case green
        case blue
        case alpha
    }

    private enum ValueType: String, Codable {
        case number
        case boolean
        case string
        case color
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ValueType.self, forKey: .type) {
        case .number:
            self = .number(try container.decode(Double.self, forKey: .value))
        case .boolean:
            self = .boolean(try container.decode(Bool.self, forKey: .value))
        case .string:
            self = .string(try container.decode(String.self, forKey: .value))
        case .color:
            self = .color(
                red: try container.decode(Double.self, forKey: .red),
                green: try container.decode(Double.self, forKey: .green),
                blue: try container.decode(Double.self, forKey: .blue),
                alpha: try container.decode(Double.self, forKey: .alpha)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .number(let value):
            try container.encode(ValueType.number, forKey: .type)
            try container.encode(value, forKey: .value)
        case .boolean(let value):
            try container.encode(ValueType.boolean, forKey: .type)
            try container.encode(value, forKey: .value)
        case .string(let value):
            try container.encode(ValueType.string, forKey: .type)
            try container.encode(value, forKey: .value)
        case .color(let red, let green, let blue, let alpha):
            try container.encode(ValueType.color, forKey: .type)
            try container.encode(red, forKey: .red)
            try container.encode(green, forKey: .green)
            try container.encode(blue, forKey: .blue)
            try container.encode(alpha, forKey: .alpha)
        }
    }
}

struct PortRecord: Identifiable, Codable, Hashable, Sendable {
    var id: PortID
    var key: String
    var name: String
    var direction: PortDirection
    var dataType: PortDataType
}

struct NodeRecord: Identifiable, Codable, Hashable, Sendable {
    var id: NodeID
    var patchType: String
    var name: String
    var position: CanvasPoint
    var ports: [PortRecord]
    var parameters: [String: ParameterValue]
    var configuration: [String: JSONValue]
    var isDisabled: Bool
    var catalogPathID: String?

    init(
        id: NodeID = NodeID(),
        patchType: String,
        name: String,
        position: CanvasPoint = .zero,
        ports: [PortRecord] = [],
        parameters: [String: ParameterValue] = [:],
        configuration: [String: JSONValue] = [:],
        isDisabled: Bool = false,
        catalogPathID: String? = nil
    ) {
        self.id = id
        self.patchType = patchType
        self.name = name
        self.position = position
        self.ports = ports
        self.parameters = parameters
        self.configuration = configuration
        self.isDisabled = isDisabled
        self.catalogPathID = catalogPathID
    }

    var breaksFrameCycle: Bool { patchType == "com.steolepanda.metaliquartz.feedback" }
}

struct ConnectionRecord: Identifiable, Codable, Hashable, Sendable {
    var id: ConnectionID
    var outputNodeID: NodeID
    var outputPortID: PortID
    var inputNodeID: NodeID
    var inputPortID: PortID

    init(
        id: ConnectionID = ConnectionID(),
        outputNodeID: NodeID,
        outputPortID: PortID,
        inputNodeID: NodeID,
        inputPortID: PortID
    ) {
        self.id = id
        self.outputNodeID = outputNodeID
        self.outputPortID = outputPortID
        self.inputNodeID = inputNodeID
        self.inputPortID = inputPortID
    }
}

struct PublishedParameterRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var nodeID: NodeID
    var parameterKey: String
    var minimum: Double?
    var maximum: Double?
    var smoothing: Double
}

struct ControlMappingRecord: Identifiable, Codable, Hashable, Sendable {
    enum Source: Codable, Hashable, Sendable {
        case midi(deviceID: String?, channel: Int?, controller: Int)
        case midiNote(deviceID: String?, channel: Int?, note: Int)
        case midiPitchBend(deviceID: String?, channel: Int?)
        case osc(address: String)
    }

    var id: UUID
    var publishedParameterID: UUID
    var source: Source
    var minimum: Double
    var maximum: Double
}

struct PresetRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var values: [UUID: ParameterValue]
}

struct AssetReference: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var filename: String
    var originalFilename: String
    var mediaType: String
}

struct CompositionMetadata: Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var author: String?
    var createdAt: Date
    var modifiedAt: Date

    static func untitled(now: Date = Date()) -> CompositionMetadata {
        let documentTimestamp = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
        return CompositionMetadata(
            id: UUID(),
            title: "Untitled Composition",
            author: nil,
            createdAt: documentTimestamp,
            modifiedAt: documentTimestamp
        )
    }
}

struct ChildGraphRecord: Codable, Hashable, Sendable {
    var ownerNodeID: NodeID
    var graph: GraphRecord
    var editorState: EditorStateRecord
}

struct GraphRecord: Codable, Hashable, Sendable {
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

    static let empty = GraphRecord(nodes: [], connections: [])
}

struct EditorStateRecord: Codable, Hashable, Sendable {
    var viewport: CanvasViewport
    var selectedNodeIDs: [NodeID]

    static let `default` = EditorStateRecord(viewport: .default, selectedNodeIDs: [])
}

struct LiveSessionSettings: Codable, Hashable, Sendable {
    var outputDisplayID: UInt32?
    var outputResolution: String
    var oscPort: UInt16? = nil

    static let `default` = LiveSessionSettings(
        outputDisplayID: nil,
        outputResolution: "1920×1080",
        oscPort: 9_000
    )
}

struct CompositionFile: Codable, Hashable, Sendable {
    static let formatIdentifier = "com.steolepanda.metaliquartz.composition"
    static let currentVersion = 2

    var format: String
    var version: Int
    var metadata: CompositionMetadata
    var graph: GraphRecord
    var publishedParameters: [PublishedParameterRecord]
    var controlMappings: [ControlMappingRecord]
    var presets: [PresetRecord]
    var assets: [AssetReference]
    var editorState: EditorStateRecord
    var liveSession: LiveSessionSettings?
    var macros: [MacroDefinitionRecord]?

    static func empty(now: Date = Date()) -> CompositionFile {
        CompositionFile(
            format: formatIdentifier,
            version: currentVersion,
            metadata: .untitled(now: now),
            graph: .empty,
            publishedParameters: [],
            controlMappings: [],
            presets: [],
            assets: [],
            editorState: .default,
            liveSession: .default,
            macros: []
        )
    }
}

enum CompositionCodingError: LocalizedError, Equatable {
    case invalidFormat(String?)
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let identifier):
            "This package is not a Metaliquartz composition (format: \(identifier ?? "missing"))."
        case .unsupportedVersion(let version):
            "This composition uses unsupported format version \(version)."
        }
    }
}

enum CompositionCodec {
    private struct Header: Decodable {
        var format: String?
        var version: Int?
    }

    private struct LegacyCompositionV0: Decodable {
        var version: Int
        var title: String
        var nodes: [NodeRecord]
        var connections: [ConnectionRecord]
    }

    static func encode(_ composition: CompositionFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(composition)
    }

    static func decode(_ data: Data) throws -> CompositionFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let header = try decoder.decode(Header.self, from: data)
        let version = header.version ?? 0

        if version == 0 {
            let legacy = try decoder.decode(LegacyCompositionV0.self, from: data)
            var composition = CompositionFile.empty()
            composition.metadata.title = legacy.title
            composition.graph = GraphRecord(nodes: legacy.nodes, connections: legacy.connections)
            return composition
        }

        guard header.format == CompositionFile.formatIdentifier else {
            throw CompositionCodingError.invalidFormat(header.format)
        }
        guard version == 1 || version == CompositionFile.currentVersion else {
            throw CompositionCodingError.unsupportedVersion(version)
        }
        var composition = try decoder.decode(CompositionFile.self, from: data)
        composition.version = CompositionFile.currentVersion
        return composition
    }
}

enum GraphValidationIssue: LocalizedError, Equatable, Sendable {
    case duplicateNode(NodeID)
    case duplicatePort(PortID)
    case duplicateConnection(ConnectionID)
    case missingNode(NodeID)
    case missingPort(PortID)
    case invalidOutputPort(PortID)
    case invalidInputPort(PortID)
    case typeMismatch(output: PortDataType, input: PortDataType)
    case inputAlreadyConnected(PortID)
    case cycleDetected
    case duplicateChildGraph(NodeID)
    case orphanChildGraph(NodeID)
    case invalidChildGraphOwner(NodeID)
    case invalidChildGraph(owner: NodeID, issues: [GraphValidationIssue])

    var errorDescription: String? {
        switch self {
        case .duplicateNode(let id): "Duplicate node ID: \(id)."
        case .duplicatePort(let id): "Duplicate port ID: \(id)."
        case .duplicateConnection(let id): "Duplicate connection ID: \(id)."
        case .missingNode(let id): "Connection references missing node: \(id)."
        case .missingPort(let id): "Connection references missing port: \(id)."
        case .invalidOutputPort(let id): "Port \(id) is not an output."
        case .invalidInputPort(let id): "Port \(id) is not an input."
        case .typeMismatch(let output, let input):
            "Cannot connect \(output.rawValue) to \(input.rawValue)."
        case .inputAlreadyConnected(let id): "Input port \(id) already has a connection."
        case .cycleDetected: "The graph contains a cycle without a Feedback patch."
        case .duplicateChildGraph(let id): "Node \(id) owns more than one child graph."
        case .orphanChildGraph(let id): "Child graph references missing owner node \(id)."
        case .invalidChildGraphOwner(let id): "Node \(id) is not a child-graph container."
        case .invalidChildGraph(let owner, let issues):
            "Child graph owned by \(owner) is invalid: \(issues.compactMap(\.errorDescription).joined(separator: " "))"
        }
    }
}

enum GraphValidator {
    static func validate(_ graph: GraphRecord) -> [GraphValidationIssue] {
        var issues: [GraphValidationIssue] = []
        var nodesByID: [NodeID: NodeRecord] = [:]
        var portsByID: [PortID: PortRecord] = [:]
        var connectionIDs = Set<ConnectionID>()
        var connectedInputIDs = Set<PortID>()
        var childGraphOwnerIDs = Set<NodeID>()

        for node in graph.nodes {
            if nodesByID.updateValue(node, forKey: node.id) != nil {
                issues.append(.duplicateNode(node.id))
            }
            for port in node.ports {
                if portsByID.updateValue(port, forKey: port.id) != nil {
                    issues.append(.duplicatePort(port.id))
                }
            }
        }

        var validEdges: [(NodeID, NodeID)] = []
        for connection in graph.connections {
            if !connectionIDs.insert(connection.id).inserted {
                issues.append(.duplicateConnection(connection.id))
            }
            guard let outputNode = nodesByID[connection.outputNodeID] else {
                issues.append(.missingNode(connection.outputNodeID))
                continue
            }
            guard nodesByID[connection.inputNodeID] != nil else {
                issues.append(.missingNode(connection.inputNodeID))
                continue
            }
            guard let output = portsByID[connection.outputPortID] else {
                issues.append(.missingPort(connection.outputPortID))
                continue
            }
            guard let input = portsByID[connection.inputPortID] else {
                issues.append(.missingPort(connection.inputPortID))
                continue
            }
            if output.direction != .output {
                issues.append(.invalidOutputPort(output.id))
            }
            if input.direction != .input {
                issues.append(.invalidInputPort(input.id))
            }
            if output.dataType != input.dataType {
                issues.append(.typeMismatch(output: output.dataType, input: input.dataType))
            }
            if !connectedInputIDs.insert(input.id).inserted {
                issues.append(.inputAlreadyConnected(input.id))
            }
            if output.direction == .output,
                input.direction == .input,
                output.dataType == input.dataType,
                !outputNode.breaksFrameCycle
            {
                validEdges.append((connection.outputNodeID, connection.inputNodeID))
            }
        }

        if containsCycle(nodes: Array(nodesByID.keys), edges: validEdges) {
            issues.append(.cycleDetected)
        }
        for childGraph in graph.childGraphs {
            if !childGraphOwnerIDs.insert(childGraph.ownerNodeID).inserted {
                issues.append(.duplicateChildGraph(childGraph.ownerNodeID))
            }
            guard let owner = nodesByID[childGraph.ownerNodeID] else {
                issues.append(.orphanChildGraph(childGraph.ownerNodeID))
                continue
            }
            guard PatchRegistry.definition(for: owner.patchType)?.isContainer == true else {
                issues.append(.invalidChildGraphOwner(owner.id))
                continue
            }
            let childIssues = validate(childGraph.graph)
            if !childIssues.isEmpty {
                issues.append(.invalidChildGraph(owner: owner.id, issues: childIssues))
            }
        }
        for node in graph.nodes
        where PatchRegistry.definition(for: node.patchType)?.isContainer == true
            && !childGraphOwnerIDs.contains(node.id)
        {
            issues.append(.orphanChildGraph(node.id))
        }
        return issues
    }

    private static func containsCycle(nodes: [NodeID], edges: [(NodeID, NodeID)]) -> Bool {
        var indegree = Dictionary(uniqueKeysWithValues: nodes.map { ($0, 0) })
        var destinations: [NodeID: [NodeID]] = [:]
        for (source, destination) in edges {
            destinations[source, default: []].append(destination)
            indegree[destination, default: 0] += 1
        }
        var ready = indegree.compactMap { $0.value == 0 ? $0.key : nil }
        var visited = 0
        while let node = ready.popLast() {
            visited += 1
            for destination in destinations[node, default: []] {
                indegree[destination, default: 0] -= 1
                if indegree[destination] == 0 {
                    ready.append(destination)
                }
            }
        }
        return visited != nodes.count
    }
}
