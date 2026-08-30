import Foundation

enum MirrorDiagnosticCode: String, Sendable {
    case appStarted = "app_started"
    case profileMissing = "profile_missing"
    case profilePendingApproval = "profile_pending_approval"
    case profileInvalid = "profile_invalid"
    case setupStarted = "setup_started"
    case pairingFailed = "pairing_failed"
    case usbAccessoryApprovalRequired = "usb_accessory_approval_required"
    case usbRouteUnavailable = "usb_c_unavailable"
    case usbRouteUnsafe = "usb_c_connection_not_verified"
    case sshBannerMissing = "ssh_banner_missing"
    case localIdentityPrepared = "local_identity_prepared"
    case hostIdentityPinned = "host_identity_pinned"
    case openSSHUnavailable = "openssh_unavailable"
    case hostIdentityRejected = "host_identity_rejected"
    case authenticationRejected = "authentication_rejected"
    case tabletPrerequisiteMismatch = "tablet_prerequisite_mismatch"
    case capabilityResponseInvalid = "capability_response_invalid"
    case transportAuthenticated = "transport_authenticated"
    case generationCleared = "generation_cleared"
    case inputRestorationUncertain = "input_restoration_uncertain"
    case shutdownComplete = "shutdown_complete"
    case shutdownFailed = "shutdown_failed"
}

actor ConnectionDiagnostics {
    private struct Entry: Sendable {
        let date: Date
        let code: MirrorDiagnosticCode
        let detail: String?
    }

    private static let maximumEntries = 64
    private var entries: [Entry] = []

    func record(_ code: MirrorDiagnosticCode, at date: Date = Date()) {
        append(Entry(date: date, code: code, detail: nil))
    }

    func recordPairingFailure(
        _ retry: TabletPairingFinalizationRetry,
        at date: Date = Date()
    ) {
        append(Entry(
            date: date,
            code: .pairingFailed,
            detail: "stage=\(retry.stage) failure=\(retry.failure)"
        ))
    }

    private func append(_ entry: Entry) {
        entries.append(entry)
        if entries.count > Self.maximumEntries {
            entries.removeFirst(entries.count - Self.maximumEntries)
        }
    }

    func report() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let eventLines = entries.map { entry in
            let detail = entry.detail.map { " \($0)" } ?? ""
            return "\(formatter.string(from: entry.date)) \(entry.code.rawValue)\(detail)"
        }
        return ([
            "reMarkable Mirror diagnostics",
            "Platform: macOS",
            "Build: \(ProductBuild.displayVersion)",
            "Connection milestone: 6",
            "Events:",
        ] + eventLines).joined(separator: "\n")
    }
}
