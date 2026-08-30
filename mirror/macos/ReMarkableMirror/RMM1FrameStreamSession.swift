import Foundation

struct RMM1FrameDelivery: Equatable, Sendable {
    let generation: GenerationID
    let update: RMM1FrameUpdate
}

enum RMM1FrameStreamInterruption: Equatable, Sendable {
    case endOfFile
    case ownedProcess(OwnedProcessError)
    case transport
}

enum RMM1FrameStreamTermination: Equatable, Sendable {
    case cancelled
    case firstFrameTimedOut
    case sinkRejected
    case protocolMismatch(RMM1ProtocolError)
    case retryableInterruption(RMM1FrameStreamInterruption)
}

enum RMM1FrameStreamSessionError: Error, Equatable, Sendable {
    case alreadyStarted
}

protocol RMM1FrameStreamingProcess: Actor {
    nonisolated var id: OwnedProcessID { get }

    func read(upToCount count: Int) async throws -> Data
    func cancel() async throws -> ProcessExecutionResult
}

extension OwnedStreamingProcess: RMM1FrameStreamingProcess { }

struct RMM1FirstFrameWatchdog: Sendable {
    let wait: @Sendable () async -> Bool

    static let tenSeconds = RMM1FirstFrameWatchdog {
        do {
            try await Task.sleep(for: .seconds(10))
            return true
        } catch {
            return false
        }
    }
}

actor RMM1FrameStreamSession {
    typealias OpenStream = @Sendable (
        GenerationID
    ) async throws -> any RMM1FrameStreamingProcess
    typealias Sink = @Sendable (RMM1FrameDelivery) async -> Bool

    static let readByteCount = 65_536

    private enum Phase: Equatable {
        case idle
        case opening
        case streaming
        case finished
    }

    private enum StopReason: Equatable {
        case cancelled
        case firstFrameTimedOut
    }

    private let generation: GenerationID
    private let openStream: OpenStream
    private let firstFrameWatchdog: RMM1FirstFrameWatchdog
    private let sink: Sink

    private var parser = RMM1StreamParser()
    private var surface = RMM1FrameSurface()
    private var phase = Phase.idle
    private var stopReason: StopReason?
    private var hasAcceptedFirstFrame = false
    private var firstFrameSignpost: PerformanceSignposts.Interval?
    private var activeProcess: (any RMM1FrameStreamingProcess)?
    private var watchdogTask: Task<Void, Never>?

    init(
        route: SSHRoute,
        generation: GenerationID,
        registry: OwnedProcessRegistry,
        sink: @escaping Sink
    ) {
        self.generation = generation
        self.openStream = { generation in
            try await route.openFrameStream(
                generation: generation,
                registry: registry
            )
        }
        self.firstFrameWatchdog = .tenSeconds
        self.sink = sink
    }

    init(
        generation: GenerationID,
        openStream: @escaping OpenStream,
        firstFrameWatchdog: RMM1FirstFrameWatchdog,
        sink: @escaping Sink
    ) {
        self.generation = generation
        self.openStream = openStream
        self.firstFrameWatchdog = firstFrameWatchdog
        self.sink = sink
    }

    func run() async throws -> RMM1FrameStreamTermination {
        try await withTaskCancellationHandler {
            try await runOnce()
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    /// Cancels only the process opened by this session. It deliberately does
    /// not await `run()`, so a route-clear publisher can call this while the
    /// asynchronous frame sink is suspended without creating a join cycle.
    func cancel() async {
        await requestStop(.cancelled)
    }

    func canonicalSurface() -> RMM1FrameSurface {
        surface
    }

    private func runOnce() async throws -> RMM1FrameStreamTermination {
        guard phase == .idle else {
            throw RMM1FrameStreamSessionError.alreadyStarted
        }
        phase = .opening
        firstFrameSignpost = PerformanceSignposts.begin("RMM1 First Frame Delivery")

        if Task.isCancelled || stopReason == .cancelled {
            return finish(.cancelled)
        }

        let process: any RMM1FrameStreamingProcess
        do {
            process = try await openStream(generation)
        } catch {
            let termination = classifyOpenError(error)
            return finish(termination)
        }

        activeProcess = process
        if let stopped = stopTermination {
            _ = try? await process.cancel()
            return finish(stopped)
        }
        if Task.isCancelled {
            stopReason = .cancelled
            _ = try? await process.cancel()
            return finish(.cancelled)
        }

        phase = .streaming
        startFirstFrameWatchdog(for: process)
        let termination = await consume(process)
        return finish(termination)
    }

    private func consume(
        _ process: any RMM1FrameStreamingProcess
    ) async -> RMM1FrameStreamTermination {
        while true {
            if let stopped = stopTermination {
                return stopped
            }

            let data: Data
            do {
                data = try await process.read(upToCount: Self.readByteCount)
            } catch {
                if let stopped = stopTermination {
                    return stopped
                }
                if error is CancellationError || Task.isCancelled {
                    stopReason = .cancelled
                    _ = try? await process.cancel()
                    return .cancelled
                }
                _ = try? await process.cancel()
                if let processError = error as? OwnedProcessError {
                    return .retryableInterruption(.ownedProcess(processError))
                }
                return .retryableInterruption(.transport)
            }

            if let stopped = stopTermination {
                return stopped
            }

            if data.isEmpty {
                do {
                    try parser.finish()
                } catch let error as RMM1ProtocolError {
                    _ = try? await process.cancel()
                    return .protocolMismatch(error)
                } catch {
                    _ = try? await process.cancel()
                    return .retryableInterruption(.transport)
                }
                _ = try? await process.cancel()
                return .retryableInterruption(.endOfFile)
            }

            var updates: [RMM1FrameUpdate] = []
            var parserFailure: RMM1ProtocolError?
            do {
                try parser.consume(data) { update in
                    updates.append(update)
                }
            } catch let error as RMM1ProtocolError {
                parserFailure = error
            } catch {
                _ = try? await process.cancel()
                return .retryableInterruption(.transport)
            }

            // The parser can emit more than one tiny dirty rectangle from a
            // read. This array is still strictly bounded by readByteCount, and
            // every sink call is awaited before another update or read begins.
            for update in updates {
                if let stopped = stopTermination {
                    return stopped
                }

                let isFirstFrame = !surface.hasFrame
                do {
                    try surface.apply(update)
                } catch let error as RMM1ProtocolError {
                    _ = try? await process.cancel()
                    return .protocolMismatch(error)
                } catch {
                    _ = try? await process.cancel()
                    return .retryableInterruption(.transport)
                }

                let accepted = await sink(RMM1FrameDelivery(
                    generation: generation,
                    update: update
                ))
                if let stopped = stopTermination {
                    return stopped
                }
                guard accepted else {
                    _ = try? await process.cancel()
                    return .sinkRejected
                }
                if isFirstFrame {
                    hasAcceptedFirstFrame = true
                    endFirstFrameSignpost()
                    cancelFirstFrameWatchdog()
                }
            }

            if let stopped = stopTermination {
                return stopped
            }
            if let parserFailure {
                _ = try? await process.cancel()
                return .protocolMismatch(parserFailure)
            }
        }
    }

    private func startFirstFrameWatchdog(
        for process: any RMM1FrameStreamingProcess
    ) {
        let wait = firstFrameWatchdog.wait
        let processID = process.id
        watchdogTask = Task { [weak self] in
            guard await wait() else { return }
            await self?.firstFrameDeadlineReached(processID: processID)
        }
    }

    private func firstFrameDeadlineReached(processID: OwnedProcessID) async {
        guard phase == .streaming,
              activeProcess?.id == processID,
              !hasAcceptedFirstFrame,
              stopReason == nil else {
            return
        }
        await requestStop(.firstFrameTimedOut)
    }

    private func requestStop(_ requestedReason: StopReason) async {
        guard phase != .finished else { return }
        if stopReason == nil {
            stopReason = requestedReason
        }
        cancelFirstFrameWatchdog()
        if let activeProcess {
            _ = try? await activeProcess.cancel()
        }
    }

    private func cancelFirstFrameWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    private var stopTermination: RMM1FrameStreamTermination? {
        switch stopReason {
        case .cancelled:
            return .cancelled
        case .firstFrameTimedOut:
            return .firstFrameTimedOut
        case nil:
            return nil
        }
    }

    private func classifyOpenError(_ error: any Error) -> RMM1FrameStreamTermination {
        if stopReason == .cancelled || error is CancellationError || Task.isCancelled {
            stopReason = .cancelled
            return .cancelled
        }
        if let processError = error as? OwnedProcessError {
            return .retryableInterruption(.ownedProcess(processError))
        }
        return .retryableInterruption(.transport)
    }

    private func finish(
        _ termination: RMM1FrameStreamTermination
    ) -> RMM1FrameStreamTermination {
        endFirstFrameSignpost()
        cancelFirstFrameWatchdog()
        activeProcess = nil
        phase = .finished
        return termination
    }

    private func endFirstFrameSignpost() {
        guard let firstFrameSignpost else { return }
        PerformanceSignposts.end(firstFrameSignpost)
        self.firstFrameSignpost = nil
    }
}
