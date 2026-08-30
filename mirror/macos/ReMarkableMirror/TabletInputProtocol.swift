import Foundation

enum TabletInputDisplayState: String, Equatable, Sendable {
    case unknown
    case normal
    case deepSleep = "deep_sleep"
}

enum TabletInputFilesState: String, Equatable, Sendable {
    case ready
    case unavailable
}

struct TabletInputHandshake: Equatable, Sendable {
    let displayState: TabletInputDisplayState
    let filesState: TabletInputFilesState?

    init(
        displayState: TabletInputDisplayState,
        filesState: TabletInputFilesState? = nil
    ) {
        self.displayState = displayState
        self.filesState = filesState
    }
}

enum TabletInputPointerEvent: Equatable, Sendable {
    case down(x: Double, y: Double, pressure: Double? = nil)
    case move(x: Double, y: Double, pressure: Double? = nil)
    case up
}

enum TabletInputPenTool: String, Equatable, Sendable {
    case pen
    case eraser
}

enum TabletInputPenEvent: Equatable, Sendable {
    case down(
        x: Double,
        y: Double,
        pressure: Double? = nil,
        tool: TabletInputPenTool
    )
    case move(x: Double, y: Double, pressure: Double? = nil)
    case up
}

enum TabletInputKeyAction: String, Equatable, Sendable {
    case down
    case up
    case click
}

struct TabletInputKey: Hashable, Sendable {
    let rawValue: String

    init(validating value: String) throws {
        var name = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        if name.hasPrefix("KEY_") {
            name.removeFirst(4)
        }
        guard Self.helperKeyNames.contains(name) else {
            throw TabletInputProtocolError.unsupportedKey
        }
        rawValue = "KEY_\(name)"
    }

    private static let helperKeyNames: Set<String> = [
        "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
        "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
        "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
        "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
        "ESC", "BACKSPACE", "TAB", "ENTER",
        "MINUS", "EQUAL", "LEFTBRACE", "RIGHTBRACE",
        "SEMICOLON", "APOSTROPHE", "GRAVE", "BACKSLASH",
        "COMMA", "DOT", "SLASH",
        "LEFTCTRL", "LEFTSHIFT", "RIGHTSHIFT",
        "LEFTALT", "SPACE", "CAPSLOCK", "RIGHTCTRL", "RIGHTALT",
        "HOME", "UP", "PAGEUP", "LEFT", "RIGHT", "END", "DOWN", "PAGEDOWN",
        "INSERT", "DELETE", "POWER", "WAKEUP", "LEFTMETA", "RIGHTMETA",
    ]
}

enum TabletInputEvent: Equatable, Sendable {
    case touch(TabletInputPointerEvent)
    case pen(TabletInputPenEvent)
    case key(action: TabletInputKeyAction, key: TabletInputKey)
    case text(String)
    case reset
}

enum TabletInputProtocolError: Error, Equatable, Sendable {
    case invalidHandshake
    case invalidResponse
    case invalidIdentifier
    case responseIdentifierMismatch(expected: UInt64, actual: UInt64)
    case unsupportedKey
    case invalidCoordinates
    case invalidPressure
    case invalidText
    case commandTooLarge
    case identifierExhausted
}

struct TabletInputCommandRejection: Error, Equatable, Sendable {
    let id: UInt64
    let code: String
}

enum TabletInputCommandResponse: Equatable, Sendable {
    case acknowledged(id: UInt64)
    case rejected(TabletInputCommandRejection)
}

/// A checked monotonically increasing command-ID source. It never emits zero
/// and stops rather than wrapping after UInt64.max.
struct TabletInputCommandIDSequence: Equatable, Sendable {
    private(set) var lastID: UInt64

    init(lastID: UInt64 = 0) {
        self.lastID = lastID
    }

    mutating func next() throws -> UInt64 {
        guard lastID < UInt64.max else {
            throw TabletInputProtocolError.identifierExhausted
        }
        lastID += 1
        return lastID
    }
}

enum TabletInputWireCodec {
    static let handshakeSchema = "rmmirror.input/v1"
    static let maximumHandshakeBytes = 4_096
    static let maximumResponseBytes = 4_096
    static let maximumTextBytes = 4_096
    static let maximumCommandLineBytes = 64 * 1_024

    static func parseHandshake(_ data: Data) throws -> TabletInputHandshake {
        let root: TabletInputJSONValue
        do {
            root = try parseJSON(data, maximumBytes: maximumHandshakeBytes)
        } catch {
            throw TabletInputProtocolError.invalidHandshake
        }

        let requiredKeys: Set<String> = [
            "schema", "ready", "display_state", "touch", "pen", "text",
        ]
        let allowedKeys = requiredKeys.union(["files_state"])
        guard case let .object(values) = root,
              Set(values.keys).isSuperset(of: requiredKeys),
              Set(values.keys).isSubset(of: allowedKeys),
              case let .string(schema)? = values["schema"],
              schema == handshakeSchema,
              case .boolean(true)? = values["ready"],
              case let .string(displayStateValue)? = values["display_state"],
              let displayState = TabletInputDisplayState(rawValue: displayStateValue),
              hasExactAxisRange(values["touch"], xMaximum: 1_248, yMaximum: 2_208),
              hasExactAxisRange(values["pen"], xMaximum: 6_760, yMaximum: 11_960),
              case .string("us-ascii")? = values["text"] else {
            throw TabletInputProtocolError.invalidHandshake
        }

        let filesState: TabletInputFilesState?
        if let value = values["files_state"] {
            guard case let .string(rawValue) = value,
                  let decoded = TabletInputFilesState(rawValue: rawValue) else {
                throw TabletInputProtocolError.invalidHandshake
            }
            filesState = decoded
        } else {
            filesState = nil
        }

        return TabletInputHandshake(
            displayState: displayState,
            filesState: filesState
        )
    }

    static func parseResponse(
        _ data: Data,
        expectedID: UInt64
    ) throws -> TabletInputCommandResponse {
        guard expectedID > 0 else {
            throw TabletInputProtocolError.invalidIdentifier
        }

        let root: TabletInputJSONValue
        do {
            root = try parseJSON(data, maximumBytes: maximumResponseBytes)
        } catch {
            throw TabletInputProtocolError.invalidResponse
        }

        guard case let .object(values) = root,
              case let .unsignedInteger(id)? = values["id"],
              id > 0 else {
            throw TabletInputProtocolError.invalidResponse
        }

        let response: TabletInputCommandResponse
        if Set(values.keys) == ["id", "ok"] {
            guard case .boolean(true)? = values["ok"] else {
                throw TabletInputProtocolError.invalidResponse
            }
            response = .acknowledged(id: id)
        } else if Set(values.keys) == ["id", "error"],
                  case let .string(code)? = values["error"],
                  isRejectionCode(code) {
            response = .rejected(TabletInputCommandRejection(id: id, code: code))
        } else {
            throw TabletInputProtocolError.invalidResponse
        }

        guard id == expectedID else {
            throw TabletInputProtocolError.responseIdentifierMismatch(
                expected: expectedID,
                actual: id
            )
        }
        return response
    }

    static func encode(event: TabletInputEvent, id: UInt64) throws -> Data {
        try validateIdentifier(id)

        let body: String
        switch event {
        case let .touch(pointer):
            body = try encodeTouch(pointer, id: id)
        case let .pen(pen):
            body = try encodePen(pen, id: id)
        case let .key(action, key):
            body = "{\"id\":\(id),\"type\":\"key\",\"action\":\"\(action.rawValue)\",\"key\":\"\(key.rawValue)\"}"
        case let .text(text):
            body = "{\"id\":\(id),\"type\":\"text\",\"text\":\"\(try encodeText(text))\"}"
        case .reset:
            body = "{\"id\":\(id),\"type\":\"reset\"}"
        }
        return try terminatedLine(body)
    }

    static func encodePing(id: UInt64) throws -> Data {
        try validateIdentifier(id)
        return try terminatedLine("{\"id\":\(id),\"type\":\"ping\"}")
    }

    private static func encodeTouch(_ event: TabletInputPointerEvent, id: UInt64) throws -> String {
        switch event {
        case let .down(x, y, pressure):
            return try encodePointer(
                id: id,
                type: "touch",
                action: "down",
                x: x,
                y: y,
                pressure: pressure
            )
        case let .move(x, y, pressure):
            return try encodePointer(
                id: id,
                type: "touch",
                action: "move",
                x: x,
                y: y,
                pressure: pressure
            )
        case .up:
            return "{\"id\":\(id),\"type\":\"touch\",\"action\":\"up\"}"
        }
    }

    private static func encodePen(_ event: TabletInputPenEvent, id: UInt64) throws -> String {
        switch event {
        case let .down(x, y, pressure, tool):
            let pointer = try encodePointer(
                id: id,
                type: "pen",
                action: "down",
                x: x,
                y: y,
                pressure: pressure,
                closingBrace: false
            )
            return "\(pointer),\"tool\":\"\(tool.rawValue)\"}"
        case let .move(x, y, pressure):
            return try encodePointer(
                id: id,
                type: "pen",
                action: "move",
                x: x,
                y: y,
                pressure: pressure
            )
        case .up:
            return "{\"id\":\(id),\"type\":\"pen\",\"action\":\"up\"}"
        }
    }

    private static func encodePointer(
        id: UInt64,
        type: String,
        action: String,
        x: Double,
        y: Double,
        pressure: Double?,
        closingBrace: Bool = true
    ) throws -> String {
        guard isUnitValue(x), isUnitValue(y) else {
            throw TabletInputProtocolError.invalidCoordinates
        }
        if let pressure, !isUnitValue(pressure) {
            throw TabletInputProtocolError.invalidPressure
        }

        var body = "{\"id\":\(id),\"type\":\"\(type)\",\"action\":\"\(action)\",\"x\":\(number(x)),\"y\":\(number(y))"
        if let pressure {
            body += ",\"pressure\":\(number(pressure))"
        }
        if closingBrace {
            body += "}"
        }
        return body
    }

    private static func encodeText(_ value: String) throws -> String {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumTextBytes else {
            throw TabletInputProtocolError.invalidText
        }

        var encoded = ""
        encoded.reserveCapacity(bytes.count)
        for byte in bytes {
            switch byte {
            case 0x08:
                encoded += "\\b"
            case 0x09:
                encoded += "\\t"
            case 0x0A:
                encoded += "\\n"
            case 0x0D:
                encoded += "\\r"
            case 0x22:
                encoded += "\\\""
            case 0x5C:
                encoded += "\\\\"
            case 0x20...0x7E:
                guard let scalar = UnicodeScalar(Int(byte)) else {
                    throw TabletInputProtocolError.invalidText
                }
                encoded.unicodeScalars.append(scalar)
            default:
                throw TabletInputProtocolError.invalidText
            }
        }
        return encoded
    }

    private static func terminatedLine(_ body: String) throws -> Data {
        let data = Data((body + "\n").utf8)
        guard data.count <= maximumCommandLineBytes else {
            throw TabletInputProtocolError.commandTooLarge
        }
        return data
    }

    private static func validateIdentifier(_ id: UInt64) throws {
        guard id > 0 else {
            throw TabletInputProtocolError.invalidIdentifier
        }
    }

    private static func isUnitValue(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && value <= 1
    }

    private static func number(_ value: Double) -> String {
        if value == 0 {
            return "0"
        }
        if value == 1 {
            return "1"
        }
        return String(value)
    }

    private static func hasExactAxisRange(
        _ value: TabletInputJSONValue?,
        xMaximum: UInt64,
        yMaximum: UInt64
    ) -> Bool {
        guard case let .object(values)? = value,
              Set(values.keys) == ["x_max", "y_max"],
              case .unsignedInteger(xMaximum)? = values["x_max"],
              case .unsignedInteger(yMaximum)? = values["y_max"] else {
            return false
        }
        return true
    }

    private static func isRejectionCode(_ value: String) -> Bool {
        let bytes = value.utf8
        return (1...64).contains(bytes.count) && bytes.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) ||
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) ||
                byte == UInt8(ascii: "_")
        }
    }

    private static func parseJSON(
        _ data: Data,
        maximumBytes: Int
    ) throws -> TabletInputJSONValue {
        guard !data.isEmpty,
              data.count <= maximumBytes,
              String(data: data, encoding: .utf8) != nil else {
            throw TabletInputJSONError.invalid
        }
        var parser = TabletInputStrictJSONParser(data: data)
        return try parser.parse()
    }
}

private enum TabletInputJSONValue: Equatable {
    case object([String: TabletInputJSONValue])
    case string(String)
    case boolean(Bool)
    case unsignedInteger(UInt64)
}

private enum TabletInputJSONError: Error {
    case invalid
}

/// Parses only the JSON value shapes used by the input protocol. Object keys
/// are decoded before duplicate detection, and the complete input must contain
/// exactly one value plus JSON whitespace.
private struct TabletInputStrictJSONParser {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func parse() throws -> TabletInputJSONValue {
        skipWhitespace()
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else {
            throw TabletInputJSONError.invalid
        }
        return value
    }

    private mutating func parseValue(depth: Int) throws -> TabletInputJSONValue {
        guard index < bytes.count else {
            throw TabletInputJSONError.invalid
        }
        switch bytes[index] {
        case UInt8(ascii: "{"):
            return .object(try parseObject(depth: depth))
        case UInt8(ascii: "\""):
            return .string(try parseString())
        case UInt8(ascii: "t"):
            try requireLiteral("true")
            return .boolean(true)
        case UInt8(ascii: "f"):
            try requireLiteral("false")
            return .boolean(false)
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return .unsignedInteger(try parseUnsignedInteger())
        default:
            throw TabletInputJSONError.invalid
        }
    }

    private mutating func parseObject(depth: Int) throws -> [String: TabletInputJSONValue] {
        guard depth <= 8 else {
            throw TabletInputJSONError.invalid
        }
        try require(UInt8(ascii: "{"))
        skipWhitespace()

        var values: [String: TabletInputJSONValue] = [:]
        if consume(UInt8(ascii: "}")) {
            return values
        }

        while true {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
                throw TabletInputJSONError.invalid
            }
            let key = try parseString()
            guard values[key] == nil else {
                throw TabletInputJSONError.invalid
            }
            skipWhitespace()
            try require(UInt8(ascii: ":"))
            skipWhitespace()
            values[key] = try parseValue(depth: depth + 1)
            skipWhitespace()

            if consume(UInt8(ascii: "}")) {
                return values
            }
            try require(UInt8(ascii: ","))
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        try require(UInt8(ascii: "\""))
        var decoded: [UInt8] = []

        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == UInt8(ascii: "\"") {
                guard let value = String(bytes: decoded, encoding: .utf8) else {
                    throw TabletInputJSONError.invalid
                }
                return value
            }
            if byte < 0x20 {
                throw TabletInputJSONError.invalid
            }
            if byte != UInt8(ascii: "\\") {
                decoded.append(byte)
                continue
            }

            guard index < bytes.count else {
                throw TabletInputJSONError.invalid
            }
            let escape = bytes[index]
            index += 1
            switch escape {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"):
                decoded.append(escape)
            case UInt8(ascii: "b"):
                decoded.append(0x08)
            case UInt8(ascii: "f"):
                decoded.append(0x0C)
            case UInt8(ascii: "n"):
                decoded.append(0x0A)
            case UInt8(ascii: "r"):
                decoded.append(0x0D)
            case UInt8(ascii: "t"):
                decoded.append(0x09)
            case UInt8(ascii: "u"):
                let first = try parseHexQuad()
                let scalarValue: UInt32
                if (0xD800...0xDBFF).contains(first) {
                    try require(UInt8(ascii: "\\"))
                    try require(UInt8(ascii: "u"))
                    let second = try parseHexQuad()
                    guard (0xDC00...0xDFFF).contains(second) else {
                        throw TabletInputJSONError.invalid
                    }
                    scalarValue = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                } else {
                    guard !(0xDC00...0xDFFF).contains(first) else {
                        throw TabletInputJSONError.invalid
                    }
                    scalarValue = first
                }
                guard let scalar = UnicodeScalar(scalarValue) else {
                    throw TabletInputJSONError.invalid
                }
                decoded.append(contentsOf: String(scalar).utf8)
            default:
                throw TabletInputJSONError.invalid
            }
        }

        throw TabletInputJSONError.invalid
    }

    private mutating func parseHexQuad() throws -> UInt32 {
        guard index + 4 <= bytes.count else {
            throw TabletInputJSONError.invalid
        }
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let digit = hexValue(bytes[index]) else {
                throw TabletInputJSONError.invalid
            }
            value = (value << 4) | UInt32(digit)
            index += 1
        }
        return value
    }

    private func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"):
            return byte - UInt8(ascii: "A") + 10
        default:
            return nil
        }
    }

    private mutating func parseUnsignedInteger() throws -> UInt64 {
        guard index < bytes.count else {
            throw TabletInputJSONError.invalid
        }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
            if index < bytes.count,
               (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                throw TabletInputJSONError.invalid
            }
            return 0
        }

        var value: UInt64 = 0
        var consumed = false
        while index < bytes.count,
              (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
            consumed = true
            let digit = UInt64(bytes[index] - UInt8(ascii: "0"))
            guard value <= (UInt64.max - digit) / 10 else {
                throw TabletInputJSONError.invalid
            }
            value = value * 10 + digit
            index += 1
        }
        guard consumed else {
            throw TabletInputJSONError.invalid
        }
        return value
    }

    private mutating func requireLiteral(_ literal: StaticString) throws {
        let literalBytes = literal.withUTF8Buffer { Array($0) }
        guard index + literalBytes.count <= bytes.count,
              Array(bytes[index..<(index + literalBytes.count)]) == literalBytes else {
            throw TabletInputJSONError.invalid
        }
        index += literalBytes.count
    }

    private mutating func require(_ byte: UInt8) throws {
        guard consume(byte) else {
            throw TabletInputJSONError.invalid
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else {
            return false
        }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x09, 0x0A, 0x0D, 0x20:
                index += 1
            default:
                return
            }
        }
    }
}
