enum WiFiRepairProbeResult: Equatable, Sendable {
    case success
    case authenticatedTabletPrerequisiteMismatch
    case identityRejected
    case other
}

enum WiFiRepairDisposition: Equatable, Sendable {
    case offline
    case repair
}

/// Prevents one transitional Wi-Fi capability mismatch from becoming a repair
/// requirement. Direct USB setup failures do not pass through this policy.
struct WiFiRepairConfirmationPolicy: Sendable {
    private static let requiredConsecutiveMatches = 2

    private var candidateRoute: VerifiedWiFiRoute?
    private var consecutiveMatches = 0

    mutating func record(
        route: VerifiedWiFiRoute?,
        result: WiFiRepairProbeResult
    ) -> WiFiRepairDisposition {
        guard let route,
              result == .authenticatedTabletPrerequisiteMismatch else {
            reset()
            return .offline
        }

        if candidateRoute != route {
            candidateRoute = route
            consecutiveMatches = 0
        }

        consecutiveMatches = min(
            consecutiveMatches + 1,
            Self.requiredConsecutiveMatches
        )
        return consecutiveMatches >= Self.requiredConsecutiveMatches
            ? .repair
            : .offline
    }

    mutating func reset() {
        candidateRoute = nil
        consecutiveMatches = 0
    }
}
