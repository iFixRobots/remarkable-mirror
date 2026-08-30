import Foundation

enum RMM1Protocol {
    static let headerByteCount = 28
    static let frameWidth = 954
    static let frameHeight = 1_696
    static let bytesPerPixel = 4
    static let frameByteCount = frameWidth * frameHeight * bytesPerPixel

    static let magic: [UInt8] = [0x52, 0x4D, 0x4D, 0x31]
    static let version: UInt8 = 1
    static let fullFrameFlag: UInt8 = 1
}

enum RMM1ProtocolError: Error, Equatable, Sendable {
    case invalidMagic
    case unsupportedVersion(UInt8)
    case invalidHeaderLength(UInt16)
    case nonIncreasingSequence(previous: UInt64, received: UInt64)
    case emptyRectangle
    case rectangleOutOfBounds
    case invalidPayloadLength(expected: Int, received: Int)
    case initialFrameMustBeFull
    case arithmeticOverflow
    case truncatedHeader(received: Int)
    case truncatedPayload(expected: Int, received: Int)
    case streamAlreadyFinished
}

struct RMM1FrameUpdate: Equatable, Sendable {
    let sequence: UInt64
    let isFull: Bool
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let payload: Data
}

struct RMM1StreamParser: Sendable {
    static let maximumBufferedByteCount = RMM1Protocol.frameByteCount

    private var headerBuffer = Data()
    private var payloadBuffer = Data()
    private var pendingHeader: ParsedHeader?
    private var previousSequence: UInt64 = 0
    private var hasDeliveredFrame = false
    private var terminalError: RMM1ProtocolError?
    private var isFinished = false

    var bufferedByteCount: Int {
        headerBuffer.count + payloadBuffer.count
    }

    mutating func consume(
        _ data: Data,
        onUpdate: (RMM1FrameUpdate) -> Void
    ) throws {
        if let terminalError {
            throw terminalError
        }
        guard !isFinished else {
            throw RMM1ProtocolError.streamAlreadyFinished
        }

        var offset = 0
        while offset < data.count {
            if pendingHeader == nil {
                let required = RMM1Protocol.headerByteCount - headerBuffer.count
                let count = min(required, data.count - offset)
                Self.append(data, offset: offset, count: count, to: &headerBuffer)
                offset += count

                if headerBuffer.count == RMM1Protocol.headerByteCount {
                    do {
                        let header = try Self.parseHeader(
                            headerBuffer,
                            previousSequence: previousSequence
                        )
                        pendingHeader = header
                        payloadBuffer.reserveCapacity(header.payloadByteCount)
                    } catch let error as RMM1ProtocolError {
                        payloadBuffer = Data()
                        pendingHeader = nil
                        terminalError = error
                        throw error
                    }
                    headerBuffer.removeAll(keepingCapacity: true)
                }
            } else if let header = pendingHeader {
                let required = header.payloadByteCount - payloadBuffer.count
                let count = min(required, data.count - offset)
                Self.append(data, offset: offset, count: count, to: &payloadBuffer)
                offset += count

                if payloadBuffer.count == header.payloadByteCount {
                    do {
                        try RMM1Validation.validateInitialFrameIfNeeded(
                            requiresInitialFullFrame: !hasDeliveredFrame,
                            isFull: header.isFull,
                            x: header.x,
                            y: header.y,
                            width: header.width,
                            height: header.height
                        )
                    } catch let error as RMM1ProtocolError {
                        payloadBuffer = Data()
                        pendingHeader = nil
                        terminalError = error
                        throw error
                    }

                    let update = RMM1FrameUpdate(
                        sequence: header.sequence,
                        isFull: header.isFull,
                        x: header.x,
                        y: header.y,
                        width: header.width,
                        height: header.height,
                        payload: payloadBuffer
                    )
                    payloadBuffer = Data()
                    pendingHeader = nil
                    previousSequence = header.sequence
                    hasDeliveredFrame = true
                    onUpdate(update)
                }
            }

            assert(bufferedByteCount <= Self.maximumBufferedByteCount)
        }
    }

    mutating func finish() throws {
        if let terminalError {
            throw terminalError
        }
        if isFinished {
            return
        }
        if let pendingHeader {
            let error = RMM1ProtocolError.truncatedPayload(
                expected: pendingHeader.payloadByteCount,
                received: payloadBuffer.count
            )
            terminalError = error
            throw error
        }
        if !headerBuffer.isEmpty {
            let error = RMM1ProtocolError.truncatedHeader(received: headerBuffer.count)
            terminalError = error
            throw error
        }
        isFinished = true
    }

    private static func parseHeader(
        _ data: Data,
        previousSequence: UInt64
    ) throws -> ParsedHeader {
        precondition(data.count == RMM1Protocol.headerByteCount)
        let bytes = [UInt8](data)

        guard Array(bytes[0..<4]) == RMM1Protocol.magic else {
            throw RMM1ProtocolError.invalidMagic
        }
        guard bytes[4] == RMM1Protocol.version else {
            throw RMM1ProtocolError.unsupportedVersion(bytes[4])
        }
        // Windows treats every flag bit except bit zero as forward-compatible.
        let flags = bytes[5]

        let headerByteCount = littleEndianUInt16(bytes, at: 6)
        guard headerByteCount == UInt16(RMM1Protocol.headerByteCount) else {
            throw RMM1ProtocolError.invalidHeaderLength(headerByteCount)
        }

        let sequence = littleEndianUInt64(bytes, at: 8)
        let x = Int(littleEndianUInt16(bytes, at: 16))
        let y = Int(littleEndianUInt16(bytes, at: 18))
        let width = Int(littleEndianUInt16(bytes, at: 20))
        let height = Int(littleEndianUInt16(bytes, at: 22))
        let payloadByteCount = Int(littleEndianUInt32(bytes, at: 24))
        let isFull = flags & RMM1Protocol.fullFrameFlag != 0

        try RMM1Validation.validate(
            sequence: sequence,
            previousSequence: previousSequence,
            requiresInitialFullFrame: false,
            isFull: isFull,
            x: x,
            y: y,
            width: width,
            height: height,
            payloadByteCount: payloadByteCount
        )

        return ParsedHeader(
            sequence: sequence,
            isFull: isFull,
            x: x,
            y: y,
            width: width,
            height: height,
            payloadByteCount: payloadByteCount
        )
    }

    private static func append(
        _ source: Data,
        offset: Int,
        count: Int,
        to destination: inout Data
    ) {
        guard count > 0 else {
            return
        }
        let start = source.index(source.startIndex, offsetBy: offset)
        let end = source.index(start, offsetBy: count)
        destination.append(contentsOf: source[start..<end])
    }

    private static func littleEndianUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) |
            (UInt16(bytes[offset + 1]) << 8)
    }

    private static func littleEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(bytes[offset + index]) << UInt32(index * 8)
        }
        return value
    }

    private static func littleEndianUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(bytes[offset + index]) << UInt64(index * 8)
        }
        return value
    }

    private struct ParsedHeader: Sendable {
        let sequence: UInt64
        let isFull: Bool
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let payloadByteCount: Int
    }
}

enum RMM1Validation {
    static func validate(
        sequence: UInt64,
        previousSequence: UInt64,
        requiresInitialFullFrame: Bool,
        isFull: Bool,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        payloadByteCount: Int
    ) throws {
        guard sequence > previousSequence else {
            throw RMM1ProtocolError.nonIncreasingSequence(
                previous: previousSequence,
                received: sequence
            )
        }
        guard width > 0, height > 0 else {
            throw RMM1ProtocolError.emptyRectangle
        }

        let expectedPayloadByteCount = try expectedPayloadByteCount(
            width: width,
            height: height
        )

        guard x >= 0, y >= 0 else {
            throw RMM1ProtocolError.rectangleOutOfBounds
        }
        let (maximumX, xOverflow) = x.addingReportingOverflow(width)
        let (maximumY, yOverflow) = y.addingReportingOverflow(height)
        guard !xOverflow, !yOverflow else {
            throw RMM1ProtocolError.arithmeticOverflow
        }
        guard maximumX <= RMM1Protocol.frameWidth,
              maximumY <= RMM1Protocol.frameHeight else {
            throw RMM1ProtocolError.rectangleOutOfBounds
        }
        guard payloadByteCount == expectedPayloadByteCount else {
            throw RMM1ProtocolError.invalidPayloadLength(
                expected: expectedPayloadByteCount,
                received: payloadByteCount
            )
        }
        try validateInitialFrameIfNeeded(
            requiresInitialFullFrame: requiresInitialFullFrame,
            isFull: isFull,
            x: x,
            y: y,
            width: width,
            height: height
        )
    }

    static func validateInitialFrameIfNeeded(
        requiresInitialFullFrame: Bool,
        isFull: Bool,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) throws {
        guard !requiresInitialFullFrame || (
            isFull &&
                x == 0 &&
                y == 0 &&
                width == RMM1Protocol.frameWidth &&
                height == RMM1Protocol.frameHeight
        ) else {
            throw RMM1ProtocolError.initialFrameMustBeFull
        }
    }

    static func expectedPayloadByteCount(width: Int, height: Int) throws -> Int {
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(
            by: RMM1Protocol.bytesPerPixel
        )
        guard !pixelOverflow, !byteOverflow else {
            throw RMM1ProtocolError.arithmeticOverflow
        }
        return byteCount
    }
}
