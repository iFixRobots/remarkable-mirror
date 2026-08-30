import Foundation

protocol TabletKeyAuthorizationRouteVerifying: Actor {
    func verify() async -> DirectUSBRouteVerification
}

extension DirectUSBRouteVerifier: TabletKeyAuthorizationRouteVerifying { }

protocol TabletKeyAuthorizationStreamingProcess: Actor {
    func write(_ data: Data) async throws
    func finishWriting() async
    func waitForExitBeforeDeadline(
        _ timeout: Duration
    ) async throws -> ProcessExecutionResult?
    func abortAndConfirm(timeout: Duration) async throws -> ProcessExecutionResult
}

extension OwnedStreamingProcess: TabletKeyAuthorizationStreamingProcess { }

protocol TabletKeyAuthorizationProcessLaunching: Actor {
    func launchAuthorizationProcess(
        _ request: ProcessRequest
    ) async throws -> any TabletKeyAuthorizationStreamingProcess
}

extension OwnedProcessRegistry: TabletKeyAuthorizationProcessLaunching {
    func launchAuthorizationProcess(
        _ request: ProcessRequest
    ) async throws -> any TabletKeyAuthorizationStreamingProcess {
        try await launchInteractive(request)
    }
}

protocol TabletKeyAuthorizationKeyOnlyProbing: Actor {
    func probeKeyOnly(
        identityURL: URL,
        knownHostsURL: URL,
        usbContext: DirectUSBRouteContext,
        generation: GenerationID
    ) async throws -> PassiveRouteProbeResult
}

actor PassiveTabletKeyAuthorizationProbe: TabletKeyAuthorizationKeyOnlyProbing {
    private let processRunner: any ProcessRunning

    init(processRunner: any ProcessRunning) {
        self.processRunner = processRunner
    }

    func probeKeyOnly(
        identityURL: URL,
        knownHostsURL: URL,
        usbContext: DirectUSBRouteContext,
        generation: GenerationID
    ) async throws -> PassiveRouteProbeResult {
        let route = try SSHRoute(
            kind: .usb,
            host: DeviceProfile.requiredHostKeyAlias,
            identityURL: identityURL,
            knownHostsURL: knownHostsURL,
            boundInterface: usbContext.interfaceName
        )
        let probe = PassiveRouteProbe(
            route: route,
            processRunner: processRunner
        )
        return try await probe.probe(generation: generation)
    }
}

enum TabletKeyAuthorizationFailure: Equatable, Sendable {
    case busy
    case invalidPassword
    case invalidPublicKey
    case invalidCredentialPath
    case scriptUnavailable
    case usbUnavailable
    case unsafeUSBRoute
    case usbContextChanged
    case openSSHUnavailable
    case authorizationTimedOut
    case authorizationRejected
    case authorizationProtocolFailed
    case keyVerificationFailed(PassiveRouteProbeDetail)
}

enum TabletKeyAuthorizationResult: Equatable, Sendable {
    /// The key was appended and then proved over the exact key-only USB route.
    /// A current capability lets setup skip the otherwise idempotent installer.
    case authorized(PassiveRouteCapability?)
    case failed(TabletKeyAuthorizationFailure)
}

/// Performs the one password-authenticated operation allowed by Mirror: adding
/// the already-generated app key after an explicit owner approval. The
/// password is accepted only by this method and is written only to the owned
/// Expect child's standard input.
actor TabletKeyAuthorizer {
    static let maximumPasswordBytes = 1_024
    static let maximumPublicKeyBytes = 4_096
    static let maximumProcessOutputBytes = 4_096

    private static let expectURL = URL(filePath: "/usr/bin/expect")
    private static let scriptName = "AuthorizeTabletKey"
    private static let scriptExtension = "expect"
    private static let authorizationTimeout: Duration = .seconds(12)
    private static let abortConfirmationTimeout: Duration = .seconds(3)

    private let routeVerifier: any TabletKeyAuthorizationRouteVerifying
    private let processLauncher: any TabletKeyAuthorizationProcessLaunching
    private let keyOnlyProbe: any TabletKeyAuthorizationKeyOnlyProbing
    private let scriptURL: URL?

    private var activeOperationID: UUID?

    init(
        processRegistry: OwnedProcessRegistry,
        routeVerifier: DirectUSBRouteVerifier
    ) {
        self.routeVerifier = routeVerifier
        self.processLauncher = processRegistry
        self.keyOnlyProbe = PassiveTabletKeyAuthorizationProbe(
            processRunner: processRegistry
        )
        self.scriptURL = Self.bundledScriptURL(in: .main)
    }

    init(
        routeVerifier: any TabletKeyAuthorizationRouteVerifying,
        processLauncher: any TabletKeyAuthorizationProcessLaunching,
        keyOnlyProbe: any TabletKeyAuthorizationKeyOnlyProbing,
        scriptURL: URL?
    ) {
        self.routeVerifier = routeVerifier
        self.processLauncher = processLauncher
        self.keyOnlyProbe = keyOnlyProbe
        self.scriptURL = scriptURL
    }

    func authorizeOwnerApprovedKey(
        password: String,
        publicKey: Data,
        identityURL: URL,
        knownHostsURL: URL,
        expectedUSBContext: DirectUSBRouteContext,
        generation: GenerationID
    ) async throws -> TabletKeyAuthorizationResult {
        guard activeOperationID == nil else { return .failed(.busy) }
        guard Self.isValidPassword(password) else { return .failed(.invalidPassword) }
        guard let publicKey = Self.normalizedEd25519PublicKey(publicKey) else {
            return .failed(.invalidPublicKey)
        }
        guard SafeConnectionValue.isAbsoluteFileURL(identityURL),
              SafeConnectionValue.isAbsoluteFileURL(knownHostsURL) else {
            return .failed(.invalidCredentialPath)
        }
        guard BSDInterfaceName.isValid(expectedUSBContext.interfaceName) else {
            return .failed(.unsafeUSBRoute)
        }
        guard let scriptURL,
              let request = Self.authorizationRequest(
                  scriptURL: scriptURL,
                  knownHostsURL: knownHostsURL,
                  usbContext: expectedUSBContext,
                  generation: generation
              ) else {
            return .failed(.scriptUnavailable)
        }

        let operationID = UUID()
        let childOwner = TabletKeyAuthorizationChildOwner(
            confirmationTimeout: Self.abortConfirmationTimeout
        )
        activeOperationID = operationID
        defer {
            if activeOperationID == operationID {
                activeOperationID = nil
            }
        }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let failure = await exactRouteFailure(expected: expectedUSBContext) {
                return .failed(failure)
            }
            try Task.checkCancellation()

            let process: any TabletKeyAuthorizationStreamingProcess
            do {
                process = try await processLauncher.launchAuthorizationProcess(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return .failed(.openSSHUnavailable)
            }
            try await childOwner.install(process)

            do {
                try Task.checkCancellation()
                let payload = Data("\(password)\n\(publicKey)\n".utf8)
                try await process.write(payload)
                await process.finishWriting()
                guard let execution = try await process.waitForExitBeforeDeadline(
                    Self.authorizationTimeout
                ) else {
                    await childOwner.abortAndWait(process)
                    return .failed(.authorizationTimedOut)
                }
                try Task.checkCancellation()
                await childOwner.markFinished()

                guard Self.isSuccessfulAuthorizationExecution(execution) else {
                    if let failure = await exactRouteFailure(
                        expected: expectedUSBContext
                    ) {
                        return .failed(failure)
                    }
                    return .failed(Self.authorizationFailure(for: execution))
                }
            } catch is CancellationError {
                await childOwner.abortAndWait(process)
                throw CancellationError()
            } catch {
                await childOwner.abortAndWait(process)
                if let failure = await exactRouteFailure(
                    expected: expectedUSBContext
                ) {
                    return .failed(failure)
                }
                return .failed(.authorizationProtocolFailed)
            }

            try Task.checkCancellation()
            if let failure = await exactRouteFailure(expected: expectedUSBContext) {
                return .failed(failure)
            }
            try Task.checkCancellation()

            let proof: PassiveRouteProbeResult
            do {
                proof = try await keyOnlyProbe.probeKeyOnly(
                    identityURL: identityURL,
                    knownHostsURL: knownHostsURL,
                    usbContext: expectedUSBContext,
                    generation: generation
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return .failed(.keyVerificationFailed(.openSSHUnavailable))
            }
            try Task.checkCancellation()
            guard proof.identityAuthenticated,
                  proof.state == .authenticated || proof.state == .prerequisiteMismatch else {
                return .failed(.keyVerificationFailed(proof.detail))
            }

            if let failure = await exactRouteFailure(expected: expectedUSBContext) {
                return .failed(failure)
            }
            try Task.checkCancellation()
            return .authorized(proof.capability)
        } onCancel: {
            Task { await childOwner.requestCancellation() }
        }
    }

    static func bundledScriptURL(in bundle: Bundle) -> URL? {
        bundle.url(forResource: scriptName, withExtension: scriptExtension)
    }

    static func authorizationRequest(
        scriptURL: URL,
        knownHostsURL: URL,
        usbContext: DirectUSBRouteContext,
        generation: GenerationID
    ) -> ProcessRequest? {
        guard SafeConnectionValue.isAbsoluteFileURL(scriptURL),
              SafeConnectionValue.isAbsoluteFileURL(knownHostsURL),
              BSDInterfaceName.isValid(usbContext.interfaceName) else {
            return nil
        }
        return ProcessRequest(
            executableURL: expectURL,
            arguments: [
                "-N", "-n", "-f", scriptURL.path,
                usbContext.interfaceName,
                knownHostsURL.path,
            ],
            generation: generation,
            role: .tabletKeyAuthorization,
            outputLimit: maximumProcessOutputBytes,
            ioMode: .streaming
        )
    }

    static func normalizedEd25519PublicKey(_ data: Data) -> String? {
        guard !data.isEmpty,
              data.count <= maximumPublicKeyBytes,
              var line = String(data: data, encoding: .utf8) else {
            return nil
        }
        if line.hasSuffix("\r\n") {
            line.removeLast(2)
        } else if line.hasSuffix("\n") {
            line.removeLast()
        }
        guard !line.isEmpty,
              line.utf8.count <= maximumPublicKeyBytes,
              !line.contains("\r"),
              !line.contains("\n"),
              line.utf8.allSatisfy({ (0x20...0x7e).contains($0) }) else {
            return nil
        }

        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard (2...3).contains(fields.count),
              fields[0] == Substring(KnownHostIdentity.algorithm),
              let blob = Data(base64Encoded: String(fields[1])),
              blob.base64EncodedString() == fields[1],
              (try? KnownHostIdentity(
                  alias: DeviceProfile.requiredHostKeyAlias,
                  keyBlob: blob
              )) != nil else {
            return nil
        }
        if fields.count == 3 {
            return "\(KnownHostIdentity.algorithm) \(fields[1]) \(fields[2])"
        }
        return "\(KnownHostIdentity.algorithm) \(fields[1])"
    }

    private static func isValidPassword(_ password: String) -> Bool {
        let bytes = password.utf8
        return !bytes.isEmpty &&
            bytes.count <= maximumPasswordBytes &&
            !password.contains("\0") &&
            !password.contains("\r") &&
            !password.contains("\n")
    }

    private static func isSuccessfulAuthorizationExecution(
        _ execution: ProcessExecutionResult
    ) -> Bool {
        execution.outcome == .exited(status: 0) &&
            !execution.standardOutput.wasTruncated &&
            execution.standardOutput.data.isEmpty &&
            !execution.standardError.wasTruncated &&
            execution.standardError.data.isEmpty
    }

    private static func authorizationFailure(
        for execution: ProcessExecutionResult
    ) -> TabletKeyAuthorizationFailure {
        switch execution.outcome {
        case .timedOut, .exited(status: 80):
            .authorizationTimedOut
        case .exited(status: 78):
            .authorizationRejected
        case .exited:
            .authorizationProtocolFailed
        }
    }

    private func exactRouteFailure(
        expected: DirectUSBRouteContext
    ) async -> TabletKeyAuthorizationFailure? {
        switch await routeVerifier.verify() {
        case let .verified(current) where current == expected:
            return nil
        case .verified:
            return .usbContextChanged
        case .unavailable:
            return .usbUnavailable
        case .accessoryApprovalRequired:
            return .usbUnavailable
        case .unsafeRoute:
            return .unsafeUSBRoute
        }
    }

}

private actor TabletKeyAuthorizationChildOwner {
    private let confirmationTimeout: Duration
    private var process: (any TabletKeyAuthorizationStreamingProcess)?
    private var cleanupTask: Task<Void, Never>?
    private var cancellationRequested = false

    init(confirmationTimeout: Duration) {
        self.confirmationTimeout = confirmationTimeout
    }

    func install(
        _ process: any TabletKeyAuthorizationStreamingProcess
    ) async throws {
        self.process = process
        if cancellationRequested {
            await startCleanupIfNeeded(process)
            throw CancellationError()
        }
    }

    func requestCancellation() async {
        cancellationRequested = true
        guard let process else { return }
        await startCleanupIfNeeded(process)
    }

    func abortAndWait(
        _ process: any TabletKeyAuthorizationStreamingProcess
    ) async {
        if self.process == nil, cleanupTask == nil {
            self.process = process
        }
        await startCleanupIfNeeded(process)
    }

    func markFinished() {
        process = nil
    }

    private func startCleanupIfNeeded(
        _ process: any TabletKeyAuthorizationStreamingProcess
    ) async {
        if cleanupTask == nil {
            let confirmationTimeout = self.confirmationTimeout
            cleanupTask = Task {
                _ = try? await process.abortAndConfirm(timeout: confirmationTimeout)
            }
        }
        if let cleanupTask {
            await cleanupTask.value
        }
        self.process = nil
    }
}
