import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

enum FilesPaneCopy {
    static let title = "Files"
    static let subtitle = "Drop files in. Drag documents out."
    static let disconnected = "Connect or unlock your reMarkable to browse files."
    static let retryUnavailable = "Files isn’t responding yet. Choose Try Files Again."
    static let rootLocation = "My files"
    static let connecting = "Connecting to your library…"
    static let retryingAvailability = "Trying Files again…"
    static let emptyFolder = "This folder is empty."
    static let uploadInterrupted =
        "Sending stopped before Mirror could confirm the result. " +
        "Check the tablet, then refresh before retrying."

    static func skippedUnsupportedItems(_ count: Int) -> String {
        "Skipped \(count) unsupported item\(count == 1 ? "" : "s"). " +
            "Only PDF and DRM-free EPUB files can be sent."
    }
}

struct FilesPaneLocation: Equatable, Sendable {
    let folderID: UUID?
    let title: String

    static let root = FilesPaneLocation(
        folderID: nil,
        title: FilesPaneCopy.rootLocation
    )
}

enum FilesPaneTransferState: Equatable, Sendable {
    case sending
    case sent
    case failed
    case ambiguous

    var label: String {
        switch self {
        case .sending: "Sending…"
        case .sent: "Sent"
        case .failed: "Couldn’t send"
        case .ambiguous: "Check tablet, then refresh"
        }
    }
}

struct FilesPaneTransfer: Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    var state: FilesPaneTransferState

    init(
        id: UUID = UUID(),
        name: String,
        state: FilesPaneTransferState
    ) {
        self.id = id
        self.name = name
        self.state = state
    }
}

struct FilesPaneImportFile: Sendable {
    let url: URL
    let removesSourceAfterImport: Bool

    static func local(_ url: URL) -> FilesPaneImportFile {
        FilesPaneImportFile(url: url, removesSourceAfterImport: false)
    }
}

struct FilesPaneService: Sendable {
    let id: UUID
    let listRoot: @Sendable () async throws -> [RemarkableLibraryItem]
    let listFolder: @Sendable (UUID) async throws -> [RemarkableLibraryItem]
    let importFile: @Sendable (URL, UUID?) async throws -> FilesUploadReceipt
    let exportDocument: @Sendable (
        UUID,
        FilesExportFormat,
        URL
    ) async throws -> FilesDownloadReceipt
    let makeDocumentPromise: (@MainActor @Sendable (
        RemarkableLibraryItem
    ) -> FinderDocumentPromise?)?

    init(
        id: UUID = UUID(),
        listRoot: @escaping @Sendable () async throws -> [RemarkableLibraryItem],
        listFolder: @escaping @Sendable (UUID) async throws -> [RemarkableLibraryItem],
        importFile: @escaping @Sendable (URL, UUID?) async throws -> FilesUploadReceipt,
        exportDocument: @escaping @Sendable (
            UUID,
            FilesExportFormat,
            URL
        ) async throws -> FilesDownloadReceipt,
        makeDocumentPromise: (@MainActor @Sendable (
            RemarkableLibraryItem
        ) -> FinderDocumentPromise?)? = nil
    ) {
        self.id = id
        self.listRoot = listRoot
        self.listFolder = listFolder
        self.importFile = importFile
        self.exportDocument = exportDocument
        self.makeDocumentPromise = makeDocumentPromise
    }

    init(id: UUID = UUID(), client: RemarkableFilesClient) {
        self.init(
            id: id,
            listRoot: { try await client.listRoot() },
            listFolder: { try await client.listFolder($0) },
            importFile: { try await client.importFile(at: $0, to: $1) },
            exportDocument: {
                try await client.exportDocument(
                    $0,
                    format: $1,
                    to: $2,
                    overwrite: true
                )
            },
            makeDocumentPromise: { item in
                guard item.kind == .document else { return nil }
                return FinderDocumentPromise(
                    documentID: item.id,
                    displayName: item.displayName,
                    client: client
                )
            }
        )
    }
}

struct FilesPaneExportDestinationPicker {
    let choose: @MainActor (
        RemarkableLibraryItem,
        FilesExportFormat
    ) async -> URL?

    init(
        _ choose: @escaping @MainActor (
            RemarkableLibraryItem,
            FilesExportFormat
        ) async -> URL?
    ) {
        self.choose = choose
    }

    static let system = FilesPaneExportDestinationPicker { item, format in
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = FilesPanePresentation.suggestedExportName(
            for: item,
            format: format
        )
        switch format {
        case .pdf:
            panel.allowedContentTypes = [.pdf]
        case .rmdoc:
            panel.allowedContentTypes = [
                UTType(filenameExtension: "rmdoc") ?? .data,
            ]
        }
        return panel.runModal() == .OK ? panel.url : nil
    }
}

@MainActor
@Observable
final class FilesPanePresentation {
    private(set) var isAvailable = false
    private(set) var isRefreshing = false
    private(set) var isDropTargeted = false
    private(set) var items: [RemarkableLibraryItem] = []
    private(set) var transfers: [FilesPaneTransfer] = []
    private(set) var location = FilesPaneLocation.root
    private(set) var statusText = FilesPaneCopy.disconnected

    @ObservationIgnored var showNotice: ((MirrorNotice) -> Void)?
    @ObservationIgnored var reportConnectionFailure: ((UUID) -> Void)?
    @ObservationIgnored var availabilityConfirmed: (() -> Void)?

    @ObservationIgnored private var service: FilesPaneService?
    @ObservationIgnored private let exportDestinationPicker: FilesPaneExportDestinationPicker
    @ObservationIgnored private var automaticRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var serviceRevision: UInt64 = 0
    @ObservationIgnored private var refreshRevision: UInt64 = 0
    @ObservationIgnored private var history: [FilesPaneLocation] = []

    init(
        exportDestinationPicker: FilesPaneExportDestinationPicker = .system
    ) {
        self.exportDestinationPicker = exportDestinationPicker
    }

    var locationText: String { location.title }
    var canGoBack: Bool { isAvailable && !isRefreshing && !history.isEmpty }
    var canRefresh: Bool { isAvailable && !isRefreshing }
    var dropTargetTitle: String { isAvailable ? "Drop to send" : "Connect or unlock to send" }
    var hasTransfers: Bool { !transfers.isEmpty }
    var transferCountText: String {
        "\(transfers.count) transfer\(transfers.count == 1 ? "" : "s")"
    }

    func attach(
        _ service: FilesPaneService,
        automaticallyRefresh: Bool = true
    ) {
        automaticRefreshTask?.cancel()
        serviceRevision &+= 1
        refreshRevision &+= 1
        self.service = service
        isAvailable = true
        isRefreshing = false
        isDropTargeted = false
        items = []
        history = []
        location = .root
        statusText = FilesPaneCopy.connecting

        guard automaticallyRefresh else { return }
        automaticRefreshTask = Task { [weak self] in
            await self?.refresh()
        }
    }

    func detach() {
        automaticRefreshTask?.cancel()
        automaticRefreshTask = nil
        serviceRevision &+= 1
        refreshRevision &+= 1
        service = nil
        isAvailable = false
        isRefreshing = false
        isDropTargeted = false
        items = []
        history = []
        location = .root
        statusText = FilesPaneCopy.disconnected
        for index in transfers.indices where transfers[index].state == .sending {
            // Once a send has been admitted, losing the service cannot prove
            // that the tablet did not accept it. Keep the UI conservative so a
            // reconnect does not invite an immediate duplicate upload.
            transfers[index].state = .ambiguous
        }
    }

    func refresh() async {
        guard isAvailable, let service else {
            applyDisconnectedState()
            return
        }

        refreshRevision &+= 1
        let requestRevision = refreshRevision
        let expectedServiceRevision = serviceRevision
        let requestedLocation = location
        isRefreshing = true
        statusText = FilesPaneCopy.connecting

        do {
            let receivedItems: [RemarkableLibraryItem]
            if let folderID = requestedLocation.folderID {
                receivedItems = try await service.listFolder(folderID)
            } else {
                receivedItems = try await service.listRoot()
            }
            guard isCurrent(
                serviceRevision: expectedServiceRevision,
                refreshRevision: requestRevision,
                location: requestedLocation
            ) else { return }

            items = Self.sorted(receivedItems)
            statusText = receivedItems.isEmpty
                ? FilesPaneCopy.emptyFolder
                : "\(receivedItems.count) item\(receivedItems.count == 1 ? "" : "s")"
            isRefreshing = false
            availabilityConfirmed?()
        } catch is CancellationError {
            guard isCurrent(
                serviceRevision: expectedServiceRevision,
                refreshRevision: requestRevision,
                location: requestedLocation
            ) else { return }
            isRefreshing = false
        } catch {
            guard isCurrent(
                serviceRevision: expectedServiceRevision,
                refreshRevision: requestRevision,
                location: requestedLocation
            ) else { return }
            isRefreshing = false
            handle(error, fallback: "Couldn’t load this folder. Try again.")
        }
    }

    func goBack() async {
        guard canGoBack, let previous = history.popLast() else { return }
        location = previous
        items = []
        await refresh()
    }

    func activate(_ item: RemarkableLibraryItem) async {
        guard isAvailable, !isRefreshing else { return }
        switch item.kind {
        case .collection:
            history.append(location)
            location = FilesPaneLocation(
                folderID: item.id,
                title: Self.nonemptyDisplayName(item, fallback: "Folder")
            )
            items = []
            await refresh()
        case .document:
            await exportDocument(item, as: .pdf)
        }
    }

    func exportDocument(
        _ item: RemarkableLibraryItem,
        as format: FilesExportFormat
    ) async {
        guard item.kind == .document,
              isAvailable,
              let service else { return }

        let expectedServiceRevision = serviceRevision
        guard let destination = await exportDestinationPicker.choose(item, format),
              expectedServiceRevision == serviceRevision,
              isAvailable else { return }

        do {
            _ = try await service.exportDocument(item.id, format, destination)
            guard expectedServiceRevision == serviceRevision, isAvailable else { return }
            publishNotice("Document saved.", severity: .success)
        } catch is CancellationError {
        } catch {
            guard expectedServiceRevision == serviceRevision else { return }
            handle(error, fallback: "Couldn’t save that document.")
        }
    }

    func importFiles(_ urls: [URL]) async {
        await importFiles(urls.map(FilesPaneImportFile.local))
    }

    func importFiles(_ files: [FilesPaneImportFile]) async {
        guard isAvailable, let service else {
            discardStagedFiles(files)
            publishNotice(
                "Connect or unlock your reMarkable before sending files.",
                severity: .warning
            )
            return
        }

        let accepted = files.filter { Self.acceptsImport($0.url) }
        let rejected = files.filter { !Self.acceptsImport($0.url) }
        discardStagedFiles(rejected)
        guard !accepted.isEmpty else {
            if rejected.isEmpty {
                publishNotice("Drop a PDF or EPUB file here.", severity: .warning)
            } else {
                publishNotice(
                    FilesPaneCopy.skippedUnsupportedItems(rejected.count),
                    severity: .warning
                )
            }
            return
        }
        if !rejected.isEmpty {
            publishNotice(
                FilesPaneCopy.skippedUnsupportedItems(rejected.count),
                severity: .warning
            )
        }

        let expectedServiceRevision = serviceRevision
        let destinationLocation = location
        let destinationFolderID = destinationLocation.folderID
        var sentCount = 0

        for (fileIndex, file) in accepted.enumerated() {
            defer { discardStagedFile(file) }
            guard expectedServiceRevision == serviceRevision, isAvailable else { continue }

            let transfer = FilesPaneTransfer(
                name: file.url.lastPathComponent,
                state: .sending
            )
            transfers.insert(transfer, at: 0)
            do {
                _ = try await service.importFile(file.url, destinationFolderID)
                guard expectedServiceRevision == serviceRevision, isAvailable else { continue }
                setTransferState(.sent, id: transfer.id)
                sentCount += 1
            } catch is CancellationError {
                setTransferState(.ambiguous, id: transfer.id)
                discardStagedFiles(Array(accepted.dropFirst(fileIndex + 1)))
                if expectedServiceRevision == serviceRevision {
                    publishNotice(
                        FilesPaneCopy.uploadInterrupted,
                        severity: .warning
                    )
                }
                return
            } catch let error as FilesTransferError {
                guard expectedServiceRevision == serviceRevision else { continue }
                // A connection error can arrive after the tablet returned a
                // receipt but generation validation lost the route. Once this
                // transfer was admitted, neither that race nor an explicitly
                // ambiguous result proves the document was not created.
                let isAmbiguous = error.failure == .ambiguousResult ||
                    error.failure == .connection
                setTransferState(isAmbiguous ? .ambiguous : .failed, id: transfer.id)
                handle(error, fallback: "Couldn’t send that file.")
                if isAmbiguous {
                    discardStagedFiles(Array(accepted.dropFirst(fileIndex + 1)))
                    return
                }
            } catch {
                guard expectedServiceRevision == serviceRevision else { continue }
                setTransferState(.failed, id: transfer.id)
                handle(error, fallback: "Couldn’t send that file.")
            }
        }

        guard sentCount > 0,
              expectedServiceRevision == serviceRevision,
              isAvailable else { return }
        let stayedAtDestination = location == destinationLocation
        var summary = stayedAtDestination
            ? "Sent \(sentCount) file\(sentCount == 1 ? "" : "s") to your reMarkable."
            : "Sent \(sentCount) file\(sentCount == 1 ? "" : "s") to the transfer’s original folder."
        if !rejected.isEmpty {
            summary += " Skipped \(rejected.count) unsupported item\(rejected.count == 1 ? "" : "s")."
        }
        publishNotice(
            summary,
            severity: rejected.isEmpty ? .success : .warning
        )
        if stayedAtDestination {
            await refresh()
        }
    }

    func setDropTargeted(_ targeted: Bool) {
        isDropTargeted = targeted && isAvailable
    }

    func documentPromise(
        for item: RemarkableLibraryItem
    ) -> FinderDocumentPromise? {
        guard item.kind == .document,
              isAvailable,
              let makeDocumentPromise = service?.makeDocumentPromise else {
            return nil
        }
        return makeDocumentPromise(item)
    }

    static func sorted(
        _ items: [RemarkableLibraryItem]
    ) -> [RemarkableLibraryItem] {
        items.sorted { left, right in
            if left.kind != right.kind {
                return left.kind == .collection
            }
            let comparison = left.displayName.localizedStandardCompare(right.displayName)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            return left.id.uuidString < right.id.uuidString
        }
    }

    static func acceptsImport(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return switch url.pathExtension.lowercased() {
        case "pdf", "epub": true
        default: false
        }
    }

    static func suggestedExportName(
        for item: RemarkableLibraryItem,
        format: FilesExportFormat
    ) -> String {
        var name = nonemptyDisplayName(item, fallback: "Document")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        for suffix in [".pdf", ".rmdoc"] where name.lowercased().hasSuffix(suffix) {
            name.removeLast(suffix.count)
            break
        }
        // NSSavePanel appends the extension for its allowed content type.
        // Supplying it here as well produces a doubled suffix for dynamic
        // types such as RMDOC.
        return name
    }

    private func isCurrent(
        serviceRevision: UInt64,
        refreshRevision: UInt64,
        location: FilesPaneLocation
    ) -> Bool {
        self.serviceRevision == serviceRevision &&
            self.refreshRevision == refreshRevision &&
            self.location == location &&
            isAvailable
    }

    private func handle(_ error: Error, fallback: String) {
        if let filesError = error as? FilesTransferError {
            if filesError.failure == .connection {
                let failedServiceID = service?.id
                applyDisconnectedState()
                if let failedServiceID {
                    reportConnectionFailure?(failedServiceID)
                }
                return
            }
            let message = filesError.userFacingMessage
            statusText = message
            publishNotice(
                message,
                severity: filesError.failure == .ambiguousResult ? .warning : .error
            )
            return
        }
        statusText = fallback
        publishNotice(fallback, severity: .error)
    }

    private func publishNotice(
        _ message: String,
        severity: MirrorNoticeSeverity
    ) {
        showNotice?(MirrorNotice(message: message, severity: severity))
    }

    private func applyDisconnectedState() {
        isAvailable = false
        isRefreshing = false
        isDropTargeted = false
        items = []
        statusText = FilesPaneCopy.disconnected
    }

    private func setTransferState(
        _ state: FilesPaneTransferState,
        id: UUID
    ) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].state = state
    }

    private func discardStagedFiles(_ files: [FilesPaneImportFile]) {
        for file in files {
            discardStagedFile(file)
        }
    }

    private func discardStagedFile(_ file: FilesPaneImportFile) {
        guard file.removesSourceAfterImport else { return }
        try? FileManager.default.removeItem(at: file.url)
    }

    private static func nonemptyDisplayName(
        _ item: RemarkableLibraryItem,
        fallback: String
    ) -> String {
        let name = item.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? fallback : name
    }
}

extension RemarkableLibraryItem {
    var filesPaneKindLabel: String {
        switch kind {
        case .collection:
            "Folder"
        case .document:
            fileType?.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .uppercased()
                .nilIfEmpty ?? "Document"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
