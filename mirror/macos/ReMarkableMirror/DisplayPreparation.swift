import Foundation
import Security

enum DisplayPreparationFailureKind: Equatable, Sendable {
    case secureConnectionUnavailable
    case authenticationRejected
    case hostIdentityChanged
    case companionMissing
    case companionNotReady
    case companionFailed
    case protocolMismatch
    case connectionProcessUnavailable
    case streamInterrupted
}

struct DisplayPreparationFailure: Error, Equatable, Sendable {
    let kind: DisplayPreparationFailureKind
    let message: String
    let canAutoRetry: Bool
    let technicalDetail: String
}

struct DisplayPreparationResult: Equatable, Sendable {
    let startedXovi: Bool
}

enum XoviActivationOutcome: String, Equatable, Sendable {
    case running
    case readyAlready = "ready_already"
    case readyStarted = "ready_started"
    case failedUnchanged = "failed_unchanged"
    case failedRolledBack = "failed_rolled_back"
    case failedUnknown = "failed_unknown"

    var isFailure: Bool {
        switch self {
        case .failedUnchanged, .failedRolledBack, .failedUnknown:
            true
        case .running, .readyAlready, .readyStarted:
            false
        }
    }
}

struct XoviActivationStatus: Equatable, Sendable {
    let attempt: String
    let outcome: XoviActivationOutcome
    let errorCode: String?
}

enum DisplayReadinessMarker: Equatable, Sendable {
    case ready
    case notReady
}

enum DisplayPreparationParsing {
    static let activationSchema = "rmmirror.xovi-activation/v1"
    static let maximumActivationStatusBytes = 4_096
    static let maximumReadinessOutputBytes = 8_192

    static func activationStatus(from data: Data) throws -> XoviActivationStatus {
        guard !data.isEmpty,
              data.count <= maximumActivationStatusBytes,
              String(data: data, encoding: .utf8) != nil else {
            throw invalidActivationStatus()
        }

        let values: [String: String]
        do {
            var parser = StrictStringJSONObjectParser(data: data)
            values = try parser.parse()
        } catch {
            throw invalidActivationStatus()
        }

        let allowedKeys: Set<String> = ["schema", "attempt", "outcome", "error_code"]
        guard Set(values.keys).isSubset(of: allowedKeys),
              values["schema"] == activationSchema,
              let attempt = values["attempt"],
              isActivationAttempt(attempt),
              let outcomeValue = values["outcome"],
              let outcome = XoviActivationOutcome(rawValue: outcomeValue),
              outcome.isFailure == (values["error_code"] != nil),
              values.count == (outcome.isFailure ? 4 : 3) else {
            throw invalidActivationStatus()
        }

        if let errorCode = values["error_code"], !isActivationErrorCode(errorCode) {
            throw invalidActivationStatus()
        }

        return XoviActivationStatus(
            attempt: attempt,
            outcome: outcome,
            errorCode: values["error_code"]
        )
    }

    static func readinessMarker(from data: Data) throws -> DisplayReadinessMarker {
        guard data.count <= maximumReadinessOutputBytes,
              let output = String(data: data, encoding: .utf8) else {
            throw invalidReadinessMarker()
        }

        let bytes = Array(output.utf8)
        var foundReady = false
        var foundNotReady = false
        var lineStart = 0
        var index = 0
        while index <= bytes.count {
            guard index == bytes.count || bytes[index] == 0x0A || bytes[index] == 0x0D else {
                index += 1
                continue
            }
            let line = String(decoding: bytes[lineStart..<index], as: UTF8.self)
            if line == "RMMIRROR_DISPLAY_READY=ready" {
                foundReady = true
            } else if line == "RMMIRROR_DISPLAY_READY=not_ready" {
                foundNotReady = true
            }
            guard index < bytes.count else { break }
            let separator = bytes[index]
            index += 1
            if separator == 0x0D, index < bytes.count, bytes[index] == 0x0A {
                index += 1
            }
            lineStart = index
        }

        guard foundReady != foundNotReady else {
            throw invalidReadinessMarker()
        }
        return foundReady ? .ready : .notReady
    }

    static func isActivationAttempt(_ value: String) -> Bool {
        let bytes = value.utf8
        return bytes.count == 32 && bytes.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) ||
                (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    private static func isActivationErrorCode(_ value: String) -> Bool {
        let bytes = value.utf8
        return (1...64).contains(bytes.count) && bytes.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) ||
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) ||
                byte == UInt8(ascii: "_")
        }
    }

    private static func invalidActivationStatus() -> DisplayPreparationFailure {
        DisplayPreparationFailureFactory.protocolMismatch(
            "category=activation_status_invalid"
        )
    }

    private static func invalidReadinessMarker() -> DisplayPreparationFailure {
        DisplayPreparationFailureFactory.protocolMismatch(
            "category=display_readiness_invalid"
        )
    }
}

protocol ActivationAttemptGenerating: Sendable {
    func makeAttempt() throws -> String
}

struct SecureActivationAttemptGenerator: ActivationAttemptGenerating {
    func makeAttempt() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SecureActivationAttemptError.randomUnavailable
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

private enum SecureActivationAttemptError: Error {
    case randomUnavailable
}

struct DisplayPreparationTiming: Sendable {
    let now: @Sendable () async -> Duration
    let sleep: @Sendable (Duration) async throws -> Void

    static func continuous() -> DisplayPreparationTiming {
        let clock = ContinuousClock()
        let origin = clock.now
        return DisplayPreparationTiming(
            now: { origin.duration(to: clock.now) },
            sleep: { duration in try await Task.sleep(for: duration) }
        )
    }
}

struct DisplayPreparationPolicy: Equatable, Sendable {
    let activationPollTimeout: Duration
    let activationTransientTimeout: Duration
    let freshReadinessTimeout: Duration
    let pollInterval: Duration

    static let production = DisplayPreparationPolicy(
        activationPollTimeout: .seconds(120),
        activationTransientTimeout: .seconds(20),
        freshReadinessTimeout: .seconds(25),
        pollInterval: .milliseconds(350)
    )
}

actor DisplayPreparationService {
    static let activationStatusCommand =
        "/home/root/.local/bin/rmmirror-probe xovi-activation-status"
    static let activationCommandPrefix =
        "/home/root/.local/bin/rmmirror-probe xovi-activate --attempt "

    // Keep this byte-for-byte aligned with Windows SshFrameSource.EnsureDisplayReadyCommand.
    static let readinessShell = #"""
probe=/home/root/.local/bin/rmmirror-probe
xovi=/home/root/xovi

if ! test -x "$probe"; then
  printf '%s\n' 'rmmirror: companion_missing' >&2
  exit 40
fi

cancel_pending_system_sleep() {
  systemctl stop suspend-then-hibernate.target >/dev/null 2>&1 || true
  systemctl stop systemd-suspend-then-hibernate.service >/dev/null 2>&1 || true
  for sleep_unit in suspend-then-hibernate.target systemd-suspend-then-hibernate.service; do
    sleep_state=$(systemctl is-active "$sleep_unit" 2>/dev/null || true)
    case "$sleep_state" in
      inactive|failed) ;;
      *) return 1 ;;
    esac
  done
}

if test "$allow_start" -eq 1 && ! cancel_pending_system_sleep; then
  printf '%s\n' 'rmmirror: sleep_cancel_failed' >&2
  exit 49
fi

if test "$allow_start" -eq 1; then
  input_ready_output=$("$probe" input-ready --restore-timeout 50s 2>&1) || {
    printf '%s\n' 'rmmirror: input_restore_not_ready' >&2
    printf '%s\n' "$input_ready_output" | tail -c 800 >&2
    exit 47
  }
fi

display_ready() {
  "$probe" snapshot 2>/dev/null | grep -q '"framebuffer_address_seen":true'
}

runtime_ready() {
  runtime_pid="$(pidof xochitl || true)"
  test -n "$runtime_pid" &&
    test -p /run/xovi-mb &&
    test -p /run/xovi-mb-out &&
    grep -Fq "$xovi/xovi.so" "/proc/$runtime_pid/maps" &&
    grep -Fq "$xovi/extensions.d/framebuffer-spy.so" "/proc/$runtime_pid/maps" &&
    grep -Fq "$xovi/extensions.d/xovi-message-broker.so" "/proc/$runtime_pid/maps" &&
    grep -Fq "$xovi/extensions.d/rmmirror-files-loopback.so" "/proc/$runtime_pid/maps" &&
    ! grep -Fq "$xovi/extensions.d/qt-resource-rebuilder.so" "/proc/$runtime_pid/maps" &&
    ! grep -Fq "$xovi/extensions.d/webserver-remote.so" "/proc/$runtime_pid/maps" &&
    systemctl is-active --quiet xochitl &&
    systemctl is-active --quiet rm-sync
}

if display_ready && runtime_ready; then
  printf '%s\n' 'RMMIRROR_DISPLAY_READY=ready'
  exit 0
fi

attempt=0
while test "$attempt" -lt "$readiness_attempts"; do
  sleep 0.25
  if display_ready && runtime_ready; then
    printf '%s\n' 'RMMIRROR_DISPLAY_READY=ready'
    exit 0
  fi
  attempt=$((attempt + 1))
done

printf '%s\n' 'RMMIRROR_DISPLAY_READY=not_ready'
exit 0
"""#

    private let route: SSHRoute
    private let processRunner: any ProcessRunning
    private let attemptGenerator: any ActivationAttemptGenerating
    private let timing: DisplayPreparationTiming
    private let policy: DisplayPreparationPolicy
    private var activeGeneration: GenerationID?

    init(route: SSHRoute, registry: OwnedProcessRegistry) {
        self.init(
            route: route,
            processRunner: registry,
            attemptGenerator: SecureActivationAttemptGenerator(),
            timing: .continuous(),
            policy: .production
        )
    }

    init(
        route: SSHRoute,
        processRunner: any ProcessRunning,
        attemptGenerator: any ActivationAttemptGenerating = SecureActivationAttemptGenerator(),
        timing: DisplayPreparationTiming = .continuous(),
        policy: DisplayPreparationPolicy = .production
    ) {
        self.route = route
        self.processRunner = processRunner
        self.attemptGenerator = attemptGenerator
        self.timing = timing
        self.policy = policy
    }

    func prepare(
        generation: GenerationID,
        allowStart: Bool
    ) async throws -> DisplayPreparationResult {
        guard activeGeneration == nil else {
            throw DisplayPreparationFailureFactory.companionNotReady(
                autoRetry: true,
                detail: "category=display_preparation_in_progress"
            )
        }
        activeGeneration = generation
        defer { activeGeneration = nil }
        return try await performPreparation(generation: generation, allowStart: allowStart)
    }

    static func readinessCommand(allowStart: Bool, readinessAttempts: Int) -> String {
        precondition(readinessAttempts >= 0)
        return "allow_start=\(allowStart ? 1 : 0)\n" +
            "readiness_attempts=\(readinessAttempts)\n" +
            readinessShell
    }

    private func performPreparation(
        generation: GenerationID,
        allowStart: Bool
    ) async throws -> DisplayPreparationResult {
        var activationStatus: XoviActivationStatus?
        if allowStart,
           let existing = try await readActivationStatus(generation: generation),
           existing.outcome == .running {
            activationStatus = existing
        }

        if activationStatus == nil {
            let ready = try await probeDisplayReadiness(
                generation: generation,
                allowStart: allowStart,
                readinessAttempts: allowStart ? 0 : 40,
                timeout: .seconds(150)
            )
            if ready {
                return DisplayPreparationResult(startedXovi: false)
            }

            if let afterPreflight = try await readActivationStatus(generation: generation),
               afterPreflight.outcome == .running {
                activationStatus = afterPreflight
            } else {
                guard allowStart else {
                    throw DisplayPreparationFailureFactory.displayRuntimeNotReady()
                }
                activationStatus = try await launchActivation(generation: generation)
            }
        }

        guard let activationStatus else {
            throw DisplayPreparationFailureFactory.protocolMismatch(
                "category=activation_status_missing"
            )
        }
        let completed = try await pollActivation(
            activationStatus,
            generation: generation
        )
        guard completed.outcome == .readyAlready || completed.outcome == .readyStarted else {
            throw DisplayPreparationFailureFactory.activationFailure(completed)
        }

        try await waitForFreshDisplayReadiness(generation: generation)
        return DisplayPreparationResult(startedXovi: completed.outcome == .readyStarted)
    }

    private func probeDisplayReadiness(
        generation: GenerationID,
        allowStart: Bool,
        readinessAttempts: Int,
        timeout: Duration
    ) async throws -> Bool {
        let result = try await run(
            command: Self.readinessCommand(
                allowStart: allowStart,
                readinessAttempts: readinessAttempts
            ),
            generation: generation,
            timeout: timeout
        )
        guard result.outcome != .timedOut else {
            throw DisplayPreparationFailureFactory.companionNotReady(
                autoRetry: false,
                detail: "category=display_preparation_timeout"
            )
        }
        guard case let .exited(status) = result.outcome else {
            throw DisplayPreparationFailureFactory.streamInterrupted(
                "category=display_preparation_outcome_invalid"
            )
        }
        guard status == 0 else {
            throw DisplayPreparationFailureFactory.classifyPreparationExit(
                status: status,
                standardError: result.standardError.data
            )
        }
        guard !result.standardOutput.wasTruncated else {
            throw DisplayPreparationFailureFactory.protocolMismatch(
                "category=display_readiness_truncated"
            )
        }

        switch try DisplayPreparationParsing.readinessMarker(from: result.standardOutput.data) {
        case .ready:
            return true
        case .notReady:
            return false
        }
    }

    private func readActivationStatus(
        generation: GenerationID
    ) async throws -> XoviActivationStatus? {
        let result = try await run(
            command: Self.activationStatusCommand,
            generation: generation,
            timeout: .seconds(8)
        )
        guard result.outcome != .timedOut else {
            throw DisplayPreparationFailureFactory.secureConnectionUnavailable(
                "category=activation_status_timeout"
            )
        }
        guard case let .exited(status) = result.outcome else {
            throw DisplayPreparationFailureFactory.streamInterrupted(
                "category=activation_status_outcome_invalid"
            )
        }
        if status == 0 {
            guard !result.standardOutput.wasTruncated else {
                throw DisplayPreparationFailureFactory.protocolMismatch(
                    "category=activation_status_truncated"
                )
            }
            return try DisplayPreparationParsing.activationStatus(from: result.standardOutput.data)
        }

        let standardError = String(decoding: result.standardError.data, as: UTF8.self)
        if Self.containsAny(
            standardError,
            "xovi_activation_status_unavailable",
            "xovi_activation_status_stale"
        ) {
            return nil
        }
        throw DisplayPreparationFailureFactory.classifyExit(
            status: status,
            standardError: result.standardError.data
        )
    }

    private func launchActivation(
        generation: GenerationID
    ) async throws -> XoviActivationStatus {
        let attempt: String
        do {
            attempt = try attemptGenerator.makeAttempt()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DisplayPreparationFailureFactory.connectionProcessUnavailable(
                "category=secure_random_unavailable"
            )
        }
        guard DisplayPreparationParsing.isActivationAttempt(attempt) else {
            throw DisplayPreparationFailureFactory.connectionProcessUnavailable(
                "category=activation_attempt_generation_invalid"
            )
        }

        let result = try await run(
            command: Self.activationCommandPrefix + attempt,
            generation: generation,
            timeout: .seconds(12)
        )
        if result.outcome == .timedOut {
            return XoviActivationStatus(attempt: attempt, outcome: .running, errorCode: nil)
        }

        if !result.standardOutput.data.isEmpty {
            guard !result.standardOutput.wasTruncated else {
                throw DisplayPreparationFailureFactory.protocolMismatch(
                    "category=activation_status_truncated"
                )
            }
            let output = String(data: result.standardOutput.data, encoding: .utf8)
            if output == nil || !output!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let status = try DisplayPreparationParsing.activationStatus(
                    from: result.standardOutput.data
                )
                guard status.attempt == attempt else {
                    throw DisplayPreparationFailureFactory.protocolMismatch(
                        "category=activation_attempt_mismatch"
                    )
                }
                return status
            }
        }

        let standardError = String(decoding: result.standardError.data, as: UTF8.self)
        if Self.containsAny(standardError, "xovi_activation_busy") {
            if let existing = try await readActivationStatus(generation: generation),
               existing.outcome == .running {
                return existing
            }
            throw DisplayPreparationFailureFactory.companionNotReady(
                autoRetry: false,
                detail: "category=activation_busy_without_running_status"
            )
        }

        guard case let .exited(status) = result.outcome else {
            throw DisplayPreparationFailureFactory.streamInterrupted(
                "category=activation_launch_outcome_invalid"
            )
        }
        let failure = DisplayPreparationFailureFactory.classifyExit(
            status: status,
            standardError: result.standardError.data
        )
        if failure.kind == .secureConnectionUnavailable {
            return XoviActivationStatus(attempt: attempt, outcome: .running, errorCode: nil)
        }
        throw failure
    }

    private func pollActivation(
        _ initialStatus: XoviActivationStatus,
        generation: GenerationID
    ) async throws -> XoviActivationStatus {
        let expectedAttempt = initialStatus.attempt
        var status = initialStatus
        let startedAt = await timing.now()
        var transientStartedAt: Duration?
        var lastTransientFailure: DisplayPreparationFailure?

        while status.outcome == .running {
            try Task.checkCancellation()
            let beforePoll = await timing.now()
            guard beforePoll - startedAt < policy.activationPollTimeout else {
                break
            }

            do {
                if let observed = try await readActivationStatus(generation: generation) {
                    guard observed.attempt == expectedAttempt else {
                        throw DisplayPreparationFailureFactory.protocolMismatch(
                            "category=activation_attempt_mismatch"
                        )
                    }
                    status = observed
                    transientStartedAt = nil
                    lastTransientFailure = nil
                    if status.outcome != .running {
                        return status
                    }
                } else if transientStartedAt == nil {
                    transientStartedAt = await timing.now()
                }
            } catch let failure as DisplayPreparationFailure
                where failure.kind == .secureConnectionUnavailable {
                if transientStartedAt == nil {
                    transientStartedAt = await timing.now()
                }
                lastTransientFailure = failure
            }

            let afterPoll = await timing.now()
            if let transientStartedAt,
               afterPoll - transientStartedAt >= policy.activationTransientTimeout {
                throw lastTransientFailure ?? DisplayPreparationFailureFactory.companionNotReady(
                    autoRetry: true,
                    detail: "category=activation_status_temporarily_unavailable"
                )
            }

            let remaining = policy.activationPollTimeout - (afterPoll - startedAt)
            guard remaining > .zero else { break }
            try await timing.sleep(min(policy.pollInterval, remaining))
        }

        if status.outcome != .running {
            return status
        }
        throw DisplayPreparationFailureFactory.companionNotReady(
            autoRetry: false,
            detail: "category=activation_poll_timeout"
        )
    }

    private func waitForFreshDisplayReadiness(
        generation: GenerationID
    ) async throws {
        let startedAt = await timing.now()
        var lastTransientFailure: DisplayPreparationFailure?

        while await timing.now() - startedAt < policy.freshReadinessTimeout {
            try Task.checkCancellation()
            do {
                if try await probeDisplayReadiness(
                    generation: generation,
                    allowStart: false,
                    readinessAttempts: 20,
                    timeout: .seconds(12)
                ) {
                    return
                }
                lastTransientFailure = nil
            } catch let failure as DisplayPreparationFailure
                where failure.kind == .secureConnectionUnavailable ||
                    failure.kind == .companionNotReady {
                lastTransientFailure = failure
            }

            let elapsed = await timing.now() - startedAt
            let remaining = policy.freshReadinessTimeout - elapsed
            guard remaining > .zero else { break }
            try await timing.sleep(min(policy.pollInterval, remaining))
        }

        throw lastTransientFailure ?? DisplayPreparationFailureFactory.displayRuntimeNotReady()
    }

    private func run(
        command: String,
        generation: GenerationID,
        timeout: Duration
    ) async throws -> ProcessExecutionResult {
        do {
            return try await processRunner.run(
                route.displayPreparationRequest(
                    command: command,
                    generation: generation
                ),
                timeout: timeout
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DisplayPreparationFailureFactory.connectionProcessUnavailable(
                "category=ssh_process_unavailable"
            )
        }
    }

    private static func containsAny(_ value: String, _ candidates: String...) -> Bool {
        let folded = value.lowercased()
        return candidates.contains { folded.contains($0.lowercased()) }
    }
}

private extension SSHRoute {
    func displayPreparationRequest(
        command: String,
        generation: GenerationID
    ) -> ProcessRequest {
        ProcessRequest(
            executableURL: Self.executableURL,
            arguments: [
                "-F", "/dev/null",
                "-i", identityURL.path,
                "-o", "BatchMode=yes",
                "-o", "IdentitiesOnly=yes",
                "-o", "IdentityAgent=none",
                "-o", "PasswordAuthentication=no",
                "-o", "KbdInteractiveAuthentication=no",
                "-o", "StrictHostKeyChecking=yes",
                "-o", "HostKeyAlgorithms=ssh-ed25519",
                "-o", "UserKnownHostsFile=\(OpenSSHConfigValue.quotedPath(knownHostsURL.path))",
                "-o", "GlobalKnownHostsFile=/dev/null",
                "-o", "HostKeyAlias=\(DeviceProfile.requiredHostKeyAlias)",
                "-o", "CheckHostIP=no",
                "-o", "UpdateHostKeys=no",
                "-o", "ConnectTimeout=3",
                "-o", "ServerAliveInterval=3",
                "-o", "ServerAliveCountMax=3",
                "-T", "root@\(host)", command,
            ],
            generation: generation,
            role: .passiveProbe,
            outputLimit: 8_192
        )
    }
}

private enum DisplayPreparationFailureFactory {
    static func secureConnectionUnavailable(
        _ detail: String
    ) -> DisplayPreparationFailure {
        DisplayPreparationFailure(
            kind: .secureConnectionUnavailable,
            message: "The secure connection is not ready. Check the tablet and cable, then choose Connect USB‑C or Connect Wi‑Fi again.",
            canAutoRetry: false,
            technicalDetail: detail
        )
    }

    static func protocolMismatch(_ detail: String) -> DisplayPreparationFailure {
        DisplayPreparationFailure(
            kind: .protocolMismatch,
            message: "The tablet mirror companion is incompatible with this app. Choose Set Up Again to update Mirror setup.",
            canAutoRetry: false,
            technicalDetail: detail
        )
    }

    static func companionNotReady(
        autoRetry: Bool,
        detail: String
    ) -> DisplayPreparationFailure {
        DisplayPreparationFailure(
            kind: .companionNotReady,
            message: autoRetry
                ? "The tablet display service is still starting. Wait a moment, then choose a connection again."
                : "The tablet display service could not be prepared safely. Choose Set Up Again before connecting.",
            canAutoRetry: false,
            technicalDetail: detail
        )
    }

    static func displayRuntimeNotReady() -> DisplayPreparationFailure {
        companionNotReady(
            autoRetry: true,
            detail: "category=display_runtime_not_ready"
        )
    }

    static func streamInterrupted(_ detail: String) -> DisplayPreparationFailure {
        DisplayPreparationFailure(
            kind: .streamInterrupted,
            message: "The tablet display connection stopped. Choose Connect USB‑C or Connect Wi‑Fi to start a new session.",
            canAutoRetry: false,
            technicalDetail: detail
        )
    }

    static func connectionProcessUnavailable(_ detail: String) -> DisplayPreparationFailure {
        DisplayPreparationFailure(
            kind: .connectionProcessUnavailable,
            message: "macOS could not open the secure tablet connection. Restart reMarkable Mirror, then choose a connection again.",
            canAutoRetry: false,
            technicalDetail: detail
        )
    }

    static func activationFailure(
        _ status: XoviActivationStatus
    ) -> DisplayPreparationFailure {
        let detail = "category=activation_\(status.outcome.rawValue); " +
            "error_code=\(status.errorCode ?? "missing")"
        if status.errorCode == "xovi_configuration_missing" ||
            status.errorCode == "xovi_worker_executable_failed" {
            return DisplayPreparationFailure(
                kind: .companionMissing,
                message: "Tablet mirror setup is incomplete. Choose Set Up Again to repair it.",
                canAutoRetry: false,
                technicalDetail: detail
            )
        }
        if status.outcome == .failedUnknown {
            return DisplayPreparationFailure(
                kind: .companionFailed,
                message: "The tablet display service stopped in an unverified state. Choose Set Up Again before connecting.",
                canAutoRetry: false,
                technicalDetail: detail
            )
        }
        return companionNotReady(autoRetry: false, detail: detail)
    }

    static func classifyPreparationExit(
        status: Int32,
        standardError: Data
    ) -> DisplayPreparationFailure {
        let error = String(decoding: standardError, as: UTF8.self)
        if containsAny(error, "rmmirror: companion_missing") {
            return DisplayPreparationFailure(
                kind: .companionMissing,
                message: "Tablet mirror setup is incomplete. Choose Set Up Again to repair it.",
                canAutoRetry: false,
                technicalDetail: technicalDetail(status: status, standardError: error)
            )
        }
        if containsAny(error, "rmmirror: display_runtime_not_ready") {
            return companionNotReady(
                autoRetry: true,
                detail: technicalDetail(status: status, standardError: error)
            )
        }
        if containsAny(
            error,
            "rmmirror: sleep_cancel_failed",
            "rmmirror: input_restore_not_ready"
        ) {
            return companionNotReady(
                autoRetry: false,
                detail: technicalDetail(status: status, standardError: error)
            )
        }
        return classifyExit(status: status, standardError: standardError)
    }

    static func classifyExit(
        status: Int32,
        standardError: Data
    ) -> DisplayPreparationFailure {
        let error = String(decoding: standardError, as: UTF8.self)
        let detail = technicalDetail(status: status, standardError: error)
        if containsAny(
            error,
            "REMOTE HOST IDENTIFICATION HAS CHANGED",
            "Host key verification failed"
        ) {
            return DisplayPreparationFailure(
                kind: .hostIdentityChanged,
                message: "The tablet's secure identity changed. Choose Set Up Again before connecting.",
                canAutoRetry: false,
                technicalDetail: detail
            )
        }
        if status == 255 && containsAny(
            error,
            "Permission denied",
            "no supported authentication methods available",
            "Too many authentication failures"
        ) {
            return DisplayPreparationFailure(
                kind: .authenticationRejected,
                message: "This Mac is no longer authorized to connect to the tablet. Choose Set Up Again before connecting.",
                canAutoRetry: false,
                technicalDetail: detail
            )
        }
        if containsAny(
            error,
            "not found",
            "No such file",
            "rmmirror: companion_missing"
        ) {
            return DisplayPreparationFailure(
                kind: .companionMissing,
                message: "The mirror companion is missing on the tablet. Choose Set Up Again to repair it.",
                canAutoRetry: false,
                technicalDetail: detail
            )
        }
        if containsAny(error, "rmmirror-probe:") {
            return DisplayPreparationFailure(
                kind: .companionFailed,
                message: "The tablet mirror companion stopped unexpectedly. Copy Connection Diagnostics from the Help menu, then choose Set Up Again.",
                canAutoRetry: false,
                technicalDetail: detail
            )
        }
        if containsAny(
            error,
            "Connection refused",
            "Connection timed out",
            "Operation timed out",
            "No route to host",
            "Network is unreachable",
            "Connection reset",
            "Connection closed",
            "Broken pipe",
            "kex_exchange_identification"
        ) || status == 255 {
            return secureConnectionUnavailable(detail)
        }
        return streamInterrupted(detail)
    }

    private static func technicalDetail(
        status: Int32,
        standardError: String
    ) -> String {
        let category: String
        if containsAny(
            standardError,
            "REMOTE HOST IDENTIFICATION HAS CHANGED",
            "Host key verification failed"
        ) {
            category = "host_identity_changed"
        } else if containsAny(
            standardError,
            "Permission denied",
            "no supported authentication methods available",
            "Too many authentication failures"
        ) {
            category = "authentication_rejected"
        } else if containsAny(
            standardError,
            "rmmirror: companion_missing",
            "rmmirror: xovi_missing"
        ) {
            category = "companion_missing"
        } else if containsAny(standardError, "rmmirror: display_runtime_not_ready") {
            category = "display_runtime_not_ready"
        } else if containsAny(standardError, "rmmirror: xovi_configuration_invalid") {
            category = "xovi_configuration_invalid"
        } else if containsAny(standardError, "rmmirror-probe:") {
            category = "companion_reported_failure"
        } else if containsAny(standardError, "Timeout, server") &&
            containsAny(standardError, "not responding") {
            category = "ssh_keepalive_timeout"
        } else if containsAny(
            standardError,
            "Connection refused",
            "Connection timed out",
            "Operation timed out",
            "No route to host",
            "Network is unreachable",
            "Connection reset",
            "Connection closed",
            "Broken pipe",
            "kex_exchange_identification"
        ) {
            category = "connection_unavailable"
        } else if standardError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            category = "stderr_empty"
        } else {
            category = "ssh_process_failed"
        }
        return "exit=\(status); category=\(category)"
    }

    private static func containsAny(_ value: String, _ candidates: String...) -> Bool {
        let folded = value.lowercased()
        return candidates.contains { folded.contains($0.lowercased()) }
    }
}

private enum StrictStringJSONError: Error {
    case invalid
}

private struct StrictStringJSONObjectParser {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func parse() throws -> [String: String] {
        skipWhitespace()
        try require(UInt8(ascii: "{"))
        skipWhitespace()
        if consume(UInt8(ascii: "}")) {
            skipWhitespace()
            guard index == bytes.count else { throw StrictStringJSONError.invalid }
            return [:]
        }

        var result: [String: String] = [:]
        while true {
            let key = try parseString()
            guard result[key] == nil else { throw StrictStringJSONError.invalid }
            skipWhitespace()
            try require(UInt8(ascii: ":"))
            skipWhitespace()
            let value = try parseString()
            result[key] = value
            skipWhitespace()
            if consume(UInt8(ascii: "}")) {
                break
            }
            try require(UInt8(ascii: ","))
            skipWhitespace()
        }

        skipWhitespace()
        guard index == bytes.count else { throw StrictStringJSONError.invalid }
        return result
    }

    private mutating func parseString() throws -> String {
        try require(UInt8(ascii: "\""))
        var value = ""
        var segmentStart = index

        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                try appendRawString(from: segmentStart, to: index, into: &value)
                index += 1
                return value
            }
            if byte == UInt8(ascii: "\\") {
                try appendRawString(from: segmentStart, to: index, into: &value)
                index += 1
                guard index < bytes.count else { throw StrictStringJSONError.invalid }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""):
                    value.append("\"")
                case UInt8(ascii: "\\"):
                    value.append("\\")
                case UInt8(ascii: "/"):
                    value.append("/")
                case UInt8(ascii: "b"):
                    value.append("\u{0008}")
                case UInt8(ascii: "f"):
                    value.append("\u{000C}")
                case UInt8(ascii: "n"):
                    value.append("\n")
                case UInt8(ascii: "r"):
                    value.append("\r")
                case UInt8(ascii: "t"):
                    value.append("\t")
                case UInt8(ascii: "u"):
                    try appendUnicodeEscape(into: &value)
                default:
                    throw StrictStringJSONError.invalid
                }
                segmentStart = index
                continue
            }
            guard byte >= 0x20 else { throw StrictStringJSONError.invalid }
            index += 1
        }
        throw StrictStringJSONError.invalid
    }

    private mutating func appendUnicodeEscape(into value: inout String) throws {
        let first = try readHexQuad()
        let scalarValue: UInt32
        if (0xD800...0xDBFF).contains(first) {
            guard consume(UInt8(ascii: "\\")), consume(UInt8(ascii: "u")) else {
                throw StrictStringJSONError.invalid
            }
            let second = try readHexQuad()
            guard (0xDC00...0xDFFF).contains(second) else {
                throw StrictStringJSONError.invalid
            }
            scalarValue = 0x10000 +
                (UInt32(first - 0xD800) << 10) +
                UInt32(second - 0xDC00)
        } else {
            guard !(0xDC00...0xDFFF).contains(first) else {
                throw StrictStringJSONError.invalid
            }
            scalarValue = UInt32(first)
        }
        guard let scalar = UnicodeScalar(scalarValue) else {
            throw StrictStringJSONError.invalid
        }
        value.unicodeScalars.append(scalar)
    }

    private mutating func readHexQuad() throws -> UInt16 {
        guard index + 4 <= bytes.count else { throw StrictStringJSONError.invalid }
        var value: UInt16 = 0
        for _ in 0..<4 {
            guard let digit = hexValue(bytes[index]) else {
                throw StrictStringJSONError.invalid
            }
            value = (value << 4) | UInt16(digit)
            index += 1
        }
        return value
    }

    private func appendRawString(
        from start: Int,
        to end: Int,
        into value: inout String
    ) throws {
        guard start <= end,
              let segment = String(bytes: bytes[start..<end], encoding: .utf8) else {
            throw StrictStringJSONError.invalid
        }
        value.append(segment)
    }

    private func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"):
            byte - UInt8(ascii: "A") + 10
        default:
            nil
        }
    }

    private mutating func skipWhitespace() {
        while index < bytes.count,
              bytes[index] == 0x20 || bytes[index] == 0x09 ||
              bytes[index] == 0x0A || bytes[index] == 0x0D {
            index += 1
        }
    }

    private mutating func require(_ byte: UInt8) throws {
        guard consume(byte) else { throw StrictStringJSONError.invalid }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }
}
