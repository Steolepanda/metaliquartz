import Foundation

struct MacroID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    var description: String { rawValue.uuidString }
}

struct MacroPortRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var key: String
    var name: String
    var direction: PortDirection
    var dataType: PortDataType
    var internalNodeID: NodeID
    var internalPortID: PortID
}

struct MacroDefinitionRecord: Identifiable, Codable, Hashable, Sendable {
    var id: MacroID
    var name: String
    var graph: GraphRecord
    var editorState: EditorStateRecord
    var ports: [MacroPortRecord]
}

enum ContainerGraphRoot: Hashable, Sendable {
    case root
    case macro(MacroID)
}

enum GraphLocation: Hashable, Sendable {
    case root
    case macro(MacroID)
    case container(root: ContainerGraphRoot, path: [NodeID])
}

extension NodeRecord {
    static let macroPatchType = "com.steolepanda.metaliquartz.macro"

    var macroID: MacroID? {
        guard patchType == Self.macroPatchType,
            case .string(let rawID) = configuration["macroID"],
            let id = UUID(uuidString: rawID)
        else { return nil }
        return MacroID(id)
    }

    static func macroInstance(
        definition: MacroDefinitionRecord,
        position: CanvasPoint
    ) -> NodeRecord {
        NodeRecord(
            patchType: macroPatchType,
            name: definition.name,
            position: position,
            ports: definition.ports.map { boundary in
                PortRecord(
                    id: PortID(),
                    key: boundary.key,
                    name: boundary.name,
                    direction: boundary.direction,
                    dataType: boundary.dataType
                )
            },
            configuration: ["macroID": .string(definition.id.rawValue.uuidString)]
        )
    }
}

extension CompositionFile {
    var macroDefinitions: [MacroDefinitionRecord] {
        get { macros ?? [] }
        set { macros = newValue }
    }

    func macroDefinition(id: MacroID) -> MacroDefinitionRecord? {
        macroDefinitions.first { $0.id == id }
    }

    func node(id: NodeID) -> NodeRecord? {
        if let node = graph.recursiveNode(id: id) { return node }
        for definition in macroDefinitions {
            if let node = definition.graph.recursiveNode(id: id) {
                return node
            }
        }
        return nil
    }

    func graph(at location: GraphLocation) -> GraphRecord? {
        switch location {
        case .root:
            graph
        case .macro(let id):
            macroDefinition(id: id)?.graph
        case .container(let root, let path):
            baseGraph(for: root)?.childGraph(path: path)?.graph
        }
    }

    func editorState(at location: GraphLocation) -> EditorStateRecord? {
        switch location {
        case .root:
            editorState
        case .macro(let id):
            macroDefinition(id: id)?.editorState
        case .container(let root, let path):
            baseGraph(for: root)?.childGraph(path: path)?.editorState
        }
    }

    mutating func setGraph(_ graph: GraphRecord, at location: GraphLocation) {
        switch location {
        case .root:
            self.graph = graph
        case .macro(let id):
            guard var definitions = macros,
                let index = definitions.firstIndex(where: { $0.id == id })
            else { return }
            definitions[index].graph = graph
            macros = definitions
        case .container(let root, let path):
            mutateBaseGraph(for: root) { base in
                base.setChildGraph(graph, path: path)
            }
        }
    }

    mutating func setEditorState(
        _ editorState: EditorStateRecord,
        at location: GraphLocation
    ) {
        switch location {
        case .root:
            self.editorState = editorState
        case .macro(let id):
            guard var definitions = macros,
                let index = definitions.firstIndex(where: { $0.id == id })
            else { return }
            definitions[index].editorState = editorState
            macros = definitions
        case .container(let root, let path):
            mutateBaseGraph(for: root) { base in
                base.setChildEditorState(editorState, path: path)
            }
        }
    }

    mutating func updateNode(
        id: NodeID,
        _ update: (inout NodeRecord) -> Void
    ) -> Bool {
        if graph.recursivelyUpdateNode(id: id, update) {
            return true
        }
        guard var definitions = macros else { return false }
        for macroIndex in definitions.indices {
            if definitions[macroIndex].graph.recursivelyUpdateNode(id: id, update) {
                macros = definitions
                return true
            }
        }
        return false
    }

    private func baseGraph(for root: ContainerGraphRoot) -> GraphRecord? {
        switch root {
        case .root: graph
        case .macro(let id): macroDefinition(id: id)?.graph
        }
    }

    private mutating func mutateBaseGraph(
        for root: ContainerGraphRoot,
        _ update: (inout GraphRecord) -> Void
    ) {
        switch root {
        case .root:
            update(&graph)
        case .macro(let id):
            guard var definitions = macros,
                let index = definitions.firstIndex(where: { $0.id == id })
            else { return }
            update(&definitions[index].graph)
            macros = definitions
        }
    }
}

extension GraphRecord {
    var recursiveNodes: [NodeRecord] {
        nodes + childGraphs.flatMap { $0.graph.recursiveNodes }
    }

    func childGraph(path: [NodeID]) -> ChildGraphRecord? {
        guard let owner = path.first,
            let child = childGraphs.first(where: { $0.ownerNodeID == owner })
        else { return nil }
        if path.count == 1 { return child }
        return child.graph.childGraph(path: Array(path.dropFirst()))
    }

    fileprivate func recursiveNode(id: NodeID) -> NodeRecord? {
        if let node = nodes.first(where: { $0.id == id }) { return node }
        for child in childGraphs {
            if let node = child.graph.recursiveNode(id: id) { return node }
        }
        return nil
    }

    fileprivate mutating func recursivelyUpdateNode(
        id: NodeID,
        _ update: (inout NodeRecord) -> Void
    ) -> Bool {
        if let index = nodes.firstIndex(where: { $0.id == id }) {
            update(&nodes[index])
            return true
        }
        for index in childGraphs.indices {
            if childGraphs[index].graph.recursivelyUpdateNode(id: id, update) {
                return true
            }
        }
        return false
    }

    fileprivate mutating func setChildGraph(_ graph: GraphRecord, path: [NodeID]) {
        guard let owner = path.first,
            let index = childGraphs.firstIndex(where: { $0.ownerNodeID == owner })
        else { return }
        if path.count == 1 {
            childGraphs[index].graph = graph
        } else {
            childGraphs[index].graph.setChildGraph(graph, path: Array(path.dropFirst()))
        }
    }

    fileprivate mutating func setChildEditorState(
        _ editorState: EditorStateRecord,
        path: [NodeID]
    ) {
        guard let owner = path.first,
            let index = childGraphs.firstIndex(where: { $0.ownerNodeID == owner })
        else { return }
        if path.count == 1 {
            childGraphs[index].editorState = editorState
        } else {
            childGraphs[index].graph.setChildEditorState(
                editorState, path: Array(path.dropFirst())
            )
        }
    }
}

enum MacroValidationIssue: LocalizedError, Equatable, Sendable {
    case duplicateMacro(MacroID)
    case malformedInstance(NodeID)
    case missingReference(nodeID: NodeID, macroID: MacroID)
    case invalidInstancePort(nodeID: NodeID, portID: PortID)
    case invalidBoundary(macroID: MacroID, boundaryID: UUID)
    case invalidGraph(macroID: MacroID, issues: [GraphValidationIssue])
    case recursiveReference([MacroID])

    var errorDescription: String? {
        switch self {
        case .duplicateMacro(let id):
            "Duplicate macro ID: \(id)."
        case .malformedInstance(let nodeID):
            "Macro node \(nodeID) has no valid macro identifier."
        case .missingReference(let nodeID, let macroID):
            "Macro node \(nodeID) references missing macro \(macroID)."
        case .invalidInstancePort(let nodeID, let portID):
            "Macro node \(nodeID) has a stale or incompatible port \(portID)."
        case .invalidBoundary(let macroID, let boundaryID):
            "Macro \(macroID) has an invalid published boundary \(boundaryID)."
        case .invalidGraph(let macroID, let issues):
            "Macro \(macroID) is invalid: \(issues.compactMap(\.errorDescription).joined(separator: " "))"
        case .recursiveReference(let path):
            "Recursive macro reference: \(path.map(\.description).joined(separator: " → "))."
        }
    }
}

enum MacroValidator {
    static func validate(
        rootGraph: GraphRecord,
        macros: [MacroDefinitionRecord]
    ) -> [MacroValidationIssue] {
        var issues: [MacroValidationIssue] = []
        var definitionsByID: [MacroID: MacroDefinitionRecord] = [:]
        for definition in macros {
            if definitionsByID.updateValue(definition, forKey: definition.id) != nil {
                issues.append(.duplicateMacro(definition.id))
            }
        }

        validateInstances(
            in: rootGraph,
            definitionsByID: definitionsByID,
            issues: &issues
        )
        for definition in macros {
            let graphIssues = GraphValidator.validate(definition.graph)
            if !graphIssues.isEmpty {
                issues.append(.invalidGraph(macroID: definition.id, issues: graphIssues))
            }
            validateBoundaries(definition, issues: &issues)
            validateInstances(
                in: definition.graph,
                definitionsByID: definitionsByID,
                issues: &issues
            )
        }
        issues.append(contentsOf: recursiveReferenceIssues(macros: macros))
        return issues
    }

    private static func validateInstances(
        in graph: GraphRecord,
        definitionsByID: [MacroID: MacroDefinitionRecord],
        issues: inout [MacroValidationIssue]
    ) {
        for node in graph.nodes where node.patchType == NodeRecord.macroPatchType {
            guard let macroID = node.macroID else {
                issues.append(.malformedInstance(node.id))
                continue
            }
            guard let definition = definitionsByID[macroID] else {
                issues.append(.missingReference(nodeID: node.id, macroID: macroID))
                continue
            }
            var boundariesByKey: [String: MacroPortRecord] = [:]
            for boundary in definition.ports where boundariesByKey[boundary.key] == nil {
                boundariesByKey[boundary.key] = boundary
            }
            var seenInstanceKeys = Set<String>()
            for port in node.ports {
                guard let boundary = boundariesByKey[port.key],
                    seenInstanceKeys.insert(port.key).inserted,
                    boundary.direction == port.direction,
                    boundary.dataType == port.dataType
                else {
                    issues.append(.invalidInstancePort(nodeID: node.id, portID: port.id))
                    continue
                }
            }
            let instanceKeys = Set(node.ports.map(\.key))
            for boundary in definition.ports where !instanceKeys.contains(boundary.key) {
                issues.append(
                    .invalidInstancePort(nodeID: node.id, portID: PortID(boundary.id))
                )
            }
        }
        for child in graph.childGraphs {
            validateInstances(
                in: child.graph,
                definitionsByID: definitionsByID,
                issues: &issues
            )
        }
    }

    private static func validateBoundaries(
        _ definition: MacroDefinitionRecord,
        issues: inout [MacroValidationIssue]
    ) {
        var keys = Set<String>()
        for boundary in definition.ports {
            guard keys.insert(boundary.key).inserted,
                let node = definition.graph.nodes.first(where: {
                    $0.id == boundary.internalNodeID
                }),
                let port = node.ports.first(where: { $0.id == boundary.internalPortID }),
                port.direction == boundary.direction,
                port.dataType == boundary.dataType
            else {
                issues.append(
                    .invalidBoundary(macroID: definition.id, boundaryID: boundary.id)
                )
                continue
            }
        }
    }

    private static func recursiveReferenceIssues(
        macros: [MacroDefinitionRecord]
    ) -> [MacroValidationIssue] {
        var definitionsByID: [MacroID: MacroDefinitionRecord] = [:]
        for definition in macros where definitionsByID[definition.id] == nil {
            definitionsByID[definition.id] = definition
        }
        var visited = Set<MacroID>()
        var active: [MacroID] = []
        var reported = Set<MacroID>()
        var issues: [MacroValidationIssue] = []

        func visit(_ id: MacroID) {
            if let cycleIndex = active.firstIndex(of: id) {
                let path = Array(active[cycleIndex...]) + [id]
                if let first = path.first, reported.insert(first).inserted {
                    issues.append(.recursiveReference(path))
                }
                return
            }
            guard visited.insert(id).inserted,
                let definition = definitionsByID[id]
            else { return }
            active.append(id)
            for reference in definition.graph.recursiveNodes.compactMap(\.macroID) {
                visit(reference)
            }
            active.removeLast()
        }

        for id in macros.map(\.id) {
            visit(id)
        }
        return issues
    }
}

enum MacroExpansionError: LocalizedError, Equatable {
    case invalidLibrary([MacroValidationIssue])

    var errorDescription: String? {
        switch self {
        case .invalidLibrary(let issues):
            issues.compactMap(\.errorDescription).joined(separator: "\n")
        }
    }
}

enum MacroExpander {
    static func expand(
        graph: GraphRecord,
        macros: [MacroDefinitionRecord]
    ) throws -> GraphRecord {
        let issues = MacroValidator.validate(rootGraph: graph, macros: macros)
        guard issues.isEmpty else { throw MacroExpansionError.invalidLibrary(issues) }
        let definitions = Dictionary(uniqueKeysWithValues: macros.map { ($0.id, $0) })
        var expanded = graph
        for index in expanded.childGraphs.indices {
            expanded.childGraphs[index].graph = try expand(
                graph: expanded.childGraphs[index].graph,
                macros: macros
            )
        }
        while let instanceIndex = expanded.nodes.firstIndex(where: { $0.macroID != nil }) {
            let instance = expanded.nodes[instanceIndex]
            guard let macroID = instance.macroID, let definition = definitions[macroID] else {
                break
            }
            expanded = inline(instance: instance, definition: definition, in: expanded)
        }
        return expanded
    }

    private static func inline(
        instance: NodeRecord,
        definition: MacroDefinitionRecord,
        in graph: GraphRecord
    ) -> GraphRecord {
        var nodeIDs: [NodeID: NodeID] = [:]
        var portIDs: [PortID: PortID] = [:]
        let clonedNodes = definition.graph.nodes.map { node -> NodeRecord in
            var clone = node
            clone.id = NodeID()
            nodeIDs[node.id] = clone.id
            clone.position.x += instance.position.x
            clone.position.y += instance.position.y
            clone.ports = node.ports.map { port in
                var clonedPort = port
                clonedPort.id = PortID()
                portIDs[port.id] = clonedPort.id
                return clonedPort
            }
            return clone
        }
        let clonedConnections = definition.graph.connections.compactMap {
            connection -> ConnectionRecord? in
            guard let outputNodeID = nodeIDs[connection.outputNodeID],
                let outputPortID = portIDs[connection.outputPortID],
                let inputNodeID = nodeIDs[connection.inputNodeID],
                let inputPortID = portIDs[connection.inputPortID]
            else { return nil }
            return ConnectionRecord(
                outputNodeID: outputNodeID,
                outputPortID: outputPortID,
                inputNodeID: inputNodeID,
                inputPortID: inputPortID
            )
        }
        let clonedChildGraphs = definition.graph.childGraphs.compactMap {
            child -> ChildGraphRecord? in
            guard let ownerNodeID = nodeIDs[child.ownerNodeID] else { return nil }
            return ChildGraphRecord(
                ownerNodeID: ownerNodeID,
                graph: child.graph.reidentified(),
                editorState: .default
            )
        }
        let boundaries = Dictionary(uniqueKeysWithValues: definition.ports.map { ($0.key, $0) })
        let instancePorts = Dictionary(uniqueKeysWithValues: instance.ports.map { ($0.id, $0) })
        var connections: [ConnectionRecord] = []
        for var connection in graph.connections {
            if connection.inputNodeID == instance.id,
                let port = instancePorts[connection.inputPortID],
                let boundary = boundaries[port.key],
                let nodeID = nodeIDs[boundary.internalNodeID],
                let portID = portIDs[boundary.internalPortID]
            {
                connection.inputNodeID = nodeID
                connection.inputPortID = portID
                connections.append(connection)
            } else if connection.outputNodeID == instance.id,
                let port = instancePorts[connection.outputPortID],
                let boundary = boundaries[port.key],
                let nodeID = nodeIDs[boundary.internalNodeID],
                let portID = portIDs[boundary.internalPortID]
            {
                connection.outputNodeID = nodeID
                connection.outputPortID = portID
                connections.append(connection)
            } else if connection.inputNodeID != instance.id
                && connection.outputNodeID != instance.id
            {
                connections.append(connection)
            }
        }
        return GraphRecord(
            nodes: graph.nodes.filter { $0.id != instance.id } + clonedNodes,
            connections: connections + clonedConnections,
            childGraphs: graph.childGraphs + clonedChildGraphs
        )
    }
}

struct MacroConversionResult: Sendable {
    var composition: CompositionFile
    var macroID: MacroID
    var instanceNodeID: NodeID
}

enum MacroConversionError: LocalizedError, Equatable {
    case emptySelection
    case invalidSelection

    var errorDescription: String? {
        switch self {
        case .emptySelection: "Select at least one patch to create a macro."
        case .invalidSelection: "The selected patches cannot form a valid macro."
        }
    }
}

enum MacroConverter {
    private struct Endpoint: Hashable {
        var nodeID: NodeID
        var portID: PortID
    }

    static func convert(
        selection: Set<NodeID>,
        in composition: CompositionFile,
        location: GraphLocation = .root,
        name: String = "Macro"
    ) throws -> MacroConversionResult {
        guard !selection.isEmpty else { throw MacroConversionError.emptySelection }
        guard let sourceGraph = composition.graph(at: location) else {
            throw MacroConversionError.invalidSelection
        }
        let selectedNodes = sourceGraph.nodes.filter { selection.contains($0.id) }
        guard selectedNodes.count == selection.count else {
            throw MacroConversionError.invalidSelection
        }

        let incoming = sourceGraph.connections.filter {
            !selection.contains($0.outputNodeID) && selection.contains($0.inputNodeID)
        }
        let outgoing = sourceGraph.connections.filter {
            selection.contains($0.outputNodeID) && !selection.contains($0.inputNodeID)
        }
        let internalConnections = sourceGraph.connections.filter {
            selection.contains($0.outputNodeID) && selection.contains($0.inputNodeID)
        }
        let externalConnections = sourceGraph.connections.filter {
            !selection.contains($0.outputNodeID) && !selection.contains($0.inputNodeID)
        }

        let macroID = MacroID()
        let instanceNodeID = NodeID()
        var boundaries: [MacroPortRecord] = []
        var instancePorts: [PortRecord] = []
        var rewiredConnections = externalConnections

        for (index, connection) in incoming.enumerated() {
            guard let node = selectedNodes.first(where: { $0.id == connection.inputNodeID }),
                let port = node.ports.first(where: { $0.id == connection.inputPortID })
            else { throw MacroConversionError.invalidSelection }
            let key = "input-\(index)"
            let instancePort = PortRecord(
                id: PortID(),
                key: key,
                name: "\(node.name) · \(port.name)",
                direction: .input,
                dataType: port.dataType
            )
            instancePorts.append(instancePort)
            boundaries.append(
                MacroPortRecord(
                    id: UUID(),
                    key: key,
                    name: instancePort.name,
                    direction: .input,
                    dataType: port.dataType,
                    internalNodeID: node.id,
                    internalPortID: port.id
                )
            )
            var rewired = connection
            rewired.inputNodeID = instanceNodeID
            rewired.inputPortID = instancePort.id
            rewiredConnections.append(rewired)
        }

        var outputBoundaries: [Endpoint: (MacroPortRecord, PortRecord)] = [:]
        for connection in outgoing {
            guard let node = selectedNodes.first(where: { $0.id == connection.outputNodeID }),
                let port = node.ports.first(where: { $0.id == connection.outputPortID })
            else { throw MacroConversionError.invalidSelection }
            let endpoint = Endpoint(nodeID: node.id, portID: port.id)
            let pair: (MacroPortRecord, PortRecord)
            if let existing = outputBoundaries[endpoint] {
                pair = existing
            } else {
                let key = "output-\(outputBoundaries.count)"
                let instancePort = PortRecord(
                    id: PortID(),
                    key: key,
                    name: "\(node.name) · \(port.name)",
                    direction: .output,
                    dataType: port.dataType
                )
                let boundary = MacroPortRecord(
                    id: UUID(),
                    key: key,
                    name: instancePort.name,
                    direction: .output,
                    dataType: port.dataType,
                    internalNodeID: node.id,
                    internalPortID: port.id
                )
                pair = (boundary, instancePort)
                outputBoundaries[endpoint] = pair
                boundaries.append(boundary)
                instancePorts.append(instancePort)
            }
            var rewired = connection
            rewired.outputNodeID = instanceNodeID
            rewired.outputPortID = pair.1.id
            rewiredConnections.append(rewired)
        }

        let center = CanvasPoint(
            x: selectedNodes.map(\.position.x).reduce(0, +) / Double(selectedNodes.count),
            y: selectedNodes.map(\.position.y).reduce(0, +) / Double(selectedNodes.count)
        )
        let definition = MacroDefinitionRecord(
            id: macroID,
            name: name,
            graph: GraphRecord(
                nodes: selectedNodes,
                connections: internalConnections,
                childGraphs: sourceGraph.childGraphs.filter {
                    selection.contains($0.ownerNodeID)
                }
            ),
            editorState: EditorStateRecord(
                viewport: composition.editorState(at: location)?.viewport ?? .default,
                selectedNodeIDs: selectedNodes.map(\.id)
            ),
            ports: boundaries
        )
        var instance = NodeRecord.macroInstance(definition: definition, position: center)
        instance.id = instanceNodeID
        instance.ports = instancePorts
        let replacement = GraphRecord(
            nodes: sourceGraph.nodes.filter { !selection.contains($0.id) } + [instance],
            connections: rewiredConnections,
            childGraphs: sourceGraph.childGraphs.filter {
                !selection.contains($0.ownerNodeID)
            }
        )
        var result = composition
        result.setGraph(replacement, at: location)
        result.setEditorState(
            EditorStateRecord(
                viewport: composition.editorState(at: location)?.viewport ?? .default,
                selectedNodeIDs: [instance.id]
            ),
            at: location
        )
        result.macroDefinitions.append(definition)
        guard
            MacroValidator.validate(
                rootGraph: result.graph,
                macros: result.macroDefinitions
            ).isEmpty
        else {
            throw MacroConversionError.invalidSelection
        }
        return MacroConversionResult(
            composition: result,
            macroID: macroID,
            instanceNodeID: instance.id
        )
    }
}
