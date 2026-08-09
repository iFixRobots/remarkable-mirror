enum TabletInputRecoveryDisposition: Equatable, Sendable {
    case none
    case awaitingFrameInterruption
    case beginNow
}

enum TabletInputRecoveryPolicyError: Error, Equatable, Sendable {
    case negativeTimestamp
    case negativeMaximumAge
}

/// Gates interactive publication and bounds automatic input recovery to one
/// additional handoff per route generation.
///
/// Established-session loss must couple to display recovery. A setup failure
/// before publication must first reserve the same one-shot recovery budget.
actor TabletInputRecoveryPolicy {
    private struct TimedGeneration: Sendable {
        let generation: GenerationID
        let timestamp: Duration
    }

    private var scheduled: TimedGeneration?
    private var recentFrameFailure: TimedGeneration?
    private var consumedGeneration: GenerationID?
    private var requiredPublicationGeneration: GenerationID?

    func beginGeneration(_ generation: GenerationID) {
        scheduled = nil
        recentFrameFailure = nil
        consumedGeneration = nil

        // A Mirror route is interactive by definition. Its first Live
        // publication is gated on a running input session just like a recovery
        // publication is.
        requiredPublicationGeneration = generation
    }

    func recordFrameInterruption(
        _ generation: GenerationID,
        timestamp: Duration
    ) throws {
        try Self.validateTimestamp(timestamp)
        recentFrameFailure = TimedGeneration(
            generation: generation,
            timestamp: timestamp
        )
    }

    func recordPublishedSessionLoss(
        _ generation: GenerationID,
        timestamp: Duration,
        maximumAge: Duration,
        allowAutomaticRecovery: Bool
    ) throws -> TabletInputRecoveryDisposition {
        try Self.validate(timestamp: timestamp, maximumAge: maximumAge)

        // Losing a session that was already published always revokes the Live
        // promise until controls and a fresh frame coexist again.
        requiredPublicationGeneration = generation
        guard allowAutomaticRecovery, consumedGeneration != generation else {
            return .none
        }

        // Spend the one-shot budget before either observer can reset a
        // preparation epoch or perform remote work.
        consumedGeneration = generation
        if let frameFailure = recentFrameFailure,
           frameFailure.generation == generation {
            recentFrameFailure = nil
            if Self.isWithinMaximumAge(
                earlier: frameFailure.timestamp,
                later: timestamp,
                maximumAge: maximumAge
            ) {
                scheduled = nil
                return .beginNow
            }
        }

        // Input was observed first. A nearby frame interruption must consume
        // this marker before the retry latch can be cleared.
        scheduled = TimedGeneration(
            generation: generation,
            timestamp: timestamp
        )
        return .awaitingFrameInterruption
    }

    func tryConsumeScheduled(
        _ generation: GenerationID,
        timestamp: Duration,
        maximumAge: Duration
    ) throws -> Bool {
        try Self.validate(timestamp: timestamp, maximumAge: maximumAge)
        guard let scheduled, scheduled.generation == generation else {
            return false
        }

        // Matching observations consume the marker even when it is stale. A
        // later observation cannot make an expired interruption eligible.
        self.scheduled = nil
        return Self.isWithinMaximumAge(
            earlier: scheduled.timestamp,
            later: timestamp,
            maximumAge: maximumAge
        )
    }

    func tryReserveStoppedSessionRecovery(_ generation: GenerationID) -> Bool {
        guard consumedGeneration != generation else {
            return false
        }

        // Display recovery found the stopped established session first.
        // Reserve the same one-shot budget before disposing or restarting.
        consumedGeneration = generation
        scheduled = nil
        requiredPublicationGeneration = generation
        return true
    }

    func tryReserveSetupFailureRecovery(_ generation: GenerationID) -> Bool {
        guard consumedGeneration != generation else {
            return false
        }

        // A transient failure before publication may spend the same one-shot
        // budget. The host will rebuild both preparation barriers so the next
        // attempt first proves physical restoration again.
        consumedGeneration = generation
        scheduled = nil
        recentFrameFailure = nil
        requiredPublicationGeneration = generation
        return true
    }

    func requiresInputPublication(_ generation: GenerationID) -> Bool {
        requiredPublicationGeneration == generation
    }

    func markRecoveryComplete(_ generation: GenerationID) {
        if requiredPublicationGeneration == generation {
            requiredPublicationGeneration = nil
        }
    }

    func abandonGeneration(_ generation: GenerationID) {
        if scheduled?.generation == generation {
            scheduled = nil
        }
        if recentFrameFailure?.generation == generation {
            recentFrameFailure = nil
        }
        if requiredPublicationGeneration == generation {
            requiredPublicationGeneration = nil
        }
    }

    func rearmGeneration(_ generation: GenerationID) {
        if scheduled?.generation == generation {
            scheduled = nil
        }
        if recentFrameFailure?.generation == generation {
            recentFrameFailure = nil
        }
        if consumedGeneration == generation {
            consumedGeneration = nil
        }

        // Explicit Retry starts a fresh interactive publication attempt.
        requiredPublicationGeneration = generation
    }

    func reset() {
        scheduled = nil
        recentFrameFailure = nil
        consumedGeneration = nil
        requiredPublicationGeneration = nil
    }

    private static func validate(
        timestamp: Duration,
        maximumAge: Duration
    ) throws {
        try validateTimestamp(timestamp)
        guard maximumAge >= .zero else {
            throw TabletInputRecoveryPolicyError.negativeMaximumAge
        }
    }

    private static func validateTimestamp(_ timestamp: Duration) throws {
        guard timestamp >= .zero else {
            throw TabletInputRecoveryPolicyError.negativeTimestamp
        }
    }

    private static func isWithinMaximumAge(
        earlier: Duration,
        later: Duration,
        maximumAge: Duration
    ) -> Bool {
        // A monotonic clock moving backwards cannot prove that two failures
        // belong to the same interruption. Treat it as outside the window.
        guard later >= earlier else {
            return false
        }
        return later - earlier <= maximumAge
    }
}
