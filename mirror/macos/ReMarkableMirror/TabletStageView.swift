import SwiftUI

struct TabletStageView: View {
    let model: AppModel

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = max(0, geometry.size.width)
            let availableHeight = max(0, geometry.size.height)
            let scale = min(
                1,
                availableWidth / TabletStageMetrics.chassisSize.width,
                availableHeight / TabletStageMetrics.chassisSize.height
            )
            let tabletWidth = TabletStageMetrics.chassisSize.width * scale
            let tabletHeight = TabletStageMetrics.chassisSize.height * scale

            ZStack {
                RoundedRectangle(cornerRadius: max(2, 5 * scale), style: .continuous)
                    .fill(MirrorPalette.bezel)
                    .frame(width: tabletWidth, height: tabletHeight)
                    .accessibilityHidden(true)

                Group {
                    if model.wifiAddressPromptIsPresented {
                        TabletWaitingScreen(
                            recoveryCard: model.recoveryCard,
                            model: model
                        )
                    } else if model.hasCurrentFrame,
                       let presentation = model.framePresentation {
                        ZStack {
                            TabletFrameView(presentation: presentation)

                            TabletInputSurface(
                                mode: model.inputMode.tabletInputMode,
                                isEnabled: model.canSendInput,
                                onEvent: { event in
                                    model.sendTabletInput(event)
                                }
                            )
                        }
                    } else {
                        TabletWaitingScreen(
                            recoveryCard: model.recoveryCard,
                            model: model
                        )
                    }
                }
                .frame(width: 954 * scale, height: 1_696 * scale)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, TabletStageMetrics.horizontalPadding)
        .padding(.vertical, TabletStageMetrics.verticalPadding)
        .background(MirrorPalette.stage)
    }
}

private extension MirrorInputMode {
    var tabletInputMode: TabletInputMode {
        switch self {
        case .touchAndType:
            .touchAndType
        case .pen:
            .pen
        }
    }
}

private struct TabletWaitingScreen: View {
    let recoveryCard: RecoveryCardContent?
    let model: AppModel

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height

            ZStack {
                Color.white
                    .accessibilityHidden(true)

                if !model.wifiAddressPromptIsPresented,
                   model.connectionState == .setupRequired {
                    SetupWalkthroughCard(model: model)
                        .frame(
                            width: max(
                                0,
                                min(380, width - 48)
                            )
                        )
                        .frame(
                            maxHeight: max(
                                0,
                                height - 48
                            )
                        )
                } else if let recoveryCard {
                    RecoveryCardView(
                        content: recoveryCard,
                        model: model
                    )
                        .frame(
                            width: max(
                                0,
                                min(380, width - 48)
                            )
                        )
                        .frame(
                            maxHeight: max(
                                0,
                                height - 48
                            )
                        )
                } else {
                    RecoveryCardView(
                        content: RecoveryCardContent(
                            symbol: "ipad.gen2",
                            title: "Opening your reMarkable",
                            message: "Waiting for the tablet screen.",
                            showsProgress: true,
                            actions: []
                        ),
                        model: model
                    )
                    .frame(
                        width: max(
                            0,
                            min(380, width - 48)
                        )
                    )
                    .frame(
                        maxHeight: max(
                            0,
                            height - 48
                        )
                    )
                }
            }
            .clipped()
        }
    }
}

private struct RecoveryCardView: View {
    let content: RecoveryCardContent
    @Bindable var model: AppModel
    @FocusState private var wifiAddressIsFocused: Bool

    var body: some View {
        cardContent
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

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: content.symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(MirrorPalette.ink)
                .frame(width: 42, height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(MirrorPalette.accent.opacity(0.10))
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(content.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(MirrorPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text(content.message)
                    .font(.system(size: 14))
                    .foregroundStyle(MirrorPalette.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.wifiAddressPromptIsPresented {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tablet IP address")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MirrorPalette.ink)

                    TextField("192.168.1.42", text: $model.wifiAddressInput)
                        .textFieldStyle(.roundedBorder)
                        .focused($wifiAddressIsFocused)
                        .accessibilityLabel("Tablet Wi‑Fi IP address")
                        .onSubmit {
                            guard model.canSubmitWiFiAddress else { return }
                            model.performRecoveryAction(.connectWiFi)
                        }
                        .task {
                            wifiAddressIsFocused = true
                        }
                }
            }

            if content.showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(MirrorPalette.accent)
                    .accessibilityLabel("\(content.title), in progress")
            }

            if !content.actions.isEmpty {
                if content.actions.map(\.action) == [.connectUSB, .connectWiFi] {
                    VStack(spacing: 8) {
                        ForEach(content.actions) { descriptor in
                            actionButton(descriptor, fillsWidth: true)
                        }
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            ForEach(content.actions) { descriptor in
                                actionButton(descriptor, fillsWidth: false)
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)

                        VStack(spacing: 8) {
                            ForEach(content.actions) { descriptor in
                                actionButton(descriptor, fillsWidth: true)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func actionButton(
        _ descriptor: RecoveryCardAction,
        fillsWidth: Bool
    ) -> some View {
        let showsRequestProgress = model.connectionRequestIsInFlight(
            for: descriptor.action
        )
        let button = Button {
            model.performRecoveryAction(descriptor.action)
        } label: {
            HStack(spacing: 6) {
                if descriptor.action.isConnectionAction {
                    ProgressView()
                        .controlSize(.small)
                        .opacity(showsRequestProgress ? 1 : 0)
                        .frame(width: 12, height: 12)
                        .accessibilityHidden(true)
                }

                Text(descriptor.label)
                    .font(.system(size: 14))
                    .fixedSize(horizontal: !fillsWidth, vertical: true)
            }
            .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .accessibilityLabel(descriptor.accessibilityLabel)
        .disabled(!model.recoveryActionIsEnabled(descriptor.action))

        if descriptor.isPrimary {
            button
                .buttonStyle(.borderedProminent)
                .tint(MirrorPalette.accent)
                .connectionProgressAccessibility(showsRequestProgress)
        } else {
            button
                .buttonStyle(.bordered)
                .connectionProgressAccessibility(showsRequestProgress)
        }
    }

}

private extension RecoveryAction {
    var isConnectionAction: Bool {
        self == .connectUSB || self == .connectWiFi
    }
}

private extension View {
    @ViewBuilder
    func connectionProgressAccessibility(_ isInProgress: Bool) -> some View {
        if isInProgress {
            accessibilityValue("In progress")
        } else {
            self
        }
    }
}
