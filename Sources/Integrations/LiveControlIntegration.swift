import Foundation
import Observation

enum LiveControlAction: Sendable {
    case setParameter(publishedParameterID: UUID, value: ParameterValue)
    case learnedMapping(
        publishedParameterID: UUID,
        source: ControlMappingRecord.Source
    )
}

@MainActor
@Observable
final class LiveControlController {
    private enum InputValue {
        case scalar(Double)
        case boolean(Bool)
        case string(String)
    }

    private struct ScalarTarget {
        var value: Double
        var parameter: PublishedParameterRecord
    }

    private(set) var midiSources: [MIDISourceDescriptor] = []
    private(set) var midiError: String?
    private(set) var oscState: OSCUDPServerState = .stopped
    private(set) var lastInputDescription: String?
    private(set) var actionRevision = 0
    private(set) var learningPublishedParameterID: UUID?

    private var composition = CompositionFile.empty()
    private var currentValues: [UUID: ParameterValue] = [:]
    private var scalarTargets: [UUID: ScalarTarget] = [:]
    private var pendingActions: [LiveControlAction] = []
    private var midiService: MIDIInputService?
    private var oscServer: OSCUDPServer?
    private var oscRetry: Task<Void, Never>?
    private var activeOSCPort: UInt16?
    private var ticker: Task<Void, Never>?
    private var isStarted = false
    private var lastTick = ContinuousClock.now

    func start(composition: CompositionFile) {
        configure(composition: composition)
        guard !isStarted else { return }
        isStarted = true
        startMIDI()
        restartOSCIfNeeded()
        lastTick = .now
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        ticker?.cancel()
        ticker = nil
        midiService?.stop()
        midiService = nil
        oscServer?.stop()
        oscServer = nil
        oscRetry?.cancel()
        oscRetry = nil
        activeOSCPort = nil
        oscState = .stopped
        midiSources = []
        learningPublishedParameterID = nil
        scalarTargets.removeAll()
    }

    func configure(composition: CompositionFile) {
        self.composition = composition
        currentValues = Dictionary(
            uniqueKeysWithValues: composition.publishedParameters.compactMap { parameter in
                composition.node(id: parameter.nodeID)?.parameters[parameter.parameterKey]
                    .map { (parameter.id, $0) }
            }
        )
        let validParameterIDs = Set(composition.publishedParameters.map(\.id))
        scalarTargets = scalarTargets.filter { validParameterIDs.contains($0.key) }
        if let learningPublishedParameterID,
            !validParameterIDs.contains(learningPublishedParameterID)
        {
            self.learningPublishedParameterID = nil
        }
        if isStarted { restartOSCIfNeeded() }
    }

    func toggleMIDILearn(for publishedParameterID: UUID) {
        if learningPublishedParameterID == publishedParameterID {
            learningPublishedParameterID = nil
        } else {
            learningPublishedParameterID = publishedParameterID
        }
    }

    func drainActions() -> [LiveControlAction] {
        defer { pendingActions.removeAll(keepingCapacity: true) }
        return pendingActions
    }

    func advanceSmoothing(by deltaTime: Double) {
        advanceScalarTargets(deltaTime: max(0, deltaTime))
    }

    private func startMIDI() {
        let service = MIDIInputService(
            eventHandler: { [weak self] event in
                Task { @MainActor [weak self] in self?.receive(event) }
            },
            sourcesHandler: { [weak self] sources in
                Task { @MainActor [weak self] in self?.midiSources = sources }
            }
        )
        do {
            try service.start()
            midiService = service
            midiError = nil
        } catch {
            midiError = error.localizedDescription
        }
    }

    private func restartOSCIfNeeded() {
        let requestedPort = composition.liveSession?.oscPort ?? 9_000
        guard activeOSCPort != requestedPort else { return }
        oscServer?.stop()
        let server = OSCUDPServer(
            port: requestedPort,
            messageHandler: { [weak self] message in
                Task { @MainActor [weak self] in self?.receive(message) }
            },
            stateHandler: { [weak self] state in
                Task { @MainActor [weak self] in self?.updateOSCState(state) }
            }
        )
        do {
            try server.start()
            oscServer = server
            activeOSCPort = requestedPort
        } catch {
            oscServer = nil
            activeOSCPort = nil
            oscState = .failed(error.localizedDescription)
        }
    }

    private func updateOSCState(_ state: OSCUDPServerState) {
        oscState = state
        guard case .failed = state, isStarted else { return }
        oscServer = nil
        activeOSCPort = nil
        oscRetry?.cancel()
        oscRetry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.restartOSCIfNeeded()
        }
    }

    func receive(_ event: MIDIInputEvent) {
        lastInputDescription = event.description(midiSources: midiSources)
        if let learningID = learningPublishedParameterID,
            let parameter = publishedParameter(id: learningID)
        {
            learningPublishedParameterID = nil
            enqueue(
                .learnedMapping(
                    publishedParameterID: learningID,
                    source: event.mappingSource
                )
            )
            let temporaryMapping = ControlMappingRecord(
                id: UUID(),
                publishedParameterID: learningID,
                source: event.mappingSource,
                minimum: parameter.minimum ?? 0,
                maximum: parameter.maximum ?? 1
            )
            apply(.scalar(event.normalizedValue), through: temporaryMapping, to: parameter)
            return
        }

        for mapping in composition.controlMappings where mapping.source.matches(event) {
            guard let parameter = publishedParameter(id: mapping.publishedParameterID) else {
                continue
            }
            apply(.scalar(event.normalizedValue), through: mapping, to: parameter)
        }
    }

    func receive(_ scheduledMessage: OSCScheduledMessage) {
        let message = scheduledMessage.message
        lastInputDescription = "OSC \(message.addressPattern)"
        guard let argument = message.arguments.first else { return }
        let input: InputValue
        switch argument {
        case .int32(let value): input = .scalar(Double(value))
        case .float32(let value): input = .scalar(Double(value))
        case .string(let value): input = .string(value)
        case .boolean(let value): input = .boolean(value)
        }

        for parameter in composition.publishedParameters {
            let oscMappings = composition.controlMappings.filter {
                $0.publishedParameterID == parameter.id && $0.source.isOSC
            }
            if oscMappings.isEmpty {
                let address = OSCAddress.defaultAddress(for: parameter.name)
                guard OSCAddress.pattern(message.addressPattern, matches: address) else { continue }
                let mapping = ControlMappingRecord(
                    id: UUID(),
                    publishedParameterID: parameter.id,
                    source: .osc(address: address),
                    minimum: parameter.minimum ?? 0,
                    maximum: parameter.maximum ?? 1
                )
                apply(input, through: mapping, to: parameter)
            } else {
                for mapping in oscMappings where mapping.source.matches(message) {
                    apply(input, through: mapping, to: parameter)
                }
            }
        }
    }

    private func apply(
        _ input: InputValue,
        through mapping: ControlMappingRecord,
        to parameter: PublishedParameterRecord
    ) {
        guard let currentValue = currentValues[parameter.id] else { return }
        switch (currentValue, input) {
        case (.number, .scalar(let normalizedValue)):
            let normalizedValue = min(max(normalizedValue, 0), 1)
            let mappedValue =
                mapping.minimum + normalizedValue * (mapping.maximum - mapping.minimum)
            if parameter.smoothing > 0 {
                scalarTargets[parameter.id] = ScalarTarget(
                    value: mappedValue,
                    parameter: parameter
                )
            } else {
                currentValues[parameter.id] = .number(mappedValue)
                enqueue(
                    .setParameter(
                        publishedParameterID: parameter.id,
                        value: .number(mappedValue)
                    )
                )
            }
        case (.number, .boolean(let value)):
            apply(.scalar(value ? 1 : 0), through: mapping, to: parameter)
        case (.boolean, .scalar(let value)):
            let mapped = value >= 0.5
            currentValues[parameter.id] = .boolean(mapped)
            enqueue(.setParameter(publishedParameterID: parameter.id, value: .boolean(mapped)))
        case (.boolean, .boolean(let value)):
            currentValues[parameter.id] = .boolean(value)
            enqueue(.setParameter(publishedParameterID: parameter.id, value: .boolean(value)))
        case (.string, .string(let value)):
            currentValues[parameter.id] = .string(value)
            enqueue(.setParameter(publishedParameterID: parameter.id, value: .string(value)))
        default:
            break
        }
    }

    private func tick() {
        let now = ContinuousClock.now
        let delta = max(0, lastTick.duration(to: now).seconds)
        lastTick = now
        advanceScalarTargets(deltaTime: delta)
    }

    private func advanceScalarTargets(deltaTime: Double) {
        for (parameterID, target) in Array(scalarTargets) {
            guard case .number(let current) = currentValues[parameterID] else {
                scalarTargets.removeValue(forKey: parameterID)
                continue
            }
            let response = max(0.001, target.parameter.smoothing)
            let alpha = 1 - exp(-deltaTime / response)
            var value = current + (target.value - current) * alpha
            if abs(value - target.value) < 0.000_1 {
                value = target.value
                scalarTargets.removeValue(forKey: parameterID)
            }
            currentValues[parameterID] = .number(value)
            enqueue(
                .setParameter(
                    publishedParameterID: parameterID,
                    value: .number(value)
                )
            )
        }
    }

    private func publishedParameter(id: UUID) -> PublishedParameterRecord? {
        composition.publishedParameters.first { $0.id == id }
    }

    private func enqueue(_ action: LiveControlAction) {
        pendingActions.append(action)
        actionRevision &+= 1
    }
}

extension ControlMappingRecord.Source {
    var isMIDI: Bool {
        switch self {
        case .midi, .midiNote, .midiPitchBend: true
        case .osc: false
        }
    }

    var isOSC: Bool { !isMIDI }

    func matches(_ event: MIDIInputEvent) -> Bool {
        switch (self, event.message) {
        case (
            .midi(let deviceID, let channel, let controller),
            .controlChange(let incomingController, _)
        ):
            matches(deviceID: deviceID, channel: channel, event: event)
                && controller == incomingController
        case (
            .midiNote(let deviceID, let channel, let note),
            .note(let incomingNote, _)
        ):
            matches(deviceID: deviceID, channel: channel, event: event)
                && note == incomingNote
        case (
            .midiPitchBend(let deviceID, let channel),
            .pitchBend
        ):
            matches(deviceID: deviceID, channel: channel, event: event)
        default:
            false
        }
    }

    func matches(_ message: OSCMessage) -> Bool {
        guard case .osc(let address) = self else { return false }
        return OSCAddress.pattern(message.addressPattern, matches: address)
    }

    private func matches(
        deviceID: String?,
        channel: Int?,
        event: MIDIInputEvent
    ) -> Bool {
        (deviceID == nil || deviceID == event.source.id)
            && (channel == nil || channel == event.channel)
    }
}

extension MIDIInputEvent {
    fileprivate func description(midiSources: [MIDISourceDescriptor]) -> String {
        let sourceName = midiSources.first { $0.id == source.id }?.name ?? source.name
        let detail: String
        switch message {
        case .controlChange(let controller, _): detail = "CC \(controller)"
        case .note(let note, _): detail = "Note \(note)"
        case .pitchBend: detail = "Pitch Bend"
        }
        return "\(sourceName) · Ch \(channel) · \(detail)"
    }
}

extension Duration {
    fileprivate var seconds: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
