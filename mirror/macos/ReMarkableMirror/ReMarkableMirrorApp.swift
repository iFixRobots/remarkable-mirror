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
}
