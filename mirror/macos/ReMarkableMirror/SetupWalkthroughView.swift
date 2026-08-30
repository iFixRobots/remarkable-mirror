import SwiftUI

private struct WalkthroughStep {
    let symbol: String
    let title: String
    let message: String
    var checklist: [String] = []
}

private let walkthroughSteps: [WalkthroughStep] = [
    WalkthroughStep(
        symbol: "externaldrive.badge.checkmark",
        title: "Back up your tablet",
        message: "Mirror copies every document to this Mac before the " +
            "reset erases them.",
        checklist: [
            "On the tablet, turn on Settings > Storage > USB web interface.",
            "Connect the tablet to this Mac with a USB\u{2011}C cable.",
            "Click Back Up Tablet.",
        ]
    ),
    WalkthroughStep(
        symbol: "hammer",
        title: "Enable Developer Mode",
        message: "On the tablet, open Settings > General > Software > Advanced " +
            "and turn on Developer Mode. This factory-resets the tablet."
    ),
    WalkthroughStep(
        symbol: "arrow.clockwise",
        title: "Set the tablet up again",
        message: "Sign in, reconnect Wi\u{2011}Fi, and wait for your documents to " +
            "restore. Skip any software update it offers for now."
    ),
    WalkthroughStep(
        symbol: "lock.open",
        title: "Unlock it once",
        message: "After the tablet restarts, unlock it one time so USB\u{2011}C " +
            "data is available."
    ),
    WalkthroughStep(
        symbol: "network",
        title: "Turn on the USB web interface",
        message: "On the tablet, turn Settings > Storage > USB web " +
            "interface back on. The reset switched it off."
    ),
    WalkthroughStep(
        symbol: "key",
        title: "Find the one-time password",
        message: "It is shown under Settings > General > Help > About > " +
            "Copyrights and Licenses. Mirror asks for it once and never saves it."
    ),
    WalkthroughStep(
        symbol: "cable.connector",
        title: "Connect USB\u{2011}C",
        message: "Plug the tablet directly into this Mac with a data-capable " +
            "USB\u{2011}C cable. Wake it and unlock it, then start setup. " +
            "If the tablet was set up before, Mirror verifies it and " +
            "reinstalls nothing."
    ),
]

private enum BackupPhase: Equatable {
    case idle
    case running(completed: Int, total: Int)
    case finished(count: Int, folder: String)
    case failed(String)
}

struct SetupWalkthroughCard: View {
    let model: AppModel

    @State private var stepIndex = 0
    @State private var backupPhase: BackupPhase = .idle

    private var step: WalkthroughStep { walkthroughSteps[stepIndex] }
    private var isLastStep: Bool { stepIndex == walkthroughSteps.count - 1 }
    private var isBackupStep: Bool { stepIndex == 0 }
    private var backupIsRunning: Bool {
        if case .running = backupPhase { return true }
        return false
    }
    private var backupIsFinished: Bool {
        if case .finished = backupPhase { return true }
        return false
    }

    @ViewBuilder
    private var backupStatus: some View {
        switch backupPhase {
        case .idle:
            EmptyView()
        case let .running(completed, total):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(total > 0
                    ? "Backing up \(completed) of \(total)…"
                    : "Checking the tablet…")
                    .font(.system(size: 12))
                    .foregroundStyle(MirrorPalette.muted)
            }
        case let .finished(count, folder):
            Text("Backed up \(count) document\(count == 1 ? "" : "s") to \(folder).")
                .font(.system(size: 12))
                .foregroundStyle(MirrorPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        case let .failed(message):
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(MirrorPalette.status(.red))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func runBackup() {
        backupPhase = .running(completed: 0, total: 0)
        Task {
            do {
                let result = try await TabletBackupService().backUpAllDocuments { progress in
                    Task { @MainActor in
                        backupPhase = .running(
                            completed: progress.completed,
                            total: progress.total
                        )
                    }
                }
                await MainActor.run {
                    backupPhase = .finished(
                        count: result.count,
                        folder: result.destination.path
                    )
                }
            } catch {
                await MainActor.run {
                    backupPhase = .failed(error.localizedDescription)
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: step.symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(MirrorPalette.ink)
                .frame(width: 42, height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(MirrorPalette.accent.opacity(0.10))
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Step \(stepIndex + 1) of \(walkthroughSteps.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MirrorPalette.muted)

                Text(step.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(MirrorPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text(step.message)
                    .font(.system(size: 14))
                    .foregroundStyle(MirrorPalette.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                if !step.checklist.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(
                            Array(step.checklist.enumerated()),
                            id: \.offset
                        ) { index, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\(index + 1).")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(MirrorPalette.ink)

                                Text(item)
                                    .font(.system(size: 13))
                                    .foregroundStyle(MirrorPalette.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }

            if isBackupStep, backupPhase != .idle {
                backupStatus
            }

            HStack(spacing: 8) {
                if stepIndex > 0 {
                    Button("Back") { stepIndex -= 1 }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Previous setup step")
                }

                Spacer(minLength: 0)

                if isLastStep {
                    Button("Start Setup") {
                        model.performRecoveryAction(.setup)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MirrorPalette.accent)
                    .disabled(!model.recoveryActionIsEnabled(.setup))
                    .accessibilityLabel("Start reMarkable setup")
                } else if isBackupStep, !backupIsFinished {
                    Button("Skip") { stepIndex += 1 }
                        .buttonStyle(.bordered)
                        .disabled(backupIsRunning)
                        .accessibilityLabel("Skip the backup")

                    Button("Back Up Tablet") { runBackup() }
                        .buttonStyle(.borderedProminent)
                        .tint(MirrorPalette.accent)
                        .disabled(backupIsRunning)
                        .accessibilityLabel("Back up the tablet now")
                } else {
                    Button("Continue") { stepIndex += 1 }
                        .buttonStyle(.borderedProminent)
                        .tint(MirrorPalette.accent)
                        .accessibilityLabel("Next setup step")
                }
            }

            if !isLastStep {
                HStack(spacing: 8) {
                    Text("Tablet already prepared?")
                        .font(.system(size: 12))
                        .foregroundStyle(MirrorPalette.muted)

                    Button("Skip Ahead") {
                        stepIndex = walkthroughSteps.count - 1
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Skip to the final setup step")
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(MirrorPalette.paper)
                .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(MirrorPalette.border, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}
