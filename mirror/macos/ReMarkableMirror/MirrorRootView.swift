import SwiftUI

struct MirrorRootView: View {
    let model: AppModel

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                MirrorPalette.navy

                ProductHeaderView(model: model)
                    .frame(
                        width: model.layout.compactWidth,
                        height: WindowLayout.headerHeight,
                        alignment: .leading
                    )

                continuousStage(height: geometry.size.height - WindowLayout.headerHeight - WindowLayout.stageMargin)
                    .offset(
                        x: WindowLayout.stageMargin,
                        y: WindowLayout.headerHeight
                    )

                if let notice = model.toast {
                    VStack {
                        Spacer(minLength: 0)
                        MirrorNoticeBanner(notice: notice)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 14)
                    }
                    .frame(
                        width: model.layout.compactStageWidth,
                        height: geometry.size.height - WindowLayout.headerHeight - WindowLayout.stageMargin
                    )
                    .offset(
                        x: WindowLayout.stageMargin,
                        y: WindowLayout.headerHeight
                    )
                    .id(notice.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
                }

                if model.tabletAuthorizationPromptIsPresented {
                    TabletAuthorizationPrompt(
                        repairsUSB: model.authorizationPromptRepairsUSB,
                        onCancel: model.dismissTabletAuthorizationPrompt,
                        onSubmit: model.submitTabletAuthorization(password:)
                    )
                    .frame(
                        width: model.layout.expandedWidth,
                        height: geometry.size.height
                    )
                    .transition(.opacity)
                    .zIndex(10)
                }
            }
            .animation(.easeOut(duration: 0.16), value: model.toast?.id)
            .animation(
                .easeOut(duration: 0.14),
                value: model.tabletAuthorizationPromptIsPresented
            )
        }
        .frame(width: model.layout.expandedWidth)
        .background(MirrorPalette.navy)
        .ignoresSafeArea()
    }

    private func continuousStage(height: CGFloat) -> some View {
        HStack(spacing: 0) {
            TabletStageView(model: model)
                .frame(width: model.layout.compactStageWidth, height: height)

            Rectangle()
                .fill(MirrorPalette.border)
                .frame(width: 1, height: max(0, height - 30))

            FilesPaneView(model: model)
                .frame(width: WindowLayout.filesWidth - 1, height: height)
                .disabled(!model.filesFullyOpen)
                .allowsHitTesting(model.filesFullyOpen)
        }
        .frame(
            width: model.layout.compactStageWidth + WindowLayout.filesWidth,
            height: height,
            alignment: .leading
        )
        .background(MirrorPalette.stage)
        .environment(\.colorScheme, .light)
    }
}

private struct TabletAuthorizationPrompt: View {
    let repairsUSB: Bool
    let onCancel: () -> Void
    let onSubmit: (String) async -> Bool

    @State private var password = ""
    @State private var isSubmitting = false
    @FocusState private var passwordIsFocused: Bool

    private var canSubmit: Bool {
        !isSubmitting &&
            !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(0.44)

            VStack(alignment: .leading, spacing: 0) {
                Text(repairsUSB ? "Authorize USB‑C again" : "Authorize this Mac")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(MirrorPalette.ink)

                Text(promptMessage)
                .font(.system(size: 13))
                .foregroundStyle(MirrorPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

                Text("Developer Mode password")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MirrorPalette.ink)
                    .padding(.top, 18)

                SecureField("Paste password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($passwordIsFocused)
                    .onSubmit(submit)
                    .padding(.top, 6)

                Text(footnote)
                .font(.system(size: 11.5))
                .foregroundStyle(MirrorPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

                HStack(spacing: 10) {
                    Spacer()

                    Button("Cancel", action: cancel)
                        .keyboardShortcut(.cancelAction)
                        .disabled(isSubmitting)

                    Button(action: submit) {
                        HStack(spacing: 7) {
                            if isSubmitting {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(repairsUSB ? "Authorize USB‑C" : "Authorize")
                        }
                        .frame(minWidth: 126)
                    }
                        .buttonStyle(.borderedProminent)
                        .tint(MirrorPalette.accent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSubmit)
                }
                .controlSize(.large)
                .padding(.top, 20)
            }
            .frame(width: 328)
            .padding(22)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(MirrorPalette.paper)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(MirrorPalette.border, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.24), radius: 24, y: 10)
            .frame(width: WindowLayout.fixed.compactWidth)
            .frame(maxHeight: .infinity)
        }
        .environment(\.colorScheme, .light)
        .contentShape(Rectangle())
        .onAppear {
            DispatchQueue.main.async {
                passwordIsFocused = true
            }
        }
        .onExitCommand(perform: cancel)
    }

    private func submit() {
        guard canSubmit else { return }
        let submittedPassword = password.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        isSubmitting = true
        Task { @MainActor in
            if await onSubmit(submittedPassword) {
                password = ""
            } else {
                isSubmitting = false
                passwordIsFocused = true
            }
        }
    }

    private var promptMessage: String {
        "Enter the Developer Mode password shown on your reMarkable. " +
            "Mirror uses it for this attempt only and never saves it."
    }

    private var footnote: String {
        if repairsUSB {
            return "This repairs this Mac’s saved USB‑C authorization. " +
                "It does not configure Wi‑Fi or change documents."
        }
        return "This adds this Mac’s access key and installs Mirror’s USB " +
            "keep-awake helper. Keep the tablet connected, awake, and unlocked."
    }

    private func cancel() {
        guard !isSubmitting else { return }
        password = ""
        onCancel()
    }
}

private struct MirrorNoticeBanner: View {
    let notice: MirrorToast

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(symbolColor)

            Text(notice.message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 360)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(MirrorPalette.ink.opacity(0.96))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
    }

    private var symbol: String {
        switch notice.severity {
        case .success: "checkmark.circle.fill"
        case .informational: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var symbolColor: Color {
        switch notice.severity {
        case .success: MirrorPalette.status(.green)
        case .informational: .white.opacity(0.82)
        case .warning: MirrorPalette.status(.amber)
        case .error: MirrorPalette.status(.red)
        }
    }
}
