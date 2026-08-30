import Foundation

struct RMM1FrameSurface: Equatable, Sendable {
    private(set) var bgra = Data(
        repeating: 0,
        count: RMM1Protocol.frameByteCount
    )
    private(set) var sequence: UInt64?
    private(set) var hasFrame = false

    mutating func apply(_ update: RMM1FrameUpdate) throws {
        try RMM1Validation.validate(
            sequence: update.sequence,
            previousSequence: sequence ?? 0,
            requiresInitialFullFrame: !hasFrame,
            isFull: update.isFull,
            x: update.x,
            y: update.y,
            width: update.width,
            height: update.height,
            payloadByteCount: update.payload.count
        )

        // The full bit gates only the first update. Later updates are applied
        // by geometry, matching the Windows host even if that bit is still set.
        let isCanonicalFullRectangle = update.x == 0 &&
            update.y == 0 &&
            update.width == RMM1Protocol.frameWidth &&
            update.height == RMM1Protocol.frameHeight
        if isCanonicalFullRectangle {
            bgra = update.payload
        } else {
            let rowByteCount = update.width * RMM1Protocol.bytesPerPixel
            bgra.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
                update.payload.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                    guard let destinationBase = destination.baseAddress,
                          let sourceBase = source.baseAddress else {
                        return
                    }
                    for row in 0..<update.height {
                        let sourceOffset = row * rowByteCount
                        let destinationOffset = (
                            ((update.y + row) * RMM1Protocol.frameWidth) + update.x
                        ) * RMM1Protocol.bytesPerPixel
                        destinationBase
                            .advanced(by: destinationOffset)
                            .copyMemory(
                                from: sourceBase.advanced(by: sourceOffset),
                                byteCount: rowByteCount
                            )
                    }
                }
            }
        }

        sequence = update.sequence
        hasFrame = true
    }
}
