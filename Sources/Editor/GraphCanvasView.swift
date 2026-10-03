import AppKit
import SwiftUI

enum GraphCanvasAppearance: Hashable, Sendable {
    case modern
    case quartzComposer4
}

@MainActor
final class GraphCommandExecutor: NSObject {
    private var document: Binding<CompositionDocument>?
    private var location = GraphLocation.root
    private weak var undoManager: UndoManager?

    func bind(
        document: Binding<CompositionDocument>,
        location: GraphLocation,
        undoManager: UndoManager?
    ) {
        self.document = document
        self.location = location
        self.undoManager = undoManager
    }

    func perform(_ command: GraphCommand, actionName: String) {
        perform(command, at: location, actionName: actionName)
    }

    private func perform(
        _ command: GraphCommand,
        at location: GraphLocation,
        actionName: String
    ) {
        guard let document else { return }
        var value = document.wrappedValue
        guard var graph = value.composition.graph(at: location) else { return }
        let inverse = command.apply(to: &graph)
        value.composition.setGraph(graph, at: location)
        value.composition.metadata.modifiedAt = Date(
            timeIntervalSince1970: floor(Date().timeIntervalSince1970)
        )
        document.wrappedValue = value

        if let undoManager {
            undoManager.registerUndo(withTarget: self) { target in
                target.perform(inverse, at: location, actionName: actionName)
            }
            undoManager.setActionName(actionName)
        }
    }

    func updateEditorState(_ state: EditorStateRecord) {
        guard let document else { return }
        var value = document.wrappedValue
        value.composition.setEditorState(state, at: location)
        document.wrappedValue = value
    }

    func replaceComposition(_ composition: CompositionFile, actionName: String) {
        guard let document else { return }
        var value = document.wrappedValue
        let inverse = value.composition
        value.composition = composition
        value.composition.metadata.modifiedAt = Date(
            timeIntervalSince1970: floor(Date().timeIntervalSince1970)
        )
        document.wrappedValue = value
        if let undoManager {
            undoManager.registerUndo(withTarget: self) { target in
                target.replaceComposition(inverse, actionName: actionName)
            }
            undoManager.setActionName(actionName)
        }
    }

    func replaceDocument(_ replacement: CompositionDocument, actionName: String) {
        guard let document else { return }
        let inverse = document.wrappedValue
        document.wrappedValue = replacement
        if let undoManager {
            undoManager.registerUndo(withTarget: self) { target in
                target.replaceDocument(inverse, actionName: actionName)
            }
            undoManager.setActionName(actionName)
        }
    }
}

struct GraphCanvasRepresentable: NSViewRepresentable {
    @Binding var document: CompositionDocument
    @Binding var selectedNodeID: NodeID?
    let location: GraphLocation
    let commandExecutor: GraphCommandExecutor
    let appearance: GraphCanvasAppearance
    let onOpenMacro: (MacroID) -> Void
    let onOpenContainer: (NodeID) -> Void
    let onImageDrop: (ImageDropRequest) -> Void

    @Environment(\.undoManager) private var undoManager

    func makeCoordinator() -> Coordinator {
        Coordinator(
            document: $document,
            selectedNodeID: $selectedNodeID,
            location: location,
            commandExecutor: commandExecutor
        )
    }

    func makeNSView(context: Context) -> GraphCanvasView {
        let view = GraphCanvasView()
        context.coordinator.connect(to: view)
        return view
    }

    func updateNSView(_ nsView: GraphCanvasView, context: Context) {
        context.coordinator.document = $document
        context.coordinator.selectedNodeID = $selectedNodeID
        context.coordinator.location = location
        commandExecutor.bind(
            document: $document,
            location: location,
            undoManager: undoManager
        )
        guard let graph = document.composition.graph(at: location),
            let editorState = document.composition.editorState(at: location)
        else { return }
        nsView.update(
            graph: graph,
            editorState: editorState,
            macros: document.composition.macroDefinitions,
            appearance: appearance
        )
        nsView.graphLocation = location
        nsView.onOpenMacro = onOpenMacro
        nsView.onOpenContainer = onOpenContainer
        nsView.onImageDrop = onImageDrop
    }

    @MainActor
    final class Coordinator {
        var document: Binding<CompositionDocument>
        var selectedNodeID: Binding<NodeID?>
        var location: GraphLocation
        private let commandExecutor: GraphCommandExecutor

        init(
            document: Binding<CompositionDocument>,
            selectedNodeID: Binding<NodeID?>,
            location: GraphLocation,
            commandExecutor: GraphCommandExecutor
        ) {
            self.document = document
            self.selectedNodeID = selectedNodeID
            self.location = location
            self.commandExecutor = commandExecutor
        }

        func connect(to view: GraphCanvasView) {
            view.onCommand = { [weak self] command, name in
                self?.commandExecutor.perform(command, actionName: name)
            }
            view.onSelectionChange = { [weak self, weak view] selection in
                guard let self, let view else { return }
                selectedNodeID.wrappedValue = selection.last
                commandExecutor.updateEditorState(
                    EditorStateRecord(
                        viewport: view.viewport,
                        selectedNodeIDs: selection
                    )
                )
            }
            view.onViewportChange = { [weak self, weak view] viewport in
                guard let self, let view else { return }
                commandExecutor.updateEditorState(
                    EditorStateRecord(
                        viewport: viewport,
                        selectedNodeIDs: Array(view.selection)
                    )
                )
            }
        }
    }
}

@MainActor
final class GraphCanvasView: NSView {
    typealias CommandHandler = (GraphCommand, String) -> Void

    private enum Interaction {
        case none
        case draggingNodes(start: CanvasPoint, original: [NodeID: CanvasPoint])
        case marquee(start: CanvasPoint, current: CanvasPoint)
        case panning(start: NSPoint, original: CanvasPoint)
        case connecting(
            outputNodeID: NodeID,
            outputPort: PortRecord,
            connectionID: ConnectionID?,
            current: CanvasPoint
        )
    }

    private struct PortHit {
        var node: NodeRecord
        var port: PortRecord
        var point: CanvasPoint
    }

    static let graphPasteboardType = NSPasteboard.PasteboardType(
        "com.steolepanda.metaliquartz.graph-nodes"
    )

    var onCommand: CommandHandler?
    var onSelectionChange: (([NodeID]) -> Void)?
    var onViewportChange: ((CanvasViewport) -> Void)?
    var onOpenMacro: ((MacroID) -> Void)?
    var onOpenContainer: ((NodeID) -> Void)?
    var onImageDrop: ((ImageDropRequest) -> Void)?
    var graphLocation = GraphLocation.root

    private(set) var graph = GraphRecord.empty
    private(set) var viewport = CanvasViewport.default
    private(set) var selection = Set<NodeID>()
    private(set) var canvasAppearance = GraphCanvasAppearance.modern
    private var macros: [MacroDefinitionRecord] = []

    private var interaction = Interaction.none
    private var didMoveDuringInteraction = false
    private var imageDropTargetNodeID: NodeID?
    private var isReceivingImageDrop = false
    private var isResolvingImageDrop = false
    private var representedAccessibilityElements: [NSAccessibilityElement] = []

    private var nodeWidth: Double { canvasAppearance == .quartzComposer4 ? 164 : 190 }
    private var headerHeight: Double { canvasAppearance == .quartzComposer4 ? 24 : 30 }
    private var portRowHeight: Double { canvasAppearance == .quartzComposer4 ? 19 : 23 }
    private var gridSpacing: Double { canvasAppearance == .quartzComposer4 ? 16 : 24 }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.string] + ImageDropResolver.readableTypes)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Composition graph canvas")
        setAccessibilityIdentifier("mq.graph.canvas")
        setAccessibilityHelp(
            "Press Tab to move between patches, arrow keys to move the selection, Return to enter a macro, and Command-A to select all."
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        graph: GraphRecord,
        editorState: EditorStateRecord,
        macros: [MacroDefinitionRecord],
        appearance: GraphCanvasAppearance = .modern
    ) {
        guard case .none = interaction else { return }
        self.graph = graph
        self.macros = macros
        canvasAppearance = appearance
        viewport = editorState.viewport
        selection = Set(
            editorState.selectedNodeIDs.filter { selectedID in
                graph.nodes.contains { $0.id == selectedID }
            })
        updateAccessibilitySummary()
        updateRepresentedAccessibilityElements()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateRepresentedAccessibilityElements()
    }

    override func layout() {
        super.layout()
        updateRepresentedAccessibilityElements()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let backgroundWhite: CGFloat = canvasAppearance == .quartzComposer4 ? 0.115 : 0.065
        NSColor(calibratedWhite: backgroundWhite, alpha: 1).setFill()
        dirtyRect.fill()
        drawGrid(in: dirtyRect)
        drawConnections()
        drawNodes()
        drawActiveConnection()
        drawMarquee()

        if graph.nodes.isEmpty {
            drawEmptyState()
        }
        drawImageDropHighlight()
        if window?.firstResponder === self {
            NSColor.controlAccentColor.setStroke()
            let focusRect = bounds.insetBy(dx: 1.5, dy: 1.5)
            let path = NSBezierPath(roundedRect: focusRect, xRadius: 6, yRadius: 6)
            path.lineWidth = 2
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let viewPoint = convert(event.locationInWindow, from: nil)
        let worldPoint = viewToWorld(viewPoint)
        didMoveDuringInteraction = false

        if event.buttonNumber == 2 || event.modifierFlags.contains(.option) {
            interaction = .panning(start: viewPoint, original: viewport.origin)
            return
        }

        if let hit = port(at: viewPoint) {
            beginConnection(from: hit, current: worldPoint)
            return
        }

        if let node = node(at: viewPoint) {
            if event.clickCount >= 2 {
                if let macroID = node.macroID {
                    onOpenMacro?(macroID)
                    return
                }
                if PatchDescriptor.descriptor(for: node.patchType)?.isContainer == true {
                    onOpenContainer?(node.id)
                    return
                }
            }
            updateSelectionForClick(node.id, modifiers: event.modifierFlags)
            let original = Dictionary(
                uniqueKeysWithValues: graph.nodes.filter { selection.contains($0.id) }.map {
                    ($0.id, $0.position)
                }
            )
            interaction = .draggingNodes(start: worldPoint, original: original)
            return
        }

        if !event.modifierFlags.contains(.shift) && !event.modifierFlags.contains(.command) {
            setSelection([])
        }
        interaction = .marquee(start: worldPoint, current: worldPoint)
    }

    override func mouseDragged(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let worldPoint = viewToWorld(viewPoint)

        switch interaction {
        case .none:
            break
        case .draggingNodes(let start, let original):
            let delta = CanvasPoint(x: worldPoint.x - start.x, y: worldPoint.y - start.y)
            for index in graph.nodes.indices {
                guard let initial = original[graph.nodes[index].id] else { continue }
                graph.nodes[index].position = CanvasPoint(
                    x: initial.x + delta.x,
                    y: initial.y + delta.y
                )
            }
            didMoveDuringInteraction = abs(delta.x) > 0.5 || abs(delta.y) > 0.5
        case .marquee(let start, _):
            interaction = .marquee(start: start, current: worldPoint)
            let marquee = normalizedRect(from: start, to: worldPoint)
            setSelection(
                graph.nodes.filter { marquee.intersects(nodeRect(for: $0)) }.map(\.id)
            )
        case .panning(let start, let original):
            viewport.origin = CanvasPoint(
                x: original.x - Double(viewPoint.x - start.x) / viewport.zoom,
                y: original.y - Double(viewPoint.y - start.y) / viewport.zoom
            )
            didMoveDuringInteraction = true
        case .connecting(let nodeID, let output, let connectionID, _):
            interaction = .connecting(
                outputNodeID: nodeID,
                outputPort: output,
                connectionID: connectionID,
                current: worldPoint
            )
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let endingInteraction = interaction
        interaction = .none

        switch endingInteraction {
        case .draggingNodes(_, let original):
            if didMoveDuringInteraction {
                let newPositions = Dictionary(
                    uniqueKeysWithValues: graph.nodes.filter { original[$0.id] != nil }.map {
                        ($0.id, $0.position)
                    }
                )
                onCommand?(.moveNodes(newPositions), "Move Nodes")
            }
        case .panning:
            if didMoveDuringInteraction {
                onViewportChange?(viewport)
            }
        case .connecting(let outputNodeID, let output, let connectionID, _):
            if let inputHit = port(at: viewPoint),
                inputHit.port.direction == .input,
                inputHit.port.dataType == output.dataType,
                inputHit.node.id != outputNodeID
            {
                let connection = ConnectionRecord(
                    id: connectionID ?? ConnectionID(),
                    outputNodeID: outputNodeID,
                    outputPortID: output.id,
                    inputNodeID: inputHit.node.id,
                    inputPortID: inputHit.port.id
                )
                onCommand?(.addConnection(connection), "Connect Patches")
            }
        case .none, .marquee:
            break
        }
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let node = node(at: point), !selection.contains(node.id) {
            setSelection([node.id])
        }
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "Graph")
        if !selection.isEmpty {
            menu.addItem(
                withTitle: "Copy",
                action: #selector(copySelection(_:)),
                keyEquivalent: "c"
            )
            menu.addItem(
                withTitle: "Delete",
                action: #selector(deleteSelection(_:)),
                keyEquivalent: "\u{8}"
            )
            menu.addItem(.separator())
        }
        menu.addItem(
            withTitle: "Paste",
            action: #selector(pasteSelection(_:)),
            keyEquivalent: "v"
        )
        for item in menu.items {
            item.target = self
        }
        return menu
    }

    override func keyDown(with event: NSEvent) {
        let characters = event.charactersIgnoringModifiers ?? ""
        if event.modifierFlags.contains(.command) {
            switch characters.lowercased() {
            case "a":
                setSelection(graph.nodes.map(\.id))
            case "c":
                copySelection(nil)
            case "v":
                pasteSelection(nil)
            case "0":
                viewport = .default
                onViewportChange?(viewport)
                needsDisplay = true
            default:
                super.keyDown(with: event)
            }
            return
        }

        if characters == String(UnicodeScalar(NSDeleteCharacter)!)
            || characters == String(UnicodeScalar(NSBackspaceCharacter)!)
        {
            deleteSelection(nil)
            return
        }

        if event.keyCode == 48 {
            selectAdjacentNode(backward: event.modifierFlags.contains(.shift))
            return
        }

        if event.keyCode == 36, let nodeID = selection.first,
            let node = graph.nodes.first(where: { $0.id == nodeID })
        {
            if let macroID = node.macroID {
                onOpenMacro?(macroID)
                return
            }
            if PatchDescriptor.descriptor(for: node.patchType)?.isContainer == true {
                onOpenContainer?(node.id)
                return
            }
        }

        let movement: CanvasPoint?
        switch event.keyCode {
        case 123: movement = CanvasPoint(x: -1, y: 0)
        case 124: movement = CanvasPoint(x: 1, y: 0)
        case 125: movement = CanvasPoint(x: 0, y: 1)
        case 126: movement = CanvasPoint(x: 0, y: -1)
        default: movement = nil
        }
        if let movement, !selection.isEmpty {
            let distance = event.modifierFlags.contains(.shift) ? 10.0 : 1.0
            let positions = Dictionary(
                uniqueKeysWithValues: graph.nodes.filter { selection.contains($0.id) }.map {
                    (
                        $0.id,
                        CanvasPoint(
                            x: $0.position.x + movement.x * distance,
                            y: $0.position.y + movement.y * distance
                        )
                    )
                }
            )
            onCommand?(.moveNodes(positions), "Nudge Nodes")
        } else {
            super.keyDown(with: event)
        }
    }

    private func selectAdjacentNode(backward: Bool) {
        guard !graph.nodes.isEmpty else { return }
        let ordered = graph.nodes.sorted {
            if $0.position.y == $1.position.y { return $0.position.x < $1.position.x }
            return $0.position.y < $1.position.y
        }
        let currentIndex = ordered.firstIndex { selection.contains($0.id) }
        let nextIndex: Int
        if let currentIndex {
            nextIndex = (currentIndex + (backward ? ordered.count - 1 : 1)) % ordered.count
        } else {
            nextIndex = backward ? ordered.count - 1 : 0
        }
        setSelection([ordered[nextIndex].id])
        updateAccessibilitySummary()
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    private func updateAccessibilitySummary() {
        setAccessibilityValue(accessibilitySummary)
    }

    private func updateRepresentedAccessibilityElements() {
        guard window != nil else {
            representedAccessibilityElements = []
            setAccessibilityChildren([])
            return
        }

        var elements: [NSAccessibilityElement] = []
        elements.append(
            makeAccessibilityElement(
                role: .group,
                frame: bounds,
                label: "Composition graph canvas",
                identifier: "mq.graph.canvas",
                value: accessibilitySummary
            )
        )
        for node in graph.nodes {
            let nodeSlug = accessibilitySlug(node.name)
            elements.append(
                makeAccessibilityElement(
                    role: .group,
                    frame: nodeViewRect(for: node),
                    label: node.name,
                    identifier: "mq.graph.node.\(nodeSlug)"
                )
            )

            for port in node.ports {
                let point = worldToView(portWorldPoint(node: node, port: port))
                let direction = port.direction == .input ? "input" : "output"
                elements.append(
                    makeAccessibilityElement(
                        role: .button,
                        frame: CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18),
                        label: "\(node.name), \(direction) \(port.name)",
                        identifier:
                            "mq.graph.node.\(nodeSlug).port.\(direction).\(accessibilitySlug(port.key))"
                    )
                )
            }
        }
        representedAccessibilityElements = elements
        setAccessibilityChildren(elements)
    }

    private func makeAccessibilityElement(
        role: NSAccessibility.Role,
        frame: CGRect,
        label: String,
        identifier: String,
        value: String? = nil
    ) -> NSAccessibilityElement {
        let element = NSAccessibilityElement()
        element.setAccessibilityRole(role)
        element.setAccessibilityFrame(accessibilityScreenFrame(for: frame))
        element.setAccessibilityLabel(label)
        element.setAccessibilityParent(self)
        element.setAccessibilityIdentifier(identifier)
        element.setAccessibilityEnabled(true)
        if let value {
            element.setAccessibilityValue(value)
        }
        return element
    }

    private var accessibilitySummary: String {
        let selectedNames = graph.nodes.filter { selection.contains($0.id) }.map(\.name)
        let selectionDescription =
            selectedNames.isEmpty
            ? "No selection" : "Selected: \(selectedNames.joined(separator: ", "))"
        return
            "\(graph.nodes.count) patches, \(graph.connections.count) connections. \(selectionDescription)."
    }

    private func accessibilityScreenFrame(for frame: CGRect) -> CGRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(frame, to: nil))
    }

    private func accessibilitySlug(_ value: String) -> String {
        var result = ""
        var pendingSeparator = false
        for scalar in value.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingSeparator, !result.isEmpty { result.append("-") }
                result.unicodeScalars.append(scalar)
                pendingSeparator = false
            } else {
                pendingSeparator = true
            }
        }
        return result
    }

    override func scrollWheel(with event: NSEvent) {
        viewport.origin.x += Double(event.scrollingDeltaX) / viewport.zoom
        viewport.origin.y += Double(event.scrollingDeltaY) / viewport.zoom
        onViewportChange?(viewport)
        updateRepresentedAccessibilityElements()
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let anchoredWorldPoint = viewToWorld(viewPoint)
        viewport.zoom = min(2.5, max(0.25, viewport.zoom * (1 + Double(event.magnification))))
        viewport.origin = CanvasPoint(
            x: anchoredWorldPoint.x - Double(viewPoint.x) / viewport.zoom,
            y: anchoredWorldPoint.y - Double(viewPoint.y) / viewport.zoom
        )
        onViewportChange?(viewport)
        updateRepresentedAccessibilityElements()
        needsDisplay = true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if draggedPatchIdentifier(from: sender.draggingPasteboard) != nil {
            return .copy
        }
        guard ImageDropResolver.canResolveImages(from: sender.draggingPasteboard) else {
            return []
        }
        updateImageDropTarget(sender)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if draggedPatchIdentifier(from: sender.draggingPasteboard) != nil {
            return .copy
        }
        guard ImageDropResolver.canResolveImages(from: sender.draggingPasteboard) else {
            return []
        }
        updateImageDropTarget(sender)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        imageDropTargetNodeID = nil
        isReceivingImageDrop = false
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = viewToWorld(convert(sender.draggingLocation, from: nil))
        if let patchID = draggedPatchIdentifier(from: sender.draggingPasteboard) {
            let node: NodeRecord
            let actionName: String
            if let entry = QuartzComposerCatalog.addableEntry(id: patchID),
                let definitionID = entry.definitionID,
                let descriptor = PatchDescriptor.descriptor(for: definitionID)
            {
                node = descriptor.makeNode(at: point, catalogPathID: entry.id)
                actionName = "Add \(descriptor.name)"
            } else if patchID.hasPrefix("macro:"),
                let rawID = UUID(uuidString: String(patchID.dropFirst("macro:".count))),
                let definition = macros.first(where: { $0.id == MacroID(rawID) })
            {
                node = NodeRecord.macroInstance(definition: definition, position: point)
                actionName = "Add \(definition.name)"
            } else {
                return false
            }
            onCommand?(.addNodes([node]), actionName)
            graph.nodes.append(node)
            setSelection([node.id])
            return true
        }

        guard ImageDropResolver.canResolveImages(from: sender.draggingPasteboard) else {
            return false
        }
        let targetNodeID = node(at: convert(sender.draggingLocation, from: nil))?.id
        isResolvingImageDrop = true
        isReceivingImageDrop = false
        imageDropTargetNodeID = targetNodeID
        needsDisplay = true
        ImageDropResolver.resolve(pasteboard: sender.draggingPasteboard) {
            [weak self] payloads, failures in
            guard let self else { return }
            isResolvingImageDrop = false
            imageDropTargetNodeID = nil
            needsDisplay = true
            onImageDrop?(
                ImageDropRequest(
                    location: graphLocation,
                    point: point,
                    targetNodeID: targetNodeID,
                    payloads: payloads,
                    failures: failures
                )
            )
        }
        return true
    }

    private func draggedPatchIdentifier(from pasteboard: NSPasteboard) -> String? {
        guard let identifier = pasteboard.string(forType: .string) else { return nil }
        if QuartzComposerCatalog.addableEntry(id: identifier) != nil {
            return identifier
        }
        guard identifier.hasPrefix("macro:"),
            let rawID = UUID(uuidString: String(identifier.dropFirst("macro:".count))),
            macros.contains(where: { $0.id == MacroID(rawID) })
        else { return nil }
        return identifier
    }

    private func updateImageDropTarget(_ sender: NSDraggingInfo) {
        let point = convert(sender.draggingLocation, from: nil)
        imageDropTargetNodeID = node(at: point)?.id
        isReceivingImageDrop = true
        needsDisplay = true
    }

    @objc private func copySelection(_ sender: Any?) {
        let payload = GraphClipboardPayload.selection(from: graph, nodeIDs: selection)
        guard !payload.nodes.isEmpty, let data = try? JSONEncoder().encode(payload) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: Self.graphPasteboardType)
    }

    @objc private func pasteSelection(_ sender: Any?) {
        guard
            let data = NSPasteboard.general.data(forType: Self.graphPasteboardType),
            let payload = try? JSONDecoder().decode(GraphClipboardPayload.self, from: data)
        else {
            return
        }
        let duplicate = payload.duplicated()
        var replacement = graph
        replacement.nodes.append(contentsOf: duplicate.nodes)
        replacement.connections.append(contentsOf: duplicate.connections)
        replacement.childGraphs.append(contentsOf: duplicate.childGraphs)
        onCommand?(.replaceGraph(replacement), "Paste Nodes")
        graph = replacement
        setSelection(duplicate.nodes.map(\.id))
    }

    @objc private func deleteSelection(_ sender: Any?) {
        guard !selection.isEmpty else { return }
        onCommand?(.removeNodes(selection), "Delete Nodes")
        setSelection([])
    }

    private func beginConnection(from hit: PortHit, current: CanvasPoint) {
        if hit.port.direction == .output {
            interaction = .connecting(
                outputNodeID: hit.node.id,
                outputPort: hit.port,
                connectionID: nil,
                current: current
            )
        } else if let connection = graph.connections.first(where: {
            $0.inputPortID == hit.port.id
        }), let outputNode = graph.nodes.first(where: { $0.id == connection.outputNodeID }),
            let outputPort = outputNode.ports.first(where: { $0.id == connection.outputPortID })
        {
            interaction = .connecting(
                outputNodeID: outputNode.id,
                outputPort: outputPort,
                connectionID: connection.id,
                current: current
            )
        }
    }

    private func updateSelectionForClick(_ id: NodeID, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) || modifiers.contains(.shift) {
            if selection.contains(id) {
                selection.remove(id)
            } else {
                selection.insert(id)
            }
            publishSelection()
        } else if !selection.contains(id) {
            setSelection([id])
        }
    }

    private func setSelection<S: Sequence>(_ ids: S) where S.Element == NodeID {
        selection = Set(ids)
        publishSelection()
        needsDisplay = true
    }

    private func publishSelection() {
        let ordered = graph.nodes.map(\.id).filter(selection.contains)
        onSelectionChange?(ordered)
        updateAccessibilitySummary()
        updateRepresentedAccessibilityElements()
    }

    private func viewToWorld(_ point: NSPoint) -> CanvasPoint {
        CanvasPoint(
            x: viewport.origin.x + Double(point.x) / viewport.zoom,
            y: viewport.origin.y + Double(point.y) / viewport.zoom
        )
    }

    private func worldToView(_ point: CanvasPoint) -> NSPoint {
        NSPoint(
            x: (point.x - viewport.origin.x) * viewport.zoom,
            y: (point.y - viewport.origin.y) * viewport.zoom
        )
    }

    private func nodeHeight(for node: NodeRecord) -> Double {
        let inputs = node.ports.filter { $0.direction == .input }.count
        let outputs = node.ports.filter { $0.direction == .output }.count
        return max(
            canvasAppearance == .quartzComposer4 ? 58 : 76,
            headerHeight + (canvasAppearance == .quartzComposer4 ? 10 : 14)
                + Double(max(inputs, outputs)) * portRowHeight
        )
    }

    private func nodeRect(for node: NodeRecord) -> CGRect {
        CGRect(
            x: node.position.x,
            y: node.position.y,
            width: nodeWidth,
            height: nodeHeight(for: node)
        )
    }

    private func nodeViewRect(for node: NodeRecord) -> CGRect {
        let origin = worldToView(node.position)
        return CGRect(
            x: origin.x,
            y: origin.y,
            width: nodeWidth * viewport.zoom,
            height: nodeHeight(for: node) * viewport.zoom
        )
    }

    private func portWorldPoint(node: NodeRecord, port: PortRecord) -> CanvasPoint {
        let peers = node.ports.filter { $0.direction == port.direction }
        let index = peers.firstIndex(where: { $0.id == port.id }) ?? 0
        return CanvasPoint(
            x: node.position.x + (port.direction == .input ? 0 : nodeWidth),
            y: node.position.y + headerHeight
                + (canvasAppearance == .quartzComposer4 ? 13 : 17)
                + Double(index) * portRowHeight
        )
    }

    private func port(at viewPoint: NSPoint) -> PortHit? {
        for node in graph.nodes.reversed() {
            for candidate in node.ports {
                let worldPoint = portWorldPoint(node: node, port: candidate)
                let point = worldToView(worldPoint)
                if hypot(point.x - viewPoint.x, point.y - viewPoint.y) <= 10 {
                    return PortHit(node: node, port: candidate, point: worldPoint)
                }
            }
        }
        return nil
    }

    private func node(at viewPoint: NSPoint) -> NodeRecord? {
        graph.nodes.reversed().first { nodeViewRect(for: $0).contains(viewPoint) }
    }

    private func normalizedRect(from start: CanvasPoint, to end: CanvasPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func drawGrid(in dirtyRect: NSRect) {
        let spacing = gridSpacing * viewport.zoom
        guard spacing >= 5 else { return }
        let origin = worldToView(.zero)
        let startX = origin.x.truncatingRemainder(dividingBy: spacing)
        let startY = origin.y.truncatingRemainder(dividingBy: spacing)
        let path = NSBezierPath()
        for x in stride(from: startX, through: dirtyRect.maxX, by: spacing) {
            path.move(to: NSPoint(x: x, y: dirtyRect.minY))
            path.line(to: NSPoint(x: x, y: dirtyRect.maxY))
        }
        for y in stride(from: startY, through: dirtyRect.maxY, by: spacing) {
            path.move(to: NSPoint(x: dirtyRect.minX, y: y))
            path.line(to: NSPoint(x: dirtyRect.maxX, y: y))
        }
        NSColor(
            calibratedWhite: canvasAppearance == .quartzComposer4 ? 0.21 : 0.16,
            alpha: canvasAppearance == .quartzComposer4 ? 0.58 : 0.7
        ).setStroke()
        path.lineWidth = canvasAppearance == .quartzComposer4 ? 0.35 : 0.5
        path.stroke()
    }

    private func drawConnections() {
        for connection in graph.connections {
            guard
                let outputNode = graph.nodes.first(where: { $0.id == connection.outputNodeID }),
                let output = outputNode.ports.first(where: { $0.id == connection.outputPortID }),
                let inputNode = graph.nodes.first(where: { $0.id == connection.inputNodeID }),
                let input = inputNode.ports.first(where: { $0.id == connection.inputPortID })
            else { continue }
            drawCable(
                from: worldToView(portWorldPoint(node: outputNode, port: output)),
                to: worldToView(portWorldPoint(node: inputNode, port: input)),
                color: portColor(output.dataType)
            )
        }
    }

    private func drawCable(from start: NSPoint, to end: NSPoint, color: NSColor) {
        let distance = max(48, abs(end.x - start.x) * 0.45)
        let path = NSBezierPath()
        path.move(to: start)
        path.curve(
            to: end,
            controlPoint1: NSPoint(x: start.x + distance, y: start.y),
            controlPoint2: NSPoint(x: end.x - distance, y: end.y)
        )
        NSColor.black.withAlphaComponent(canvasAppearance == .quartzComposer4 ? 0.85 : 0.7)
            .setStroke()
        path.lineWidth = canvasAppearance == .quartzComposer4 ? 4 : 5
        path.stroke()
        (canvasAppearance == .quartzComposer4
            ? NSColor(calibratedWhite: 0.72, alpha: 1) : color)
            .withAlphaComponent(0.9).setStroke()
        path.lineWidth = canvasAppearance == .quartzComposer4 ? 1.35 : 2
        path.stroke()
    }

    private func drawNodes() {
        for node in graph.nodes {
            let rect = nodeViewRect(for: node)
            let isContainer = PatchDescriptor.descriptor(for: node.patchType)?.isContainer == true
            let radius =
                (isContainer ? 0 : (canvasAppearance == .quartzComposer4 ? 5 : 8))
                * viewport.zoom
            let body = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            if canvasAppearance == .quartzComposer4 {
                NSGradient(
                    starting: NSColor(calibratedWhite: 0.19, alpha: 1),
                    ending: NSColor(calibratedWhite: 0.075, alpha: 1)
                )?.draw(in: body, angle: -90)
            } else {
                NSColor(calibratedWhite: 0.115, alpha: 0.98).setFill()
                body.fill()
            }

            let headerRect = CGRect(
                x: rect.minX,
                y: rect.minY,
                width: rect.width,
                height: headerHeight * viewport.zoom
            )
            let header = NSBezierPath(
                roundedRect: headerRect,
                xRadius: radius,
                yRadius: radius
            )
            categoryColor(for: node).setFill()
            header.fill()
            NSColor(calibratedWhite: 0.03, alpha: 0.7).setStroke()
            body.lineWidth =
                selection.contains(node.id)
                ? (canvasAppearance == .quartzComposer4 ? 2 : 3) : 1
            if selection.contains(node.id) {
                (canvasAppearance == .quartzComposer4
                    ? NSColor.systemYellow : NSColor.controlAccentColor)
                    .setStroke()
            }
            body.stroke()

            drawNodeLabels(node, in: rect)
            for port in node.ports {
                drawPort(node: node, port: port)
            }
        }
    }

    private func drawNodeLabels(_ node: NodeRecord, in rect: CGRect) {
        let title = node.name as NSString
        title.draw(
            in: CGRect(
                x: rect.minX + 10 * viewport.zoom,
                y: rect.minY + (canvasAppearance == .quartzComposer4 ? 4 : 6) * viewport.zoom,
                width: rect.width - 20 * viewport.zoom,
                height: 19 * viewport.zoom
            ),
            withAttributes: [
                .font: NSFont.systemFont(
                    ofSize: max(
                        8,
                        (canvasAppearance == .quartzComposer4 ? 10.5 : 12) * viewport.zoom
                    ),
                    weight: canvasAppearance == .quartzComposer4 ? .medium : .semibold
                ),
                .foregroundColor: NSColor.white,
            ]
        )
        if PatchDescriptor.descriptor(for: node.patchType)?.isConsumer == true,
            case .number(let layer) = node.parameters["layer"]
        {
            let layerLabel = "Layer \(Int(layer))" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: max(7, 9 * viewport.zoom), weight: .semibold
                ),
                .foregroundColor: NSColor.white.withAlphaComponent(0.78),
            ]
            let size = layerLabel.size(withAttributes: attributes)
            layerLabel.draw(
                at: NSPoint(
                    x: rect.maxX - size.width - 8 * viewport.zoom,
                    y: rect.minY + (canvasAppearance == .quartzComposer4 ? 5 : 7) * viewport.zoom
                ),
                withAttributes: attributes
            )
        }
    }

    private func drawPort(node: NodeRecord, port: PortRecord) {
        let point = worldToView(portWorldPoint(node: node, port: port))
        let radius = max(
            canvasAppearance == .quartzComposer4 ? 2.75 : 3.5,
            (canvasAppearance == .quartzComposer4 ? 4 : 5) * viewport.zoom
        )
        let dot = NSBezierPath(
            ovalIn: CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        )
        portColor(port.dataType).setFill()
        dot.fill()
        (canvasAppearance == .quartzComposer4 ? NSColor.white : NSColor.black)
            .withAlphaComponent(canvasAppearance == .quartzComposer4 ? 0.65 : 0.8).setStroke()
        dot.lineWidth = 1
        dot.stroke()

        let label = port.name as NSString
        let labelWidth = 110 * viewport.zoom
        let labelRect = CGRect(
            x: port.direction == .input
                ? point.x + 10 * viewport.zoom
                : point.x - labelWidth - 10 * viewport.zoom,
            y: point.y - 8 * viewport.zoom,
            width: labelWidth,
            height: 18 * viewport.zoom
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = port.direction == .input ? .left : .right
        label.draw(
            in: labelRect,
            withAttributes: [
                .font: NSFont.systemFont(
                    ofSize: max(
                        7.5,
                        (canvasAppearance == .quartzComposer4 ? 9.25 : 10.5) * viewport.zoom
                    )
                ),
                .foregroundColor: NSColor(
                    calibratedWhite: canvasAppearance == .quartzComposer4 ? 0.86 : 0.78,
                    alpha: 1
                ),
                .paragraphStyle: paragraph,
            ]
        )
    }

    private func drawActiveConnection() {
        guard case .connecting(let nodeID, let output, _, let current) = interaction,
            let node = graph.nodes.first(where: { $0.id == nodeID })
        else { return }
        drawCable(
            from: worldToView(portWorldPoint(node: node, port: output)),
            to: worldToView(current),
            color: portColor(output.dataType)
        )
    }

    private func drawMarquee() {
        guard case .marquee(let start, let current) = interaction else { return }
        let startPoint = worldToView(start)
        let endPoint = worldToView(current)
        let rect = CGRect(
            x: min(startPoint.x, endPoint.x),
            y: min(startPoint.y, endPoint.y),
            width: abs(endPoint.x - startPoint.x),
            height: abs(endPoint.y - startPoint.y)
        )
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        rect.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        path.stroke()
    }

    private func drawImageDropHighlight() {
        guard isReceivingImageDrop || isResolvingImageDrop else { return }
        let label: NSString
        let rect: CGRect
        if let imageDropTargetNodeID,
            let node = graph.nodes.first(where: { $0.id == imageDropTargetNodeID }),
            node.patchType == "\(PatchRegistry.namespace).image-file"
        {
            rect = nodeViewRect(for: node).insetBy(dx: -4, dy: -4)
            label = isResolvingImageDrop ? "IMPORTING…" : "REPLACE IMAGE"
        } else {
            rect = bounds.insetBy(dx: 7, dy: 7)
            label = isResolvingImageDrop ? "IMPORTING IMAGE…" : "DROP TO IMPORT IMAGE"
        }
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        outline.lineWidth = 2
        outline.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.88),
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.minY + 9),
            withAttributes: attributes
        )
    }

    private func drawEmptyState() {
        let title = "DROP A PATCH TO BEGIN" as NSString
        let subtitle = "Drag from the library or use the Add button" as NSString
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.66, alpha: 1),
        ]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor(calibratedWhite: 0.46, alpha: 1),
        ]
        let titleSize = title.size(withAttributes: titleAttributes)
        let subtitleSize = subtitle.size(withAttributes: subtitleAttributes)
        title.draw(
            at: NSPoint(x: bounds.midX - titleSize.width / 2, y: bounds.midY - 17),
            withAttributes: titleAttributes
        )
        subtitle.draw(
            at: NSPoint(x: bounds.midX - subtitleSize.width / 2, y: bounds.midY + 9),
            withAttributes: subtitleAttributes
        )
    }

    private func portColor(_ type: PortDataType) -> NSColor {
        switch type {
        case .number: .systemYellow
        case .boolean: .systemOrange
        case .string: .systemGreen
        case .color: .systemPink
        case .image: .systemCyan
        case .event: .systemPurple
        }
    }

    private func categoryColor(for node: NodeRecord) -> NSColor {
        guard PatchDescriptor.descriptor(for: node.patchType) != nil else {
            return NSColor.systemGray.withAlphaComponent(0.7)
        }
        if let entry = QuartzComposerCatalog.entry(id: node.catalogPathID) {
            return CategoryColorPreferences.color(for: entry.topLevelCategory)
                .withAlphaComponent(canvasAppearance == .quartzComposer4 ? 0.82 : 0.72)
        }
        return switch PatchDescriptor.descriptor(for: node.patchType)?.category {
        case .control, .input, .processing, .rendering:
            CategoryColorPreferences.color(for: "Metaliquartz")
                .withAlphaComponent(canvasAppearance == .quartzComposer4 ? 0.82 : 0.72)
        case nil: NSColor.systemGray.withAlphaComponent(0.7)
        }
    }
}
