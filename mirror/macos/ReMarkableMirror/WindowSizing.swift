import CoreGraphics
import Foundation

enum TabletStageMetrics {
    static let chassisSize = CGSize(width: 978, height: 1_720)
    static let horizontalPadding: CGFloat = 6
    static let verticalPadding: CGFloat = 10
}

struct WindowLayout: Equatable, Sendable {
    static let filesWidth: CGFloat = 320
    static let headerHeight: CGFloat = 66
    static let stageMargin: CGFloat = 6
    static let fixed = WindowLayout()

    let outerHeight: CGFloat = 877
    let compactWidth: CGFloat = 456

    private init() {}

    var expandedWidth: CGFloat {
        compactWidth + Self.filesWidth
    }

    var compactStageWidth: CGFloat {
        compactWidth - (Self.stageMargin * 2)
    }

    func initialFrame(in visibleFrame: CGRect) -> CGRect {
        let preferredX = visibleFrame.midX - (expandedWidth / 2)
        let minimumX = visibleFrame.minX + 16
        let maximumX = max(minimumX, visibleFrame.maxX - expandedWidth - 16)
        let x = min(max(preferredX, minimumX), maximumX)
        let preferredY = visibleFrame.midY - (outerHeight / 2)
        let minimumY = visibleFrame.minY + 16
        let maximumY = max(minimumY, visibleFrame.maxY - outerHeight - 16)
        let y = min(max(preferredY, minimumY), maximumY)

        return CGRect(x: x, y: y, width: compactWidth, height: outerHeight)
    }

    func frame(
        preservingTopLeftOf oldFrame: CGRect,
        visualProgress: Double,
        within visibleFrame: CGRect
    ) -> CGRect {
        let clamped = min(max(visualProgress, 0), 1)
        let width = compactWidth + (Self.filesWidth * CGFloat(clamped))
        let minimumX = visibleFrame.minX + 16
        let maximumX = max(minimumX, visibleFrame.maxX - width - 16)
        let x = min(max(oldFrame.minX, minimumX), maximumX)
        let minimumY = visibleFrame.minY + 16
        let maximumY = max(minimumY, visibleFrame.maxY - oldFrame.height - 16)
        let y = min(max(oldFrame.minY, minimumY), maximumY)

        return CGRect(
            x: x,
            y: y,
            width: width,
            height: oldFrame.height
        )
    }
}

enum FilesMotion {
    static let openingDuration: TimeInterval = 0.250
    static let closingDuration: TimeInterval = 0.167

    static func smoothstep(_ progress: Double) -> Double {
        let clamped = min(max(progress, 0), 1)
        return clamped * clamped * (3 - (2 * clamped))
    }

    static func advancedLinearProgress(
        from progress: Double,
        opening: Bool,
        elapsed: TimeInterval
    ) -> Double {
        let duration = opening ? openingDuration : closingDuration
        let signedDelta = elapsed / duration * (opening ? 1 : -1)
        return min(max(progress + signedDelta, 0), 1)
    }
}
