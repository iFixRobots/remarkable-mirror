import Foundation

enum RMM1InputReadCancellationBehavior: Equatable, Sendable {
    /// Cancellation makes response alignment unknowable, so the exact child
    /// must be discarded.
    case abortProcess

    /// Used only by startup and graceful-close work that must leave the child
    /// available for an EOF-driven physical-input restoration attempt.
    case preserveForGracefulClose
}

enum RMM1InputProcessWaitResult: Equatable, Sendable {
    case exited(ProcessExecutionResult)
    case deadlineExceeded
}

enum RMM1InputProcessError: Error, Equatable, Sendable {
    case readTimedOut
}

/// The narrow process boundary required by the input protocol. Production
/// launchers must create one no-PTY `/usr/bin/ssh` child using
/// `RMM1InputSession.remoteCommand`, with stdin/stdout/stderr kept separate.
protocol RMM1InputStreamingProcess: Actor {
    func write(_ data: Data) async throws
    func read(
        upToCount: Int,
        timeout: Duration?,
        cancellationBehavior: RMM1InputReadCancellationBehavior
    ) async throws -> Data
    func finishWriting() async
    func beginDiscardingOutput() async
    func waitForExit(timeout: Duration) async throws -> RMM1InputProcessWaitResult
    func abort(confirmationTimeout: Duration) async throws -> ProcessExecutionResult
    func isRunning() async -> Bool
}

protocol RMM1InputProcessLaunching: Actor {
    func launchInput(
        route: SSHRoute,
        generation: GenerationID
    ) async throws -> any RMM1InputStreamingProcess
}

struct RMM1InputTiming: Sendable {
    let now: @Sendable () async -> Duration
    let sleep: @Sendable (Duration) async throws -> Void

    static func continuous() -> RMM1InputTiming {
        let clock = ContinuousClock()
        let origin = clock.now
        return RMM1InputTiming(
            now: { origin.duration(to: clock.now) },
            sleep: { duration in try await clock.sleep(for: duration) }
        )
    }
}

enum RMM1InputFailureKind: String, Equatable, Sendable {
    case startupTimedOut
    case sessionBusy
    case displayServiceNotReady
    case heartbeatTimedOut
    case secureConnectionUnavailable
    case hostIdentityChanged
    case authenticationRejected
    case companionMissing
    case companionFailed
    case protocolMismatch
    case processUnavailable
    case connectionClosed
    case restorationUncertain
    case physicalRestoreFailed
    case queueFull
}

/// A UI-safe failure. `technicalDetail` is always a fixed classification code;
/// raw SSH stderr can contain local paths, addresses, and configuration and is
/// intentionally never retained here.
struct RMM1InputFailure: Error, Equatable, Sendable {
    let kind: RMM1InputFailureKind
    let isPersistent: Bool
    let technicalDetail: String

    init(
        _ kind: RMM1InputFailureKind,
        isPersistent: Bool,
        technicalDetail: String? = nil
    ) {
        self.kind = kind
        self.isPersistent = isPersistent
        self.technicalDetail = technicalDetail ?? kind.rawValue
    }
}

enum RMM1InputSessionState: Equatable, Sendable {
    case starting
    case running
    case closing
    case closed
    case failed
}

enum RMM1InputRestorationStatus: Equatable, Sendable {
    case confirmed
    case uncertain
}

struct RMM1InputStopResult: Equatable, Sendable {
    let restoration: RMM1InputRestorationStatus
    let failure: RMM1InputFailure?
}

struct RMM1InputSessionSnapshot: Equatable, Sendable {
    let state: RMM1InputSessionState
    let processIsRunning: Bool
    let terminalFailure: RMM1InputFailure?
    let restoration: RMM1InputRestorationStatus
}

actor RMM1InputSession {
    static let remoteCommand =
        "/home/root/.local/bin/rmmirror-probe input --heartbeat-timeout 15s"

    static let startupTimeout: Duration = .seconds(100)
    static let heartbeatInterval: Duration = .seconds(3)
    static let wifiActivityInterval: Duration = .seconds(10)
    static let usbActivityInterval: Duration = .seconds(45)
    static let commandDrainTimeout: Duration = .seconds(2)
    static let gracefulShutdownTimeout: Duration = .seconds(100)
    static let forcedShutdownTimeout: Duration = .seconds(3)
    static let maximumQueuedCommands = 64

    nonisolated let generation: GenerationID
    nonisolated let handshake: TabletInputHandshake
    nonisolated let routeKind: ConnectionRoute

    private enum Payload: Sendable {
        case event(TabletInputEvent)
        case ping
    }

    private struct TransactionWaiter {
        let id: UUID
        let continuation: CheckedContinuation<UUID, any Error>
    }

    private struct StopWaiter {
        let id: UUID
        let continuation: CheckedContinuation<RMM1InputFailure?, any Error>
    }

    private let process: any RMM1InputStreamingProcess
    private let lineReader: RMM1InputLineReader
    private let timing: RMM1InputTiming

    private var state: RMM1InputSessionState = .starting
    private var deepSleepWakeAttempted = false
    private var lastActivityAt: Duration?
    private var lastHeartbeatAt: Duration?
    private var commandIDs = TabletInputCommandIDSequence()
    private var activeTransaction: UUID?
    private var transactionWaiters: [TransactionWaiter] = []
    private var stopWaiters: [StopWaiter] = []
    private var heartbeatTask: Task<Void, Never>?
    private var closeTask: Task<RMM1InputStopResult, Never>?
    private var completedStop: RMM1InputStopResult?
    private var terminalFailure: RMM1InputFailure?
    private var restorationIsUncertain = false

    private init(
        generation: GenerationID,
        handshake: TabletInputHandshake,
        routeKind: ConnectionRoute,
        process: any RMM1InputStreamingProcess,
        lineReader: RMM1InputLineReader,
        timing: RMM1InputTiming
    ) {
        self.generation = generation
        self.handshake = handshake
        self.routeKind = routeKind
        self.process = process
        self.lineReader = lineReader
        self.timing = timing
    }

    static func connect(
        route: SSHRoute,
        generation: GenerationID,
        launcher: any RMM1InputProcessLaunching,
        timing: RMM1InputTiming = .continuous()
    ) async throws -> RMM1InputSession {
        let process: any RMM1InputStreamingProcess
        do {
            process = try await launcher.launchInput(
                route: route,
                generation: generation
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as RMM1InputFailure {
            throw failure
        } catch {
            throw RMM1InputFailure(.processUnavailable, isPersistent: true)
        }

        let reader = RMM1InputLineReader()
        let startedAt = await timing.now()
        let deadline = startedAt + startupTimeout

        do {
            let readyLine = try await reader.nextLine(
                from: process,
                deadline: deadline,
                timing: timing,
                cancellationBehavior: .preserveForGracefulClose
            )
            let handshake: TabletInputHandshake
            do {
                handshake = try TabletInputWireCodec.parseHandshake(readyLine)
            } catch {
                throw RMM1InputFailure(.protocolMismatch, isPersistent: true)
            }

            let session = RMM1InputSession(
                generation: generation,
                handshake: handshake,
                routeKind: route.kind,
                process: process,
                lineReader: reader,
                timing: timing
            )
            try await session.start()
            return session
        } catch {
            let original = Self.startupFailure(from: error)
            let cleanup = await Task {
                await Self.stopProcessGracefully(process)
            }.value

            if cleanup.restoration == .uncertain {
                throw RMM1InputFailure(.restorationUncertain, isPersistent: true)
            }
            if error is CancellationError {
                throw CancellationError()
            }
            if let processFailure = cleanup.failure {
                throw processFailure
            }
            throw original
        }
    }

    /// Sends exactly one ordered touch, pen, key, text, or reset command and
    /// returns only after its matching acknowledgement arrives.
    func send(_ event: TabletInputEvent) async throws {
        // Validate locally before occupying the bounded FIFO or consuming an
        // ID. The actual line is encoded again with the owned sequence value.
        _ = try TabletInputWireCodec.encode(event: event, id: 1)
        try await transact(
            .event(event),
            allowStarting: false,
            cancellationBehavior: .abortProcess
        )
        markActivity(at: await timing.now())
    }

    func close() async -> RMM1InputStopResult {
        if let completedStop {
            return completedStop
        }
        if let closeTask {
            return await closeTask.value
        }

        state = .closing
        heartbeatTask?.cancel()
        heartbeatTask = nil
        failQueuedTransactions(
            with: RMM1InputFailure(.connectionClosed, isPersistent: false)
        )

        let task = Task { await self.performClose() }
        closeTask = task
        return await task.value
    }

    func snapshot() async -> RMM1InputSessionSnapshot {
        let running = await process.isRunning()
        return RMM1InputSessionSnapshot(
            state: state,
            processIsRunning: running,
            terminalFailure: terminalFailure,
            restoration: restorationIsUncertain ? .uncertain : .confirmed
        )
    }

    /// Suspends until the autonomous heartbeat fails or the session closes.
    /// Coordinators use this to revoke Live immediately without polling.
    func waitUntilStopped() async throws -> RMM1InputFailure? {
        if state == .failed || state == .closed {
            return terminalFailure
        }
        try Task.checkCancellation()

        let waiterID = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<RMM1InputFailure?, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                stopWaiters.append(
                    StopWaiter(id: waiterID, continuation: continuation)
                )
            }
        }, onCancel: {
            Task { await self.cancelStopWaiter(waiterID) }
        })
    }

    private func start() async throws {
        do {
            try await transact(
                .ping,
                allowStarting: true,
                cancellationBehavior: .abortProcess
            )
        } catch let rejection as TabletInputCommandRejection {
            let failure = RMM1InputFailure(
                .companionFailed,
                isPersistent: true,
                technicalDetail: "startup_ping_rejected_\(rejection.code)"
            )
            await failAndAbort(failure)
            throw failure
        }

        try await wakeIfDeepSleeping()
        if routeKind == .wifi {
            try await sendActivity(allowStarting: true)
        } else {
            markActivity(at: await timing.now())
        }

        guard state == .starting else {
            throw terminalFailure ?? RMM1InputFailure(
                .connectionClosed,
                isPersistent: false
            )
        }
        state = .running
        startHeartbeatLoop()
    }

    private func startHeartbeatLoop() {
        heartbeatTask = Task { [weak self] in
            await self?.runHeartbeatLoop()
        }
    }

    private func runHeartbeatLoop() async {
        while !Task.isCancelled, state == .running {
            do {
                let now = await timing.now()
                let nextHeartbeat = (lastHeartbeatAt ?? now) + Self.heartbeatInterval
                let nextActivity = (lastActivityAt ?? now) + activityInterval
                let nextDeadline = min(nextHeartbeat, nextActivity)
                if now < nextDeadline {
                    try await timing.sleep(nextDeadline - now)
                    try Task.checkCancellation()
                    guard state == .running else { return }
                    continue
                }

                if now >= nextActivity {
                    try await sendActivity(allowStarting: false)
                } else {
                    try await sendHeartbeat()
                }
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func sendHeartbeat() async throws {
        do {
            try await transact(
                .ping,
                allowStarting: false,
                cancellationBehavior: .preserveForGracefulClose
            )
        } catch let rejection as TabletInputCommandRejection {
            let failure = RMM1InputFailure(
                .companionFailed,
                isPersistent: true,
                technicalDetail: "heartbeat_rejected_\(rejection.code)"
            )
            await failAndAbort(failure)
            throw failure
        }
        lastHeartbeatAt = await timing.now()
    }

    private func wakeIfDeepSleeping() async throws {
        guard handshake.displayState == .deepSleep,
              !deepSleepWakeAttempted else {
            return
        }

        // Mark the attempt before any write can begin. Once command alignment
        // is uncertain, this session must never toggle the display a second
        // time while trying to recover the acknowledgement.
        deepSleepWakeAttempted = true
        let powerKey = try TabletInputKey(validating: "POWER")
        do {
            try await transact(
                .event(.key(action: .click, key: powerKey)),
                allowStarting: true,
                cancellationBehavior: .abortProcess
            )
        } catch let rejection as TabletInputCommandRejection {
            let failure = RMM1InputFailure(
                .companionFailed,
                isPersistent: true,
                technicalDetail: "startup_wake_rejected_\(rejection.code)"
            )
            await failAndAbort(failure)
            throw failure
        }
    }

    private func sendActivity(allowStarting: Bool) async throws {
        let activityKey = try TabletInputKey(validating: "F12")
        do {
            try await transact(
                .event(.key(action: .click, key: activityKey)),
                allowStarting: allowStarting,
                cancellationBehavior: allowStarting
                    ? .abortProcess
                    : .preserveForGracefulClose
            )
        } catch let rejection as TabletInputCommandRejection {
            let failure = RMM1InputFailure(
                .companionFailed,
                isPersistent: true,
                technicalDetail: allowStarting
                    ? "startup_activity_rejected_\(rejection.code)"
                    : "activity_rejected_\(rejection.code)"
            )
            await failAndAbort(failure)
            throw failure
        }
        markActivity(at: await timing.now())
    }

    private var activityInterval: Duration {
        routeKind == .wifi
            ? Self.wifiActivityInterval
            : Self.usbActivityInterval
    }

    private func markActivity(at instant: Duration) {
        lastActivityAt = instant
        lastHeartbeatAt = instant
    }

    private func transact(
        _ payload: Payload,
        allowStarting: Bool,
        cancellationBehavior: RMM1InputReadCancellationBehavior
    ) async throws {
        let token = try await acquireTransaction(allowStarting: allowStarting)
        var writeMayHaveStarted = false
        defer { releaseTransaction(token) }

        do {
            try Task.checkCancellation()
            let id = try commandIDs.next()
            let line: Data
            switch payload {
            case let .event(event):
                line = try TabletInputWireCodec.encode(event: event, id: id)
            case .ping:
                line = try TabletInputWireCodec.encodePing(id: id)
            }

            // A canceled or failed async write can be partial. Mark ownership
            // conservative before crossing that suspension point.
            writeMayHaveStarted = true
            try await process.write(line)
            let responseLine = try await lineReader.nextLine(
                from: process,
                deadline: nil,
                timing: timing,
                cancellationBehavior: cancellationBehavior
            )
            switch try TabletInputWireCodec.parseResponse(
                responseLine,
                expectedID: id
            ) {
            case .acknowledged:
                return
            case let .rejected(rejection):
                throw rejection
            }
        } catch let rejection as TabletInputCommandRejection {
            // An aligned rejection consumed its response and does not poison
            // the ordered stream.
            throw rejection
        } catch is CancellationError {
            if writeMayHaveStarted,
               !(cancellationBehavior == .preserveForGracefulClose && state == .closing) {
                await failAndAbort(
                    RMM1InputFailure(.connectionClosed, isPersistent: false)
                )
            }
            throw CancellationError()
        } catch {
            if writeMayHaveStarted {
                let failure = Self.activeCommandFailure(from: error)
                await failAndAbort(failure)
                throw failure
            }
            throw error
        }
    }

    private func acquireTransaction(allowStarting: Bool) async throws -> UUID {
        try Task.checkCancellation()
        try requireUsableState(allowStarting: allowStarting)

        if activeTransaction == nil {
            let token = UUID()
            activeTransaction = token
            return token
        }
        guard transactionWaiters.count < Self.maximumQueuedCommands else {
            throw RMM1InputFailure(.queueFull, isPersistent: false)
        }

        let waiterID = UUID()
        let token: UUID = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<UUID, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                transactionWaiters.append(
                    TransactionWaiter(id: waiterID, continuation: continuation)
                )
            }
        }, onCancel: {
            Task { await self.cancelQueuedTransaction(waiterID) }
        })

        if Task.isCancelled {
            if activeTransaction == token {
                releaseTransaction(token)
            }
            throw CancellationError()
        }
        try requireUsableState(allowStarting: allowStarting)
        return token
    }

    private func cancelQueuedTransaction(_ waiterID: UUID) {
        guard let index = transactionWaiters.firstIndex(where: { $0.id == waiterID }) else {
            return
        }
        let waiter = transactionWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func cancelStopWaiter(_ waiterID: UUID) {
        guard let index = stopWaiters.firstIndex(where: { $0.id == waiterID }) else {
            return
        }
        let waiter = stopWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func signalStopped() {
        let waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(returning: terminalFailure)
        }
    }

    private func releaseTransaction(_ token: UUID) {
        guard activeTransaction == token else { return }
        activeTransaction = nil

        guard state == .running else {
            failQueuedTransactions(
                with: terminalFailure ?? RMM1InputFailure(
                    .connectionClosed,
                    isPersistent: false
                )
            )
            return
        }
        guard !transactionWaiters.isEmpty else { return }
        let waiter = transactionWaiters.removeFirst()
        let nextToken = UUID()
        activeTransaction = nextToken
        waiter.continuation.resume(returning: nextToken)
    }

    private func requireUsableState(allowStarting: Bool) throws {
        guard state == .running || (allowStarting && state == .starting) else {
            throw terminalFailure ?? RMM1InputFailure(
                .connectionClosed,
                isPersistent: false
            )
        }
    }

    private func failQueuedTransactions(with failure: RMM1InputFailure) {
        let waiters = transactionWaiters
        transactionWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(throwing: failure)
        }
    }

    private func failAndAbort(_ failure: RMM1InputFailure) async {
        guard state != .closed else { return }
        if terminalFailure == nil {
            terminalFailure = failure
        }
        state = .failed
        restorationIsUncertain = true
        heartbeatTask?.cancel()
        heartbeatTask = nil
        failQueuedTransactions(with: failure)
        signalStopped()

        let process = self.process
        let abortTask = Task<ProcessExecutionResult, any Error> {
            try await process.abort(
                confirmationTimeout: Self.forcedShutdownTimeout
            )
        }
        if let result = try? await abortTask.value,
           let classified = Self.failure(from: result),
           classified.kind == .physicalRestoreFailed {
            terminalFailure = classified
        }
    }

    private func performClose() async -> RMM1InputStopResult {
        let drainDeadline = await timing.now() + Self.commandDrainTimeout
        while activeTransaction != nil {
            let now = await timing.now()
            guard now < drainDeadline else { break }
            let remaining = drainDeadline - now
            do {
                try await timing.sleep(min(remaining, .milliseconds(50)))
            } catch {
                break
            }
        }

        await process.finishWriting()
        await process.beginDiscardingOutput()

        var stopFailure = terminalFailure
        do {
            switch try await process.waitForExit(
                timeout: Self.gracefulShutdownTimeout
            ) {
            case let .exited(result):
                if let classified = Self.failure(from: result) {
                    stopFailure = classified
                    if classified.kind == .physicalRestoreFailed {
                        restorationIsUncertain = true
                    }
                }
                if case .timedOut = result.outcome {
                    restorationIsUncertain = true
                }
            case .deadlineExceeded:
                restorationIsUncertain = true
                let result = try await process.abort(
                    confirmationTimeout: Self.forcedShutdownTimeout
                )
                if let classified = Self.failure(from: result),
                   classified.kind == .physicalRestoreFailed {
                    stopFailure = classified
                }
            }
        } catch {
            restorationIsUncertain = true
        }

        if restorationIsUncertain, stopFailure == nil {
            stopFailure = RMM1InputFailure(
                .restorationUncertain,
                isPersistent: true
            )
        }
        let result = RMM1InputStopResult(
            restoration: restorationIsUncertain ? .uncertain : .confirmed,
            failure: stopFailure
        )
        completedStop = result
        state = .closed
        signalStopped()
        closeTask = nil
        return result
    }

    private static func stopProcessGracefully(
        _ process: any RMM1InputStreamingProcess
    ) async -> RMM1InputStopResult {
        await process.finishWriting()
        await process.beginDiscardingOutput()
        do {
            switch try await process.waitForExit(timeout: gracefulShutdownTimeout) {
            case let .exited(result):
                let processFailure = failure(from: result)
                let uncertain = processFailure?.kind == .physicalRestoreFailed || {
                    if case .timedOut = result.outcome { return true }
                    return false
                }()
                return RMM1InputStopResult(
                    restoration: uncertain ? .uncertain : .confirmed,
                    failure: processFailure
                )
            case .deadlineExceeded:
                let result = try await process.abort(
                    confirmationTimeout: forcedShutdownTimeout
                )
                return RMM1InputStopResult(
                    restoration: .uncertain,
                    failure: failure(from: result) ?? RMM1InputFailure(
                        .restorationUncertain,
                        isPersistent: true
                    )
                )
            }
        } catch {
            _ = try? await process.abort(
                confirmationTimeout: forcedShutdownTimeout
            )
            return RMM1InputStopResult(
                restoration: .uncertain,
                failure: RMM1InputFailure(
                    .restorationUncertain,
                    isPersistent: true
                )
            )
        }
    }

    private static func startupFailure(from error: any Error) -> any Error {
        if error is CancellationError {
            return CancellationError()
        }
        if let failure = error as? RMM1InputFailure {
            return failure
        }
        if let lineError = error as? RMM1InputLineError {
            switch lineError {
            case .deadlineExceeded:
                return RMM1InputFailure(.startupTimedOut, isPersistent: false)
            case .endOfFile:
                return RMM1InputFailure(.connectionClosed, isPersistent: false)
            case .lineTooLong, .unterminatedLine:
                return RMM1InputFailure(.protocolMismatch, isPersistent: true)
            }
        }
        if error as? RMM1InputProcessError == .readTimedOut {
            return RMM1InputFailure(.startupTimedOut, isPersistent: false)
        }
        if error is TabletInputProtocolError {
            return RMM1InputFailure(.protocolMismatch, isPersistent: true)
        }
        return RMM1InputFailure(.processUnavailable, isPersistent: true)
    }

    private static func activeCommandFailure(
        from error: any Error
    ) -> RMM1InputFailure {
        if let failure = error as? RMM1InputFailure {
            return failure
        }
        if error is TabletInputProtocolError || error is RMM1InputLineError {
            return RMM1InputFailure(.protocolMismatch, isPersistent: true)
        }
        return RMM1InputFailure(.connectionClosed, isPersistent: false)
    }

    static func failure(from result: ProcessExecutionResult) -> RMM1InputFailure? {
        let stderr = String(decoding: result.standardError.data, as: UTF8.self)

        if stderr.contains("input_physical_restore_failed") {
            return RMM1InputFailure(.physicalRestoreFailed, isPersistent: true)
        }
        if stderr.contains("input_input_session_busy") {
            return RMM1InputFailure(.sessionBusy, isPersistent: false)
        }
        if stderr.contains("input_xochitl_not_running") {
            return RMM1InputFailure(.displayServiceNotReady, isPersistent: false)
        }
        if stderr.contains("input_heartbeat_timeout") {
            return RMM1InputFailure(.heartbeatTimedOut, isPersistent: false)
        }
        if stderr.localizedCaseInsensitiveContains("Timeout, server"),
           stderr.localizedCaseInsensitiveContains("not responding") {
            return RMM1InputFailure(
                .secureConnectionUnavailable,
                isPersistent: false,
                technicalDetail: "network_keepalive_timeout"
            )
        }
        if stderr.localizedCaseInsensitiveContains(
            "REMOTE HOST IDENTIFICATION HAS CHANGED"
        ) || stderr.localizedCaseInsensitiveContains("Host key verification failed") {
            return RMM1InputFailure(.hostIdentityChanged, isPersistent: true)
        }
        if stderr.localizedCaseInsensitiveContains("Permission denied") {
            return RMM1InputFailure(.authenticationRejected, isPersistent: true)
        }

        let status: Int32?
        switch result.outcome {
        case let .exited(exitStatus):
            status = exitStatus
        case .timedOut:
            return RMM1InputFailure(.restorationUncertain, isPersistent: true)
        }
        if status == 126 || status == 127 {
            return RMM1InputFailure(.companionMissing, isPersistent: true)
        }
        if stderr.localizedCaseInsensitiveContains("rmmirror-probe:") {
            return RMM1InputFailure(.companionFailed, isPersistent: true)
        }
        if status == 0 {
            return nil
        }
        if status != nil {
            return RMM1InputFailure(
                .connectionClosed,
                isPersistent: false,
                technicalDetail: "nonzero_exit"
            )
        }
        return RMM1InputFailure(.connectionClosed, isPersistent: false)
    }
}

private enum RMM1InputLineError: Error, Equatable, Sendable {
    case lineTooLong
    case unterminatedLine
    case endOfFile
    case deadlineExceeded
}

private actor RMM1InputLineReader {
    private static let chunkSize = 4_096
    private static let maximumLineBytes = 4_096

    private var buffer = Data()

    func nextLine(
        from process: any RMM1InputStreamingProcess,
        deadline: Duration?,
        timing: RMM1InputTiming,
        cancellationBehavior: RMM1InputReadCancellationBehavior
    ) async throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineLength = buffer.distance(
                    from: buffer.startIndex,
                    to: newline
                )
                guard lineLength <= Self.maximumLineBytes else {
                    throw RMM1InputLineError.lineTooLong
                }
                var line = Data(buffer[..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if line.last == UInt8(ascii: "\r") {
                    line.removeLast()
                }
                return line
            }
            guard buffer.count <= Self.maximumLineBytes else {
                throw RMM1InputLineError.lineTooLong
            }

            let timeout: Duration?
            if let deadline {
                let now = await timing.now()
                guard now < deadline else {
                    throw RMM1InputLineError.deadlineExceeded
                }
                timeout = deadline - now
            } else {
                timeout = nil
            }

            let chunk: Data
            do {
                chunk = try await process.read(
                    upToCount: Self.chunkSize,
                    timeout: timeout,
                    cancellationBehavior: cancellationBehavior
                )
            } catch RMM1InputProcessError.readTimedOut {
                throw RMM1InputLineError.deadlineExceeded
            }
            guard !chunk.isEmpty else {
                if buffer.isEmpty {
                    throw RMM1InputLineError.endOfFile
                }
                throw RMM1InputLineError.unterminatedLine
            }
            buffer.append(chunk)
        }
    }
}
