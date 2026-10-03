import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum LiveOutputResolution: String, CaseIterable, Identifiable, Sendable {
    case hd = "1280×720"
    case fullHD = "1920×1080"
    case ultraHD = "3840×2160"

    var id: String { rawValue }

    var size: CGSize {
        switch self {
        case .hd: CGSize(width: 1_280, height: 720)
        case .fullHD: CGSize(width: 1_920, height: 1_080)
        case .ultraHD: CGSize(width: 3_840, height: 2_160)
        }
    }
}

struct OutputDisplayOption: Identifiable, Hashable, Sendable {
    var id: UInt32
    var name: String

    @MainActor
    static var available: [OutputDisplayOption] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            return OutputDisplayOption(id: id, name: screen.localizedName)
        }
    }
}

extension NSScreen {
    fileprivate var displayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

@MainActor
@Observable
final class FullscreenOutputState {
    var composition: CompositionFile
    var assets: [String: Data]
    var transport: PlaybackTransportState
    var resolution: LiveOutputResolution
    let diagnostics = RenderDiagnosticsModel()

    init(
        composition: CompositionFile,
        assets: [String: Data],
        transport: PlaybackTransportState,
        resolution: LiveOutputResolution
    ) {
        self.composition = composition
        self.assets = assets
        self.transport = transport
        self.resolution = resolution
    }
}

private final class LiveOutputWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
@Observable
final class FullscreenOutputController {
    private(set) var isPresented = false
    private var window: NSWindow?
    private var state: FullscreenOutputState?

    func present(
        composition: CompositionFile,
        assets: [String: Data],
        transport: PlaybackTransportState,
        displayID: UInt32?,
        resolution: LiveOutputResolution
    ) {
        dismiss()
        let screen =
            NSScreen.screens.first { $0.displayID == displayID }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let state = FullscreenOutputState(
            composition: composition,
            assets: assets,
            transport: transport,
            resolution: resolution
        )
        let window = LiveOutputWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.title = "Metaliquartz Live Output"
        window.backgroundColor = .black
        window.isOpaque = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(
            rootView: FullscreenOutputView(state: state) { [weak self] in
                self?.dismiss()
            }
        )
        window.makeKeyAndOrderFront(nil)
        self.state = state
        self.window = window
        isPresented = true
    }

    func update(
        composition: CompositionFile,
        assets: [String: Data],
        transport: PlaybackTransportState,
        resolution: LiveOutputResolution
    ) {
        guard let state else { return }
        state.composition = composition
        state.assets = assets
        state.transport = transport
        state.resolution = resolution
    }

    func dismiss() {
        window?.contentView = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        state = nil
        isPresented = false
    }
}

private struct FullscreenOutputView: View {
    @Bindable var state: FullscreenOutputState
    let onExit: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            MetalPreviewView(
                composition: state.composition,
                assets: state.assets,
                transport: state.transport,
                diagnostics: state.diagnostics,
                showsHeader: false,
                forcedDrawableSize: state.resolution.size
            )
            Button(action: onExit) {
                Label("Exit Fullscreen", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.title)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.7))
            .padding(18)
        }
        .background(Color.black)
        .onExitCommand(perform: onExit)
    }
}

enum ProjectRecoveryStore {
    static func defaultDirectory(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("Metaliquartz/Recovery", isDirectory: true)
    }

    @discardableResult
    static func save(
        _ document: CompositionDocument,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = try directory ?? defaultDirectory(fileManager: fileManager)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = recoveryURL(
            compositionID: document.composition.metadata.id,
            directory: directory
        )
        let wrapper = try document.makePackageWrapper()
        try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
        return url
    }

    static func load(
        compositionID: UUID,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> CompositionDocument {
        let directory = try directory ?? defaultDirectory(fileManager: fileManager)
        let url = recoveryURL(compositionID: compositionID, directory: directory)
        return try CompositionDocument(
            packageWrapper: FileWrapper(url: url, options: .immediate)
        )
    }

    static func exists(
        compositionID: UUID,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let directory = try? directory ?? defaultDirectory(fileManager: fileManager) else {
            return false
        }
        return fileManager.fileExists(
            atPath: recoveryURL(compositionID: compositionID, directory: directory).path
        )
    }

    static func remove(
        compositionID: UUID,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        let directory = try directory ?? defaultDirectory(fileManager: fileManager)
        let url = recoveryURL(compositionID: compositionID, directory: directory)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    static func availableSnapshots(
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard let directory = try? directory ?? defaultDirectory(fileManager: fileManager),
            let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        return entries.filter { $0.pathExtension == "mquartz" }.sorted { lhs, rhs in
            let left = try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            let right = try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            return (left ?? .distantPast) > (right ?? .distantPast)
        }
    }

    static func recoveryURL(compositionID: UUID, directory: URL) -> URL {
        directory.appendingPathComponent("\(compositionID.uuidString).mquartz", isDirectory: true)
    }
}

enum PublishedParameterMapper {
    static func mappedValue(
        normalizedValue: Double,
        parameter: PublishedParameterRecord
    ) -> Double {
        let minimum = parameter.minimum ?? 0
        let maximum = parameter.maximum ?? 1
        return minimum + min(max(normalizedValue, 0), 1) * (maximum - minimum)
    }
}

final class PublishedParameterSmoother: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: Double] = [:]

    func value(
        for parameter: PublishedParameterRecord,
        target: Double,
        deltaTime: Double
    ) -> Double {
        lock.lock()
        defer { lock.unlock() }
        let previous = values[parameter.id] ?? target
        let response = max(0, parameter.smoothing)
        let alpha = response == 0 ? 1 : 1 - exp(-max(0, deltaTime) / response)
        let result = previous + (target - previous) * alpha
        values[parameter.id] = result
        return result
    }

    func reset() {
        lock.lock()
        values.removeAll()
        lock.unlock()
    }
}

struct LiveSessionPanel: View {
    @Binding var document: CompositionDocument
    @Binding var transport: PlaybackTransportState
    let diagnostics: RenderDiagnosticsModel
    let fullscreen: FullscreenOutputController
    let liveControls: LiveControlController

    @Environment(\.dismiss) private var dismiss
    @State private var presetName = ""
    @State private var recoveryMessage: String?
    @State private var supportMessage: String?
    @State private var pendingSample: SampleComposition?
    @State private var permissions = PermissionGuidanceModel()

    private var displays: [OutputDisplayOption] { OutputDisplayOption.available }
    private var settings: LiveSessionSettings {
        document.composition.liveSession ?? .default
    }
    private var resolution: LiveOutputResolution {
        LiveOutputResolution(rawValue: settings.outputResolution) ?? .fullHD
    }

    var body: some View {
        Form {
            Section("Transport & Output") {
                HStack {
                    Button(transport.isPlaying ? "Pause" : "Play") {
                        transport.isPlaying.toggle()
                    }
                    Button("Reset") { transport.resetToken += 1 }
                    Spacer()
                    Button(fullscreen.isPresented ? "Stop Fullscreen" : "Start Fullscreen") {
                        toggleFullscreen()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Picker("Display", selection: displayBinding) {
                    Text("Main Display").tag(nil as UInt32?)
                    ForEach(displays) { display in
                        Text(display.name).tag(display.id as UInt32?)
                    }
                }
                Picker("Resolution", selection: resolutionBinding) {
                    ForEach(LiveOutputResolution.allCases) { resolution in
                        Text(resolution.rawValue).tag(resolution.rawValue)
                    }
                }
            }

            Section("Published Parameters") {
                if document.composition.publishedParameters.isEmpty {
                    ContentUnavailableView(
                        "No Live Controls",
                        systemImage: "slider.horizontal.3",
                        description: Text("Publish parameters from a patch Inspector.")
                    )
                    .frame(minHeight: 110)
                } else {
                    ForEach(document.composition.publishedParameters) { parameter in
                        PublishedParameterRow(
                            parameter: parameter,
                            value: parameterValue(parameter),
                            mappings: document.composition.controlMappings.filter {
                                $0.publishedParameterID == parameter.id
                            },
                            midiSources: liveControls.midiSources,
                            isLearningMIDI:
                                liveControls.learningPublishedParameterID == parameter.id,
                            onValueChange: { setParameterValue(parameter, $0) },
                            onRecordChange: { updatePublishedParameter($0) },
                            onToggleMIDILearn: {
                                liveControls.toggleMIDILearn(for: parameter.id)
                            },
                            onAddOSCMapping: { addOSCMapping(for: parameter) },
                            onMappingChange: updateControlMapping,
                            onRemoveMapping: removeControlMapping,
                            onRemove: { removePublishedParameter(parameter.id) }
                        )
                    }
                }
            }

            Section("MIDI & OSC Input") {
                LabeledContent("MIDI") {
                    if let midiError = liveControls.midiError {
                        Text(midiError).foregroundStyle(.red)
                    } else {
                        Text(
                            liveControls.midiSources.isEmpty
                                ? "Waiting for devices"
                                : "\(liveControls.midiSources.count) source(s)"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("OSC UDP Port") {
                    TextField("Port", value: oscPortBinding, format: .number)
                        .frame(width: 90)
                }
                LabeledContent("OSC Status") {
                    Text(oscStatusDescription)
                        .foregroundStyle(oscStatusIsFailure ? .red : .secondary)
                }
                if let lastInputDescription = liveControls.lastInputDescription {
                    LabeledContent("Last Input") {
                        Text(lastInputDescription).lineLimit(1)
                    }
                }
            }

            Section("Presets") {
                HStack {
                    TextField("Preset name", text: $presetName)
                    Button("Capture") { capturePreset() }
                        .disabled(document.composition.publishedParameters.isEmpty)
                }
                ForEach(document.composition.presets) { preset in
                    HStack {
                        Text(preset.name)
                        Spacer()
                        Button("Apply") { applyPreset(preset) }
                        Button(role: .destructive) {
                            removePreset(preset.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }

            Section("Diagnostics") {
                DiagnosticsGrid(snapshot: diagnostics.snapshot)
                if diagnostics.snapshot.nodeErrors.isEmpty {
                    Label("No node errors", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    ForEach(
                        diagnostics.snapshot.nodeErrors.sorted {
                            $0.key.rawValue.uuidString < $1.key.rawValue.uuidString
                        },
                        id: \.key
                    ) {
                        nodeID, message in
                        VStack(alignment: .leading) {
                            Text(nodeName(nodeID)).font(.caption.weight(.semibold))
                            Text(message).font(.caption2).foregroundStyle(.red)
                        }
                    }
                }
                HStack {
                    Button("Reset Counters") { diagnostics.reset() }
                    Button("Export Diagnostic Report") { exportDiagnosticReport() }
                }
            }

            Section("Recovery") {
                HStack {
                    Button("Save Recovery Snapshot") { saveRecovery() }
                    Button("Restore Recovery Snapshot") { restoreRecovery() }
                        .disabled(
                            !ProjectRecoveryStore.exists(
                                compositionID: document.composition.metadata.id
                            )
                        )
                    Button("Delete Snapshot", role: .destructive) { deleteRecovery() }
                        .disabled(
                            !ProjectRecoveryStore.exists(
                                compositionID: document.composition.metadata.id
                            )
                        )
                }
                if let recoveryMessage {
                    Text(recoveryMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Permissions") {
                ForEach(permissions.items) { item in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.callout.weight(.semibold))
                            Text(item.guidance).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(item.readiness.rawValue)
                            .font(.caption)
                            .foregroundStyle(item.readiness == .ready ? .green : .orange)
                        if item.id == "camera" && item.readiness == .notDetermined {
                            Button("Request") { permissions.requestCamera() }
                        } else if item.settingsPane != nil && item.readiness != .ready {
                            Button("Settings") { permissions.openSettings(for: item) }
                        }
                    }
                }
                Button("Refresh Permission Status") { permissions.refresh() }
            }

            Section("Sample Compositions") {
                ForEach(SampleCompositionLibrary.samples) { sample in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sample.title).font(.callout.weight(.semibold))
                            Text(sample.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Load") { pendingSample = sample }
                    }
                }
                if let supportMessage {
                    Text(supportMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 640, height: 780)
        .navigationTitle("Live Session")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .confirmationDialog(
            "Replace this composition with the sample?",
            isPresented: Binding(
                get: { pendingSample != nil },
                set: { if !$0 { pendingSample = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Load Sample", role: .destructive) { loadPendingSample() }
            Button("Cancel", role: .cancel) { pendingSample = nil }
        } message: {
            Text("Unsaved changes in the current composition will be replaced.")
        }
    }

    private var displayBinding: Binding<UInt32?> {
        Binding(
            get: { settings.outputDisplayID },
            set: { displayID in
                updateSettings { $0.outputDisplayID = displayID }
                restartFullscreenIfNeeded()
            }
        )
    }

    private var resolutionBinding: Binding<String> {
        Binding(
            get: { settings.outputResolution },
            set: { rawValue in
                updateSettings { $0.outputResolution = rawValue }
                fullscreen.update(
                    composition: document.composition,
                    assets: document.assets,
                    transport: transport,
                    resolution: LiveOutputResolution(rawValue: rawValue) ?? .fullHD
                )
            }
        )
    }

    private var oscPortBinding: Binding<Int> {
        Binding(
            get: { Int(settings.oscPort ?? 9_000) },
            set: { port in
                updateSettings { $0.oscPort = UInt16(clamping: min(max(port, 1), 65_535)) }
            }
        )
    }

    private var oscStatusDescription: String {
        switch liveControls.oscState {
        case .stopped: "Stopped"
        case .ready(let port): "Listening on UDP \(port)"
        case .failed(let message): message
        }
    }

    private var oscStatusIsFailure: Bool {
        if case .failed = liveControls.oscState { return true }
        return false
    }

    private func toggleFullscreen() {
        if fullscreen.isPresented {
            fullscreen.dismiss()
        } else {
            fullscreen.present(
                composition: document.composition,
                assets: document.assets,
                transport: transport,
                displayID: settings.outputDisplayID,
                resolution: resolution
            )
        }
    }

    private func restartFullscreenIfNeeded() {
        guard fullscreen.isPresented else { return }
        fullscreen.present(
            composition: document.composition,
            assets: document.assets,
            transport: transport,
            displayID: settings.outputDisplayID,
            resolution: resolution
        )
    }

    private func updateSettings(_ update: (inout LiveSessionSettings) -> Void) {
        var value = document
        var settings = value.composition.liveSession ?? .default
        update(&settings)
        value.composition.liveSession = settings
        touch(&value)
        document = value
    }

    private func parameterValue(_ parameter: PublishedParameterRecord) -> ParameterValue? {
        document.composition.node(id: parameter.nodeID)?.parameters[parameter.parameterKey]
    }

    private func setParameterValue(
        _ parameter: PublishedParameterRecord,
        _ newValue: ParameterValue
    ) {
        var value = document
        guard
            value.composition.updateNode(
                id: parameter.nodeID,
                { node in
                    node.parameters[parameter.parameterKey] = newValue
                })
        else { return }
        touch(&value)
        document = value
    }

    private func updatePublishedParameter(_ parameter: PublishedParameterRecord) {
        var value = document
        guard
            let index = value.composition.publishedParameters.firstIndex(where: {
                $0.id == parameter.id
            })
        else { return }
        value.composition.publishedParameters[index] = parameter
        touch(&value)
        document = value
    }

    private func addOSCMapping(for parameter: PublishedParameterRecord) {
        let address = OSCAddress.defaultAddress(for: parameter.name)
        guard
            !document.composition.controlMappings.contains(where: {
                $0.publishedParameterID == parameter.id && $0.source == .osc(address: address)
            })
        else { return }
        var value = document
        value.composition.controlMappings.append(
            ControlMappingRecord(
                id: UUID(),
                publishedParameterID: parameter.id,
                source: .osc(address: address),
                minimum: parameter.minimum ?? 0,
                maximum: parameter.maximum ?? 1
            )
        )
        touch(&value)
        document = value
    }

    private func updateControlMapping(_ mapping: ControlMappingRecord) {
        var value = document
        guard
            let index = value.composition.controlMappings.firstIndex(where: {
                $0.id == mapping.id
            })
        else { return }
        value.composition.controlMappings[index] = mapping
        touch(&value)
        document = value
    }

    private func removeControlMapping(_ id: UUID) {
        var value = document
        value.composition.controlMappings.removeAll { $0.id == id }
        touch(&value)
        document = value
    }

    private func removePublishedParameter(_ id: UUID) {
        var value = document
        value.composition.publishedParameters.removeAll { $0.id == id }
        value.composition.controlMappings.removeAll { $0.publishedParameterID == id }
        touch(&value)
        document = value
    }

    private func capturePreset() {
        var value = document
        let values = Dictionary(
            uniqueKeysWithValues: value.composition.publishedParameters.compactMap { parameter in
                parameterValue(parameter).map { (parameter.id, $0) }
            }
        )
        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        value.composition.presets.append(
            PresetRecord(
                id: UUID(),
                name: name.isEmpty ? "Preset \(value.composition.presets.count + 1)" : name,
                values: values
            )
        )
        presetName = ""
        touch(&value)
        document = value
    }

    private func applyPreset(_ preset: PresetRecord) {
        var value = document
        for parameter in value.composition.publishedParameters {
            guard let presetValue = preset.values[parameter.id] else { continue }
            _ = value.composition.updateNode(id: parameter.nodeID) { node in
                node.parameters[parameter.parameterKey] = presetValue
            }
        }
        touch(&value)
        document = value
    }

    private func removePreset(_ id: UUID) {
        var value = document
        value.composition.presets.removeAll { $0.id == id }
        touch(&value)
        document = value
    }

    private func saveRecovery() {
        do {
            _ = try ProjectRecoveryStore.save(document)
            recoveryMessage = "Recovery snapshot saved."
        } catch {
            ApplicationHealthStore.record(
                category: "recovery",
                message: "Could not save a recovery snapshot",
                error: error
            )
            recoveryMessage = error.localizedDescription
        }
    }

    private func restoreRecovery() {
        do {
            document = try ProjectRecoveryStore.load(
                compositionID: document.composition.metadata.id
            )
            recoveryMessage = "Recovery snapshot restored."
        } catch {
            ApplicationHealthStore.record(
                category: "recovery",
                message: "Could not restore a recovery snapshot",
                error: error
            )
            recoveryMessage = error.localizedDescription
        }
    }

    private func deleteRecovery() {
        do {
            try ProjectRecoveryStore.remove(
                compositionID: document.composition.metadata.id
            )
            recoveryMessage = "Recovery snapshot deleted."
        } catch {
            ApplicationHealthStore.record(
                category: "recovery",
                message: "Could not delete a recovery snapshot",
                error: error
            )
            recoveryMessage = error.localizedDescription
        }
    }

    private func loadPendingSample() {
        guard let sample = pendingSample else { return }
        pendingSample = nil
        document = sample.document
        supportMessage = "Loaded \(sample.title). Save As to keep it as a new .mquartz project."
    }

    private func exportDiagnosticReport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Metaliquartz-Diagnostics.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ApplicationHealthStore.exportDiagnosticReport(
                renderSnapshot: diagnostics.snapshot,
                to: url
            )
            supportMessage = "Diagnostic report exported."
        } catch {
            ApplicationHealthStore.record(
                category: "diagnostics",
                message: "Could not export the diagnostic report",
                error: error
            )
            supportMessage = error.localizedDescription
        }
    }

    private func nodeName(_ nodeID: NodeID) -> String {
        document.composition.node(id: nodeID)?.name ?? "Unknown Patch"
    }

    private func touch(_ document: inout CompositionDocument) {
        document.composition.metadata.modifiedAt = Date(
            timeIntervalSince1970: floor(Date().timeIntervalSince1970)
        )
    }
}

private struct PublishedParameterRow: View {
    let parameter: PublishedParameterRecord
    let value: ParameterValue?
    let mappings: [ControlMappingRecord]
    let midiSources: [MIDISourceDescriptor]
    let isLearningMIDI: Bool
    let onValueChange: (ParameterValue) -> Void
    let onRecordChange: (PublishedParameterRecord) -> Void
    let onToggleMIDILearn: () -> Void
    let onAddOSCMapping: () -> Void
    let onMappingChange: (ControlMappingRecord) -> Void
    let onRemoveMapping: (UUID) -> Void
    let onRemove: () -> Void

    var body: some View {
        DisclosureGroup {
            liveControl
            LabeledContent("Mapping Minimum") {
                TextField("", value: recordNumberBinding(\.minimum, fallback: 0), format: .number)
                    .frame(width: 90)
            }
            LabeledContent("Mapping Maximum") {
                TextField("", value: recordNumberBinding(\.maximum, fallback: 1), format: .number)
                    .frame(width: 90)
            }
            LabeledContent("Smoothing") {
                HStack {
                    Slider(value: smoothingBinding, in: 0...5)
                    Text("\(parameter.smoothing, format: .number.precision(.fractionLength(2))) s")
                        .monospacedDigit()
                        .frame(width: 55)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if isLearningMIDI {
                        Button("Cancel MIDI Learn") { onToggleMIDILearn() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("MIDI Learn") { onToggleMIDILearn() }
                            .buttonStyle(.bordered)
                    }
                    Button("Add Default OSC") { onAddOSCMapping() }
                        .disabled(
                            mappings.contains {
                                $0.source
                                    == .osc(address: OSCAddress.defaultAddress(for: parameter.name))
                            }
                        )
                }
                if isLearningMIDI {
                    Label("Move a CC, play a note, or move pitch bend.", systemImage: "waveform")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if mappings.isEmpty {
                    Text("Default OSC: \(OSCAddress.defaultAddress(for: parameter.name))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(mappings) { mapping in
                        ControlMappingEditorRow(
                            mapping: mapping,
                            midiSources: midiSources,
                            onChange: onMappingChange,
                            onRemove: { onRemoveMapping(mapping.id) }
                        )
                    }
                }
            }
            Button("Unpublish", role: .destructive, action: onRemove)
        } label: {
            Text(parameter.name)
        }
    }

    @ViewBuilder
    private var liveControl: some View {
        switch value {
        case .number(let number):
            HStack {
                Slider(
                    value: Binding(
                        get: { number },
                        set: { onValueChange(.number($0)) }
                    ),
                    in: (parameter.minimum ?? 0)...max(
                        parameter.maximum ?? 1,
                        (parameter.minimum ?? 0) + 0.000_1
                    )
                )
                Text(number, format: .number.precision(.fractionLength(3)))
                    .monospacedDigit()
                    .frame(width: 65)
            }
        case .boolean(let boolean):
            Toggle(
                "Value",
                isOn: Binding(
                    get: { boolean },
                    set: { onValueChange(.boolean($0)) }
                )
            )
        case .string(let string):
            TextField(
                "Value",
                text: Binding(
                    get: { string },
                    set: { onValueChange(.string($0)) }
                )
            )
        case .color(let red, let green, let blue, let alpha):
            ColorPicker(
                "Value",
                selection: Binding(
                    get: { Color(red: red, green: green, blue: blue, opacity: alpha) },
                    set: { color in
                        guard let converted = NSColor(color).usingColorSpace(.deviceRGB) else {
                            return
                        }
                        onValueChange(
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
        case nil:
            Text("Source parameter is unavailable.").foregroundStyle(.secondary)
        }
    }

    private func recordNumberBinding(
        _ keyPath: WritableKeyPath<PublishedParameterRecord, Double?>,
        fallback: Double
    ) -> Binding<Double> {
        Binding(
            get: { parameter[keyPath: keyPath] ?? fallback },
            set: { newValue in
                var copy = parameter
                copy[keyPath: keyPath] = newValue
                onRecordChange(copy)
            }
        )
    }

    private var smoothingBinding: Binding<Double> {
        Binding(
            get: { parameter.smoothing },
            set: { newValue in
                var copy = parameter
                copy.smoothing = newValue
                onRecordChange(copy)
            }
        )
    }
}

private struct ControlMappingEditorRow: View {
    let mapping: ControlMappingRecord
    let midiSources: [MIDISourceDescriptor]
    let onChange: (ControlMappingRecord) -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sourceEditor
                Spacer()
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            HStack {
                Text("Range").foregroundStyle(.secondary)
                TextField("Minimum", value: minimumBinding, format: .number)
                Text("…").foregroundStyle(.secondary)
                TextField("Maximum", value: maximumBinding, format: .number)
            }
            .textFieldStyle(.roundedBorder)
        }
        .font(.caption)
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder
    private var sourceEditor: some View {
        switch mapping.source {
        case .osc(let address):
            Label("OSC", systemImage: "network")
            TextField("/metaliquartz/parameter", text: oscAddressBinding(address))
                .textFieldStyle(.roundedBorder)
        case .midi(let deviceID, let channel, let controller):
            midiSourceEditors(deviceID: deviceID, channel: channel)
            Text("CC \(controller)").monospacedDigit()
        case .midiNote(let deviceID, let channel, let note):
            midiSourceEditors(deviceID: deviceID, channel: channel)
            Text("Note \(note)").monospacedDigit()
        case .midiPitchBend(let deviceID, let channel):
            midiSourceEditors(deviceID: deviceID, channel: channel)
            Text("Pitch Bend")
        }
    }

    private func midiSourceEditors(deviceID: String?, channel: Int?) -> some View {
        Group {
            Picker("Device", selection: midiDeviceBinding(deviceID: deviceID, channel: channel)) {
                Text("Any Device").tag(nil as String?)
                if let deviceID, !midiSources.contains(where: { $0.id == deviceID }) {
                    Text("Unavailable · \(deviceID)").tag(deviceID as String?)
                }
                ForEach(midiSources) { source in
                    Text(source.name).tag(source.id as String?)
                }
            }
            .labelsHidden()
            Picker("Channel", selection: midiChannelBinding(deviceID: deviceID, channel: channel)) {
                Text("Any Ch").tag(nil as Int?)
                ForEach(1...16, id: \.self) { channel in
                    Text("Ch \(channel)").tag(channel as Int?)
                }
            }
            .labelsHidden()
        }
    }

    private var minimumBinding: Binding<Double> {
        Binding(
            get: { mapping.minimum },
            set: { value in
                var copy = mapping
                copy.minimum = value
                onChange(copy)
            }
        )
    }

    private var maximumBinding: Binding<Double> {
        Binding(
            get: { mapping.maximum },
            set: { value in
                var copy = mapping
                copy.maximum = value
                onChange(copy)
            }
        )
    }

    private func oscAddressBinding(_ address: String) -> Binding<String> {
        Binding(
            get: { address },
            set: { value in
                var copy = mapping
                copy.source = .osc(address: value)
                onChange(copy)
            }
        )
    }

    private func midiDeviceBinding(deviceID: String?, channel: Int?) -> Binding<String?> {
        Binding(
            get: { deviceID },
            set: { deviceID in updateMIDIFilter(deviceID: deviceID, channel: channel) }
        )
    }

    private func midiChannelBinding(deviceID: String?, channel: Int?) -> Binding<Int?> {
        Binding(
            get: { channel },
            set: { channel in updateMIDIFilter(deviceID: deviceID, channel: channel) }
        )
    }

    private func updateMIDIFilter(deviceID: String?, channel: Int?) {
        var copy = mapping
        switch mapping.source {
        case .midi(_, _, let controller):
            copy.source = .midi(deviceID: deviceID, channel: channel, controller: controller)
        case .midiNote(_, _, let note):
            copy.source = .midiNote(deviceID: deviceID, channel: channel, note: note)
        case .midiPitchBend:
            copy.source = .midiPitchBend(deviceID: deviceID, channel: channel)
        case .osc:
            return
        }
        onChange(copy)
    }
}

private struct DiagnosticsGrid: View {
    let snapshot: RenderDiagnosticsSnapshot

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
            row(
                "Frame Rate",
                snapshot.framesPerSecond.formatted(
                    .number.precision(.fractionLength(1))
                ) + " fps"
            )
            row(
                "CPU Frame",
                snapshot.cpuFrameMilliseconds.formatted(
                    .number.precision(.fractionLength(2))
                ) + " ms"
            )
            row(
                "GPU Frame",
                snapshot.gpuFrameMilliseconds.formatted(
                    .number.precision(.fractionLength(2))
                ) + " ms"
            )
            row(
                "p95 Frame",
                snapshot.p95FrameMilliseconds.formatted(
                    .number.precision(.fractionLength(2))
                ) + " ms"
            )
            row(
                "Dropped",
                "\(snapshot.droppedFrames) / \(snapshot.totalFrames) ("
                    + snapshot.droppedFramePercentage.formatted(
                        .number.precision(.fractionLength(2))
                    ) + "%)"
            )
            row(
                "Texture Pool",
                "\(snapshot.texturePool.inUse) in use · \(snapshot.texturePool.available) cached"
            )
        }
        .font(.caption.monospacedDigit())
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}
