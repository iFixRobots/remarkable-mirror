import Foundation

enum ConnectionShutdownResult: Equatable, Sendable {
    case clean
    case inputRestorationUncertain
    case processFailure

    static func resolve(
        stoppedActiveWork: Bool,
        stoppedOwnedProcesses: Bool,
        hasActiveOwnedProcesses: Bool,
        inputRestorationIsUncertain: Bool
    ) -> Self {
        guard stoppedActiveWork,
              stoppedOwnedProcesses,
              !hasActiveOwnedProcesses else {
            return .processFailure
        }
        return inputRestorationIsUncertain ? .inputRestorationUncertain : .clean
    }
}

protocol LocalPairingPreparing: Actor {
    func prepare() async -> LocalPairingPreparationResult
}

extension LocalPairingPreparer: LocalPairingPreparing { }

actor ConnectionCoordinator {
    private static let initialConnectionRecoveryLimit: TimeInterval = 45
    private static let directCableInitialRetryDelay: Duration = .milliseconds(250)
    private static let filesOpenRecoveryLimit: TimeInterval = 60
    private static let filesReadinessRetryDelay: Duration = .milliseconds(250)

    private struct Operation {
        let id: UUID
        let task: Task<Void, Never>
    }

    private struct FrameOperation {
        let id: UUID
        let generation: GenerationID
        var inputSession: RMM1InputSession?
        var inputMonitorTask: Task<Void, Never>?
        var session: RMM1FrameStreamSession?
        var isStopping: Bool
        let task: Task<Void, Never>
    }

    private struct FilesCapability {
        let id: UUID
        let generation: GenerationID
        let tunnel: FilesSSHTunnel
        let client: RemarkableFilesClient
        let service: FilesPaneService
        let operationOwner: FilesGenerationOperationOwner
        var probeTask: Task<Void, Never>?
        var readinessProbeAttempted: Bool
        var isPreparingProbe: Bool
        var ownerRequestID: UUID?
        var ownerRequestedProbeUntil: TimeInterval?
        var isAttached: Bool
        var isRetiring: Bool
    }

    private struct FilesPaneOwnerRequest {
        let id: UUID
        var generation: GenerationID?
        var deadline: TimeInterval?
    }

    private struct MonitorDelayOperation {
        let id: UUID
        let task: Task<Void, Never>
    }

    private struct PairingFinalizationOperation {
        let id: UUID
        let generation: GenerationID
        let task: Task<Void, Never>
    }

    private enum PairingFinalizationRequest: Sendable {
        case authorize(password: String)
        case checkAuthorization
        case repairUSB
        case reauthorizeUSB(password: String)
        case finishWiFi

        func accepts(_ pairingState: DeviceProfile.PairingState) -> Bool {
            switch self {
            case .authorize, .checkAuthorization:
                pairingState == .pendingTabletAuthorization
            case .repairUSB:
                pairingState == .pendingWiFiVerification || pairingState == .ready
            case .reauthorizeUSB:
                pairingState == .pendingWiFiVerification || pairingState == .ready
            case .finishWiFi:
                pairingState == .pendingWiFiVerification
            }
        }
    }

    private enum PendingAuthorizationNextStep: Sendable {
        case checkAuthorization
        case enterPassword
    }

    private struct PairingFinalizationDisposition: Sendable {
        let remoteState: TabletPairingRemoteState
        let wakeTokenCleanup: TabletPairingWakeTokenCleanup
        let requiresProfileAttention: Bool
        let resumablePendingWiFiProfile: DeviceProfile?
        let pendingAuthorizationNextStep: PendingAuthorizationNextStep?
        let manualEvidence: ConnectionEvidence?

        init(
            remoteState: TabletPairingRemoteState,
            wakeTokenCleanup: TabletPairingWakeTokenCleanup,
            requiresProfileAttention: Bool,
            resumablePendingWiFiProfile: DeviceProfile? = nil,
            pendingAuthorizationNextStep: PendingAuthorizationNextStep? = nil,
            manualEvidence: ConnectionEvidence? = nil
        ) {
            self.remoteState = remoteState
            self.wakeTokenCleanup = wakeTokenCleanup
            self.requiresProfileAttention = requiresProfileAttention
            self.resumablePendingWiFiProfile = resumablePendingWiFiProfile
            self.pendingAuthorizationNextStep = pendingAuthorizationNextStep
            self.manualEvidence = manualEvidence
        }

        static let unchanged = PairingFinalizationDisposition(
            remoteState: .unchanged,
            wakeTokenCleanup: .notNeeded,
            requiresProfileAttention: false
        )

        var remoteMutationMayHaveOccurred: Bool {
            remoteState != .unchanged
        }

        var blocksNormalRecovery: Bool {
            requiresProfileAttention ||
                wakeTokenCleanup == .deferred ||
                wakeTokenCleanup == .failed
        }

        func merging(
            _ other: PairingFinalizationDisposition
        ) -> PairingFinalizationDisposition {
            PairingFinalizationDisposition(
                remoteState: other.remoteState == .unchanged
                    ? remoteState
                    : other.remoteState,
                wakeTokenCleanup: Self.strongerCleanup(
                    wakeTokenCleanup,
                    other.wakeTokenCleanup
                ),
                requiresProfileAttention: requiresProfileAttention ||
                    other.requiresProfileAttention,
                resumablePendingWiFiProfile: Self.mergedResumableProfile(
                    resumablePendingWiFiProfile,
                    other.resumablePendingWiFiProfile
                ),
                pendingAuthorizationNextStep:
                    other.pendingAuthorizationNextStep ??
                    pendingAuthorizationNextStep,
                manualEvidence: other.manualEvidence ?? manualEvidence
            )
        }

        func requiringProfileAttention() -> PairingFinalizationDisposition {
            PairingFinalizationDisposition(
                remoteState: remoteState,
                wakeTokenCleanup: wakeTokenCleanup,
                requiresProfileAttention: true,
                resumablePendingWiFiProfile: resumablePendingWiFiProfile,
                pendingAuthorizationNextStep: pendingAuthorizationNextStep,
                manualEvidence: manualEvidence
            )
        }

        func requiringAuthorizationCheck() -> PairingFinalizationDisposition {
            withPendingAuthorizationNextStep(.checkAuthorization)
        }

        func requiringPassword() -> PairingFinalizationDisposition {
            withPendingAuthorizationNextStep(.enterPassword)
        }

        func withManualEvidence(
            _ evidence: ConnectionEvidence
        ) -> PairingFinalizationDisposition {
            PairingFinalizationDisposition(
                remoteState: remoteState,
                wakeTokenCleanup: wakeTokenCleanup,
                requiresProfileAttention: requiresProfileAttention,
                resumablePendingWiFiProfile: resumablePendingWiFiProfile,
                pendingAuthorizationNextStep: pendingAuthorizationNextStep,
                manualEvidence: evidence
            )
        }

        private func withPendingAuthorizationNextStep(
            _ nextStep: PendingAuthorizationNextStep
        ) -> PairingFinalizationDisposition {
            PairingFinalizationDisposition(
                remoteState: remoteState,
                wakeTokenCleanup: wakeTokenCleanup,
                requiresProfileAttention: requiresProfileAttention,
                resumablePendingWiFiProfile: resumablePendingWiFiProfile,
                pendingAuthorizationNextStep: nextStep,
                manualEvidence: manualEvidence
            )
        }

        private static func mergedResumableProfile(
            _ lhs: DeviceProfile?,
            _ rhs: DeviceProfile?
        ) -> DeviceProfile? {
            switch (lhs, rhs) {
            case let (profile?, nil), let (nil, profile?):
                profile
            case let (lhs?, rhs?) where lhs == rhs:
                lhs
            case (nil, nil), (_?, _?):
                nil
            }
        }

        private static func strongerCleanup(
            _ lhs: TabletPairingWakeTokenCleanup,
            _ rhs: TabletPairingWakeTokenCleanup
        ) -> TabletPairingWakeTokenCleanup {
            let order: [TabletPairingWakeTokenCleanup] = [
                .notNeeded,
                .completed,
                .deferred,
                .failed,
            ]
            let lhsIndex = order.firstIndex(of: lhs) ?? 0
            let rhsIndex = order.firstIndex(of: rhs) ?? 0
            return order[max(lhsIndex, rhsIndex)]
        }
    }

    private enum MonitorActivationResult {
        case activated
        case deferredUntilIdle
        case candidateBindingChanged
        case failed
    }

    private let profileStore: DeviceProfileStore
    private let processRegistry: OwnedProcessRegistry
    private let bannerProbe: SocketSSHBannerProbe
    private let directUSBRouteVerifier: DirectUSBRouteVerifier
    private let pairingPreparer: any LocalPairingPreparing
    private let pairingFinalizer: any TabletPairingFinalizing
    private let keychainSecretStore: KeychainSecretStore
    private let monitorServices: ConnectionMonitorServices
    private let diagnostics: ConnectionDiagnostics
    private let presentFrame: @Sendable (GenerationID, RMM1FrameUpdate) async -> Bool
    private let publishFilesService: @Sendable (
        GenerationID?,
        FilesPaneService?
    ) async -> Void
    private let publishSnapshot: @Sendable (ConnectionSnapshot) async -> Void

    private var lifecycle: RouteGenerationLifecycle?
    private var activeRouteGeneration: GenerationID?
    private var activeRoute: ConnectionRoute?
    private var activeRouteBinding: MonitorRouteBinding?
    private var activeSSHRoute: SSHRoute?
    private var pendingActivationCandidate: MonitorRouteCandidate?
    private var routeTransitionReservation: GenerationID?
    private var frameGeneration: GenerationID?
    private var inputGeneration: GenerationID?
    private var monitorOperation: Operation?
    private var pairingOperation: Operation?
    private var pairingFinalizationOperation: PairingFinalizationOperation?
    private var frameOperation: FrameOperation?
    private var filesCapability: FilesCapability?
    private var filesGeneration: GenerationID?
    private var filesPaneIsOpen = false
    private var filesPaneVisibilityRevision: UInt64 = 0
    private var filesPaneOwnerRequest: FilesPaneOwnerRequest?
    private var filesReadinessRetryOperation: Operation?
    private var pointerInteractionIsActive = false
    private var monitorDelayOperation: MonitorDelayOperation?
    private var manualRouteSessionPolicy = ManualRouteSessionPolicy()
    private var wifiRepairPolicy = WiFiRepairConfirmationPolicy()
    private var usbWakePolicy = USBWakePolicy()
    private var monitorObservationEpoch = MonitorObservationEpoch()
    private var inputRestorationIsUncertain = false
    private var revision: UInt64 = 0
    private var manualStep = ConnectionManualStep.none
    private var manualConnectionSessionEnded = false
    private var manualInitialConnectionDeadline: TimeInterval?
    private var didStart = false
    private var isStoppingActiveWork = false
    private var isShuttingDown = false

    init(
        profileStore: DeviceProfileStore = DeviceProfileStore(),
        processRegistry: OwnedProcessRegistry = OwnedProcessRegistry(),
        bannerProbe: SocketSSHBannerProbe = SocketSSHBannerProbe(),
        keychainSecretStore: KeychainSecretStore = KeychainSecretStore(),
        monitorServices: ConnectionMonitorServices? = nil,
        pairingPreparer: (any LocalPairingPreparing)? = nil,
        pairingFinalizer: (any TabletPairingFinalizing)? = nil,
        presentFrame: @escaping @Sendable (
            GenerationID,
            RMM1FrameUpdate
        ) async -> Bool = { _, _ in false },
        publishFilesService: @escaping @Sendable (
            GenerationID?,
            FilesPaneService?
        ) async -> Void = { _, _ in },
        publishSnapshot: @escaping @Sendable (ConnectionSnapshot) async -> Void
    ) {
        let directUSBRouteVerifier = DirectUSBRouteVerifier(processRegistry: processRegistry)
        let wifiContextProvider = WiFiNetworkContextProvider()
        let productionPairingPreparer = LocalPairingPreparer(
            profileStore: profileStore,
            processRegistry: processRegistry,
            bannerProbe: bannerProbe,
            directUSBRouteVerifier: directUSBRouteVerifier
        )
        let productionPairingFinalizer = TabletPairingFinalizer(
            profileStore: profileStore,
            routeVerifier: directUSBRouteVerifier,
            keyAuthorizer: TabletKeyAuthorizer(
                processRegistry: processRegistry,
                routeVerifier: directUSBRouteVerifier
            ),
            wifiContextProvider: wifiContextProvider,
            wakeTokenStore: keychainSecretStore,
            processRegistry: processRegistry
        )

        self.profileStore = profileStore
        self.processRegistry = processRegistry
        self.bannerProbe = bannerProbe
        self.directUSBRouteVerifier = directUSBRouteVerifier
        self.keychainSecretStore = keychainSecretStore
        self.monitorServices = monitorServices ?? .production(
            directUSBRouteVerifier: directUSBRouteVerifier,
            wifiContextProvider: wifiContextProvider,
            processRegistry: processRegistry
        )
        self.pairingPreparer = pairingPreparer ?? productionPairingPreparer
        self.pairingFinalizer = pairingFinalizer ?? productionPairingFinalizer
        self.diagnostics = ConnectionDiagnostics()
        self.presentFrame = presentFrame
        self.publishFilesService = publishFilesService
        self.publishSnapshot = publishSnapshot
    }

    func start() async {
        guard !didStart, !isShuttingDown else { return }
        didStart = true
        await diagnostics.record(.appStarted)
        await loadProfileAndContinue()
    }

    @discardableResult
    func prepareLocalPairing() async -> Bool {
        guard !isShuttingDown,
              !isStoppingActiveWork,
              pairingFinalizationOperation == nil else {
            return false
        }
        if let pairingOperation {
            await pairingOperation.task.value
            return false
        }

        manualStep = .retrySetup
        let operationID = UUID()
        let task = Task { [self] in
            await runPairingOperation(id: operationID)
            finishPairingOperation(id: operationID)
        }
        pairingOperation = Operation(id: operationID, task: task)
        await task.value
        return true
    }

    @discardableResult
    func cancelLocalPairing() async -> Bool {
        guard !isShuttingDown, !isStoppingActiveWork else { return false }
        manualStep = .cancelSetup
        isStoppingActiveWork = true
        await stopPairingOperation()
        do {
            try await stopPairingFinalizationOperation()
        } catch {
            isStoppingActiveWork = false
            await publishApplication(.profileAttention)
            return true
        }
        isStoppingActiveWork = false
        await loadProfileAndContinue()
        return true
    }

    @discardableResult
    func retryLocalPairing() async -> Bool {
        guard !isShuttingDown, !isStoppingActiveWork else { return false }
        return await prepareLocalPairing()
    }

    @discardableResult
    func authorizeTablet(password: String) -> Bool {
        guard !isShuttingDown,
              !isStoppingActiveWork,
              pairingFinalizationOperation == nil else {
            return false
        }

        manualStep = .authorizeTablet
        return reservePairingFinalizationOperation(
            request: .authorize(password: password)
        )
    }

    @discardableResult
    func checkTabletAuthorization() -> Bool {
        guard !isShuttingDown, !isStoppingActiveWork else { return false }
        manualStep = .checkTabletAuthorization
        return reservePairingFinalizationOperation(request: .checkAuthorization)
    }

    @discardableResult
    func repairUSB() -> Bool {
        guard !isShuttingDown, !isStoppingActiveWork else { return false }
        manualStep = .repairUSB
        return reservePairingFinalizationOperation(request: .repairUSB)
    }

    @discardableResult
    func reauthorizeUSB(password: String) -> Bool {
        guard !isShuttingDown,
              !isStoppingActiveWork,
              pairingFinalizationOperation == nil else {
            return false
        }
        manualStep = .reauthorizeUSB
        return reservePairingFinalizationOperation(
            request: .reauthorizeUSB(password: password)
        )
    }

    @discardableResult
    func finishWiFiPairing() -> Bool {
        guard !isShuttingDown, !isStoppingActiveWork else { return false }
        manualStep = .finishWiFi
        return reservePairingFinalizationOperation(request: .finishWiFi)
    }

    func resetLocalPairing() async {
        guard !isShuttingDown, !isStoppingActiveWork else { return }
        isStoppingActiveWork = true

        do {
            try await stopActiveWork()
            try await keychainSecretStore.deleteAllWakeTokens()
            try await profileStore.resetLocalSetup()
            manualStep = .none
        } catch {
            isStoppingActiveWork = false
            await diagnostics.record(.profileInvalid)
            await publishApplication(.profileAttention)
            return
        }
        isStoppingActiveWork = false
        await diagnostics.record(.profileMissing)
        await publishApplication(.setupRequired)
    }

    @discardableResult
    func connect(target: ManualConnectionTarget) async -> Bool {
        guard !isShuttingDown, !isStoppingActiveWork else { return false }
        let route = target.route
        let connectionDeadline = monitorServices.monotonicNow() +
            Self.initialConnectionRecoveryLimit
        isStoppingActiveWork = true
        do {
            try await stopActiveWork()
        } catch {
            manualInitialConnectionDeadline = nil
            isStoppingActiveWork = false
            await publishApplication(.attention)
            return true
        }
        manualInitialConnectionDeadline = connectionDeadline

        let profileState = await profileStore.load()
        guard !isShuttingDown else {
            manualInitialConnectionDeadline = nil
            isStoppingActiveWork = false
            return false
        }

        switch profileState {
        case let .ready(profile)
            where profile.pairingState == .ready ||
                profile.pairingState == .pendingWiFiVerification:
            let manualWiFi: ManualWiFiConnection?
            switch target {
            case .usb:
                manualWiFi = nil
            case let .wifi(host):
                guard TabletWiFiPairingProbe.isGlobalIPv4Host(host),
                      let context = try? monitorServices.currentWiFiSessionContext() else {
                    manualInitialConnectionDeadline = nil
                    isStoppingActiveWork = false
                    manualStep = .chooseConnection
                    await publishApplication(.offline)
                    return true
                }
                manualWiFi = ManualWiFiConnection(
                    host: host,
                    context: context
                )
            }
            manualStep = switch route {
            case .usb:
                profile.pairingState == .pendingWiFiVerification
                    ? .connectUSBBeforeWiFi
                    : .connectUSB
            case .wifi:
                .connectWiFi
            }
            let started = await beginMonitoring(
                profile: profile,
                requestedRoute: route,
                manualWiFi: manualWiFi
            )
            if !started {
                manualInitialConnectionDeadline = nil
            }
            isStoppingActiveWork = false
            return started
        case .ready, .missing, .invalid:
            manualInitialConnectionDeadline = nil
            isStoppingActiveWork = false
            await loadProfileAndContinue()
            return true
        }
    }

    func diagnosticReport() async -> String {
        await diagnostics.report()
    }

    func sendInput(
        _ event: TabletInputEvent,
        generation: GenerationID
    ) async {
        guard !isShuttingDown,
              activeRouteGeneration == generation,
              routeTransitionReservation != generation,
              inputGeneration == generation,
              let operation = frameOperation,
              operation.generation == generation,
              let session = operation.inputSession else {
            return
        }

        let changesPointerInteraction =
            Self.beginsOrContinuesPointerInteraction(event) ||
            Self.endsPointerInteraction(event)
        if Self.beginsOrContinuesPointerInteraction(event) {
            pointerInteractionIsActive = true
        }
        var clearPointerWhenFinished = Self.endsPointerInteraction(event)
        defer {
            if clearPointerWhenFinished {
                pointerInteractionIsActive = false
            }
        }

        do {
            try await session.send(event)
        } catch is TabletInputCommandRejection {
            // A helper rejection is aligned to this command. The session stays
            // usable for the next pointer or keyboard event.
            clearPointerWhenFinished = changesPointerInteraction
            return
        } catch is CancellationError {
            clearPointerWhenFinished = changesPointerInteraction
            return
        } catch {
            clearPointerWhenFinished = true
            guard activeRouteGeneration == generation,
                  frameOperation?.id == operation.id,
                  let lifecycleAtFailure = lifecycle else {
                return
            }
            frameOperation?.isStopping = true
            reserveManualSessionRetirement(generation: generation)
            frameGeneration = nil
            inputGeneration = nil
            if let route = activeRoute {
                await publish(
                    evidence: .transportReady(route),
                    admission: .generationEvent,
                    generation: generation
                )
            }
            guard isCurrentInputOperation(
                operationID: operation.id,
                generation: generation,
                lifecycle: lifecycleAtFailure
            ) else {
                return
            }
            await lifecycleAtFailure.request(.none)
        }
    }

    func reportFilesConnectionFailure(capabilityID: UUID) async {
        guard let generation = activeRouteGeneration,
              var capability = filesCapability,
              capability.id == capabilityID,
              capability.generation == generation,
              !capability.isRetiring else {
            return
        }

        cancelFilesReadinessRetry()
        capability.probeTask?.cancel()
        capability.isAttached = false
        capability.isRetiring = true
        filesCapability = capability
        filesGeneration = nil
        await publishFilesService(nil, nil)
        await capability.operationOwner.retire()
        await capability.probeTask?.value

        guard activeRouteGeneration == generation,
              filesCapability?.id == capability.id,
              filesCapability?.isRetiring == true,
              !isShuttingDown,
              let route = activeRoute else {
            if filesCapability?.id == capability.id {
                filesCapability = nil
            }
            return
        }
        filesCapability = makeFilesCapability(
            generation: generation,
            tunnel: capability.tunnel,
            client: capability.client,
            allowsOwnerlessInitialProbe: false
        )
        await publish(
            evidence: .transportReady(route),
            admission: .generationEvent,
            generation: generation
        )
    }

    func setFilesPaneOpen(_ isOpen: Bool, revision: UInt64) {
        guard !isShuttingDown,
              revision > filesPaneVisibilityRevision else {
            return
        }
        let wasOpen = filesPaneIsOpen
        filesPaneVisibilityRevision = revision
        filesPaneIsOpen = isOpen
        cancelFilesReadinessRetry()

        guard isOpen else {
            filesPaneOwnerRequest = nil
            if var capability = filesCapability,
               !capability.isRetiring {
                capability.ownerRequestID = nil
                capability.ownerRequestedProbeUntil = nil
                if capability.probeTask == nil, !capability.isAttached {
                    capability.readinessProbeAttempted = true
                }
                filesCapability = capability
            }
            return
        }

        let existingRequestID: UUID?
        if wasOpen,
           let existing = filesPaneOwnerRequest,
           existing.generation == nil ||
            existing.generation == activeRouteGeneration,
           existing.deadline.map({
               monitorServices.monotonicNow() < $0
           }) ?? true {
            existingRequestID = existing.id
        } else {
            existingRequestID = nil
        }
        let request = FilesPaneOwnerRequest(
            id: existingRequestID ?? UUID(),
            generation: activeRouteGeneration,
            deadline: nil
        )
        filesPaneOwnerRequest = request

        guard var capability = filesCapability,
              !capability.isRetiring else {
            return
        }

        guard !capability.isAttached else {
            _ = currentFilesPaneOwnerRequest(for: capability.generation)
            capability.ownerRequestID = nil
            capability.ownerRequestedProbeUntil = nil
            filesCapability = capability
            return
        }

        guard activeRouteGeneration == capability.generation,
              routeTransitionReservation != capability.generation,
              !manualConnectionSessionEnded else {
            capability.ownerRequestID = nil
            capability.ownerRequestedProbeUntil = nil
            filesCapability = capability
            return
        }

        guard let claimedRequest = currentFilesPaneOwnerRequest(
            for: capability.generation
        ), let deadline = claimedRequest.deadline else {
            return
        }
        capability.ownerRequestID = claimedRequest.id
        capability.ownerRequestedProbeUntil = deadline
        if capability.probeTask == nil, !capability.isPreparingProbe {
            capability.readinessProbeAttempted = false
        }
        filesCapability = capability
        startFilesProbeIfNeeded()
    }

    func shutdown() async -> ConnectionShutdownResult {
        isShuttingDown = true
        isStoppingActiveWork = true
        var stoppedActiveWork = true
        do {
            try await stopActiveWork()
        } catch {
            stoppedActiveWork = false
        }

        var stoppedOwnedProcesses = true
        do {
            try await processRegistry.shutdown()
        } catch {
            stoppedOwnedProcesses = false
        }

        let hasActiveOwnedProcesses = !(await processRegistry.activeProcessIDs()).isEmpty
        // The uncertain-restoration result is only reachable after every
        // Mirror-owned host process has been confirmed stopped. The remaining
        // uncertainty is limited to the tablet's physical-input restoration.
        let result = ConnectionShutdownResult.resolve(
            stoppedActiveWork: stoppedActiveWork,
            stoppedOwnedProcesses: stoppedOwnedProcesses,
            hasActiveOwnedProcesses: hasActiveOwnedProcesses,
            inputRestorationIsUncertain: inputRestorationIsUncertain
        )

        await diagnostics.record(result == .clean ? .shutdownComplete : .shutdownFailed)
        return result
    }

    private func loadProfileAndContinue() async {
        switch await profileStore.load() {
        case .missing:
            manualStep = .none
            await diagnostics.record(.profileMissing)
            await publishApplication(.setupRequired)
        case let .invalid(failure):
            _ = failure
            manualStep = .none
            await diagnostics.record(.profileInvalid)
            await publishApplication(.profileAttention)
        case let .ready(profile):
            switch profile.pairingState {
            case .pendingTabletAuthorization:
                manualStep = .checkTabletAuthorization
                await diagnostics.record(.profilePendingApproval)
                await publishApplication(.awaitingTabletAuthorizationCheck)
            case .pendingWiFiVerification:
                manualStep = .connectUSBBeforeWiFi
                await publishApplication(.awaitingWiFiVerification)
            case .ready:
                manualStep = .chooseConnection
                await publishApplication(.readyToConnect)
            }
        }
    }

    private func reservePairingFinalizationOperation(
        request: PairingFinalizationRequest
    ) -> Bool {
        guard !isShuttingDown,
              !isStoppingActiveWork,
              pairingFinalizationOperation == nil else {
            return false
        }

        let operationID = UUID()
        let generation = GenerationID.make()
        let task = Task { [self] in
            let disposition = await runPairingFinalizationOperation(
                id: operationID,
                generation: generation,
                request: request
            )
            await completePairingFinalizationOperation(
                id: operationID,
                generation: generation,
                disposition: disposition
            )
        }
        pairingFinalizationOperation = PairingFinalizationOperation(
            id: operationID,
            generation: generation,
            task: task
        )
        return true
    }

    private func runPairingFinalizationOperation(
        id: UUID,
        generation: GenerationID,
        request: PairingFinalizationRequest
    ) async -> PairingFinalizationDisposition {
        await stopPairingOperation()
        do {
            try await stopMonitorAndLifecycle()
        } catch {
            return PairingFinalizationDisposition(
                remoteState: .unchanged,
                wakeTokenCleanup: .notNeeded,
                requiresProfileAttention: true
            )
        }
        guard canContinuePairingFinalization(id: id, generation: generation) else {
            return .unchanged
        }

        let profile: DeviceProfile
        switch await profileStore.load() {
        case let .ready(current) where request.accepts(current.pairingState):
            profile = current
        case .ready, .missing, .invalid:
            return .unchanged
        }
        guard canContinuePairingFinalization(id: id, generation: generation) else {
            return .unchanged
        }

        let usbContext: DirectUSBRouteContext
        switch await monitorServices.verifyUSB() {
        case let .verified(context):
            usbContext = context
        case .accessoryApprovalRequired:
            await diagnostics.record(.usbAccessoryApprovalRequired)
            return Self.preflightFailureDisposition(
                for: request,
                evidence: .usbAccessoryApprovalRequired
            )
        case .unavailable:
            await diagnostics.record(.usbRouteUnavailable)
            return Self.preflightFailureDisposition(
                for: request,
                evidence: .setupWaitingForUSB
            )
        case .unsafeRoute:
            await diagnostics.record(.usbRouteUnsafe)
            return Self.preflightFailureDisposition(
                for: request,
                evidence: .setupUnsafeUSBRoute
            )
        }
        guard canContinuePairingFinalization(id: id, generation: generation) else {
            return .unchanged
        }

        switch request {
        case let .authorize(password):
            await diagnostics.record(.setupStarted)
            await publishApplication(.setupInProgress)
            guard canContinuePairingFinalization(
                id: id,
                generation: generation
            ) else {
                return .unchanged
            }

            let result = await pairingFinalizer.finalizeOwnerApprovedPairing(
                expectedPending: profile,
                expectedUSBContext: usbContext,
                password: password,
                approval: .ownerApproved,
                generation: generation
            )
            guard canContinuePairingFinalization(
                id: id,
                generation: generation
            ) else {
                return .unchanged
            }

            if case let .retryRequired(retry) = result {
                await diagnostics.recordPairingFailure(retry)
            }
            let disposition = Self.disposition(for: result)
            if case let .retryRequired(retry) = result {
                switch retry.failure {
                case .keyAuthorizationFailed(.invalidPassword),
                     .keyAuthorizationFailed(.busy):
                    return disposition.requiringPassword()
                case .keyAuthorizationFailed(.invalidPublicKey),
                     .keyAuthorizationFailed(.invalidCredentialPath),
                     .keyAuthorizationFailed(.scriptUnavailable),
                     .keyAuthorizationFailed(.openSSHUnavailable),
                     .keyAuthorizationFailed(
                        .keyVerificationFailed(.localCredentialFilesMissing)
                     ),
                     .keyAuthorizationFailed(
                        .keyVerificationFailed(.openSSHUnavailable)
                     ):
                    return disposition.requiringProfileAttention()
                default:
                    break
                }
                if retry.remoteState == .unchanged {
                    switch retry.stage {
                    case .validatingUSB:
                        // The finalizer revalidates the exact USB context before
                        // launching the password child. A failure here proves the
                        // password was never sent and no key could have changed.
                        return disposition.requiringPassword()
                    case .validatingProfile:
                        switch retry.failure {
                        case .busy, .cancelled:
                            return disposition.requiringPassword()
                        default:
                            return disposition.requiringProfileAttention()
                        }
                    default:
                        break
                    }
                }
                // A failed password-authenticated child can stop after the key
                // changed but before proof returned. Require a separate
                // key-only owner action before offering another password.
                return disposition.requiringAuthorizationCheck()
            }
            return disposition

        case .checkAuthorization:
            await diagnostics.record(.setupStarted)
            await publishApplication(.setupInProgress)
            guard canContinuePairingFinalization(
                id: id,
                generation: generation
            ) else {
                return .unchanged
            }

            let result = await pairingFinalizer.recoverAuthorizedTabletKey(
                expectedPending: profile,
                expectedUSBContext: usbContext,
                generation: generation
            )
            guard canContinuePairingFinalization(
                id: id,
                generation: generation
            ) else {
                return .unchanged
            }
            switch result {
            case .authorizationStillRequired:
                return PairingFinalizationDisposition.unchanged
                    .requiringPassword()
            case .recovered:
                return Self.disposition(for: result)
            case let .retryRequired(retry):
                await diagnostics.recordPairingFailure(retry)
                return Self.disposition(for: result)
                    .requiringAuthorizationCheck()
            }

        case .repairUSB:
            await diagnostics.record(.setupStarted)
            await publishApplication(.setupInProgress)
            let result = await pairingFinalizer.repairAuthorizedUSBWake(
                expectedPendingWiFi: profile,
                expectedUSBContext: usbContext,
                approval: .ownerApproved,
                generation: generation
            )
            guard canContinuePairingFinalization(
                id: id,
                generation: generation
            ) else {
                return .unchanged
            }
            if case let .retryRequired(retry) = result {
                await diagnostics.recordPairingFailure(retry)
                return Self.usbRepairDisposition(for: retry)
            }
            return Self.disposition(for: result)

        case let .reauthorizeUSB(password):
            await diagnostics.record(.setupStarted)
            await publishApplication(.setupInProgress)
            let result = await pairingFinalizer.reauthorizeUSBWake(
                expectedProfile: profile,
                expectedUSBContext: usbContext,
                password: password,
                approval: .ownerApproved,
                generation: generation
            )
            guard canContinuePairingFinalization(
                id: id,
                generation: generation
            ) else {
                return .unchanged
            }
            if case let .retryRequired(retry) = result {
                await diagnostics.recordPairingFailure(retry)
                if case .keyAuthorizationFailed(.invalidPassword) = retry.failure {
                    return Self.disposition(for: result).withManualEvidence(
                        .usbRepairRequired(.keyRejected)
                    )
                }
                return Self.usbRepairDisposition(for: retry)
            }
            return Self.disposition(for: result)

        case .finishWiFi:
            await diagnostics.record(.setupStarted)
            await publishApplication(.setupInProgress)
            let result = await pairingFinalizer.resumeWiFiVerification(
                expectedPendingWiFi: profile,
                expectedUSBContext: usbContext,
                approval: .ownerApproved,
                generation: generation
            )
            guard canContinuePairingFinalization(
                id: id,
                generation: generation
            ) else {
                return .unchanged
            }
            if case let .retryRequired(retry) = result {
                await diagnostics.recordPairingFailure(retry)
            }
            return Self.disposition(for: result)
        }
    }

    private static func usbRepairDisposition(
        for retry: TabletPairingFinalizationRetry
    ) -> PairingFinalizationDisposition {
        let disposition = Self.disposition(
            for: TabletPairingFinalizationResult.retryRequired(retry)
        )
        switch retry.failure {
        case .keyAuthorizationFailed(
            .keyVerificationFailed(.authenticationRejected)
        ):
            return disposition.withManualEvidence(
                .usbRepairRequired(.keyRejected)
            )
        case .keyAuthorizationFailed(
            .keyVerificationFailed(.hostKeyRejected)
        ),
        .localCredentialsUnavailable,
        .wakeTokenStorageFailed,
        .wakeTokenReadbackFailed,
        .profileTransitionFailed,
        .currentProfileMismatch,
        .invalidProfileState:
            return disposition.requiringProfileAttention()
        case .keyAuthorizationFailed(.invalidPassword):
            return disposition.withManualEvidence(
                .usbRepairRequired(.keyRejected)
            )
        case .keyAuthorizationFailed:
            return disposition.withManualEvidence(
                .usbRepairRequired(.authorizationUncertain)
            )
        default:
            return disposition.withManualEvidence(
                .usbRepairRequired(.secureTransportUnavailable)
            )
        }
    }

    private func completePairingFinalizationOperation(
        id: UUID,
        generation: GenerationID,
        disposition: PairingFinalizationDisposition
    ) async {
        var retirementFailed = false
        do {
            try await processRegistry.retire(generation: generation)
        } catch {
            retirementFailed = true
        }

        guard isPairingFinalizationOperation(id: id, generation: generation) else {
            return
        }
        if retirementFailed {
            if !Task.isCancelled, !isStoppingActiveWork, !isShuttingDown {
                await reconcilePairingFinalization(
                    operationID: id,
                    generation: generation,
                    disposition: disposition.merging(
                        PairingFinalizationDisposition(
                            remoteState: .unchanged,
                            wakeTokenCleanup: .notNeeded,
                            requiresProfileAttention: true
                        )
                    )
                )
            }
            // Preserve the completed operation and its exact generation so a
            // later cancel, reset, retry, or shutdown can retry retirement.
            return
        }
        guard !Task.isCancelled, !isStoppingActiveWork, !isShuttingDown else {
            pairingFinalizationOperation = nil
            return
        }

        await reconcilePairingFinalization(
            operationID: id,
            generation: generation,
            disposition: disposition
        )
        if isPairingFinalizationOperation(id: id, generation: generation) {
            pairingFinalizationOperation = nil
        }
    }

    private func reconcilePairingFinalization(
        operationID: UUID,
        generation: GenerationID,
        disposition: PairingFinalizationDisposition
    ) async {
        let durableState = await profileStore.load()
        guard canContinuePairingFinalization(
            id: operationID,
            generation: generation
        ) else {
            return
        }

        let resumesPendingWiFiAfterTokenStorageFailure: Bool
        if case let .ready(profile) = durableState {
            resumesPendingWiFiAfterTokenStorageFailure =
                profile.pairingState == .pendingWiFiVerification &&
                profile == disposition.resumablePendingWiFiProfile
        } else {
            resumesPendingWiFiAfterTokenStorageFailure = false
        }

        if disposition.requiresProfileAttention ||
            (disposition.blocksNormalRecovery &&
                !resumesPendingWiFiAfterTokenStorageFailure) {
            await diagnostics.record(.profileInvalid)
            await publishApplication(.profileAttention)
            return
        }

        switch durableState {
        case .missing:
            manualStep = .none
            if disposition.remoteMutationMayHaveOccurred {
                await diagnostics.record(.profileInvalid)
                await publishApplication(.profileAttention)
            } else {
                await diagnostics.record(.profileMissing)
                await publishApplication(.setupRequired)
            }

        case .invalid:
            manualStep = .none
            await diagnostics.record(.profileInvalid)
            await publishApplication(.profileAttention)

        case let .ready(profile):
            switch profile.pairingState {
            case .pendingTabletAuthorization:
                switch disposition.pendingAuthorizationNextStep {
                case .enterPassword:
                    manualStep = .authorizeTablet
                    await diagnostics.record(.profilePendingApproval)
                    if let evidence = disposition.manualEvidence {
                        await publishApplication(evidence)
                    } else {
                        await publishApplication(.awaitingTabletAuthorization)
                    }
                case .checkAuthorization, .none:
                    manualStep = .checkTabletAuthorization
                    await diagnostics.record(.profilePendingApproval)
                    if let evidence = disposition.manualEvidence {
                        await publishApplication(evidence)
                    } else {
                        await publishApplication(.awaitingTabletAuthorizationCheck)
                    }
                }
            case .pendingWiFiVerification:
                if let evidence = disposition.manualEvidence {
                    if case let .usbRepairRequired(reason) = evidence {
                        manualStep = reason == .keyRejected
                            ? .reauthorizeUSB
                            : .repairUSB
                    }
                    await publishApplication(evidence)
                } else {
                    manualStep = manualStep == .finishWiFi
                        ? .finishWiFi
                        : .connectUSBBeforeWiFi
                    await publishApplication(.awaitingWiFiVerification)
                }
            case .ready:
                if let evidence = disposition.manualEvidence {
                    if case let .usbRepairRequired(reason) = evidence {
                        manualStep = reason == .keyRejected
                            ? .reauthorizeUSB
                            : .repairUSB
                    }
                    await publishApplication(evidence)
                } else {
                    manualStep = .chooseConnection
                    await publishApplication(.readyToConnect)
                }
            }
        }
    }

    private func canContinuePairingFinalization(
        id: UUID,
        generation: GenerationID
    ) -> Bool {
        isPairingFinalizationOperation(id: id, generation: generation) &&
            !Task.isCancelled &&
            !isStoppingActiveWork &&
            !isShuttingDown
    }

    private func isPairingFinalizationOperation(
        id: UUID,
        generation: GenerationID
    ) -> Bool {
        pairingFinalizationOperation?.id == id &&
            pairingFinalizationOperation?.generation == generation
    }

    private static func disposition(
        for result: TabletPairingFinalizationResult
    ) -> PairingFinalizationDisposition {
        switch result {
        case let .ready(profile):
            PairingFinalizationDisposition(
                remoteState: profile.pairingState == .ready
                    ? .wifiSSHEnabled
                    : .keyAuthorized,
                wakeTokenCleanup: .notNeeded,
                requiresProfileAttention: false
            )
        case let .retryRequired(retry):
            PairingFinalizationDisposition(
                remoteState: retry.remoteState,
                wakeTokenCleanup: retry.wakeTokenCleanup,
                requiresProfileAttention: false,
                resumablePendingWiFiProfile:
                    Self.resumablePendingWiFiProfile(after: retry)
            )
        }
    }

    private static func disposition(
        for result: TabletPairingAuthorizationRecoveryResult
    ) -> PairingFinalizationDisposition {
        switch result {
        case .authorizationStillRequired:
            .unchanged
        case .recovered:
            PairingFinalizationDisposition(
                remoteState: .keyAuthorized,
                wakeTokenCleanup: .notNeeded,
                requiresProfileAttention: false
            )
        case let .retryRequired(retry):
            PairingFinalizationDisposition(
                remoteState: retry.remoteState,
                wakeTokenCleanup: retry.wakeTokenCleanup,
                requiresProfileAttention: false,
                resumablePendingWiFiProfile:
                    Self.resumablePendingWiFiProfile(after: retry)
            )
        }
    }

    private static func resumablePendingWiFiProfile(
        after retry: TabletPairingFinalizationRetry
    ) -> DeviceProfile? {
        guard retry.failure == .wakeTokenStorageFailed,
              let profile = retry.durableProfile,
              profile.pairingState == .pendingWiFiVerification else {
            return nil
        }
        return profile
    }

    private func runPairingOperation(id: UUID) async {
        do {
            try await stopMonitorAndLifecycle()
        } catch {
            await publishApplication(.setupAttention)
            return
        }
        guard isCurrentPairingOperation(id), !Task.isCancelled, !isShuttingDown else {
            return
        }
        await diagnostics.record(.setupStarted)
        await publishApplication(.setupInProgress)
        guard isCurrentPairingOperation(id), !Task.isCancelled else { return }
        let result = await pairingPreparer.prepare()
        guard isCurrentPairingOperation(id), !Task.isCancelled, !isShuttingDown else {
            return
        }

        switch result {
        case .waitingForUSB:
            await diagnostics.record(.usbRouteUnavailable)
            await publishApplication(.setupWaitingForUSB)
        case .accessoryApprovalRequired:
            await diagnostics.record(.usbAccessoryApprovalRequired)
            await publishApplication(.usbAccessoryApprovalRequired)
        case .unsafeUSBRoute:
            await diagnostics.record(.usbRouteUnsafe)
            await publishApplication(.setupUnsafeUSBRoute)
        case .waitingForSSHBanner:
            await diagnostics.record(.sshBannerMissing)
            await publishApplication(.setupWaitingForWakeAndUnlock)
        case .awaitingTabletAuthorization:
            manualStep = .authorizeTablet
            await diagnostics.record(.localIdentityPrepared)
            await diagnostics.record(.hostIdentityPinned)
            await diagnostics.record(.profilePendingApproval)
            await publishApplication(.awaitingTabletAuthorization)
        case .awaitingWiFiVerification:
            manualStep = .connectUSBBeforeWiFi
            await publishApplication(.awaitingWiFiVerification)
        case .alreadyReady:
            manualStep = .chooseConnection
            await publishApplication(.readyToConnect)
        case let .failed(failure):
            switch failure {
            case .openSSHUnavailable:
                await diagnostics.record(.openSSHUnavailable)
            case .hostIdentity:
                await diagnostics.record(.hostIdentityRejected)
            case .profileStorage, .identityGeneration:
                await diagnostics.record(.profileInvalid)
            }
            await publishApplication(.setupAttention)
        }
    }

    private func isCurrentPairingOperation(_ id: UUID) -> Bool {
        pairingOperation?.id == id
    }

    private func finishPairingOperation(id: UUID) {
        if pairingOperation?.id == id {
            pairingOperation = nil
        }
    }

    private func beginMonitoring(
        profile: DeviceProfile,
        requestedRoute: ConnectionRoute,
        manualWiFi: ManualWiFiConnection?
    ) async -> Bool {
        guard !isShuttingDown, monitorOperation == nil else {
            manualInitialConnectionDeadline = nil
            return false
        }
        let initialConnectionDeadline = manualInitialConnectionDeadline
        manualInitialConnectionDeadline = nil
        manualConnectionSessionEnded = false
        ensureLifecycle()
        let operationID = UUID()
        let task = Task { [self] in
            await runMonitorOperation(
                profile: profile,
                requestedRoute: requestedRoute,
                manualWiFi: manualWiFi,
                initialConnectionDeadline: initialConnectionDeadline,
                id: operationID
            )
            finishMonitorOperation(id: operationID)
        }
        monitorOperation = Operation(id: operationID, task: task)
        return true
    }

    private func runMonitorOperation(
        profile: DeviceProfile,
        requestedRoute: ConnectionRoute,
        manualWiFi: ManualWiFiConnection?,
        initialConnectionDeadline: TimeInterval?,
        id: UUID
    ) async {
        let startingRevision = revision
        let progressTask = Task { [self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled,
                  isCurrentMonitorOperation(id),
                  revision == startingRevision,
                  activeRouteGeneration == nil,
                  !manualConnectionSessionEnded,
                  !isShuttingDown else {
                return
            }
            await publishApplication(.connecting)
        }
        defer { progressTask.cancel() }
        await runMonitor(
            profile: profile,
            requestedRoute: requestedRoute,
            manualWiFi: manualWiFi,
            initialConnectionDeadline: initialConnectionDeadline,
            operationID: id
        )
    }

    private func runMonitor(
        profile initialProfile: DeviceProfile,
        requestedRoute: ConnectionRoute,
        manualWiFi: ManualWiFiConnection?,
        initialConnectionDeadline: TimeInterval?,
        operationID: UUID
    ) async {
        var profile = initialProfile
        let paths = await profileStore.paths()
        let initialRecoveryLimit: Duration
        if let deadline = initialConnectionDeadline {
            let remaining = max(
                0,
                deadline - monitorServices.monotonicNow()
            )
            initialRecoveryLimit = .milliseconds(
                Int64((remaining * 1_000).rounded(.down))
            )
        } else {
            initialRecoveryLimit = .seconds(45)
        }
        manualRouteSessionPolicy = ManualRouteSessionPolicy(
            initialConnectionLimit: initialRecoveryLimit
        )
        wifiRepairPolicy.reset()

        while isCurrentMonitorOperation(operationID),
              !manualConnectionSessionEnded,
              !Task.isCancelled,
              !isShuttingDown {
            if activeRouteBinding == nil,
               let deadline = initialConnectionDeadline,
               monitorServices.monotonicNow() >= deadline {
                await retireActiveRouteAndPublish(.offline)
                return
            }
            let observationEpoch = monitorObservationEpoch.capture()
            let preActivationDeadline = activeRouteBinding == nil
                ? initialConnectionDeadline
                : nil
            let observations: (
                usb: MonitorRouteObservation,
                wifi: MonitorRouteObservation
            )
            do {
                observations = try await observeRoutes(
                    profile: profile,
                    paths: paths,
                    requestedRoute: requestedRoute,
                    manualWiFi: manualWiFi,
                    initialConnectionDeadline: preActivationDeadline,
                    allowUSBWake: true,
                    allowUSBHoldConfirmation: true
                )
            } catch is CancellationError {
                if Task.isCancelled { return }
                if !monitorObservationEpoch.isCurrent(observationEpoch) {
                    continue
                }
                await retireActiveRouteAndPublish(.offline)
                return
            } catch {
                if !monitorObservationEpoch.isCurrent(observationEpoch) {
                    continue
                }
                await retireActiveRouteAndPublish(.attention)
                return
            }
            if !isCurrentMonitorOperation(operationID) || Task.isCancelled || isShuttingDown {
                return
            }
            guard monitorObservationEpoch.isCurrent(observationEpoch) else {
                continue
            }

            let observation = requestedRoute == .usb
                ? observations.usb
                : observations.wifi
            let decision = manualRouteSessionPolicy.evaluate(
                hasActiveRoute: activeRouteBinding?.kind == requestedRoute,
                outcome: observation.selectionOutcome(
                    activeBinding: activeRouteBinding
                ),
                canWaitForInitialRecovery: Self.canWaitForInitialConnectionRecovery(
                    requestedRoute: requestedRoute,
                    evidence: observation.evidence
                )
            )

            switch decision {
            case .endSession:
                if requestedRoute == .usb,
                   case .usbRepairRequired = observation.evidence {
                    manualStep = .repairUSB
                }
                await retireActiveRouteAndPublish(observation.evidence)
                return

            case .waitForSelectedRoute:
                let interval = requestedRoute == .usb && activeRouteBinding == nil
                    ? Self.directCableInitialRetryDelay
                    : MonitorPollCadence.interval(
                        outcome: observation.outcome,
                        evidence: observation.evidence
                    )
                guard await pauseMonitor(
                    for: interval,
                    noLaterThan: initialConnectionDeadline
                ) else { return }

            case .useSelectedRoute:
                guard let candidate = observation.candidate else {
                    await retireActiveRouteAndPublish(observation.evidence)
                    return
                }

                if activeRouteBinding != candidate.binding {
                    guard activeRouteBinding == nil else {
                        await retireActiveRouteAndPublish(.readyToConnect)
                        return
                    }
                    guard observation.isAuthenticatedActivationCandidate else {
                        await retireActiveRouteAndPublish(observation.evidence)
                        return
                    }
                    let activation = await activateRoute(
                        candidate,
                        profile: profile,
                        requiresIdleAdmission: false,
                        observationEpoch: observationEpoch
                    )
                    guard isCurrentMonitorOperation(operationID),
                          !Task.isCancelled,
                          !isShuttingDown else {
                        return
                    }
                    switch activation {
                    case .activated:
                        break
                    case .deferredUntilIdle:
                        await publishApplication(.attention)
                        return
                    case .candidateBindingChanged:
                        wifiRepairPolicy.reset()
                        await publishApplication(.offline)
                        return
                    case .failed:
                        await publishApplication(.attention)
                        return
                    }
                }

                guard activeRouteBinding == candidate.binding,
                      let selectedGeneration = activeRouteGeneration else {
                    await publishApplication(.attention)
                    return
                }

                if observation.outcome == .ready {
                    await diagnostics.record(.transportAuthenticated)
                    guard activeRouteBinding == candidate.binding,
                          activeRouteGeneration == selectedGeneration else {
                        continue
                    }
                    guard await candidateBindingIsCurrent(
                        candidate,
                        profile: profile
                    ) else {
                        await retireActiveRouteAndPublish(.offline)
                        return
                    }
                    guard activeRouteBinding == candidate.binding,
                          activeRouteGeneration == selectedGeneration else {
                        continue
                    }
                    startFrameOperationIfNeeded(route: candidate.route)
                    await startFilesCapabilityIfNeeded(route: candidate.route)
                    guard activeRouteBinding == candidate.binding,
                          activeRouteGeneration == selectedGeneration else {
                        continue
                    }
                }

                if manualWiFi == nil,
                   observation.outcome == .ready,
                   let capability = observation.capability {
                    do {
                        profile = try await refreshedProfileIfNeeded(
                            profile,
                            capability: capability
                        )
                        guard activeRouteBinding == candidate.binding,
                              activeRouteGeneration == selectedGeneration else {
                            continue
                        }
                    } catch {
                        await retireActiveRouteAndPublish(.profileAttention)
                        return
                    }
                }

                let interval = MonitorPollCadence.interval(
                    outcome: observation.outcome,
                    evidence: observation.evidence,
                    retainedActiveTransient:
                        observation.outcome == .transientFailure &&
                        activeRouteBinding == candidate.binding
                )
                guard await pauseMonitor(for: interval) else { return }
            }
        }
    }

    private static func canWaitForInitialConnectionRecovery(
        requestedRoute: ConnectionRoute,
        evidence: ConnectionEvidence
    ) -> Bool {
        switch requestedRoute {
        case .usb:
            canWaitForUSBConnectionRecovery(evidence)
        case .wifi:
            evidence == .offline
        }
    }

    private static func canWaitForUSBConnectionRecovery(
        _ evidence: ConnectionEvidence
    ) -> Bool {
        switch evidence {
        case .offline,
             .sleeping,
             .waking,
             .starting:
            true
        default:
            false
        }
    }

    private func observeRoutes(
        profile: DeviceProfile,
        paths: DeviceProfilePaths,
        requestedRoute: ConnectionRoute,
        manualWiFi: ManualWiFiConnection?,
        initialConnectionDeadline: TimeInterval?,
        allowUSBWake: Bool,
        allowUSBHoldConfirmation: Bool
    ) async throws -> (
        usb: MonitorRouteObservation,
        wifi: MonitorRouteObservation
    ) {
        let usbUnavailable = MonitorRouteObservation.unavailable(.offline)
        let wifiUnavailable = MonitorRouteObservation.unavailable(.offline)

        switch requestedRoute {
        case .usb:
            return (
                try await observeUSB(
                    profile: profile,
                    paths: paths,
                    allowWake: allowUSBWake,
                    allowHoldConfirmation: allowUSBHoldConfirmation,
                    initialConnectionDeadline: initialConnectionDeadline
                ),
                wifiUnavailable
            )
        case .wifi:
            return (
                usbUnavailable,
                try await observeWiFi(
                    profile: profile,
                    paths: paths,
                    manualWiFi: manualWiFi
                )
            )
        }
    }

    private func observeUSB(
        profile: DeviceProfile,
        paths: DeviceProfilePaths,
        allowWake: Bool,
        allowHoldConfirmation: Bool,
        initialConnectionDeadline: TimeInterval?
    ) async throws -> MonitorRouteObservation {
        let context: DirectUSBRouteContext
        switch await monitorServices.verifyUSB() {
        case let .verified(verifiedContext):
            context = verifiedContext
        case .accessoryApprovalRequired:
            await diagnostics.record(.usbAccessoryApprovalRequired)
            return .unavailable(.usbAccessoryApprovalRequired)
        case .unsafeRoute:
            await diagnostics.record(.usbRouteUnsafe)
            return .unavailable(.setupUnsafeUSBRoute)
        case .unavailable:
            await diagnostics.record(.usbRouteUnavailable)
            return .unavailable(.setupWaitingForUSB)
        }

        let candidate: MonitorRouteCandidate
        do {
            candidate = try .make(
                binding: .usb(context),
                paths: paths
            )
        } catch {
            return .unavailable(.profileAttention)
        }

        // Ask the cable-authorized tablet service first, then authenticate SSH
        // once startup can proceed. This remains inside the single
        // owner-started USB-C session and never depends on Wi-Fi credentials.
        let wakeFallback = MonitorRouteObservation(
            outcome: .transientFailure,
            candidate: candidate,
            capability: nil,
            evidence: .offline
        )
        let wakeObservation: MonitorRouteObservation
        if allowWake {
            wakeObservation = await observeUSBWakeState(
                context: context,
                candidate: candidate,
                fallback: wakeFallback,
                initialConnectionDeadline: initialConnectionDeadline
            )
            guard case let .verified(wakeCheckedContext) =
                    await monitorServices.verifyUSB(),
                  wakeCheckedContext == context else {
                return .unavailable(.offline)
            }
            switch wakeObservation.evidence {
            case .sleeping, .waking, .unlockRequired, .repair:
                return wakeObservation
            default:
                break
            }
        } else {
            wakeObservation = wakeFallback
        }

        if let deadline = initialConnectionDeadline,
           monitorServices.monotonicNow() >= deadline {
            return wakeObservation
        }

        var result = try await monitorServices.probe(
            candidate.route,
            probeGeneration(for: candidate)
        )
        try Task.checkCancellation()
        guard case let .verified(currentContext) = await monitorServices.verifyUSB(),
              currentContext == context else {
            return .unavailable(.offline)
        }
        try Task.checkCancellation()

        if result.state == .authenticated,
           result.capability?.isCurrent == true,
           result.capability?.transportOperational != true {
            guard allowHoldConfirmation else {
                return MonitorRouteObservation(
                    outcome: .unavailable,
                    candidate: candidate,
                    capability: nil,
                    evidence: .repair
                )
            }
            // The tablet helper samples its USB hold once per second. Give one
            // manual Connect attempt a single bounded confirmation window, but
            // never admit USB without a proven active keep-awake hold.
            let holdConfirmationDelay: Duration
            if let deadline = initialConnectionDeadline {
                let remaining = max(
                    0,
                    deadline - monitorServices.monotonicNow()
                )
                guard remaining > 0 else { return wakeObservation }
                holdConfirmationDelay = min(
                    .milliseconds(1_250),
                    .milliseconds(
                        Int64((remaining * 1_000).rounded(.down))
                    )
                )
            } else {
                holdConfirmationDelay = .milliseconds(1_250)
            }
            try await Task.sleep(for: holdConfirmationDelay)
            if let deadline = initialConnectionDeadline,
               monitorServices.monotonicNow() >= deadline {
                return wakeObservation
            }
            guard case let .verified(confirmingContext) =
                    await monitorServices.verifyUSB(),
                  confirmingContext == context else {
                return .unavailable(.offline)
            }
            if let deadline = initialConnectionDeadline,
               monitorServices.monotonicNow() >= deadline {
                return wakeObservation
            }
            result = try await monitorServices.probe(
                candidate.route,
                probeGeneration(for: candidate)
            )
            try Task.checkCancellation()
            guard case let .verified(confirmedContext) =
                    await monitorServices.verifyUSB(),
                  confirmedContext == context else {
                return .unavailable(.offline)
            }
            try Task.checkCancellation()
        }

        switch result.state {
        case .authenticated
            where result.capability?.isCurrent == true &&
                result.capability?.transportOperational == true:
            let ready = MonitorRouteObservation(
                outcome: .ready,
                candidate: candidate,
                capability: result.capability?.verified(at: monitorServices.now()),
                evidence: .transportReady(.usb)
            )
            guard allowWake else { return ready }
            return Self.reconcileUSBWakeObservation(
                wakeObservation,
                fallback: ready
            )

        case .noRoute, .portOpenNoBanner:
            guard allowWake else {
                return MonitorRouteObservation(
                    outcome: .transientFailure,
                    candidate: candidate,
                    capability: nil,
                    evidence: .offline
                )
            }
            return Self.reconcileUSBWakeObservation(
                wakeObservation,
                fallback: MonitorRouteObservation(
                    outcome: .transientFailure,
                    candidate: candidate,
                    capability: nil,
                    evidence: result.state == .portOpenNoBanner
                        ? .wakeAndUnlock
                        : .offline
                )
            )

        case .identityRejected:
            await diagnostics.record(
                result.detail == .hostKeyRejected
                    ? .hostIdentityRejected
                    : .authenticationRejected
            )
            return MonitorRouteObservation(
                outcome: .unavailable,
                candidate: candidate,
                capability: nil,
                evidence: .repair
            )

        case .prerequisiteMismatch, .authenticated:
            await recordProbeMismatch(result.detail)
            let evidence: ConnectionEvidence
            switch result.detail {
            case .localCredentialFilesMissing:
                evidence = .repair
            case .openSSHUnavailable:
                evidence = .attention
            default:
                evidence = .repair
            }
            return MonitorRouteObservation(
                outcome: .unavailable,
                candidate: candidate,
                capability: nil,
                evidence: evidence
            )
        }
    }

    private static func reconcileUSBWakeObservation(
        _ wakeObservation: MonitorRouteObservation,
        fallback: MonitorRouteObservation
    ) -> MonitorRouteObservation {
        switch wakeObservation.evidence {
        case .offline:
            return fallback
        case .starting where fallback.outcome == .ready:
            return fallback
        default:
            return wakeObservation
        }
    }

    private static func preflightFailureDisposition(
        for request: PairingFinalizationRequest,
        evidence: ConnectionEvidence
    ) -> PairingFinalizationDisposition {
        let disposition = PairingFinalizationDisposition.unchanged.withManualEvidence(
            evidence
        )
        switch request {
        case .authorize:
            // The password was never sent. Do not retain it; return directly to
            // the explicit Add This Mac action instead of inserting a key check.
            return disposition.requiringPassword()
        case .checkAuthorization:
            return disposition.requiringAuthorizationCheck()
        case .repairUSB:
            return disposition.withManualEvidence(
                .usbRepairRequired(.secureTransportUnavailable)
            )
        case .reauthorizeUSB:
            return disposition.withManualEvidence(
                .usbRepairRequired(.keyRejected)
            )
        case .finishWiFi:
            return disposition
        }
    }

    private func observeUSBWakeState(
        context: DirectUSBRouteContext,
        candidate: MonitorRouteCandidate,
        fallback: MonitorRouteObservation,
        initialConnectionDeadline: TimeInterval?
    ) async -> MonitorRouteObservation {
        if let deadline = initialConnectionDeadline,
           monitorServices.monotonicNow() >= deadline {
            return fallback
        }
        let client: any TabletWakeServicing
        do {
            // USB-C status and wake are authorized by possession of the exact
            // verified cable. Durable bearer state is reserved for Wi-Fi setup
            // and must never affect a direct-cable connection.
            client = try await monitorServices
                .makeDirectCableRecoveryWakeClient(
                    context
                )
        } catch is CancellationError {
            return MonitorRouteObservation(
                outcome: .transientFailure,
                candidate: candidate,
                capability: nil,
                evidence: fallback.evidence
            )
        } catch {
            return MonitorRouteObservation(
                outcome: .unavailable,
                candidate: candidate,
                capability: nil,
                evidence: .repair
            )
        }
        if let deadline = initialConnectionDeadline,
           monitorServices.monotonicNow() >= deadline {
            return fallback
        }

        let status: TabletWakeResponse?
        do {
            status = try await client.status()
        } catch is CancellationError {
            return MonitorRouteObservation(
                outcome: .transientFailure,
                candidate: candidate,
                capability: nil,
                evidence: fallback.evidence
            )
        } catch TabletWakeClientError.authenticationFailed {
            // An older same-version helper can still require its bearer on the
            // cable listener. Surface the bounded owner-approved helper repair
            // instead of sending the user through local setup again.
            return MonitorRouteObservation(
                outcome: .unavailable,
                candidate: candidate,
                capability: nil,
                evidence: .usbRepairRequired(.secureTransportUnavailable)
            )
        } catch {
            return MonitorRouteObservation(
                outcome: .unavailable,
                candidate: candidate,
                capability: nil,
                evidence: .repair
            )
        }
        guard !Task.isCancelled, let status else {
            return fallback
        }
        if status.state == .sleeping,
           let deadline = initialConnectionDeadline,
           monitorServices.monotonicNow() >= deadline {
            return fallback
        }

        let now = monitorServices.monotonicNow()
        switch usbWakePolicy.directive(for: status.state, at: now) {
        case let .publish(evidence):
            return .resolvingUSBWake(
                state: status.state,
                evidence: evidence,
                candidate: candidate,
                fallback: fallback
            )

        case .sendWake:
            if let deadline = initialConnectionDeadline,
               monitorServices.monotonicNow() >= deadline {
                return fallback
            }
            let response: TabletWakeResponse?
            do {
                response = try await client.wake()
            } catch is CancellationError {
                return MonitorRouteObservation(
                    outcome: .transientFailure,
                    candidate: candidate,
                    capability: nil,
                    evidence: .sleeping
                )
            } catch {
                return MonitorRouteObservation(
                    outcome: .unavailable,
                    candidate: candidate,
                    capability: nil,
                    evidence: .repair
                )
            }
            guard !Task.isCancelled else {
                return MonitorRouteObservation(
                    outcome: .transientFailure,
                    candidate: candidate,
                    capability: nil,
                    evidence: .sleeping
                )
            }
            guard let response else {
                return .authoritativeUSBWake(
                    .sleeping,
                    candidate: candidate
                )
            }
            if response.wakeSent {
                usbWakePolicy.recordWakeSucceeded(at: now)
            }
            switch usbWakePolicy.directive(
                for: response.state,
                at: monitorServices.monotonicNow()
            ) {
            case let .publish(evidence):
                return .resolvingUSBWake(
                    state: response.state,
                    evidence: evidence,
                    candidate: candidate,
                    fallback: fallback
                )
            case .sendWake:
                return .authoritativeUSBWake(
                    .sleeping,
                    candidate: candidate
                )
            }
        }
    }

    private func observeWiFi(
        profile: DeviceProfile,
        paths: DeviceProfilePaths,
        manualWiFi: ManualWiFiConnection?
    ) async throws -> MonitorRouteObservation {
        let candidate: MonitorRouteCandidate
        let repairRoute: VerifiedWiFiRoute?
        if let manualWiFi {
            guard (try? monitorServices.currentWiFiSessionContext()) ==
                    manualWiFi.context else {
                wifiRepairPolicy.reset()
                return .unavailable(.offline)
            }
            do {
                candidate = try .make(
                    binding: .manualWiFi(
                        host: manualWiFi.host,
                        context: manualWiFi.context
                    ),
                    paths: paths
                )
            } catch {
                wifiRepairPolicy.reset()
                return .unavailable(.profileAttention)
            }
            repairRoute = nil
        } else {
            guard let wifiRoute = profile.wifi else {
                wifiRepairPolicy.reset()
                return .unavailable(.offline)
            }

            let context: WiFiNetworkContextMatch
            do {
                context = try await monitorServices.matchWiFi(
                    wifiRoute.contextDigest
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                wifiRepairPolicy.reset()
                return .unavailable(.offline)
            }
            guard context.isMatch else {
                wifiRepairPolicy.reset()
                return .unavailable(.offline)
            }

            do {
                candidate = try .make(
                    binding: .wifi(
                        route: wifiRoute,
                        interfaceName: context.interfaceName
                    ),
                    paths: paths
                )
            } catch {
                wifiRepairPolicy.reset()
                return .unavailable(.profileAttention)
            }
            repairRoute = wifiRoute
        }

        var result = try await monitorServices.probe(
            candidate.route,
            probeGeneration(for: candidate)
        )
        try Task.checkCancellation()
        guard await wifiConnectionIsCurrent(
            manualWiFi: manualWiFi,
            savedRoute: repairRoute,
            expectedInterface: candidate.binding.boundInterface
        ) else {
            wifiRepairPolicy.reset()
            return .unavailable(.offline)
        }
        try Task.checkCancellation()

        if result.identityAuthenticated &&
            (result.detail == .tabletPrerequisiteMismatch ||
                (result.state == .authenticated &&
                    result.capability?.isCurrent != true)) {
            let firstDisposition = wifiRepairPolicy.record(
                route: repairRoute,
                result: .authenticatedTabletPrerequisiteMismatch
            )
            if firstDisposition != .repair {
                // Confirm a dynamic companion mismatch twice inside this one
                // explicit Connect attempt. A cold route otherwise ends after
                // its first transient observation and could never reach Repair.
                try await Task.sleep(for: .milliseconds(500))
                guard await wifiConnectionIsCurrent(
                    manualWiFi: manualWiFi,
                    savedRoute: repairRoute,
                    expectedInterface: candidate.binding.boundInterface
                ) else {
                    wifiRepairPolicy.reset()
                    return .unavailable(.offline)
                }
                result = try await monitorServices.probe(
                    candidate.route,
                    probeGeneration(for: candidate)
                )
                try Task.checkCancellation()
                guard await wifiConnectionIsCurrent(
                    manualWiFi: manualWiFi,
                    savedRoute: repairRoute,
                    expectedInterface: candidate.binding.boundInterface
                ) else {
                    wifiRepairPolicy.reset()
                    return .unavailable(.offline)
                }
                try Task.checkCancellation()
            }
        }

        switch result.state {
        case .authenticated where result.capability?.isCurrent == true:
            _ = wifiRepairPolicy.record(route: repairRoute, result: .success)
            return MonitorRouteObservation(
                outcome: .ready,
                candidate: candidate,
                capability: result.capability?.verified(at: monitorServices.now()),
                evidence: .transportReady(.wifi)
            )

        case .noRoute, .portOpenNoBanner:
            _ = wifiRepairPolicy.record(route: repairRoute, result: .other)
            return MonitorRouteObservation(
                outcome: .transientFailure,
                candidate: candidate,
                capability: nil,
                evidence: .offline
            )

        case .identityRejected:
            _ = wifiRepairPolicy.record(
                route: repairRoute,
                result: .identityRejected
            )
            await diagnostics.record(
                result.detail == .hostKeyRejected
                    ? .hostIdentityRejected
                    : .authenticationRejected
            )
            return MonitorRouteObservation(
                outcome: .unavailable,
                candidate: candidate,
                capability: nil,
                evidence: manualWiFi == nil ? .repair : .offline
            )

        case .prerequisiteMismatch, .authenticated:
            await recordProbeMismatch(result.detail)
            if result.identityAuthenticated,
               result.detail == .tabletPrerequisiteMismatch ||
                    result.state == .authenticated {
                let disposition = wifiRepairPolicy.record(
                    route: repairRoute,
                    result: .authenticatedTabletPrerequisiteMismatch
                )
                return MonitorRouteObservation(
                    outcome: disposition == .repair
                        ? .unavailable
                        : .transientFailure,
                    candidate: candidate,
                    capability: nil,
                    evidence: disposition == .repair ? .repair : .offline
                )
            }

            _ = wifiRepairPolicy.record(route: repairRoute, result: .other)
            let evidence: ConnectionEvidence
            let outcome: RouteProbeOutcome
            switch result.detail {
            case .localCredentialFilesMissing:
                evidence = .repair
                outcome = .unavailable
            case .openSSHUnavailable:
                evidence = .attention
                outcome = .unavailable
            default:
                evidence = .offline
                outcome = .transientFailure
            }
            return MonitorRouteObservation(
                outcome: outcome,
                candidate: candidate,
                capability: nil,
                evidence: evidence
            )
        }
    }

    private func wifiConnectionIsCurrent(
        manualWiFi: ManualWiFiConnection?,
        savedRoute: VerifiedWiFiRoute?,
        expectedInterface: String
    ) async -> Bool {
        if let manualWiFi {
            guard manualWiFi.context.interfaceName == expectedInterface else {
                return false
            }
            return (try? monitorServices.currentWiFiSessionContext()) ==
                manualWiFi.context
        }

        guard let savedRoute else { return false }
        let context: WiFiNetworkContextMatch
        do {
            context = try await monitorServices.matchWiFi(
                savedRoute.contextDigest
            )
        } catch {
            return false
        }
        return context.isMatch && context.interfaceName == expectedInterface
    }

    private func probeGeneration(
        for candidate: MonitorRouteCandidate
    ) -> GenerationID {
        if candidate.binding == activeRouteBinding,
           let activeRouteGeneration {
            return activeRouteGeneration
        }
        return .make()
    }

    private func refreshedProfileIfNeeded(
        _ profile: DeviceProfile,
        capability: VerifiedTabletCapability
    ) async throws -> DeviceProfile {
        guard let stored = profile.lastVerified else {
            throw DeviceProfileStoreError.invalidProfile
        }
        guard !stored.isSemanticallyEquivalent(to: capability) else {
            return profile
        }
        switch profile.pairingState {
        case .pendingTabletAuthorization:
            throw DeviceProfileStoreError.invalidProfile
        case .pendingWiFiVerification:
            return try await profileStore.refreshPendingWiFiVerification(
                expected: profile,
                capability: capability
            )
        case .ready:
            return try await profileStore.refreshLastVerified(
                expectedReady: profile,
                capability: capability
            )
        }
    }

    private func activateRoute(
        _ candidate: MonitorRouteCandidate,
        profile: DeviceProfile,
        requiresIdleAdmission: Bool,
        observationEpoch: MonitorObservationEpoch.Token
    ) async -> MonitorActivationResult {
        guard let lifecycle else { return .failed }
        guard monitorObservationEpoch.isCurrent(observationEpoch) else {
            return .candidateBindingChanged
        }

        routeTransitionReservation = activeRouteGeneration
        if requiresIdleAdmission {
            let filesInFlight = await filesCapability?
                .operationOwner
                .inFlightCount ?? 0
            guard monitorObservationEpoch.isCurrent(observationEpoch) else {
                routeTransitionReservation = nil
                return .candidateBindingChanged
            }
            guard !pointerInteractionIsActive, filesInFlight == 0 else {
                routeTransitionReservation = nil
                return .deferredUntilIdle
            }
        }
        guard await candidateBindingIsCurrent(candidate, profile: profile),
              monitorObservationEpoch.isCurrent(observationEpoch) else {
            routeTransitionReservation = nil
            return .candidateBindingChanged
        }

        let signpost = PerformanceSignposts.begin("Connection Route Activation")
        defer { PerformanceSignposts.end(signpost) }

        if activeRouteGeneration != nil {
            let epochBeforeClear = monitorObservationEpoch.capture()
            await lifecycle.request(.none)
            do {
                try await lifecycle.awaitSettled()
            } catch {
                routeTransitionReservation = nil
                return .failed
            }
            guard monitorObservationEpoch.advancedExactlyOnce(
                since: epochBeforeClear
            ) else {
                routeTransitionReservation = nil
                return .candidateBindingChanged
            }
        }

        let clearedEpoch = monitorObservationEpoch.capture()
        guard await candidateBindingIsCurrent(candidate, profile: profile),
              monitorObservationEpoch.isCurrent(clearedEpoch) else {
            routeTransitionReservation = nil
            return .candidateBindingChanged
        }

        pendingActivationCandidate = candidate
        await lifecycle.request(.route(candidate.binding.kind))
        do {
            try await lifecycle.awaitSettled()
        } catch {
            pendingActivationCandidate = nil
            routeTransitionReservation = nil
            return .failed
        }
        pendingActivationCandidate = nil
        routeTransitionReservation = nil
        guard activeRouteBinding == candidate.binding,
              activeRouteGeneration != nil else {
            await lifecycle.request(.none)
            try? await lifecycle.awaitSettled()
            return .failed
        }
        return .activated
    }

    private func candidateBindingIsCurrent(
        _ candidate: MonitorRouteCandidate,
        profile: DeviceProfile
    ) async -> Bool {
        switch candidate.binding {
        case let .usb(expectedContext):
            guard case let .verified(currentContext) =
                    await monitorServices.verifyUSB() else {
                return false
            }
            return currentContext == expectedContext

        case let .wifi(wifiRoute, expectedInterface):
            let context: WiFiNetworkContextMatch
            do {
                context = try await monitorServices.matchWiFi(
                    wifiRoute.contextDigest
                )
            } catch {
                return false
            }
            return context.isMatch &&
                context.interfaceName == expectedInterface &&
                profile.wifi == wifiRoute

        case let .manualWiFi(_, expectedContext):
            return (try? monitorServices.currentWiFiSessionContext()) ==
                expectedContext
        }
    }

    private func isCurrentMonitorOperation(_ id: UUID) -> Bool {
        monitorOperation?.id == id
    }

    private func finishMonitorOperation(id: UUID) {
        if monitorOperation?.id == id {
            monitorOperation = nil
        }
    }

    private func ensureLifecycle() {
        guard lifecycle == nil else { return }
        let registry = processRegistry
        lifecycle = RouteGenerationLifecycle(
            factory: RouteGenerationFactory { route in
                RouteGeneration(id: .make(), route: route, processRegistry: registry)
            },
            publish: { [self] publication in
                await handleLifecyclePublication(publication)
            }
        )
    }

    private func handleLifecyclePublication(_ publication: RouteLifecyclePublication) async {
        guard !Task.isCancelled else { return }
        switch publication {
        case .cleared:
            let hadActiveRoute = activeRouteGeneration != nil
            let operation = clearActiveRouteState()
            if hadActiveRoute {
                manualConnectionSessionEnded = true
                manualStep = manualConnectionRecoveryStep()
            }
            await publish(
                evidence: hadActiveRoute ? .readyToConnect : .connecting,
                admission: .clearGeneration,
                generation: nil
            )
            await diagnostics.record(.generationCleared)
            await clearFilesCapability()
            await cancelFrameOperation(operation)
        case let .activated(generation, route):
            guard !Task.isCancelled else { return }
            guard let candidate = pendingActivationCandidate,
                  candidate.binding.kind == route else {
                return
            }
            activeRouteGeneration = generation
            activeRoute = route
            activeRouteBinding = candidate.binding
            activeSSHRoute = candidate.route
            frameGeneration = nil
            inputGeneration = nil
            filesGeneration = nil
            monitorObservationEpoch.advance()
            await publish(
                evidence: .transportReady(route),
                admission: .activateGeneration,
                generation: generation
            )
        case .failed:
            manualConnectionSessionEnded = true
            manualStep = manualConnectionRecoveryStep()
            let operation = clearActiveRouteState()
            await publish(
                evidence: .attention,
                admission: .clearGeneration,
                generation: nil
            )
            await clearFilesCapability()
            await cancelFrameOperation(operation)
        }
    }

    private func clearActiveRouteState() -> FrameOperation? {
        let operation = takeFrameOperation()
        activeRouteGeneration = nil
        activeRoute = nil
        activeRouteBinding = nil
        activeSSHRoute = nil
        frameGeneration = nil
        inputGeneration = nil
        filesGeneration = nil
        pointerInteractionIsActive = false
        monitorObservationEpoch.advance()
        return operation
    }

    private func retireActiveRouteAndPublish(_ evidence: ConnectionEvidence) async {
        if let lifecycle {
            routeTransitionReservation = activeRouteGeneration
            await lifecycle.request(DesiredRoute.none)
            do {
                try await lifecycle.awaitSettled()
            } catch {
                routeTransitionReservation = nil
                await publishApplication(.attention)
                return
            }
            routeTransitionReservation = nil
        }
        manualConnectionSessionEnded = true
        manualStep = manualConnectionRecoveryStep()
        await publishApplication(evidence)
    }

    private func manualConnectionRecoveryStep() -> ConnectionManualStep {
        .chooseConnection
    }

    private func recordProbeMismatch(_ detail: PassiveRouteProbeDetail) async {
        switch detail {
        case .openSSHUnavailable, .localCredentialFilesMissing:
            await diagnostics.record(.openSSHUnavailable)
        case .hostKeyRejected:
            await diagnostics.record(.hostIdentityRejected)
        case .authenticationRejected:
            await diagnostics.record(.authenticationRejected)
        case .tabletPrerequisiteMismatch:
            await diagnostics.record(.tabletPrerequisiteMismatch)
        default:
            await diagnostics.record(.capabilityResponseInvalid)
        }
    }

    private func publishApplication(_ evidence: ConnectionEvidence) async {
        await clearFilesCapability()
        activeRouteGeneration = nil
        activeRoute = nil
        activeRouteBinding = nil
        activeSSHRoute = nil
        frameGeneration = nil
        inputGeneration = nil
        pointerInteractionIsActive = false
        await publish(
            evidence: evidence,
            admission: .application,
            generation: nil
        )
    }

    private func publish(
        evidence: ConnectionEvidence,
        admission: ConnectionSnapshotAdmission,
        generation: GenerationID?
    ) async {
        guard !Task.isCancelled else { return }
        revision &+= 1
        let snapshot = ConnectionSnapshot(
            revision: revision,
            admission: admission,
            generation: generation,
            evidence: evidence,
            frameGeneration: frameGeneration,
            inputGeneration: inputGeneration,
            filesReady: generation != nil && filesGeneration == generation,
            manualStep: manualStep
        )
        guard !Task.isCancelled else { return }
        await publishSnapshot(snapshot)
    }

    private func startFrameOperationIfNeeded(route: SSHRoute) {
        guard !isShuttingDown,
              !manualConnectionSessionEnded,
              frameOperation == nil,
              frameGeneration == nil,
              let generation = activeRouteGeneration,
              routeTransitionReservation != generation,
              activeRoute == route.kind,
              activeSSHRoute == route else {
            return
        }

        let operationID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runFrameOperation(
                id: operationID,
                generation: generation,
                route: route
            )
        }
        frameOperation = FrameOperation(
            id: operationID,
            generation: generation,
            inputSession: nil,
            inputMonitorTask: nil,
            session: nil,
            isStopping: false,
            task: task
        )
    }

    private func runFrameOperation(
        id: UUID,
        generation: GenerationID,
        route: SSHRoute
    ) async {
        do {
            let preparation = DisplayPreparationService(
                route: route,
                registry: processRegistry
            )
            _ = try await preparation.prepare(
                generation: generation,
                allowStart: true
            )
            try Task.checkCancellation()

            guard isCurrentFrameOperation(id: id, generation: generation),
                  !manualConnectionSessionEnded,
                  routeTransitionReservation != generation,
                  !isShuttingDown else {
                return
            }

            let inputSession = try await RMM1InputSession.connect(
                route: route,
                generation: generation,
                launcher: processRegistry
            )
            guard isCurrentFrameOperation(id: id, generation: generation),
                  !Task.isCancelled,
                  !manualConnectionSessionEnded,
                  routeTransitionReservation != generation,
                  !isShuttingDown else {
                _ = await closeInputSession(inputSession)
                return
            }

            frameOperation?.inputSession = inputSession
            frameOperation?.inputMonitorTask = Task { [weak self] in
                do {
                    let failure = try await inputSession.waitUntilStopped()
                    guard !Task.isCancelled else { return }
                    await self?.inputSessionStopped(
                        failure,
                        operationID: id,
                        generation: generation
                    )
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    await self?.inputSessionStopped(
                        RMM1InputFailure(
                            .connectionClosed,
                            isPersistent: false
                        ),
                        operationID: id,
                        generation: generation
                    )
                }
            }
            inputGeneration = generation
            if let activeRoute {
                await publish(
                    evidence: .transportReady(activeRoute),
                    admission: .generationEvent,
                    generation: generation
                )
            }

            guard isCurrentFrameOperation(id: id, generation: generation),
                  !Task.isCancelled,
                  !manualConnectionSessionEnded,
                  routeTransitionReservation != generation,
                  !isShuttingDown else {
                _ = await closeInputSession(inputSession)
                return
            }
            _ = try await preparation.prepare(
                generation: generation,
                allowStart: false
            )
            try Task.checkCancellation()
            await startFilesCapabilityIfNeeded(route: route)
        } catch is CancellationError {
            await finishFrameOperation(
                id: id,
                generation: generation,
                termination: .cancelled
            )
            return
        } catch {
            await recordUncertainInputRestorationIfNeeded(error)
            await finishFrameOperation(
                id: id,
                generation: generation,
                termination: .retryableInterruption(.transport)
            )
            return
        }

        guard isCurrentFrameOperation(id: id, generation: generation),
              !manualConnectionSessionEnded,
              routeTransitionReservation != generation else {
            return
        }

        let session = RMM1FrameStreamSession(
            route: route,
            generation: generation,
            registry: processRegistry
        ) { [weak self] delivery in
            guard let self else { return false }
            return await self.acceptFrame(delivery, operationID: id)
        }
        frameOperation?.session = session

        let termination: RMM1FrameStreamTermination
        do {
            termination = try await session.run()
        } catch is CancellationError {
            termination = .cancelled
        } catch {
            termination = .retryableInterruption(.transport)
        }
        await finishFrameOperation(
            id: id,
            generation: generation,
            termination: termination
        )
    }

    private func acceptFrame(
        _ delivery: RMM1FrameDelivery,
        operationID: UUID
    ) async -> Bool {
        guard MonitorGenerationAdmission.accepts(
                generation: delivery.generation,
                activeGeneration: activeRouteGeneration,
                transitionReservation: routeTransitionReservation
              ),
              isCurrentFrameOperation(
                id: operationID,
                generation: delivery.generation
              ),
              !manualConnectionSessionEnded,
              !isShuttingDown else {
            return false
        }

        let accepted = await presentFrame(delivery.generation, delivery.update)
        guard accepted,
              MonitorGenerationAdmission.accepts(
                generation: delivery.generation,
                activeGeneration: activeRouteGeneration,
                transitionReservation: routeTransitionReservation
              ),
              isCurrentFrameOperation(
                id: operationID,
                generation: delivery.generation
              ),
              !manualConnectionSessionEnded,
              !isShuttingDown else {
            return false
        }

        if frameGeneration != delivery.generation {
            frameGeneration = delivery.generation
            guard let route = activeRoute else { return false }
            await publish(
                evidence: .transportReady(route),
                admission: .generationEvent,
                generation: delivery.generation
            )
        }

        return MonitorGenerationAdmission.accepts(
            generation: delivery.generation,
            activeGeneration: activeRouteGeneration,
            transitionReservation: routeTransitionReservation
        ) &&
            isCurrentFrameOperation(
                id: operationID,
                generation: delivery.generation
            ) &&
            !manualConnectionSessionEnded &&
            !isShuttingDown
    }

    private func finishFrameOperation(
        id: UUID,
        generation: GenerationID,
        termination _: RMM1FrameStreamTermination
    ) async {
        guard isCurrentFrameOperation(id: id, generation: generation),
              let operation = frameOperation else {
            return
        }
        frameOperation?.isStopping = true
        operation.inputMonitorTask?.cancel()

        guard activeRouteGeneration == generation, !isShuttingDown else {
            return
        }

        reserveManualSessionRetirement(generation: generation)

        frameGeneration = nil
        inputGeneration = nil
        if let route = activeRoute {
            await publish(
                evidence: .transportReady(route),
                admission: .generationEvent,
                generation: generation
            )
        }

        if let inputSession = operation.inputSession {
            _ = await closeInputSession(inputSession)
        }

        guard isCurrentFrameOperation(id: id, generation: generation) else {
            return
        }
        frameOperation = nil

        await lifecycle?.request(.none)
    }

    private func isCurrentFrameOperation(
        id: UUID,
        generation: GenerationID
    ) -> Bool {
        frameOperation?.id == id && frameOperation?.generation == generation
    }

    private func takeFrameOperation() -> FrameOperation? {
        let operation = frameOperation
        frameOperation = nil
        return operation
    }

    private func cancelFrameOperation(_ operation: FrameOperation?) async {
        guard let operation else { return }
        operation.task.cancel()
        operation.inputMonitorTask?.cancel()
        if let session = operation.session {
            await session.cancel()
        }
        if let inputSession = operation.inputSession {
            _ = await closeInputSession(inputSession)
        } else {
            // During startup, connect() owns a child before it can publish the
            // session. Let its cancellation path finish EOF restoration before
            // the route generation retires that child.
            await operation.task.value
        }
    }

    private func inputSessionStopped(
        _ failure: RMM1InputFailure?,
        operationID: UUID,
        generation: GenerationID
    ) async {
        guard activeRouteGeneration == generation,
              frameOperation?.id == operationID,
              frameOperation?.isStopping == false,
              let lifecycleAtStop = lifecycle,
              !isShuttingDown else {
            return
        }

        frameOperation?.isStopping = true
        reserveManualSessionRetirement(generation: generation)
        frameGeneration = nil
        inputGeneration = nil
        if let failure {
            await recordUncertainInputRestorationIfNeeded(failure)
            guard isCurrentInputOperation(
                operationID: operationID,
                generation: generation,
                lifecycle: lifecycleAtStop
            ) else {
                return
            }
        }
        if let route = activeRoute {
            await publish(
                evidence: .transportReady(route),
                admission: .generationEvent,
                generation: generation
            )
        }
        guard isCurrentInputOperation(
            operationID: operationID,
            generation: generation,
            lifecycle: lifecycleAtStop
        ) else {
            return
        }
        await lifecycleAtStop.request(.none)
    }

    private func isCurrentInputOperation(
        operationID: UUID,
        generation: GenerationID,
        lifecycle expectedLifecycle: RouteGenerationLifecycle
    ) -> Bool {
        !isShuttingDown &&
            activeRouteGeneration == generation &&
            frameOperation?.id == operationID &&
            frameOperation?.generation == generation &&
            lifecycle === expectedLifecycle
    }

    @discardableResult
    private func closeInputSession(
        _ session: RMM1InputSession
    ) async -> RMM1InputStopResult {
        let result = await session.close()
        if result.restoration == .uncertain {
            inputRestorationIsUncertain = true
            await diagnostics.record(.inputRestorationUncertain)
        }
        return result
    }

    private func recordUncertainInputRestorationIfNeeded(
        _ error: any Error
    ) async {
        guard let failure = error as? RMM1InputFailure,
              failure.kind == .restorationUncertain ||
                failure.kind == .physicalRestoreFailed else {
            return
        }
        inputRestorationIsUncertain = true
        await diagnostics.record(.inputRestorationUncertain)
    }

    private func startFilesCapabilityIfNeeded(route: SSHRoute) async {
        guard !isShuttingDown,
              !manualConnectionSessionEnded,
              let generation = activeRouteGeneration,
              routeTransitionReservation != generation,
              inputGeneration == generation,
              activeRoute == route.kind,
              activeSSHRoute == route else {
            return
        }

        if filesCapability == nil {
            let tunnel = FilesSSHTunnel(
                route: route,
                generation: generation,
                processRegistry: processRegistry
            )
            let client = RemarkableFilesClient(tunnel: tunnel)
            filesCapability = makeFilesCapability(
                generation: generation,
                tunnel: tunnel,
                client: client
            )
        } else if filesCapability?.generation != generation {
            return
        }

        guard activeRouteGeneration == generation,
              filesCapability?.generation == generation,
              filesCapability?.isRetiring == false else {
            return
        }
        if var capability = filesCapability,
           capability.probeTask == nil,
           !capability.readinessProbeAttempted,
           !capability.isPreparingProbe,
           !capability.isAttached,
           filesGeneration == nil {
            let capabilityID = capability.id
            capability.isPreparingProbe = true
            filesCapability = capability
            if !(await capability.tunnel.isActive()) {
                try? await capability.tunnel.resetAfterFailureForRetry()
            }
            guard var current = filesCapability,
                  current.id == capabilityID,
                  current.generation == generation else {
                return
            }
            current.isPreparingProbe = false
            if let ownerRequestID = current.ownerRequestID,
               let deadline = current.ownerRequestedProbeUntil,
               filesPaneIsOpen,
               filesPaneOwnerRequest?.id == ownerRequestID,
               monitorServices.monotonicNow() < deadline {
                current.readinessProbeAttempted = false
            }
            filesCapability = current
        }
        startFilesProbeIfNeeded()
    }

    private func makeFilesCapability(
        generation: GenerationID,
        tunnel: FilesSSHTunnel,
        client: RemarkableFilesClient,
        allowsOwnerlessInitialProbe: Bool = true
    ) -> FilesCapability {
        let ownerRequest = currentFilesPaneOwnerRequest(for: generation)
        let id = UUID()
        return FilesCapability(
            id: id,
            generation: generation,
            tunnel: tunnel,
            client: client,
            service: makeFilesService(id: id, generation: generation),
            operationOwner: FilesGenerationOperationOwner(generation: generation),
            probeTask: nil,
            readinessProbeAttempted:
                ownerRequest == nil && !allowsOwnerlessInitialProbe,
            isPreparingProbe: false,
            ownerRequestID: ownerRequest?.id,
            ownerRequestedProbeUntil: ownerRequest?.deadline,
            isAttached: false,
            isRetiring: false
        )
    }

    private func currentFilesPaneOwnerRequest(
        for generation: GenerationID
    ) -> FilesPaneOwnerRequest? {
        guard filesPaneIsOpen,
              var request = filesPaneOwnerRequest else {
            return nil
        }
        if let requestedGeneration = request.generation {
            guard requestedGeneration == generation else {
                filesPaneOwnerRequest = nil
                return nil
            }
        } else {
            request.generation = generation
        }
        if let deadline = request.deadline {
            guard monitorServices.monotonicNow() < deadline else {
                filesPaneOwnerRequest = nil
                return nil
            }
        } else {
            request.deadline =
                monitorServices.monotonicNow() + Self.filesOpenRecoveryLimit
        }
        filesPaneOwnerRequest = request
        return request
    }

    private func clearFilesPaneOwnerRequest(ifMatching id: UUID?) {
        guard let id,
              filesPaneOwnerRequest?.id == id else {
            return
        }
        filesPaneOwnerRequest = nil
    }

    private func makeFilesService(
        id: UUID,
        generation: GenerationID
    ) -> FilesPaneService {
        FilesPaneService(
            id: id,
            listRoot: { [weak self] in
                guard let self else { throw Self.filesUnavailable() }
                return try await self.listFilesRoot(
                    capabilityID: id,
                    generation: generation
                )
            },
            listFolder: { [weak self] folderID in
                guard let self else { throw Self.filesUnavailable() }
                return try await self.listFilesFolder(
                    folderID,
                    capabilityID: id,
                    generation: generation
                )
            },
            importFile: { [weak self] sourceURL, folderID in
                guard let self else { throw Self.filesUnavailable() }
                return try await self.importFile(
                    sourceURL,
                    to: folderID,
                    capabilityID: id,
                    generation: generation
                )
            },
            exportDocument: { [weak self] documentID, format, destinationURL in
                guard let self else { throw Self.filesUnavailable() }
                return try await self.exportFile(
                    documentID,
                    format: format,
                    to: destinationURL,
                    capabilityID: id,
                    generation: generation
                )
            },
            makeDocumentPromise: { [weak self] item in
                guard item.kind == .document else { return nil }
                return FinderDocumentPromise(
                    documentID: item.id,
                    displayName: item.displayName,
                    materializer: FinderPromiseMaterializer {
                        [weak self] documentID, destinationURL in
                        guard let self else {
                            throw Self.filesUnavailable()
                        }
                        _ = try await self.exportFile(
                            documentID,
                            format: .pdf,
                            to: destinationURL,
                            capabilityID: id,
                            generation: generation
                        )
                    }
                )
            }
        )
    }

    private func startFilesProbeIfNeeded() {
        guard var capability = filesCapability,
              !manualConnectionSessionEnded,
              activeRouteGeneration == capability.generation,
              routeTransitionReservation != capability.generation,
              capability.probeTask == nil,
              !capability.isPreparingProbe,
              !capability.isRetiring,
              filesGeneration != capability.generation else {
            return
        }

        if let deadline = capability.ownerRequestedProbeUntil,
           monitorServices.monotonicNow() >= deadline {
            clearFilesPaneOwnerRequest(ifMatching: capability.ownerRequestID)
            capability.ownerRequestID = nil
            capability.ownerRequestedProbeUntil = nil
            capability.readinessProbeAttempted = true
            filesCapability = capability
            return
        }
        guard !capability.readinessProbeAttempted else { return }

        let id = capability.id
        let generation = capability.generation
        let ownerRequestID = capability.ownerRequestID
        capability.readinessProbeAttempted = true
        capability.probeTask = Task { [weak self] in
            await self?.runFilesProbe(
                capabilityID: id,
                generation: generation,
                ownerRequestID: ownerRequestID
            )
        }
        filesCapability = capability
    }

    private func scheduleFilesReadinessRetry(
        capabilityID: UUID,
        generation: GenerationID,
        ownerRequestID: UUID
    ) {
        guard filesReadinessRetryOperation == nil,
              filesPaneIsOpen,
              let capability = filesCapability,
              capability.id == capabilityID,
              capability.generation == generation,
              capability.ownerRequestID == ownerRequestID,
              filesPaneOwnerRequest?.id == ownerRequestID,
              capability.probeTask == nil,
              capability.readinessProbeAttempted,
              !capability.isPreparingProbe,
              !capability.isAttached,
              !capability.isRetiring else {
            return
        }

        let operationID = UUID()
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.filesReadinessRetryDelay)
            } catch {
                return
            }
            await self?.finishFilesReadinessRetry(
                operationID: operationID,
                capabilityID: capabilityID,
                generation: generation,
                ownerRequestID: ownerRequestID
            )
        }
        filesReadinessRetryOperation = Operation(id: operationID, task: task)
    }

    private func finishFilesReadinessRetry(
        operationID: UUID,
        capabilityID: UUID,
        generation: GenerationID,
        ownerRequestID: UUID
    ) {
        guard filesReadinessRetryOperation?.id == operationID else { return }
        filesReadinessRetryOperation = nil

        guard !isShuttingDown,
              !manualConnectionSessionEnded,
              filesPaneIsOpen,
              activeRouteGeneration == generation,
              routeTransitionReservation != generation,
              var capability = filesCapability,
              capability.id == capabilityID,
              capability.generation == generation,
              capability.ownerRequestID == ownerRequestID,
              filesPaneOwnerRequest?.id == ownerRequestID,
              capability.probeTask == nil,
              !capability.isPreparingProbe,
              !capability.isAttached,
              !capability.isRetiring else {
            return
        }

        capability.readinessProbeAttempted = false
        filesCapability = capability
        startFilesProbeIfNeeded()
    }

    private func cancelFilesReadinessRetry() {
        filesReadinessRetryOperation?.task.cancel()
        filesReadinessRetryOperation = nil
    }

    private func runFilesProbe(
        capabilityID: UUID,
        generation: GenerationID,
        ownerRequestID: UUID?
    ) async {
        guard let capability = filesCapability,
              capability.id == capabilityID,
              capability.generation == generation,
              activeRouteGeneration == generation,
              routeTransitionReservation != generation,
              !manualConnectionSessionEnded,
              !capability.isRetiring else {
            return
        }

        do {
            try await capability.operationOwner.run {
                try await capability.client.probeReadiness()
            }
            guard !Task.isCancelled else { return }
            await finishFilesProbe(
                capabilityID: capabilityID,
                generation: generation,
                isReady: true,
                ownerRequestID: ownerRequestID
            )
        } catch is CancellationError {
            return
        } catch is FilesGenerationOperationOwnerError {
            return
        } catch {
            await finishFilesProbe(
                capabilityID: capabilityID,
                generation: generation,
                isReady: false,
                ownerRequestID: ownerRequestID
            )
        }
    }

    private func finishFilesProbe(
        capabilityID: UUID,
        generation: GenerationID,
        isReady: Bool,
        ownerRequestID: UUID?
    ) async {
        var retryOwnerRequestID: UUID?
        guard var capability = filesCapability,
              capability.id == capabilityID,
              capability.generation == generation,
              activeRouteGeneration == generation,
              routeTransitionReservation != generation,
              !manualConnectionSessionEnded,
              !capability.isRetiring else {
            return
        }

        capability.probeTask = nil
        let ownerResultIsCurrent: Bool
        if let ownerRequestID {
            ownerResultIsCurrent = filesPaneIsOpen &&
                capability.ownerRequestID == ownerRequestID &&
                filesPaneOwnerRequest?.id == ownerRequestID &&
                capability.ownerRequestedProbeUntil.map {
                    monitorServices.monotonicNow() < $0
                } == true
        } else {
            ownerResultIsCurrent = true
        }
        if isReady, ownerResultIsCurrent {
            capability.isAttached = true
            capability.ownerRequestID = nil
            capability.ownerRequestedProbeUntil = nil
            filesCapability = capability
            filesGeneration = generation
            await publishFilesService(generation, capability.service)
        } else {
            capability.isAttached = false
            capability.isPreparingProbe = true
            filesCapability = capability
            filesGeneration = nil
            if !(await capability.tunnel.isActive()) {
                try? await capability.tunnel.resetAfterFailureForRetry()
            }
            guard var current = filesCapability,
                  current.id == capabilityID,
                  current.generation == generation else {
                return
            }
            current.isPreparingProbe = false
            if current.probeTask == nil,
               let currentOwnerRequestID = current.ownerRequestID,
               let deadline = current.ownerRequestedProbeUntil {
                if filesPaneIsOpen,
                   filesPaneOwnerRequest?.id == currentOwnerRequestID,
                   monitorServices.monotonicNow() < deadline {
                    current.readinessProbeAttempted = true
                    retryOwnerRequestID = currentOwnerRequestID
                } else {
                    clearFilesPaneOwnerRequest(ifMatching: currentOwnerRequestID)
                    current.ownerRequestID = nil
                    current.ownerRequestedProbeUntil = nil
                }
            }
            filesCapability = current
            await publishFilesService(nil, nil)
        }

        guard activeRouteGeneration == generation,
              filesCapability?.id == capabilityID,
              let route = activeRoute else {
            return
        }
        await publish(
            evidence: .transportReady(route),
            admission: .generationEvent,
            generation: generation
        )
        if let retryOwnerRequestID {
            scheduleFilesReadinessRetry(
                capabilityID: capabilityID,
                generation: generation,
                ownerRequestID: retryOwnerRequestID
            )
        }
    }

    private func clearFilesCapability() async {
        cancelFilesReadinessRetry()
        guard var capability = filesCapability else {
            filesGeneration = nil
            return
        }
        capability.probeTask?.cancel()
        capability.isAttached = false
        capability.isRetiring = true
        filesCapability = capability
        filesGeneration = nil
        await publishFilesService(nil, nil)
        await capability.operationOwner.retire()
        await capability.probeTask?.value
        // A connection-failure handler may finish the same owner drain first
        // and install its clean retry capability while this actor is reentrant.
        // Clearing the route owns the stronger boundary: discard any capability
        // for the retiring generation, not only the exact retired instance.
        if filesCapability?.generation == capability.generation {
            filesCapability = nil
        }
    }

    private func listFilesRoot(
        capabilityID: UUID,
        generation: GenerationID
    ) async throws -> [RemarkableLibraryItem] {
        let capability = try currentFilesCapability(
            capabilityID: capabilityID,
            generation: generation
        )
        let items = try await runFilesOperation(capability) {
            try await capability.client.listRoot()
        }
        return items
    }

    private func listFilesFolder(
        _ folderID: UUID,
        capabilityID: UUID,
        generation: GenerationID
    ) async throws -> [RemarkableLibraryItem] {
        let capability = try currentFilesCapability(
            capabilityID: capabilityID,
            generation: generation
        )
        let items = try await runFilesOperation(capability) {
            try await capability.client.listFolder(folderID)
        }
        return items
    }

    private func importFile(
        _ sourceURL: URL,
        to folderID: UUID?,
        capabilityID: UUID,
        generation: GenerationID
    ) async throws -> FilesUploadReceipt {
        let capability = try currentFilesCapability(
            capabilityID: capabilityID,
            generation: generation
        )
        let receipt = try await runFilesOperation(capability) {
            try await capability.client.importFile(at: sourceURL, to: folderID)
        }
        return receipt
    }

    private func exportFile(
        _ documentID: UUID,
        format: FilesExportFormat,
        to destinationURL: URL,
        capabilityID: UUID,
        generation: GenerationID
    ) async throws -> FilesDownloadReceipt {
        let capability = try currentFilesCapability(
            capabilityID: capabilityID,
            generation: generation
        )
        let receipt = try await runFilesOperation(capability) {
            try await capability.client.exportDocument(
                documentID,
                format: format,
                to: destinationURL,
                overwrite: true
            )
        }
        return receipt
    }

    private func currentFilesCapability(
        capabilityID: UUID,
        generation: GenerationID
    ) throws -> FilesCapability {
        try validateFilesCapability(
            capabilityID: capabilityID,
            generation: generation
        )
        guard let capability = filesCapability else {
            throw Self.filesUnavailable()
        }
        return capability
    }

    private func runFilesOperation<Output: Sendable>(
        _ capability: FilesCapability,
        operation: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        let capabilityID = capability.id
        let generation = capability.generation
        do {
            return try await capability.operationOwner.run { [weak self] in
                let output = try await operation()
                guard let self else { throw Self.filesUnavailable() }
                try await self.validateFilesCapability(
                    capabilityID: capabilityID,
                    generation: generation
                )
                return output
            }
        } catch is FilesGenerationOperationOwnerError {
            throw Self.filesUnavailable()
        }
    }

    private func validateFilesCapability(
        capabilityID: UUID,
        generation: GenerationID
    ) throws {
        guard activeRouteGeneration == generation,
              routeTransitionReservation != generation,
              !manualConnectionSessionEnded,
              let capability = filesCapability,
              capability.id == capabilityID,
              capability.generation == generation,
              capability.isAttached,
              !capability.isRetiring else {
            throw Self.filesUnavailable()
        }
    }

    private static func filesUnavailable() -> FilesTransferError {
        FilesTransferError(
            .connection,
            "The secure tablet file connection is unavailable."
        )
    }

    private func reserveManualSessionRetirement(generation: GenerationID) {
        guard activeRouteGeneration == generation else { return }
        manualConnectionSessionEnded = true
        manualStep = manualConnectionRecoveryStep()
        routeTransitionReservation = generation
        monitorObservationEpoch.advance()
    }

    private func stopActiveWork() async throws {
        await stopPairingOperation()
        try await stopPairingFinalizationOperation()
        try await stopMonitorAndLifecycle()
    }

    private func stopPairingOperation() async {
        guard let operation = pairingOperation else { return }
        operation.task.cancel()
        await operation.task.value
        if pairingOperation?.id == operation.id {
            pairingOperation = nil
        }
    }

    private func stopPairingFinalizationOperation() async throws {
        guard let operation = pairingFinalizationOperation else { return }
        operation.task.cancel()

        var retirementFailed = false
        do {
            try await processRegistry.retire(generation: operation.generation)
        } catch {
            retirementFailed = true
        }
        await operation.task.value

        guard isPairingFinalizationOperation(
            id: operation.id,
            generation: operation.generation
        ) else {
            if retirementFailed {
                throw OwnedProcessError.retirementFailed
            }
            return
        }
        guard !retirementFailed else {
            // Keep the exact generation reachable for a later retirement
            // retry. Clearing it here would lose process ownership.
            throw OwnedProcessError.retirementFailed
        }
        pairingFinalizationOperation = nil
    }

    private func stopMonitorAndLifecycle() async throws {
        monitorDelayOperation?.task.cancel()
        if let operation = monitorOperation {
            pendingActivationCandidate = nil
            operation.task.cancel()
            await operation.task.value
            if monitorOperation?.id == operation.id {
                monitorOperation = nil
            }
        }
        monitorDelayOperation = nil
        if let lifecycle {
            try await lifecycle.shutdown()
            self.lifecycle = nil
            activeRouteGeneration = nil
            activeRoute = nil
            activeRouteBinding = nil
            activeSSHRoute = nil
            routeTransitionReservation = nil
        }
    }

    private func pauseMonitor(
        for duration: Duration,
        noLaterThan deadline: TimeInterval? = nil
    ) async -> Bool {
        let boundedDuration: Duration
        if let deadline {
            let remaining = max(0, deadline - monitorServices.monotonicNow())
            guard remaining > 0 else { return true }
            boundedDuration = min(
                duration,
                .milliseconds(Int64((remaining * 1_000).rounded(.down)))
            )
        } else {
            boundedDuration = duration
        }
        let operationID = UUID()
        let delayTask = Task<Void, Never> {
            try? await Task.sleep(for: boundedDuration)
        }
        monitorDelayOperation = MonitorDelayOperation(
            id: operationID,
            task: delayTask
        )
        await withTaskCancellationHandler {
            await delayTask.value
        } onCancel: {
            delayTask.cancel()
        }
        if monitorDelayOperation?.id == operationID {
            monitorDelayOperation = nil
        }
        return !Task.isCancelled
    }

    private static func beginsOrContinuesPointerInteraction(
        _ event: TabletInputEvent
    ) -> Bool {
        switch event {
        case .touch(.down), .touch(.move), .pen(.down), .pen(.move): true
        case .touch(.up), .pen(.up), .key, .text, .reset: false
        }
    }

    private static func endsPointerInteraction(
        _ event: TabletInputEvent
    ) -> Bool {
        switch event {
        case .touch(.up), .pen(.up), .reset: true
        case .touch(.down), .touch(.move), .pen(.down), .pen(.move), .key, .text:
            false
        }
    }
}
