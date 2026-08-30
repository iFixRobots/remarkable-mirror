import AppKit
import SwiftUI

@MainActor
final class MirrorWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private let contentContainer = NSView()
    private let hostingView: NSHostingView<MirrorRootView>
    private let contentMaskLayer = CAShapeLayer()
    private let stageOutlineLayer = CAShapeLayer()
    private var revealAnimator: FilesRevealAnimator!

    init(model: AppModel) {
        self.model = model

        let screen = NSScreen.main ?? NSScreen.screens[0]

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.setFrame(
            model.layout.initialFrame(in: screen.visibleFrame),
            display: false
        )
        window.title = "reMarkable Mirror"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .none
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0, green: 10 / 255, blue: 35 / 255, alpha: 1)
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenNone, .fullScreenDisallowsTiling]
        window.animationBehavior = .none
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.toolTip = "The Mirror window has a fixed size."

        hostingView = NSHostingView(rootView: MirrorRootView(model: model))

        super.init(window: window)

        window.delegate = self
        configureContent(in: window)

        revealAnimator = FilesRevealAnimator(
            window: window,
            model: model,
            applyStageChrome: { [weak self] visualProgress in
                self?.applyStageChrome(visualProgress: visualProgress)
            }
        )
        model.requestFilesToggle = { [weak revealAnimator] in
            revealAnimator?.toggle()
        }

        revealAnimator.applyCurrentProgress()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureContent(in window: NSWindow) {
        contentContainer.wantsLayer = true
        contentContainer.layer?.masksToBounds = true
        window.contentView = contentContainer

        hostingView.frame = CGRect(
            x: 0,
            y: 0,
            width: model.layout.expandedWidth,
            height: contentContainer.bounds.height
        )
        hostingView.autoresizingMask = [.height]
        contentContainer.addSubview(hostingView)

        contentMaskLayer.fillColor = NSColor.white.cgColor
        contentContainer.layer?.mask = contentMaskLayer

        stageOutlineLayer.fillColor = NSColor.clear.cgColor
        stageOutlineLayer.lineWidth = 2
        stageOutlineLayer.strokeColor = NSColor(
            red: 207 / 255,
            green: 207 / 255,
            blue: 201 / 255,
            alpha: 0.65
        ).cgColor
        updateLayerContentsScale()
        contentContainer.layer?.addSublayer(stageOutlineLayer)
    }

    private func applyStageChrome(visualProgress: Double) {
        let bounds = contentContainer.bounds
        let contentWidth = model.layout.compactWidth
            + (WindowLayout.filesWidth * CGFloat(visualProgress))
        let stageFrame = CGRect(
            x: WindowLayout.stageMargin,
            y: WindowLayout.stageMargin,
            width: max(0, contentWidth - (WindowLayout.stageMargin * 2)),
            height: max(
                0,
                bounds.height - WindowLayout.headerHeight - WindowLayout.stageMargin
            )
        )
        let headerFrame = CGRect(
            x: 0,
            y: max(0, bounds.height - WindowLayout.headerHeight),
            width: contentWidth,
            height: WindowLayout.headerHeight
        )

        let stagePath = CGPath(
            roundedRect: stageFrame,
            cornerWidth: 24,
            cornerHeight: 24,
            transform: nil
        )
        let maskPath = CGMutablePath()
        maskPath.addRect(headerFrame)
        maskPath.addPath(stagePath)

        contentMaskLayer.frame = bounds
        contentMaskLayer.path = maskPath

        stageOutlineLayer.frame = bounds
        stageOutlineLayer.path = stagePath

        contentContainer.needsDisplay = true
    }

    private func updateLayerContentsScale() {
        guard let window else { return }
        contentMaskLayer.contentsScale = window.backingScaleFactor
        stageOutlineLayer.contentsScale = window.backingScaleFactor
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        updateLayerContentsScale()
        revealAnimator.applyCurrentProgress()
    }

    func windowWillClose(_ notification: Notification) {
        revealAnimator.stop()
    }

    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        false
    }
}
