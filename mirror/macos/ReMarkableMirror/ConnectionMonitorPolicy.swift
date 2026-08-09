import Foundation

enum MonitorRouteBinding: Equatable, Sendable {
    case usb(DirectUSBRouteContext)
    case wifi(route: VerifiedWiFiRoute, interfaceName: String)
    case manualWiFi(host: String, context: WiFiNetworkSessionContext)

    var kind: ConnectionRoute {
        switch self {
        case .usb: .usb
        case .wifi, .manualWiFi: .wifi
        }
    }

    var boundInterface: String {
        switch self {
        case let .usb(context): context.interfaceName
        case let .wifi(_, interfaceName): interfaceName
        case let .manualWiFi(_, context): context.interfaceName
        }
    }
}

struct ManualWiFiConnection: Equatable, Sendable {
    let host: String
    let context: WiFiNetworkSessionContext
}

struct MonitorRouteCandidate: Equatable, Sendable {
    let binding: MonitorRouteBinding
    let route: SSHRoute

    static func make(
        binding: MonitorRouteBinding,
        paths: DeviceProfilePaths
    ) throws -> MonitorRouteCandidate {
        let host: String
        switch binding {
        case .usb:
            host = DeviceProfile.requiredHostKeyAlias
        case let .wifi(wifiRoute, _):
            host = wifiRoute.host
        case let .manualWiFi(manualHost, _):
            host = manualHost
        }

        return MonitorRouteCandidate(
            binding: binding,
            route: try SSHRoute(
                kind: binding.kind,
                host: host,
                identityURL: paths.privateKey,
                knownHostsURL: paths.knownHosts,
                boundInterface: binding.boundInterface
            )
        )
    }
}

struct MonitorRouteObservation: Equatable, Sendable {
    let outcome: RouteProbeOutcome
    let candidate: MonitorRouteCandidate?
    let capability: VerifiedTabletCapability?
    let evidence: ConnectionEvidence

    static func unavailable(_ evidence: ConnectionEvidence) -> Self {
        MonitorRouteObservation(
            outcome: .unavailable,
            candidate: nil,
            capability: nil,
            evidence: evidence
        )
    }

    static func authoritativeUSBWake(
        _ evidence: ConnectionEvidence,
        candidate: MonitorRouteCandidate
    ) -> Self {
        MonitorRouteObservation(
            outcome: .unavailable,
            candidate: candidate,
            capability: nil,
            evidence: evidence
        )
    }

    static func resolvingUSBWake(
        state: TabletWakeState,
        evidence: ConnectionEvidence,
        candidate: MonitorRouteCandidate,
        fallback: Self
    ) -> Self {
        if (state == .ready || state == .starting),
           fallback.outcome == .ready,
           fallback.candidate == candidate {
            return fallback
        }
        return .authoritativeUSBWake(
            evidence,
            candidate: candidate
        )
    }

    /// Transient retention is valid only for the exact route that is already
    /// active. A newly observed USB device or Wi-Fi interface has not passed
    /// authenticated admission and must be treated as unavailable until it
    /// produces a ready observation.
    func selectionOutcome(
        activeBinding: MonitorRouteBinding?
    ) -> RouteProbeOutcome {
        guard outcome == .transientFailure,
              let activeBinding,
              candidate?.binding != activeBinding else {
            return outcome
        }
        return .unavailable
    }

    var isAuthenticatedActivationCandidate: Bool {
        outcome == .ready && candidate != nil
    }
}

struct MonitorObservationEpoch: Sendable {
    typealias Token = UInt64

    private var value: UInt64 = 0

    func capture() -> Token {
        value
    }

    func isCurrent(_ token: Token) -> Bool {
        value == token
    }

    func advancedExactlyOnce(since token: Token) -> Bool {
        value == token &+ 1
    }

    mutating func advance() {
        value &+= 1
    }
}

enum MonitorPollCadence {
    static let retainedSSHReady: Duration = .seconds(10)
    static let authenticatedReady: Duration = .seconds(10)
    static let disconnected: Duration = .seconds(3)
    static let waking: Duration = .seconds(1)
    static let recovery: Duration = .seconds(2)

    static func interval(
        outcome: RouteProbeOutcome?,
        evidence: ConnectionEvidence,
        retainedActiveTransient: Bool = false
    ) -> Duration {
        if outcome == .ready {
            return authenticatedReady
        }
        if retainedActiveTransient {
            return retainedSSHReady
        }
        return switch evidence {
        case .offline:
            disconnected
        case .waking:
            waking
        default:
            recovery
        }
    }
}

enum MonitorGenerationAdmission {
    static func accepts(
        generation: GenerationID,
        activeGeneration: GenerationID?,
        transitionReservation: GenerationID?
    ) -> Bool {
        generation == activeGeneration && transitionReservation != generation
    }
}

enum USBWakeDirective: Equatable, Sendable {
    case publish(ConnectionEvidence)
    case sendWake
}

/// Stateful USB-only wake admission. A successful POST creates a short grace
/// window so the monitor does not publish Sleeping while the tablet is
/// transitioning, and another POST cannot be attempted more than once every
/// ten seconds.
struct USBWakePolicy: Sendable {
    static let minimumAttemptInterval: TimeInterval = 10
    static let wakingGraceInterval: TimeInterval = 10

    private var lastAttemptAt: TimeInterval?
    private var wakingUntil: TimeInterval?

    mutating func directive(
        for state: TabletWakeState,
        at now: TimeInterval
    ) -> USBWakeDirective {
        switch state {
        case .ready:
            wakingUntil = nil
            return .publish(.starting)
        case .unlockRequired:
            wakingUntil = nil
            return .publish(.unlockRequired)
        case .starting:
            wakingUntil = nil
            return .publish(.starting)
        case .sleeping:
            if let wakingUntil, now < wakingUntil {
                return .publish(.waking)
            }
            guard lastAttemptAt.map({ now - $0 }) ?? .infinity
                    >= Self.minimumAttemptInterval else {
                return .publish(.sleeping)
            }
            lastAttemptAt = now
            return .sendWake
        }
    }

    mutating func recordWakeSucceeded(at now: TimeInterval) {
        wakingUntil = now + Self.wakingGraceInterval
    }

    mutating func reset() {
        lastAttemptAt = nil
        wakingUntil = nil
    }
}

extension VerifiedTabletCapability {
    func isSemanticallyEquivalent(
        to other: VerifiedTabletCapability
    ) -> Bool {
        bootID == other.bootID &&
            activeRoot == other.activeRoot &&
            osVersion == other.osVersion &&
            osBuild == other.osBuild &&
            kernelRelease == other.kernelRelease &&
            probeVersion == other.probeVersion &&
            transportVersion == other.transportVersion &&
            transportSchema == other.transportSchema &&
            xoviVersion == other.xoviVersion
    }
}

protocol TabletWakeServicing: Sendable {
    func status() async throws -> TabletWakeResponse?
    func wake() async throws -> TabletWakeResponse?
}

extension TabletWakeClient: TabletWakeServicing { }

struct ConnectionMonitorServices: Sendable {
    let verifyUSB: @Sendable () async -> DirectUSBRouteVerification
    let currentWiFiSessionContext: @Sendable () throws -> WiFiNetworkSessionContext
    let matchWiFi: @Sendable (String) async throws -> WiFiNetworkContextMatch
    let probe: @Sendable (
        SSHRoute,
        GenerationID
    ) async throws -> PassiveRouteProbeResult
    let makeDirectCableRecoveryWakeClient: @Sendable (
        DirectUSBRouteContext
    ) async throws -> any TabletWakeServicing
    let now: @Sendable () -> Date
    let monotonicNow: @Sendable () -> TimeInterval

    static func production(
        directUSBRouteVerifier: DirectUSBRouteVerifier,
        wifiContextProvider: WiFiNetworkContextProvider,
        processRegistry: OwnedProcessRegistry
    ) -> ConnectionMonitorServices {
        ConnectionMonitorServices(
            verifyUSB: {
                await directUSBRouteVerifier.verify()
            },
            currentWiFiSessionContext: {
                try wifiContextProvider.currentSessionContext()
            },
            matchWiFi: { digest in
                try await wifiContextProvider.matchCurrentNetwork(
                    storedDigest: digest
                )
            },
            probe: { route, generation in
                let probe = PassiveRouteProbe(
                    route: route,
                    processRunner: processRegistry
                )
                return try await probe.probe(generation: generation)
            },
            makeDirectCableRecoveryWakeClient: { context in
                return try TabletWakeClient.makeDirectCableRecoveryUSB(
                    directUSBContext: context
                )
            },
            now: Date.init,
            monotonicNow: { ProcessInfo.processInfo.systemUptime }
        )
    }
}
