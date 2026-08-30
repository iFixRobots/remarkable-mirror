import AppKit
import SwiftUI

@main
struct ReMarkableMirrorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) { }

            CommandMenu("Connection") {
                Button("Set Up Wi‑Fi…") {
                    model.finishWiFiSetup()
                }
                .disabled(!model.canFinishWiFiSetup)

                Divider()

                Button("Restore Backup…") {
                    restoreBackup()
                }

                Button("Set Up Again…") {
                    model.performRecoveryAction(.resetSetup)
                }
                .disabled(!model.recoveryActionIsEnabled(.resetSetup))
            }

            CommandGroup(replacing: .appInfo) {
                Button("About reMarkable Mirror") {
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [
                            .applicationName: "reMarkable Mirror",
                            .applicationVersion: ProductBuild.displayVersion,
                            .credits: NSAttributedString(
                                string: "A native companion for your reMarkable tablet.",
                                attributes: [.foregroundColor: NSColor.secondaryLabelColor]
                            )
                        ]
                    )
                }
            }

            CommandGroup(after: .help) {
                Button("Copy Connection Diagnostics") {
                    model.copyConnectionDiagnostics()
                }
            }
        }
    }

    private func restoreBackup() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Restore"
        panel.message = "Choose the backup folder to restore to the tablet " +
            "over USB\u{2011}C."
        panel.directoryURL = TabletBackupService.latestBackupFolder()
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let model = model
        model.showToast("Restoring backup…", severity: .informational)
        Task {
            do {
                let count = try await TabletBackupService()
                    .restoreAllDocuments(from: folder) { _ in }
                await MainActor.run {
                    model.showToast(
                        "Restored \(count) document\(count == 1 ? "" : "s") to the tablet.",
                        severity: .success
                    )
                }
            } catch {
                await MainActor.run {
                    model.showToast(
                        error.localizedDescription,
                        severity: .error
                    )
                }
            }
        }
    }
}
