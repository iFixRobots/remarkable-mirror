import Darwin
import Foundation
import os

enum TabletWakeState: String, Equatable, Sendable {
    case unlockRequired = "unlock_required"
    case sleeping
    case ready
    case starting
}

struct TabletWakeResponse: Equatable, Sendable {
    let state: TabletWakeState
    let wakeSent: Bool
}

enum TabletWakeClientError: Error, Equatable, Sendable {
    case invalidToken
    case invalidConfiguration
    case authenticationFailed
}

enum TabletWakeOperation: Equatable, Sendable {
    case status
    case wake

    var method: String {
        switch self {
        case .status: "GET"
        case .wake: "POST"
        }
    }

    var path: String {
        switch self {
        case .status: "/v1/status"
        case .wake: "/v1/wake"
        }
    }
}

enum TabletWakeAuthorization: Equatable, Sendable {
    case bearer(Data)
    case directCableRecovery

    var isValid: Bool {
        switch self {
        case let .bearer(token):
            TabletWakeToken.isValid(token)
        case .directCableRecovery:
            true
        }
    }
}

/// The authorization mode is explicit through the transport boundary. A
/// missing bearer can never become an implicit tokenless request or retry.
struct TabletWakeTransportRequest: Sendable {
    let operation: TabletWakeOperation
    let directUSBContext: DirectUSBRouteContext
    let authorization: TabletWakeAuthorization
    let port: UInt16
    let connectTimeoutMilliseconds: Int32
    let requestTimeoutMilliseconds: Int32
}

struct TabletWakeTransportResponse: Equatable, Sendable {
    let statusCode: Int
    let body: Data
}

enum TabletWakeTransportError: Error, Equatable, Sendable {
    case invalidRequest
    case usbContextChanged
    case interfaceUnavailable
    case interfaceBindingFailed
    case endpointVerificationFailed
    case connection
    case timeout
    case responseTooLarge
    case invalidResponse
}

protocol TabletWakeTransporting: Sendable {
    func response(
        for request: TabletWakeTransportRequest,
        maximumBodyBytes: Int
    ) async throws -> TabletWakeTransportResponse
}

final class TabletWakeCancellationSignal: Sendable {
    private struct State {
        var isCancelled = false
        var sensitiveOperationCount = 0
        var cancellationWaiters: [DispatchSemaphore] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    let pollDescriptor: Int32
    private let signalDescriptor: Int32

    init() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        let pipeStatus = descriptors.withUnsafeMutableBufferPointer { buffer in
            Darwin.pipe(buffer.baseAddress!)
        }
        guard pipeStatus == 0 else {
            throw TabletWakeTransportError.connection
        }

        let readDescriptor = descriptors[0]
        let writeDescriptor = descriptors[1]
        guard Self.configureDescriptor(readDescriptor),
              Self.configureDescriptor(writeDescriptor) else {
            Darwin.close(readDescriptor)
            Darwin.close(writeDescriptor)
            throw TabletWakeTransportError.connection
        }
        pollDescriptor = readDescriptor
        signalDescriptor = writeDescriptor
    }

    deinit {
        Darwin.close(pollDescriptor)
        Darwin.close(signalDescriptor)
    }

    func cancel() {
        let action = state.withLock { state -> (Bool, DispatchSemaphore?) in
            let shouldSignal = !state.isCancelled
            state.isCancelled = true
            guard state.sensitiveOperationCount > 0 else {
                return (shouldSignal, nil)
            }
            let waiter = DispatchSemaphore(value: 0)
            state.cancellationWaiters.append(waiter)
            return (shouldSignal, waiter)
        }
        action.1?.wait()
        guard action.0 else { return }

        var byte: UInt8 = 1
        while true {
            let result = withUnsafePointer(to: &byte) { pointer in
                Darwin.write(signalDescriptor, pointer, 1)
            }
            if result == 1 || errno != EINTR { return }
        }
    }

    func throwIfCancelled() throws {
        if state.withLock({ $0.isCancelled }) {
            throw CancellationError()
        }
    }

    func performUnlessCancelled<Result>(
        _ operation: () throws -> Result
    ) throws -> Result {
        let admitted = state.withLock { state in
            guard !state.isCancelled else { return false }
            state.sensitiveOperationCount += 1
            return true
        }
        guard admitted else { throw CancellationError() }
        defer { finishSensitiveOperation() }
        return try operation()
    }

    private func finishSensitiveOperation() {
        let waiters = state.withLock { state -> [DispatchSemaphore] in
            precondition(state.sensitiveOperationCount > 0)
            state.sensitiveOperationCount -= 1
            guard state.sensitiveOperationCount == 0 else { return [] }
            let waiters = state.cancellationWaiters
            state.cancellationWaiters.removeAll(keepingCapacity: false)
            return waiters
        }
        waiters.forEach { $0.signal() }
    }

    private static func configureDescriptor(_ descriptor: Int32) -> Bool {
        let statusFlags = fcntl(descriptor, F_GETFL, 0)
        guard statusFlags >= 0,
              fcntl(descriptor, F_SETFL, statusFlags | O_NONBLOCK) == 0 else {
            return false
        }
        let descriptorFlags = fcntl(descriptor, F_GETFD, 0)
        return descriptorFlags >= 0 &&
            fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0
    }
}

private final class TabletWakeQueuedOperation: Sendable {
    typealias Continuation = CheckedContinuation<
        TabletWakeTransportResponse,
        any Error
    >

    private enum Phase {
        case awaitingContinuation
        case pending(Continuation)
        case running(Continuation)
        case completed
    }

    private struct State {
        var phase = Phase.awaitingContinuation
        var cancellationRequested = false
    }

    private let cancellation: TabletWakeCancellationSignal
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(cancellation: TabletWakeCancellationSignal) {
        self.cancellation = cancellation
    }

    func install(_ continuation: Continuation) -> Bool {
        let shouldEnqueue = state.withLock { state in
            guard case .awaitingContinuation = state.phase else {
                return false
            }
            guard !state.cancellationRequested else {
                state.phase = .completed
                return false
            }
            state.phase = .pending(continuation)
            return true
        }
        if !shouldEnqueue {
            continuation.resume(throwing: CancellationError())
        }
        return shouldEnqueue
    }

    func cancel() {
        cancellation.cancel()
        let continuation = state.withLock { state -> Continuation? in
            state.cancellationRequested = true
            guard case let .pending(continuation) = state.phase else {
                return nil
            }
            state.phase = .completed
            return continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    func execute(
        _ operation: @escaping @Sendable (
            TabletWakeCancellationSignal
        ) throws -> TabletWakeTransportResponse
    ) {
        let continuation = state.withLock { state -> Continuation? in
            guard case let .pending(continuation) = state.phase else {
                return nil
            }
            state.phase = .running(continuation)
            return continuation
        }
        guard let continuation else { return }

        let result = Result<TabletWakeTransportResponse, any Error> {
            try cancellation.throwIfCancelled()
            let response = try operation(cancellation)
            try cancellation.throwIfCancelled()
            return response
        }
        let shouldResume = state.withLock { state in
            guard case .running = state.phase else { return false }
            state.phase = .completed
            return true
        }
        if shouldResume {
            continuation.resume(with: result)
        }
    }
}

struct TabletWakeWorkerQueue: Sendable {
    private let queue: DispatchQueue
    private let didEnqueue: @Sendable () -> Void
    private let didCancel: @Sendable () -> Void

    init(
        queue: DispatchQueue,
        didEnqueue: @escaping @Sendable () -> Void = { },
        didCancel: @escaping @Sendable () -> Void = { }
    ) {
        self.queue = queue
        self.didEnqueue = didEnqueue
        self.didCancel = didCancel
    }

    func run(
        _ operation: @escaping @Sendable (
            TabletWakeCancellationSignal
        ) throws -> TabletWakeTransportResponse
    ) async throws -> TabletWakeTransportResponse {
        let cancellation = try TabletWakeCancellationSignal()
        let queuedOperation = TabletWakeQueuedOperation(
            cancellation: cancellation
        )
        return try await withTaskCancellationHandler {
            try cancellation.throwIfCancelled()
            let response: TabletWakeTransportResponse = try await withCheckedThrowingContinuation {
                continuation in
                guard queuedOperation.install(continuation) else { return }
                queue.async {
                    queuedOperation.execute(operation)
                }
                didEnqueue()
            }
            try cancellation.throwIfCancelled()
            return response
        } onCancel: {
            queuedOperation.cancel()
            didCancel()
        }
    }
}

struct TabletWakeIPv4InterfaceAddress: Equatable, Sendable {
    let interfaceName: String
    let address: String
    let netmask: String
    let isUp: Bool
    let isRunning: Bool
}

protocol TabletWakeIPv4InterfaceInspecting: Sendable {
    func addresses(
        interfaceName: String
    ) -> [TabletWakeIPv4InterfaceAddress]
}

struct DarwinTabletWakeIPv4InterfaceInspector: TabletWakeIPv4InterfaceInspecting {
    func addresses(
        interfaceName: String
    ) -> [TabletWakeIPv4InterfaceAddress] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }

        var result: [TabletWakeIPv4InterfaceAddress] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard String(cString: entry.pointee.ifa_name) == interfaceName,
                  let socketAddress = entry.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == sa_family_t(AF_INET),
                  let netmaskAddress = entry.pointee.ifa_netmask,
                  let address = Self.string(from: socketAddress),
                  let netmask = Self.string(from: netmaskAddress) else {
                continue
            }
            result.append(
                TabletWakeIPv4InterfaceAddress(
                    interfaceName: interfaceName,
                    address: address,
                    netmask: netmask,
                    isUp: entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                    isRunning: entry.pointee.ifa_flags & UInt32(IFF_RUNNING) != 0
                )
            )
        }
        return result
    }

    private static func string(
        from socketAddress: UnsafePointer<sockaddr>
    ) -> String? {
        var ipv4 = UnsafeRawPointer(socketAddress)
            .assumingMemoryBound(to: sockaddr_in.self)
            .pointee
            .sin_addr
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let converted = text.withUnsafeMutableBufferPointer { buffer in
            inet_ntop(
                AF_INET,
                &ipv4,
                buffer.baseAddress,
                socklen_t(buffer.count)
            )
        }
        guard converted != nil else { return nil }
        return String(
            decoding: text.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }
}

actor TabletWakeClient {
    static let expectedSchema = "rmmirror.wake/v1"
    static let maximumResponseBytes = 4_096
    static let defaultPort: UInt16 = 51_337

    private static let connectTimeoutMilliseconds: Int32 = 750
    private static let requestTimeoutMilliseconds: Int32 = 2_000

    private let directUSBContext: DirectUSBRouteContext
    private let authorization: TabletWakeAuthorization
    private let port: UInt16
    private let transport: any TabletWakeTransporting
    private var requestIsInFlight = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    static func makeDirectCableRecoveryUSB(
        directUSBContext: DirectUSBRouteContext,
        transport: any TabletWakeTransporting = DarwinBoundUSBWakeTransport(),
        port: UInt16 = defaultPort
    ) throws -> TabletWakeClient {
        try TabletWakeClient(
            authorization: .directCableRecovery,
            directUSBContext: directUSBContext,
            transport: transport,
            port: port
        )
    }

    init(
        authorization: TabletWakeAuthorization,
        directUSBContext: DirectUSBRouteContext,
        transport: any TabletWakeTransporting,
        port: UInt16 = defaultPort
    ) throws {
        guard authorization.isValid else {
            throw TabletWakeClientError.invalidToken
        }
        guard port > 0,
              directUSBContext.usbRegistryEntryID > 0,
              SafeConnectionValue.isHost(directUSBContext.interfaceName) else {
            throw TabletWakeClientError.invalidConfiguration
        }
        self.authorization = authorization
        self.directUSBContext = directUSBContext
        self.transport = transport
        self.port = port
    }

    func status() async throws -> TabletWakeResponse? {
        try await send(.status)
    }

    func wake() async throws -> TabletWakeResponse? {
        try await send(.wake)
    }

    private func send(
        _ operation: TabletWakeOperation
    ) async throws -> TabletWakeResponse? {
        await acquireRequestSlot()
        defer { releaseRequestSlot() }
        try Task.checkCancellation()

        let transportResponse: TabletWakeTransportResponse
        do {
            transportResponse = try await transport.response(
                for: TabletWakeTransportRequest(
                    operation: operation,
                    directUSBContext: directUSBContext,
                    authorization: authorization,
                    port: port,
                    connectTimeoutMilliseconds: Self.connectTimeoutMilliseconds,
                    requestTimeoutMilliseconds: Self.requestTimeoutMilliseconds
                ),
                maximumBodyBytes: Self.maximumResponseBytes
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }

        if transportResponse.statusCode == 401 || transportResponse.statusCode == 403 {
            throw TabletWakeClientError.authenticationFailed
        }
        guard transportResponse.statusCode == 200,
              transportResponse.body.count <= Self.maximumResponseBytes else {
            return nil
        }
        return TabletWakeWireParser.parse(transportResponse.body)
    }

    private func acquireRequestSlot() async {
        guard requestIsInFlight else {
            requestIsInFlight = true
            return
        }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    private func releaseRequestSlot() {
        guard !requestWaiters.isEmpty else {
            requestIsInFlight = false
            return
        }
        requestWaiters.removeFirst().resume()
    }
}

actor DarwinBoundUSBWakeTransport: TabletWakeTransporting {
    static let tabletAddress = "10.11.99.1"

    private static let maximumHeaderBytes = 4_096
    private static let defaultWorker = TabletWakeWorkerQueue(
        queue: DispatchQueue(
            label: "com.ifixrobots.ReMarkableMirror.wake-usb",
            qos: .userInitiated
        )
    )

    private let usbInterfaceInspector: any USBInterfaceInspecting
    private let ipv4InterfaceInspector: any TabletWakeIPv4InterfaceInspecting
    private let worker: TabletWakeWorkerQueue

    init(
        usbInterfaceInspector: any USBInterfaceInspecting = IOKitUSBInterfaceInspector(),
        ipv4InterfaceInspector: any TabletWakeIPv4InterfaceInspecting =
            DarwinTabletWakeIPv4InterfaceInspector(),
        worker: TabletWakeWorkerQueue? = nil
    ) {
        self.usbInterfaceInspector = usbInterfaceInspector
        self.ipv4InterfaceInspector = ipv4InterfaceInspector
        self.worker = worker ?? Self.defaultWorker
    }

    func response(
        for request: TabletWakeTransportRequest,
        maximumBodyBytes: Int
    ) async throws -> TabletWakeTransportResponse {
        try Task.checkCancellation()
        let inspector = usbInterfaceInspector
        let ipv4Inspector = ipv4InterfaceInspector
        let response = try await worker.run { cancellation in
            try Self.blockingResponse(
                for: request,
                maximumBodyBytes: maximumBodyBytes,
                usbInterfaceInspector: inspector,
                ipv4InterfaceInspector: ipv4Inspector,
                cancellation: cancellation
            )
        }
        try Task.checkCancellation()
        return response
    }

    static func makeHTTPRequest(
        for request: TabletWakeTransportRequest
    ) throws -> Data {
        guard request.authorization.isValid, request.port > 0 else {
            throw TabletWakeTransportError.invalidRequest
        }

        var payload = Data(
            "\(request.operation.method) \(request.operation.path) HTTP/1.1\r\n".utf8
        )
        payload.append(Data("Host: \(tabletAddress):\(request.port)\r\n".utf8))
        if case let .bearer(token) = request.authorization {
            payload.append(Data("Authorization: Bearer ".utf8))
            payload.append(token)
            payload.append(Data("\r\n".utf8))
        }
        payload.append(Data("Accept: application/json\r\n".utf8))
        payload.append(Data("Accept-Encoding: identity\r\n".utf8))
        if request.operation == .wake {
            payload.append(Data("Content-Length: 0\r\n".utf8))
        }
        payload.append(Data("Connection: close\r\n\r\n".utf8))
        return payload
    }

    static func makeHTTPRequestForSend(
        for request: TabletWakeTransportRequest,
        cancellation: TabletWakeCancellationSignal
    ) throws -> Data {
        try makeHTTPRequestForSend(
            for: request,
            cancellation: cancellation,
            materialize: makeHTTPRequest
        )
    }

    static func makeHTTPRequestForSend(
        for request: TabletWakeTransportRequest,
        cancellation: TabletWakeCancellationSignal,
        materialize: @Sendable (TabletWakeTransportRequest) throws -> Data
    ) throws -> Data {
        let wireRequest = try cancellation.performUnlessCancelled {
            try materialize(request)
        }
        try cancellation.throwIfCancelled()
        return wireRequest
    }

    static func selectSourceAddress(
        interfaceName: String,
        from candidates: [TabletWakeIPv4InterfaceAddress]
    ) throws -> TabletWakeIPv4InterfaceAddress {
        guard let tablet = parsedIPv4(tabletAddress) else {
            throw TabletWakeTransportError.invalidRequest
        }
        let eligible = candidates.filter { candidate in
            guard candidate.interfaceName == interfaceName,
                  candidate.isUp,
                  candidate.isRunning,
                  let source = parsedIPv4(candidate.address),
                  let netmask = parsedIPv4(candidate.netmask),
                  isContiguousNetmask(netmask),
                  isSafeUnicastSource(source, netmask: netmask),
                  (source & netmask) == (tablet & netmask),
                  source != tablet else {
                return false
            }
            return true
        }
        guard eligible.count == 1, let source = eligible.first else {
            throw TabletWakeTransportError.interfaceUnavailable
        }
        return source
    }

    static func usbContextIsCurrent(
        _ context: DirectUSBRouteContext,
        inspector: any USBInterfaceInspecting
    ) -> Bool {
        inspector.usbAncestorRegistryEntryID(
            interfaceName: context.interfaceName
        ) == context.usbRegistryEntryID
    }

    private static func blockingResponse(
        for request: TabletWakeTransportRequest,
        maximumBodyBytes: Int,
        usbInterfaceInspector: any USBInterfaceInspecting,
        ipv4InterfaceInspector: any TabletWakeIPv4InterfaceInspecting,
        cancellation: TabletWakeCancellationSignal
    ) throws -> TabletWakeTransportResponse {
        try cancellation.throwIfCancelled()
        guard maximumBodyBytes > 0,
              maximumBodyBytes <= TabletWakeClient.maximumResponseBytes,
              request.connectTimeoutMilliseconds > 0,
              request.requestTimeoutMilliseconds >= request.connectTimeoutMilliseconds,
              request.directUSBContext.usbRegistryEntryID > 0,
              SafeConnectionValue.isHost(request.directUSBContext.interfaceName),
              request.authorization.isValid else {
            throw TabletWakeTransportError.invalidRequest
        }

        let context = request.directUSBContext
        guard usbContextIsCurrent(
            context,
            inspector: usbInterfaceInspector
        ) else {
            throw TabletWakeTransportError.usbContextChanged
        }
        guard let interfaceIndex = interfaceIndex(named: context.interfaceName),
              let sourceAddress = try? selectSourceAddress(
                interfaceName: context.interfaceName,
                from: ipv4InterfaceInspector.addresses(
                    interfaceName: context.interfaceName
                )
              ) else {
            throw TabletWakeTransportError.interfaceUnavailable
        }
        try cancellation.throwIfCancelled()

        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TabletWakeTransportError.connection }
        defer { Darwin.close(descriptor) }

        try configure(
            descriptor,
            interfaceIndex: interfaceIndex,
            localAddress: sourceAddress.address
        )

        let startedAt = DispatchTime.now().uptimeNanoseconds
        let requestDeadline = deadline(
            afterMilliseconds: request.requestTimeoutMilliseconds,
            from: startedAt
        )
        let connectDeadline = min(
            requestDeadline,
            deadline(
                afterMilliseconds: request.connectTimeoutMilliseconds,
                from: startedAt
            )
        )
        try connect(
            descriptor,
            remoteAddress: tabletAddress,
            port: request.port,
            deadline: connectDeadline,
            cancellation: cancellation
        )

        let localEndpoint = endpoint(descriptor, operation: getsockname)
        let remoteEndpoint = endpoint(descriptor, operation: getpeername)
        let refreshedSourceAddress = try? selectSourceAddress(
            interfaceName: context.interfaceName,
            from: ipv4InterfaceInspector.addresses(
                interfaceName: context.interfaceName
            )
        )
        guard boundInterfaceIndex(descriptor) == interfaceIndex,
              localEndpoint?.address == sourceAddress.address,
              localEndpoint?.port != nil,
              remoteEndpoint == IPv4Endpoint(address: tabletAddress, port: request.port),
              Self.interfaceIndex(named: context.interfaceName) == interfaceIndex,
              refreshedSourceAddress == sourceAddress,
              usbContextIsCurrent(
                context,
                inspector: usbInterfaceInspector
              ) else {
            throw TabletWakeTransportError.endpointVerificationFailed
        }

        // Authorization bytes, when present, are not materialized until every
        // interface and endpoint check above has passed. IP_BOUND_IF remains
        // set for every write.
        let wireRequest = try makeHTTPRequestForSend(
            for: request,
            cancellation: cancellation
        )
        try writeAll(
            descriptor,
            data: wireRequest,
            deadline: requestDeadline,
            cancellation: cancellation
        )
        return try readResponse(
            descriptor,
            maximumBodyBytes: maximumBodyBytes,
            deadline: requestDeadline,
            cancellation: cancellation
        )
    }

    private static func configure(
        _ descriptor: Int32,
        interfaceIndex: Int32,
        localAddress: String
    ) throws {
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw TabletWakeTransportError.connection
        }

        var noSignal: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw TabletWakeTransportError.connection
        }

        var requiredInterface = interfaceIndex
        guard setsockopt(
            descriptor,
            IPPROTO_IP,
            IP_BOUND_IF,
            &requiredInterface,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0,
        boundInterfaceIndex(descriptor) == interfaceIndex else {
            throw TabletWakeTransportError.interfaceBindingFailed
        }

        var local = address(localAddress, port: 0)
        let result = withUnsafePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard result == 0 else {
            throw TabletWakeTransportError.interfaceBindingFailed
        }
    }

    private static func connect(
        _ descriptor: Int32,
        remoteAddress: String,
        port: UInt16,
        deadline: UInt64,
        cancellation: TabletWakeCancellationSignal
    ) throws {
        try cancellation.throwIfCancelled()
        var remote = address(remoteAddress, port: port)
        let result = withUnsafePointer(to: &remote) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        if result == 0 { return }
        guard errno == EINPROGRESS else {
            throw TabletWakeTransportError.connection
        }

        _ = try wait(
            descriptor,
            events: Int16(POLLOUT),
            deadline: deadline,
            cancellation: cancellation
        )
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(
            descriptor,
            SOL_SOCKET,
            SO_ERROR,
            &socketError,
            &length
        ) == 0,
        socketError == 0 else {
            throw TabletWakeTransportError.connection
        }
    }

    private static func writeAll(
        _ descriptor: Int32,
        data: Data,
        deadline: UInt64,
        cancellation: TabletWakeCancellationSignal
    ) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                throw TabletWakeTransportError.invalidRequest
            }
            var offset = 0
            while offset < bytes.count {
                _ = try wait(
                    descriptor,
                    events: Int16(POLLOUT),
                    deadline: deadline,
                    cancellation: cancellation
                )
                let written = try cancellation.performUnlessCancelled {
                    Darwin.send(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        bytes.count - offset,
                        0
                    )
                }
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                    continue
                }
                throw TabletWakeTransportError.connection
            }
        }
    }

    private static func readResponse(
        _ descriptor: Int32,
        maximumBodyBytes: Int,
        deadline: UInt64,
        cancellation: TabletWakeCancellationSignal
    ) throws -> TabletWakeTransportResponse {
        var decoder = TabletWakeHTTPResponseDecoder(
            maximumHeaderBytes: maximumHeaderBytes,
            maximumBodyBytes: maximumBodyBytes
        )
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            _ = try wait(
                descriptor,
                events: Int16(POLLIN),
                deadline: deadline,
                cancellation: cancellation
            )
            try cancellation.throwIfCancelled()
            let count = buffer.withUnsafeMutableBytes {
                Darwin.recv(descriptor, $0.baseAddress, $0.count, 0)
            }
            if count > 0 {
                if let response = try decoder.consume(Data(buffer.prefix(count))) {
                    return response
                }
                continue
            }
            if count == 0 {
                return try decoder.finish()
            }
            if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            }
            throw TabletWakeTransportError.connection
        }
    }

    private static func wait(
        _ descriptor: Int32,
        events: Int16,
        deadline: UInt64,
        cancellation: TabletWakeCancellationSignal
    ) throws -> Int16 {
        while true {
            try cancellation.throwIfCancelled()
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw TabletWakeTransportError.timeout }
            let remainingNanoseconds = deadline - now
            let roundedMilliseconds = (remainingNanoseconds + 999_999) / 1_000_000
            let timeout = Int32(min(roundedMilliseconds, UInt64(Int32.max)))
            var items = [
                pollfd(fd: descriptor, events: events, revents: 0),
                pollfd(
                    fd: cancellation.pollDescriptor,
                    events: Int16(POLLIN),
                    revents: 0
                ),
            ]
            let result = items.withUnsafeMutableBufferPointer { buffer in
                Darwin.poll(buffer.baseAddress, nfds_t(buffer.count), timeout)
            }
            if result > 0 {
                try cancellation.throwIfCancelled()
                if items[1].revents != 0 {
                    throw CancellationError()
                }
                if items[0].revents & Int16(POLLNVAL) != 0 {
                    throw TabletWakeTransportError.connection
                }
                return items[0].revents
            }
            if result == 0 { throw TabletWakeTransportError.timeout }
            if errno != EINTR { throw TabletWakeTransportError.connection }
        }
    }

    private static func boundInterfaceIndex(_ descriptor: Int32) -> Int32? {
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(
            descriptor,
            IPPROTO_IP,
            IP_BOUND_IF,
            &value,
            &length
        ) == 0,
        length == socklen_t(MemoryLayout<Int32>.size) else {
            return nil
        }
        return value
    }

    private static func interfaceIndex(named name: String) -> Int32? {
        let value = name.withCString { if_nametoindex($0) }
        guard value > 0, value <= UInt32(Int32.max) else { return nil }
        return Int32(value)
    }

    private struct IPv4Endpoint: Equatable {
        let address: String
        let port: UInt16?
    }

    private typealias SocketNameOperation = (
        Int32,
        UnsafeMutablePointer<sockaddr>?,
        UnsafeMutablePointer<socklen_t>?
    ) -> Int32

    private static func endpoint(
        _ descriptor: Int32,
        operation: SocketNameOperation
    ) -> IPv4Endpoint? {
        var value = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                operation(descriptor, $0, &length)
            }
        }
        guard result == 0,
              length == socklen_t(MemoryLayout<sockaddr_in>.size),
              value.sin_family == sa_family_t(AF_INET) else {
            return nil
        }

        var address = value.sin_addr
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let converted = text.withUnsafeMutableBufferPointer { buffer in
            inet_ntop(
                AF_INET,
                &address,
                buffer.baseAddress,
                socklen_t(buffer.count)
            )
        }
        guard converted != nil else {
            return nil
        }
        let port = UInt16(bigEndian: value.sin_port)
        return IPv4Endpoint(
            address: String(
                decoding: text.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
                as: UTF8.self
            ),
            port: port == 0 ? nil : port
        )
    }

    private static func address(_ value: String, port: UInt16) -> sockaddr_in {
        sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: port.bigEndian,
            sin_addr: in_addr(s_addr: inet_addr(value)),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )
    }

    private static func parsedIPv4(_ value: String) -> UInt32? {
        var address = in_addr()
        guard value.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else {
            return nil
        }
        return UInt32(bigEndian: address.s_addr)
    }

    private static func isContiguousNetmask(_ netmask: UInt32) -> Bool {
        guard netmask != 0 else { return false }
        let inverted = ~netmask
        return inverted & (inverted &+ 1) == 0
    }

    private static func isSafeUnicastSource(
        _ source: UInt32,
        netmask: UInt32
    ) -> Bool {
        let firstOctet = UInt8((source >> 24) & 0xFF)
        let secondOctet = UInt8((source >> 16) & 0xFF)
        let hostPart = source & ~netmask
        return source != 0 &&
            source != UInt32.max &&
            firstOctet != 0 &&
            firstOctet != 127 &&
            !(firstOctet == 169 && secondOctet == 254) &&
            !(224...239).contains(firstOctet) &&
            hostPart != 0 &&
            hostPart != ~netmask
    }

    private static func deadline(
        afterMilliseconds milliseconds: Int32,
        from start: UInt64
    ) -> UInt64 {
        start.addingReportingOverflow(UInt64(milliseconds) * 1_000_000).partialValue
    }
}

struct TabletWakeHTTPResponseDecoder {
    private struct Header {
        let statusCode: Int
        let contentLength: Int?
    }

    private static let terminator = Data("\r\n\r\n".utf8)

    private let maximumHeaderBytes: Int
    private let maximumBodyBytes: Int
    private var unparsedHeader = Data()
    private var header: Header?
    private var body = Data()
    private var completed = false

    init(maximumHeaderBytes: Int, maximumBodyBytes: Int) {
        precondition(maximumHeaderBytes > 0 && maximumBodyBytes > 0)
        self.maximumHeaderBytes = maximumHeaderBytes
        self.maximumBodyBytes = maximumBodyBytes
    }

    mutating func consume(
        _ chunk: Data
    ) throws -> TabletWakeTransportResponse? {
        guard !completed else { throw TabletWakeTransportError.invalidResponse }
        guard !chunk.isEmpty else { return nil }

        if header == nil {
            unparsedHeader.append(chunk)
            if let terminatorRange = unparsedHeader.range(of: Self.terminator) {
                let headerBytes = Data(unparsedHeader[..<terminatorRange.lowerBound])
                guard headerBytes.count <= maximumHeaderBytes else {
                    throw TabletWakeTransportError.responseTooLarge
                }
                let parsedHeader = try Self.parseHeader(headerBytes)
                header = parsedHeader
                if parsedHeader.statusCode != 200 {
                    completed = true
                    unparsedHeader.removeAll(keepingCapacity: false)
                    return TabletWakeTransportResponse(
                        statusCode: parsedHeader.statusCode,
                        body: Data()
                    )
                }
                if let contentLength = parsedHeader.contentLength,
                   contentLength > maximumBodyBytes {
                    throw TabletWakeTransportError.responseTooLarge
                }
                let bodyPrefix = Data(unparsedHeader[terminatorRange.upperBound...])
                unparsedHeader.removeAll(keepingCapacity: false)
                return try appendBody(bodyPrefix)
            }
            if unparsedHeader.count > maximumHeaderBytes + Self.terminator.count - 1 {
                throw TabletWakeTransportError.responseTooLarge
            }
            return nil
        }
        return try appendBody(chunk)
    }

    mutating func finish() throws -> TabletWakeTransportResponse {
        guard !completed, let header else {
            throw TabletWakeTransportError.invalidResponse
        }
        if let contentLength = header.contentLength,
           body.count != contentLength {
            throw TabletWakeTransportError.invalidResponse
        }
        completed = true
        return TabletWakeTransportResponse(
            statusCode: header.statusCode,
            body: body
        )
    }

    private mutating func appendBody(
        _ bytes: Data
    ) throws -> TabletWakeTransportResponse? {
        guard let header else { throw TabletWakeTransportError.invalidResponse }
        guard body.count <= maximumBodyBytes,
              bytes.count <= maximumBodyBytes - body.count else {
            throw TabletWakeTransportError.responseTooLarge
        }
        body.append(bytes)

        guard let contentLength = header.contentLength else { return nil }
        guard body.count <= contentLength else {
            throw TabletWakeTransportError.invalidResponse
        }
        guard body.count == contentLength else { return nil }
        completed = true
        return TabletWakeTransportResponse(
            statusCode: header.statusCode,
            body: body
        )
    }

    private static func parseHeader(_ data: Data) throws -> Header {
        guard let text = String(data: data, encoding: .utf8) else {
            throw TabletWakeTransportError.invalidResponse
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw TabletWakeTransportError.invalidResponse
        }
        let statusFields = statusLine.split(
            separator: " ",
            maxSplits: 2,
            omittingEmptySubsequences: true
        )
        guard statusFields.count >= 2,
              statusFields[0] == "HTTP/1.1" || statusFields[0] == "HTTP/1.0",
              let statusCode = Int(statusFields[1]),
              (100...599).contains(statusCode) else {
            throw TabletWakeTransportError.invalidResponse
        }

        var contentLength: Int?
        var sawTransferEncoding = false
        for line in lines.dropFirst() {
            guard !line.isEmpty,
                  !line.first!.isWhitespace,
                  let colon = line.firstIndex(of: ":") else {
                throw TabletWakeTransportError.invalidResponse
            }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw TabletWakeTransportError.invalidResponse }

            switch name {
            case "content-length":
                guard contentLength == nil,
                      !value.isEmpty,
                      value.utf8.allSatisfy({ (48...57).contains($0) }),
                      let parsed = Int(value) else {
                    throw TabletWakeTransportError.invalidResponse
                }
                contentLength = parsed
            case "transfer-encoding":
                sawTransferEncoding = true
            case "content-encoding":
                guard value.caseInsensitiveCompare("identity") == .orderedSame else {
                    throw TabletWakeTransportError.invalidResponse
                }
            default:
                break
            }
        }
        guard !sawTransferEncoding else {
            throw TabletWakeTransportError.invalidResponse
        }
        return Header(statusCode: statusCode, contentLength: contentLength)
    }
}

private enum TabletWakeToken {
    static func isValid(_ data: Data) -> Bool {
        data.count == 64 && data.allSatisfy { byte in
            (48...57).contains(byte) ||
                (65...70).contains(byte) ||
                (97...102).contains(byte)
        }
    }
}

private enum TabletWakeWireParser {
    static func parse(_ data: Data) -> TabletWakeResponse? {
        guard !data.isEmpty,
              data.count <= TabletWakeClient.maximumResponseBytes else {
            return nil
        }
        do {
            var parser = JSONParser(data)
            return try parser.parseResponse()
        } catch {
            return nil
        }
    }

    private struct JSONParser {
        private enum ParseError: Error {
            case invalid
        }

        private let bytes: [UInt8]
        private var index = 0

        init(_ data: Data) {
            bytes = Array(data)
        }

        mutating func parseResponse() throws -> TabletWakeResponse {
            skipWhitespace()
            try consume(123)

            var schema: String?
            var state: String?
            var wakeSent = false
            var keys = Set<String>()

            skipWhitespace()
            guard peek() != 125 else { throw ParseError.invalid }
            while true {
                skipWhitespace()
                let key = try parseString()
                guard keys.insert(key).inserted else { throw ParseError.invalid }
                skipWhitespace()
                try consume(58)
                skipWhitespace()

                switch key {
                case "schema":
                    schema = try parseString()
                case "state":
                    state = try parseString()
                case "wake_sent":
                    wakeSent = try parseBoolean()
                default:
                    throw ParseError.invalid
                }

                skipWhitespace()
                if peek() == 44 {
                    index += 1
                    continue
                }
                try consume(125)
                break
            }

            skipWhitespace()
            guard index == bytes.count,
                  schema == TabletWakeClient.expectedSchema,
                  let state,
                  let parsedState = TabletWakeState(rawValue: state) else {
                throw ParseError.invalid
            }
            return TabletWakeResponse(state: parsedState, wakeSent: wakeSent)
        }

        private mutating func parseString() throws -> String {
            guard peek() == 34 else { throw ParseError.invalid }
            let start = index
            index += 1
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                if byte < 0x20 { throw ParseError.invalid }
                index += 1
                if escaped {
                    escaped = false
                } else if byte == 92 {
                    escaped = true
                } else if byte == 34 {
                    let literal = Data(bytes[start..<index])
                    guard let value = try? JSONDecoder().decode(String.self, from: literal) else {
                        throw ParseError.invalid
                    }
                    return value
                }
            }
            throw ParseError.invalid
        }

        private mutating func parseBoolean() throws -> Bool {
            if matches("true") {
                index += 4
                return true
            }
            if matches("false") {
                index += 5
                return false
            }
            throw ParseError.invalid
        }

        private func matches(_ value: String) -> Bool {
            let expected = Array(value.utf8)
            guard index + expected.count <= bytes.count else { return false }
            return bytes[index..<(index + expected.count)].elementsEqual(expected)
        }

        private mutating func consume(_ expected: UInt8) throws {
            guard peek() == expected else { throw ParseError.invalid }
            index += 1
        }

        private mutating func skipWhitespace() {
            while let byte = peek(), byte == 0x20 || byte == 0x09 ||
                    byte == 0x0A || byte == 0x0D {
                index += 1
            }
        }

        private func peek() -> UInt8? {
            index < bytes.count ? bytes[index] : nil
        }
    }
}
