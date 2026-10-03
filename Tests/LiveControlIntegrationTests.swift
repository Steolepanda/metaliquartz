import XCTest

@testable import Metaliquartz

@MainActor
final class LiveControlIntegrationTests: XCTestCase {
    func testMIDIControlMapsNormalizedValueIntoPersistedRange() throws {
        let fixture = makeNumberFixture(value: 0, range: -2...2)
        var composition = fixture.composition
        composition.controlMappings = [
            ControlMappingRecord(
                id: UUID(),
                publishedParameterID: fixture.parameter.id,
                source: .midi(deviceID: "controller", channel: 2, controller: 10),
                minimum: -2,
                maximum: 2
            )
        ]
        let controller = LiveControlController()
        controller.configure(composition: composition)
        controller.receive(
            MIDIInputEvent(
                source: MIDISourceDescriptor(id: "controller", name: "Controller"),
                channel: 2,
                message: .controlChange(controller: 10, value: 127)
            )
        )

        let action = try XCTUnwrap(controller.drainActions().first)
        guard case .setParameter(let parameterID, let value) = action else {
            return XCTFail("Expected a parameter update")
        }
        XCTAssertEqual(parameterID, fixture.parameter.id)
        XCTAssertEqual(value, .number(2))
    }

    func testMIDILearnCapturesCCNoteAndPitchBendSources() throws {
        for message in [
            MIDIInputMessage.controlChange(controller: 74, value: 64),
            .note(note: 60, velocity: 100),
            .pitchBend(value: 8_192),
        ] {
            let fixture = makeNumberFixture(value: 0, range: 0...1)
            let controller = LiveControlController()
            controller.configure(composition: fixture.composition)
            controller.toggleMIDILearn(for: fixture.parameter.id)
            let event = MIDIInputEvent(
                source: MIDISourceDescriptor(id: "learn", name: "Learn Device"),
                channel: 6,
                message: message
            )
            controller.receive(event)

            let actions = controller.drainActions()
            guard case .learnedMapping(let parameterID, let source) = actions.first else {
                return XCTFail("Expected MIDI Learn to create a mapping")
            }
            XCTAssertEqual(parameterID, fixture.parameter.id)
            XCTAssertEqual(source, event.mappingSource)
            XCTAssertNil(controller.learningPublishedParameterID)
        }
    }

    func testOSCDefaultAddressAppliesNumbersBooleansAndStrings() throws {
        var composition = CompositionFile.empty()
        var node = NodeRecord(patchType: "test.live", name: "Live")
        node.parameters = [
            "number": .number(0),
            "boolean": .boolean(false),
            "string": .string("before"),
        ]
        composition.graph.nodes = [node]
        let parameters = [
            PublishedParameterRecord(
                id: UUID(),
                name: "Amount",
                nodeID: node.id,
                parameterKey: "number",
                minimum: 0,
                maximum: 10,
                smoothing: 0
            ),
            PublishedParameterRecord(
                id: UUID(),
                name: "Enabled",
                nodeID: node.id,
                parameterKey: "boolean",
                minimum: nil,
                maximum: nil,
                smoothing: 0
            ),
            PublishedParameterRecord(
                id: UUID(),
                name: "Label",
                nodeID: node.id,
                parameterKey: "string",
                minimum: nil,
                maximum: nil,
                smoothing: 0
            ),
        ]
        composition.publishedParameters = parameters
        let controller = LiveControlController()
        controller.configure(composition: composition)

        controller.receive(scheduled(address: "/metaliquartz/amount", argument: .float32(0.25)))
        controller.receive(scheduled(address: "/metaliquartz/enabled", argument: .boolean(true)))
        controller.receive(scheduled(address: "/metaliquartz/label", argument: .string("after")))

        let values: [UUID: ParameterValue] = Dictionary(
            uniqueKeysWithValues: controller.drainActions().compactMap { action in
                guard case .setParameter(let id, let value) = action else { return nil }
                return (id, value)
            }
        )
        XCTAssertEqual(values[parameters[0].id], .number(2.5))
        XCTAssertEqual(values[parameters[1].id], .boolean(true))
        XCTAssertEqual(values[parameters[2].id], .string("after"))
    }

    func testSmoothingAdvancesTowardLatestControlTarget() throws {
        var fixture = makeNumberFixture(value: 0, range: 0...1)
        fixture.composition.publishedParameters[0].smoothing = 1
        fixture.composition.controlMappings = [
            ControlMappingRecord(
                id: UUID(),
                publishedParameterID: fixture.parameter.id,
                source: .midi(deviceID: nil, channel: nil, controller: 1),
                minimum: 0,
                maximum: 1
            )
        ]
        let controller = LiveControlController()
        controller.configure(composition: fixture.composition)
        controller.receive(
            MIDIInputEvent(
                source: MIDISourceDescriptor(id: "any", name: "Any"),
                channel: 1,
                message: .controlChange(controller: 1, value: 127)
            )
        )
        XCTAssertTrue(controller.drainActions().isEmpty)
        controller.advanceSmoothing(by: 0.1)

        let action = try XCTUnwrap(controller.drainActions().first)
        guard case .setParameter(_, .number(let value)) = action else {
            return XCTFail("Expected a smoothed number")
        }
        XCTAssertGreaterThan(value, 0)
        XCTAssertLessThan(value, 1)
    }

    func testMappingsAndOSCSettingsRoundTripInCompositionPackageJSON() throws {
        var fixture = makeNumberFixture(value: 0, range: 0...1)
        fixture.composition.liveSession?.oscPort = 9_100
        fixture.composition.controlMappings = [
            ControlMappingRecord(
                id: UUID(),
                publishedParameterID: fixture.parameter.id,
                source: .midiNote(deviceID: nil, channel: 3, note: 48),
                minimum: 0,
                maximum: 1
            ),
            ControlMappingRecord(
                id: UUID(),
                publishedParameterID: fixture.parameter.id,
                source: .midiPitchBend(deviceID: "wheel", channel: nil),
                minimum: -1,
                maximum: 1
            ),
            ControlMappingRecord(
                id: UUID(),
                publishedParameterID: fixture.parameter.id,
                source: .osc(address: "/metaliquartz/amount"),
                minimum: 0,
                maximum: 1
            ),
        ]

        let reopened = try CompositionCodec.decode(CompositionCodec.encode(fixture.composition))
        XCTAssertEqual(reopened.controlMappings, fixture.composition.controlMappings)
        XCTAssertEqual(reopened.liveSession?.oscPort, 9_100)
    }

    private func makeNumberFixture(
        value: Double,
        range: ClosedRange<Double>
    ) -> (composition: CompositionFile, parameter: PublishedParameterRecord) {
        var composition = CompositionFile.empty()
        var node = NodeRecord(patchType: "test.number", name: "Number")
        node.parameters["value"] = .number(value)
        composition.graph.nodes = [node]
        let parameter = PublishedParameterRecord(
            id: UUID(),
            name: "Amount",
            nodeID: node.id,
            parameterKey: "value",
            minimum: range.lowerBound,
            maximum: range.upperBound,
            smoothing: 0
        )
        composition.publishedParameters = [parameter]
        return (composition, parameter)
    }

    private func scheduled(address: String, argument: OSCArgument) -> OSCScheduledMessage {
        OSCScheduledMessage(
            message: OSCMessage(addressPattern: address, arguments: [argument]),
            timeTag: nil
        )
    }
}
