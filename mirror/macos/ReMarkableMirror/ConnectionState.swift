import Foundation

enum StatusTone: Sendable {
    case green
    case gray
    case amber
    case red
}

enum RecoveryAction: String, Hashable, Sendable {
    case setup
    case cancelSetup
    case retrySetup
    case resetSetup
    case authorizeTablet
    case checkTabletAuthorization
    case repairUSB
    case reauthorizeUSB
    case connectUSB
    case connectWiFi
}

struct RecoveryCardAction: Equatable, Identifiable, Sendable {
    let action: RecoveryAction
    let label: String
    let accessibilityLabel: String
    let isPrimary: Bool

    var id: RecoveryAction { action }

    static let setup = RecoveryCardAction(
        action: .setup,
        label: "Set Up",
        accessibilityLabel: "Set up this Mac",
        isPrimary: true
    )
    static let cancelSetup = RecoveryCardAction(
        action: .cancelSetup,
        label: "Cancel",
        accessibilityLabel: "Cancel Mac setup",
        isPrimary: false
    )
    static let retrySetup = RecoveryCardAction(
        action: .retrySetup,
        label: "Retry Setup",
        accessibilityLabel: "Retry Mac setup",
        isPrimary: true
    )
    static let resetSetup = RecoveryCardAction(
        action: .resetSetup,
        label: "Set Up Again…",
        accessibilityLabel: "Reset and set up this Mac again",
        isPrimary: true
    )
    static let authorizeTablet = RecoveryCardAction(
        action: .authorizeTablet,
        label: "Add This Mac…",
        accessibilityLabel: "Add this Mac to your reMarkable",
        isPrimary: true
    )
    static let checkTabletAuthorization = RecoveryCardAction(
        action: .checkTabletAuthorization,
        label: "Check Authorization",
        accessibilityLabel: "Check tablet authorization",
        isPrimary: true
    )
    static let repairUSB = RecoveryCardAction(
        action: .repairUSB,
        label: "Repair USB‑C",
        accessibilityLabel: "Repair USB‑C connection",
        isPrimary: true
    )
    static let reauthorizeUSB = RecoveryCardAction(
        action: .reauthorizeUSB,
        label: "Authorize USB‑C Again…",
        accessibilityLabel: "Authorize USB‑C again",
        isPrimary: true
    )
    static let connectUSB = RecoveryCardAction(
        action: .connectUSB,
        label: "Connect USB‑C",
        accessibilityLabel: "Connect to your reMarkable over USB‑C",
        isPrimary: true
    )
    static let connectWiFi = RecoveryCardAction(
        action: .connectWiFi,
        label: "Connect Wi‑Fi",
        accessibilityLabel: "Connect to your reMarkable over Wi‑Fi",
        isPrimary: false
    )
}

struct RecoveryCardContent: Equatable, Sendable {
    let symbol: String
    let title: String
    let message: String
    let showsProgress: Bool
    let actions: [RecoveryCardAction]

    init(
        symbol: String,
        title: String,
        message: String,
        showsProgress: Bool,
        showsActions: Bool
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.showsProgress = showsProgress
        self.actions = showsActions
            ? [.connectUSB, .connectWiFi]
            : []
    }

    init(
        symbol: String,
        title: String,
        message: String,
        showsProgress: Bool,
        actions: [RecoveryCardAction]
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.showsProgress = showsProgress
        self.actions = actions
    }

    func replacingActions(
        _ actions: [RecoveryCardAction]
    ) -> RecoveryCardContent {
        RecoveryCardContent(
            symbol: symbol,
            title: title,
            message: message,
            showsProgress: showsProgress,
            actions: actions
        )
    }
}

enum USBRepairReason: Equatable, Sendable {
    case keyRejected
    case secureTransportUnavailable
    case authorizationUncertain
}

enum ConnectionPresentationState: Equatable, Sendable {
    case loadingProfile
    case setupRequired
    case setupInProgress
    case setupRetrying
    case setupWaitingForUSB
    case setupUnsafeUSBRoute
    case usbAccessoryApprovalRequired
    case setupWaitingForWakeAndUnlock
    case setupAttention
    case awaitingTabletAuthorization
    case awaitingTabletAuthorizationCheck
    case awaitingWiFiVerification
    case usbRepairRequired(USBRepairReason)
    case profileAttention
    case readyToConnect
    case offline
    case wakeAndUnlock
    case unlockRequired
    case sleeping
    case waking
    case starting
    case connecting
    case transportReady(ConnectionRoute)
    case attention
    case repair
    case live(ConnectionRoute)

    var isLive: Bool {
        if case .live = self { return true }
        return false
    }

    var statusText: String {
        switch self {
        case .loadingProfile: "Checking"
        case .setupRequired, .setupInProgress, .setupRetrying, .setupWaitingForUSB,
             .setupWaitingForWakeAndUnlock, .awaitingTabletAuthorization,
             .awaitingTabletAuthorizationCheck: "Setup"
        case .setupUnsafeUSBRoute: "USB needed"
        case .usbAccessoryApprovalRequired: "USB blocked"
        case .connecting: "Connecting"
        case .transportReady: "Preparing"
        case .setupAttention, .profileAttention, .attention: "Attention"
        case .awaitingWiFiVerification, .readyToConnect, .offline: "Disconnected"
        case .usbRepairRequired: "USB repair"
        case .wakeAndUnlock: "Waiting"
        case .unlockRequired: "Unlock"
        case .sleeping: "Sleeping"
        case .waking: "Waking"
        case .starting: "Starting"
        case .repair: "Repair"
        case let .live(route): route == .usb ? "Live over USB‑C" : "Live over Wi‑Fi"
        }
    }

    var tone: StatusTone {
        switch self {
        case .live: .green
        case .loadingProfile, .offline, .wakeAndUnlock, .unlockRequired, .sleeping,
             .starting, .setupRequired, .setupWaitingForUSB, .readyToConnect,
             .setupWaitingForWakeAndUnlock, .awaitingWiFiVerification:
            .gray
        case .setupInProgress, .setupRetrying, .setupUnsafeUSBRoute,
             .usbAccessoryApprovalRequired, .awaitingTabletAuthorization,
             .awaitingTabletAuthorizationCheck,
             .waking, .connecting, .transportReady:
            .amber
        case .usbRepairRequired:
            .amber
        case .setupAttention, .profileAttention, .attention, .repair:
            .red
        }
    }

    var recoveryCard: RecoveryCardContent? {
        switch self {
        case .live:
            nil
        case .loadingProfile:
            RecoveryCardContent(
                symbol: "laptopcomputer",
                title: "Checking this Mac",
                message: "Loading your saved connection.",
                showsProgress: true,
                showsActions: false
            )
        case .setupRequired:
            RecoveryCardContent(
                symbol: "laptopcomputer.and.arrow.down",
                title: "Set up this Mac",
                message: "Connect your reMarkable with USB‑C and unlock it.",
                showsProgress: false,
                actions: [.setup]
            )
        case .setupInProgress:
            RecoveryCardContent(
                symbol: "lock.shield",
                title: "Setting up this Mac",
                message: "Checking the tablet through USB‑C once. Keep it connected and unlocked.",
                showsProgress: true,
                showsActions: false
            )
        case .setupRetrying:
            RecoveryCardContent(
                symbol: "arrow.clockwise",
                title: "USB setup paused",
                message: "The last USB check did not finish. Check the cable and tablet, then try again.",
                showsProgress: false,
                actions: [.retrySetup, .cancelSetup]
            )
        case .setupWaitingForUSB:
            RecoveryCardContent(
                symbol: "cable.connector",
                title: "USB‑C isn’t connected",
                message: "Connect the tablet with a data-capable USB‑C cable, unlock it, then try again.",
                showsProgress: false,
                actions: [.retrySetup, .cancelSetup]
            )
        case .setupUnsafeUSBRoute:
            RecoveryCardContent(
                symbol: "exclamationmark.arrow.triangle.2.circlepath",
                title: "USB‑C couldn’t verify the tablet",
                message: "Mirror couldn’t confirm the tablet through this USB‑C cable. Reconnect it directly to the Mac, then try again.",
                showsProgress: false,
                actions: [.retrySetup, .cancelSetup]
            )
        case .usbAccessoryApprovalRequired:
            RecoveryCardContent(
                symbol: "lock.open",
                title: "USB‑C data isn’t available",
                message: "Keep both devices unlocked, reconnect the data-capable USB‑C cable directly, then try again.",
                showsProgress: false,
                actions: [.retrySetup]
            )
        case .setupWaitingForWakeAndUnlock:
            RecoveryCardContent(
                symbol: "power",
                title: "Tablet not ready",
                message: "Keep USB‑C connected, unlock the tablet, then try again.",
                showsProgress: false,
                actions: [.retrySetup, .cancelSetup]
            )
        case .setupAttention:
            RecoveryCardContent(
                symbol: "exclamationmark.triangle",
                title: "Setup couldn’t finish",
                message: "Nothing changed on the tablet. Keep it unlocked and connected with USB‑C, then retry.",
                showsProgress: false,
                actions: [.retrySetup]
            )
        case .awaitingTabletAuthorization:
            RecoveryCardContent(
                symbol: "checkmark.shield",
                title: "Add this Mac to your reMarkable",
                message: "Choose Add This Mac to add this Mac’s access key and install USB keep-awake. Wi‑Fi setup is a separate step.",
                showsProgress: false,
                actions: [.authorizeTablet]
            )
        case .awaitingTabletAuthorizationCheck:
            RecoveryCardContent(
                symbol: "checkmark.shield",
                title: "Check tablet authorization",
                message: "Setup may already have added this Mac. Keep USB‑C connected and check before entering the password again.",
                showsProgress: false,
                actions: [.checkTabletAuthorization]
            )
        case .awaitingWiFiVerification:
            RecoveryCardContent(
                symbol: "cable.connector",
                title: "Connect your reMarkable",
                message: "Connect the tablet to this Mac with USB‑C, then choose Connect USB‑C.",
                showsProgress: false,
                actions: [.connectUSB]
            )
        case let .usbRepairRequired(reason):
            switch reason {
            case .keyRejected:
                RecoveryCardContent(
                    symbol: "lock.shield",
                    title: "Tablet authorization is required",
                    message: "The tablet rejected this Mac’s saved USB‑C authorization. Authorize USB‑C again with the Developer Mode password.",
                    showsProgress: false,
                    actions: [.reauthorizeUSB]
                )
            case .secureTransportUnavailable:
                RecoveryCardContent(
                    symbol: "cable.connector",
                    title: "USB‑C couldn’t reach the tablet",
                    message: "Mirror couldn’t restore USB‑C access during this attempt. Reconnect USB‑C, unlock the tablet if it shows a passcode, then choose Repair USB‑C again.",
                    showsProgress: false,
                    actions: [.repairUSB]
                )
            case .authorizationUncertain:
                RecoveryCardContent(
                    symbol: "checkmark.shield",
                    title: "Authorization was not confirmed",
                    message: "Repair USB‑C will check the saved key once before asking for the password again.",
                    showsProgress: false,
                    actions: [.repairUSB]
                )
            }
        case .profileAttention:
            RecoveryCardContent(
                symbol: "exclamationmark.shield",
                title: "Saved setup can’t be used",
                message: "Mirror can’t safely use this Mac’s saved setup. Set up again to replace only the local copy.",
                showsProgress: false,
                actions: [.resetSetup]
            )
        case .readyToConnect:
            RecoveryCardContent(
                symbol: "ipad.gen2",
                title: "Connect to your reMarkable",
                message: "Choose USB‑C or Wi‑Fi. Mirror will handle waking the tablet during a USB‑C connection.",
                showsProgress: false,
                actions: [.connectUSB, .connectWiFi]
            )
        case .offline:
            RecoveryCardContent(
                symbol: "power",
                title: "Couldn’t connect",
                message: "Choose USB‑C or Wi‑Fi to try the connection again.",
                showsProgress: false,
                actions: [.connectUSB, .connectWiFi]
            )
        case .wakeAndUnlock:
            RecoveryCardContent(
                symbol: "power",
                title: "The tablet needs attention",
                message: "Mirror couldn’t complete the connection. If the tablet shows a passcode, unlock it, then try again.",
                showsProgress: false,
                actions: [.connectUSB, .connectWiFi]
            )
        case .unlockRequired:
            RecoveryCardContent(
                symbol: "lock.open",
                title: "Unlock your reMarkable",
                message: "Enter your passcode on the tablet, then choose the connection again.",
                showsProgress: false,
                actions: [.connectUSB, .connectWiFi]
            )
        case .sleeping:
            RecoveryCardContent(
                symbol: "sun.max",
                title: "Mirror couldn’t wake the tablet",
                message: "Reconnect USB‑C, then choose Connect USB‑C to try the wake-and-connect session again.",
                showsProgress: false,
                actions: [.connectUSB]
            )
        case .waking:
            RecoveryCardContent(
                symbol: "sun.max",
                title: "The tablet did not finish waking",
                message: "Reconnect USB‑C, then choose Connect USB‑C to try again.",
                showsProgress: false,
                actions: [.connectUSB]
            )
        case .starting:
            RecoveryCardContent(
                symbol: "rectangle.stack.badge.play",
                title: "The tablet did not finish starting",
                message: "Reconnect USB‑C, then choose Connect USB‑C to try again.",
                showsProgress: false,
                actions: [.connectUSB]
            )
        case .connecting:
            RecoveryCardContent(
                symbol: "ipad.gen2",
                title: "Connecting",
                message: "Opening the connection you selected.",
                showsProgress: true,
                showsActions: false
            )
        case .transportReady:
            RecoveryCardContent(
                symbol: "checkmark.shield",
                title: "Secure connection ready",
                message: "The tablet is authenticated. Screen sharing and controls aren’t available yet.",
                showsProgress: true,
                showsActions: false
            )
        case .attention:
            RecoveryCardContent(
                symbol: "exclamationmark.triangle",
                title: "Connection couldn’t open",
                message: "Mirror stopped this attempt. Choose the connection you want to try again.",
                showsProgress: false,
                showsActions: true
            )
        case .repair:
            RecoveryCardContent(
                symbol: "wrench.and.screwdriver",
                title: "Setup needs attention",
                message: "Mirror couldn’t verify the saved tablet identity or required tablet components. Set up this Mac again to repair the connection.",
                showsProgress: false,
                actions: [.resetSetup]
            )
        }
    }
}

enum ConnectionEvidence: Equatable, Sendable {
    case loadingProfile
    case setupRequired
    case setupInProgress
    case setupRetrying
    case setupWaitingForUSB
    case setupUnsafeUSBRoute
    case usbAccessoryApprovalRequired
    case setupWaitingForWakeAndUnlock
    case setupAttention
    case awaitingTabletAuthorization
    case awaitingTabletAuthorizationCheck
    case awaitingWiFiVerification
    case usbRepairRequired(USBRepairReason)
    case profileAttention
    case readyToConnect
    case offline
    case wakeAndUnlock
    case unlockRequired
    case sleeping
    case waking
    case starting
    case connecting
    case transportReady(ConnectionRoute)
    case attention
    case repair
}

enum ConnectionSnapshotAdmission: Equatable, Sendable {
    case application
    case clearGeneration
    case activateGeneration
    case generationEvent
}

enum ConnectionManualStep: Equatable, Sendable {
    case none
    case retrySetup
    case cancelSetup
    case authorizeTablet
    case checkTabletAuthorization
    case repairUSB
    case reauthorizeUSB
    case finishWiFi
    case chooseConnection
    case connectUSBBeforeWiFi
    case connectUSB
    case connectWiFi
}

struct ConnectionSnapshot: Equatable, Sendable {
    let revision: UInt64
    let admission: ConnectionSnapshotAdmission
    let generation: GenerationID?
    let evidence: ConnectionEvidence
    let frameGeneration: GenerationID?
    let inputGeneration: GenerationID?
    let filesReady: Bool
    let manualStep: ConnectionManualStep

    init(
        revision: UInt64,
        admission: ConnectionSnapshotAdmission,
        generation: GenerationID?,
        evidence: ConnectionEvidence,
        frameGeneration: GenerationID?,
        inputGeneration: GenerationID?,
        filesReady: Bool,
        manualStep: ConnectionManualStep = .none
    ) {
        self.revision = revision
        self.admission = admission
        self.generation = generation
        self.evidence = evidence
        self.frameGeneration = frameGeneration
        self.inputGeneration = inputGeneration
        self.filesReady = filesReady
        self.manualStep = manualStep
    }

    static func activation(
        revision: UInt64,
        generation: GenerationID,
        evidence: ConnectionEvidence,
        filesReady: Bool = false,
        manualStep: ConnectionManualStep = .none
    ) -> ConnectionSnapshot {
        ConnectionSnapshot(
            revision: revision,
            admission: .activateGeneration,
            generation: generation,
            evidence: evidence,
            frameGeneration: nil,
            inputGeneration: nil,
            filesReady: filesReady,
            manualStep: manualStep
        )
    }
}

enum ConnectionPublicationGate {
    static func presentation(for snapshot: ConnectionSnapshot) -> ConnectionPresentationState {
        if case let .transportReady(route) = snapshot.evidence,
           let generation = snapshot.generation,
           snapshot.frameGeneration == generation,
           snapshot.inputGeneration == generation {
            return .live(route)
        }

        return switch snapshot.evidence {
        case .loadingProfile: .loadingProfile
        case .setupRequired: .setupRequired
        case .setupInProgress: .setupInProgress
        case .setupRetrying: .setupRetrying
        case .setupWaitingForUSB: .setupWaitingForUSB
        case .setupUnsafeUSBRoute: .setupUnsafeUSBRoute
        case .usbAccessoryApprovalRequired: .usbAccessoryApprovalRequired
        case .setupWaitingForWakeAndUnlock: .setupWaitingForWakeAndUnlock
        case .setupAttention: .setupAttention
        case .awaitingTabletAuthorization: .awaitingTabletAuthorization
        case .awaitingTabletAuthorizationCheck: .awaitingTabletAuthorizationCheck
        case .awaitingWiFiVerification: .awaitingWiFiVerification
        case let .usbRepairRequired(reason): .usbRepairRequired(reason)
        case .profileAttention: .profileAttention
        case .readyToConnect: .readyToConnect
        case .offline: .offline
        case .wakeAndUnlock: .wakeAndUnlock
        case .unlockRequired: .unlockRequired
        case .sleeping: .sleeping
        case .waking: .waking
        case .starting: .starting
        case .connecting: .connecting
        case let .transportReady(route): .transportReady(route)
        case .attention: .attention
        case .repair: .repair
        }
    }
}
