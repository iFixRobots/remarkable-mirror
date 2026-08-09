import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum TabletFrameSnapshotError: Error, Equatable, Sendable {
    case invalidByteCount(expected: Int, received: Int)
    case colorSpaceUnavailable
    case imageCreationFailed
    case destinationCreationFailed
    case encodingFailed
}

/// An immutable click-time copy of the exact visible tablet framebuffer.
///
/// Creating a snapshot is intentionally the only presentation path that copies
/// the complete frame. Normal display updates stay in the Metal texture and
/// upload only the RMM1 rectangle that changed.
struct TabletFrameSnapshot: Sendable {
    let bgra: Data

    init(bgra: Data) throws {
        guard bgra.count == RMM1Protocol.frameByteCount else {
            throw TabletFrameSnapshotError.invalidByteCount(
                expected: RMM1Protocol.frameByteCount,
                received: bgra.count
            )
        }
        self.bgra = bgra
    }

    /// Encodes a `954 x 1696` opaque sRGB PNG without changing source RGB.
    func pngData() throws -> Data {
        let signpost = PerformanceSignposts.begin("Screenshot PNG Encoding")
        defer { PerformanceSignposts.end(signpost) }

        var opaqueBGRA = bgra
        opaqueBGRA.withUnsafeMutableBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for alphaOffset in stride(
                from: RMM1Protocol.bytesPerPixel - 1,
                to: bytes.count,
                by: RMM1Protocol.bytesPerPixel
            ) {
                bytes[alphaOffset] = 255
            }
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw TabletFrameSnapshotError.colorSpaceUnavailable
        }
        guard let provider = CGDataProvider(data: opaqueBGRA as CFData) else {
            throw TabletFrameSnapshotError.imageCreationFailed
        }

        let alphaInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
        )
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(alphaInfo)
        guard let image = CGImage(
            width: RMM1Protocol.frameWidth,
            height: RMM1Protocol.frameHeight,
            bitsPerComponent: 8,
            bitsPerPixel: RMM1Protocol.bytesPerPixel * 8,
            bytesPerRow: RMM1Protocol.frameWidth * RMM1Protocol.bytesPerPixel,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw TabletFrameSnapshotError.imageCreationFailed
        }

        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw TabletFrameSnapshotError.destinationCreationFailed
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw TabletFrameSnapshotError.encodingFailed
        }
        return encoded as Data
    }
}
