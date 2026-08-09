import Foundation

protocol TabletPairingProfileStoring: Actor {
    func load() -> DeviceProfileLoadResult
    func paths() -> DeviceProfilePaths
    func loadPendingSSHMaterial() -> PendingSSHMaterialLoadResult
    func markTabletAuthorized(
        expectedPending: DeviceProfile,
        authenticatedUSBCapability: VerifiedTabletCapability
    ) throws -> DeviceProfile
    func refreshPendingWiFiVerification(
        expected: DeviceProfile,
        capability: VerifiedTabletCapability
    ) throws -> DeviceProfile
    func refreshLastVerified(
        expectedReady: DeviceProfile,
        capability: VerifiedTabletCapability
    ) throws -> DeviceProfile
    func promoteToReady(
        expectedPendingWiFiVerification: DeviceProfile,
        wifi: VerifiedWiFiRoute,
        capability: VerifiedTabletCapability
    ) throws -> DeviceProfile
}

extension DeviceProfileStore: TabletPairingProfileStoring { }

protocol TabletPairingKeyAuthorizing: Actor {
    func authorizeOwnerApprovedKey(
        password: String,
        publicKey: Data,
        identityURL: URL,
        knownHostsURL: URL,
        expectedUSBContext: DirectUSBRouteContext,
        generation: GenerationID
    ) async throws -> TabletKeyAuthorizationResult
}

extension TabletKeyAuthorizer: TabletPairingKeyAuthorizing { }

protocol TabletPairingWiFiContextProviding: Sendable {
    func currentContext() async throws -> WiFiNetworkContextIdentity
}

extension WiFiNetworkContextProvider: TabletPairingWiFiContextProviding { }

protocol TabletPairingWakeTokenStoring: Actor {
    func storeWakeToken(_ token: Data, profileID: UUID) async throws
    func readWakeToken(profileID: UUID) async throws -> Data
    func deleteWakeToken(profileID: UUID) async throws
}

extension KeychainSecretStore: TabletPairingWakeTokenStoring { }

enum TabletPairingFinalizationApproval: Equatable, Sendable {
    case ownerApproved
}

enum TabletPairingFinalizationStage: Equatable, Sendable {
    case validatingProfile
    case validatingUSB
    case authorizingTabletKey
    case installingTransportWake
    case recordingTabletAuthorization
    case verifyingUSBKey
    case retrievingWakeToken
    case storingWakeToken
    case validatingWakeStatus
    case discoveringTabletWiFi
    case readingMacWiFiContext
    case enablingTabletWiFiSSH
    case verifyingWiFiIdentityAndCapability
    case promotingProfile
}

enum TabletPairingRemoteState: Equatable, Sendable {
    case unchanged
    case keyAuthorizationUncertain
    case keyAuthorized
    case wifiSSHEnablementUncertain
    case wifiSSHEnabled
}

enum TabletPairingWakeTokenCleanup: Equatable, Sendable {
    case notNeeded
    case completed
    case deferred
    case failed
}

enum TabletPairingFinalizationFailure: Equatable, Sendable {
    case busy
    case cancelled
    case invalidProfileState
    case currentProfileMismatch
    case localCredentialsUnavailable
    case usbUnavailable
    case unsafeUSBRoute
    case usbContextChanged
    case keyAuthorizationFailed(TabletKeyAuthorizationFailure)
    case transportWakeInstallFailed(TabletTransportWakeInstallationFailure)
    case profileTransitionFailed
    case requestRejected
    case processUnavailable
    case invalidResponse
    case tabletWiFiUnavailable
    case macWiFiContextUnavailable
    case macWiFiContextChanged
    case wakeTokenStorageFailed
    case wakeTokenReadbackFailed
    case wakeStatusUnavailable
    case wakeStatusAuthenticationFailed
    case profilePromotionFailed
}

struct TabletPairingFinalizationRetry: Equatable, Sendable {
    let stage: TabletPairingFinalizationStage
    let failure: TabletPairingFinalizationFailure
    let remoteState: TabletPairingRemoteState
    let durableProfile: DeviceProfile?
    let wakeTokenCleanup: TabletPairingWakeTokenCleanup
}

enum TabletPairingFinalizationResult: Equatable, Sendable {
    case ready(DeviceProfile)
    case retryRequired(TabletPairingFinalizationRetry)
}

enum TabletPairingAuthorizationRecoveryResult: Equatable, Sendable {
    case authorizationStillRequired(DeviceProfile)
    case recovered(DeviceProfile)
    case retryRequired(TabletPairingFinalizationRetry)
}

protocol TabletPairingFinalizing: Actor {
    func finalizeOwnerApprovedPairing(
        expectedPending: DeviceProfile,
        expectedUSBContext: DirectUSBRouteContext,
        password: String,
        approval: TabletPairingFinalizationApproval,
        generation: GenerationID
    ) async -> TabletPairingFinalizationResult

    func recoverAuthorizedTabletKey(
        expectedPending: DeviceProfile,
        expectedUSBContext: DirectUSBRouteContext,
        generation: GenerationID
    ) async -> TabletPairingAuthorizationRecoveryResult

    func resumeWiFiVerification(
        expectedPendingWiFi: DeviceProfile,
        expectedUSBContext: DirectUSBRouteContext,
        approval: TabletPairingFinalizationApproval,
        generation: GenerationID
    ) async -> TabletPairingFinalizationResult

    func repairAuthorizedUSBWake(
        expectedPendingWiFi: DeviceProfile,
        expectedUSBContext: DirectUSBRouteContext,
        approval: TabletPairingFinalizationApproval,
        generation: GenerationID
    ) async -> TabletPairingFinalizationResult

    func reauthorizeUSBWake(
        expectedProfile: DeviceProfile,
        expectedUSBContext: DirectUSBRouteContext,
        password: String,
        approval: TabletPairingFinalizationApproval,
        generation: GenerationID
    ) async -> TabletPairingFinalizationResult
}

/// Owns the one-way pairing transaction. A successful remote key append can be
/// recovered while the local profile remains pending. Direct USB-C access uses
/// the exact verified cable plus pinned SSH identity; the durable wake bearer is
/// prepared only by the later, separate Wi-Fi setup action.
actor TabletPairingFinalizer {
    private enum PendingWiFiContinuation {
        case repairUSB
        case finishWiFi
    }

    private static let processTimeout: Duration = .seconds(7)

    private let profileStore: any TabletPairingProfileStoring
    private let routeVerifier: any TabletKeyAuthorizationRouteVerifying
    private let keyAuthorizer: any TabletPairingKeyAuthorizing
    private let transportWakeInstaller: any TabletTransportWakeInstalling
    private let wifiContextProvider: any TabletPairingWiFiContextProviding
    private let wakeTokenStore: any TabletPairingWakeTokenStoring
    private let processRunner: any ProcessRunning
    private let now: @Sendable () -> Date

    private var isFinalizing = false

    init(
        profileStore: DeviceProfileStore,
        routeVerifier: DirectUSBRouteVerifier,
        keyAuthorizer: TabletKeyAuthorizer,
        wifiContextProvider: WiFiNetworkContextProvider,
        wakeTokenStore: KeychainSecretStore,
        processRegistry: OwnedProcessRegistry,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.profileStore = profileStore
        self.routeVerifier = routeVerifier
        self.keyAuthorizer = keyAuthorizer
        self.transportWakeInstaller = TabletTransportWakeInstaller(
            routeVerifier: routeVerifier,
            processRunner: processRegistry
        )
        self.wifiContextProvider = wifiContextProvider
        self.wakeTokenStore = wakeTokenStore
        self.processRunner = processRegistry
        self.now = now
    }

    init(
        profileStore: any TabletPairingProfileStoring,
        routeVerifier: any TabletKeyAuthorizationRouteVerifying,
        keyAuthorizer: any TabletPairingKeyAuthorizing,
        transportWakeInstaller: any TabletTransportWakeInstalling,
        wifiContextProvider: any TabletPairingWiFiContextProviding,
        wakeTokenStore: any TabletPairingWakeTokenStoring,
        processRunner: any ProcessRunning,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.profileStore = profileStore
        self.routeVerifier = routeVerifier
        self.keyAuthorizer = keyAuthorizer
        self.transportWakeInstaller = transportWakeInstaller
        self.wifiContextProvider = wifiContextProvider
        self.wakeTokenStore = wakeTokenStore
        self.processRunner = processRunner
        self.now = now
    }

    func finalizeOwnerApprovedPairing(
        expectedPending: DeviceProfile,
        expectedUSBContext: DirectUSBRouteContext,
        password: String,
        approval: TabletPairingFinalizationApproval,
        generation: GenerationID
    ) async -> TabletPairingFinalizationResult {
        guard begin() else {
            return retry(
                stage: .validatingProfile,
                failure: .busy,
                remoteState: .unchanged
            )
        }
        defer { finish() }

        switch approval {
        case .ownerApproved:
            break
        }
        guard Self.hasPairingState(expectedPending, .pendingTabletAuthorization) else {
            return retry(
                stage: .validatingProfile,
                failure: .invalidProfileState,
                remoteState: .unchanged
            )
        }
        guard await currentProfileMatches(expectedPending) else {
            return retry(
                stage: .validatingProfile,
                failure: .currentProfileMismatch,
                remoteState: .unchanged
            )
        }
        if Task.isCancelled {
            return retry(
                stage: .validatingProfile,
                failure: .cancelled,
                remoteState: .unchanged,
                durableProfile: expectedPending
            )
        }
        if let failure = await usbFailure(expected: expectedUSBContext) {
            return retry(
                stage: .validatingUSB,
                failure: failure,
                remoteState: .unchanged,
                durableProfile: expectedPending
            )
        }

        guard case let .ready(material) = await profileStore.loadPendingSSHMaterial(),
              material.hostIdentity.fingerprint == expectedPending.sshFingerprint,
              TabletKeyAuthorizer.normalizedEd25519PublicKey(material.publicKey) != nil else {
            return retry(
                stage: .validatingProfile,
                failure: .localCredentialsUnavailable,
                remoteState: .unchanged,
                durableProfile: expectedPending
            )
        }
        let paths = await profileStore.paths()

        let authorization: TabletKeyAuthorizationResult
        do {
            authorization = try await keyAuthorizer.authorizeOwnerApprovedKey(
                password: password,
                publicKey: material.publicKey,
                identityURL: paths.privateKey,
                knownHostsURL: paths.knownHosts,
                expectedUSBContext: expectedUSBContext,
                generation: generation
            )
        } catch is CancellationError {
            return retry(
                stage: .authorizingTabletKey,
                failure: .cancelled,
                remoteState: .keyAuthorizationUncertain,
                durableProfile: expectedPending
            )
        } catch {
            return retry(
                stage: .authorizingTabletKey,
                failure: .processUnavailable,
                remoteState: .keyAuthorizationUncertain,
                durableProfile: expectedPending
            )
        }

        switch authorization {
        case .authorized:
            break
        case let .failed(failure):
            return retry(
                stage: .authorizingTabletKey,
                failure: .keyAuthorizationFailed(failure),
                remoteState: Self.remoteState(after: failure),
                durableProfile: expectedPending
            )
        }
        let usbCapability: PassiveRouteCapability
        do {
            usbCapability = try await transportWakeInstaller.installOrUpgrade(
                identityURL: paths.privateKey,
                knownHostsURL: paths.knownHosts,
                expectedUSBContext: expectedUSBContext,
                generation: generation
            )
        } catch is CancellationError {
            return retry(
                stage: .installingTransportWake,
                failure: .cancelled,
                remoteState: .keyAuthorized,
                durableProfile: expectedPending
            )
        } catch let failure as TabletTransportWakeInstallationFailure {
            return retry(
                stage: .installingTransportWake,
                failure: .transportWakeInstallFailed(failure),
                remoteState: .keyAuthorized,
                durableProfile: expectedPending
            )
        } catch {
            return retry(
                stage: .installingTransportWake,
                failure: .processUnavailable,
                remoteState: .keyAuthorized,
                durableProfile: expectedPending
            )
        }
        if let failure = await usbFailure(expected: expectedUSBContext) {
            return retry(
                stage: .validatingUSB,
                failure: failure,
                remoteState: .keyAuthorized,
                durableProfile: expectedPending
            )
        }

        // USB-C wake is authorized by the exact verified cable and does not
        // depend on a durable bearer. The bearer remains a separate Wi-Fi
        // setup concern and is stored only when the owner chooses that step.
        let verifiedUSBCapability = usbCapability.verified(at: now())
        let intendedPendingWiFi: DeviceProfile
        do {
            intendedPendingWiFi = try DeviceProfile.pendingWiFiVerification(
                from: expectedPending,
                authenticatedUSBCapability: verifiedUSBCapability
            )
        } catch {
            return retry(
                stage: .recordingTabletAuthorization,
                failure: .profileTransitionFailed,
                remoteState: .keyAuthorized,
                durableProfile: expectedPending
            )
        }

        let pendingWiFi: DeviceProfile
        do {
            pendingWiFi = try await profileStore.markTabletAuthorized(
                expectedPending: expectedPending,
                authenticatedUSBCapability: verifiedUSBCapability
            )
        } catch {
            let durableProfile = await currentProfile()
            guard durableProfile == intendedPendingWiFi else {
                return retry(
                    stage: .recordingTabletAuthorization,
                    failure: .profileTransitionFailed,
                    remoteState: .keyAuthorized,
                    durableProfile: durableProfile
                )
            }
            pendingWiFi = intendedPendingWiFi
        }

        return .ready(pendingWiFi)
    }

    /// Repairs the narrow crash window between a successful remote key append
    /// and the local authorization checkpoint. It is key-only and read-only on
    /// the tablet; it never asks for or attempts password authentication.
    func recoverAuthorizedTabletKey(
        expectedPending: DeviceProfile,
        expectedUSBContext: DirectUSBRouteContext,
        generation: GenerationID
    ) async -> TabletPairingAuthorizationRecoveryResult {
        guard begin() else {
            return .retryRequired(retryRecord(
                stage: .validatingProfile,
                failure: .busy,
                remoteState: .unchanged,
                durableProfile: expectedPending
            ))
        }
        defer { finish() }

        guard Self.hasPairingState(expectedPending, .pendingTabletAuthorization) else {
            return .retryRequired(retryRecord(
                stage: .validatingProfile,
                failure: .invalidProfileState,
                remoteState: .unchanged
            ))
        }
        guard await currentProfileMatches(expectedPending) else {
            return .retryRequired(retryRecord(
                stage: .validatingProfile,
                failure: .currentProfileMismatch,
                remoteState: .unchanged
            ))
        }
        if Task.isCancelled {
            return .retryRequired(retryRecord(
                stage: .verifyingUSBKey,
                failure: .cancelled,
                remoteState: .unchanged,
                durableProfile: expectedPending
            ))
        }
        if let failure = await usbFailure(expected: expectedUSBContext) {
            return .retryRequired(retryRecord(
                stage: .validatingUSB,
                failure: failure,
                remoteState: .unchanged,
                durableProfile: expectedPending
            ))
        }
        guard case let .ready(material) = await profileStore.loadPendingSSHMaterial(),
              material.hostIdentity.fingerprint == expectedPending.sshFingerprint else {
            return .retryRequired(retryRecord(
                stage: .validatingProfile,
                failure: .localCredentialsUnavailable,
                remoteState: .unchanged,
                durableProfile: expectedPending
            ))
        }

        let paths = await profileStore.paths()
        let usbRoute: SSHRoute
        do {
            usbRoute = try Self.usbRoute(paths: paths, context: expectedUSBContext)
        } catch {
            return .retryRequired(retryRecord(
                stage: .validatingUSB,
                failure: .unsafeUSBRoute,
                remoteState: .unchanged,
                durableProfile: expectedPending
            ))
        }

        let proof: PassiveRouteProbeResult
        do {
            let execution = try await processRunner.run(
                usbRoute.authenticationProbeRequest(generation: generation),
                timeout: Self.processTimeout
            )
            proof = PassiveRouteProbe.classify(execution)
        } catch is CancellationError {
            return .retryRequired(retryRecord(
                stage: .verifyingUSBKey,
                failure: .cancelled,
                remoteState: .unchanged,
                durableProfile: expectedPending
            ))
        } catch {
            return .retryRequired(retryRecord(
                stage: .verifyingUSBKey,
                failure: .processUnavailable,
                remoteState: .unchanged,
                durableProfile: expectedPending
            ))
        }

        // A failed key-only child is conclusive only while it still refers to
        // the exact direct USB device context checked before the probe. A
        // disconnect or re-enumeration must reacquire USB and retry without
        // making password authorization eligible again.
        if let failure = await usbFailure(expected: expectedUSBContext) {
            return .retryRequired(retryRecord(
                stage: .validatingUSB,
                failure: failure,
                remoteState: .unchanged,
                durableProfile: expectedPending
            ))
        }

        if proof.state == .identityRejected,
           proof.detail == .authenticationRejected {
            return .authorizationStillRequired(expectedPending)
        }
        guard proof.identityAuthenticated,
              proof.state == .authenticated || proof.state == .prerequisiteMismatch else {
            return .retryRequired(retryRecord(
                stage: .verifyingUSBKey,
                failure: .invalidResponse,
                remoteState: .unchanged,
                durableProfile: expectedPending
            ))
        }
        let capability: PassiveRouteCapability
        if proof.state == .authenticated,
           let currentCapability = proof.capability,
           currentCapability.isCurrent,
           currentCapability.transportOperational {
            // Recovery is entered after an interrupted owner operation. If the
            // authenticated probe already proves the complete current tablet
            // prerequisite set, do not run the persistent installer again.
            capability = currentCapability
        } else {
            do {
                capability = try await transportWakeInstaller.installOrUpgrade(
                    identityURL: paths.privateKey,
                    knownHostsURL: paths.knownHosts,
                    expectedUSBContext: expectedUSBContext,
                    generation: generation
                )
            } catch is CancellationError {
                return .retryRequired(retryRecord(
                    stage: .installingTransportWake,
                    failure: .cancelled,
                    remoteState: .keyAuthorized,
                    durableProfile: expectedPending
                ))
            } catch let failure as TabletTransportWakeInstallationFailure {
                return .retryRequired(retryRecord(
                    stage: .installingTransportWake,
                    failure: .transportWakeInstallFailed(failure),
                    remoteState: .keyAuthorized,
                    durableProfile: expectedPending
                ))
            } catch {
                return .retryRequired(retryRecord(
                    stage: .installingTransportWake,
                    failure: .processUnavailable,
                    remoteState: .keyAuthorized,
                    durableProfile: expectedPending
                ))
            }
        }
        if let failure = await usbFailure(expected: expectedUSBContext) {
            return .retryRequired(retryRecord(
                stage: .validatingUSB,
                failure: failure,
                remoteState: .keyAuthorizationUncertain,
                durableProfile: expectedPending
            ))
        }

        let verifiedUSBCapability = capability.verified(at: now())
        let intendedPendingWiFi: DeviceProfile
        do {
            intendedPendingWiFi = try DeviceProfile.pendingWiFiVerification(
                from: expectedPending,
                authenticatedUSBCapability: verifiedUSBCapability
            )
        } catch {
            return .retryRequired(retryRecord(
                stage: .recordingTabletAuthorization,
                failure: .profileTransitionFailed,
                remoteState: .keyAuthorized,
                durableProfile: expectedPending
            ))
        }

        let recovered: DeviceProfile
        do {
            recovered = try await profileStore.markTabletAuthorized(
                expectedPending: expectedPending,
                authenticatedUSBCapability: verifiedUSBCapability
            )
        } catch {
            let durableProfile = await currentProfile()
            if durableProfile == intendedPendingWiFi {
                recovered = intendedPendingWiFi
            } else {
                return .retryRequired(retryRecord(
                    stage: .recordingTabletAuthorization,
                    failure: .profileTransitionFailed,
                    remoteState: .keyAuthorized,
                    durableProfile: durableProfile
                ))
            }
        }
        return .recovered(recovered)
    }

    func resumeWiFiVerification(
        expectedPendingWiFi: DeviceProfile,
        expectedUSBContext: DirectUSBRouteContext,
        approval: TabletPairingFinalizationApproval,
        generation: GenerationID
    ) async -> TabletPairingFinalizationResult {
        await resumePendingWiFiProfile(
            expectedPendingWiFi: expectedPendingWiFi,
            expectedUSBContext: expectedUSBContext,
            approval: approval,
            generation: generation,
            continuation: .finishWiFi
        )
    }

    func repairAuthorizedUSBWake(
        expectedPendingWiFi: DeviceProfile,
        expectedUSBContext: DirectUSBRouteContext,
        approval: TabletPairingFinalizationApproval,
        generation: GenerationID
    ) async -> TabletPairingFinalizationResult {
        await resumePendingWiFiProfile(
            expectedPendingWiFi: expectedPendingWiFi,
            expectedUSBContext: expectedUSBContext,
            approval: approval,
            generation: generation,
            continuation: .repairUSB
        )
    }

    func reauthorizeUSBWake(
        expectedProfile: DeviceProfile,
        expectedUSBContext: DirectUSBRouteContext,
        password: String,
        approval: TabletPairingFinalizationApproval,
        generation: GenerationID
    ) async -> TabletPairingFinalizationResult {
        guard begin() else {
            return retry(
                stage: .validatingProfile,
                failure: .busy,
                remoteState: .keyAuthorized,
                durableProfile: expectedProfile
            )
        }
        defer { finish() }

        switch approval {
        case .ownerApproved:
            break
        }
        let validProfileState = expectedProfile.pairingState == .pendingWiFiVerification ||
            expectedProfile.pairingState == .ready
        guard validProfileState,
              await currentProfileMatches(expectedProfile) else {
            return retry(
                stage: .validatingProfile,
                failure: .currentProfileMismatch,
                remoteState: .keyAuthorized,
                durableProfile: await currentProfile()
            )
        }
        if let failure = await usbFailure(expected: expectedUSBContext) {
            return retry(
                stage: .validatingUSB,
                failure: failure,
                remoteState: .keyAuthorized,
                durableProfile: expectedProfile
            )
        }
        guard case let .ready(material) = await profileStore.loadPendingSSHMaterial(),
              material.hostIdentity.fingerprint == expectedProfile.sshFingerprint,
              TabletKeyAuthorizer.normalizedEd25519PublicKey(material.publicKey) != nil else {
            return retry(
                stage: .validatingProfile,
                failure: .localCredentialsUnavailable,
                remoteState: .keyAuthorized,
                durableProfile: expectedProfile
            )
        }
        let paths = await profileStore.paths()
        let authorization: TabletKeyAuthorizationResult
        do {
            authorization = try await keyAuthorizer.authorizeOwnerApprovedKey(
                password: password,
                publicKey: material.publicKey,
                identityURL: paths.privateKey,
                knownHostsURL: paths.knownHosts,
                expectedUSBContext: expectedUSBContext,
                generation: generation
            )
        } catch is CancellationError {
            return retry(
                stage: .authorizingTabletKey,
                failure: .cancelled,
                remoteState: .keyAuthorizationUncertain,
                durableProfile: expectedProfile
            )
        } catch {
            return retry(
                stage: .authorizingTabletKey,
                failure: .processUnavailable,
                remoteState: .keyAuthorizationUncertain,
                durableProfile: expectedProfile
            )
        }
        if case let .failed(failure) = authorization {
            return retry(
                stage: .authorizingTabletKey,
                failure: .keyAuthorizationFailed(failure),
                remoteState: Self.remoteState(after: failure),
                durableProfile: expectedProfile
            )
        }
        return await continuePendingWiFiProfile(
            expectedPendingWiFi: expectedProfile,
            expectedUSBContext: expectedUSBContext,
            approval: approval,
            generation: generation,
            continuation: .repairUSB
        )
    }

    private func resumePendingWiFiProfile(
        expectedPendingWiFi: DeviceProfile,
        expectedUSBContext: DirectUSBRouteContext,
        approval: TabletPairingFinalizationApproval,
        generation: GenerationID,
        continuation: PendingWiFiContinuation
    ) async -> TabletPairingFinalizationResult {
        guard begin() else {
            return retry(
                stage: .validatingProfile,
                failure: .busy,
                remoteState: .keyAuthorized,
                durableProfile: expectedPendingWiFi
            )
        }
        defer { finish() }

        return await continuePendingWiFiProfile(
            expectedPendingWiFi: expectedPendingWiFi,
            expectedUSBContext: expectedUSBContext,
            approval: approval,
            generation: generation,
            continuation: continuation
        )
    }

    private func continuePendingWiFiProfile(
        expectedPendingWiFi: DeviceProfile,
        expectedUSBContext: DirectUSBRouteContext,
        approval: TabletPairingFinalizationApproval,
        generation: GenerationID,
        continuation: PendingWiFiContinuation
    ) async -> TabletPairingFinalizationResult {
        switch approval {
        case .ownerApproved:
            break
        }
        let validProfileState = switch continuation {
        case .repairUSB:
            expectedPendingWiFi.pairingState == .pendingWiFiVerification ||
                expectedPendingWiFi.pairingState == .ready
        case .finishWiFi:
            expectedPendingWiFi.pairingState == .pendingWiFiVerification
        }
        guard validProfileState else {
            return retry(
                stage: .validatingProfile,
                failure: .invalidProfileState,
                remoteState: .keyAuthorized
            )
        }
        guard await currentProfileMatches(expectedPendingWiFi) else {
            return retry(
                stage: .validatingProfile,
                failure: .currentProfileMismatch,
                remoteState: .keyAuthorized
            )
        }
        if Task.isCancelled {
            return retry(
                stage: .validatingProfile,
                failure: .cancelled,
                remoteState: .keyAuthorized,
                durableProfile: expectedPendingWiFi
            )
        }
        if let failure = await usbFailure(expected: expectedUSBContext) {
            return retry(
                stage: .validatingUSB,
                failure: failure,
                remoteState: .keyAuthorized,
                durableProfile: expectedPendingWiFi
            )
        }

        guard case let .ready(material) = await profileStore.loadPendingSSHMaterial(),
              material.hostIdentity.fingerprint == expectedPendingWiFi.sshFingerprint else {
            return retry(
                stage: .validatingProfile,
                failure: .localCredentialsUnavailable,
                remoteState: .keyAuthorized,
                durableProfile: expectedPendingWiFi
            )
        }
        let paths = await profileStore.paths()
        let usbRoute: SSHRoute
        do {
            usbRoute = try Self.usbRoute(paths: paths, context: expectedUSBContext)
        } catch {
            return retry(
                stage: .validatingUSB,
                failure: .unsafeUSBRoute,
                remoteState: .keyAuthorized,
                durableProfile: expectedPendingWiFi
            )
        }

        let usbCapability: PassiveRouteCapability
        do {
            let execution = try await processRunner.run(
                usbRoute.authenticationProbeRequest(generation: generation),
                timeout: Self.processTimeout
            )
            let proof = PassiveRouteProbe.classify(execution)
            guard proof.identityAuthenticated,
                  proof.state == .authenticated ||
                    proof.state == .prerequisiteMismatch else {
                if let failure = await usbFailure(expected: expectedUSBContext) {
                    return retry(
                        stage: .validatingUSB,
                        failure: failure,
                        remoteState: .keyAuthorized,
                        durableProfile: expectedPendingWiFi
                    )
                }
                let failure: TabletPairingFinalizationFailure =
                    proof.state == .identityRejected
                    ? .keyAuthorizationFailed(
                        .keyVerificationFailed(proof.detail)
                    )
                    : .invalidResponse
                return retry(
                    stage: .verifyingUSBKey,
                    failure: failure,
                    remoteState: .keyAuthorized,
                    durableProfile: expectedPendingWiFi
                )
            }
            // Repair USB-C is an explicit owner action. Always redeploy the
            // bundled helper on that path even when the older helper reports
            // the same capability version: older builds can satisfy the
            // capability probe without supporting direct-cable token recovery.
            if case .finishWiFi = continuation,
               proof.state == .authenticated,
               let capability = proof.capability,
               capability.isCurrent,
               capability.transportOperational {
                usbCapability = capability
            } else {
                do {
                    let repairedCapability = try await transportWakeInstaller
                        .installOrUpgrade(
                            identityURL: paths.privateKey,
                            knownHostsURL: paths.knownHosts,
                            expectedUSBContext: expectedUSBContext,
                            generation: generation
                        )
                    guard repairedCapability.isCurrent,
                          repairedCapability.transportOperational else {
                        return retry(
                            stage: .installingTransportWake,
                            failure: .invalidResponse,
                            remoteState: .keyAuthorized,
                            durableProfile: expectedPendingWiFi
                        )
                    }
                    usbCapability = repairedCapability
                } catch is CancellationError {
                    return retry(
                        stage: .installingTransportWake,
                        failure: .cancelled,
                        remoteState: .keyAuthorized,
                        durableProfile: expectedPendingWiFi
                    )
                } catch let failure as TabletTransportWakeInstallationFailure {
                    return retry(
                        stage: .installingTransportWake,
                        failure: .transportWakeInstallFailed(failure),
                        remoteState: .keyAuthorized,
                        durableProfile: expectedPendingWiFi
                    )
                } catch {
                    return retry(
                        stage: .installingTransportWake,
                        failure: .processUnavailable,
                        remoteState: .keyAuthorized,
                        durableProfile: expectedPendingWiFi
                    )
                }
            }
        } catch is CancellationError {
            return retry(
                stage: .verifyingUSBKey,
                failure: .cancelled,
                remoteState: .keyAuthorized,
                durableProfile: expectedPendingWiFi
            )
        } catch {
            return retry(
                stage: .verifyingUSBKey,
                failure: .processUnavailable,
                remoteState: .keyAuthorized,
                durableProfile: expectedPendingWiFi
            )
        }
        if let failure = await usbFailure(expected: expectedUSBContext) {
            return retry(
                stage: .validatingUSB,
                failure: failure,
                remoteState: .keyAuthorized,
                durableProfile: expectedPendingWiFi
            )
        }

        let refreshedCapability = usbCapability.verified(at: now())
        let intendedProfile: DeviceProfile
        do {
            intendedProfile = switch expectedPendingWiFi.pairingState {
            case .pendingWiFiVerification:
                try expectedPendingWiFi.refreshingPendingWiFiVerification(
                    with: refreshedCapability
                )
            case .ready:
                try expectedPendingWiFi.refreshingLastVerified(
                    with: refreshedCapability
                )
            case .pendingTabletAuthorization:
                throw DeviceProfileValidationError.inconsistentPairingState
            }
        } catch {
            return retry(
                stage: .recordingTabletAuthorization,
                failure: .profileTransitionFailed,
                remoteState: .keyAuthorized,
                durableProfile: expectedPendingWiFi
            )
        }

        let refreshedProfile: DeviceProfile
        do {
            refreshedProfile = switch expectedPendingWiFi.pairingState {
            case .pendingWiFiVerification:
                try await profileStore.refreshPendingWiFiVerification(
                    expected: expectedPendingWiFi,
                    capability: refreshedCapability
                )
            case .ready:
                try await profileStore.refreshLastVerified(
                    expectedReady: expectedPendingWiFi,
                    capability: refreshedCapability
                )
            case .pendingTabletAuthorization:
                throw DeviceProfileStoreError.invalidProfile
            }
        } catch {
            let durableProfile = await currentProfile()
            guard durableProfile == intendedProfile else {
                return retry(
                    stage: .recordingTabletAuthorization,
                    failure: .profileTransitionFailed,
                    remoteState: .keyAuthorized,
                    durableProfile: durableProfile
                )
            }
            refreshedProfile = intendedProfile
        }

        switch continuation {
        case .repairUSB:
            return .ready(refreshedProfile)
        case .finishWiFi:
            return await finishWiFiPairing(
                expectedPendingWiFi: refreshedProfile,
                expectedUSBContext: expectedUSBContext,
                usbCapability: usbCapability,
                generation: generation
            )
        }
    }

    private func finishWiFiPairing(
        expectedPendingWiFi: DeviceProfile,
        expectedUSBContext: DirectUSBRouteContext,
        usbCapability: PassiveRouteCapability,
        generation: GenerationID
    ) async -> TabletPairingFinalizationResult {
        guard Self.hasPairingState(expectedPendingWiFi, .pendingWiFiVerification),
              await currentProfileMatches(expectedPendingWiFi) else {
            return retry(
                stage: .validatingProfile,
                failure: .currentProfileMismatch,
                remoteState: .keyAuthorized
            )
        }
        if Task.isCancelled {
            return retry(
                stage: .discoveringTabletWiFi,
                failure: .cancelled,
                remoteState: .keyAuthorized,
                durableProfile: expectedPendingWiFi
            )
        }

        let paths = await profileStore.paths()
        let usbRoute: SSHRoute
        do {
            usbRoute = try Self.usbRoute(paths: paths, context: expectedUSBContext)
        } catch {
            return retry(
                stage: .validatingUSB,
                failure: .unsafeUSBRoute,
                remoteState: .keyAuthorized,
                durableProfile: expectedPendingWiFi
            )
        }

        if let retry = await prepareUSBWakeToken(
            profile: expectedPendingWiFi,
            usbRoute: usbRoute,
            expectedUSBContext: expectedUSBContext,
            generation: generation
        ) {
            return .retryRequired(retry)
        }

        let result = await finishWiFiPairingAfterWakeToken(
            expectedPendingWiFi: expectedPendingWiFi,
            expectedUSBContext: expectedUSBContext,
            usbCapability: usbCapability,
            usbRoute: usbRoute,
            paths: paths,
            generation: generation
        )
        return await reconcileOwnedWakeTokenResult(
            expectedProfile: expectedPendingWiFi,
            result: result
        )
    }

    private func finishWiFiPairingAfterWakeToken(
        expectedPendingWiFi: DeviceProfile,
        expectedUSBContext: DirectUSBRouteContext,
        usbCapability: PassiveRouteCapability,
        usbRoute: SSHRoute,
        paths: DeviceProfilePaths,
        generation: GenerationID
    ) async -> TabletPairingFinalizationResult {
        if Task.isCancelled {
            return retry(
                stage: .discoveringTabletWiFi,
                failure: .cancelled,
                remoteState: .keyAuthorized,
                durableProfile: expectedPendingWiFi
            )
        }
        let discovery: TabletWiFiDiscovery
        do {
            let request = try TabletWiFiPairingProbe.discoveryRequest(
                usbRoute: usbRoute,
                generation: generation
            )
            let execution = try await processRunner.run(
                request,
                timeout: Self.processTimeout
            )
            discovery = try TabletWiFiPairingProbe.parseDiscovery(execution)
        } catch is CancellationError {
            return retry(
                stage: .discoveringTabletWiFi,
                failure: .cancelled,
                remoteState: .keyAuthorized,
                durableProfile: expectedPendingWiFi
            )
        } catch let error as TabletWiFiPairingProbeError {
            return retry(
                stage: .discoveringTabletWiFi,
                failure: Self.probeFailure(error),
                remoteState: .keyAuthorized,
                durableProfile: expectedPendingWiFi
            )
        } catch {
            return retry(
                stage: .discoveringTabletWiFi,
                failure: .processUnavailable,
                remoteState: .keyAuthorized,
                durableProfile: expectedPendingWiFi
            )
        }
        guard discovery.isReady, let wifiHost = discovery.globalIPv4Host else {
            return retry(
                stage: .discoveringTabletWiFi,
                failure: .tabletWiFiUnavailable,
                remoteState: .keyAuthorized,
                durableProfile: expectedPendingWiFi
            )
        }

        let pairedMacContext: WiFiNetworkContextIdentity
        do {
            pairedMacContext = try await wifiContextProvider.currentContext()
        } catch is CancellationError {
            return retry(
                stage: .readingMacWiFiContext,
                failure: .cancelled,
                remoteState: .keyAuthorized,
                durableProfile: expectedPendingWiFi
            )
        } catch {
            return retry(
                stage: .readingMacWiFiContext,
                failure: .macWiFiContextUnavailable,
                remoteState: .keyAuthorized,
                durableProfile: expectedPendingWiFi
            )
        }
        if let failure = await usbFailure(expected: expectedUSBContext) {
            return retry(
                stage: .validatingUSB,
                failure: failure,
                remoteState: .keyAuthorized,
                durableProfile: expectedPendingWiFi
            )
        }
        guard await currentProfileMatches(expectedPendingWiFi) else {
            return retry(
                stage: .validatingProfile,
                failure: .currentProfileMismatch,
                remoteState: .keyAuthorized
            )
        }

        let enableExecution: ProcessExecutionResult
        do {
            let request = try TabletWiFiPairingProbe.enableRequest(
                usbRoute: usbRoute,
                generation: generation,
                approval: .ownerApproved
            )
            enableExecution = try await processRunner.run(
                request,
                timeout: Self.processTimeout
            )
        } catch is CancellationError {
            return retry(
                stage: .enablingTabletWiFiSSH,
                failure: .cancelled,
                remoteState: .wifiSSHEnablementUncertain,
                durableProfile: expectedPendingWiFi
            )
        } catch let error as TabletWiFiPairingProbeError {
            return retry(
                stage: .enablingTabletWiFiSSH,
                failure: Self.probeFailure(error),
                remoteState: .keyAuthorized,
                durableProfile: expectedPendingWiFi
            )
        } catch {
            return retry(
                stage: .enablingTabletWiFiSSH,
                failure: .processUnavailable,
                remoteState: .wifiSSHEnablementUncertain,
                durableProfile: expectedPendingWiFi
            )
        }
        do {
            _ = try TabletWiFiPairingProbe.parseEnableVerification(enableExecution)
        } catch {
            return retry(
                stage: .enablingTabletWiFiSSH,
                failure: .invalidResponse,
                remoteState: .wifiSSHEnablementUncertain,
                durableProfile: expectedPendingWiFi
            )
        }

        let preProbeMacContext: WiFiNetworkContextIdentity
        do {
            preProbeMacContext = try await wifiContextProvider.currentContext()
        } catch is CancellationError {
            return retry(
                stage: .readingMacWiFiContext,
                failure: .cancelled,
                remoteState: .wifiSSHEnabled,
                durableProfile: expectedPendingWiFi
            )
        } catch {
            return retry(
                stage: .readingMacWiFiContext,
                failure: .macWiFiContextUnavailable,
                remoteState: .wifiSSHEnabled,
                durableProfile: expectedPendingWiFi
            )
        }
        guard preProbeMacContext == pairedMacContext else {
            return retry(
                stage: .readingMacWiFiContext,
                failure: .macWiFiContextChanged,
                remoteState: .wifiSSHEnabled,
                durableProfile: expectedPendingWiFi
            )
        }

        let wifiCapability: PassiveRouteCapability
        do {
            let wifiRoute = try SSHRoute(
                kind: .wifi,
                host: wifiHost,
                identityURL: paths.privateKey,
                knownHostsURL: paths.knownHosts,
                boundInterface: preProbeMacContext.interfaceName
            )
            let request = try TabletWiFiPairingProbe.verificationRequest(
                wifiRoute: wifiRoute,
                generation: generation
            )
            let execution = try await processRunner.run(
                request,
                timeout: Self.processTimeout
            )
            wifiCapability = try TabletWiFiPairingProbe.parseWiFiVerification(
                execution,
                matching: usbCapability
            )
        } catch is CancellationError {
            return retry(
                stage: .verifyingWiFiIdentityAndCapability,
                failure: .cancelled,
                remoteState: .wifiSSHEnabled,
                durableProfile: expectedPendingWiFi
            )
        } catch let error as TabletWiFiPairingProbeError {
            return retry(
                stage: .verifyingWiFiIdentityAndCapability,
                failure: Self.probeFailure(error),
                remoteState: .wifiSSHEnabled,
                durableProfile: expectedPendingWiFi
            )
        } catch {
            return retry(
                stage: .verifyingWiFiIdentityAndCapability,
                failure: .requestRejected,
                remoteState: .wifiSSHEnabled,
                durableProfile: expectedPendingWiFi
            )
        }

        let postProbeMacContext: WiFiNetworkContextIdentity
        do {
            postProbeMacContext = try await wifiContextProvider.currentContext()
        } catch is CancellationError {
            return retry(
                stage: .readingMacWiFiContext,
                failure: .cancelled,
                remoteState: .wifiSSHEnabled,
                durableProfile: expectedPendingWiFi
            )
        } catch {
            return retry(
                stage: .readingMacWiFiContext,
                failure: .macWiFiContextUnavailable,
                remoteState: .wifiSSHEnabled,
                durableProfile: expectedPendingWiFi
            )
        }
        guard postProbeMacContext == pairedMacContext else {
            return retry(
                stage: .readingMacWiFiContext,
                failure: .macWiFiContextChanged,
                remoteState: .wifiSSHEnabled,
                durableProfile: expectedPendingWiFi
            )
        }
        if let failure = await usbFailure(expected: expectedUSBContext) {
            return retry(
                stage: .validatingUSB,
                failure: failure,
                remoteState: .wifiSSHEnabled,
                durableProfile: expectedPendingWiFi
            )
        }

        if Task.isCancelled {
            return retry(
                stage: .promotingProfile,
                failure: .cancelled,
                remoteState: .wifiSSHEnabled,
                durableProfile: expectedPendingWiFi
            )
        }

        let wifi = VerifiedWiFiRoute(
            host: wifiHost,
            contextDigest: pairedMacContext.digest.storageValue
        )
        let verifiedWiFiCapability = wifiCapability.verified(at: now())
        let intendedReady: DeviceProfile
        do {
            intendedReady = try DeviceProfile.ready(
                from: expectedPendingWiFi,
                wifi: wifi,
                capability: verifiedWiFiCapability
            )
        } catch {
            return retry(
                stage: .promotingProfile,
                failure: .profilePromotionFailed,
                remoteState: .wifiSSHEnabled,
                durableProfile: expectedPendingWiFi
            )
        }

        do {
            let ready = try await profileStore.promoteToReady(
                expectedPendingWiFiVerification: expectedPendingWiFi,
                wifi: wifi,
                capability: verifiedWiFiCapability
            )
            return .ready(ready)
        } catch is CancellationError {
            return await resolvePromotionFailure(
                expectedPendingWiFi: expectedPendingWiFi,
                intendedReady: intendedReady,
                failure: .cancelled
            )
        } catch {
            return await resolvePromotionFailure(
                expectedPendingWiFi: expectedPendingWiFi,
                intendedReady: intendedReady,
                failure: .profilePromotionFailed
            )
        }
    }

    private func prepareUSBWakeToken(
        profile: DeviceProfile,
        usbRoute: SSHRoute,
        expectedUSBContext: DirectUSBRouteContext,
        generation: GenerationID
    ) async -> TabletPairingFinalizationRetry? {
        let initialProfile = await currentProfile()
        guard initialProfile == profile else {
            return retryRecord(
                stage: .validatingProfile,
                failure: .currentProfileMismatch,
                remoteState: .keyAuthorized,
                durableProfile: initialProfile
            )
        }
        if let failure = await usbFailure(expected: expectedUSBContext) {
            return retryRecord(
                stage: .validatingUSB,
                failure: failure,
                remoteState: .keyAuthorized,
                durableProfile: profile
            )
        }

        let wakeToken: Data
        do {
            let request = try TabletWiFiPairingProbe.wakeTokenRequest(
                usbRoute: usbRoute,
                generation: generation
            )
            let execution = try await processRunner.run(
                request,
                timeout: Self.processTimeout
            )
            wakeToken = try TabletWiFiPairingProbe.parseWakeToken(execution)
        } catch is CancellationError {
            return retryRecord(
                stage: .retrievingWakeToken,
                failure: .cancelled,
                remoteState: .keyAuthorized,
                durableProfile: profile
            )
        } catch let error as TabletWiFiPairingProbeError {
            return retryRecord(
                stage: .retrievingWakeToken,
                failure: Self.probeFailure(error),
                remoteState: .keyAuthorized,
                durableProfile: profile
            )
        } catch {
            return retryRecord(
                stage: .retrievingWakeToken,
                failure: .processUnavailable,
                remoteState: .keyAuthorized,
                durableProfile: profile
            )
        }

        if Task.isCancelled {
            return retryRecord(
                stage: .storingWakeToken,
                failure: .cancelled,
                remoteState: .keyAuthorized,
                durableProfile: profile
            )
        }

        let previousWakeToken: Data?
        do {
            previousWakeToken = try await wakeTokenStore.readWakeToken(
                profileID: profile.profileID
            )
        } catch KeychainSecretStoreError.notFound {
            previousWakeToken = nil
        } catch is CancellationError {
            return retryRecord(
                stage: .storingWakeToken,
                failure: .cancelled,
                remoteState: .keyAuthorized,
                durableProfile: profile
            )
        } catch {
            return retryRecord(
                stage: .storingWakeToken,
                failure: .wakeTokenReadbackFailed,
                remoteState: .keyAuthorized,
                durableProfile: profile
            )
        }
        if Task.isCancelled {
            return retryRecord(
                stage: .storingWakeToken,
                failure: .cancelled,
                remoteState: .keyAuthorized,
                durableProfile: profile
            )
        }
        do {
            try await wakeTokenStore.storeWakeToken(
                wakeToken,
                profileID: profile.profileID
            )
        } catch is CancellationError {
            return await rollbackWakeTokenRecord(
                profile: profile,
                stage: .storingWakeToken,
                failure: .cancelled,
                remoteState: .keyAuthorized,
                previousWakeToken: previousWakeToken
            )
        } catch {
            return await rollbackWakeTokenRecord(
                profile: profile,
                stage: .storingWakeToken,
                failure: .wakeTokenStorageFailed,
                remoteState: .keyAuthorized,
                previousWakeToken: previousWakeToken
            )
        }

        do {
            let storedToken = try await wakeTokenStore.readWakeToken(
                profileID: profile.profileID
            )
            guard storedToken == wakeToken else {
                return await rollbackWakeTokenRecord(
                    profile: profile,
                    stage: .storingWakeToken,
                    failure: .wakeTokenReadbackFailed,
                    remoteState: .keyAuthorized,
                    previousWakeToken: previousWakeToken
                )
            }
        } catch is CancellationError {
            return await rollbackWakeTokenRecord(
                profile: profile,
                stage: .storingWakeToken,
                failure: .cancelled,
                remoteState: .keyAuthorized,
                previousWakeToken: previousWakeToken
            )
        } catch {
            return await rollbackWakeTokenRecord(
                profile: profile,
                stage: .storingWakeToken,
                failure: .wakeTokenReadbackFailed,
                remoteState: .keyAuthorized,
                previousWakeToken: previousWakeToken
            )
        }

        // wakeTokenRequest proves the token against the loopback-only wake
        // endpoint over the already pinned USB SSH route before returning it.
        // Once Keychain readback matches that proven token, a later cable loss
        // cannot invalidate or roll it back. The same profile ID owns the token
        // across the pending-authorization to USB-authorized transition.
        return await reconcileValidatedWakeTokenOwnership(
            expectedProfile: profile,
            remoteState: .keyAuthorized
        )
    }

    /// Reconcile the profile after wake-token validation without deleting a
    /// token that a concurrent same-profile promotion may already own.
    private func reconcileValidatedWakeTokenOwnership(
        expectedProfile: DeviceProfile,
        remoteState: TabletPairingRemoteState
    ) async -> TabletPairingFinalizationRetry? {
        switch await profileStore.load() {
        case let .ready(current) where current == expectedProfile:
            return nil
        case let .ready(current) where current.profileID != expectedProfile.profileID:
            let cleanup = await deleteWakeToken(profileID: expectedProfile.profileID)
            return retryRecord(
                stage: .validatingProfile,
                failure: .currentProfileMismatch,
                remoteState: remoteState,
                durableProfile: current,
                wakeTokenCleanup: cleanup
            )
        case let .ready(current):
            return retryRecord(
                stage: .validatingProfile,
                failure: .currentProfileMismatch,
                remoteState: remoteState,
                durableProfile: current,
                wakeTokenCleanup: .deferred
            )
        case .missing:
            let cleanup = await deleteWakeToken(profileID: expectedProfile.profileID)
            return retryRecord(
                stage: .validatingProfile,
                failure: .currentProfileMismatch,
                remoteState: remoteState,
                wakeTokenCleanup: cleanup
            )
        case .invalid:
            return retryRecord(
                stage: .validatingProfile,
                failure: .currentProfileMismatch,
                remoteState: remoteState,
                wakeTokenCleanup: .deferred
            )
        }
    }

    /// Every retry after wake-token validation rechecks who owns the token.
    /// Later Wi-Fi awaits cannot leave an orphan if the durable profile was
    /// removed or replaced while finalization was in flight.
    private func reconcileOwnedWakeTokenResult(
        expectedProfile: DeviceProfile,
        result: TabletPairingFinalizationResult
    ) async -> TabletPairingFinalizationResult {
        guard case let .retryRequired(retry) = result,
              retry.wakeTokenCleanup == .notNeeded else {
            return result
        }

        let durableProfile: DeviceProfile?
        let cleanup: TabletPairingWakeTokenCleanup
        switch await profileStore.load() {
        case let .ready(current) where current == expectedProfile:
            return result
        case let .ready(current) where current.profileID != expectedProfile.profileID:
            durableProfile = current
            cleanup = await deleteWakeToken(profileID: expectedProfile.profileID)
        case let .ready(current):
            durableProfile = current
            cleanup = .deferred
        case .missing:
            durableProfile = nil
            cleanup = await deleteWakeToken(profileID: expectedProfile.profileID)
        case .invalid:
            durableProfile = nil
            cleanup = .deferred
        }

        return .retryRequired(retryRecord(
            stage: retry.stage,
            failure: retry.failure,
            remoteState: retry.remoteState,
            durableProfile: durableProfile,
            wakeTokenCleanup: cleanup
        ))
    }

    /// A profile save can report a durability error after its atomic rename
    /// has already published the ready profile. Reconcile the durable state so
    /// a ready or still-usable USB-authorized profile keeps its validated token,
    /// while a missing or replaced profile cannot leave an orphan behind.
    private func resolvePromotionFailure(
        expectedPendingWiFi: DeviceProfile,
        intendedReady: DeviceProfile,
        failure: TabletPairingFinalizationFailure
    ) async -> TabletPairingFinalizationResult {
        switch await profileStore.load() {
        case let .ready(current) where current == intendedReady:
            return .ready(current)
        case let .ready(current) where current == expectedPendingWiFi:
            return retry(
                stage: .promotingProfile,
                failure: failure,
                remoteState: .wifiSSHEnabled,
                durableProfile: current
            )
        case let .ready(current) where current.profileID != expectedPendingWiFi.profileID:
            let cleanup = await deleteWakeToken(profileID: expectedPendingWiFi.profileID)
            return retry(
                stage: .promotingProfile,
                failure: failure,
                remoteState: .wifiSSHEnabled,
                durableProfile: current,
                wakeTokenCleanup: cleanup
            )
        case let .ready(current):
            return retry(
                stage: .promotingProfile,
                failure: failure,
                remoteState: .wifiSSHEnabled,
                durableProfile: current,
                wakeTokenCleanup: .deferred
            )
        case .missing:
            let cleanup = await deleteWakeToken(profileID: expectedPendingWiFi.profileID)
            return retry(
                stage: .promotingProfile,
                failure: failure,
                remoteState: .wifiSSHEnabled,
                wakeTokenCleanup: cleanup
            )
        case .invalid:
            return retry(
                stage: .promotingProfile,
                failure: failure,
                remoteState: .wifiSSHEnabled,
                wakeTokenCleanup: .deferred
            )
        }
    }

    private func rollbackWakeTokenRecord(
        profile: DeviceProfile,
        stage: TabletPairingFinalizationStage,
        failure: TabletPairingFinalizationFailure,
        remoteState: TabletPairingRemoteState,
        previousWakeToken: Data?
    ) async -> TabletPairingFinalizationRetry {
        let cleanup = await restoreWakeToken(
            previousWakeToken,
            profileID: profile.profileID
        )
        return retryRecord(
            stage: stage,
            failure: failure,
            remoteState: remoteState,
            durableProfile: profile,
            wakeTokenCleanup: cleanup
        )
    }

    private func restoreWakeToken(
        _ previousWakeToken: Data?,
        profileID: UUID
    ) async -> TabletPairingWakeTokenCleanup {
        guard let previousWakeToken else {
            return await deleteWakeToken(profileID: profileID)
        }
        do {
            try await wakeTokenStore.storeWakeToken(
                previousWakeToken,
                profileID: profileID
            )
            let restored = try await wakeTokenStore.readWakeToken(
                profileID: profileID
            )
            return restored == previousWakeToken ? .completed : .failed
        } catch {
            return .failed
        }
    }

    private func deleteWakeToken(profileID: UUID) async -> TabletPairingWakeTokenCleanup {
        do {
            try await wakeTokenStore.deleteWakeToken(profileID: profileID)
            return .completed
        } catch {
            return .failed
        }
    }

    private func usbFailure(
        expected: DirectUSBRouteContext
    ) async -> TabletPairingFinalizationFailure? {
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

    private func currentProfileMatches(_ expected: DeviceProfile) async -> Bool {
        await currentProfile() == expected
    }

    private func currentProfile() async -> DeviceProfile? {
        guard case let .ready(current) = await profileStore.load() else { return nil }
        return current
    }

    private func retry(
        stage: TabletPairingFinalizationStage,
        failure: TabletPairingFinalizationFailure,
        remoteState: TabletPairingRemoteState,
        durableProfile: DeviceProfile? = nil,
        wakeTokenCleanup: TabletPairingWakeTokenCleanup = .notNeeded
    ) -> TabletPairingFinalizationResult {
        .retryRequired(retryRecord(
            stage: stage,
            failure: failure,
            remoteState: remoteState,
            durableProfile: durableProfile,
            wakeTokenCleanup: wakeTokenCleanup
        ))
    }

    private func retryRecord(
        stage: TabletPairingFinalizationStage,
        failure: TabletPairingFinalizationFailure,
        remoteState: TabletPairingRemoteState,
        durableProfile: DeviceProfile? = nil,
        wakeTokenCleanup: TabletPairingWakeTokenCleanup = .notNeeded
    ) -> TabletPairingFinalizationRetry {
        TabletPairingFinalizationRetry(
            stage: stage,
            failure: failure,
            remoteState: remoteState,
            durableProfile: durableProfile,
            wakeTokenCleanup: wakeTokenCleanup
        )
    }

    private func begin() -> Bool {
        guard !isFinalizing else { return false }
        isFinalizing = true
        return true
    }

    private func finish() {
        isFinalizing = false
    }

    private static func hasPairingState(
        _ profile: DeviceProfile,
        _ state: DeviceProfile.PairingState
    ) -> Bool {
        guard (try? profile.validated()) == profile else { return false }
        return profile.pairingState == state
    }

    private static func usbRoute(
        paths: DeviceProfilePaths,
        context: DirectUSBRouteContext
    ) throws -> SSHRoute {
        try SSHRoute(
            kind: .usb,
            host: DeviceProfile.requiredHostKeyAlias,
            identityURL: paths.privateKey,
            knownHostsURL: paths.knownHosts,
            boundInterface: context.interfaceName
        )
    }

    private static func remoteState(
        after failure: TabletKeyAuthorizationFailure
    ) -> TabletPairingRemoteState {
        switch failure {
        case .authorizationTimedOut,
             .authorizationRejected,
             .authorizationProtocolFailed,
             .usbUnavailable,
             .unsafeUSBRoute,
             .usbContextChanged,
             .keyVerificationFailed:
            return .keyAuthorizationUncertain
        case .busy,
             .invalidPassword,
             .invalidPublicKey,
             .invalidCredentialPath,
             .scriptUnavailable,
             .openSSHUnavailable:
            return .unchanged
        }
    }

    private static func probeFailure(
        _ error: TabletWiFiPairingProbeError
    ) -> TabletPairingFinalizationFailure {
        switch error {
        case .usbRouteRequired,
             .wifiRouteRequired,
             .boundInterfaceRequired,
             .unsafeWiFiHost:
            return .requestRejected
        case .processFailed:
            return .processUnavailable
        case .truncatedOutput,
             .unexpectedStandardError,
             .malformedOutput,
             .capabilityMismatch:
            return .invalidResponse
        }
    }
}

extension TabletPairingFinalizer: TabletPairingFinalizing { }
