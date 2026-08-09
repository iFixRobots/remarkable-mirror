import Darwin
import Foundation

struct OwnedProcessID: Hashable, Sendable {
    let rawValue: UUID
}

struct BoundedProcessOutput: Equatable, Sendable {
    let data: Data
    let wasTruncated: Bool

    static let empty = BoundedProcessOutput(data: Data(), wasTruncated: false)
}

enum ProcessOutcome: Equatable, Sendable {
    case exited(status: Int32)
    case timedOut
}

struct ProcessExecutionResult: Equatable, Sendable {
    let outcome: ProcessOutcome
    let standardOutput: BoundedProcessOutput
    let standardError: BoundedProcessOutput
}

enum OwnedProcessError: Error, Equatable, Sendable {
    case invalidRequest
    case launchFailed
    case processNotOwned
    case notStreamingProcess
    case invalidReadSize
    case invalidWriteSize
    case streamWriteFailed
    case concurrentStreamRead
    case generationRetired
    case registryShutDown
    case retirementFailed
}

struct ProcessHeartbeat: Sendable {
    let pulse: Data
    let interval: Duration
    let sleep: @Sendable (Duration) async throws -> Void

    static let newlineEveryThreeSeconds = ProcessHeartbeat(
        pulse: Data("\n".utf8),
        interval: .seconds(3),
        sleep: { duration in try await Task.sleep(for: duration) }
    )
}

actor OwnedStreamingProcess {
    nonisolated let id: OwnedProcessID

    private let registry: OwnedProcessRegistry
    private var readInProgress = false

    fileprivate init(id: OwnedProcessID, registry: OwnedProcessRegistry) {
        self.id = id
        self.registry = registry
    }

    func read(upToCount count: Int) async throws -> Data {
        guard (1...65_536).contains(count) else {
            throw OwnedProcessError.invalidReadSize
        }
        guard !readInProgress else {
            throw OwnedProcessError.concurrentStreamRead
        }
        readInProgress = true
        defer { readInProgress = false }
        let registry = self.registry
        let id = self.id
        let cancellation = StreamingReadCancellation(registry: registry, id: id)
        return try await withTaskCancellationHandler {
            let data = try await registry.readStreamingOutput(id, upToCount: count)
            if Task.isCancelled {
                await cancellation.waitForCleanup()
            }
            try Task.checkCancellation()
            return data
        } onCancel: {
            Task { await cancellation.startCleanup() }
        }
    }

    /// Reads with a deadline while preserving the child when the deadline or
    /// caller cancellation wins. The underlying pipe read remains owned so a
    /// subsequent graceful close can drain it after sending EOF.
    func readPreservingProcess(
        upToCount count: Int,
        timeout: Duration?
    ) async throws -> Data? {
        guard (1...65_536).contains(count) else {
            throw OwnedProcessError.invalidReadSize
        }
        guard !readInProgress else {
            throw OwnedProcessError.concurrentStreamRead
        }
        readInProgress = true
        defer { readInProgress = false }
        return try await registry.readStreamingOutput(
            id,
            upToCount: count,
            timeout: timeout
        )
    }

    func write(_ data: Data) async throws {
        guard (1...65_536).contains(data.count) else {
            throw OwnedProcessError.invalidWriteSize
        }
        try await registry.writeStreamingInput(id, data: data)
    }

    func finishWriting() async {
        await registry.finishStreamingInput(id)
    }

    func waitForExit() async throws -> ProcessExecutionResult {
        try await registry.waitForStreamingExit(id)
    }

    /// Waits without terminating the child. `nil` means the process remained
    /// alive through the deadline, allowing a session owner to decide whether
    /// a graceful remote cleanup should continue or the exact child must be
    /// discarded.
    func waitForExitBeforeDeadline(
        _ timeout: Duration
    ) async throws -> ProcessExecutionResult? {
        try await registry.waitForStreamingExit(id, timeout: timeout)
    }

    func beginDiscardingOutput() async {
        await registry.beginDiscardingStreamingOutput(id)
    }

    func abortAndConfirm(
        timeout: Duration
    ) async throws -> ProcessExecutionResult {
        try await registry.abortStreamingProcess(id, confirmationTimeout: timeout)
    }

    func isRunning() async -> Bool {
        await registry.isRunning(id)
    }

    func cancel() async throws -> ProcessExecutionResult {
        try await registry.cancelStreamingProcess(id)
    }
}

private actor StreamingReadCancellation {
    private let registry: OwnedProcessRegistry
    private let id: OwnedProcessID
    private var cleanupTask: Task<Void, Never>?
    private var cleanupTaskWaiters: [CheckedContinuation<Task<Void, Never>, Never>] = []

    init(registry: OwnedProcessRegistry, id: OwnedProcessID) {
        self.registry = registry
        self.id = id
    }

    func startCleanup() {
        guard cleanupTask == nil else { return }
        let task = Task {
            _ = try? await registry.cancelStreamingProcess(id)
        }
        cleanupTask = task
        let waiters = cleanupTaskWaiters
        cleanupTaskWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: task)
        }
    }

    func waitForCleanup() async {
        if let cleanupTask {
            await cleanupTask.value
            return
        }
        let task = await withCheckedContinuation { continuation in
            cleanupTaskWaiters.append(continuation)
        }
        await task.value
    }
}

actor OwnedProcessRegistry {
    private struct Child {
        let id: OwnedProcessID
        let request: ProcessRequest
        let process: Process
        let exitLatch: ProcessExitLatch
        let standardOutputTask: Task<BoundedProcessOutput, Never>?
        let standardErrorTask: Task<BoundedProcessOutput, Never>?
        let streamingInput: OwnedProcessInput?
        let streamingOutput: OwnedProcessOutput?
        var heartbeatTask: Task<Void, Never>?
    }

    private let terminationGrace: Duration
    private var children: [OwnedProcessID: Child] = [:]
    private var retirementTasks: [GenerationID: Task<Void, Error>] = [:]
    private var closedGenerations: Set<GenerationID> = []
    private var acceptsLaunches = true
    private var completedResults: [OwnedProcessID: ProcessExecutionResult] = [:]
    private var completedOrder: [OwnedProcessID] = []
    private var requestedTerminationOutcomes: [OwnedProcessID: ProcessOutcome] = [:]

    init(terminationGrace: Duration = .seconds(1)) {
        self.terminationGrace = terminationGrace
    }

    func launchPersistent(_ request: ProcessRequest) async throws -> OwnedProcessID {
        try Task.checkCancellation()
        guard request.ioMode == .collected else {
            throw OwnedProcessError.invalidRequest
        }
        let id = try launch(request)
        if Task.isCancelled {
            _ = try? await terminateAndCollect(id, outcome: .timedOut)
            throw CancellationError()
        }
        return id
    }

    func launchStreaming(
        _ request: ProcessRequest,
        heartbeat: ProcessHeartbeat = .newlineEveryThreeSeconds
    ) async throws -> OwnedStreamingProcess {
        try Task.checkCancellation()
        guard request.ioMode == .streaming,
              !heartbeat.pulse.isEmpty,
              heartbeat.pulse.count <= 4_096,
              heartbeat.interval > .zero else {
            throw OwnedProcessError.invalidRequest
        }

        let id = try launch(request)
        guard let input = children[id]?.streamingInput else {
            _ = try? await terminateAndCollect(id, outcome: .timedOut)
            throw OwnedProcessError.notStreamingProcess
        }

        do {
            try await input.write(heartbeat.pulse)
            try Task.checkCancellation()
        } catch is CancellationError {
            _ = try? await terminateAndCollect(id, outcome: .timedOut)
            throw CancellationError()
        } catch {
            _ = try? await terminateAndCollect(id, outcome: .timedOut)
            throw OwnedProcessError.launchFailed
        }

        guard acceptsLaunches else {
            _ = try? await terminateAndCollect(id, outcome: .timedOut)
            throw OwnedProcessError.registryShutDown
        }
        guard !closedGenerations.contains(request.generation),
              var child = children[id] else {
            _ = try? await terminateAndCollect(id, outcome: .timedOut)
            throw OwnedProcessError.generationRetired
        }

        child.heartbeatTask = Task {
            while !Task.isCancelled {
                do {
                    try await heartbeat.sleep(heartbeat.interval)
                    try Task.checkCancellation()
                    try await input.write(heartbeat.pulse)
                } catch {
                    return
                }
            }
        }
        children[id] = child
        return OwnedStreamingProcess(id: id, registry: self)
    }

    /// Opens an owned bidirectional stream without injecting bytes into its
    /// protocol. The session layered above this API owns all writes, including
    /// acknowledged heartbeats.
    func launchInteractive(
        _ request: ProcessRequest
    ) async throws -> OwnedStreamingProcess {
        try Task.checkCancellation()
        guard request.ioMode == .streaming else {
            throw OwnedProcessError.invalidRequest
        }

        let id = try launch(request)
        guard children[id]?.streamingInput != nil,
              children[id]?.streamingOutput != nil else {
            _ = try? await terminateAndCollect(id, outcome: .timedOut)
            throw OwnedProcessError.notStreamingProcess
        }

        if Task.isCancelled {
            _ = try? await terminateAndCollect(id, outcome: .timedOut)
            throw CancellationError()
        }
        guard acceptsLaunches else {
            _ = try? await terminateAndCollect(id, outcome: .timedOut)
            throw OwnedProcessError.registryShutDown
        }
        guard !closedGenerations.contains(request.generation),
              children[id] != nil else {
            _ = try? await terminateAndCollect(id, outcome: .timedOut)
            throw OwnedProcessError.generationRetired
        }

        return OwnedStreamingProcess(id: id, registry: self)
    }

    func run(
        _ request: ProcessRequest,
        timeout: Duration
    ) async throws -> ProcessExecutionResult {
        try Task.checkCancellation()
        guard request.ioMode == .collected else {
            throw OwnedProcessError.invalidRequest
        }
        let id = try launch(request)
        guard let child = children[id] else { throw OwnedProcessError.processNotOwned }

        do {
            let exit = try await child.exitLatch.wait(timeout: timeout)
            return try await collect(id, outcome: .exited(status: exit.status))
        } catch is ProcessWaitTimeout {
            return try await terminateAndCollect(id, outcome: .timedOut)
        } catch is CancellationError {
            _ = try? await terminateAndCollect(id, outcome: .timedOut)
            throw CancellationError()
        }
    }

    func retire(generation: GenerationID) async throws {
        closedGenerations.insert(generation)
        if let existing = retirementTasks[generation] {
            return try await existing.value
        }

        let task = Task { [self] in
            try await performRetirement(generation: generation)
        }
        retirementTasks[generation] = task
        do {
            try await task.value
            retirementTasks[generation] = nil
        } catch {
            retirementTasks[generation] = nil
            throw error
        }
    }

    func shutdown() async throws {
        acceptsLaunches = false
        let generations = Set(children.values.map(\.request.generation))
        for generation in generations {
            try await retire(generation: generation)
        }
    }

    func isRunning(_ id: OwnedProcessID) -> Bool {
        children[id]?.process.isRunning == true
    }

    func ownsLoopbackTCPListener(
        _ port: UInt16,
        process id: OwnedProcessID
    ) -> Bool {
        guard let child = children[id], child.process.isRunning else {
            return false
        }
        return DarwinFilesTCPListenerOwnershipVerifier.isOwned(
            processIdentifier: child.process.processIdentifier,
            port: port
        )
    }

    func terminatePersistent(_ id: OwnedProcessID) async throws {
        guard let child = children[id] else {
            if completedResults[id] != nil { return }
            throw OwnedProcessError.processNotOwned
        }
        guard child.request.ioMode == .collected else {
            throw OwnedProcessError.notStreamingProcess
        }
        _ = try await terminateAndCollect(id, outcome: .timedOut)
    }

    func activeProcessIDs() -> [OwnedProcessID] {
        children.keys.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
    }

    fileprivate func readStreamingOutput(
        _ id: OwnedProcessID,
        upToCount count: Int
    ) async throws -> Data {
        guard (1...65_536).contains(count) else {
            throw OwnedProcessError.invalidReadSize
        }
        guard let child = children[id] else {
            if completedResults[id] != nil { return Data() }
            throw OwnedProcessError.processNotOwned
        }
        guard let output = child.streamingOutput else {
            throw OwnedProcessError.notStreamingProcess
        }
        return await output.read(upToCount: count)
    }

    fileprivate func readStreamingOutput(
        _ id: OwnedProcessID,
        upToCount count: Int,
        timeout: Duration?
    ) async throws -> Data? {
        guard (1...65_536).contains(count) else {
            throw OwnedProcessError.invalidReadSize
        }
        if let timeout, timeout < .zero {
            throw OwnedProcessError.invalidRequest
        }
        guard let child = children[id] else {
            if completedResults[id] != nil { return Data() }
            throw OwnedProcessError.processNotOwned
        }
        guard let output = child.streamingOutput else {
            throw OwnedProcessError.notStreamingProcess
        }
        return try await output.read(upToCount: count, timeout: timeout)
    }

    fileprivate func writeStreamingInput(
        _ id: OwnedProcessID,
        data: Data
    ) async throws {
        guard (1...65_536).contains(data.count) else {
            throw OwnedProcessError.invalidWriteSize
        }
        guard let child = children[id] else {
            throw OwnedProcessError.processNotOwned
        }
        guard let input = child.streamingInput,
              child.streamingOutput != nil else {
            throw OwnedProcessError.notStreamingProcess
        }

        do {
            try await input.write(data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OwnedProcessError.streamWriteFailed
        }
    }

    fileprivate func finishStreamingInput(_ id: OwnedProcessID) async {
        await stopStreamingInput(id)
    }

    fileprivate func beginDiscardingStreamingOutput(_ id: OwnedProcessID) async {
        await children[id]?.streamingOutput?.beginDiscarding()
    }

    fileprivate func waitForStreamingExit(
        _ id: OwnedProcessID
    ) async throws -> ProcessExecutionResult {
        if let completed = completedResults[id] { return completed }
        guard let child = children[id] else {
            throw OwnedProcessError.processNotOwned
        }
        guard child.streamingOutput != nil else {
            throw OwnedProcessError.notStreamingProcess
        }
        let exit = try await child.exitLatch.wait()
        return try await collect(id, outcome: .exited(status: exit.status))
    }

    fileprivate func waitForStreamingExit(
        _ id: OwnedProcessID,
        timeout: Duration
    ) async throws -> ProcessExecutionResult? {
        guard timeout >= .zero else {
            throw OwnedProcessError.invalidRequest
        }
        if let completed = completedResults[id] { return completed }
        guard let child = children[id] else {
            throw OwnedProcessError.processNotOwned
        }
        guard child.streamingOutput != nil else {
            throw OwnedProcessError.notStreamingProcess
        }

        do {
            let exit = try await child.exitLatch.wait(timeout: timeout)
            return try await collect(id, outcome: .exited(status: exit.status))
        } catch is ProcessWaitTimeout {
            return nil
        }
    }

    fileprivate func cancelStreamingProcess(
        _ id: OwnedProcessID
    ) async throws -> ProcessExecutionResult {
        if let completed = completedResults[id] { return completed }
        guard children[id]?.streamingOutput != nil else {
            if children[id] == nil { throw OwnedProcessError.processNotOwned }
            throw OwnedProcessError.notStreamingProcess
        }
        return try await terminateAndCollect(id, outcome: .timedOut)
    }

    fileprivate func abortStreamingProcess(
        _ id: OwnedProcessID,
        confirmationTimeout: Duration
    ) async throws -> ProcessExecutionResult {
        guard confirmationTimeout > .zero else {
            throw OwnedProcessError.invalidRequest
        }
        if let completed = completedResults[id] { return completed }
        guard let child = children[id] else {
            throw OwnedProcessError.processNotOwned
        }
        guard child.streamingOutput != nil else {
            throw OwnedProcessError.notStreamingProcess
        }

        await stopStreamingInput(id)
        await child.streamingOutput?.beginDiscarding()
        requestedTerminationOutcomes[id] = .timedOut
        if child.process.isRunning {
            let status = kill(child.process.processIdentifier, SIGKILL)
            guard status == 0 || errno == ESRCH else {
                throw OwnedProcessError.retirementFailed
            }
        }

        do {
            _ = try await child.exitLatch.wait(timeout: confirmationTimeout)
        } catch {
            throw OwnedProcessError.retirementFailed
        }
        return try await collect(id, outcome: .timedOut)
    }

    private func launch(_ request: ProcessRequest) throws -> OwnedProcessID {
        guard acceptsLaunches else {
            throw OwnedProcessError.registryShutDown
        }
        guard !closedGenerations.contains(request.generation) else {
            throw OwnedProcessError.generationRetired
        }
        guard request.executableURL.isFileURL,
              request.executableURL.path.first == "/",
              request.outputLimit >= 0,
              request.outputLimit <= 65_536,
              request.arguments.allSatisfy({ !$0.contains("\0") }) else {
            throw OwnedProcessError.invalidRequest
        }

        let id = OwnedProcessID(rawValue: UUID())
        let process = Process()
        let exitLatch = ProcessExitLatch()
        let inputPipe = request.ioMode == .streaming ? Pipe() : nil
        let outputPipe = request.ioMode == .streaming || request.outputLimit > 0
            ? Pipe()
            : nil
        let errorPipe = request.outputLimit > 0 ? Pipe() : nil

        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        process.standardOutput = outputPipe ?? FileHandle.nullDevice
        process.standardError = errorPipe ?? FileHandle.nullDevice
        process.terminationHandler = { process in
            let status = process.terminationStatus
            Task { await exitLatch.finish(ProcessExit(status: status)) }
        }

        do {
            try process.run()
        } catch {
            try? inputPipe?.fileHandleForReading.close()
            try? inputPipe?.fileHandleForWriting.close()
            try? outputPipe?.fileHandleForReading.close()
            try? outputPipe?.fileHandleForWriting.close()
            try? errorPipe?.fileHandleForReading.close()
            try? errorPipe?.fileHandleForWriting.close()
            throw OwnedProcessError.launchFailed
        }

        try? inputPipe?.fileHandleForReading.close()
        try? outputPipe?.fileHandleForWriting.close()
        try? errorPipe?.fileHandleForWriting.close()

        let streamingInput = inputPipe.map {
            OwnedProcessInput(handle: $0.fileHandleForWriting)
        }
        let streamingOutput = request.ioMode == .streaming
            ? outputPipe.map { OwnedProcessOutput(handle: $0.fileHandleForReading) }
            : nil
        let standardOutputTask = request.ioMode == .collected
            ? outputPipe.map { pipe in
                Task { await Self.drain(pipe.fileHandleForReading, limit: request.outputLimit) }
            }
            : nil
        let standardErrorTask = errorPipe.map { pipe in
            Task { await Self.drain(pipe.fileHandleForReading, limit: request.outputLimit) }
        }
        children[id] = Child(
            id: id,
            request: request,
            process: process,
            exitLatch: exitLatch,
            standardOutputTask: standardOutputTask,
            standardErrorTask: standardErrorTask,
            streamingInput: streamingInput,
            streamingOutput: streamingOutput,
            heartbeatTask: nil
        )
        return id
    }

    private func performRetirement(generation: GenerationID) async throws {
        let ids = children.values
            .filter { $0.request.generation == generation }
            .map(\.id)
        for id in ids {
            _ = try await terminateAndCollect(id, outcome: .timedOut)
        }
    }

    private func terminateAndCollect(
        _ id: OwnedProcessID,
        outcome: ProcessOutcome
    ) async throws -> ProcessExecutionResult {
        guard let child = children[id] else {
            if let completed = completedResults[id] {
                return completed
            }
            return ProcessExecutionResult(
                outcome: outcome,
                standardOutput: .empty,
                standardError: .empty
            )
        }

        await stopStreamingInput(id)
        if let completed = completedResults[id] { return completed }

        let priorRequestedOutcome = requestedTerminationOutcomes[id]
        requestedTerminationOutcomes[id] = outcome
        if child.process.isRunning {
            let status = kill(child.process.processIdentifier, SIGTERM)
            guard status == 0 || errno == ESRCH else {
                if let priorRequestedOutcome {
                    requestedTerminationOutcomes[id] = priorRequestedOutcome
                } else {
                    requestedTerminationOutcomes[id] = nil
                }
                throw OwnedProcessError.retirementFailed
            }
        }

        do {
            _ = try await child.exitLatch.wait(timeout: terminationGrace)
        } catch is ProcessWaitTimeout {
            if child.process.isRunning {
                let status = kill(child.process.processIdentifier, SIGKILL)
                guard status == 0 || errno == ESRCH else {
                    throw OwnedProcessError.retirementFailed
                }
            }
            do {
                _ = try await child.exitLatch.wait(timeout: .seconds(1))
            } catch {
                throw OwnedProcessError.retirementFailed
            }
        }

        return try await collect(id, outcome: outcome)
    }

    private func collect(
        _ id: OwnedProcessID,
        outcome: ProcessOutcome
    ) async throws -> ProcessExecutionResult {
        if let completed = completedResults[id] { return completed }
        guard let child = children[id] else { throw OwnedProcessError.processNotOwned }
        await stopStreamingInput(id)
        await child.streamingOutput?.drainAndClose()
        let standardOutput = await child.standardOutputTask?.value ?? .empty
        let standardError = await child.standardErrorTask?.value ?? .empty
        if let completed = completedResults[id] { return completed }
        let result = ProcessExecutionResult(
            outcome: requestedTerminationOutcomes[id] ?? outcome,
            standardOutput: standardOutput,
            standardError: standardError
        )
        if children[id]?.process === child.process {
            children[id] = nil
            recordCompleted(result, for: id)
            requestedTerminationOutcomes[id] = nil
        }
        return completedResults[id] ?? result
    }

    private func stopStreamingInput(_ id: OwnedProcessID) async {
        guard var child = children[id] else { return }
        let heartbeatTask = child.heartbeatTask
        child.heartbeatTask = nil
        children[id] = child

        heartbeatTask?.cancel()
        await child.streamingInput?.close()
        if let heartbeatTask {
            await heartbeatTask.value
        }
    }

    private func recordCompleted(
        _ result: ProcessExecutionResult,
        for id: OwnedProcessID
    ) {
        guard completedResults[id] == nil else { return }
        completedResults[id] = result
        completedOrder.append(id)
        while completedOrder.count > 256 {
            let expired = completedOrder.removeFirst()
            completedResults[expired] = nil
        }
    }

    private static func drain(
        _ handle: FileHandle,
        limit: Int
    ) async -> BoundedProcessOutput {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var collected = Data()
                collected.reserveCapacity(limit)
                var wasTruncated = false

                while true {
                    let chunk = handle.readData(ofLength: 4_096)
                    if chunk.isEmpty { break }
                    let remaining = max(0, limit - collected.count)
                    if remaining > 0 {
                        collected.append(chunk.prefix(remaining))
                    }
                    if chunk.count > remaining {
                        wasTruncated = true
                    }
                }
                try? handle.close()
                continuation.resume(
                    returning: BoundedProcessOutput(
                        data: collected,
                        wasTruncated: wasTruncated
                    )
                )
            }
        }
    }
}

enum DarwinFilesTCPListenerOwnershipVerifier {
    static func isOwned(processIdentifier: pid_t, port: UInt16) -> Bool {
        guard processIdentifier > 0, port > 0 else { return false }

        let requiredBytes = proc_pidinfo(
            processIdentifier,
            PROC_PIDLISTFDS,
            0,
            nil,
            0
        )
        guard requiredBytes > 0 else { return false }

        let descriptorStride = MemoryLayout<proc_fdinfo>.stride
        let capacity = (Int(requiredBytes) / descriptorStride) + 16
        var descriptors = Array(
            repeating: proc_fdinfo(),
            count: capacity
        )
        let bytesWritten = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(
                processIdentifier,
                PROC_PIDLISTFDS,
                0,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard bytesWritten > 0 else { return false }

        let descriptorCount = min(
            descriptors.count,
            Int(bytesWritten) / descriptorStride
        )
        let expectedAddress = inet_addr("127.0.0.1")
        let expectedNetworkPort = port.bigEndian

        for descriptor in descriptors.prefix(descriptorCount)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var information = socket_fdinfo()
            let result = withUnsafeMutablePointer(to: &information) { pointer in
                proc_pidfdinfo(
                    processIdentifier,
                    descriptor.proc_fd,
                    PROC_PIDFDSOCKETINFO,
                    pointer,
                    Int32(MemoryLayout<socket_fdinfo>.size)
                )
            }
            guard result == MemoryLayout<socket_fdinfo>.size else { continue }

            let socket = information.psi
            let tcp = socket.soi_proto.pri_tcp
            guard socket.soi_family == AF_INET,
                  socket.soi_protocol == IPPROTO_TCP,
                  socket.soi_kind == SOCKINFO_TCP,
                  tcp.tcpsi_state == TSI_S_LISTEN,
                  UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport) == expectedNetworkPort,
                  tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr == expectedAddress else {
                continue
            }
            return true
        }
        return false
    }
}

extension OwnedStreamingProcess: RMM1InputStreamingProcess {
    func read(
        upToCount count: Int,
        timeout: Duration?,
        cancellationBehavior: RMM1InputReadCancellationBehavior
    ) async throws -> Data {
        switch cancellationBehavior {
        case .abortProcess:
            guard let timeout else {
                return try await read(upToCount: count)
            }
            do {
                guard let data = try await readPreservingProcess(
                    upToCount: count,
                    timeout: timeout
                ) else {
                    _ = try? await abortAndConfirm(timeout: .seconds(3))
                    throw RMM1InputProcessError.readTimedOut
                }
                return data
            } catch is CancellationError {
                _ = try? await abortAndConfirm(timeout: .seconds(3))
                throw CancellationError()
            }
        case .preserveForGracefulClose:
            guard let data = try await readPreservingProcess(
                upToCount: count,
                timeout: timeout
            ) else {
                throw RMM1InputProcessError.readTimedOut
            }
            return data
        }
    }

    func waitForExit(
        timeout: Duration
    ) async throws -> RMM1InputProcessWaitResult {
        guard let result = try await waitForExitBeforeDeadline(timeout) else {
            return .deadlineExceeded
        }
        return .exited(result)
    }

    func abort(
        confirmationTimeout: Duration
    ) async throws -> ProcessExecutionResult {
        try await abortAndConfirm(timeout: confirmationTimeout)
    }
}

extension OwnedProcessRegistry: RMM1InputProcessLaunching {
    func launchInput(
        route: SSHRoute,
        generation: GenerationID
    ) async throws -> any RMM1InputStreamingProcess {
        try await route.openInputStream(
            generation: generation,
            registry: self
        )
    }
}

private struct ProcessInputClosed: Error, Sendable { }

private actor OwnedProcessInput {
    private let handle: FileHandle
    private var isClosed = false

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) throws {
        try Task.checkCancellation()
        guard !isClosed else { throw ProcessInputClosed() }
        try handle.write(contentsOf: data)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        try? handle.close()
    }
}

private actor OwnedProcessOutput {
    private struct PendingRead {
        let token: UUID
        let task: Task<Data, Never>
    }

    private let handle: FileHandle
    private var pendingRead: PendingRead?
    private var isClosing = false
    private var drainTask: Task<Void, Never>?

    init(handle: FileHandle) {
        self.handle = handle
    }

    func read(upToCount count: Int) async -> Data {
        guard !isClosing, pendingRead == nil else { return Data() }
        let token = UUID()
        let handle = handle
        let task = Task {
            await Self.read(handle, upToCount: count)
        }
        pendingRead = PendingRead(token: token, task: task)
        let data = await task.value
        if pendingRead?.token == token {
            pendingRead = nil
        }
        return data
    }

    /// `nil` means the deadline elapsed. A timeout or caller cancellation does
    /// not close the pipe or terminate the process; the pending read is kept so
    /// `beginDiscarding()` can join it during graceful session cleanup.
    func read(
        upToCount count: Int,
        timeout: Duration?
    ) async throws -> Data? {
        guard !isClosing, pendingRead == nil else { return Data() }
        let token = UUID()
        let handle = handle
        let task = Task {
            await Self.read(handle, upToCount: count)
        }
        pendingRead = PendingRead(token: token, task: task)

        guard let timeout else {
            let data = await task.value
            if pendingRead?.token == token {
                pendingRead = nil
            }
            try Task.checkCancellation()
            return data
        }

        let race = StreamingReadRace()
        let completion = Task {
            let data = await task.value
            await race.resolve(.data(data))
        }
        let deadline = Task {
            do {
                try await Task.sleep(for: timeout)
                await race.resolve(.deadlineExceeded)
            } catch {
                // Data or caller cancellation won the race.
            }
        }
        let result = await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            Task { await race.resolve(.cancelled) }
        }
        deadline.cancel()

        switch result {
        case let .data(data):
            _ = await completion.value
            if pendingRead?.token == token {
                pendingRead = nil
            }
            return data
        case .deadlineExceeded:
            return nil
        case .cancelled:
            throw CancellationError()
        }
    }

    func beginDiscarding() {
        guard drainTask == nil else { return }
        isClosing = true
        let pendingTask = pendingRead?.task
        let handle = handle
        drainTask = Task {
            if let pendingTask {
                _ = await pendingTask.value
            }
            await Self.discardRemainingBytes(handle)
            try? handle.close()
        }
    }

    func drainAndClose() async {
        beginDiscarding()
        if let drainTask {
            await drainTask.value
        }
        pendingRead = nil
    }

    private static func read(
        _ handle: FileHandle,
        upToCount count: Int
    ) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = [UInt8](repeating: 0, count: count)
                let bytesRead = buffer.withUnsafeMutableBytes { storage in
                    var result: Int
                    repeat {
                        result = Darwin.read(
                            handle.fileDescriptor,
                            storage.baseAddress,
                            storage.count
                        )
                    } while result < 0 && errno == EINTR
                    return result
                }
                guard bytesRead > 0 else {
                    continuation.resume(returning: Data())
                    return
                }
                continuation.resume(
                    returning: Data(buffer.prefix(bytesRead))
                )
            }
        }
    }

    private static func discardRemainingBytes(_ handle: FileHandle) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                while !handle.readData(ofLength: 4_096).isEmpty { }
                continuation.resume()
            }
        }
    }
}

private enum StreamingReadRaceResult: Sendable {
    case data(Data)
    case deadlineExceeded
    case cancelled
}

private actor StreamingReadRace {
    private var result: StreamingReadRaceResult?
    private var waiters: [CheckedContinuation<StreamingReadRaceResult, Never>] = []

    func resolve(_ result: StreamingReadRaceResult) {
        guard self.result == nil else { return }
        self.result = result
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume(returning: result)
        }
    }

    func wait() async -> StreamingReadRaceResult {
        if let result { return result }
        return await withCheckedContinuation { continuation in
            if let result {
                continuation.resume(returning: result)
            } else {
                waiters.append(continuation)
            }
        }
    }
}

private struct ProcessExit: Sendable {
    let status: Int32
}

private struct ProcessWaitTimeout: Error, Sendable { }

private actor ProcessExitLatch {
    private var exit: ProcessExit?
    private var waiters: [UUID: CheckedContinuation<ProcessExit, Error>] = [:]

    func finish(_ exit: ProcessExit) {
        guard self.exit == nil else { return }
        self.exit = exit
        let continuations = waiters.values
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume(returning: exit)
        }
    }

    func wait(timeout: Duration) async throws -> ProcessExit {
        try await withThrowingTaskGroup(of: ProcessExit.self) { group in
            group.addTask { [self] in try await wait() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ProcessWaitTimeout()
            }
            guard let first = try await group.next() else {
                throw ProcessWaitTimeout()
            }
            group.cancelAll()
            return first
        }
    }

    func wait() async throws -> ProcessExit {
        if let exit { return exit }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let exit {
                    continuation.resume(returning: exit)
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
