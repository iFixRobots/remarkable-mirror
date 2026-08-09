import AppKit
import Darwin
import UniformTypeIdentifiers

enum PairingPermissionAction: Equatable, Sendable {
    case authorizeTablet
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let mirrorBundleIdentifiers: Set<String> = [
        "com.ifixrobots.ReMarkableMirror"
    ]
    private var mirrorWindowController: MirrorWindowController?
    private var connectionCoordinator: ConnectionCoordinator?
    private var tabletInputPump: TabletInputEventPump?
    private var terminationTask: Task<Void, Never>?
    private var allowsImmediateTermination = false
    private var allowsUnconfirmedInputTermination = false
    private var instanceLock: MirrorInstanceLock?
    private var launchSuppressed = false
    private let screenshotIO = TabletScreenshotIO()

    func applicationWillFinishLaunching(_ notification: Notification) {
        do {
            instanceLock = try MirrorInstanceLock.acquire()
        } catch {
            launchSuppressed = true
            existingMirrorApplication()?.activate(options: [.activateAllWindows])
            if (error as? MirrorInstanceLockError) != .busy {
                NSLog("reMarkable Mirror instance lock failed: %@", String(describing: error))
            }
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !launchSuppressed else { return }
        NSWindow.allowsAutomaticWindowTabbing = false

        let model = AppModel.shared
        let coordinator = ConnectionCoordinator(
            presentFrame: { generation, update in
                await MainActor.run {
                    guard !Task.isCancelled else { return false }
                    do {
                        return try model.applyFrame(
                            update,
                            generation: generation
                        )
                    } catch {
                        return false
                    }
                }
            },
            publishFilesService: { generation, service in
                await MainActor.run {
                    if let generation, let service {
                        _ = model.attachFilesService(
                            service,
                            generation: generation
                        )
                    } else {
                        model.detachFilesService()
                    }
                }
            },
            publishSnapshot: { snapshot in
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    let wasFilesReady = model.filesReady
                    guard model.apply(snapshot) else { return }
                    if !wasFilesReady,
                       model.filesReady,
                       model.filesDesiredOpen,
                       model.filesFullyOpen {
                        Task { await model.filesPane.refresh() }
                    }
                }
            }
        )
        connectionCoordinator = coordinator
        model.authorizeTabletWithPassword = { password in
            await coordinator.authorizeTablet(password: password)
        }
        model.reauthorizeUSBWithPassword = { password in
            await coordinator.reauthorizeUSB(password: password)
        }
        let tabletInputPump = TabletInputEventPump { event, generation in
            await coordinator.sendInput(event, generation: generation)
        }
        self.tabletInputPump = tabletInputPump
        model.requestTabletInput = { [weak tabletInputPump] event, generation in
            tabletInputPump?.enqueue(event, generation: generation)
        }
        model.filesPane.showNotice = { [weak model] notice in
            model?.showToast(notice.message, severity: notice.severity)
        }
        model.filesPane.reportConnectionFailure = { capabilityID in
            Task {
                await coordinator.reportFilesConnectionFailure(
                    capabilityID: capabilityID
                )
            }
        }
        model.requestFilesPaneVisibilityChange = { isOpen, revision in
            Task {
                await coordinator.setFilesPaneOpen(
                    isOpen,
                    revision: revision
                )
            }
        }
        model.requestLocalSetup = {
            await coordinator.prepareLocalPairing()
        }
        model.requestCancelLocalSetup = {
            await coordinator.cancelLocalPairing()
        }
        model.requestRetryLocalSetup = {
            await coordinator.retryLocalPairing()
        }
        model.requestAuthorizeTablet = { [weak self] in
            self?.requestPairingAction(.authorizeTablet)
        }
        model.requestCheckTabletAuthorization = {
            await coordinator.checkTabletAuthorization()
        }
        model.requestRepairUSB = {
            await coordinator.repairUSB()
        }
        model.requestFinishWiFiSetup = {
            await coordinator.finishWiFiPairing()
        }
        model.requestConnect = { route in
            await coordinator.connect(route: route)
        }
        model.requestCopyDetails = {
            Task {
                let report = await coordinator.diagnosticReport()
                await MainActor.run {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(report, forType: .string)
                    model.showToast("Connection diagnostics copied.", severity: .success)
                }
            }
        }

        let controller = MirrorWindowController(model: model)
        mirrorWindowController = controller
        model.requestCopyScreenshot = { [weak model, screenshotIO] in
            guard let model else { return }
            let snapshot: TabletFrameSnapshot
            do {
                guard let available = try model.currentFrameSnapshot() else {
                    model.showToast(
                        "Screenshot will be available when the mirror is live."
                    )
                    return
                }
                snapshot = available
            } catch {
                    model.showToast(
                        "Couldn’t copy the screenshot. Try again.",
                        severity: .error
                )
                return
            }

            Task { [weak model] in
                do {
                    let png = try await screenshotIO.pngData(for: snapshot)
                    guard let model else { return }
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    guard pasteboard.setData(png, forType: .png) else {
                        throw TabletScreenshotIOError.pasteboardWriteFailed
                    }
                    model.showToast("Screenshot copied.", severity: .success)
                } catch {
                    model?.showToast(
                        "Couldn’t copy the screenshot. Try again.",
                        severity: .error
                    )
                }
            }
        }
        model.requestSaveScreenshot = { [weak model, weak controller, screenshotIO] in
            guard let model else { return }
            let snapshot: TabletFrameSnapshot
            do {
                guard let available = try model.currentFrameSnapshot() else {
                    model.showToast(
                        "Screenshot will be available when the mirror is live."
                    )
                    return
                }
                snapshot = available
            } catch {
                model.showToast(
                    "Couldn’t save the screenshot. Try again.",
                    severity: .error
                )
                return
            }
            guard let window = controller?.window else { return }

            let panel = NSSavePanel()
            panel.title = "Save screenshot as"
            panel.nameFieldStringValue = "reMarkable Screenshot.png"
            panel.allowedContentTypes = [.png]
            panel.canCreateDirectories = true
            panel.beginSheetModal(for: window) { [weak model] response in
                guard response == .OK, let destination = panel.url else { return }
                Task { [weak model] in
                    do {
                        try await screenshotIO.write(snapshot, to: destination)
                        model?.showToast("Screenshot saved.", severity: .success)
                    } catch {
                        model?.showToast(
                            "Couldn’t save the screenshot. Try again.",
                            severity: .error
                        )
                    }
                }
            }
        }
        model.requestResetLocalSetup = { [weak controller] in
            guard let window = controller?.window else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Remove this Mac’s Mirror setup?"
            alert.informativeText = "This removes reMarkable Mirror’s profile and connection key from this Mac. The tablet is not changed."
            let removeButton = alert.addButton(withTitle: "Remove Local Setup")
            removeButton.hasDestructiveAction = true
            let cancelButton = alert.addButton(withTitle: "Cancel")
            cancelButton.keyEquivalent = "\u{1b}"
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                Task { await coordinator.resetLocalPairing() }
            }
        }
        controller.showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        Task {
            await FinderDocumentPromise.sweepStaleCache()
            await coordinator.start()
        }
    }

    private func existingMirrorApplication() -> NSRunningApplication? {
        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.first { application in
            application.processIdentifier != currentProcessIdentifier &&
                !application.isTerminated &&
                application.bundleIdentifier.map(
                    Self.mirrorBundleIdentifiers.contains
                ) == true
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        instanceLock?.release()
        instanceLock = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func requestPairingAction(_ action: PairingPermissionAction) {
        guard pairingActionIsCurrent(action) else { return }
        continuePairingAction(action)
    }

    private func continuePairingAction(_ action: PairingPermissionAction) {
        guard pairingActionIsCurrent(action) else { return }

        switch action {
        case .authorizeTablet:
            AppModel.shared.presentTabletAuthorizationPrompt()
        }
    }

    private func pairingActionIsCurrent(_ action: PairingPermissionAction) -> Bool {
        switch action {
        case .authorizeTablet:
            AppModel.shared.canAuthorizeTablet
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if allowsImmediateTermination || allowsUnconfirmedInputTermination {
            return .terminateNow
        }
        guard let connectionCoordinator else { return .terminateNow }
        if terminationTask != nil { return .terminateCancel }

        tabletInputPump?.stop()
        tabletInputPump = nil
        AppModel.shared.requestTabletInput = nil
        AppModel.shared.filesPane.detach()
        terminationTask = Task {
            async let promiseRetirement: Void =
                FinderDocumentPromise.retireProcessOperations()
            async let connectionShutdown = connectionCoordinator.shutdown()
            let (_, result) = await (promiseRetirement, connectionShutdown)
            terminationTask = nil
            switch result {
            case .clean:
                allowsImmediateTermination = true
                sender.terminate(nil)
            case .inputRestorationUncertain:
                presentInputRestorationWarning()
            case .processFailure:
                presentTerminationFailure()
            }
        }
        return .terminateCancel
    }

    private func presentTerminationFailure() {
        guard let controller = mirrorWindowController,
              let window = controller.window else { return }

        controller.showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Mirror is still closing the connection"
        alert.informativeText =
            "One or more connection processes have not stopped yet. " +
            "Mirror cannot safely quit until they do."
        alert.addButton(withTitle: "Try Again")
        alert.beginSheetModal(for: window) { _ in
            NSApplication.shared.terminate(nil)
        }
    }

    private func presentInputRestorationWarning() {
        guard let controller = mirrorWindowController,
              let window = controller.window else { return }

        controller.showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Check the tablet before quitting"
        alert.informativeText =
            "All Mac connection processes are stopped. Mirror couldn’t confirm " +
            "that touch, pen, and buttons were restored. Check them on the tablet, then quit."
        let quitButton = alert.addButton(withTitle: "Quit Anyway")
        quitButton.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn,
                  let self else { return }
            self.allowsUnconfirmedInputTermination = true
            NSApplication.shared.terminate(nil)
        }
    }
}

enum MirrorInstanceLockError: Error, Equatable {
    case busy
    case directoryCreationFailed
    case openFailed(Int32)
    case permissionsFailed(Int32)
    case lockFailed(Int32)
}

final class MirrorInstanceLock {
    static let defaultURL = URL.applicationSupportDirectory
        .appending(path: ".com.ifixrobots.ReMarkableMirror.instance.lock")

    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(at url: URL = defaultURL) throws -> MirrorInstanceLock {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw MirrorInstanceLockError.directoryCreationFailed
        }

        let descriptor = open(
            url.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw MirrorInstanceLockError.openFailed(errno)
        }

        guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            let failure = errno
            close(descriptor)
            throw MirrorInstanceLockError.permissionsFailed(failure)
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            close(descriptor)
            if failure == EWOULDBLOCK || failure == EAGAIN {
                throw MirrorInstanceLockError.busy
            }
            throw MirrorInstanceLockError.lockFailed(failure)
        }

        return MirrorInstanceLock(descriptor: descriptor)
    }

    func release() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }
}

@MainActor
private final class TabletInputEventPump {
    private let send: @Sendable (TabletInputEvent, GenerationID) async -> Void
    private var pending = GenerationBoundTabletInputBuffer()
    private var drainTask: Task<Void, Never>?
    private var acceptsEvents = true

    init(
        send: @escaping @Sendable (TabletInputEvent, GenerationID) async -> Void
    ) {
        self.send = send
    }

    func enqueue(
        _ hostEvent: TabletHostInputEvent,
        generation: GenerationID
    ) {
        guard acceptsEvents,
              let event = try? TabletHostInputTranslator.translate(hostEvent) else {
            return
        }

        pending.enqueue(event, generation: generation)
        startDrainIfNeeded()
    }

    func stop() {
        acceptsEvents = false
        pending.removeAll()
    }

    private func startDrainIfNeeded() {
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !Task.isCancelled, let queued = pending.dequeue() {
            await send(queued.event, queued.generation)
        }
        drainTask = nil
        if acceptsEvents, !pending.isEmpty {
            startDrainIfNeeded()
        }
    }
}

struct GenerationBoundTabletInput: Equatable, Sendable {
    let event: TabletInputEvent
    let generation: GenerationID
}

struct GenerationBoundTabletInputBuffer: Sendable {
    private var generation: GenerationID?
    private var pending = TabletInputEventBuffer()

    var isEmpty: Bool { pending.isEmpty }

    mutating func enqueue(
        _ event: TabletInputEvent,
        generation: GenerationID
    ) {
        if self.generation != generation {
            pending.removeAll()
            self.generation = generation
        }
        pending.enqueue(event)
    }

    mutating func dequeue() -> GenerationBoundTabletInput? {
        guard let generation,
              let event = pending.dequeue() else {
            return nil
        }
        if pending.isEmpty {
            self.generation = nil
        }
        return GenerationBoundTabletInput(
            event: event,
            generation: generation
        )
    }

    mutating func removeAll() {
        pending.removeAll()
        generation = nil
    }
}

private enum TabletScreenshotIOError: Error {
    case pasteboardWriteFailed
}

private actor TabletScreenshotIO {
    func pngData(for snapshot: TabletFrameSnapshot) throws -> Data {
        try snapshot.pngData()
    }

    func write(_ snapshot: TabletFrameSnapshot, to destination: URL) throws {
        let png = try snapshot.pngData()
        try png.write(to: destination, options: .atomic)
    }
}
