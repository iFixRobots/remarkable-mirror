import Darwin
import Foundation

struct FilesLoopbackEndpoint: Equatable, Sendable {
    let port: UInt16

    init(port: UInt16) {
        precondition(port > 0)
        self.port = port
    }

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)/")!
    }
}

enum FilesSSHTunnelError: Error, Equatable, Sendable {
    case portAllocationFailed
    case listenerUnavailable
    case ownedForwardExited
}

protocol FilesProcessRegistering: Actor {
    func launchPersistent(_ request: ProcessRequest) async throws -> OwnedProcessID
    func isRunning(_ id: OwnedProcessID) -> Bool
    func ownsLoopbackTCPListener(_ port: UInt16, process id: OwnedProcessID) -> Bool
    func terminatePersistent(_ id: OwnedProcessID) async throws
}

extension OwnedProcessRegistry: FilesProcessRegistering {}

struct FilesLoopbackPortAllocator: Sendable {
    let allocate: @Sendable () async throws -> UInt16

    init(_ allocate: @escaping @Sendable () async throws -> UInt16) {
        self.allocate = allocate
    }

    static let system = FilesLoopbackPortAllocator {
        try FilesLoopbackSocket.allocatePort()
    }
}

struct FilesLoopbackListenerProbe: Sendable {
    let waitUntilListening: @Sendable (UInt16, Duration) async throws -> Void

    init(
        _ waitUntilListening: @escaping @Sendable (UInt16, Duration) async throws -> Void
    ) {
        self.waitUntilListening = waitUntilListening
    }

    static let system = FilesLoopbackListenerProbe { port, timeout in
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            if FilesLoopbackSocket.canConnect(to: port) {
                return
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        throw FilesSSHTunnelError.listenerUnavailable
    }
}

actor FilesSSHTunnel {
    private enum ForwardFailureReason: Sendable {
        case cancelled
        case listenerUnavailable
        case ownedForwardExited
    }

    private struct ForwardFailure: Error, Sendable {
        let reason: ForwardFailureReason
        let processID: OwnedProcessID
    }

    private struct ActiveForward: Sendable {
        let processID: OwnedProcessID
        let endpoint: FilesLoopbackEndpoint
    }

    private struct StartedForward: Sendable {
        let processID: OwnedProcessID
        let endpoint: FilesLoopbackEndpoint
    }

    private struct Startup: Sendable {
        let id: UUID
        let task: Task<StartedForward, Error>
    }

    private let route: SSHRoute
    private let generation: GenerationID
    private let processRegistry: any FilesProcessRegistering
    private let portAllocator: FilesLoopbackPortAllocator
    private let listenerProbe: FilesLoopbackListenerProbe
    private let startupTimeout: Duration

    private var activeForward: ActiveForward?
    private var startup: Startup?
    private var startupFailed = false
    private var failedProcessID: OwnedProcessID?

    init(
        route: SSHRoute,
        generation: GenerationID,
        processRegistry: any FilesProcessRegistering,
        portAllocator: FilesLoopbackPortAllocator = .system,
        listenerProbe: FilesLoopbackListenerProbe = .system,
        startupTimeout: Duration = .seconds(5)
    ) {
        self.route = route
        self.generation = generation
        self.processRegistry = processRegistry
        self.portAllocator = portAllocator
        self.listenerProbe = listenerProbe
        self.startupTimeout = startupTimeout
    }

    func endpoint() async throws -> FilesLoopbackEndpoint {
        if let activeForward {
            guard await processRegistry.isRunning(activeForward.processID) else {
                throw FilesSSHTunnelError.ownedForwardExited
            }
            guard await processRegistry.ownsLoopbackTCPListener(
                activeForward.endpoint.port,
                process: activeForward.processID
            ) else {
                throw FilesSSHTunnelError.listenerUnavailable
            }
            return activeForward.endpoint
        }
        guard !startupFailed else {
            throw FilesSSHTunnelError.ownedForwardExited
        }
        if let startup {
            return try await finish(startup)
        }

        let route = self.route
        let generation = self.generation
        let registry = self.processRegistry
        let allocator = self.portAllocator
        let probe = self.listenerProbe
        let timeout = self.startupTimeout
        let startup = Startup(id: UUID(), task: Task {
            try await Self.startForward(
                route: route,
                generation: generation,
                processRegistry: registry,
                portAllocator: allocator,
                listenerProbe: probe,
                startupTimeout: timeout
            )
        })
        self.startup = startup
        return try await finish(startup)
    }

    func isActive() async -> Bool {
        guard let activeForward else { return false }
        guard await processRegistry.isRunning(activeForward.processID) else {
            return false
        }
        return await processRegistry.ownsLoopbackTCPListener(
            activeForward.endpoint.port,
            process: activeForward.processID
        )
    }

    /// Clears a failed forward only after its exact owned child is confirmed
    /// stopped. This allows Files to recover inside a still-live mirror route
    /// without ever creating a duplicate SSH forward.
    func resetAfterFailureForRetry() async throws {
        guard startup == nil else {
            throw FilesSSHTunnelError.listenerUnavailable
        }

        let processIDs = Set(
            [activeForward?.processID, failedProcessID].compactMap { $0 }
        )
        for processID in processIDs where await processRegistry.isRunning(processID) {
            try await processRegistry.terminatePersistent(processID)
        }
        for processID in processIDs where await processRegistry.isRunning(processID) {
            throw FilesSSHTunnelError.ownedForwardExited
        }

        activeForward = nil
        failedProcessID = nil
        startupFailed = false
    }

    private func finish(
        _ startup: Startup
    ) async throws -> FilesLoopbackEndpoint {
        do {
            let started = try await startup.task.value
            if self.startup?.id == startup.id {
                activeForward = ActiveForward(
                    processID: started.processID,
                    endpoint: started.endpoint
                )
                self.startup = nil
            }
            return started.endpoint
        } catch {
            if self.startup?.id == startup.id {
                self.startup = nil
                startupFailed = true
                failedProcessID = (error as? ForwardFailure)?.processID
            }
            if let failure = error as? ForwardFailure {
                switch failure.reason {
                case .cancelled:
                    throw CancellationError()
                case .listenerUnavailable:
                    throw FilesSSHTunnelError.listenerUnavailable
                case .ownedForwardExited:
                    throw FilesSSHTunnelError.ownedForwardExited
                }
            }
            throw error
        }
    }

    private static func startForward(
        route: SSHRoute,
        generation: GenerationID,
        processRegistry: any FilesProcessRegistering,
        portAllocator: FilesLoopbackPortAllocator,
        listenerProbe: FilesLoopbackListenerProbe,
        startupTimeout: Duration
    ) async throws -> StartedForward {
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let port = try await portAllocator.allocate()
            guard port > 0 else { throw FilesSSHTunnelError.portAllocationFailed }
            let request = try route.forwardRequest(
                generation: generation,
                role: .filesForward,
                localPort: port,
                targetHost: "127.0.0.1",
                targetPort: 80
            )
            let processID = try await processRegistry.launchPersistent(request)
            do {
                try await listenerProbe.waitUntilListening(port, startupTimeout)
                guard await processRegistry.isRunning(processID) else {
                    if attempt == 0 { continue }
                    throw ForwardFailure(
                        reason: .ownedForwardExited,
                        processID: processID
                    )
                }
                guard await processRegistry.ownsLoopbackTCPListener(
                    port,
                    process: processID
                ) else {
                    throw ForwardFailure(
                        reason: .listenerUnavailable,
                        processID: processID
                    )
                }
                guard await processRegistry.isRunning(processID),
                      await processRegistry.ownsLoopbackTCPListener(
                        port,
                        process: processID
                      ) else {
                    throw ForwardFailure(
                        reason: .ownedForwardExited,
                        processID: processID
                    )
                }
                return StartedForward(
                    processID: processID,
                    endpoint: FilesLoopbackEndpoint(port: port)
                )
            } catch is CancellationError {
                throw ForwardFailure(
                    reason: .cancelled,
                    processID: processID
                )
            } catch {
                let isRunning = await processRegistry.isRunning(processID)
                if attempt == 0, !isRunning {
                    continue
                }
                if isRunning {
                    throw ForwardFailure(
                        reason: .listenerUnavailable,
                        processID: processID
                    )
                }
                throw ForwardFailure(
                    reason: .ownedForwardExited,
                    processID: processID
                )
            }
        }
        throw FilesSSHTunnelError.ownedForwardExited
    }
}

private enum FilesLoopbackSocket {
    static func allocatePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw FilesSSHTunnelError.portAllocationFailed }
        defer { close(descriptor) }

        var address = loopbackAddress(port: 0)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0 else { throw FilesSSHTunnelError.portAllocationFailed }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(descriptor, socketAddress, &length)
            }
        }
        let port = UInt16(bigEndian: address.sin_port)
        guard nameResult == 0, port > 0 else {
            throw FilesSSHTunnelError.portAllocationFailed
        }
        return port
    }

    static func canConnect(to port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = loopbackAddress(port: port)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                ) == 0
            }
        }
    }

    private static func loopbackAddress(port: UInt16) -> sockaddr_in {
        sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: port.bigEndian,
            sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )
    }
}
