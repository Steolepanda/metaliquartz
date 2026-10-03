import CoreMIDI
import Foundation

struct MIDISourceDescriptor: Identifiable, Equatable, Hashable, Sendable {
    var id: String
    var name: String
}

enum MIDIInputMessage: Equatable, Sendable {
    case controlChange(controller: Int, value: Int)
    case note(note: Int, velocity: Int)
    case pitchBend(value: Int)
}

struct MIDIInputEvent: Equatable, Sendable {
    var source: MIDISourceDescriptor
    var channel: Int
    var message: MIDIInputMessage

    var normalizedValue: Double {
        switch message {
        case .controlChange(_, let value), .note(_, let value):
            Double(value) / 127
        case .pitchBend(let value):
            Double(value) / 16_383
        }
    }

    var mappingSource: ControlMappingRecord.Source {
        switch message {
        case .controlChange(let controller, _):
            .midi(deviceID: source.id, channel: channel, controller: controller)
        case .note(let note, _):
            .midiNote(deviceID: source.id, channel: channel, note: note)
        case .pitchBend:
            .midiPitchBend(deviceID: source.id, channel: channel)
        }
    }
}

enum MIDI1MessageParser {
    static func event(
        umpWord: UInt32,
        source: MIDISourceDescriptor
    ) -> MIDIInputEvent? {
        guard (umpWord >> 28) == 0x2 else { return nil }
        let status = Int((umpWord >> 16) & 0xff)
        let channel = (status & 0x0f) + 1
        let data1 = Int((umpWord >> 8) & 0x7f)
        let data2 = Int(umpWord & 0x7f)
        let message: MIDIInputMessage
        switch status & 0xf0 {
        case 0x80:
            message = .note(note: data1, velocity: 0)
        case 0x90:
            message = .note(note: data1, velocity: data2)
        case 0xb0:
            message = .controlChange(controller: data1, value: data2)
        case 0xe0:
            message = .pitchBend(value: data1 | (data2 << 7))
        default:
            return nil
        }
        return MIDIInputEvent(source: source, channel: channel, message: message)
    }
}

struct CoreMIDIServiceError: LocalizedError {
    var operation: String
    var status: OSStatus

    var errorDescription: String? {
        "\(operation) failed with CoreMIDI status \(status)."
    }
}

final class MIDIInputService: @unchecked Sendable {
    typealias EventHandler = @Sendable (MIDIInputEvent) -> Void
    typealias SourcesHandler = @Sendable ([MIDISourceDescriptor]) -> Void

    private final class SourceContext {
        let descriptor: MIDISourceDescriptor

        init(descriptor: MIDISourceDescriptor) {
            self.descriptor = descriptor
        }
    }

    private let eventHandler: EventHandler
    private let sourcesHandler: SourcesHandler
    private let queue = DispatchQueue(label: "com.steolepanda.Metaliquartz.midi-input")
    private let stateLock = NSLock()
    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var sourceContexts: [MIDIEndpointRef: UnsafeMutableRawPointer] = [:]
    private var retiredContexts: [UnsafeMutableRawPointer] = []
    private var isStarted = false

    init(
        eventHandler: @escaping EventHandler,
        sourcesHandler: @escaping SourcesHandler = { _ in }
    ) {
        self.eventHandler = eventHandler
        self.sourcesHandler = sourcesHandler
    }

    func start() throws {
        stateLock.lock()
        let alreadyStarted = isStarted
        stateLock.unlock()
        guard !alreadyStarted else { return }
        var client = MIDIClientRef()
        let clientStatus = MIDIClientCreateWithBlock(
            "Metaliquartz MIDI" as CFString,
            &client
        ) { [weak self] _ in
            guard let service = self else { return }
            service.queue.async { service.refreshSources() }
        }
        guard clientStatus == noErr else {
            throw CoreMIDIServiceError(operation: "Creating the MIDI client", status: clientStatus)
        }
        var inputPort = MIDIPortRef()
        let portStatus = MIDIInputPortCreateWithProtocol(
            client,
            "Metaliquartz MIDI Input" as CFString,
            ._1_0,
            &inputPort
        ) { [weak self] eventList, sourceContext in
            self?.receive(eventList: eventList, sourceContext: sourceContext)
        }
        guard portStatus == noErr else {
            MIDIClientDispose(client)
            self.client = MIDIClientRef()
            throw CoreMIDIServiceError(
                operation: "Creating the MIDI input port", status: portStatus)
        }
        stateLock.lock()
        self.client = client
        self.inputPort = inputPort
        isStarted = true
        stateLock.unlock()
        queue.async { [weak self] in self?.refreshSources() }
    }

    func stop() {
        stateLock.lock()
        guard isStarted else {
            stateLock.unlock()
            return
        }
        isStarted = false
        let portToDispose = inputPort
        let clientToDispose = client
        inputPort = MIDIPortRef()
        client = MIDIClientRef()
        let contexts = Array(sourceContexts.values) + retiredContexts
        sourceContexts.removeAll()
        retiredContexts.removeAll()
        stateLock.unlock()
        if portToDispose != 0 { MIDIPortDispose(portToDispose) }
        if clientToDispose != 0 { MIDIClientDispose(clientToDispose) }
        for context in contexts {
            Unmanaged<SourceContext>.fromOpaque(context).release()
        }
        sourcesHandler([])
    }

    deinit {
        stop()
    }

    private func refreshSources() {
        stateLock.lock()
        guard isStarted else {
            stateLock.unlock()
            return
        }
        let available = Self.availableSources()
        let endpoints = Set(available.map(\.endpoint))

        let disconnected = sourceContexts.filter { !endpoints.contains($0.key) }
        for (endpoint, context) in disconnected {
            MIDIPortDisconnectSource(inputPort, endpoint)
            sourceContexts.removeValue(forKey: endpoint)
            retiredContexts.append(context)
        }

        for source in available where sourceContexts[source.endpoint] == nil {
            let context = Unmanaged.passRetained(SourceContext(descriptor: source.descriptor))
            let pointer = context.toOpaque()
            let status = MIDIPortConnectSource(inputPort, source.endpoint, pointer)
            if status == noErr {
                sourceContexts[source.endpoint] = pointer
            } else {
                context.release()
            }
        }
        let descriptors = available.map(\.descriptor)
        stateLock.unlock()
        sourcesHandler(descriptors)
    }

    private func receive(
        eventList: UnsafePointer<MIDIEventList>,
        sourceContext: UnsafeMutableRawPointer?
    ) {
        stateLock.lock()
        guard isStarted else {
            stateLock.unlock()
            return
        }
        defer { stateLock.unlock() }
        guard let sourceContext else { return }
        let source = Unmanaged<SourceContext>.fromOpaque(sourceContext)
            .takeUnretainedValue().descriptor
        let events = Self.events(in: eventList, source: source)
        guard !events.isEmpty else { return }
        queue.async { [weak self] in self?.deliver(events) }
    }

    private func deliver(_ events: [MIDIInputEvent]) {
        stateLock.lock()
        let shouldDeliver = isStarted
        stateLock.unlock()
        guard shouldDeliver else { return }
        for event in events { eventHandler(event) }
    }

    private static func events(
        in eventList: UnsafePointer<MIDIEventList>,
        source: MIDISourceDescriptor
    ) -> [MIDIInputEvent] {
        var events: [MIDIInputEvent] = []
        withUnsafePointer(to: eventList.pointee.packet) { firstPacket in
            var packet = UnsafeMutablePointer(mutating: firstPacket)
            for _ in 0..<eventList.pointee.numPackets {
                let wordCount = Int(packet.pointee.wordCount)
                withUnsafePointer(to: packet.pointee.words) { words in
                    words.withMemoryRebound(to: UInt32.self, capacity: wordCount) { words in
                        for index in 0..<wordCount {
                            if let event = MIDI1MessageParser.event(
                                umpWord: words[index],
                                source: source
                            ) {
                                events.append(event)
                            }
                        }
                    }
                }
                packet = MIDIEventPacketNext(packet)
            }
        }
        return events
    }

    private struct AvailableSource {
        var endpoint: MIDIEndpointRef
        var descriptor: MIDISourceDescriptor
    }

    private static func availableSources() -> [AvailableSource] {
        (0..<MIDIGetNumberOfSources()).compactMap { index in
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0 else { return nil }
            let uniqueID = integerProperty(kMIDIPropertyUniqueID, of: endpoint)
            let id = uniqueID == 0 ? "endpoint-\(endpoint)" : String(uniqueID)
            let name =
                stringProperty(kMIDIPropertyDisplayName, of: endpoint)
                ?? stringProperty(kMIDIPropertyName, of: endpoint)
                ?? "MIDI Source \(index + 1)"
            return AvailableSource(
                endpoint: endpoint,
                descriptor: MIDISourceDescriptor(id: id, name: name)
            )
        }
        .sorted {
            $0.descriptor.name.localizedStandardCompare($1.descriptor.name) == .orderedAscending
        }
    }

    private static func integerProperty(
        _ property: CFString,
        of object: MIDIObjectRef
    ) -> Int32 {
        var value: Int32 = 0
        guard MIDIObjectGetIntegerProperty(object, property, &value) == noErr else { return 0 }
        return value
    }

    private static func stringProperty(
        _ property: CFString,
        of object: MIDIObjectRef
    ) -> String? {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, property, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
