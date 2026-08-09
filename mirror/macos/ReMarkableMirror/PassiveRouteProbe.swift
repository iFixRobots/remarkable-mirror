import Darwin
import Foundation
import os

protocol ProcessRunning: Actor {
    func run(_ request: ProcessRequest, timeout: Duration) async throws -> ProcessExecutionResult
}

extension OwnedProcessRegistry: ProcessRunning { }

struct SSHBannerProbeTarget: Equatable, Sendable {
    let host: String
    let boundInterface: String?

    init?(host: String, boundInterface: String? = nil) {
        guard SafeConnectionValue.isHost(host),
              Self.isNumericIPv4(host),
              boundInterface.map(BSDInterfaceName.isValid) ?? true else {
            return nil
        }
        self.host = host
        self.boundInterface = boundInterface
    }

    private static func isNumericIPv4(_ value: String) -> Bool {
        var address = in_addr()
        return value.withCString { inet_pton(AF_INET, $0, &address) } == 1
    }
}

protocol SSHBannerProbing: Actor {
    func probe(target: SSHBannerProbeTarget) async throws -> SSHBannerProbeResult
}

extension SSHBannerProbing {
    func probe(host: String) async throws -> SSHBannerProbeResult {
        guard let target = SSHBannerProbeTarget(host: host) else {
            return .noRoute(.tcpUnavailable)
        }
        return try await probe(target: target)
    }
}

enum SSHBannerProbeResult: Equatable, Sendable {
    case ssh
    case noRoute(PassiveRouteProbeDetail)
    case portOpenNoBanner(PassiveRouteProbeDetail)
}

enum SSHBannerDetection: Equatable, Sendable {
    case pending
    case found
    case invalid
}

struct SSHBannerParser: Sendable {
    static let maximumBytes = 4_096
    static let maximumLineBytes = 1_024
    static let maximumLines = 16

    private var line = Data()
    private var totalBytes = 0
    private var totalLines = 0
    private var terminalResult: SSHBannerDetection?

    mutating func consume(_ bytes: Data) -> SSHBannerDetection {
        if let terminalResult { return terminalResult }

        for byte in bytes {
            guard totalBytes < Self.maximumBytes,
                  totalLines < Self.maximumLines else {
                terminalResult = .invalid
                return .invalid
            }
            totalBytes += 1

            if byte == 0x0A {
                var candidate = line
                if candidate.last == 0x0D { candidate.removeLast() }
                if Self.isIdentification(candidate) {
                    terminalResult = .found
                    return .found
                }
                totalLines += 1
                line.removeAll(keepingCapacity: true)
                continue
            }

            guard line.count < Self.maximumLineBytes else {
                terminalResult = .invalid
                return .invalid
            }
            line.append(byte)
        }

        if totalBytes >= Self.maximumBytes || totalLines >= Self.maximumLines {
            terminalResult = .invalid
            return .invalid
        }
        return .pending
    }

    mutating func finish() -> SSHBannerDetection {
        if let terminalResult { return terminalResult }
        terminalResult = .invalid
        return .invalid
    }

    private static func isIdentification(_ line: Data) -> Bool {
        let ssh2 = Data("SSH-2.0-".utf8)
        let compatible = Data("SSH-1.99-".utf8)
        return (line.count > ssh2.count && line.starts(with: ssh2)) ||
            (line.count > compatible.count && line.starts(with: compatible))
    }
}

private enum SSHBannerProbeInfrastructureError: Error {
    case cancellationSignalUnavailable
}

final class SSHBannerProbeCancellationSignal: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    let pollDescriptor: Int32
    private let signalDescriptor: Int32

    init() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        let pipeStatus = descriptors.withUnsafeMutableBufferPointer { buffer in
            Darwin.pipe(buffer.baseAddress!)
        }
        guard pipeStatus == 0 else {
            throw SSHBannerProbeInfrastructureError.cancellationSignalUnavailable
        }

        let readDescriptor = descriptors[0]
        let writeDescriptor = descriptors[1]
        guard Self.configureDescriptor(readDescriptor),
              Self.configureDescriptor(writeDescriptor) else {
            Darwin.close(readDescriptor)
            Darwin.close(writeDescriptor)
            throw SSHBannerProbeInfrastructureError.cancellationSignalUnavailable
        }
        pollDescriptor = readDescriptor
        signalDescriptor = writeDescriptor
    }

    deinit {
        Darwin.close(pollDescriptor)
        Darwin.close(signalDescriptor)
    }

    func cancel() {
        let shouldSignal = state.withLock { isCancelled in
            guard !isCancelled else { return false }
            isCancelled = true
            return true
        }
        guard shouldSignal else { return }

        var byte: UInt8 = 1
        while true {
            let result = withUnsafePointer(to: &byte) { pointer in
                Darwin.write(signalDescriptor, pointer, 1)
            }
            if result == 1 || errno != EINTR { return }
        }
    }

    func throwIfCancelled() throws {
        if state.withLock({ $0 }) {
            throw CancellationError()
        }
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

private final class SSHBannerProbeQueuedOperation: Sendable {
    typealias Continuation = CheckedContinuation<SSHBannerProbeResult, any Error>

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

    private let cancellation: SSHBannerProbeCancellationSignal
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(cancellation: SSHBannerProbeCancellationSignal) {
        self.cancellation = cancellation
    }

    func install(_ continuation: Continuation) -> Bool {
        let shouldEnqueue = state.withLock { state in
            guard case .awaitingContinuation = state.phase else { return false }
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
            guard case let .pending(continuation) = state.phase else { return nil }
            state.phase = .completed
            return continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    func execute(
        _ operation: @escaping @Sendable (
            SSHBannerProbeCancellationSignal
        ) throws -> SSHBannerProbeResult
    ) {
        let continuation = state.withLock { state -> Continuation? in
            guard case let .pending(continuation) = state.phase else { return nil }
            state.phase = .running(continuation)
            return continuation
        }
        guard let continuation else { return }

        let result = Result<SSHBannerProbeResult, any Error> {
            try cancellation.throwIfCancelled()
            let result = try operation(cancellation)
            try cancellation.throwIfCancelled()
            return result
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

struct SSHBannerProbeWorkerQueue: Sendable {
    private let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func run(
        _ operation: @escaping @Sendable (
            SSHBannerProbeCancellationSignal
        ) throws -> SSHBannerProbeResult
    ) async throws -> SSHBannerProbeResult {
        let cancellation = try SSHBannerProbeCancellationSignal()
        let queuedOperation = SSHBannerProbeQueuedOperation(cancellation: cancellation)
        return try await withTaskCancellationHandler {
            try cancellation.throwIfCancelled()
            let result: SSHBannerProbeResult = try await withCheckedThrowingContinuation {
                continuation in
                guard queuedOperation.install(continuation) else { return }
                queue.async {
                    queuedOperation.execute(operation)
                }
            }
            try cancellation.throwIfCancelled()
            return result
        } onCancel: {
            queuedOperation.cancel()
        }
    }
}

enum SSHBannerSocketWaitResult: Equatable, Sendable {
    case ready(Int16)
    case timedOut
    case failed
}

actor SocketSSHBannerProbe: SSHBannerProbing {
    private struct IPv4InterfaceBinding {
        let index: UInt32
        let addresses: [in_addr_t]
    }

    private static let defaultWorker = SSHBannerProbeWorkerQueue(
        queue: DispatchQueue.global(qos: .utility)
    )
    private let worker: SSHBannerProbeWorkerQueue

    init(worker: SSHBannerProbeWorkerQueue? = nil) {
        self.worker = worker ?? Self.defaultWorker
    }

    func probe(target: SSHBannerProbeTarget) async throws -> SSHBannerProbeResult {
        try await worker.run { cancellation in
            try Self.blockingProbe(target: target, cancellation: cancellation)
        }
    }

    private static func blockingProbe(
        target: SSHBannerProbeTarget,
        cancellation: SSHBannerProbeCancellationSignal
    ) throws -> SSHBannerProbeResult {
        try cancellation.throwIfCancelled()
        let resolvedBinding: IPv4InterfaceBinding?
        if let boundInterface = target.boundInterface {
            guard let binding = interfaceBinding(named: boundInterface) else {
                return .noRoute(.tcpUnavailable)
            }
            resolvedBinding = binding
        } else {
            resolvedBinding = nil
        }
        try cancellation.throwIfCancelled()

        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_port = UInt16(22).bigEndian
        guard target.host.withCString({
            inet_pton(AF_INET, $0, &socketAddress.sin_addr)
        }) == 1 else {
            return .noRoute(.tcpUnavailable)
        }

        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { return .noRoute(.tcpUnavailable) }
        defer { abortiveClose(descriptor) }

        return try withUnsafePointer(to: &socketAddress) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                try probeSocket(
                    descriptor,
                    address: address,
                    addressLength: socklen_t(MemoryLayout<sockaddr_in>.size),
                    interfaceBinding: resolvedBinding,
                    cancellation: cancellation
                )
            }
        }
    }

    private static func probeSocket(
        _ descriptor: Int32,
        address: UnsafePointer<sockaddr>,
        addressLength: socklen_t,
        interfaceBinding: IPv4InterfaceBinding?,
        cancellation: SSHBannerProbeCancellationSignal
    ) throws -> SSHBannerProbeResult {
        try cancellation.throwIfCancelled()
        guard let expectedRemote = IPv4SocketEndpoint(
            address: address,
            length: addressLength
        ) else {
            return .noRoute(.tcpUnavailable)
        }
        if var interfaceIndex = interfaceBinding?.index {
            guard setsockopt(
                descriptor,
                IPPROTO_IP,
                IP_BOUND_IF,
                &interfaceIndex,
                socklen_t(MemoryLayout<UInt32>.size)
            ) == 0 else {
                return .noRoute(.tcpUnavailable)
            }
        }
        let originalFlags = fcntl(descriptor, F_GETFL, 0)
        guard originalFlags >= 0,
              fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            return .noRoute(.tcpUnavailable)
        }

        let connectResult = Darwin.connect(descriptor, address, addressLength)
        if connectResult != 0 {
            guard errno == EINPROGRESS else { return .noRoute(.tcpUnavailable) }
            let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            switch try waitForSocketEvents(
                descriptor,
                events: Int16(POLLOUT),
                deadline: deadline,
                cancellation: cancellation
            ) {
            case .ready:
                break
            case .timedOut:
                return .noRoute(.tcpConnectTimedOut)
            case .failed:
                return .noRoute(.tcpUnavailable)
            }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0,
                  socketError == 0 else {
                return .noRoute(.tcpUnavailable)
            }
        }

        guard let local = socketEndpoint(descriptor, peer: false),
              let remote = socketEndpoint(descriptor, peer: true),
              endpointsMatch(
                  local: local,
                  remote: remote,
                  expectedRemote: expectedRemote,
                  boundInterfaceAddresses: interfaceBinding?.addresses
              ) else {
            return .noRoute(.tcpUnavailable)
        }

        var parser = SSHBannerParser()
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            switch try waitForSocketEvents(
                descriptor,
                events: Int16(POLLIN),
                deadline: deadline,
                cancellation: cancellation
            ) {
            case .timedOut:
                return .portOpenNoBanner(.sshBannerTimedOut)
            case .failed:
                return .portOpenNoBanner(.sshBannerMissing)
            case .ready:
                break
            }

            try cancellation.throwIfCancelled()
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count == 0 { return .portOpenNoBanner(.sshBannerMissing) }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                return .portOpenNoBanner(.sshBannerMissing)
            }
            switch parser.consume(Data(buffer.prefix(count))) {
            case .found:
                return .ssh
            case .invalid:
                return .portOpenNoBanner(.sshBannerMissing)
            case .pending:
                continue
            }
        }
    }

    static func waitForSocketEvents(
        _ descriptor: Int32,
        events: Int16,
        deadline: UInt64,
        cancellation: SSHBannerProbeCancellationSignal,
        onPolling: @Sendable () -> Void = { }
    ) throws -> SSHBannerSocketWaitResult {
        var didNotify = false
        while true {
            try cancellation.throwIfCancelled()
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return .timedOut }
            let remainingNanoseconds = deadline - now
            let roundedMilliseconds = (remainingNanoseconds + 999_999) / 1_000_000
            let timeout = Int32(min(roundedMilliseconds, UInt64(Int32.max)))
            var descriptors = [
                pollfd(fd: descriptor, events: events, revents: 0),
                pollfd(fd: cancellation.pollDescriptor, events: Int16(POLLIN), revents: 0),
            ]
            if !didNotify {
                didNotify = true
                onPolling()
            }
            let pollResult = descriptors.withUnsafeMutableBufferPointer { buffer in
                Darwin.poll(buffer.baseAddress, nfds_t(buffer.count), timeout)
            }
            if pollResult == 0 { return .timedOut }
            if pollResult < 0 {
                if errno == EINTR { continue }
                return .failed
            }
            try cancellation.throwIfCancelled()
            if descriptors[1].revents != 0 {
                throw CancellationError()
            }
            if descriptors[0].revents & Int16(POLLNVAL) != 0 {
                return .failed
            }
            if descriptors[0].revents != 0 {
                return .ready(descriptors[0].revents)
            }
        }
    }

    static func endpointsMatch(
        local: IPv4SocketEndpoint,
        remote: IPv4SocketEndpoint,
        expectedRemote: IPv4SocketEndpoint,
        boundInterfaceAddresses: [in_addr_t]?
    ) -> Bool {
        guard local.address != in_addr_t(INADDR_ANY),
              local.port != 0,
              remote.address != in_addr_t(INADDR_ANY),
              remote.port != 0,
              expectedRemote.address != in_addr_t(INADDR_ANY),
              expectedRemote.port != 0,
              remote == expectedRemote else {
            return false
        }
        guard let boundInterfaceAddresses else { return true }
        return !boundInterfaceAddresses.isEmpty && boundInterfaceAddresses.contains(local.address)
    }

    private static func interfaceBinding(named name: String) -> IPv4InterfaceBinding? {
        guard BSDInterfaceName.isValid(name) else { return nil }
        let index = name.withCString(if_nametoindex)
        guard index != 0 else { return nil }

        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return nil }
        defer { freeifaddrs(first) }

        var addresses = Set<in_addr_t>()
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            current = entry.pointee.ifa_next
            guard let rawName = entry.pointee.ifa_name,
                  String(cString: rawName) == name,
                  let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET) else {
                continue
            }
            let ipv4 = UnsafeRawPointer(address)
                .assumingMemoryBound(to: sockaddr_in.self)
                .pointee
                .sin_addr
                .s_addr
            if ipv4 != in_addr_t(INADDR_ANY) {
                addresses.insert(ipv4)
            }
        }
        guard !addresses.isEmpty else { return nil }
        return IPv4InterfaceBinding(index: index, addresses: Array(addresses))
    }

    private static func socketEndpoint(
        _ descriptor: Int32,
        peer: Bool
    ) -> IPv4SocketEndpoint? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let status = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                if peer {
                    return getpeername(descriptor, socketAddress, &length)
                }
                return getsockname(descriptor, socketAddress, &length)
            }
        }
        guard status == 0 else { return nil }
        return IPv4SocketEndpoint(storage: storage, length: length)
    }

    private static func abortiveClose(_ descriptor: Int32) {
        var option = linger(l_onoff: 1, l_linger: 0)
        _ = withUnsafePointer(to: &option) { pointer in
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_LINGER,
                pointer,
                socklen_t(MemoryLayout<linger>.size)
            )
        }
        _ = Darwin.close(descriptor)
    }
}

struct IPv4SocketEndpoint: Equatable, Sendable {
    let address: in_addr_t
    let port: in_port_t

    init(address: in_addr_t, port: in_port_t) {
        self.address = address
        self.port = port
    }

    init?(address: UnsafePointer<sockaddr>, length: socklen_t) {
        guard Int(length) >= MemoryLayout<sockaddr_in>.size,
              address.pointee.sa_family == sa_family_t(AF_INET) else {
            return nil
        }
        let ipv4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee
        self.init(address: ipv4.sin_addr.s_addr, port: ipv4.sin_port)
    }

    init?(storage: sockaddr_storage, length: socklen_t) {
        guard Int(length) >= MemoryLayout<sockaddr_in>.size,
              storage.ss_family == sa_family_t(AF_INET) else {
            return nil
        }
        let ipv4 = withUnsafePointer(to: storage) { pointer in
            UnsafeRawPointer(pointer).assumingMemoryBound(to: sockaddr_in.self).pointee
        }
        self.init(address: ipv4.sin_addr.s_addr, port: ipv4.sin_port)
    }
}

enum PassiveRouteProbeState: Equatable, Sendable {
    case noRoute
    case portOpenNoBanner
    case authenticated
    case identityRejected
    case prerequisiteMismatch
}

enum PassiveRouteProbeDetail: Equatable, Sendable {
    case none
    case tcpUnavailable
    case tcpConnectTimedOut
    case sshBannerMissing
    case sshBannerTimedOut
    case localCredentialFilesMissing
    case openSSHUnavailable
    case authenticationTimedOut
    case hostKeyRejected
    case authenticationRejected
    case sshConnectionLost
    case tabletPrerequisiteMismatch
    case capabilityResponseInvalid
}

struct PassiveRouteProbeResult: Equatable, Sendable {
    let state: PassiveRouteProbeState
    let detail: PassiveRouteProbeDetail
    let capability: PassiveRouteCapability?
    let identityAuthenticated: Bool

    init(
        state: PassiveRouteProbeState,
        detail: PassiveRouteProbeDetail,
        capability: PassiveRouteCapability? = nil,
        identityAuthenticated: Bool = false
    ) {
        self.state = state
        self.detail = detail
        self.capability = capability
        self.identityAuthenticated = identityAuthenticated
    }
}

enum TabletCapabilityProbeContract {
    static let orderedKeys = [
        "RMMIRROR_CAP_BOOT_ID",
        "RMMIRROR_CAP_ACTIVE_ROOT",
        "RMMIRROR_CAP_OS_VERSION",
        "RMMIRROR_CAP_OS_BUILD",
        "RMMIRROR_CAP_KERNEL",
        "RMMIRROR_CAP_PROBE_VERSION",
        "RMMIRROR_CAP_TRANSPORT_VERSION",
        "RMMIRROR_CAP_TRANSPORT_SCHEMA",
        "RMMIRROR_CAP_USB_CONNECTION_POLICY",
        "RMMIRROR_CAP_TRANSPORT_ACTIVE",
        "RMMIRROR_CAP_WAKE_ENDPOINT_HEALTHY",
        "RMMIRROR_CAP_TRANSPORT_STATE",
        "RMMIRROR_CAP_USB_POWER_ONLINE",
        "RMMIRROR_CAP_POWER_KNOWN",
        "RMMIRROR_CAP_USB_CONNECTED",
        "RMMIRROR_CAP_CONNECTION_KNOWN",
        "RMMIRROR_CAP_USB_DATA_QUALIFIED",
        "RMMIRROR_CAP_WAKE_LOCK_ACTIVE",
        "RMMIRROR_CAP_SYSTEM_SLEEP_BLOCKED",
        "RMMIRROR_CAP_XOVI_VERSION",
    ]

    static let captureCommand = #"""
        probe=/home/root/.local/bin/rmmirror-probe
        transport=/usr/libexec/rmmirror-transport-wake
        transport_status=/run/rmmirror-transport-wake.json
        xovi_version_file=/home/root/xovi/.rmmirror-version

        boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
        active_root="$(findmnt -n -o SOURCE / 2>/dev/null | head -n 1 || true)"
        if test -z "$active_root"; then
          active_root="$(awk '$2 == "/" { print $1; exit }' /proc/mounts 2>/dev/null || true)"
        fi
        os_version="$(sed -n 's/^IMG_VERSION=//p' /etc/os-release 2>/dev/null | head -n 1 | tr -d '"')"
        os_build="$(sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | head -n 1 | tr -d '"')"
        kernel_release="$(uname -r 2>/dev/null || true)"
        probe_version="$($probe version 2>/dev/null || true)"
        transport_version="$($transport --version 2>/dev/null || true)"
        transport_active="$(systemctl is-active rmmirror-transport-wake.service 2>/dev/null || true)"
        transport_schema="$(sed -n 's/.*"schema":"\([^"]*\)".*/\1/p' "$transport_status" 2>/dev/null | head -n 1)"
        usb_connection_policy="$(sed -n 's/.*"usb_connection_policy":"\([^"]*\)".*/\1/p' "$transport_status" 2>/dev/null | head -n 1)"
        wake_endpoint_healthy="$(sed -n 's/.*"wake_endpoint_healthy":\(true\|false\).*/\1/p' "$transport_status" 2>/dev/null | head -n 1)"
        transport_state="$(sed -n 's/.*"state":"\([^"]*\)".*/\1/p' "$transport_status" 2>/dev/null | head -n 1)"
        usb_power_online="$(sed -n 's/.*"usb_power_online":\(true\|false\).*/\1/p' "$transport_status" 2>/dev/null | head -n 1)"
        power_known="$(sed -n 's/.*"power_known":\(true\|false\).*/\1/p' "$transport_status" 2>/dev/null | head -n 1)"
        usb_connected="$(sed -n 's/.*"usb_connected":\(true\|false\).*/\1/p' "$transport_status" 2>/dev/null | head -n 1)"
        connection_known="$(sed -n 's/.*"connection_known":\(true\|false\).*/\1/p' "$transport_status" 2>/dev/null | head -n 1)"
        usb_data_qualified="$(sed -n 's/.*"usb_data_qualified":\(true\|false\).*/\1/p' "$transport_status" 2>/dev/null | head -n 1)"
        wake_lock_active="$(sed -n 's/.*"wake_lock_active":\(true\|false\).*/\1/p' "$transport_status" 2>/dev/null | head -n 1)"
        system_sleep_blocked="$(sed -n 's/.*"system_sleep_blocked":\(true\|false\).*/\1/p' "$transport_status" 2>/dev/null | head -n 1)"
        xovi_version="$(cat "$xovi_version_file" 2>/dev/null | head -n 1 || true)"
        """#

    static let outputCommand = #"""
        printf '%s\n' "RMMIRROR_CAP_BOOT_ID=$boot_id"
        printf '%s\n' "RMMIRROR_CAP_ACTIVE_ROOT=$active_root"
        printf '%s\n' "RMMIRROR_CAP_OS_VERSION=$os_version"
        printf '%s\n' "RMMIRROR_CAP_OS_BUILD=$os_build"
        printf '%s\n' "RMMIRROR_CAP_KERNEL=$kernel_release"
        printf '%s\n' "RMMIRROR_CAP_PROBE_VERSION=$probe_version"
        printf '%s\n' "RMMIRROR_CAP_TRANSPORT_VERSION=$transport_version"
        printf '%s\n' "RMMIRROR_CAP_TRANSPORT_SCHEMA=$transport_schema"
        printf '%s\n' "RMMIRROR_CAP_USB_CONNECTION_POLICY=$usb_connection_policy"
        printf '%s\n' "RMMIRROR_CAP_TRANSPORT_ACTIVE=$transport_active"
        printf '%s\n' "RMMIRROR_CAP_WAKE_ENDPOINT_HEALTHY=$wake_endpoint_healthy"
        printf '%s\n' "RMMIRROR_CAP_TRANSPORT_STATE=$transport_state"
        printf '%s\n' "RMMIRROR_CAP_USB_POWER_ONLINE=$usb_power_online"
        printf '%s\n' "RMMIRROR_CAP_POWER_KNOWN=$power_known"
        printf '%s\n' "RMMIRROR_CAP_USB_CONNECTED=$usb_connected"
        printf '%s\n' "RMMIRROR_CAP_CONNECTION_KNOWN=$connection_known"
        printf '%s\n' "RMMIRROR_CAP_USB_DATA_QUALIFIED=$usb_data_qualified"
        printf '%s\n' "RMMIRROR_CAP_WAKE_LOCK_ACTIVE=$wake_lock_active"
        printf '%s\n' "RMMIRROR_CAP_SYSTEM_SLEEP_BLOCKED=$system_sleep_blocked"
        printf '%s\n' "RMMIRROR_CAP_XOVI_VERSION=$xovi_version"
        """#
}

struct PassiveRouteCapability: Equatable, Sendable {
    static let expectedProbeVersion = "0.4.9"
    static let expectedTransportVersion = "0.6.0"
    static let expectedTransportSchema = "rmmirror.transport-wake/v1"
    static let expectedUSBConnectionPolicy = "carrier-qualified-power-hold/v1"
    static let expectedXoviVersion = "v19-23052026"

    let bootID: UUID
    let activeRoot: String
    let osVersion: String
    let osBuild: String
    let kernelRelease: String
    let probeVersion: String
    let transportVersion: String
    let transportSchema: String
    let usbConnectionPolicy: String
    let transportActive: Bool
    let wakeEndpointHealthy: Bool
    let transportState: String
    let usbPowerOnline: Bool
    let powerKnown: Bool
    let usbConnected: Bool
    let connectionKnown: Bool
    let usbDataQualified: Bool
    let wakeLockActive: Bool
    let systemSleepBlocked: Bool
    let transportOperational: Bool
    let xoviVersion: String
    let isCurrent: Bool

    static func parse(_ data: Data) -> PassiveRouteCapability? {
        guard data.count <= 32_768,
              let output = String(data: data, encoding: .utf8) else {
            return nil
        }
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \Character.isNewline) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator])
            guard key.hasPrefix("RMMIRROR_CAP_") else { continue }
            let value = String(line[line.index(after: separator)...])
            guard values.updateValue(value, forKey: key) == nil else { return nil }
        }

        guard let bootIDValue = safe(values["RMMIRROR_CAP_BOOT_ID"]),
              bootIDValue.count == 36,
              let bootID = UUID(uuidString: bootIDValue),
              let activeRoot = safe(values["RMMIRROR_CAP_ACTIVE_ROOT"]),
              activeRoot.first == "/",
              !activeRoot.contains(where: \Character.isWhitespace),
              let osVersion = safe(values["RMMIRROR_CAP_OS_VERSION"]),
              let osBuild = safe(values["RMMIRROR_CAP_OS_BUILD"]),
              let kernelRelease = safe(values["RMMIRROR_CAP_KERNEL"]),
              let probeVersion = safe(values["RMMIRROR_CAP_PROBE_VERSION"]),
              let transportVersion = safe(values["RMMIRROR_CAP_TRANSPORT_VERSION"]),
              let transportSchema = safe(values["RMMIRROR_CAP_TRANSPORT_SCHEMA"]),
              let usbConnectionPolicy = safe(values["RMMIRROR_CAP_USB_CONNECTION_POLICY"]),
              let transportActiveValue = safe(values["RMMIRROR_CAP_TRANSPORT_ACTIVE"]),
              let wakeEndpointValue = safe(values["RMMIRROR_CAP_WAKE_ENDPOINT_HEALTHY"]),
              let transportState = safe(values["RMMIRROR_CAP_TRANSPORT_STATE"]),
              let usbPowerOnline = boolean(values["RMMIRROR_CAP_USB_POWER_ONLINE"]),
              let powerKnown = boolean(values["RMMIRROR_CAP_POWER_KNOWN"]),
              let usbConnected = boolean(values["RMMIRROR_CAP_USB_CONNECTED"]),
              let connectionKnown = boolean(values["RMMIRROR_CAP_CONNECTION_KNOWN"]),
              let usbDataQualified = boolean(values["RMMIRROR_CAP_USB_DATA_QUALIFIED"]),
              let wakeLockActive = boolean(values["RMMIRROR_CAP_WAKE_LOCK_ACTIVE"]),
              let systemSleepBlocked = boolean(values["RMMIRROR_CAP_SYSTEM_SLEEP_BLOCKED"]),
              let xoviVersion = safe(values["RMMIRROR_CAP_XOVI_VERSION"]) else {
            return nil
        }

        let transportActive = transportActiveValue == "active"
        let wakeEndpointHealthy = wakeEndpointValue == "true"
        let transportOperational = transportState == "holding" &&
            usbPowerOnline &&
            powerKnown &&
            usbConnected &&
            connectionKnown &&
            usbDataQualified &&
            wakeLockActive &&
            systemSleepBlocked &&
            wakeEndpointHealthy
        return PassiveRouteCapability(
            bootID: bootID,
            activeRoot: activeRoot,
            osVersion: osVersion,
            osBuild: osBuild,
            kernelRelease: kernelRelease,
            probeVersion: probeVersion,
            transportVersion: transportVersion,
            transportSchema: transportSchema,
            usbConnectionPolicy: usbConnectionPolicy,
            transportActive: transportActive,
            wakeEndpointHealthy: wakeEndpointHealthy,
            transportState: transportState,
            usbPowerOnline: usbPowerOnline,
            powerKnown: powerKnown,
            usbConnected: usbConnected,
            connectionKnown: connectionKnown,
            usbDataQualified: usbDataQualified,
            wakeLockActive: wakeLockActive,
            systemSleepBlocked: systemSleepBlocked,
            transportOperational: transportOperational,
            xoviVersion: xoviVersion,
            isCurrent: probeVersion == expectedProbeVersion &&
                transportVersion == expectedTransportVersion &&
                transportSchema == expectedTransportSchema &&
                usbConnectionPolicy == expectedUSBConnectionPolicy &&
                transportActive &&
                wakeEndpointHealthy &&
                xoviVersion == expectedXoviVersion
        )
    }

    func verified(at date: Date) -> VerifiedTabletCapability {
        VerifiedTabletCapability(
            verifiedAt: date,
            bootID: bootID,
            activeRoot: activeRoot,
            osVersion: osVersion,
            osBuild: osBuild,
            kernelRelease: kernelRelease,
            probeVersion: probeVersion,
            transportVersion: transportVersion,
            transportSchema: transportSchema,
            xoviVersion: xoviVersion
        )
    }

    func matchesTabletIdentity(
        _ other: PassiveRouteCapability
    ) -> Bool {
        bootID == other.bootID &&
            activeRoot == other.activeRoot &&
            osVersion == other.osVersion &&
            osBuild == other.osBuild &&
            kernelRelease == other.kernelRelease &&
            probeVersion == other.probeVersion &&
            transportVersion == other.transportVersion &&
            transportSchema == other.transportSchema &&
            usbConnectionPolicy == other.usbConnectionPolicy &&
            xoviVersion == other.xoviVersion
    }

    private static func safe(_ value: String?) -> String? {
        guard let value, SafeConnectionValue.isOpaque(value) else { return nil }
        return value
    }

    private static func boolean(_ value: String?) -> Bool? {
        switch value {
        case "true": true
        case "false": false
        default: nil
        }
    }
}

actor PassiveRouteProbe {
    static let capabilityCommand = #"""
        printf '%s\n' 'RMMIRROR_ROUTE_AUTHENTICATED=1'

        \#(TabletCapabilityProbeContract.captureCommand)

        \#(TabletCapabilityProbeContract.outputCommand)

        mismatch=0
        test -n "$boot_id" || mismatch=1
        test -n "$active_root" || mismatch=1
        test -n "$os_version" || mismatch=1
        test -n "$os_build" || mismatch=1
        test -n "$kernel_release" || mismatch=1
        test "$probe_version" = '0.4.9' || mismatch=1
        test "$transport_version" = '0.6.0' || mismatch=1
        test "$transport_schema" = 'rmmirror.transport-wake/v1' || mismatch=1
        test "$usb_connection_policy" = 'carrier-qualified-power-hold/v1' || mismatch=1
        test "$transport_active" = 'active' || mismatch=1
        test "$wake_endpoint_healthy" = 'true' || mismatch=1
        test "$xovi_version" = 'v19-23052026' || mismatch=1

        if test "$mismatch" -ne 0; then
          printf '%s\n' 'RMMIRROR_ROUTE_PREREQUISITE_MISMATCH=1'
          exit 42
        fi

        printf '%s\n' 'RMMIRROR_ROUTE_READY=1'
        exit 0
        """#

    private let route: SSHRoute
    private let processRunner: any ProcessRunning

    init(
        route: SSHRoute,
        processRunner: any ProcessRunning
    ) {
        self.route = route
        self.processRunner = processRunner
    }

    func probe(generation: GenerationID) async throws -> PassiveRouteProbeResult {
        guard route.credentialFilesAreReady else {
            return PassiveRouteProbeResult(
                state: .prerequisiteMismatch,
                detail: .localCredentialFilesMissing
            )
        }

        do {
            let result = try await processRunner.run(
                route.authenticationProbeRequest(generation: generation),
                timeout: .seconds(7)
            )
            return Self.classify(result)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return PassiveRouteProbeResult(
                state: .prerequisiteMismatch,
                detail: .openSSHUnavailable
            )
        }
    }

    static func classify(_ result: ProcessExecutionResult) -> PassiveRouteProbeResult {
        if result.outcome == .timedOut {
            return PassiveRouteProbeResult(state: .noRoute, detail: .authenticationTimedOut)
        }

        let errorText = String(data: result.standardError.data, encoding: .utf8) ?? ""
        if containsAny(errorText, [
            "REMOTE HOST IDENTIFICATION HAS CHANGED",
            "Host key verification failed",
        ]) {
            return PassiveRouteProbeResult(state: .identityRejected, detail: .hostKeyRejected)
        }
        if containsAny(errorText, [
            "Permission denied",
            "no supported authentication methods available",
            "Too many authentication failures",
        ]) {
            return PassiveRouteProbeResult(
                state: .identityRejected,
                detail: .authenticationRejected
            )
        }

        guard case let .exited(status) = result.outcome else {
            return PassiveRouteProbeResult(state: .noRoute, detail: .sshConnectionLost)
        }
        if status == 255 {
            return PassiveRouteProbeResult(state: .noRoute, detail: .sshConnectionLost)
        }

        let output = result.standardOutput.data
        let outputText = String(data: output, encoding: .utf8) ?? ""
        let capability = result.standardOutput.wasTruncated
            ? nil
            : PassiveRouteCapability.parse(output)
        if status == 0,
           outputText.contains("RMMIRROR_ROUTE_READY=1"),
           let capability {
            return PassiveRouteProbeResult(
                state: .authenticated,
                detail: .none,
                capability: capability,
                identityAuthenticated: true
            )
        }

        let identityAuthenticated = outputText.contains("RMMIRROR_ROUTE_AUTHENTICATED=1")
        if status == 42 || identityAuthenticated {
            return PassiveRouteProbeResult(
                state: .prerequisiteMismatch,
                detail: .tabletPrerequisiteMismatch,
                capability: capability,
                identityAuthenticated: identityAuthenticated
            )
        }

        return PassiveRouteProbeResult(
            state: .prerequisiteMismatch,
            detail: .capabilityResponseInvalid
        )
    }

    private static func containsAny(_ value: String, _ candidates: [String]) -> Bool {
        candidates.contains { value.localizedCaseInsensitiveContains($0) }
    }
}

private extension SSHRoute {
    var credentialFilesAreReady: Bool {
        Self.isSecureCredential(identityURL) && Self.isSecureCredential(knownHostsURL)
    }

    static func isSecureCredential(_ url: URL) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return false }
        return information.st_uid == geteuid() &&
            information.st_nlink == 1 &&
            information.st_mode & S_IFMT == S_IFREG &&
            information.st_mode & 0o777 == 0o600 &&
            information.st_size > 0
    }
}
