enum RouteProbeOutcome: Equatable, Sendable {
    case ready
    case transientFailure
    case unavailable
}

enum ManualRouteSessionDecision: Equatable, Sendable {
    case useSelectedRoute
    case waitForSelectedRoute
    case endSession
}

/// Health policy for the route chosen by one explicit Connect action.
///
/// An explicit Connect action may also own one bounded pre-activation recovery
/// window. USB-C can wake the tablet; Wi-Fi can wait for an owner-woken
/// tablet's services to return. Neither path can select, probe, promote, or
/// fall back to another route.
struct ManualRouteSessionPolicy: Sendable {
    private static let transientFailureThreshold = 3
    private static let transientFailureLimit = Duration.seconds(15)

    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant
    private let initialConnectionLimit: Duration
    private var transientFailures = TimedEvidence()

    init(initialConnectionLimit: Duration = .seconds(45)) {
        origin = clock.now
        self.initialConnectionLimit = initialConnectionLimit
    }

    mutating func evaluate(
        hasActiveRoute: Bool,
        outcome: RouteProbeOutcome,
        canWaitForInitialRecovery: Bool
    ) -> ManualRouteSessionDecision {
        let timestamp = origin.duration(to: clock.now)
        switch outcome {
        case .ready:
            transientFailures.reset()
            return .useSelectedRoute
        case .transientFailure:
            if !hasActiveRoute {
                transientFailures.reset()
                if canWaitForInitialRecovery,
                   timestamp < initialConnectionLimit {
                    return .waitForSelectedRoute
                }
                return .endSession
            }
            guard transientFailures.shouldRetainActiveRoute(
                at: timestamp,
                threshold: Self.transientFailureThreshold,
                limit: Self.transientFailureLimit
            ) else {
                transientFailures.reset()
                return .endSession
            }
            return .useSelectedRoute
        case .unavailable:
            transientFailures.reset()
            if !hasActiveRoute,
               canWaitForInitialRecovery,
               timestamp < initialConnectionLimit {
                return .waitForSelectedRoute
            }
            return .endSession
        }
    }
}

private struct TimedEvidence: Sendable {
    private var count = 0
    private var startedAt: Duration?

    mutating func shouldRetainActiveRoute(
        at timestamp: Duration,
        threshold: Int,
        limit: Duration
    ) -> Bool {
        record(at: timestamp)
        guard let startedAt, timestamp >= startedAt else {
            reset()
            return false
        }
        return count < threshold && timestamp - startedAt < limit
    }

    mutating func reset() {
        count = 0
        startedAt = nil
    }

    private mutating func record(at timestamp: Duration) {
        count += 1
        if startedAt == nil {
            startedAt = timestamp
        }
    }
}
