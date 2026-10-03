import Foundation
import Network

enum OSCArgument: Equatable, Sendable {
    case int32(Int32)
    case float32(Float)
    case string(String)
    case boolean(Bool)
}

struct OSCMessage: Equatable, Sendable {
    var addressPattern: String
    var arguments: [OSCArgument]
}

struct OSCTimeTag: Equatable, Comparable, Sendable {
    static let immediate = OSCTimeTag(rawValue: 1)
    private static let ntpEpochOffset = 2_208_988_800.0

    var rawValue: UInt64

    static func < (lhs: OSCTimeTag, rhs: OSCTimeTag) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var deliveryDate: Date? {
        guard self != .immediate else { return nil }
        let seconds = Double(rawValue >> 32)
        let fraction = Double(rawValue & 0xffff_ffff) / 4_294_967_296.0
        return Date(timeIntervalSince1970: seconds + fraction - Self.ntpEpochOffset)
    }
}

struct OSCScheduledMessage: Equatable, Sendable {
    var message: OSCMessage
    var timeTag: OSCTimeTag?
}

enum OSCDecodingError: LocalizedError, Equatable {
    case invalidPacket
    case invalidString
    case invalidAddress
    case invalidTypeTag(Character)
    case invalidBundleTimeTag

    var errorDescription: String? {
        switch self {
        case .invalidPacket: "The OSC packet is truncated or incorrectly aligned."
        case .invalidString: "The OSC packet contains an invalid OSC string."
        case .invalidAddress: "The OSC message has an invalid address pattern."
        case .invalidTypeTag(let tag): "The OSC message uses unsupported type tag \(tag)."
        case .invalidBundleTimeTag: "A nested OSC bundle predates its enclosing bundle."
        }
    }
}

enum OSCPacketDecoder {
    static func decode(_ data: Data) throws -> [OSCScheduledMessage] {
        guard !data.isEmpty, data.count.isMultiple(of: 4) else {
            throw OSCDecodingError.invalidPacket
        }
        return try decodePacket(data, inheritedTimeTag: nil)
    }

    private static func decodePacket(
        _ data: Data,
        inheritedTimeTag: OSCTimeTag?
    ) throws -> [OSCScheduledMessage] {
        var reader = OSCReader(data: data)
        let leadingString = try reader.readString()
        if leadingString == "#bundle" {
            return try decodeBundle(from: &reader, inheritedTimeTag: inheritedTimeTag)
        }
        return [
            try decodeMessage(
                addressPattern: leadingString,
                from: &reader,
                timeTag: inheritedTimeTag
            )
        ]
    }

    private static func decodeBundle(
        from reader: inout OSCReader,
        inheritedTimeTag: OSCTimeTag?
    ) throws -> [OSCScheduledMessage] {
        let declaredTimeTag = OSCTimeTag(rawValue: try reader.readUInt64())
        let effectiveTimeTag: OSCTimeTag
        if declaredTimeTag == .immediate {
            effectiveTimeTag = inheritedTimeTag ?? .immediate
        } else {
            if let inheritedTimeTag, inheritedTimeTag != .immediate,
                declaredTimeTag < inheritedTimeTag
            {
                throw OSCDecodingError.invalidBundleTimeTag
            }
            effectiveTimeTag = declaredTimeTag
        }

        var messages: [OSCScheduledMessage] = []
        while !reader.isAtEnd {
            let size = Int(try reader.readInt32())
            guard size > 0, size.isMultiple(of: 4) else {
                throw OSCDecodingError.invalidPacket
            }
            let element = try reader.readData(count: size)
            do {
                messages += try decodePacket(element, inheritedTimeTag: effectiveTimeTag)
            } catch OSCDecodingError.invalidTypeTag {
                // OSC 1.0 requires messages with unknown type tags to be discarded. A bad
                // sibling must not prevent the rest of a bundle from being delivered.
                continue
            }
        }
        return messages
    }

    private static func decodeMessage(
        addressPattern: String,
        from reader: inout OSCReader,
        timeTag: OSCTimeTag?
    ) throws -> OSCScheduledMessage {
        guard addressPattern.first == "/" else { throw OSCDecodingError.invalidAddress }
        guard !reader.isAtEnd else {
            return OSCScheduledMessage(
                message: OSCMessage(addressPattern: addressPattern, arguments: []),
                timeTag: timeTag
            )
        }

        let typeTags = try reader.readString()
        guard typeTags.first == "," else { throw OSCDecodingError.invalidPacket }
        var arguments: [OSCArgument] = []
        for tag in typeTags.dropFirst() {
            switch tag {
            case "i": arguments.append(.int32(try reader.readInt32()))
            case "f": arguments.append(.float32(Float(bitPattern: try reader.readUInt32())))
            case "s": arguments.append(.string(try reader.readString()))
            case "T": arguments.append(.boolean(true))
            case "F": arguments.append(.boolean(false))
            default: throw OSCDecodingError.invalidTypeTag(tag)
            }
        }
        guard reader.isAtEnd else { throw OSCDecodingError.invalidPacket }
        return OSCScheduledMessage(
            message: OSCMessage(addressPattern: addressPattern, arguments: arguments),
            timeTag: timeTag
        )
    }
}

enum OSCAddress {
    private static let prohibitedNameCharacters = CharacterSet(charactersIn: " #*/,?[]{}")

    static func defaultAddress(for publishedName: String) -> String {
        let allowed = publishedName.unicodeScalars.map { scalar -> Character in
            if scalar.isASCII,
                !prohibitedNameCharacters.contains(scalar),
                !CharacterSet.controlCharacters.contains(scalar)
            {
                return Character(String(scalar).lowercased())
            }
            return "-"
        }
        let component = String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return "/metaliquartz/\(component.isEmpty ? "parameter" : component)"
    }

    static func isValidMethodAddress(_ address: String) -> Bool {
        guard address.first == "/", address.count > 1, !address.hasSuffix("/") else {
            return false
        }
        return address.split(separator: "/").allSatisfy { component in
            !component.isEmpty
                && component.unicodeScalars.allSatisfy {
                    $0.isASCII
                        && !prohibitedNameCharacters.contains($0)
                        && !CharacterSet.controlCharacters.contains($0)
                }
        }
    }

    static func pattern(_ pattern: String, matches methodAddress: String) -> Bool {
        guard methodAddress.first == "/", let expression = regularExpression(for: pattern) else {
            return false
        }
        let range = NSRange(methodAddress.startIndex..., in: methodAddress)
        return expression.firstMatch(in: methodAddress, range: range) != nil
    }

    private static func regularExpression(for pattern: String) -> NSRegularExpression? {
        guard pattern.first == "/" else { return nil }
        var result = "^"
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            switch character {
            case "*": result += "[^/]*"
            case "?": result += "[^/]"
            case "[":
                guard let close = pattern[index...].firstIndex(of: "]"), close > index else {
                    return nil
                }
                var contents = String(pattern[pattern.index(after: index)..<close])
                if contents.first == "!" {
                    contents.removeFirst()
                    contents = "^" + contents
                }
                result += "[\(contents)]"
                index = close
            case "{":
                guard let close = pattern[index...].firstIndex(of: "}"), close > index else {
                    return nil
                }
                let contents = pattern[pattern.index(after: index)..<close]
                let alternatives = contents.split(separator: ",", omittingEmptySubsequences: false)
                guard !alternatives.contains(where: \.isEmpty) else { return nil }
                result +=
                    "(?:"
                    + alternatives.map { NSRegularExpression.escapedPattern(for: String($0)) }
                    .joined(separator: "|") + ")"
                index = close
            default:
                result += NSRegularExpression.escapedPattern(for: String(character))
            }
            index = pattern.index(after: index)
        }
        result += "$"
        return try? NSRegularExpression(pattern: result)
    }
}

enum OSCUDPServerState: Equatable, Sendable {
    case stopped
    case ready(UInt16)
    case failed(String)
}

final class OSCUDPServer: @unchecked Sendable {
    typealias MessageHandler = @Sendable (OSCScheduledMessage) -> Void
    typealias StateHandler = @Sendable (OSCUDPServerState) -> Void

    private let port: UInt16
    private let messageHandler: MessageHandler
    private let stateHandler: StateHandler
    private let queue = DispatchQueue(label: "com.steolepanda.Metaliquartz.osc-input")
    private let stateLock = NSLock()
    private var listener: NWListener?
    private var isRunning = false

    init(
        port: UInt16,
        messageHandler: @escaping MessageHandler,
        stateHandler: @escaping StateHandler = { _ in }
    ) {
        self.port = port
        self.messageHandler = messageHandler
        self.stateHandler = stateHandler
    }

    func start() throws {
        stateLock.lock()
        let alreadyRunning = isRunning
        stateLock.unlock()
        guard !alreadyRunning else { return }
        guard let networkPort = NWEndpoint.Port(rawValue: port) else {
            throw OSCDecodingError.invalidPacket
        }
        let listener = try NWListener(using: .udp, on: networkPort)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.stateHandler(.ready(self.port))
            case .failed(let error):
                self.stateHandler(.failed(error.localizedDescription))
                self.stateLock.lock()
                self.isRunning = false
                self.listener = nil
                self.stateLock.unlock()
            case .cancelled:
                self.stateHandler(.stopped)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.receiveMessages(on: connection)
        }
        stateLock.lock()
        self.listener = listener
        isRunning = true
        stateLock.unlock()
        listener.start(queue: queue)
    }

    func stop() {
        stateLock.lock()
        let listenerToCancel = listener
        listener = nil
        isRunning = false
        stateLock.unlock()
        listenerToCancel?.cancel()
        stateHandler(.stopped)
    }

    deinit {
        stateLock.lock()
        let listener = listener
        stateLock.unlock()
        listener?.cancel()
    }

    private func receiveMessages(on connection: NWConnection) {
        connection.start(queue: queue)
        receiveNextMessage(on: connection)
    }

    private func receiveNextMessage(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            guard self.isActive else {
                connection.cancel()
                return
            }
            if let data, let messages = try? OSCPacketDecoder.decode(data) {
                for message in messages {
                    self.deliver(message)
                }
            }
            if error == nil {
                self.receiveNextMessage(on: connection)
            } else {
                connection.cancel()
            }
        }
    }

    private func deliver(_ scheduledMessage: OSCScheduledMessage) {
        guard isActive else { return }
        guard let date = scheduledMessage.timeTag?.deliveryDate else {
            messageHandler(scheduledMessage)
            return
        }
        queue.asyncAfter(deadline: .now() + max(0, date.timeIntervalSinceNow)) { [weak self] in
            guard let self, self.isActive else { return }
            self.messageHandler(scheduledMessage)
        }
    }

    private var isActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isRunning
    }
}

private struct OSCReader {
    let data: Data
    private(set) var offset = 0

    init(data: Data) {
        self.data = Data(data)
    }

    var isAtEnd: Bool { offset == data.count }

    mutating func readString() throws -> String {
        guard offset < data.count,
            let terminator = data[offset...].firstIndex(of: 0)
        else { throw OSCDecodingError.invalidString }
        let bytes = data[offset..<terminator]
        guard bytes.allSatisfy({ $0 < 0x80 }),
            let string = String(data: bytes, encoding: .ascii)
        else { throw OSCDecodingError.invalidString }
        let paddedEnd = (terminator + 1 + 3) & ~3
        guard paddedEnd <= data.count,
            data[(terminator + 1)..<paddedEnd].allSatisfy({ $0 == 0 })
        else { throw OSCDecodingError.invalidString }
        offset = paddedEnd
        return string
    }

    mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readData(count: 4)
        return bytes.reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
    }

    mutating func readUInt64() throws -> UInt64 {
        let bytes = try readData(count: 8)
        return bytes.reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else {
            throw OSCDecodingError.invalidPacket
        }
        defer { offset += count }
        return Data(data[offset..<(offset + count)])
    }
}
