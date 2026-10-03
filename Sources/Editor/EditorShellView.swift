import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class EditorSession {
    var selectedPatchID: PatchDescriptor.ID? = QuartzComposerCatalog.entries.first(
        where: \.isAddable)?.id
    var selectedNodeID: NodeID?
    let commandExecutor = GraphCommandExecutor()
    var importErrorMessage: String?
    var transport = PlaybackTransportState()
    let diagnostics = RenderDiagnosticsModel()
    let fullscreenOutput = FullscreenOutputController()
    let liveControls = LiveControlController()
    var isShowingLiveSession = false
    var macroPath: [MacroID] = []
    var containerPath: [NodeID] = []
    var macroErrorMessage: String?
    var showsPatchParameters = true
    var isImportingImages = false
    var libraryDocked: Bool {
        didSet { LegacyPanelPreferences.setDocked(libraryDocked, panel: .library) }
    }
    var inspectorDocked: Bool {
        didSet { LegacyPanelPreferences.setDocked(inspectorDocked, panel: .inspector) }
    }
    var viewerDocked: Bool {
        didSet { LegacyPanelPreferences.setDocked(viewerDocked, panel: .viewer) }
    }
    var libraryVisible: Bool {
        didSet { LegacyPanelPreferences.setVisible(libraryVisible, panel: .library) }
    }
    var inspectorVisible: Bool {
        didSet { LegacyPanelPreferences.setVisible(inspectorVisible, panel: .inspector) }
    }
    var viewerVisible: Bool {
        didSet { LegacyPanelPreferences.setVisible(viewerVisible, panel: .viewer) }
    }

    @ObservationIgnored let legacyPanels = LegacyPanelCoordinator()
    @ObservationIgnored weak var editorWindow: NSWindow?

    init(defaults: UserDefaults = .standard) {
        if UITestLaunchConfiguration.isEnabled {
            libraryDocked = true
            inspectorDocked = true
            viewerDocked = true
            libraryVisible = true
            inspectorVisible = true
            viewerVisible = true
        } else {
            libraryDocked = LegacyPanelPreferences.isDocked(.library, defaults: defaults)
            inspectorDocked = LegacyPanelPreferences.isDocked(.inspector, defaults: defaults)
            viewerDocked = LegacyPanelPreferences.isDocked(.viewer, defaults: defaults)
            libraryVisible = LegacyPanelPreferences.isVisible(.library, defaults: defaults)
            inspectorVisible = LegacyPanelPreferences.isVisible(.inspector, defaults: defaults)
            viewerVisible = LegacyPanelPreferences.isVisible(.viewer, defaults: defaults)
        }
    }
}

private struct LegacyPanelConfiguration: Hashable {
    var interfaceStyle: InterfaceStyle
    var libraryDocked: Bool
    var inspectorDocked: Bool
    var viewerDocked: Bool
    var libraryVisible: Bool
    var inspectorVisible: Bool
    var viewerVisible: Bool
}

struct EditorShellView: View {
    @Binding var document: CompositionDocument
    @State private var session = EditorSession()
    @AppStorage(InterfaceStyle.preferenceKey) private var rawInterfaceStyle = ""
    @AppStorage(CategoryColorPreferences.revisionKey) private var categoryColorRevision = 0

    @Environment(\.undoManager) private var undoManager

    private var interfaceStyle: InterfaceStyle {
        UITestLaunchConfiguration.interfaceStyle
            ?? InterfaceStyle(rawValue: rawInterfaceStyle)
            ?? .modern
    }

    private var selectedPatchBinding: Binding<PatchDescriptor.ID?> {
        Binding(
            get: { session.selectedPatchID },
            set: { session.selectedPatchID = $0 }
        )
    }

    private var selectedNodeBinding: Binding<NodeID?> {
        Binding(
            get: { session.selectedNodeID },
            set: { session.selectedNodeID = $0 }
        )
    }

    private var selectedPatch: PatchDescriptor? {
        guard let definitionID = selectedCatalogEntry?.definitionID else { return nil }
        return PatchRegistry.definition(for: definitionID)
    }

    private var selectedCatalogEntry: PatchCatalogEntry? {
        QuartzComposerCatalog.entry(id: session.selectedPatchID)
    }

    private var selectedLibraryMacro: MacroDefinitionRecord? {
        guard let selectedPatchID = session.selectedPatchID, selectedPatchID.hasPrefix("macro:"),
            let id = UUID(uuidString: String(selectedPatchID.dropFirst("macro:".count)))
        else { return nil }
        return document.composition.macroDefinition(id: MacroID(id))
    }

    private var activeLocation: GraphLocation {
        if !session.containerPath.isEmpty {
            let root = session.macroPath.last.map(ContainerGraphRoot.macro) ?? .root
            return .container(root: root, path: session.containerPath)
        }
        return session.macroPath.last.map(GraphLocation.macro) ?? .root
    }

    private var activeGraph: GraphRecord {
        document.composition.graph(at: activeLocation) ?? .empty
    }

    private var activeEditorState: EditorStateRecord {
        document.composition.editorState(at: activeLocation) ?? .default
    }

    private var selectedNode: NodeRecord? {
        activeGraph.nodes.first { $0.id == session.selectedNodeID }
    }

    private var selectedNodeMacro: MacroDefinitionRecord? {
        guard let macroID = selectedNode?.macroID else { return nil }
        return document.composition.macroDefinition(id: macroID)
    }

    private var selectedNodeIsContainer: Bool {
        guard let selectedNode else { return false }
        return PatchDescriptor.descriptor(for: selectedNode.patchType)?.isContainer == true
    }

    private var navigationTitle: String {
        var components = [document.composition.metadata.title]
        if let macroID = session.macroPath.last,
            let macro = document.composition.macroDefinition(id: macroID)
        {
            components.append(macro.name)
        }
        components += session.containerPath.compactMap {
            document.composition.node(id: $0)?.name
        }
        return components.joined(separator: " › ")
    }

    private var editorBase: AnyView {
        AnyView(
            editorWorkspace
                .navigationTitle(navigationTitle)
                .toolbar { editorToolbar }
                .background {
                    HostingWindowReader { window in
                        session.editorWindow = window
                        syncLegacyPanels()
                    }
                }
                .focusedSceneValue(
                    \.editorCommandActions,
                    EditorCommandActions(
                        showLiveSession: { session.isShowingLiveSession = true },
                        toggleLibrary: { togglePanel(.library) },
                        toggleInspector: { togglePanel(.inspector) },
                        toggleViewer: { togglePanel(.viewer) },
                        createMacro: convertSelectionToMacro
                    )
                )
                .onReceive(
                    NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
                ) {
                    notification in
                    guard notification.object as? NSWindow === session.editorWindow else { return }
                    syncLegacyPanels()
                }
        )
    }

    private var editorLifecycle: AnyView {
        AnyView(
            editorBase
                .onAppear {
                    session.commandExecutor.bind(
                        document: $document,
                        location: activeLocation,
                        undoManager: undoManager
                    )
                    session.selectedNodeID = activeEditorState.selectedNodeIDs.last
                    if !UITestLaunchConfiguration.isEnabled {
                        session.liveControls.start(composition: document.composition)
                    }
                    syncLegacyPanels()
                }
                .onDisappear {
                    session.fullscreenOutput.dismiss()
                    session.liveControls.stop()
                    session.legacyPanels.hideAll()
                    LegacyPanelCoordinator.sharedUtilities.hideIfAttached(
                        to: session.editorWindow
                    )
                }
                .onChange(of: document.composition) { _, composition in
                    updateFullscreenOutput()
                    session.liveControls.configure(composition: composition)
                    syncLegacyPanels()
                }
                .onChange(of: session.liveControls.actionRevision) { _, _ in
                    applyLiveControlActions()
                }
                .onChange(of: document.assets) { _, _ in
                    updateFullscreenOutput()
                    syncLegacyPanels()
                }
                .onChange(of: session.transport) { _, _ in
                    updateFullscreenOutput()
                    syncLegacyPanels()
                }
                .onChange(of: session.macroPath) { _, _ in
                    session.commandExecutor.bind(
                        document: $document,
                        location: activeLocation,
                        undoManager: undoManager
                    )
                    session.selectedNodeID = activeEditorState.selectedNodeIDs.last
                    syncLegacyPanels()
                }
                .onChange(of: session.containerPath) { _, _ in
                    session.commandExecutor.bind(
                        document: $document,
                        location: activeLocation,
                        undoManager: undoManager
                    )
                    session.selectedNodeID = activeEditorState.selectedNodeIDs.last
                    syncLegacyPanels()
                }
        )
    }

    private var editorContent: some View {
        editorLifecycle
            .onChange(of: legacyPanelConfiguration) { _, _ in
                syncLegacyPanels()
            }
    }

    private var legacyPanelConfiguration: LegacyPanelConfiguration {
        LegacyPanelConfiguration(
            interfaceStyle: interfaceStyle,
            libraryDocked: session.libraryDocked,
            inspectorDocked: session.inspectorDocked,
            viewerDocked: session.viewerDocked,
            libraryVisible: session.libraryVisible,
            inspectorVisible: session.inspectorVisible,
            viewerVisible: session.viewerVisible
        )
    }

    var body: some View {
        editorContent
            .task(id: document.composition) {
                guard !UITestLaunchConfiguration.isEnabled else { return }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                do {
                    _ = try ProjectRecoveryStore.save(document)
                } catch {
                    ApplicationHealthStore.record(
                        category: "recovery",
                        message: "Autosave recovery snapshot failed",
                        error: error
                    )
                }
            }
            .sheet(isPresented: liveSessionBinding) {
                LiveSessionPanel(
                    document: $document,
                    transport: transportBinding,
                    diagnostics: session.diagnostics,
                    fullscreen: session.fullscreenOutput,
                    liveControls: session.liveControls
                )
            }
            .sheet(isPresented: firstLaunchChoiceBinding) {
                InterfaceChoiceView()
                    .interactiveDismissDisabled()
            }
            .alert(
                "Could Not Import Media",
                isPresented: Binding(
                    get: { session.importErrorMessage != nil },
                    set: { if !$0 { session.importErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(session.importErrorMessage ?? "The selected file could not be read.")
            }
            .alert(
                "Could Not Create Macro",
                isPresented: Binding(
                    get: { session.macroErrorMessage != nil },
                    set: { if !$0 { session.macroErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(session.macroErrorMessage ?? "The selected patches could not be converted.")
            }
    }

    private var editorWorkspace: AnyView {
        if interfaceStyle == .legacy {
            AnyView(legacyWorkspace)
        } else {
            AnyView(modernWorkspace)
        }
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        if interfaceStyle == .modern {
            ToolbarItemGroup(placement: .primaryAction) {
                if !session.macroPath.isEmpty || !session.containerPath.isEmpty {
                    Button(action: exitGraph) {
                        Label("Edit Parent", systemImage: "chevron.backward")
                    }
                    .help("Return to the containing composition")
                }

                if selectedNodeMacro != nil || selectedNodeIsContainer {
                    Button(action: enterSelectedGraph) {
                        Label("Enter Subgraph", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                    .help("Edit this patch’s child graph")
                }

                Button(action: convertSelectionToMacro) {
                    Label("Make Macro", systemImage: "square.stack.3d.up")
                }
                .disabled(activeEditorState.selectedNodeIDs.isEmpty)

                Button {
                    session.transport.resetToken += 1
                } label: {
                    Label("Reset", systemImage: "backward.end.fill")
                }

                Button {
                    session.transport.isPlaying.toggle()
                } label: {
                    Label(
                        session.transport.isPlaying ? "Pause" : "Play",
                        systemImage: session.transport.isPlaying ? "pause.fill" : "play.fill"
                    )
                }
                .keyboardShortcut(.space, modifiers: [])

                Button {
                    session.isShowingLiveSession = true
                } label: {
                    Label("Live Session", systemImage: "dot.radiowaves.left.and.right")
                }
            }
            ToolbarItem(placement: .status) {
                Label(
                    "\(activeGraph.nodes.count) patches · \(activeGraph.connections.count) links",
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var firstLaunchChoiceBinding: Binding<Bool> {
        Binding(
            get: {
                !UITestLaunchConfiguration.isEnabled && rawInterfaceStyle.isEmpty
            },
            set: { _ in }
        )
    }

    private var liveSessionBinding: Binding<Bool> {
        Binding(
            get: { session.isShowingLiveSession },
            set: { session.isShowingLiveSession = $0 }
        )
    }

    private var transportBinding: Binding<PlaybackTransportState> {
        Binding(
            get: { session.transport },
            set: { session.transport = $0 }
        )
    }

    private var modernWorkspace: some View {
        HSplitView {
            PatchLibraryPanel(
                selectedPatchID: selectedPatchBinding,
                macros: document.composition.macroDefinitions,
                onAdd: addSelectedLibraryItem
            )
            .frame(minWidth: 190, idealWidth: 220, maxWidth: 280)

            VSplitView {
                graphCanvas(appearance: .modern)
                    .frame(minHeight: 360)

                preview
                    .frame(minHeight: 220, idealHeight: 280)
            }
            .frame(minWidth: 560)

            inspector
                .frame(minWidth: 220, idealWidth: 250, maxWidth: 320)
        }
        .frame(minWidth: 1_000, minHeight: 680)
    }

    private var legacyWorkspace: some View {
        VStack(spacing: 0) {
            LegacyEditorToolbar(
                canEditParent: !session.macroPath.isEmpty || !session.containerPath.isEmpty,
                canEnterMacro: selectedNodeMacro != nil || selectedNodeIsContainer,
                showsParameters: session.showsPatchParameters,
                libraryVisible: session.libraryVisible,
                inspectorVisible: session.inspectorVisible,
                viewerVisible: session.viewerVisible,
                onLibrary: { togglePanel(.library) },
                onCreateMacro: convertSelectionToMacro,
                onEditParent: exitGraph,
                onEnterMacro: enterSelectedGraph,
                onParameters: { session.showsPatchParameters.toggle() },
                onInspector: { togglePanel(.inspector) },
                onViewer: { togglePanel(.viewer) }
            )

            HSplitView {
                if session.libraryVisible && session.libraryDocked {
                    dockedLibrary
                        .frame(minWidth: 210, idealWidth: 250, maxWidth: 310)
                }

                VSplitView {
                    graphCanvas(appearance: .quartzComposer4)
                        .frame(minHeight: 360)

                    if session.showsPatchParameters {
                        LegacyPatchParametersPane(
                            node: selectedNode,
                            assetReferences: document.composition.assets,
                            onParameterChange: setSelectedNodeParameter,
                            onImportAsset: importAsset
                        )
                        .frame(minHeight: 116, idealHeight: 180, maxHeight: 260)
                    }

                    if session.viewerVisible && session.viewerDocked {
                        dockedViewer
                            .frame(minHeight: 220, idealHeight: 300)
                    }
                }
                .frame(minWidth: 560)

                if session.inspectorVisible && session.inspectorDocked {
                    dockedInspector
                        .frame(minWidth: 240, idealWidth: 290, maxWidth: 350)
                }
            }
        }
        .background(Color(nsColor: NSColor(calibratedWhite: 0.13, alpha: 1)))
        .frame(minWidth: 880, minHeight: 640)
    }

    private func graphCanvas(appearance: GraphCanvasAppearance) -> some View {
        _ = categoryColorRevision
        return GraphCanvasRepresentable(
            document: $document,
            selectedNodeID: selectedNodeBinding,
            location: activeLocation,
            commandExecutor: session.commandExecutor,
            appearance: appearance,
            onOpenMacro: enterMacro,
            onOpenContainer: enterContainer,
            onImageDrop: importDroppedImages
        )
    }

    private var preview: some View {
        MetalPreviewView(
            composition: document.composition,
            assets: document.assets,
            transport: session.transport,
            diagnostics: session.diagnostics
        )
    }

    private var inspector: some View {
        InspectorPanel(
            node: selectedNode,
            descriptor: selectedPatch,
            catalogEntry: selectedCatalogEntry,
            assetReferences: document.composition.assets,
            onRename: renameSelectedNode,
            onParameterChange: setSelectedNodeParameter,
            onImportAsset: importAsset,
            publishedParameters: document.composition.publishedParameters,
            onTogglePublished: togglePublishedParameter,
            macroDefinition: selectedNodeMacro,
            onEnterMacro: enterSelectedGraph
        )
    }

    private var dockedLibrary: some View {
        LegacyDockedPanelHeader(
            title: LegacyPanelKind.library.title,
            onDetach: { setPanel(.library, docked: false) },
            content: {
                PatchLibraryPanel(
                    selectedPatchID: selectedPatchBinding,
                    macros: document.composition.macroDefinitions,
                    onAdd: addSelectedLibraryItem,
                    legacyStyle: true
                )
            }
        )
    }

    private var dockedInspector: some View {
        LegacyDockedPanelHeader(
            title: LegacyPanelKind.inspector.title,
            onDetach: { setPanel(.inspector, docked: false) },
            content: { inspector }
        )
    }

    private var dockedViewer: some View {
        LegacyDockedPanelHeader(
            title: LegacyPanelKind.viewer.title,
            onDetach: { setPanel(.viewer, docked: false) },
            content: {
                LegacyViewer(
                    transport: transportBinding,
                    content: { preview }
                )
            }
        )
    }

    private func addSelectedLibraryItem() {
        guard
            QuartzComposerCatalog.addableEntry(id: session.selectedPatchID) != nil
                || selectedLibraryMacro != nil
        else { return }
        let index = activeGraph.nodes.count
        let position = CanvasPoint(
            x: activeEditorState.viewport.origin.x + 80 + Double(index % 4) * 220,
            y: activeEditorState.viewport.origin.y + 70 + Double(index / 4) * 170
        )
        let node: NodeRecord
        let name: String
        if let selectedPatch, let selectedCatalogEntry {
            node = selectedPatch.makeNode(at: position, catalogPathID: selectedCatalogEntry.id)
            name = selectedPatch.name
        } else if let selectedLibraryMacro {
            node = NodeRecord.macroInstance(definition: selectedLibraryMacro, position: position)
            name = selectedLibraryMacro.name
        } else {
            return
        }
        session.commandExecutor.perform(.addNodes([node]), actionName: "Add \(name)")
        session.selectedNodeID = node.id
        session.commandExecutor.updateEditorState(
            EditorStateRecord(
                viewport: activeEditorState.viewport,
                selectedNodeIDs: [node.id]
            )
        )
    }

    private func convertSelectionToMacro() {
        do {
            let result = try MacroConverter.convert(
                selection: Set(activeEditorState.selectedNodeIDs),
                in: document.composition,
                location: activeLocation,
                name: "Macro \(document.composition.macroDefinitions.count + 1)"
            )
            session.commandExecutor.replaceComposition(
                result.composition,
                actionName: "Create Macro"
            )
            session.selectedNodeID = result.instanceNodeID
        } catch {
            session.macroErrorMessage = error.localizedDescription
        }
    }

    private func enterSelectedMacro() {
        guard let macroID = selectedNode?.macroID else { return }
        enterMacro(macroID)
    }

    private func enterSelectedGraph() {
        if selectedNodeMacro != nil {
            enterSelectedMacro()
        } else if let node = selectedNode, selectedNodeIsContainer {
            enterContainer(node.id)
        }
    }

    private func enterMacro(_ macroID: MacroID) {
        guard document.composition.macroDefinition(id: macroID) != nil else { return }
        session.containerPath = []
        session.macroPath.append(macroID)
    }

    private func enterContainer(_ nodeID: NodeID) {
        let candidate = session.containerPath + [nodeID]
        let root = session.macroPath.last.map(ContainerGraphRoot.macro) ?? .root
        guard document.composition.graph(at: .container(root: root, path: candidate)) != nil else {
            return
        }
        session.containerPath = candidate
    }

    private func exitGraph() {
        if !session.containerPath.isEmpty {
            session.containerPath.removeLast()
        } else if !session.macroPath.isEmpty {
            session.macroPath.removeLast()
        }
    }

    private func renameSelectedNode(_ name: String) {
        guard let selectedNodeID = session.selectedNodeID else { return }
        session.commandExecutor.perform(
            .renameNode(selectedNodeID, name),
            actionName: "Rename Patch"
        )
    }

    private func setSelectedNodeParameter(_ key: String, _ value: ParameterValue) {
        guard let selectedNodeID = session.selectedNodeID else { return }
        session.commandExecutor.perform(
            .setParameter(nodeID: selectedNodeID, key: key, value: value),
            actionName: "Change Parameter"
        )
    }

    private func togglePublishedParameter(_ node: NodeRecord, _ schema: ParameterSchema) {
        var value = document
        if let existing = value.composition.publishedParameters.first(where: {
            $0.nodeID == node.id && $0.parameterKey == schema.key
        }) {
            value.composition.publishedParameters.removeAll { $0.id == existing.id }
            value.composition.controlMappings.removeAll {
                $0.publishedParameterID == existing.id
            }
        } else {
            let range = schema.liveRange
            let published = PublishedParameterRecord(
                id: UUID(),
                name: "\(node.name) · \(schema.name)",
                nodeID: node.id,
                parameterKey: schema.key,
                minimum: range?.lowerBound,
                maximum: range?.upperBound,
                smoothing: 0
            )
            value.composition.publishedParameters.append(published)
            value.composition.controlMappings.append(
                ControlMappingRecord(
                    id: UUID(),
                    publishedParameterID: published.id,
                    source: .osc(address: OSCAddress.defaultAddress(for: published.name)),
                    minimum: published.minimum ?? 0,
                    maximum: published.maximum ?? 1
                )
            )
        }
        value.composition.metadata.modifiedAt = Date(
            timeIntervalSince1970: floor(Date().timeIntervalSince1970)
        )
        document = value
    }

    private func applyLiveControlActions() {
        let actions = session.liveControls.drainActions()
        guard !actions.isEmpty else { return }
        var value = document
        var didChange = false
        for action in actions {
            switch action {
            case .setParameter(let publishedParameterID, let parameterValue):
                guard
                    let published = value.composition.publishedParameters.first(where: {
                        $0.id == publishedParameterID
                    })
                else { continue }
                didChange =
                    value.composition.updateNode(id: published.nodeID) { node in
                        node.parameters[published.parameterKey] = parameterValue
                    } || didChange
            case .learnedMapping(let publishedParameterID, let source):
                guard
                    let published = value.composition.publishedParameters.first(where: {
                        $0.id == publishedParameterID
                    })
                else { continue }
                value.composition.controlMappings.removeAll {
                    $0.publishedParameterID == publishedParameterID && $0.source.isMIDI
                }
                value.composition.controlMappings.append(
                    ControlMappingRecord(
                        id: UUID(),
                        publishedParameterID: publishedParameterID,
                        source: source,
                        minimum: published.minimum ?? 0,
                        maximum: published.maximum ?? 1
                    )
                )
                didChange = true
            }
        }
        guard didChange else { return }
        value.composition.metadata.modifiedAt = Date(
            timeIntervalSince1970: floor(Date().timeIntervalSince1970)
        )
        document = value
    }

    private func updateFullscreenOutput() {
        let rawResolution =
            document.composition.liveSession?.outputResolution
            ?? LiveOutputResolution.fullHD.rawValue
        session.fullscreenOutput.update(
            composition: document.composition,
            assets: document.assets,
            transport: session.transport,
            resolution: LiveOutputResolution(rawValue: rawResolution) ?? .fullHD
        )
    }

    private func importAsset(_ key: String, _ mediaKind: AssetMediaKind, _ url: URL) {
        guard let selectedNodeID = session.selectedNodeID else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let data = try Data(contentsOf: url)
            let assetID = UUID()
            let storedFilename = "\(assetID.uuidString)-\(url.lastPathComponent)"
            var value = document
            value.assets[storedFilename] = data
            value.composition.assets.append(
                AssetReference(
                    id: assetID,
                    filename: storedFilename,
                    originalFilename: url.lastPathComponent,
                    mediaType: mediaKind.rawValue
                )
            )
            _ = value.composition.updateNode(id: selectedNodeID) { node in
                node.parameters[key] = .string(assetID.uuidString)
            }
            value.composition.metadata.modifiedAt = Date(
                timeIntervalSince1970: floor(Date().timeIntervalSince1970)
            )
            session.commandExecutor.replaceDocument(value, actionName: "Import Media")
        } catch {
            session.importErrorMessage = error.localizedDescription
        }
    }

    private func importDroppedImages(_ request: ImageDropRequest) {
        session.isImportingImages = true
        defer { session.isImportingImages = false }

        if let result = ImageImportMutation.apply(
            payloads: request.payloads,
            to: document,
            at: request.location,
            dropPoint: request.point,
            targetNodeID: request.targetNodeID
        ) {
            session.commandExecutor.replaceDocument(
                result.document,
                actionName: result.affectedNodeIDs.count == 1 ? "Import Image" : "Import Images"
            )
            session.selectedNodeID = result.affectedNodeIDs.last
        }

        guard !request.failures.isEmpty else { return }
        session.importErrorMessage = request.failures.map {
            "\($0.filename): \($0.reason)"
        }.joined(separator: "\n")
    }

    private func togglePanel(_ panel: LegacyPanelKind) {
        switch panel {
        case .library: session.libraryVisible.toggle()
        case .inspector: session.inspectorVisible.toggle()
        case .viewer: session.viewerVisible.toggle()
        }
    }

    private func setPanel(_ panel: LegacyPanelKind, docked: Bool) {
        switch panel {
        case .library:
            session.libraryVisible = true
            session.libraryDocked = docked
        case .inspector:
            session.inspectorVisible = true
            session.inspectorDocked = docked
        case .viewer:
            session.viewerVisible = true
            session.viewerDocked = docked
        }
    }

    private func setPanelVisible(_ panel: LegacyPanelKind, visible: Bool) {
        switch panel {
        case .library: session.libraryVisible = visible
        case .inspector: session.inspectorVisible = visible
        case .viewer: session.viewerVisible = visible
        }
    }

    private func syncLegacyPanels() {
        guard interfaceStyle == .legacy else {
            session.legacyPanels.hideAll()
            LegacyPanelCoordinator.sharedUtilities.hideAll()
            return
        }
        syncLegacyPanel(
            .library,
            visible: session.libraryVisible,
            docked: session.libraryDocked,
            content: AnyView(
                LegacyDetachedPanelContainer(
                    title: LegacyPanelKind.library.title,
                    onDock: { setPanel(.library, docked: true) }
                ) {
                    PatchLibraryPanel(
                        selectedPatchID: selectedPatchBinding,
                        macros: document.composition.macroDefinitions,
                        onAdd: addSelectedLibraryItem,
                        legacyStyle: true
                    )
                }
            )
        )
        syncLegacyPanel(
            .inspector,
            visible: session.inspectorVisible,
            docked: session.inspectorDocked,
            content: AnyView(
                LegacyDetachedPanelContainer(
                    title: LegacyPanelKind.inspector.title,
                    onDock: { setPanel(.inspector, docked: true) }
                ) {
                    inspector
                }
            )
        )
        syncLegacyPanel(
            .viewer,
            visible: session.viewerVisible,
            docked: session.viewerDocked,
            content: AnyView(
                LegacyDetachedPanelContainer(
                    title: LegacyPanelKind.viewer.title,
                    onDock: { setPanel(.viewer, docked: true) }
                ) {
                    LegacyViewer(transport: transportBinding) {
                        preview
                    }
                }
            )
        )
    }

    private func syncLegacyPanel(
        _ panel: LegacyPanelKind,
        visible: Bool,
        docked: Bool,
        content: AnyView
    ) {
        let panels =
            panel == .viewer
            ? session.legacyPanels : LegacyPanelCoordinator.sharedUtilities
        if panel != .viewer,
            let editorWindow = session.editorWindow,
            !editorWindow.isKeyWindow,
            panels.hasVisiblePanel
        {
            return
        }
        guard visible && !docked else {
            panels.hide(panel)
            return
        }
        panels.show(
            panel,
            parent: session.editorWindow,
            content: content,
            onClose: { setPanelVisible(panel, visible: false) }
        )
    }
}

private struct LegacyEditorToolbar: View {
    let canEditParent: Bool
    let canEnterMacro: Bool
    let showsParameters: Bool
    let libraryVisible: Bool
    let inspectorVisible: Bool
    let viewerVisible: Bool
    let onLibrary: () -> Void
    let onCreateMacro: () -> Void
    let onEditParent: () -> Void
    let onEnterMacro: () -> Void
    let onParameters: () -> Void
    let onInspector: () -> Void
    let onViewer: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            LegacyToolbarButton(
                title: "Library",
                systemImage: "square.grid.2x2",
                isActive: libraryVisible,
                action: onLibrary
            )
            Divider().frame(height: 34)
            LegacyToolbarButton(
                title: "Create Macro",
                systemImage: "square.stack.3d.up",
                action: onCreateMacro
            )
            LegacyToolbarButton(
                title: "Edit Parent",
                systemImage: "arrowshape.turn.up.backward",
                isEnabled: canEditParent,
                action: onEditParent
            )
            LegacyToolbarButton(
                title: "Edit Macro",
                systemImage: "arrow.down.right.and.arrow.up.left",
                isEnabled: canEnterMacro,
                action: onEnterMacro
            )
            Divider().frame(height: 34)
            LegacyToolbarButton(
                title: "Parameters",
                systemImage: "switch.2",
                isActive: showsParameters,
                action: onParameters
            )
            LegacyToolbarButton(
                title: "Inspector",
                systemImage: "info.circle",
                isActive: inspectorVisible,
                action: onInspector
            )
            LegacyToolbarButton(
                title: "Viewer",
                systemImage: "play.rectangle",
                isActive: viewerVisible,
                action: onViewer
            )
            Spacer()
            Text("QUARTZ COMPOSER 4")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.48))
                .padding(.trailing, 10)
        }
        .padding(.horizontal, 8)
        .frame(height: 58)
        .background {
            LinearGradient(
                colors: [
                    Color(nsColor: NSColor(calibratedWhite: 0.31, alpha: 1)),
                    Color(nsColor: NSColor(calibratedWhite: 0.20, alpha: 1)),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(.black.opacity(0.75)).frame(height: 1)
        }
    }
}

private struct LegacyToolbarButton: View {
    let title: String
    let systemImage: String
    var isActive = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                Text(title)
                    .font(.system(size: 9))
            }
            .foregroundStyle(isEnabled ? .white.opacity(0.9) : .white.opacity(0.3))
            .frame(minWidth: 62, minHeight: 45)
            .background(
                isActive ? Color.white.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

private struct LegacyDockedPanelHeader<Content: View>: View {
    let title: String
    let onDetach: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .accessibilityIdentifier(
                        title == LegacyPanelKind.library.title
                            ? "mq.patch-library" : "mq.legacy-panel.\(title)"
                    )
                Spacer()
                Button(action: onDetach) {
                    Image(systemName: "rectangle.inset.filled.and.person.filled")
                }
                .buttonStyle(.plain)
                .help("Detach \(title)")
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Color(nsColor: NSColor(calibratedWhite: 0.22, alpha: 1)))
            content()
        }
    }
}

private struct LegacyDetachedPanelContainer<Content: View>: View {
    let title: String
    let onDock: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                Button("Dock", systemImage: "rectangle.split.3x1") {
                    onDock()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .help("Dock \(title) in the editor")
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Color(nsColor: NSColor(calibratedWhite: 0.22, alpha: 1)))
            content()
        }
        .preferredColorScheme(.dark)
    }
}

private struct LegacyViewer<Content: View>: View {
    @Binding var transport: PlaybackTransportState
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    transport.resetToken += 1
                } label: {
                    Label("Reset", systemImage: "backward.end.fill")
                }
                Button {
                    transport.isPlaying.toggle()
                } label: {
                    Label(
                        transport.isPlaying ? "Stop" : "Start",
                        systemImage: transport.isPlaying ? "stop.fill" : "play.fill"
                    )
                }
                Spacer()
                Text(transport.isPlaying ? "RENDERING" : "STOPPED")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(transport.isPlaying ? .green : .secondary)
            }
            .controlSize(.small)
            .padding(.horizontal, 9)
            .frame(height: 34)
            .background(Color(nsColor: NSColor(calibratedWhite: 0.18, alpha: 1)))
            content()
        }
        .background(.black)
    }
}

private struct LegacyPatchParametersPane: View {
    let node: NodeRecord?
    let assetReferences: [AssetReference]
    let onParameterChange: (String, ParameterValue) -> Void
    let onImportAsset: (String, AssetMediaKind, URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("PATCH PARAMETERS")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 27, alignment: .leading)
                .background(Color(nsColor: NSColor(calibratedWhite: 0.21, alpha: 1)))

            if let node,
                let definition = PatchRegistry.definition(for: node.patchType),
                !definition.parameters.isEmpty
            {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        ForEach(definition.parameters, id: \.key) { parameter in
                            ParameterEditor(
                                node: node,
                                schema: parameter,
                                assetReferences: assetReferences,
                                onChange: onParameterChange,
                                onImportAsset: onImportAsset
                            )
                            .frame(width: 220, alignment: .topLeading)
                        }
                    }
                    .padding(12)
                }
            } else {
                Text("Select a patch to edit its input parameters.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .background(Color(nsColor: NSColor(calibratedWhite: 0.14, alpha: 1)))
    }
}

private struct HostingWindowReader: NSViewRepresentable {
    let onResolve: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}

@MainActor
final class LegacyPanelCoordinator {
    static let sharedUtilities = LegacyPanelCoordinator()

    private final class Record {
        let panel: NSPanel
        let host: NSHostingController<AnyView>
        let closeObserver: LegacyPanelCloseObserver

        init(
            panel: NSPanel,
            host: NSHostingController<AnyView>,
            closeObserver: LegacyPanelCloseObserver
        ) {
            self.panel = panel
            self.host = host
            self.closeObserver = closeObserver
        }
    }

    private var records: [LegacyPanelKind: Record] = [:]

    var hasVisiblePanel: Bool {
        records.values.contains { $0.panel.isVisible }
    }

    func show(
        _ kind: LegacyPanelKind,
        parent: NSWindow?,
        content: AnyView,
        onClose: @escaping @MainActor () -> Void
    ) {
        let record: Record
        if let existing = records[kind] {
            existing.host.rootView = content
            existing.closeObserver.onClose = onClose
            record = existing
        } else {
            let size = kind.defaultSize
            let panel = NSPanel(
                contentRect: CGRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .resizable, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            panel.title = kind.title
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
            panel.minSize = CGSize(width: min(240, size.width), height: min(220, size.height))
            let host = NSHostingController(rootView: content)
            panel.contentViewController = host
            let closeObserver = LegacyPanelCloseObserver(onClose: onClose)
            panel.delegate = closeObserver
            let autosaveName = LegacyPanelPreferences.frameAutosaveName(for: kind)
            if !panel.setFrameUsingName(autosaveName) {
                panel.setFrame(defaultFrame(for: kind, parent: parent), display: false)
            }
            panel.setFrameAutosaveName(autosaveName)
            record = Record(panel: panel, host: host, closeObserver: closeObserver)
            records[kind] = record
        }

        attach(record.panel, to: parent)
        record.panel.orderFront(nil)
    }

    func hide(_ kind: LegacyPanelKind) {
        guard let panel = records[kind]?.panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func hideAll() {
        for kind in LegacyPanelKind.allCases {
            hide(kind)
        }
    }

    func hideIfAttached(to parent: NSWindow?) {
        guard let parent else { return }
        for record in records.values where record.panel.parent === parent {
            record.panel.parent?.removeChildWindow(record.panel)
            record.panel.orderOut(nil)
        }
    }

    private func attach(_ panel: NSPanel, to parent: NSWindow?) {
        guard panel.parent !== parent else { return }
        panel.parent?.removeChildWindow(panel)
        parent?.addChildWindow(panel, ordered: .above)
    }

    private func defaultFrame(for kind: LegacyPanelKind, parent: NSWindow?) -> CGRect {
        let size = kind.defaultSize
        let parentFrame =
            parent?.frame ?? NSScreen.main?.visibleFrame
            ?? CGRect(
                x: 100,
                y: 100,
                width: 960,
                height: 680
            )
        let proposed: CGRect
        switch kind {
        case .library:
            proposed = CGRect(
                x: parentFrame.minX - size.width - 12,
                y: parentFrame.maxY - size.height,
                width: size.width,
                height: size.height
            )
        case .inspector:
            proposed = CGRect(
                x: parentFrame.maxX + 12,
                y: parentFrame.maxY - size.height,
                width: size.width,
                height: size.height
            )
        case .viewer:
            proposed = CGRect(
                x: parentFrame.midX - size.width / 2 + 44,
                y: parentFrame.minY - size.height - 12,
                width: size.width,
                height: size.height
            )
        }
        let visibleFrame =
            parent?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? parentFrame
        return LegacyPanelPreferences.constrainedFrame(proposed, to: visibleFrame)
    }
}

@MainActor
private final class LegacyPanelCloseObserver: NSObject, NSWindowDelegate {
    var onClose: @MainActor () -> Void

    init(onClose: @escaping @MainActor () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

private struct PatchLibraryPanel: View {
    @Binding var selectedPatchID: PatchDescriptor.ID?
    let macros: [MacroDefinitionRecord]
    let onAdd: () -> Void
    var legacyStyle = false
    @State private var searchText = ""

    private var filteredCatalog: [PatchCatalogEntry] {
        guard !searchText.isEmpty else { return QuartzComposerCatalog.entries }
        return QuartzComposerCatalog.entries.filter { entry in
            entry.name.localizedStandardContains(searchText)
                || entry.pathTitle.localizedStandardContains(searchText)
        }
    }

    private var filteredMacros: [MacroDefinitionRecord] {
        guard !searchText.isEmpty else { return macros }
        return macros.filter { $0.name.localizedStandardContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !legacyStyle {
                PanelHeader(title: "Patch Library", systemImage: "square.grid.2x2")
                    .accessibilityIdentifier("mq.patch-library")
            }

            TextField("Search patches", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("mq.patch-library.search")
                .padding(10)

            List(selection: $selectedPatchID) {
                if searchText.isEmpty {
                    ForEach(QuartzComposerCatalog.sections) { section in
                        PatchCatalogSectionRows(
                            section: section,
                            selectedPatchID: $selectedPatchID,
                            onAdd: onAdd
                        )
                    }
                } else {
                    Section("Search Results") {
                        ForEach(filteredCatalog) { entry in
                            PatchCatalogEntryRow(
                                entry: entry,
                                selectedPatchID: $selectedPatchID,
                                onAdd: onAdd,
                                showsPath: true
                            )
                        }
                    }
                }
                if !filteredMacros.isEmpty {
                    Section("Macros") {
                        ForEach(filteredMacros) { macro in
                            let itemID = "macro:\(macro.id.rawValue.uuidString)"
                            Label(macro.name, systemImage: "square.stack.3d.up")
                                .tag(itemID)
                                .onDrag { NSItemProvider(object: itemID as NSString) }
                                .onTapGesture(count: 2) {
                                    selectedPatchID = itemID
                                    onAdd()
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Button(action: onAdd) {
                Label("Add Patch", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("mq.patch-library.add")
            .buttonStyle(.borderedProminent)
            .disabled(
                QuartzComposerCatalog.addableEntry(id: selectedPatchID) == nil
                    && !((selectedPatchID ?? "").hasPrefix("macro:"))
            )
            .padding(10)
        }
        .background(
            legacyStyle
                ? Color(nsColor: NSColor(calibratedWhite: 0.16, alpha: 1))
                : Color(nsColor: .windowBackgroundColor)
        )
    }
}

private struct PatchCatalogSectionRows: View {
    let section: PatchCatalogSection
    @Binding var selectedPatchID: PatchDescriptor.ID?
    let onAdd: () -> Void

    var body: some View {
        DisclosureGroup {
            ForEach(section.entries) { entry in
                PatchCatalogEntryRow(
                    entry: entry,
                    selectedPatchID: $selectedPatchID,
                    onAdd: onAdd,
                    showsPath: false
                )
            }
            ForEach(section.children) { child in
                PatchCatalogSectionRows(
                    section: child,
                    selectedPatchID: $selectedPatchID,
                    onAdd: onAdd
                )
            }
        } label: {
            Label(
                section.name,
                systemImage: section.path.count == 1 ? "folder.fill" : "folder"
            )
            .foregroundStyle(
                section.path.count == 1
                    ? Color(
                        nsColor: CategoryColorPreferences.color(
                            for: section.path.first ?? "Metaliquartz"
                        )
                    )
                    : .primary
            )
        }
    }
}

private struct PatchCatalogEntryRow: View {
    let entry: PatchCatalogEntry
    @Binding var selectedPatchID: PatchDescriptor.ID?
    let onAdd: () -> Void
    let showsPath: Bool

    var body: some View {
        Group {
            if entry.isAddable {
                row
                    .onDrag { NSItemProvider(object: entry.id as NSString) }
                    .onTapGesture(count: 2) {
                        selectedPatchID = entry.id
                        onAdd()
                    }
            } else {
                row
            }
        }
        .tag(entry.id)
        .accessibilityIdentifier("mq.patch-library.entry.\(entry.id)")
        .onTapGesture { selectedPatchID = entry.id }
        .help(
            entry.isAddable
                ? "Add \(entry.name) from \(entry.pathTitle)"
                : "Catalog reference only; this patch is not implemented yet"
        )
    }

    private var row: some View {
        HStack(spacing: 7) {
            Image(systemName: entry.isAddable ? "puzzlepiece.extension" : "lock")
                .foregroundStyle(
                    entry.isAddable
                        ? Color(
                            nsColor: CategoryColorPreferences.color(for: entry.topLevelCategory))
                        : .secondary
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .foregroundStyle(entry.isAddable ? .primary : .secondary)
                if showsPath {
                    Text(entry.pathTitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            if entry.status == .existingAlias {
                Text("Alias")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct InspectorPanel: View {
    let node: NodeRecord?
    let descriptor: PatchDescriptor?
    let catalogEntry: PatchCatalogEntry?
    let assetReferences: [AssetReference]
    let onRename: (String) -> Void
    let onParameterChange: (String, ParameterValue) -> Void
    let onImportAsset: (String, AssetMediaKind, URL) -> Void
    let publishedParameters: [PublishedParameterRecord]
    let onTogglePublished: (NodeRecord, ParameterSchema) -> Void
    let macroDefinition: MacroDefinitionRecord?
    let onEnterMacro: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Inspector", systemImage: "slider.horizontal.3")
                .accessibilityIdentifier("mq.inspector")

            if let node {
                Form {
                    LabeledContent("Name") {
                        TextField(
                            "",
                            text: Binding(
                                get: { node.name },
                                set: { name in onRename(name) }
                            )
                        )
                        .multilineTextAlignment(.trailing)
                    }
                    LabeledContent(
                        "Category",
                        value: macroDefinition == nil
                            ? PatchDescriptor.descriptor(for: node.patchType)?.category.rawValue
                                ?? "Unavailable"
                            : "Macro"
                    )
                    LabeledContent("Type") {
                        Text(node.patchType)
                            .font(.caption2.monospaced())
                            .multilineTextAlignment(.trailing)
                            .lineLimit(2)
                    }

                    if let patch = PatchDescriptor.descriptor(for: node.patchType) {
                        Section("About") {
                            Text(patch.summary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            if patch.isContainer {
                                Button("Enter Child Graph", action: onEnterMacro)
                            }
                        }
                    } else if let macroDefinition {
                        Section("Macro") {
                            Text(
                                "\(macroDefinition.graph.nodes.count) patches · \(macroDefinition.ports.count) published ports"
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            Button("Enter Subcomposition", action: onEnterMacro)
                        }
                    }

                    Section("Ports") {
                        ForEach(node.ports) { port in
                            LabeledContent(
                                port.name,
                                value:
                                    "\(port.direction == .input ? "In" : "Out") · \(port.dataType.rawValue.capitalized)"
                            )
                            .font(.callout)
                        }
                    }

                    if let definition = PatchRegistry.definition(for: node.patchType),
                        !definition.parameters.isEmpty
                    {
                        Section("Parameters") {
                            ForEach(definition.parameters, id: \.key) { parameter in
                                VStack(alignment: .leading, spacing: 6) {
                                    ParameterEditor(
                                        node: node,
                                        schema: parameter,
                                        assetReferences: assetReferences,
                                        onChange: onParameterChange,
                                        onImportAsset: onImportAsset
                                    )
                                    publishButton(node: node, schema: parameter)
                                }
                            }
                            if definition.executorKind == .customShader,
                                case .string(let source) = node.parameters["shaderSource"]
                            {
                                ForEach(
                                    CustomShaderSource.parameterDeclarations(in: source)
                                ) { declaration in
                                    let schema = ParameterSchema.number(
                                        key: declaration.key,
                                        name: declaration.name,
                                        defaultValue: declaration.defaultValue,
                                        range: declaration.minimum...declaration.maximum
                                    )
                                    VStack(alignment: .leading, spacing: 6) {
                                        ParameterEditor(
                                            node: node,
                                            schema: schema,
                                            assetReferences: assetReferences,
                                            onChange: onParameterChange,
                                            onImportAsset: onImportAsset
                                        )
                                        publishButton(node: node, schema: schema)
                                    }
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            } else if let catalogEntry {
                Form {
                    LabeledContent("Patch", value: catalogEntry.name)
                    LabeledContent("Library Path", value: catalogEntry.pathTitle)
                    LabeledContent(
                        "Status",
                        value: catalogEntry.status == .catalogOnly
                            ? "Catalog Only"
                            : catalogEntry.status == .existingAlias
                                ? "Existing Alias" : "Functional"
                    )
                    Section("About") {
                        Text(
                            descriptor?.summary
                                ?? "This Quartz Composer library entry is preserved for search and reference, but cannot be added until an implementation is available."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView(
                    "No Patch Selected",
                    systemImage: "square.dashed",
                    description: Text("Select a patch in the library to inspect it.")
                )
            }
        }
        .background(.background)
    }

    @ViewBuilder
    private func publishButton(node: NodeRecord, schema: ParameterSchema) -> some View {
        if schema.isLivePublishable {
            let isPublished = publishedParameters.contains {
                $0.nodeID == node.id && $0.parameterKey == schema.key
            }
            Button {
                onTogglePublished(node, schema)
            } label: {
                Label(
                    isPublished ? "Published" : "Publish for Live Control",
                    systemImage: isPublished
                        ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right"
                )
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(isPublished ? .green : .secondary)
        }
    }
}

private struct ParameterEditor: View {
    let node: NodeRecord
    let schema: ParameterSchema
    let assetReferences: [AssetReference]
    let onChange: (String, ParameterValue) -> Void
    let onImportAsset: (String, AssetMediaKind, URL) -> Void
    @State private var isImportingAsset = false
    @State private var shaderDiagnostic: String?
    @AppStorage(NumericControlStyle.preferenceKey) private var rawNumericControlStyle =
        NumericControlStyle.sliders.rawValue

    private var numericControlStyle: NumericControlStyle {
        NumericControlStyle(rawValue: rawNumericControlStyle) ?? .sliders
    }

    @ViewBuilder
    var body: some View {
        switch schema {
        case .number(let key, let name, let defaultValue, let range):
            VStack(alignment: .leading, spacing: 5) {
                LabeledContent(name) {
                    HStack(spacing: 6) {
                        TextField(
                            "",
                            value: numericBinding(
                                key: key, defaultValue: defaultValue, range: range
                            ),
                            format: .number.precision(.fractionLength(0...3))
                        )
                        .accessibilityIdentifier("mq.inspector.parameter.\(key)")
                        .frame(width: 72)
                        .multilineTextAlignment(.trailing)

                        if numericControlStyle == .rotaryFaders {
                            RotaryFader(
                                value: numericBinding(
                                    key: key, defaultValue: defaultValue, range: range
                                ),
                                range: range,
                                defaultValue: defaultValue,
                                accessibilityLabel: name
                            )
                            .frame(width: 30, height: 30)
                            .help("Drag or scroll to adjust; double-click to reset")
                        }
                    }
                }
                if numericControlStyle == .sliders {
                    Slider(
                        value: numericBinding(
                            key: key, defaultValue: defaultValue, range: range
                        ),
                        in: range
                    )
                }
            }
        case .boolean(let key, let name, let defaultValue):
            Toggle(
                name,
                isOn: Binding(
                    get: { node.parameters[key]?.booleanValue ?? defaultValue },
                    set: { onChange(key, .boolean($0)) }
                )
            )
            .accessibilityIdentifier("mq.inspector.parameter.\(key)")
        case .string(let key, let name, let defaultValue):
            if node.patchType == "\(PatchRegistry.namespace).syphon-input",
                key == "serverUUID"
            {
                SyphonServerPicker(
                    selectedUUID: node.parameters[key]?.stringValue ?? defaultValue
                ) { server in
                    onChange("serverUUID", .string(server?.id ?? ""))
                    onChange("serverName", .string(server?.name ?? ""))
                    onChange("serverAppName", .string(server?.applicationName ?? ""))
                }
            } else {
                LabeledContent(name) {
                    TextField(
                        name,
                        text: Binding(
                            get: { node.parameters[key]?.stringValue ?? defaultValue },
                            set: { onChange(key, .string($0)) }
                        )
                    )
                    .accessibilityIdentifier("mq.inspector.parameter.\(key)")
                    .multilineTextAlignment(.trailing)
                }
            }
        case .choice(let key, let name, let defaultValue, let choices):
            Picker(
                name,
                selection: Binding(
                    get: { node.parameters[key]?.stringValue ?? defaultValue },
                    set: { onChange(key, .string($0)) }
                )
            ) {
                ForEach(choices, id: \.self) { choice in
                    Text(choice.capitalized).tag(choice)
                }
            }
            .accessibilityIdentifier("mq.inspector.parameter.\(key)")
        case .color(let key, let name, let defaultValue):
            ColorPicker(
                name,
                selection: Binding(
                    get: { (node.parameters[key] ?? defaultValue).swiftUIColor },
                    set: { color in
                        guard let converted = NSColor(color).usingColorSpace(.deviceRGB) else {
                            return
                        }
                        onChange(
                            key,
                            .color(
                                red: converted.redComponent,
                                green: converted.greenComponent,
                                blue: converted.blueComponent,
                                alpha: converted.alphaComponent
                            )
                        )
                    }
                )
            )
            .accessibilityIdentifier("mq.inspector.parameter.\(key)")
        case .asset(let key, let name, let mediaKind):
            LabeledContent(name) {
                Button(assetName(for: key) ?? "Choose…") {
                    isImportingAsset = true
                }
                .lineLimit(1)
                .fileImporter(
                    isPresented: $isImportingAsset,
                    allowedContentTypes: mediaKind == .image ? [.image] : [.movie]
                ) { result in
                    if case .success(let url) = result {
                        onImportAsset(key, mediaKind, url)
                    }
                }
            }
        case .code(let key, let name, let defaultValue):
            VStack(alignment: .leading, spacing: 8) {
                Text(name)
                    .font(.caption.weight(.semibold))
                TextEditor(
                    text: Binding(
                        get: { node.parameters[key]?.stringValue ?? defaultValue },
                        set: { source in
                            onChange(key, .string(source))
                            shaderDiagnostic = CustomShaderCompiler.diagnostic(for: source)
                        }
                    )
                )
                .font(.system(.caption2, design: .monospaced))
                .frame(minHeight: 220)
                .border(.separator)

                if let shaderDiagnostic {
                    Label(shaderDiagnostic, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } else {
                    Label("Shader compiles", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
            .onAppear {
                shaderDiagnostic = CustomShaderCompiler.diagnostic(
                    for: node.parameters[key]?.stringValue ?? defaultValue
                )
            }
        }
    }

    private func numericBinding(
        key: String,
        defaultValue: Double,
        range: ClosedRange<Double>
    ) -> Binding<Double> {
        Binding(
            get: { node.parameters[key]?.numberValue ?? defaultValue },
            set: { newValue in
                onChange(
                    key,
                    .number(min(range.upperBound, max(range.lowerBound, newValue)))
                )
            }
        )
    }

    private func assetName(for key: String) -> String? {
        guard
            let value = node.parameters[key]?.stringValue,
            let id = UUID(uuidString: value)
        else { return nil }
        return assetReferences.first { $0.id == id }?.originalFilename
    }
}

extension ParameterValue {
    fileprivate var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    fileprivate var booleanValue: Bool? {
        guard case .boolean(let value) = self else { return nil }
        return value
    }

    fileprivate var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    fileprivate var swiftUIColor: Color {
        guard case .color(let red, let green, let blue, let alpha) = self else {
            return .white
        }
        return Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}

extension ParameterSchema {
    fileprivate var isLivePublishable: Bool {
        switch self {
        case .asset, .code: false
        default: true
        }
    }

    fileprivate var liveRange: ClosedRange<Double>? {
        switch self {
        case .number(_, _, _, let range): range
        case .boolean, .color: 0...1
        default: nil
        }
    }

}

private struct PanelHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .background(.bar)
    }
}

extension PatchCategory {
    fileprivate var systemImage: String {
        switch self {
        case .control:
            "dial.medium"
        case .input:
            "photo.on.rectangle"
        case .processing:
            "wand.and.stars"
        case .rendering:
            "display"
        }
    }
}
