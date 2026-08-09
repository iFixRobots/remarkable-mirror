import os

/// Fixed-name Points of Interest intervals for the few product operations
/// whose wall-clock duration is useful during Instruments captures.
enum PerformanceSignposts {
    struct Interval: Sendable {
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState
    }

    private static let signposter = OSSignposter(
        subsystem: "com.ifixrobots.ReMarkableMirror",
        category: .pointsOfInterest
    )

    static func begin(_ name: StaticString) -> Interval {
        Interval(name: name, state: signposter.beginInterval(name))
    }

    static func end(_ interval: Interval) {
        signposter.endInterval(interval.name, interval.state)
    }
}
