import AppKit
import Darwin
import Foundation
import os
import UniformTypeIdentifiers

private let finderPromiseOutboundMarkerType = NSPasteboard.PasteboardType(
    "com.ifixrobots.ReMarkableMirror.outbound-document-promise"
)

struct FinderPromiseMaterializer: Sendable {
    let materializePDF: @Sendable (UUID, URL) async throws -> Void

    init(materializePDF: @escaping @Sendable (UUID, URL) async throws -> Void) {
        self.materializePDF = materializePDF
    }
}

private final class FinderPromiseOperationOwner: Sendable {
    private struct State {
        var acceptsNewOperations = true
        var operations: [UUID: Task<Void, Never>] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    @discardableResult
    func start(
        _ operation: @escaping @Sendable () async -> Void
    ) -> Bool {
        let operationID = UUID()
        return state.withLock { state in
            guard state.acceptsNewOperations else { return false }
            let task = Task(priority: .userInitiated) { [self] in
                defer { finish(operationID) }
                await operation()
            }
            state.operations[operationID] = task
            return true
        }
    }

    func retire() async {
        let operations = state.withLock { state in
            state.acceptsNewOperations = false
            return Array(state.operations.values)
        }
        operations.forEach { $0.cancel() }
        for operation in operations {
            await operation.value
        }
    }

    private func finish(_ operationID: UUID) {
        state.withLock { state in
            state.operations[operationID] = nil
        }
    }
}

private let finderPromiseOperationOwner = FinderPromiseOperationOwner()

@MainActor
final class FinderDocumentPromise {
    static let outboundMarkerType = finderPromiseOutboundMarkerType
    static let sourceOperationMask: NSDragOperation = .copy

    let provider: NSFilePromiseProvider

    private let controller: FinderPromiseController
    private let promiseDelegate: FinderDocumentPromiseDelegate

    convenience init(
        documentID: UUID,
        displayName: String,
        client: RemarkableFilesClient,
        cacheRootURL: URL? = nil
    ) {
        self.init(
            documentID: documentID,
            displayName: displayName,
            materializer: FinderPromiseMaterializer { documentID, destinationURL in
                _ = try await client.exportDocument(
                    documentID,
                    format: .pdf,
                    to: destinationURL
                )
            },
            cacheRootURL: cacheRootURL
        )
    }

    init(
        documentID: UUID,
        displayName: String,
        materializer: FinderPromiseMaterializer,
        cacheRootURL: URL? = nil
    ) {
        let cache = FinderPromiseCache(rootURL: cacheRootURL)
        let controller = FinderPromiseController(
            documentID: documentID,
            materializer: materializer,
            cache: cache
        )
        let promiseDelegate = FinderDocumentPromiseDelegate(
            fileName: FinderPromiseFileName.pdfName(displayName),
            controller: controller
        )
        let provider = FinderPDFPromiseProvider(
            fileType: UTType.pdf.identifier,
            delegate: promiseDelegate
        )
        // AppKit's delegate reference is weak. Keep the delegate alive for as
        // long as AppKit owns the provider, even if the drag-source view has
        // already released its wrapper after the session ends.
        provider.userInfo = promiseDelegate

        self.controller = controller
        self.promiseDelegate = promiseDelegate
        self.provider = provider
    }

    func cancel() async {
        await controller.cancel()
    }

    static func sweepStaleCache(
        cacheRootURL: URL? = nil,
        now: Date = Date()
    ) async {
        let cache = FinderPromiseCache(rootURL: cacheRootURL)
        await cache.sweep(
            olderThan: now.addingTimeInterval(-86_400),
            maximumEntries: 64
        )
    }

    static func retireProcessOperations() async {
        await finderPromiseOperationOwner.retire()
    }
}

@MainActor
private final class FinderPDFPromiseProvider: NSFilePromiseProvider {
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        let inherited = super.writableTypes(for: pasteboard)
        guard !inherited.contains(finderPromiseOutboundMarkerType) else {
            return inherited
        }
        return inherited + [finderPromiseOutboundMarkerType]
    }

    override func writingOptions(
        forType type: NSPasteboard.PasteboardType,
        pasteboard: NSPasteboard
    ) -> NSPasteboard.WritingOptions {
        if type == finderPromiseOutboundMarkerType {
            return []
        }
        return super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == finderPromiseOutboundMarkerType {
            return Data()
        }
        return super.pasteboardPropertyList(forType: type)
    }
}

private final class FinderDocumentPromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    private let fileName: String
    private let backgroundQueue: OperationQueue
    private let controller: FinderPromiseController

    init(fileName: String, controller: FinderPromiseController) {
        self.fileName = fileName
        self.controller = controller

        let queue = OperationQueue()
        queue.name = "com.ifixrobots.ReMarkableMirror.file-promise"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        self.backgroundQueue = queue
        super.init()
    }

    @MainActor
    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        fileName
    }

    @MainActor
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        backgroundQueue
    }

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping @Sendable ((any Error)?) -> Void
    ) {
        let controller = controller
        let accepted = finderPromiseOperationOwner.start {
            do {
                try Task.checkCancellation()
                try await controller.fulfill(to: url)
                completionHandler(nil)
            } catch is CancellationError {
                completionHandler(CancellationError())
            } catch let filesError as FilesTransferError {
                completionHandler(filesError)
            } catch {
                completionHandler(
                    FilesTransferError(
                        .localFile,
                        "Finder promise failed before Mirror could publish the document."
                    )
                )
            }
        }
        if !accepted {
            completionHandler(CancellationError())
        }
    }
}

private actor FinderPromiseController {
    private enum State {
        case idle
        case running(UUID, Task<FinderPromisePublishedFile, Error>)
        case cancelled
        case finished
    }

    private let documentID: UUID
    private let materializer: FinderPromiseMaterializer
    private let cache: FinderPromiseCache
    private var state: State = .idle

    init(
        documentID: UUID,
        materializer: FinderPromiseMaterializer,
        cache: FinderPromiseCache
    ) {
        self.documentID = documentID
        self.materializer = materializer
        self.cache = cache
    }

    func fulfill(to destinationURL: URL) async throws {
        guard destinationURL.isFileURL else {
            throw FilesTransferError(
                .invalidRequest,
                "Finder couldn’t choose a destination for this document. Try the drag again."
            )
        }
        switch state {
        case .idle:
            break
        case .cancelled:
            throw CancellationError()
        case .running, .finished:
            throw FilesTransferError(
                .invalidRequest,
                "That document drag has already finished. Drag it out again."
            )
        }

        let signpost = PerformanceSignposts.begin("Finder Promised File Fulfillment")
        defer { PerformanceSignposts.end(signpost) }

        let documentID = documentID
        let materializer = materializer
        let cache = cache
        // Build the worker outside this actor's executor. Cancellation must be
        // able to enter the controller while a large synchronous file copy is
        // in progress so the worker sees its cancellation flag between chunks.
        let operationID = UUID()
        let task = FinderPromiseWorker.start(
            documentID: documentID,
            destinationURL: destinationURL,
            materializer: materializer,
            cache: cache
        )
        state = .running(operationID, task)

        let publishedFile: FinderPromisePublishedFile
        do {
            publishedFile = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError {
            state = .cancelled
            throw CancellationError()
        } catch {
            if case .cancelled = state {
                throw CancellationError()
            }
            state = .finished
            throw error
        }

        guard !Task.isCancelled,
              case let .running(activeOperationID, _) = state,
              activeOperationID == operationID else {
            FinderPromiseDestination.removeIfOwned(publishedFile)
            state = .cancelled
            throw CancellationError()
        }
        state = .finished
    }

    func cancel() {
        switch state {
        case .idle:
            state = .cancelled
        case let .running(_, task):
            state = .cancelled
            task.cancel()
        case .cancelled, .finished:
            break
        }
    }
}

private enum FinderPromiseWorker {
    static func start(
        documentID: UUID,
        destinationURL: URL,
        materializer: FinderPromiseMaterializer,
        cache: FinderPromiseCache
    ) -> Task<FinderPromisePublishedFile, Error> {
        Task {
            let stagedURL = try await cache.makeStagingURL()
            do {
                try Task.checkCancellation()
                try await materializer.materializePDF(documentID, stagedURL)
                try await cache.validateStagingFile(stagedURL)
                try Task.checkCancellation()
                let publishedFile = try FinderPromiseDestination.copy(
                    from: stagedURL,
                    to: destinationURL
                )
                await cache.remove(stagedURL)
                return publishedFile
            } catch {
                await cache.remove(stagedURL)
                throw error
            }
        }
    }
}

private actor FinderPromiseCache {
    private let rootURL: URL

    init(rootURL: URL?) {
        self.rootURL = rootURL ?? URL.cachesDirectory
            .appending(path: "com.ifixrobots.ReMarkableMirror", directoryHint: .isDirectory)
            .appending(path: "file-promises", directoryHint: .isDirectory)
    }

    func makeStagingURL() throws -> URL {
        try prepareRoot()
        return rootURL.appending(path: "promise-\(UUID().uuidString).pdf")
    }

    func remove(_ url: URL) {
        guard contains(url), Self.isOwnedEntry(url.lastPathComponent) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func validateStagingFile(_ url: URL) throws {
        guard contains(url), Self.isOwnedEntry(url.lastPathComponent) else {
            throw FilesTransferError(
                .localFile,
                "Mirror received an invalid Finder promise staging path."
            )
        }
        var information = stat()
        guard lstat(url.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == getuid(),
              information.st_nlink == 1,
              chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
            throw FilesTransferError(
                .localFile,
                "Mirror could not secure the promised PDF."
            )
        }
    }

    func sweep(olderThan cutoff: Date, maximumEntries: Int) {
        guard maximumEntries > 0 else { return }
        do {
            try prepareRoot()
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
            let contents = try FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsSubdirectoryDescendants]
            )
            let entries = contents.compactMap { url -> (URL, Date)? in
                guard contains(url),
                      Self.isOwnedEntry(url.lastPathComponent),
                      let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true else { return nil }
                return (url, values.contentModificationDate ?? .distantPast)
            }.sorted { $0.1 > $1.1 }

            for (offset, entry) in entries.enumerated()
            where entry.1 < cutoff || offset >= maximumEntries {
                try? FileManager.default.removeItem(at: entry.0)
            }
        } catch {
            return
        }
    }

    private func prepareRoot() throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(rootURL.path, S_IRWXU) == 0 else {
            throw FilesTransferError(
                .localFile,
                "Mirror could not secure the Finder promise cache."
            )
        }
    }

    private func contains(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL == rootURL.standardizedFileURL
    }

    private static func isOwnedEntry(_ name: String) -> Bool {
        if name.hasPrefix("promise-"), name.hasSuffix(".pdf") {
            return true
        }
        return name.hasPrefix(".promise-") && name.hasSuffix(".partial")
    }
}

private struct FinderPromisePublishedFile: Sendable {
    let url: URL
    let device: UInt64
    let inode: UInt64
}

private enum FinderPromiseDestination {
    static func copy(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws -> FinderPromisePublishedFile {
        let sourceDescriptor = open(sourceURL.path, O_RDONLY | O_NOFOLLOW)
        guard sourceDescriptor >= 0 else {
            throw FilesTransferError(
                .localFile,
                "Mirror could not read the promised PDF."
            )
        }
        defer { close(sourceDescriptor) }

        let temporaryURL = destinationURL.deletingLastPathComponent().appending(
            path: ".rmmirror-\(UUID().uuidString).partial"
        )
        let destinationDescriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard destinationDescriptor >= 0 else {
            throw FilesTransferError(
                .localFile,
                "Mirror could not create the promised Finder file."
            )
        }

        var createdDestination = true
        defer {
            close(destinationDescriptor)
            if createdDestination {
                unlink(temporaryURL.path)
            }
        }

        var buffer = [UInt8](repeating: 0, count: 128 * 1_024)
        while true {
            try Task.checkCancellation()
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(sourceDescriptor, bytes.baseAddress, bytes.count)
            }
            if bytesRead == 0 { break }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw FilesTransferError(
                    .localFile,
                    "Mirror could not read the promised PDF."
                )
            }

            var bytesWritten = 0
            while bytesWritten < bytesRead {
                try Task.checkCancellation()
                let result = buffer.withUnsafeBytes { bytes in
                    Darwin.write(
                        destinationDescriptor,
                        bytes.baseAddress?.advanced(by: bytesWritten),
                        bytesRead - bytesWritten
                    )
                }
                if result < 0 {
                    if errno == EINTR { continue }
                    throw FilesTransferError(
                        .localFile,
                        "Mirror could not write the promised Finder file."
                    )
                }
                guard result > 0 else {
                    throw FilesTransferError(
                        .localFile,
                        "Mirror could not finish the promised Finder file."
                    )
                }
                bytesWritten += result
            }
        }
        guard fsync(destinationDescriptor) == 0 else {
            throw FilesTransferError(
                .localFile,
                "Mirror could not finish the promised Finder file."
            )
        }
        try Task.checkCancellation()
        var information = stat()
        guard fstat(destinationDescriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG else {
            throw FilesTransferError(
                .localFile,
                "Mirror could not verify the promised Finder file."
            )
        }
        let publishedFile = FinderPromisePublishedFile(
            url: destinationURL,
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino)
        )
        guard renamex_np(
            temporaryURL.path,
            destinationURL.path,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw FilesTransferError(
                .localFile,
                "Mirror could not publish the promised Finder file."
            )
        }
        createdDestination = false
        return publishedFile
    }

    static func removeIfOwned(_ publishedFile: FinderPromisePublishedFile) {
        var information = stat()
        guard lstat(publishedFile.url.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              UInt64(information.st_dev) == publishedFile.device,
              UInt64(information.st_ino) == publishedFile.inode else {
            return
        }
        unlink(publishedFile.url.path)
    }
}

private enum FinderPromiseFileName {
    static func pdfName(_ value: String) -> String {
        let leaf = value
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last
            .map(String.init) ?? ""
        var base = String(leaf.map { character in
            if character == "/" || character == ":" || character == "\0" ||
                character.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
                return Character("-")
            }
            return character
        }).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))

        if base.lowercased().hasSuffix(".pdf") {
            base.removeLast(4)
            base = base.trimmingCharacters(
                in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))
            )
        }
        if base.isEmpty || base == "." || base == ".." {
            base = "reMarkable document"
        }
        while base.utf8.count + 4 > 180, !base.isEmpty {
            base.removeLast()
        }
        if base.isEmpty {
            base = "reMarkable document"
        }
        return "\(base).pdf"
    }
}
