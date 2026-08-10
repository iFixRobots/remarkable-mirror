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
    case finishWiFiSetup
    case repairUSB
    case reauthorizeUSB
    case connectUSB
    case connectWiFi
    case cancelWiFiAddress
}

struct RecoveryCardAction: Equatable, Identifiable, Sendable {
    let action: RecoveryAction
    let label: String
    let accessibilityLabel: String
    let isPrimary: Bool

    var id: RecoveryAction { action }

    static let setup = RecoveryCardAction(
        action: .setup,
        label: "Start Setup",
        accessibilityLabel: "Start reMarkable setup",
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
        label: "Continue Setup",
        accessibilityLabel: "Continue reMarkable setup",
        isPrimary: true
    )
    static let checkTabletAuthorization = RecoveryCardAction(
        action: .checkTabletAuthorization,
        label: "Continue Tablet Setup",
        accessibilityLabel: "Continue tablet setup over USB-C",
        isPrimary: true
    )
    static let retryTabletSetup = RecoveryCardAction(
        action: .checkTabletAuthorization,
        label: "Retry Tablet Setup",
        accessibilityLabel: "Retry tablet setup over USB-C",
        isPrimary: true
    )
    static let finishWiFiSetup = RecoveryCardAction(
        action: .finishWiFiSetup,
        label: "Continue Setup",
        accessibilityLabel: "Continue reMarkable setup over USB-C",
        isPrimary: true
    )
    static let repairUSB = RecoveryCardAction(
        action: .repairUSB,
        label: "Repair Tablet Setup",
        accessibilityLabel: "Repair tablet setup over USB‑C",
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
        accessibilityLabel: "Connect to your reMarkable via Wi‑Fi",
        isPrimary: false
    )
    static let connectEnteredWiFi = RecoveryCardAction(
        action: .connectWiFi,
        label: "Connect Wi‑Fi",
        accessibilityLabel: "Connect to the entered tablet IP address via Wi‑Fi",
        isPrimary: true
    )
    static let cancelWiFiAddress = RecoveryCardAction(
        action: .cancelWiFiAddress,
        label: "Cancel",
        accessibilityLabel: "Cancel Wi‑Fi connection",
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
    case prerequisiteInstallFailed(String)
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
    case setupPackageAttention(String)
    case xoviAttention
    case tabletInstallAttention(String)
    case awaitingTabletAuthorization
    case awaitingTabletAuthorizationCheck(String?)
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
             .awaitingTabletAuthorizationCheck, .awaitingWiFiVerification: "Setup"
        case .setupUnsafeUSBRoute: "USB needed"
        case .usbAccessoryApprovalRequired: "USB blocked"
        case .connecting: "Connecting"
        case .transportReady: "Preparing"
        case .setupAttention, .setupPackageAttention, .xoviAttention,
             .tabletInstallAttention,
             .profileAttention,
             .attention: "Attention"
        case .readyToConnect, .offline: "Disconnected"
        case .usbRepairRequired: "Setup repair"
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
        case .setupAttention, .setupPackageAttention, .xoviAttention,
             .tabletInstallAttention,
             .profileAttention, .attention, .repair:
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
                title: "Set up your reMarkable",
                message: "First back up your tablet, enable Developer Mode, sign in again, reconnect Wi‑Fi, unlock once, and turn on the USB web interface. Then connect USB‑C and Mirror will handle the rest.",
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
        case let .setupPackageAttention(failureDescription):
            RecoveryCardContent(
                symbol: "exclamationmark.triangle",
                title: "Tablet setup can't run",
                message: "Mirror stopped while \(failureDescription). Quit Mirror and install a complete build before trying again.",
                showsProgress: false,
                actions: []
            )
        case .xoviAttention:
            RecoveryCardContent(
                symbol: "exclamationmark.triangle",
                title: "Existing Xovi setup needs attention",
                message: "Mirror found an unknown or incompatible Xovi installation and did not overwrite it. Reconcile that owner-managed setup before trying again.",
                showsProgress: false,
                actions: []
            )
        case let .tabletInstallAttention(failureDescription):
            RecoveryCardContent(
                symbol: "exclamationmark.triangle",
                title: "Existing tablet setup needs attention",
                message: "Mirror stopped while \(failureDescription) and did not replace the unsafe path. Reconcile that existing tablet setup before trying again.",
                showsProgress: false,
                actions: []
            )
        case .awaitingTabletAuthorization:
            RecoveryCardContent(
                symbol: "checkmark.shield",
                title: "Ready to authorize and install",
                message: "Continue setup to authorize this Mac and install the pinned Mirror tablet components.",
                showsProgress: false,
                actions: [.authorizeTablet]
            )
        case let .awaitingTabletAuthorizationCheck(failureDescription):
            if let failureDescription {
                RecoveryCardContent(
                    symbol: "wrench.and.screwdriver",
                    title: "Tablet setup couldn't finish",
                    message: "Mirror stopped while \(failureDescription). Keep USB-C connected, then retry without entering the password again.",
                    showsProgress: false,
                    actions: [.retryTabletSetup]
                )
            } else {
                RecoveryCardContent(
                    symbol: "checkmark.shield",
                    title: "Continue tablet setup",
                    message: "Mirror will check the saved key, then install or verify the pinned tablet components over USB-C. It will not ask for the password again.",
                    showsProgress: false,
                    actions: [.checkTabletAuthorization]
                )
            }
        case .awaitingWiFiVerification:
            RecoveryCardContent(
                symbol: "wifi",
                title: "Finish setting up your reMarkable",
                message: "Keep USB‑C connected. Mirror will finish and verify secure Wi‑Fi access, then return to the connection chooser.",
                showsProgress: false,
                actions: [.finishWiFiSetup]
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
                    title: "Tablet setup needs repair",
                    message: "Reconnect USB‑C, unlock the tablet if it shows a passcode, then choose Repair Tablet Setup again.",
                    showsProgress: false,
                    actions: [.repairUSB]
                )
            case .authorizationUncertain:
                RecoveryCardContent(
                    symbol: "checkmark.shield",
                    title: "Authorization was not confirmed",
                    message: "Repair Tablet Setup will check the saved key once before asking for the password again.",
                    showsProgress: false,
                    actions: [.repairUSB]
                )
            case let .prerequisiteInstallFailed(failureDescription):
                RecoveryCardContent(
                    symbol: "wrench.and.screwdriver",
                    title: "Tablet setup couldn't finish",
                    message: "Mirror stopped while \(failureDescription). Keep USB-C connected, then choose Repair Tablet Setup to retry safely.",
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
                title: "Tablet setup needs repair",
                message: "Connect the tablet directly over USB‑C, unlock it if needed, then repair the pinned Mirror components. Wi‑Fi is not changed.",
                showsProgress: false,
                actions: [.repairUSB]
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
    case setupPackageAttention(String)
    case xoviAttention
    case tabletInstallAttention(String)
    case awaitingTabletAuthorization
    case awaitingTabletAuthorizationCheck(String?)
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
        case let .setupPackageAttention(failureDescription):
            .setupPackageAttention(failureDescription)
        case .xoviAttention: .xoviAttention
        case let .tabletInstallAttention(failureDescription):
            .tabletInstallAttention(failureDescription)
        case .awaitingTabletAuthorization: .awaitingTabletAuthorization
        case let .awaitingTabletAuthorizationCheck(failureDescription):
            .awaitingTabletAuthorizationCheck(failureDescription)
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
