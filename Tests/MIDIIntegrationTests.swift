import CoreMIDI
import XCTest

@testable import Metaliquartz

final class MIDIIntegrationTests: XCTestCase {
    func testParsesMIDI1ChannelVoiceUMPWords() throws {
        let source = MIDISourceDescriptor(id: "device", name: "Controller")

        let cc = try XCTUnwrap(
            MIDI1MessageParser.event(
                umpWord: ump(status: 0xb2, data1: 74, data2: 127),
                source: source
            )
        )
        XCTAssertEqual(cc.channel, 3)
        XCTAssertEqual(cc.message, .controlChange(controller: 74, value: 127))
        XCTAssertEqual(cc.normalizedValue, 1)

        XCTAssertEqual(
            MIDI1MessageParser.event(
                umpWord: ump(status: 0x90, data1: 60, data2: 96),
                source: source
            )?.message,
            .note(note: 60, velocity: 96)
        )
        XCTAssertEqual(
            MIDI1MessageParser.event(
                umpWord: ump(status: 0x80, data1: 60, data2: 64),
                source: source
            )?.message,
            .note(note: 60, velocity: 0)
        )
        XCTAssertEqual(
            MIDI1MessageParser.event(
                umpWord: ump(status: 0xe0, data1: 0, data2: 64),
                source: source
            )?.message,
            .pitchBend(value: 8_192)
        )
        XCTAssertNil(
            MIDI1MessageParser.event(
                umpWord: ump(status: 0xa0, data1: 60, data2: 1),
                source: source
            )
        )
    }

    func testMIDIMappingsApplyDeviceChannelAndMessageFilters() {
        let source = MIDISourceDescriptor(id: "one", name: "Controller")
        let cc = MIDIInputEvent(
            source: source,
            channel: 4,
            message: .controlChange(controller: 7, value: 100)
        )
        XCTAssertTrue(
            ControlMappingRecord.Source.midi(deviceID: "one", channel: 4, controller: 7)
                .matches(cc)
        )
        XCTAssertTrue(
            ControlMappingRecord.Source.midi(deviceID: nil, channel: nil, controller: 7)
                .matches(cc)
        )
        XCTAssertFalse(
            ControlMappingRecord.Source.midi(deviceID: "two", channel: 4, controller: 7)
                .matches(cc)
        )
        XCTAssertFalse(
            ControlMappingRecord.Source.midi(deviceID: "one", channel: 3, controller: 7)
                .matches(cc)
        )
    }

    func testVirtualMIDISourceConnectsAndDeliversWithoutRestartingGraph() throws {
        let uniqueID = Int32.random(in: 100_000_000...2_000_000_000)
        let initialScan = expectation(description: "initial MIDI source scan")
        initialScan.assertForOverFulfill = false
        let connected = expectation(description: "virtual source connected after service start")
        connected.assertForOverFulfill = false
        let received = expectation(description: "virtual MIDI event received")
        let service = MIDIInputService(
            eventHandler: { event in
                guard event.source.id == String(uniqueID) else { return }
                XCTAssertEqual(event.channel, 1)
                XCTAssertEqual(event.message, .controlChange(controller: 21, value: 99))
                received.fulfill()
            },
            sourcesHandler: { sources in
                initialScan.fulfill()
                if sources.contains(where: { $0.id == String(uniqueID) }) {
                    connected.fulfill()
                }
            }
        )
        try service.start()
        wait(for: [initialScan], timeout: 3)

        var client = MIDIClientRef()
        XCTAssertEqual(
            MIDIClientCreate("Metaliquartz Virtual MIDI Tests" as CFString, nil, nil, &client),
            noErr
        )

        let sourceName = "Metaliquartz Virtual \(UUID().uuidString)"
        var source = MIDIEndpointRef()
        XCTAssertEqual(
            MIDISourceCreateWithProtocol(client, sourceName as CFString, ._1_0, &source),
            noErr
        )
        defer {
            service.stop()
            MIDIEndpointDispose(source)
            MIDIClientDispose(client)
        }
        XCTAssertEqual(MIDIObjectSetIntegerProperty(source, kMIDIPropertyUniqueID, uniqueID), noErr)

        wait(for: [connected], timeout: 3)

        let bufferSize = 256
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferSize,
            alignment: MemoryLayout<MIDIEventList>.alignment
        )
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: bufferSize)
        let eventList = buffer.assumingMemoryBound(to: MIDIEventList.self)
        let firstPacket = try XCTUnwrap(MIDIEventListInit(eventList, ._1_0))
        var word = ump(status: 0xb0, data1: 21, data2: 99)
        XCTAssertNotNil(
            MIDIEventListAdd(
                eventList,
                bufferSize,
                firstPacket,
                mach_absolute_time(),
                1,
                &word
            )
        )
        XCTAssertEqual(MIDIReceivedEventList(source, eventList), noErr)
        wait(for: [received], timeout: 3)
    }

    private func ump(status: UInt32, data1: UInt32, data2: UInt32) -> UInt32 {
        (0x2 << 28) | (status << 16) | (data1 << 8) | data2
    }
}
