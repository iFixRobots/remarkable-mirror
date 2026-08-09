import Foundation
import Observation

enum MirrorInputMode: String, CaseIterable, Identifiable {
    case touchAndType = "Touch + Type"
    case pen = "Pen"

    var id: Self { self }
}

enum MirrorNoticeSeverity: Equatable, Sendable {
    case success
    case informational
    case warning
    case error

    var duration: Duration {
        switch self {
        case .success:
            .seconds(3)
        case .informational:
            .milliseconds(3_500)
        case .warning:
            .seconds(4)
        case .error:
            .seconds(5)
        }
    }
}

struct MirrorNotice: Equatable, Sendable {
    let message: String
    let severity: MirrorNoticeSeverity
}

struct MirrorToast: Equatable, Identifiable, Sendable {
    let id = UUID()
    let message: String
    let severity: MirrorNoticeSeverity
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let layout: WindowLayout
    @ObservationIgnored let framePresentation: TabletFramePresentation?
    let filesPane = FilesPanePresentation()
    var inputMode: MirrorInputMode = .touchAndType
    var connectionState: ConnectionPresentationState
    private(set) var manualStep: ConnectionManualStep
    var filesReady: Bool
    private(set) var displayedFrameGeneration: GenerationID?
    @ObservationIgnored var filesProgress: Double
    var filesDesiredOpen: Bool
    var filesFullyOpen: Bool
    var toast: MirrorToast?
    var tabletAuthorizationPromptIsPresented = false
    var tabletAuthorizationSubmissionInProgress = false
    private(set) var wifiAddressPromptIsPresented = false
    var wifiAddressInput = ""

    @ObservationIgnored var requestFilesToggle: (() -> Void)?
    @ObservationIgnored var requestFilesPaneVisibilityChange: ((Bool, UInt64) -> Void)?
    @ObservationIgnored var requestLocalSetup: (() async -> Bool)?
    @ObservationIgnored var requestCancelLocalSetup: (() async -> Bool)?
    @ObservationIgnored var requestRetryLocalSetup: (() async -> Bool)?
    @ObservationIgnored var requestResetLocalSetup: (() -> Void)?
    @ObservationIgnored var requestAuthorizeTablet: (() -> Void)?
    @ObservationIgnored var requestCheckTabletAuthorization: (() async -> Bool)?
    @ObservationIgnored var requestRepairUSB: (() async -> Bool)?
    @ObservationIgnored var requestFinishWiFiSetup: (() async -> Bool)?
    @ObservationIgnored var requestConnect: ((ManualConnectionTarget) async -> Bool)?
    @ObservationIgnored var requestCopyDetails: (() -> Void)?
    @ObservationIgnored var requestCopyScreenshot: (() -> Void)?
    @ObservationIgnored var requestSaveScreenshot: (() -> Void)?
    @ObservationIgnored var authorizeTabletWithPassword: ((String) async -> Bool)?
    @ObservationIgnored var reauthorizeUSBWithPassword: ((String) async -> Bool)?
    @ObservationIgnored var requestTabletInput: ((TabletHostInputEvent, GenerationID) -> Void)?
    @ObservationIgnored private var activeGeneration: GenerationID?
    @ObservationIgnored private var latestSnapshotRevision: UInt64 = 0
    @ObservationIgnored private var connectionRequestID: UUID?
    @ObservationIgnored private var filesPaneVisibilityRevision: UInt64 = 0
    private(set) var connectionRequestInFlight = false
    private(set) var connectionRequestRoute: ConnectionRoute?
    private(set) var filesAvailabilityRequestInFlight = false
    @ObservationIgnored private var toastDismissal: Task<Void, Never>?
    @ObservationIgnored private var filesAvailabilityFeedbackTask: Task<Void, Never>?

    private init() {
        layout = .fixed
        framePresentation = try? TabletFramePresentation.makeDefault()
        displayedFrameGeneration = nil
        connectionState = .loadingProfile
        manualStep = .none
        filesReady = false
        filesDesiredOpen = false
        filesProgress = 0
        filesFullyOpen = false
        filesPane.availabilityConfirmed = { [weak self] in
            self?.endFilesAvailabilityFeedback()
        }
    }

    var canSendInput: Bool {
        connectionState.isLive && hasCurrentFrame
    }
    var canCopyScreenshot: Bool {
        guard let activeGeneration else { return false }
        return displayedFrameGeneration == activeGeneration &&
            framePresentation?.hasFrame == true
    }

    var canRetryFilesAvailability: Bool {
        filesDesiredOpen &&
            !filesReady &&
            !filesPane.isAvailable &&
            !filesAvailabilityRequestInFlight &&
            connectionState.isLive
    }

    var hasCurrentFrame: Bool { canCopyScreenshot }

    var canFinishWiFiSetup: Bool {
        guard !connectionRequestInFlight,
              !wifiAddressPromptIsPresented else {
            return false
        }
        guard manualStep == .finishWiFi ||
                manualStep == .connectUSBBeforeWiFi else {
            return false
        }
        return switch connectionState {
        case .awaitingWiFiVerification,
             .readyToConnect,
             .setupWaitingForUSB,
             .setupUnsafeUSBRoute,
             .usbAccessoryApprovalRequired,
             .setupWaitingForWakeAndUnlock,
             .setupAttention,
             .offline,
             .wakeAndUnlock,
             .unlockRequired,
             .sleeping,
             .waking,
             .starting,
             .attention:
            true
        case .transportReady(.usb), .live(.usb):
            true
        default:
            false
        }
    }

    var canAuthorizeTablet: Bool {
        guard manualStep == .authorizeTablet else { return false }
        return switch connectionState {
        case .awaitingTabletAuthorization,
             .setupWaitingForUSB,
             .setupUnsafeUSBRoute,
             .usbAccessoryApprovalRequired:
            true
        default:
            false
        }
    }

    var canReauthorizeUSB: Bool {
        guard manualStep == .reauthorizeUSB else { return false }
        guard case .usbRepairRequired(.keyRejected) = connectionState else {
            return false
        }
        return true
    }

    var authorizationPromptRepairsUSB: Bool {
        manualStep == .reauthorizeUSB
    }

    var displayedConnectionState: ConnectionPresentationState {
        wifiAddressPromptIsPresented ? .readyToConnect : connectionState
    }

    var recoveryCard: RecoveryCardContent? {
        if wifiAddressPromptIsPresented {
            return RecoveryCardContent(
                symbol: "wifi",
                title: "Make sure your reMarkable is awake",
                message: "Press the power button once if needed. It can stay locked. Enter the tablet’s Wi‑Fi IP address.",
                showsProgress: false,
                actions: [.connectEnteredWiFi, .cancelWiFiAddress]
            )
        }
        if connectionState == .setupInProgress {
            let content: RecoveryCardContent
            switch manualStep {
            case .retrySetup:
                content = RecoveryCardContent(
                    symbol: "cable.connector",
                    title: "Checking USB‑C",
                    message: "Checking the direct USB connection once.",
                    showsProgress: true,
                    actions: []
                )
            case .cancelSetup:
                content = RecoveryCardContent(
                    symbol: "xmark.circle",
                    title: "Canceling setup",
                    message: "Stopping the current USB‑C setup safely.",
                    showsProgress: true,
                    actions: []
                )
            case .authorizeTablet:
                content = RecoveryCardContent(
                    symbol: "lock.shield",
                    title: "Authorizing this Mac",
                    message: "Using the password for this attempt only. It is not saved.",
                    showsProgress: true,
                    actions: []
                )
            case .checkTabletAuthorization:
                content = RecoveryCardContent(
                    symbol: "checkmark.shield",
                    title: "Checking authorization",
                    message: "Checking the saved key once over USB‑C.",
                    showsProgress: true,
                    actions: []
                )
            case .repairUSB:
                content = RecoveryCardContent(
                    symbol: "wrench.and.screwdriver",
                    title: "Repairing USB‑C",
                    message: "Checking the saved authorization and restoring USB‑C access once. Wi‑Fi is not being configured.",
                    showsProgress: true,
                    actions: []
                )
            case .reauthorizeUSB:
                content = RecoveryCardContent(
                    symbol: "lock.shield",
                    title: "Authorizing USB‑C",
                    message: "Using the Developer Mode password for this attempt only. It is not saved.",
                    showsProgress: true,
                    actions: []
                )
            case .finishWiFi:
                content = RecoveryCardContent(
                    symbol: "wifi",
                    title: "Finishing Wi‑Fi setup",
                    message: "Checking USB‑C and Wi‑Fi once.",
                    showsProgress: true,
                    actions: []
                )
            case .connectUSBBeforeWiFi, .connectUSB:
                content = RecoveryCardContent(
                    symbol: "ipad.gen2",
                    title: "Waking and connecting",
                    message: "Mirror is waking your reMarkable and opening USB‑C. It will stop if it can’t connect.",
                    showsProgress: true,
                    actions: []
                )
            case .connectWiFi:
                content = RecoveryCardContent(
                    symbol: "wifi",
                    title: "Connecting over Wi‑Fi",
                    message: "Trying your approved Wi‑Fi connection. Mirror will stop if it can’t connect.",
                    showsProgress: true,
                    actions: []
                )
            case .chooseConnection, .none:
                return connectionState.recoveryCard
            }
            return content
        }
        if connectionState == .connecting {
            switch manualStep {
            case .connectUSBBeforeWiFi, .connectUSB:
                return RecoveryCardContent(
                    symbol: "cable.connector",
                    title: "Waking and connecting",
                    message: "Mirror is waking your reMarkable and opening USB‑C. It will stop if it can’t connect.",
                    showsProgress: true,
                    actions: []
                )
            case .connectWiFi:
                return RecoveryCardContent(
                    symbol: "wifi",
                    title: "Connecting over Wi‑Fi",
                    message: "Trying your approved Wi‑Fi connection. Mirror will stop if it can’t connect.",
                    showsProgress: true,
                    actions: []
                )
            default:
                return connectionState.recoveryCard
            }
        }
        if tabletAuthorizationSubmissionInProgress {
            return RecoveryCardContent(
                symbol: "lock.shield",
                title: "Authorizing this Mac",
                message: "Mirror is making one USB authorization attempt. If the result cannot be confirmed, it will stop and ask what to do next.",
                showsProgress: true,
                actions: []
            )
        }

        if (Self.isManualUSBFailure(connectionState) ||
                (isManualConnectionStep &&
                    Self.isManualConnectionFailure(connectionState))),
           let base = connectionState.recoveryCard {
            return base.replacingActions(manualRecoveryActions)
        }
        return connectionState.recoveryCard
    }

    func toggleFiles() {
        guard !tabletAuthorizationPromptIsPresented,
              !tabletAuthorizationSubmissionInProgress else {
            return
        }
        let wasOpen = filesDesiredOpen
        requestFilesToggle?()
        guard filesDesiredOpen != wasOpen else { return }
        if filesDesiredOpen,
           !filesReady,
           !filesPane.isAvailable,
           connectionState.isLive {
            beginFilesAvailabilityFeedback()
        } else if !filesDesiredOpen {
            endFilesAvailabilityFeedback()
        }
        filesPaneVisibilityRevision &+= 1
        requestFilesPaneVisibilityChange?(
            filesDesiredOpen,
            filesPaneVisibilityRevision
        )
    }

    func retryFilesAvailability() {
        guard canRetryFilesAvailability else { return }
        beginFilesAvailabilityFeedback()
        filesPaneVisibilityRevision &+= 1
        requestFilesPaneVisibilityChange?(
            true,
            filesPaneVisibilityRevision
        )
    }

    func connectionRequestIsInFlight(for action: RecoveryAction) -> Bool {
        guard connectionRequestInFlight else { return false }
        return switch (connectionRequestRoute, action) {
        case (.usb, .connectUSB), (.wifi, .connectWiFi): true
        default: false
        }
    }

    func performRecoveryAction(_ action: RecoveryAction) {
        switch action {
        case .setup:
            beginManualSetupOperation(
                step: .retrySetup,
                request: requestLocalSetup
            )
        case .cancelSetup:
            beginManualSetupOperation(
                step: .cancelSetup,
                request: requestCancelLocalSetup
            )
        case .retrySetup:
            beginManualSetupOperation(
                step: .retrySetup,
                request: requestRetryLocalSetup
            )
        case .resetSetup:
            requestResetLocalSetup?()
        case .authorizeTablet:
            requestAuthorizeTablet?()
        case .checkTabletAuthorization:
            beginManualSetupOperation(
                step: .checkTabletAuthorization,
                request: requestCheckTabletAuthorization
            )
        case .repairUSB:
            beginManualSetupOperation(
                step: .repairUSB,
                request: requestRepairUSB
            )
        case .reauthorizeUSB:
            presentTabletAuthorizationPrompt()
        case .connectUSB:
            beginConnectionAttempt(.usb)
        case .connectWiFi:
            if wifiAddressPromptIsPresented {
                guard let host = normalizedWiFiAddress else { return }
                beginConnectionAttempt(.wifi(host: host))
                return
            }
            guard !connectionRequestInFlight,
                  connectionState != .connecting,
                  connectionState != .setupInProgress else {
                return
            }
            wifiAddressInput = ""
            wifiAddressPromptIsPresented = true
        case .cancelWiFiAddress:
            guard !connectionRequestInFlight else { return }
            wifiAddressPromptIsPresented = false
            wifiAddressInput = ""
        }
    }

    func copyConnectionDiagnostics() {
        requestCopyDetails?()
    }

    func copyScreenshot() {
        requestCopyScreenshot?()
    }

    func saveScreenshot() {
        requestSaveScreenshot?()
    }

    func authorizeTablet() {
        requestAuthorizeTablet?()
    }

    func presentTabletAuthorizationPrompt() {
        guard canAuthorizeTablet || canReauthorizeUSB else { return }
        tabletAuthorizationPromptIsPresented = true
    }

    func dismissTabletAuthorizationPrompt() {
        tabletAuthorizationPromptIsPresented = false
    }

    @discardableResult
    func submitTabletAuthorization(password: String) async -> Bool {
        let normalizedPassword = password.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let repairsUSB = canReauthorizeUSB
        guard tabletAuthorizationPromptIsPresented,
              canAuthorizeTablet || repairsUSB,
              !normalizedPassword.isEmpty else {
            return false
        }

        let submit = repairsUSB
            ? reauthorizeUSBWithPassword
            : authorizeTabletWithPassword
        guard let submit else {
            showToast(
                "Tablet authorization isn’t ready yet. Try again.",
                severity: .error
            )
            return false
        }

        let submissionRevision = latestSnapshotRevision
        let accepted = await submit(normalizedPassword)
        guard accepted else {
            if tabletAuthorizationPromptIsPresented,
               (canAuthorizeTablet || canReauthorizeUSB) {
                showToast(
                    "Couldn’t start USB authorization. Try again.",
                    severity: .error
                )
            }
            return false
        }

        // The coordinator may publish a newer result while the request crosses
        // actors. Never let this older continuation overwrite that state with
        // the progress-only authorization card.
        guard latestSnapshotRevision == submissionRevision,
              tabletAuthorizationPromptIsPresented,
              (canAuthorizeTablet || canReauthorizeUSB) else {
            return true
        }
        tabletAuthorizationPromptIsPresented = false
        tabletAuthorizationSubmissionInProgress = true
        return true
    }

    func finishWiFiSetup() {
        guard canFinishWiFiSetup else { return }
        beginManualSetupOperation(
            step: .finishWiFi,
            request: requestFinishWiFiSetup
        )
    }

    private func beginManualSetupOperation(
        step: ConnectionManualStep,
        request: (() async -> Bool)?
    ) {
        guard connectionState != .setupInProgress,
              connectionState != .connecting,
              !connectionRequestInFlight,
              let request else {
            return
        }
        let previousState = connectionState
        let previousStep = manualStep
        let requestRevision = latestSnapshotRevision
        manualStep = step
        connectionState = .setupInProgress
        Task { @MainActor [weak self] in
            let accepted = await request()
            guard !accepted,
                  let self,
                  self.latestSnapshotRevision == requestRevision,
                  self.connectionState == .setupInProgress,
                  self.manualStep == step else {
                return
            }
            self.manualStep = previousStep
            self.connectionState = previousState
            self.showToast(
                "Another Mirror action is already in progress.",
                severity: .warning
            )
        }
    }

    var canSubmitWiFiAddress: Bool {
        normalizedWiFiAddress != nil
    }

    func recoveryActionIsEnabled(_ action: RecoveryAction) -> Bool {
        guard !connectionRequestInFlight else { return false }
        if action == .connectWiFi, wifiAddressPromptIsPresented {
            return canSubmitWiFiAddress
        }
        return true
    }

    private var normalizedWiFiAddress: String? {
        let value = wifiAddressInput.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return TabletWiFiPairingProbe.isGlobalIPv4Host(value)
            ? value
            : nil
    }

    private func beginConnectionAttempt(_ target: ManualConnectionTarget) {
        let route = target.route
        guard connectionState != .connecting,
              connectionState != .setupInProgress,
              connectionRequestID == nil,
              let requestConnect else {
            return
        }
        let requestID = UUID()
        let requestRevision = latestSnapshotRevision
        let previousState = connectionState
        let previousStep = manualStep
        connectionRequestID = requestID
        connectionRequestInFlight = true
        connectionRequestRoute = route

        Task { @MainActor [weak self] in
            let accepted = await requestConnect(target)
            guard let self, self.connectionRequestID == requestID else { return }
            guard !accepted else { return }
            self.connectionRequestID = nil
            self.connectionRequestInFlight = false
            self.connectionRequestRoute = nil
            if route == .wifi {
                self.wifiAddressPromptIsPresented = false
            }
            guard
                  self.latestSnapshotRevision == requestRevision,
                  self.connectionState == previousState,
                  self.manualStep == previousStep else {
                return
            }
            self.showToast(
                "Another Mirror action is already in progress.",
                severity: .warning
            )
        }
    }

    func sendTabletInput(_ event: TabletHostInputEvent) {
        guard canSendInput, let activeGeneration else { return }
        requestTabletInput?(event, activeGeneration)
    }

    @discardableResult
    func attachFilesService(
        _ service: FilesPaneService,
        generation: GenerationID
    ) -> Bool {
        guard activeGeneration == generation else { return false }
        filesPane.attach(service, automaticallyRefresh: false)
        return true
    }

    func detachFilesService() {
        filesReady = false
        filesPane.detach()
    }

    @discardableResult
    func apply(_ snapshot: ConnectionSnapshot) -> Bool {
        guard snapshot.revision > latestSnapshotRevision else {
            return false
        }

        switch snapshot.admission {
        case .application:
            guard snapshot.generation == nil else { return false }
            filesPane.detach()
            resetFramePresentation()
            activeGeneration = nil
        case .clearGeneration:
            guard snapshot.generation == nil else { return false }
            filesPane.detach()
            resetFramePresentation()
            activeGeneration = nil
        case .activateGeneration:
            guard let generation = snapshot.generation else { return false }
            filesPane.detach()
            resetFramePresentation()
            activeGeneration = generation
        case .generationEvent:
            guard snapshot.generation == activeGeneration,
                  snapshot.generation != nil else {
                return false
            }
            if snapshot.frameGeneration != activeGeneration {
                resetFramePresentation()
            }
        }

        latestSnapshotRevision = snapshot.revision
        if wifiAddressPromptIsPresented {
            wifiAddressPromptIsPresented = false
            wifiAddressInput = ""
        }
        if connectionRequestID != nil {
            connectionRequestID = nil
            connectionRequestInFlight = false
            connectionRequestRoute = nil
        }
        let nextConnectionState = ConnectionPublicationGate.presentation(for: snapshot)
        connectionState = nextConnectionState
        if nextConnectionState != .setupInProgress {
            tabletAuthorizationSubmissionInProgress = false
        }
        if nextConnectionState != .awaitingTabletAuthorization {
            tabletAuthorizationPromptIsPresented = false
        }
        manualStep = snapshot.manualStep
        filesReady = snapshot.filesReady
        if !nextConnectionState.isLive {
            endFilesAvailabilityFeedback()
        }
        return true
    }

    @discardableResult
    func applyFrame(
        _ update: RMM1FrameUpdate,
        generation: GenerationID
    ) throws -> Bool {
        guard generation == activeGeneration,
              let framePresentation else {
            return false
        }
        try framePresentation.apply(update)
        displayedFrameGeneration = generation
        return true
    }

    func currentFrameSnapshot() throws -> TabletFrameSnapshot? {
        guard canCopyScreenshot, let framePresentation else { return nil }
        return try framePresentation.snapshot()
    }

    func showToast(
        _ message: String,
        severity: MirrorNoticeSeverity = .informational
    ) {
        toastDismissal?.cancel()
        let nextToast = MirrorToast(message: message, severity: severity)
        toast = nextToast

        toastDismissal = Task { [weak self] in
            try? await Task.sleep(for: severity.duration)
            guard !Task.isCancelled else { return }
            self?.dismissToast(ifCurrent: nextToast.id)
        }
    }

    func dismissToast(ifCurrent id: UUID) {
        guard toast?.id == id else { return }
        toast = nil
    }

    private func resetFramePresentation() {
        displayedFrameGeneration = nil
        framePresentation?.reset()
    }

    private func beginFilesAvailabilityFeedback() {
        filesAvailabilityFeedbackTask?.cancel()
        filesAvailabilityRequestInFlight = true
        filesAvailabilityFeedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            self?.filesAvailabilityRequestInFlight = false
            self?.filesAvailabilityFeedbackTask = nil
        }
    }

    private func endFilesAvailabilityFeedback() {
        filesAvailabilityFeedbackTask?.cancel()
        filesAvailabilityFeedbackTask = nil
        filesAvailabilityRequestInFlight = false
    }

    private var manualRecoveryActions: [RecoveryCardAction] {
        switch manualStep {
        case .retrySetup:
            [.retrySetup, .cancelSetup]
        case .cancelSetup:
            []
        case .authorizeTablet:
            [.authorizeTablet]
        case .checkTabletAuthorization:
            [.checkTabletAuthorization]
        case .repairUSB:
            [.repairUSB]
        case .reauthorizeUSB:
            [.reauthorizeUSB]
        case .finishWiFi:
            [.connectUSB]
        case .connectUSBBeforeWiFi, .chooseConnection, .connectUSB, .connectWiFi:
            [.connectUSB, .connectWiFi]
        case .none:
            []
        }
    }

    private var isManualConnectionStep: Bool {
        switch manualStep {
        case .connectUSBBeforeWiFi, .chooseConnection, .connectUSB, .connectWiFi:
            true
        default:
            false
        }
    }

    private static func isManualUSBFailure(
        _ state: ConnectionPresentationState
    ) -> Bool {
        switch state {
        case .setupRetrying,
             .setupWaitingForUSB,
             .setupUnsafeUSBRoute,
             .usbAccessoryApprovalRequired,
             .setupWaitingForWakeAndUnlock,
             .setupAttention:
            true
        default:
            false
        }
    }

    private static func isManualConnectionFailure(
        _ state: ConnectionPresentationState
    ) -> Bool {
        switch state {
        case .offline,
             .wakeAndUnlock,
             .unlockRequired,
             .sleeping,
             .waking,
             .starting,
             .attention:
            true
        default:
            false
        }
    }

}
