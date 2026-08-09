import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FilesPaneView: View {
    let model: AppModel

    private var presentation: FilesPanePresentation { model.filesPane }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            dropTarget
                .padding(.top, 14)
            navigation
                .padding(.top, 14)
            libraryStatus
                .padding(.top, 6)
            libraryAndTransfers
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .background(MirrorPalette.stage)
        .foregroundStyle(MirrorPalette.ink)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(FilesPaneCopy.title)
                    .font(.system(size: 21, weight: .semibold))
                Text(FilesPaneCopy.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(MirrorPalette.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button("Close Files", systemImage: "xmark") {
                model.toggleFiles()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .frame(width: 28, height: 28)
            .help("Close Files")
        }
    }

    private var dropTarget: some View {
        VStack(spacing: 7) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(MirrorPalette.accent)

            Text(
                presentation.isAvailable
                    ? "Choose or drop files"
                    : presentation.dropTargetTitle
            )
                .font(.system(size: 14, weight: .semibold))

            Text("PDF or EPUB")
                .font(.system(size: 12))
                .foregroundStyle(MirrorPalette.muted)
        }
        .accessibilityHidden(true)
        .frame(maxWidth: .infinity, minHeight: 102, maxHeight: 102)
        .background(
            presentation.isDropTargeted
                ? MirrorPalette.accent.opacity(0.12)
                : MirrorPalette.paper,
            in: .rect(cornerRadius: 14)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    presentation.isDropTargeted
                        ? MirrorPalette.accent
                        : MirrorPalette.border,
                    lineWidth: presentation.isDropTargeted ? 2 : 1
                )
        }
        .overlay {
            FilesPaneDropReceiver(
                isEnabled: presentation.isAvailable,
                accepts: FilesPanePresentation.acceptsImport,
                setTargeted: presentation.setDropTargeted,
                receive: { urls in
                    Task { await presentation.importFiles(urls) }
                }
            )
        }
        .animation(.easeOut(duration: 0.12), value: presentation.isDropTargeted)
    }

    private var navigation: some View {
        HStack(spacing: 8) {
            Button {
                Task { await presentation.goBack() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!presentation.canGoBack)
            .help("Back")
            .accessibilityLabel("Back")

            Text(presentation.locationText)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            Button {
                if presentation.isAvailable {
                    Task { await presentation.refresh() }
                } else {
                    model.retryFilesAvailability()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(
                !presentation.canRefresh &&
                    !model.canRetryFilesAvailability
            )
            .help(presentation.isAvailable ? "Refresh" : "Try Files Again")
            .accessibilityLabel(
                presentation.isAvailable ? "Refresh" : "Try Files Again"
            )
            .filesRetryAccessibility(model.filesAvailabilityRequestInFlight)
        }
    }

    private var libraryStatus: some View {
        let showsActivity = presentation.isRefreshing ||
            model.filesAvailabilityRequestInFlight

        return HStack(alignment: .top, spacing: 7) {
            ProgressView()
                .controlSize(.small)
                .tint(MirrorPalette.accent)
                .opacity(showsActivity ? 1 : 0)
                .frame(width: 13, height: 13)
                .accessibilityHidden(!showsActivity)

            Text(
                model.filesAvailabilityRequestInFlight
                    ? FilesPaneCopy.retryingAvailability
                    : model.canRetryFilesAvailability
                    ? FilesPaneCopy.retryUnavailable
                    : presentation.statusText
            )
                .font(.system(size: 12))
                .foregroundStyle(MirrorPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .topLeading)
    }

    private var libraryAndTransfers: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(presentation.items) { item in
                    libraryRow(item)
                }

                if presentation.hasTransfers {
                    recentTransfers
                        .padding(.top, presentation.items.isEmpty ? 8 : 16)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
        }
        .scrollIndicators(.automatic)
        .disabled(!presentation.isAvailable || presentation.isRefreshing)
    }

    private func libraryRow(_ item: RemarkableLibraryItem) -> some View {
        let trimmedName = item.displayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let displayName = trimmedName.isEmpty ? "Untitled" : trimmedName
        let interactionLabel = item.kind == .collection
            ? "Open folder \(displayName)"
            : "Save \(displayName) as PDF"
        let interactionHelp = item.kind == .collection
            ? "Opens this folder."
            : "Opens a save dialog. You can also drag this document to Finder."

        return HStack(spacing: 10) {
            Image(systemName: item.kind == .collection ? "folder" : "doc")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(MirrorPalette.ink)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(item.filesPaneKindLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(MirrorPalette.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Image(
                systemName: item.kind == .collection
                    ? "chevron.right"
                    : "square.and.arrow.down"
            )
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(MirrorPalette.muted)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .contentShape(.rect)
        .accessibilityHidden(true)
        .overlay {
            FilesPaneRowInteraction(
                isDocument: item.kind == .document,
                isEnabled: presentation.isAvailable && !presentation.isRefreshing,
                accessibilityLabel: interactionLabel,
                accessibilityHelp: interactionHelp,
                makePromise: { presentation.documentPromise(for: item) },
                primaryAction: {
                    Task { await presentation.activate(item) }
                },
                savePDF: {
                    Task { await presentation.exportDocument(item, as: .pdf) }
                },
                saveRMDOC: {
                    Task { await presentation.exportDocument(item, as: .rmdoc) }
                }
            )
        }
    }

    private var recentTransfers: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent transfers")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(presentation.transferCountText)
                    .font(.system(size: 11))
                    .foregroundStyle(MirrorPalette.muted)
            }

            ForEach(presentation.transfers) { transfer in
                HStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MirrorPalette.accent)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(transfer.name)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(transfer.state.label)
                            .font(.system(size: 11))
                            .foregroundStyle(MirrorPalette.muted)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 5)
            }
        }
    }
}

private struct FilesPaneDropReceiver: NSViewRepresentable {
    let isEnabled: Bool
    let accepts: @MainActor (URL) -> Bool
    let setTargeted: @MainActor (Bool) -> Void
    let receive: @MainActor ([URL]) -> Void

    func makeNSView(context: Context) -> FilesPaneDropReceiverView {
        FilesPaneDropReceiverView(
            isEnabled: isEnabled,
            accepts: accepts,
            setTargeted: setTargeted,
            receive: receive
        )
    }

    func updateNSView(
        _ view: FilesPaneDropReceiverView,
        context: Context
    ) {
        view.update(
            isEnabled: isEnabled,
            accepts: accepts,
            setTargeted: setTargeted,
            receive: receive
        )
    }
}

@MainActor
private final class FilesPaneDropReceiverView: NSButton {
    private var receiverIsEnabled: Bool
    private var accepts: @MainActor (URL) -> Bool
    private var setTargeted: @MainActor (Bool) -> Void
    private var receive: @MainActor ([URL]) -> Void
    private var openPanel: NSOpenPanel?

    init(
        isEnabled: Bool,
        accepts: @escaping @MainActor (URL) -> Bool,
        setTargeted: @escaping @MainActor (Bool) -> Void,
        receive: @escaping @MainActor ([URL]) -> Void
    ) {
        receiverIsEnabled = isEnabled
        self.accepts = accepts
        self.setTargeted = setTargeted
        self.receive = receive
        super.init(frame: .zero)
        self.isEnabled = isEnabled
        setAccessibilityEnabled(isEnabled)
        title = ""
        isBordered = false
        isTransparent = true
        focusRingType = .exterior
        target = self
        action = #selector(chooseFiles(_:))
        setAccessibilityLabel("Choose PDF or EPUB files to send")
        setAccessibilityHelp(
            "Opens a file chooser. You can also drop one or more files here."
        )
        updateToolTip()
        registerForDraggedTypes([
            .fileURL,
            NSPasteboard.PasteboardType(UTType.pdf.identifier),
            NSPasteboard.PasteboardType(UTType.epub.identifier),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        isEnabled: Bool,
        accepts: @escaping @MainActor (URL) -> Bool,
        setTargeted: @escaping @MainActor (Bool) -> Void,
        receive: @escaping @MainActor ([URL]) -> Void
    ) {
        receiverIsEnabled = isEnabled
        self.isEnabled = isEnabled
        setAccessibilityEnabled(isEnabled)
        self.accepts = accepts
        self.setTargeted = setTargeted
        self.receive = receive
        updateToolTip()
        if !isEnabled {
            setTargeted(false)
            if let openPanel {
                self.openPanel = nil
                openPanel.cancel(nil)
            }
        }
    }

    override var acceptsFirstResponder: Bool { receiverIsEnabled }

    override func keyDown(with event: NSEvent) {
        guard receiverIsEnabled else {
            super.keyDown(with: event)
            return
        }
        let prohibitedModifiers = event.modifierFlags.intersection([
            .command,
            .control,
            .option,
        ])
        if prohibitedModifiers.isEmpty,
           event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 76 {
            performClick(nil)
            return
        }
        super.keyDown(with: event)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateTarget(for: sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateTarget(for: sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        setTargeted(false)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        !compatibleURLs(from: sender).isEmpty
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = candidateURLs(from: sender)
        let compatible = urls.filter { accepts($0) }
        setTargeted(false)
        guard !compatible.isEmpty else { return false }
        // Pass every local candidate through so presentation can report the
        // unsupported count instead of silently dropping part of a mixed drag.
        receive(urls)
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        setTargeted(false)
    }

    private func updateTarget(
        for draggingInfo: any NSDraggingInfo
    ) -> NSDragOperation {
        let valid = !compatibleURLs(from: draggingInfo).isEmpty
        setTargeted(valid)
        return valid ? .copy : []
    }

    private func compatibleURLs(
        from draggingInfo: any NSDraggingInfo
    ) -> [URL] {
        candidateURLs(from: draggingInfo).filter { accepts($0) }
    }

    private func candidateURLs(
        from draggingInfo: any NSDraggingInfo
    ) -> [URL] {
        guard receiverIsEnabled,
              draggingInfo.draggingPasteboard.types?.contains(
                  FinderDocumentPromise.outboundMarkerType
              ) != true,
              draggingInfo.draggingSourceOperationMask.contains(.copy),
              let objects = draggingInfo.draggingPasteboard.readObjects(
                  forClasses: [NSURL.self],
                  options: [.urlReadingFileURLsOnly: true]
              ) else { return [] }
        return objects.compactMap { object in
            object as? URL
        }
    }

    @objc private func chooseFiles(_ sender: Any?) {
        guard receiverIsEnabled, openPanel == nil, let window else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .epub]
        panel.allowsMultipleSelection = true
        panel.allowsOtherFileTypes = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.resolvesAliases = true
        panel.message = "Choose one or more PDF or DRM-free EPUB files to send."
        panel.prompt = "Send"
        openPanel = panel

        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            guard let self, let panel, self.openPanel === panel else { return }
            self.openPanel = nil
            guard response == .OK,
                  self.receiverIsEnabled,
                  !panel.urls.isEmpty else { return }
            self.receive(panel.urls)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard receiverIsEnabled else { return false }
        chooseFiles(nil)
        return true
    }

    private func updateToolTip() {
        toolTip = receiverIsEnabled
            ? "Choose PDF or EPUB files"
            : "Connect or unlock your reMarkable to send files"
    }
}

private struct FilesPaneRowInteraction: NSViewRepresentable {
    let isDocument: Bool
    let isEnabled: Bool
    let accessibilityLabel: String
    let accessibilityHelp: String
    let makePromise: @MainActor () -> FinderDocumentPromise?
    let primaryAction: @MainActor () -> Void
    let savePDF: @MainActor () -> Void
    let saveRMDOC: @MainActor () -> Void

    func makeNSView(context: Context) -> FilesPaneRowInteractionView {
        FilesPaneRowInteractionView(
            isDocument: isDocument,
            isEnabled: isEnabled,
            accessibilityLabel: accessibilityLabel,
            accessibilityHelp: accessibilityHelp,
            makePromise: makePromise,
            primaryAction: primaryAction,
            savePDF: savePDF,
            saveRMDOC: saveRMDOC
        )
    }

    func updateNSView(
        _ view: FilesPaneRowInteractionView,
        context: Context
    ) {
        view.update(
            isDocument: isDocument,
            isEnabled: isEnabled,
            accessibilityLabel: accessibilityLabel,
            accessibilityHelp: accessibilityHelp,
            makePromise: makePromise,
            primaryAction: primaryAction,
            savePDF: savePDF,
            saveRMDOC: saveRMDOC
        )
    }
}

@MainActor
private final class FilesPaneRowInteractionView: NSView, NSDraggingSource {
    private var isDocument: Bool
    private var isEnabled: Bool
    private var interactionAccessibilityLabel: String
    private var interactionAccessibilityHelp: String
    private var makePromise: @MainActor () -> FinderDocumentPromise?
    private var primaryAction: @MainActor () -> Void
    private var savePDF: @MainActor () -> Void
    private var saveRMDOC: @MainActor () -> Void
    private var mouseDownPoint: NSPoint?
    private var startedDrag = false
    private var activePromise: FinderDocumentPromise?

    init(
        isDocument: Bool,
        isEnabled: Bool,
        accessibilityLabel: String,
        accessibilityHelp: String,
        makePromise: @escaping @MainActor () -> FinderDocumentPromise?,
        primaryAction: @escaping @MainActor () -> Void,
        savePDF: @escaping @MainActor () -> Void,
        saveRMDOC: @escaping @MainActor () -> Void
    ) {
        self.isDocument = isDocument
        self.isEnabled = isEnabled
        interactionAccessibilityLabel = accessibilityLabel
        interactionAccessibilityHelp = accessibilityHelp
        self.makePromise = makePromise
        self.primaryAction = primaryAction
        self.savePDF = savePDF
        self.saveRMDOC = saveRMDOC
        super.init(frame: .zero)
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateAccessibilityMetadata()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        isDocument: Bool,
        isEnabled: Bool,
        accessibilityLabel: String,
        accessibilityHelp: String,
        makePromise: @escaping @MainActor () -> FinderDocumentPromise?,
        primaryAction: @escaping @MainActor () -> Void,
        savePDF: @escaping @MainActor () -> Void,
        saveRMDOC: @escaping @MainActor () -> Void
    ) {
        self.isDocument = isDocument
        self.isEnabled = isEnabled
        interactionAccessibilityLabel = accessibilityLabel
        interactionAccessibilityHelp = accessibilityHelp
        self.makePromise = makePromise
        self.primaryAction = primaryAction
        self.savePDF = savePDF
        self.saveRMDOC = saveRMDOC
        updateAccessibilityMetadata()
        if !isEnabled, window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override var acceptsFirstResponder: Bool { isEnabled }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        bounds.fill()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        isEnabled
    }

    override func becomeFirstResponder() -> Bool {
        guard isEnabled, super.becomeFirstResponder() else { return false }
        setKeyboardFocusRingNeedsDisplay(bounds)
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        setKeyboardFocusRingNeedsDisplay(bounds)
        return true
    }

    override func keyDown(with event: NSEvent) {
        let prohibitedModifiers = event.modifierFlags.intersection([
            .command,
            .control,
            .option,
        ])
        if !event.isARepeat,
           prohibitedModifiers.isEmpty,
           event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 76 {
            primaryAction()
            return
        }
        super.keyDown(with: event)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        primaryAction()
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool {
        guard isEnabled, isDocument else { return false }
        documentMenu().popUp(
            positioning: nil,
            at: NSPoint(x: bounds.midX, y: bounds.midY),
            in: self
        )
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard isEnabled, isDocument else { return nil }
        return documentMenu()
    }

    override func resetCursorRects() {
        guard isEnabled else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        startedDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled,
              isDocument,
              !startedDrag,
              let mouseDownPoint,
              hypot(
                  convert(event.locationInWindow, from: nil).x - mouseDownPoint.x,
                  convert(event.locationInWindow, from: nil).y - mouseDownPoint.y
              ) >= 3,
              let promise = makePromise() else { return }

        startedDrag = true
        activePromise = promise
        let draggingItem = NSDraggingItem(pasteboardWriter: promise.provider)
        let image = NSImage(
            systemSymbolName: "doc.fill",
            accessibilityDescription: nil
        ) ?? NSImage(size: NSSize(width: 28, height: 34))
        draggingItem.setDraggingFrame(
            NSRect(
                x: mouseDownPoint.x - 14,
                y: mouseDownPoint.y - 17,
                width: 28,
                height: 34
            ),
            contents: image
        )
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            startedDrag = false
        }
        guard isEnabled, !startedDrag else { return }
        primaryAction()
    }

    private func documentMenu() -> NSMenu {
        let menu = NSMenu()
        let pdf = NSMenuItem(
            title: "Save as PDF…",
            action: #selector(savePDFAction(_:)),
            keyEquivalent: ""
        )
        pdf.target = self
        menu.addItem(pdf)
        let native = NSMenuItem(
            title: "Save native RMDOC…",
            action: #selector(saveRMDOCAction(_:)),
            keyEquivalent: ""
        )
        native.target = self
        menu.addItem(native)
        return menu
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        FinderDocumentPromise.sourceOperationMask
    }

    func ignoreModifierKeys(
        for session: NSDraggingSession
    ) -> Bool {
        true
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        let promise = activePromise
        activePromise = nil
        guard operation.isEmpty else { return }

        // AppKit keeps promised-file writers on the drag pasteboard after a
        // rejected or cancelled drop. Remove this provider synchronously so
        // application termination cannot try to resolve an abandoned promise.
        _ = session.draggingPasteboard.clearContents()

        guard let promise else { return }
        Task { await promise.cancel() }
    }

    @objc private func savePDFAction(_ sender: Any?) {
        savePDF()
    }

    @objc private func saveRMDOCAction(_ sender: Any?) {
        saveRMDOC()
    }

    private func updateAccessibilityMetadata() {
        setAccessibilityLabel(interactionAccessibilityLabel)
        setAccessibilityHelp(interactionAccessibilityHelp)
        setAccessibilityEnabled(isEnabled)
    }
}

private extension View {
    @ViewBuilder
    func filesRetryAccessibility(_ isInProgress: Bool) -> some View {
        if isInProgress {
            accessibilityValue("In progress")
        } else {
            self
        }
    }
}
