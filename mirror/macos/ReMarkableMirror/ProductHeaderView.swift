import AppKit
import SwiftUI

struct ProductHeaderView: View {
    @Bindable var model: AppModel
    @FocusState private var filesActionFocused: Bool

    private enum Metrics {
        static let horizontalPadding: CGFloat = 12
        static let verticalPadding: CGFloat = 8
        static let groupSpacing: CGFloat = 8
        static let identityWidth: CGFloat = 150
        static let centerWidth: CGFloat = 164
        static let inputModeWidth: CGFloat = 164
        static let actionSize: CGFloat = 32
        static let actionSpacing: CGFloat = 6
        static let actionsWidth: CGFloat = (actionSize * 2) + actionSpacing
    }

    var body: some View {
        standardHeader
            .padding(.horizontal, Metrics.horizontalPadding)
            .padding(.vertical, Metrics.verticalPadding)
            .background(MirrorPalette.navy)
            .environment(\.colorScheme, .dark)
    }

    private var standardHeader: some View {
        HStack(spacing: Metrics.groupSpacing) {
            productIdentity
                .frame(width: Metrics.identityWidth, alignment: .leading)

            standardCenterContent
                .frame(width: Metrics.centerWidth, alignment: .leading)

            Spacer(minLength: 0)

            headerActions
                .frame(width: Metrics.actionsWidth)
        }
    }

    private var standardCenterContent: some View {
        inputModePicker
        .frame(width: Metrics.inputModeWidth, height: 50)
        .frame(width: Metrics.centerWidth, height: 50, alignment: .leading)
    }

    private var inputModePicker: some View {
        NativeInputModeControl(
            selection: $model.inputMode,
            isEnabled: true,
            accessibilityHint: model.canSendInput
                ? "Select how you control the tablet."
                : "Select the input mode to use when the mirror is live."
        )
    }

    private var productIdentity: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(0.13))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(.white.opacity(0.18), lineWidth: 1)
                    }

                RoundedRectangle(cornerRadius: 2)
                    .fill(MirrorPalette.paper)
                    .frame(width: 12, height: 23)
                    .overlay {
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(.black.opacity(0.65), lineWidth: 1)
                    }
            }
            .frame(width: 34, height: 38)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Paper Pro Move")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                statusLine
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Paper Pro Move. Connection status: \(model.connectionState.statusText)"
        )
    }

    private var statusLine: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(MirrorPalette.status(model.connectionState.tone))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)

            Text(model.connectionState.statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var headerActions: some View {
        return HStack(spacing: Metrics.actionSpacing) {
            screenshotAction

            filesAction
        }
    }

    private var screenshotAction: some View {
        let hint = model.canCopyScreenshot
            ? "Copies the current tablet screen."
            : "Screenshot will be available when the mirror is live."

        return headerAction(
            symbol: "camera",
            label: "Copy screenshot",
            hint: hint,
            isEnabled: model.canCopyScreenshot
        ) {
            model.copyScreenshot()
        }
        .contextMenu {
            Button("Save screenshot as…") {
                model.saveScreenshot()
            }
        }
    }

    private var filesAction: some View {
        let label = model.filesDesiredOpen ? "Close Files" : "Open Files"
        let hint = model.filesDesiredOpen
            ? "Closes the Files pane."
            : "Opens the Files pane."

        return Button {
            model.toggleFiles()
        } label: {
            Image(systemName: model.filesDesiredOpen ? "folder.fill" : "folder")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: Metrics.actionSize, height: Metrics.actionSize)
                .contentShape(Rectangle())
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(.white.opacity(0.72))
                        .frame(width: 12, height: 2)
                        .opacity(filesActionFocused ? 1 : 0)
                }
        }
        .buttonStyle(.plain)
        .focused($filesActionFocused)
        .focusEffectDisabled()
        .help(hint)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
        .onChange(of: model.filesDesiredOpen) { wasOpen, isOpen in
            if wasOpen && !isOpen {
                filesActionFocused = true
            }
        }
    }

    private func headerAction(
        symbol: String,
        label: String,
        hint: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .controlSize(.regular)
        .frame(width: Metrics.actionSize, height: Metrics.actionSize)
        .disabled(!isEnabled)
        .help(hint)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }

}

private struct NativeInputModeControl: NSViewRepresentable {
    @Binding var selection: MirrorInputMode
    let isEnabled: Bool
    let accessibilityHint: String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: MirrorInputMode.allCases.map(\.rawValue),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:))
        )
        control.controlSize = .regular
        control.segmentStyle = .rounded
        control.setWidth(116, forSegment: 0)
        control.setWidth(48, forSegment: 1)
        control.setAccessibilityLabel("Input mode")
        update(control)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        update(control)
    }

    private func update(_ control: NSSegmentedControl) {
        control.selectedSegment = MirrorInputMode.allCases.firstIndex(of: selection) ?? 0
        control.isEnabled = isEnabled
        control.font = NSFont.systemFont(ofSize: 13)
        control.setAccessibilityHelp(accessibilityHint)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: NativeInputModeControl

        init(parent: NativeInputModeControl) {
            self.parent = parent
        }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            guard MirrorInputMode.allCases.indices.contains(sender.selectedSegment) else {
                return
            }
            parent.selection = MirrorInputMode.allCases[sender.selectedSegment]
        }
    }
}
