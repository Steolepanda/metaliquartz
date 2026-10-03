import Network
import XCTest

@testable import Metaliquartz

final class OSCIntegrationTests: XCTestCase {
    func testDecodesRequiredOSC10ArgumentTypes() throws {
        let packet = message(
            address: "/metaliquartz/test",
            tags: "ifsTF",
            arguments: [
                int32(-42),
                uint32(Float(0.625).bitPattern),
                oscString("hello"),
            ]
        )

        let decoded = try XCTUnwrap(OSCPacketDecoder.decode(packet).first)
        XCTAssertEqual(decoded.message.addressPattern, "/metaliquartz/test")
        XCTAssertEqual(
            decoded.message.arguments,
            [.int32(-42), .float32(0.625), .string("hello"), .boolean(true), .boolean(false)]
        )
        XCTAssertNil(decoded.timeTag)
    }

    func testDecodesOrderedNestedBundlesAndDiscardsUnknownSiblingTypes() throws {
        let first = message(address: "/one", tags: "i", arguments: [int32(1)])
        let unknown = message(
            address: "/discard", tags: "d", arguments: [Data(repeating: 0, count: 8)])
        let nested = bundle(timeTag: 12, elements: [message(address: "/two", tags: "T")])
        let decoded = try OSCPacketDecoder.decode(
            bundle(timeTag: 10, elements: [first, unknown, nested])
        )

        XCTAssertEqual(decoded.map(\.message.addressPattern), ["/one", "/two"])
        XCTAssertEqual(decoded.map(\.timeTag?.rawValue), [10, 12])
    }

    func testRejectsMalformedPacketsAndBackwardsNestedTimeTags() {
        XCTAssertThrowsError(try OSCPacketDecoder.decode(Data([0, 1, 2])))
        XCTAssertThrowsError(
            try OSCPacketDecoder.decode(
                bundle(
                    timeTag: 20,
                    elements: [
                        bundle(timeTag: 19, elements: [message(address: "/late", tags: "F")])
                    ]
                )
            )
        ) { error in
            XCTAssertEqual(error as? OSCDecodingError, .invalidBundleTimeTag)
        }
        XCTAssertThrowsError(
            try OSCPacketDecoder.decode(message(address: "/unsupported", tags: "b"))
        ) { error in
            XCTAssertEqual(error as? OSCDecodingError, .invalidTypeTag("b"))
        }
    }

    func testDefaultAddressesAndOSCAddressPatterns() {
        XCTAssertEqual(
            OSCAddress.defaultAddress(for: "Glow · Intensity"),
            "/metaliquartz/glow-intensity"
        )
        XCTAssertTrue(OSCAddress.isValidMethodAddress("/metaliquartz/glow-intensity"))
        XCTAssertFalse(OSCAddress.isValidMethodAddress("/metaliquartz/bad name"))
        XCTAssertTrue(OSCAddress.pattern("/metaliquartz/*", matches: "/metaliquartz/glow"))
        XCTAssertTrue(OSCAddress.pattern("/{foo,bar}/[a-c]?", matches: "/bar/b7"))
        XCTAssertFalse(OSCAddress.pattern("/foo/?", matches: "/foo/long"))
    }

    func testUDPServerReceivesSyntheticDatagram() throws {
        let port = UInt16.random(in: 30_000...49_999)
        let ready = expectation(description: "OSC listener ready")
        let received = expectation(description: "OSC datagram received")
        let server = OSCUDPServer(
            port: port,
            messageHandler: { scheduled in
                if scheduled.message.addressPattern == "/metaliquartz/live" {
                    received.fulfill()
                }
            },
            stateHandler: { state in
                if state == .ready(port) { ready.fulfill() }
            }
        )
        try server.start()
        wait(for: [ready], timeout: 2)

        let connection = NWConnection(
            host: .ipv4(.loopback),
            port: try XCTUnwrap(NWEndpoint.Port(rawValue: port)),
            using: .udp
        )
        connection.start(queue: DispatchQueue(label: "OSCIntegrationTests.sender"))
        connection.send(
            content: message(address: "/metaliquartz/live", tags: "f", arguments: [uint32(0)]),
            completion: .contentProcessed { error in
                XCTAssertNil(error)
            }
        )
        wait(for: [received], timeout: 2)
        connection.cancel()
        server.stop()
    }

    private func message(
        address: String,
        tags: String,
        arguments: [Data] = []
    ) -> Data {
        oscString(address) + oscString("," + tags) + arguments.reduce(Data(), +)
    }

    private func bundle(timeTag: UInt64, elements: [Data]) -> Data {
        oscString("#bundle") + uint64(timeTag)
            + elements.reduce(Data()) { result, element in
                result + int32(Int32(element.count)) + element
            }
    }

    private func oscString(_ value: String) -> Data {
        var data = Data(value.utf8)
        data.append(0)
        while !data.count.isMultiple(of: 4) { data.append(0) }
        return data
    }

    private func int32(_ value: Int32) -> Data {
        uint32(UInt32(bitPattern: value))
    }

    private func uint32(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ])
    }

    private func uint64(_ value: UInt64) -> Data {
        Data((0..<8).map { shift in UInt8((value >> UInt64((7 - shift) * 8)) & 0xff) })
    }
}
