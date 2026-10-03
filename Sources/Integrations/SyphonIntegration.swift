import AppKit
import Metal
import SwiftUI
@preconcurrency import Syphon

struct SyphonServerDescriptor: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var applicationName: String

    var displayName: String {
        if name.isEmpty { return applicationName.isEmpty ? "Unnamed Server" : applicationName }
        return applicationName.isEmpty ? name : "\(applicationName) · \(name)"
    }

    init?(description: [String: Any]) {
        guard let id = description[SyphonServerDescriptionUUIDKey] as? String,
            !id.isEmpty
        else { return nil }
        self.id = id
        name = description[SyphonServerDescriptionNameKey] as? String ?? ""
        applicationName =
            description[SyphonServerDescriptionAppNameKey] as? String ?? ""
    }
}

enum SyphonDirectory {
    static func availableServers() -> [SyphonServerDescriptor] {
        rawDescriptions().compactMap(SyphonServerDescriptor.init(description:))
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    static func rawDescription(
        uuid: String,
        name: String,
        applicationName: String
    ) -> [String: Any]? {
        let descriptions = rawDescriptions()
        if !uuid.isEmpty,
            let exact = descriptions.first(where: {
                ($0[SyphonServerDescriptionUUIDKey] as? String) == uuid
            })
        {
            return exact
        }
        guard !name.isEmpty || !applicationName.isEmpty else { return nil }
        return descriptions.first { description in
            let candidateName = description[SyphonServerDescriptionNameKey] as? String ?? ""
            let candidateApplication =
                description[SyphonServerDescriptionAppNameKey] as? String ?? ""
            return (name.isEmpty || candidateName == name)
                && (applicationName.isEmpty || candidateApplication == applicationName)
        }
    }

    private static func rawDescriptions() -> [[String: Any]] {
        SyphonServerDirectory.shared().servers.map { description in
            description.reduce(into: [String: Any]()) { result, entry in
                result[entry.key] = entry.value
            }
        }
    }
}

struct SyphonServerPicker: View {
    var selectedUUID: String
    var onSelect: (SyphonServerDescriptor?) -> Void

    @State private var servers: [SyphonServerDescriptor] = []

    var body: some View {
        Picker(
            "Server",
            selection: Binding(
                get: { selectedUUID },
                set: { id in
                    onSelect(servers.first { $0.id == id })
                }
            )
        ) {
            Text("No Server").tag("")
            ForEach(servers) { server in
                Text(server.displayName).tag(server.id)
            }
        }
        .task {
            while !Task.isCancelled {
                servers = SyphonDirectory.availableServers()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

final class SyphonMetalBridge {
    private struct Selection: Equatable {
        var uuid: String
        var name: String
        var applicationName: String
    }

    private final class ClientState {
        var selection: Selection
        var connectedUUID: String
        var client: SyphonMetalClient
        var latestTexture: (any MTLTexture)?

        init(selection: Selection, connectedUUID: String, client: SyphonMetalClient) {
            self.selection = selection
            self.connectedUUID = connectedUUID
            self.client = client
        }
    }

    private final class ServerState {
        var name: String
        var server: SyphonMetalServer

        init(name: String, server: SyphonMetalServer) {
            self.name = name
            self.server = server
        }
    }

    let device: any MTLDevice
    private var clients: [NodeID: ClientState] = [:]
    private var servers: [NodeID: ServerState] = [:]
    private(set) var diagnostics: [NodeID: String] = [:]

    init(device: any MTLDevice) {
        self.device = device
    }

    deinit {
        for state in clients.values { state.client.stop() }
        for state in servers.values { state.server.stop() }
    }

    func update(composition: CompositionFile) {
        let inputNodes = composition.graph.nodes.filter {
            PatchRegistry.definition(for: $0.patchType)?.executorKind == .syphonInput
        }
        let outputNodes = composition.graph.nodes.filter {
            PatchRegistry.definition(for: $0.patchType)?.executorKind == .syphonOutput
        }
        let inputIDs = Set(inputNodes.map(\.id))
        let outputIDs = Set(outputNodes.map(\.id))
        for nodeID in Set(clients.keys).subtracting(inputIDs) {
            clients.removeValue(forKey: nodeID)?.client.stop()
        }
        for nodeID in Set(servers.keys).subtracting(outputIDs) {
            servers.removeValue(forKey: nodeID)?.server.stop()
        }
        diagnostics = diagnostics.filter { inputIDs.contains($0.key) || outputIDs.contains($0.key) }

        for node in inputNodes {
            let selection = selection(for: node)
            if let state = clients[node.id], state.selection != selection {
                state.client.stop()
                clients.removeValue(forKey: node.id)
            }
        }
        for node in outputNodes {
            let name = node.parameters.stringValue("serverName", default: "Metaliquartz")
            if let state = servers[node.id], state.name != name {
                state.name = name
                state.server.name = name
            }
        }
    }

    func inputTexture(for node: NodeRecord) -> (any MTLTexture)? {
        let selection = selection(for: node)
        guard !selection.uuid.isEmpty || !selection.name.isEmpty else {
            diagnostics[node.id] = "Choose an available Syphon server."
            return nil
        }

        if let existing = clients[node.id],
            existing.selection == selection,
            existing.client.isValid
        {
            if let texture = existing.client.newFrameImage() {
                existing.latestTexture = texture
            }
            guard let texture = existing.latestTexture else {
                diagnostics[node.id] = "The Syphon server has not published a frame yet."
                return nil
            }
            diagnostics.removeValue(forKey: node.id)
            return texture
        }

        clients.removeValue(forKey: node.id)?.client.stop()
        guard
            let description = SyphonDirectory.rawDescription(
                uuid: selection.uuid,
                name: selection.name,
                applicationName: selection.applicationName
            ), let descriptor = SyphonServerDescriptor(description: description)
        else {
            diagnostics[node.id] = "The selected Syphon server is unavailable."
            return nil
        }

        let client: SyphonMetalClient? = SyphonMetalClient(
            serverDescription: description,
            device: device,
            options: nil,
            newFrameHandler: nil
        )
        guard let client, client.isValid else {
            client?.stop()
            diagnostics[node.id] = "Could not connect to the selected Syphon server."
            return nil
        }
        let state = ClientState(
            selection: selection,
            connectedUUID: descriptor.id,
            client: client
        )
        clients[node.id] = state
        guard let texture = state.client.newFrameImage() else {
            diagnostics[node.id] = "The Syphon server has not published a frame yet."
            return nil
        }
        state.latestTexture = texture
        diagnostics.removeValue(forKey: node.id)
        return texture
    }

    func publish(
        texture: any MTLTexture,
        from node: NodeRecord,
        commandBuffer: any MTLCommandBuffer
    ) {
        let name = node.parameters.stringValue("serverName", default: "Metaliquartz")
        let state: ServerState
        if let existing = servers[node.id] {
            state = existing
        } else {
            let server: SyphonMetalServer? = SyphonMetalServer(
                name: name,
                device: device,
                options: nil
            )
            guard let server else {
                diagnostics[node.id] = "Could not start the Syphon output server."
                return
            }
            state = ServerState(name: name, server: server)
            servers[node.id] = state
        }
        state.server.publishFrameTexture(
            texture,
            on: commandBuffer,
            imageRegion: NSMakeRect(0, 0, Double(texture.width), Double(texture.height)),
            flipped: false
        )
        diagnostics.removeValue(forKey: node.id)
    }

    func outputDescriptor(nodeID: NodeID) -> SyphonServerDescriptor? {
        guard let description = servers[nodeID]?.server.serverDescription else { return nil }
        let raw = description.reduce(into: [String: Any]()) { result, entry in
            result[entry.key] = entry.value
        }
        return SyphonServerDescriptor(description: raw)
    }

    private func selection(for node: NodeRecord) -> Selection {
        Selection(
            uuid: node.parameters.stringValue("serverUUID"),
            name: node.parameters.stringValue("serverName"),
            applicationName: node.parameters.stringValue("serverAppName")
        )
    }
}

extension Dictionary where Key == String, Value == ParameterValue {
    fileprivate func stringValue(_ key: String, default fallback: String = "") -> String {
        guard case .string(let value) = self[key] else { return fallback }
        return value
    }
}
