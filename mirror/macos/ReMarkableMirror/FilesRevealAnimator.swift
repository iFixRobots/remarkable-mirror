import AppKit
import QuartzCore

@MainActor
final class FilesRevealAnimator: NSObject {
    private weak var window: NSWindow?
    private let model: AppModel
    private let applyStageChrome: (Double) -> Void
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var filesRefreshTask: Task<Void, Never>?
    private var compactOrigin: CGPoint?
    private var lastAppliedFrame: CGRect?

    init(
        window: NSWindow,
        model: AppModel,
        applyStageChrome: @escaping (Double) -> Void
    ) {
        self.window = window
        self.model = model
        self.applyStageChrome = applyStageChrome
        super.init()
    }

    func toggle() {
        setOpen(!model.filesDesiredOpen)
    }

    private func setOpen(_ isOpen: Bool) {
        let target = isOpen ? 1.0 : 0.0
        let now = CACurrentMediaTime()
        if isOpen, model.filesProgress <= 0.000_1 {
            compactOrigin = window?.frame.origin
        } else if !isOpen, windowOriginWasExternallyMoved {
            // Honor an intentional move made while Files was open. Automatic
            // right-edge clamping alone keeps the original compact origin.
            compactOrigin = window?.frame.origin
        }
        filesRefreshTask?.cancel()
        filesRefreshTask = nil
        model.filesDesiredOpen = isOpen
        model.filesFullyOpen = false

        guard abs(target - model.filesProgress) > 0.000_1 else {
            stopDisplayLink()
            apply(linearProgress: target)
            return
        }

        lastTimestamp = now
        startDisplayLinkIfNeeded()
    }

    func applyCurrentProgress() {
        adoptCurrentWindowOriginIfExternallyMoved()
        apply(linearProgress: model.filesProgress)
    }

    func stop() {
        stopDisplayLink()
        filesRefreshTask?.cancel()
        filesRefreshTask = nil
    }

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil, let window else { return }

        let link = window.displayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
    }

    private var windowOriginWasExternallyMoved: Bool {
        guard let window, let lastAppliedFrame else { return false }
        return abs(window.frame.minX - lastAppliedFrame.minX) > 0.5 ||
            abs(window.frame.minY - lastAppliedFrame.minY) > 0.5
    }

    private func adoptCurrentWindowOriginIfExternallyMoved() {
        guard windowOriginWasExternallyMoved, let window else { return }
        compactOrigin = window.frame.origin
        lastAppliedFrame = window.frame
    }

    @objc
    private func displayLinkDidFire(_ link: CADisplayLink) {
        let timestamp = max(link.timestamp, CACurrentMediaTime())
        let nextProgress = advancedLinearProgress(
            to: timestamp,
            opening: model.filesDesiredOpen
        )
        apply(linearProgress: nextProgress)

        let reachedEndpoint = model.filesDesiredOpen
            ? nextProgress >= 1
            : nextProgress <= 0
        if reachedEndpoint {
            stopDisplayLink()
        }
    }

    private func advancedLinearProgress(
        to timestamp: CFTimeInterval,
        opening: Bool
    ) -> Double {
        guard let previousTimestamp = lastTimestamp else {
            lastTimestamp = timestamp
            return model.filesProgress
        }

        let elapsed = max(0, timestamp - previousTimestamp)
        let nextProgress = FilesMotion.advancedLinearProgress(
            from: model.filesProgress,
            opening: opening,
            elapsed: elapsed
        )
        lastTimestamp = timestamp
        return nextProgress
    }

    private func apply(linearProgress: Double) {
        guard let window else { return }

        let clamped = min(max(linearProgress, 0), 1)
        let wasFullyOpen = model.filesFullyOpen
        let isFullyOpen = model.filesDesiredOpen && clamped == 1
        model.filesProgress = clamped
        model.filesFullyOpen = isFullyOpen
        let visualProgress = FilesMotion.smoothstep(clamped)
        let oldFrame = window.frame
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? oldFrame
        let anchorFrame = CGRect(
            origin: compactOrigin ?? oldFrame.origin,
            size: oldFrame.size
        )
        let frame = model.layout.frame(
            preservingTopLeftOf: anchorFrame,
            visualProgress: visualProgress,
            within: visibleFrame
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.setFrame(frame, display: false, animate: false)
        lastAppliedFrame = frame
        applyStageChrome(visualProgress)
        CATransaction.commit()
        window.displayIfNeeded()

        if isFullyOpen, !wasFullyOpen {
            filesRefreshTask = Task { [weak model = model] in
                guard let model,
                      model.filesDesiredOpen,
                      model.filesFullyOpen else { return }
                await model.filesPane.refresh()
            }
        }
    }
}
