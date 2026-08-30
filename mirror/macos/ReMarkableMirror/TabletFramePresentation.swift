import AppKit
import Metal
import MetalKit
import MetalPerformanceShaders
import SwiftUI

enum TabletFramePresentationError: Error, Equatable, Sendable {
    case metalDeviceUnavailable
    case commandQueueUnavailable
    case textureCreationFailed
    case textureClearFailed
    case snapshotUnavailable
}

/// Owns the one live `954 x 1696` BGRA Metal surface used for presentation.
///
/// `apply(_:)` is main-actor isolated by design. A single frame-reader task
/// should await each call before reading the next parser update; that provides
/// bounded backpressure without an unbounded frame queue or per-update tasks.
@MainActor
final class TabletFramePresentation: NSObject, MTKViewDelegate {
    private static let pixelFormat: MTLPixelFormat = .bgra8Unorm_srgb

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let texture: any MTLTexture
    private let scaleKernel: MPSImageBilinearScale
    private weak var metalView: MTKView?

    private(set) var hasFrame = false
    private(set) var latestSequence: UInt64?

    static func makeDefault() throws -> TabletFramePresentation {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw TabletFramePresentationError.metalDeviceUnavailable
        }

        return try TabletFramePresentation(device: device)
    }

    init(device: any MTLDevice) throws {
        guard let commandQueue = device.makeCommandQueue() else {
            throw TabletFramePresentationError.commandQueueUnavailable
        }

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelFormat,
            width: RMM1Protocol.frameWidth,
            height: RMM1Protocol.frameHeight,
            mipmapped: false
        )
        textureDescriptor.storageMode = .shared
        textureDescriptor.usage = [.shaderRead, .renderTarget]
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            throw TabletFramePresentationError.textureCreationFailed
        }
        texture.label = "Paper Pro Move BGRA frame"
        guard Self.clear(texture: texture, using: commandQueue) else {
            throw TabletFramePresentationError.textureClearFailed
        }

        self.device = device
        self.commandQueue = commandQueue
        self.texture = texture
        scaleKernel = MPSImageBilinearScale(device: device)
        super.init()
    }

    func apply(_ update: RMM1FrameUpdate) throws {
        try RMM1Validation.validate(
            sequence: update.sequence,
            previousSequence: latestSequence ?? 0,
            requiresInitialFullFrame: !hasFrame,
            isFull: update.isFull,
            x: update.x,
            y: update.y,
            width: update.width,
            height: update.height,
            payloadByteCount: update.payload.count
        )

        let region = MTLRegionMake2D(
            update.x,
            update.y,
            update.width,
            update.height
        )
        update.payload.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: update.width * RMM1Protocol.bytesPerPixel
            )
        }

        latestSequence = update.sequence
        hasFrame = true
        if let metalView {
            metalView.isHidden = false
            metalView.setNeedsDisplay(metalView.bounds)
        }
    }

    /// Retires the visible frame at a generation boundary before sequence one
    /// from a replacement stream is admitted.
    func reset() {
        latestSequence = nil
        hasFrame = false
        let didClear = Self.clear(texture: texture, using: commandQueue)
        metalView?.isHidden = !didClear
        if let metalView, didClear {
            metalView.setNeedsDisplay(metalView.bounds)
        }
    }

    /// Copies the current Metal surface once so PNG work can continue off-main.
    func snapshot() throws -> TabletFrameSnapshot {
        guard hasFrame else {
            throw TabletFramePresentationError.snapshotUnavailable
        }

        var bgra = Data(count: RMM1Protocol.frameByteCount)
        bgra.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.getBytes(
                baseAddress,
                bytesPerRow: RMM1Protocol.frameWidth * RMM1Protocol.bytesPerPixel,
                from: MTLRegionMake2D(
                    0,
                    0,
                    RMM1Protocol.frameWidth,
                    RMM1Protocol.frameHeight
                ),
                mipmapLevel: 0
            )
        }
        return try TabletFrameSnapshot(bgra: bgra)
    }

    func attach(to view: MTKView) {
        if let metalView, metalView !== view {
            metalView.delegate = nil
        }

        view.device = device
        view.delegate = self
        view.colorPixelFormat = Self.pixelFormat
        view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        view.clearColor = MTLClearColor(
            red: 250 / 255,
            green: 249 / 255,
            blue: 245 / 255,
            alpha: 1
        )
        view.framebufferOnly = false
        view.autoResizeDrawable = true
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.wantsLayer = true
        view.layer?.isOpaque = true
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel("Paper Pro Move screen")
        metalView = view

        view.isHidden = false
        view.setNeedsDisplay(view.bounds)
    }

    func detach(from view: MTKView) {
        guard metalView === view else { return }
        view.delegate = nil
        metalView = nil
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.setNeedsDisplay(view.bounds)
    }

    func draw(in view: MTKView) {
        guard
            let drawable = view.currentDrawable,
            let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return
        }

        commandBuffer.label = "Present tablet frame"
        scaleKernel.encode(
            commandBuffer: commandBuffer,
            sourceTexture: texture,
            destinationTexture: drawable.texture
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private static func clear(
        texture: any MTLTexture,
        using commandQueue: any MTLCommandQueue
    ) -> Bool {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return false
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 250 / 255,
            green: 249 / 255,
            blue: 245 / 255,
            alpha: 1
        )
        guard
            let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: descriptor
            )
        else {
            return false
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed
    }
}

/// The SwiftUI seam for the Metal-backed tablet framebuffer.
@MainActor
struct TabletFrameView: NSViewRepresentable {
    let presentation: TabletFramePresentation

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero)
        presentation.attach(to: view)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        if view.delegate !== presentation {
            presentation.attach(to: view)
        }
    }

    static func dismantleNSView(_ view: MTKView, coordinator: Void) {
        (view.delegate as? TabletFramePresentation)?.detach(from: view)
    }
}
