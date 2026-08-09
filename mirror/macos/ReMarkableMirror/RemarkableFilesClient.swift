import Darwin
import Foundation
import os

enum RemarkableLibraryItemKind: String, Equatable, Sendable {
    case document
    case collection
}

struct RemarkableLibraryItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let visibleName: String?
    let legacyVisibleName: String?
    let parentID: UUID?
    let kind: RemarkableLibraryItemKind
    let isBookmarked: Bool
    let modifiedClient: String?
    let currentPage: Int?
    let fileType: String?

    var displayName: String {
        legacyVisibleName ?? visibleName ?? ""
    }

    var isDocument: Bool {
        kind == .document
    }
}

enum FilesExportFormat: String, Equatable, Sendable {
    case pdf
    case rmdoc

    var fileExtension: String { ".\(rawValue)" }
}

struct FilesUploadReceipt: Equatable, Sendable {
    let sourceFileName: String
    let destinationFolderID: UUID?
    let item: RemarkableLibraryItem
}

struct FilesDownloadReceipt: Equatable, Sendable {
    let bytesWritten: Int64
    let suggestedFileName: String?
    let savedURL: URL
}

enum FilesTransferFailure: String, Equatable, Sendable {
    case configuration
    case connection
    case invalidRequest
    case protocolViolation
    case rejected
    case ambiguousResult
    case localFile
    case sourceFileChanged
}

struct FilesTransferError: Error, Equatable, Sendable, LocalizedError {
    let failure: FilesTransferFailure
    let message: String
    let statusCode: Int?

    init(
        _ failure: FilesTransferFailure,
        _ message: String,
        statusCode: Int? = nil
    ) {
        self.failure = failure
        self.message = message
        self.statusCode = statusCode
    }

    var userFacingMessage: String {
        switch failure {
        case .configuration:
            "Files isn’t available right now. Try again."
        case .connection:
            "Reconnect to your reMarkable and try again."
        case .protocolViolation:
            "Mirror couldn’t read the tablet’s files. Try again."
        case .localFile:
            "Mirror couldn’t read or save that file. Try again."
        case .sourceFileChanged:
            "That file changed while Mirror was preparing it. Wait for it to finish saving, then try again."
        case .invalidRequest, .rejected, .ambiguousResult:
            message
        }
    }

    var errorDescription: String? {
        userFacingMessage
    }
}

enum FilesHTTPMethod: String, Equatable, Sendable {
    case get = "GET"
    case post = "POST"
}

enum FilesHTTPRequestBody: Equatable, Sendable {
    case none
    case file(URL)
}

struct FilesHTTPRequest: Equatable, Sendable {
    let endpoint: FilesLoopbackEndpoint
    let method: FilesHTTPMethod
    let relativePath: String
    let headers: [String: String]
    let body: FilesHTTPRequestBody
    let timeout: Duration
}

struct FilesHTTPResponse: Equatable, Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

struct FilesHTTPDownloadResponse: Equatable, Sendable {
    let statusCode: Int
    let headers: [String: String]
    let bytesWritten: Int64
    let suggestedFileName: String?
}

enum FilesHTTPTransportError: Error, Equatable, Sendable {
    case invalidRequest
    case connection
    case responseTooLarge
    case localFile
}

protocol FilesHTTPTransporting: Sendable {
    func response(
        for request: FilesHTTPRequest,
        maximumBodyBytes: Int
    ) async throws -> FilesHTTPResponse

    func download(
        for request: FilesHTTPRequest,
        to destinationURL: URL,
        maximumBytes: Int64
    ) async throws -> FilesHTTPDownloadResponse
}

actor URLSessionFilesHTTPTransport: FilesHTTPTransporting {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.connectionProxyDictionary = [:]
        configuration.httpAdditionalHeaders = ["Accept-Encoding": "identity"]
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30 * 60

        self.session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func response(
        for request: FilesHTTPRequest,
        maximumBodyBytes: Int
    ) async throws -> FilesHTTPResponse {
        guard maximumBodyBytes > 0 else { throw FilesHTTPTransportError.invalidRequest }
        let urlRequest = try Self.makeURLRequest(request)
        do {
            let receiver = FilesBoundedDownloadDelegate(
                endpoint: request.endpoint,
                maximumBytes: Int64(maximumBodyBytes),
                sink: .memory
            )
            let task = session.downloadTask(with: urlRequest)
            task.delegate = receiver
            let result = try await receiver.run(task)
            return FilesHTTPResponse(
                statusCode: result.statusCode,
                headers: result.headers,
                body: result.body
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as FilesHTTPTransportError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            try Task.checkCancellation()
            throw FilesHTTPTransportError.connection
        } catch is URLError {
            throw FilesHTTPTransportError.connection
        } catch {
            throw FilesHTTPTransportError.localFile
        }
    }

    func download(
        for request: FilesHTTPRequest,
        to destinationURL: URL,
        maximumBytes: Int64
    ) async throws -> FilesHTTPDownloadResponse {
        guard maximumBytes > 0,
              destinationURL.isFileURL else {
            throw FilesHTTPTransportError.invalidRequest
        }
        let urlRequest = try Self.makeURLRequest(request)
        do {
            let receiver = FilesBoundedDownloadDelegate(
                endpoint: request.endpoint,
                maximumBytes: maximumBytes,
                sink: .file(destinationURL)
            )
            let task = session.downloadTask(with: urlRequest)
            task.delegate = receiver
            let result = try await receiver.run(task)
            return FilesHTTPDownloadResponse(
                statusCode: result.statusCode,
                headers: result.headers,
                bytesWritten: result.bytesWritten,
                suggestedFileName: result.suggestedFileName
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as FilesHTTPTransportError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            try Task.checkCancellation()
            throw FilesHTTPTransportError.connection
        } catch is URLError {
            throw FilesHTTPTransportError.connection
        } catch {
            throw FilesHTTPTransportError.localFile
        }
    }

    private static func makeURLRequest(_ request: FilesHTTPRequest) throws -> URLRequest {
        guard !request.relativePath.isEmpty,
              !request.relativePath.hasPrefix("/"),
              !request.relativePath.contains(".."),
              !request.relativePath.contains("?"),
              !request.relativePath.contains("#"),
              let url = URL(string: request.relativePath, relativeTo: request.endpoint.baseURL)?.absoluteURL,
              url.scheme == "http",
              url.host == "127.0.0.1",
              url.port == Int(request.endpoint.port) else {
            throw FilesHTTPTransportError.invalidRequest
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = request.timeout.timeInterval
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        switch request.body {
        case .none:
            break
        case let .file(url):
            guard url.isFileURL,
                  let stream = InputStream(url: url) else {
                throw FilesHTTPTransportError.invalidRequest
            }
            urlRequest.httpBodyStream = stream
        }
        return urlRequest
    }

}

private struct FilesBoundedHTTPResult: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
    let bytesWritten: Int64
    let suggestedFileName: String?
}

private final class FilesBoundedDownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    enum Sink: Sendable {
        case memory
        case file(URL)
    }

    private struct State {
        var continuation: CheckedContinuation<FilesBoundedHTTPResult, any Error>?
        var task: URLSessionDownloadTask?
        var result: FilesBoundedHTTPResult?
        var forcedError: FilesHTTPTransportError?
        var callerCancelled = false
        var movedDestination = false
        var completed = false
    }

    private let endpoint: FilesLoopbackEndpoint
    private let maximumBytes: Int64
    private let sink: Sink
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        endpoint: FilesLoopbackEndpoint,
        maximumBytes: Int64,
        sink: Sink
    ) {
        self.endpoint = endpoint
        self.maximumBytes = maximumBytes
        self.sink = sink
    }

    func run(_ task: URLSessionDownloadTask) async throws -> FilesBoundedHTTPResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelImmediately = state.withLock { state in
                    guard !state.callerCancelled else {
                        state.completed = true
                        return true
                    }
                    state.continuation = continuation
                    state.task = task
                    task.resume()
                    return false
                }
                if cancelImmediately {
                    task.cancel()
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let task = state.withLock { state in
                state.callerCancelled = true
                return state.task
            }
            task?.cancel()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let isTooLarge = totalBytesWritten > maximumBytes ||
            (totalBytesExpectedToWrite >= 0 && totalBytesExpectedToWrite > maximumBytes)
        guard isTooLarge else { return }
        state.withLock { state in
            if state.forcedError == nil {
                state.forcedError = .responseTooLarge
            }
        }
        downloadTask.cancel()
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let response = try validate(downloadTask.response)
            let headers = Self.headers(from: response)
            let byteCount = try Self.fileSize(at: location)
            guard byteCount <= maximumBytes else {
                throw FilesHTTPTransportError.responseTooLarge
            }
            if let expected = try Self.contentLength(from: response) {
                guard expected <= maximumBytes else {
                    throw FilesHTTPTransportError.responseTooLarge
                }
                guard expected == byteCount else {
                    throw FilesHTTPTransportError.connection
                }
            }

            let body: Data
            switch sink {
            case .memory:
                body = try Data(contentsOf: location, options: .mappedIfSafe)
                guard Int64(body.count) == byteCount else {
                    throw FilesHTTPTransportError.localFile
                }
            case let .file(destinationURL):
                try FileManager.default.moveItem(at: location, to: destinationURL)
                body = Data()
            }
            let hasDisposition = headers["content-disposition"] != nil
            let result = FilesBoundedHTTPResult(
                statusCode: response.statusCode,
                headers: headers,
                body: body,
                bytesWritten: byteCount,
                suggestedFileName: hasDisposition ? response.suggestedFilename : nil
            )
            let accepted = state.withLock { state in
                guard !state.completed,
                      !state.callerCancelled,
                      state.forcedError == nil else {
                    return false
                }
                state.result = result
                if case .file = sink {
                    state.movedDestination = true
                }
                return true
            }
            if !accepted, case let .file(destinationURL) = sink {
                try? FileManager.default.removeItem(at: destinationURL)
            }
        } catch let error as FilesHTTPTransportError {
            state.withLock { state in
                if state.forcedError == nil {
                    state.forcedError = error
                }
            }
        } catch {
            state.withLock { state in
                if state.forcedError == nil {
                    state.forcedError = .localFile
                }
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        let completion = state.withLock { state -> (
            CheckedContinuation<FilesBoundedHTTPResult, any Error>,
            Result<FilesBoundedHTTPResult, any Error>,
            Bool
        )? in
            guard !state.completed, let continuation = state.continuation else {
                return nil
            }
            state.completed = true
            state.continuation = nil
            state.task = nil

            let result: Result<FilesBoundedHTTPResult, any Error>
            if state.callerCancelled {
                result = .failure(CancellationError())
            } else if let forcedError = state.forcedError {
                result = .failure(forcedError)
            } else if error != nil {
                result = .failure(FilesHTTPTransportError.connection)
            } else if let value = state.result {
                result = .success(value)
            } else {
                result = .failure(FilesHTTPTransportError.connection)
            }
            let removeDestination: Bool
            switch result {
            case .success:
                removeDestination = false
            case .failure:
                removeDestination = state.movedDestination
            }
            return (continuation, result, removeDestination)
        }

        guard let completion else { return }
        if completion.2, case let .file(destinationURL) = sink {
            try? FileManager.default.removeItem(at: destinationURL)
        }
        completion.0.resume(with: completion.1)
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    private func validate(_ response: URLResponse?) throws -> HTTPURLResponse {
        guard let response = response as? HTTPURLResponse,
              response.url?.scheme == "http",
              response.url?.host == "127.0.0.1",
              response.url?.port == Int(endpoint.port) else {
            throw FilesHTTPTransportError.connection
        }
        return response
    }

    private static func fileSize(at url: URL) throws -> Int64 {
        var information = stat()
        guard lstat(url.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_size >= 0 else {
            throw FilesHTTPTransportError.localFile
        }
        return information.st_size
    }

    private static func headers(from response: HTTPURLResponse) -> [String: String] {
        response.allHeaderFields.reduce(into: [:]) { result, pair in
            guard let name = pair.key as? String else { return }
            result[name.lowercased()] = String(describing: pair.value)
        }
    }

    private static func contentLength(from response: HTTPURLResponse) throws -> Int64? {
        guard let value = response.value(forHTTPHeaderField: "Content-Length") else {
            return nil
        }
        guard let length = Int64(value), length >= 0 else {
            throw FilesHTTPTransportError.connection
        }
        return length
    }
}

actor RemarkableFilesClient {
    static let maximumUploadBytes: Int64 = 100_000_000
    static let maximumDownloadBytes: Int64 = 2_000_000_000

    private static let listBodyLimit = 2 * 1_024 * 1_024
    private static let confirmationBodyLimit = 64 * 1_024
    private static let uploadSuccess = Data(#"{"status":"Upload successful"}"#.utf8)
    private static let operationQueue = FilesGlobalOperationQueue()

    private let tunnel: FilesSSHTunnel
    private let httpTransport: any FilesHTTPTransporting
    private let cache: FilesTransferCache

    init(
        tunnel: FilesSSHTunnel,
        httpTransport: any FilesHTTPTransporting = URLSessionFilesHTTPTransport(),
        cacheRootURL: URL? = nil
    ) {
        self.tunnel = tunnel
        self.httpTransport = httpTransport
        self.cache = FilesTransferCache(rootURL: cacheRootURL)
    }

    func probeReadiness() async throws {
        _ = try await listRoot()
    }

    func listRoot() async throws -> [RemarkableLibraryItem] {
        try await Self.operationQueue.enqueue { [self] in
            try await listCore(folderID: nil, timeout: .seconds(10))
        }
    }

    func listFolder(_ id: UUID) async throws -> [RemarkableLibraryItem] {
        try await Self.operationQueue.enqueue { [self] in
            try await listCore(folderID: id, timeout: .seconds(10))
        }
    }

    func importFile(
        at sourceURL: URL,
        to destinationFolderID: UUID? = nil
    ) async throws -> FilesUploadReceipt {
        try await Self.operationQueue.enqueue { [self] in
            try await importCore(
                sourceURL: sourceURL,
                destinationFolderID: destinationFolderID
            )
        }
    }

    func exportDocument(
        _ id: UUID,
        format: FilesExportFormat,
        to destinationURL: URL,
        overwrite: Bool = false
    ) async throws -> FilesDownloadReceipt {
        try await Self.operationQueue.enqueue { [self] in
            try await exportCore(
                id: id,
                format: format,
                destinationURL: destinationURL,
                overwrite: overwrite
            )
        }
    }

    func sweepStaleCache(now: Date = Date()) async {
        await cache.sweep(olderThan: now.addingTimeInterval(-86_400), maximumEntries: 64)
    }

    private func listCore(
        folderID: UUID?,
        timeout: Duration
    ) async throws -> [RemarkableLibraryItem] {
        let path = folderID.map { "documents/\(Self.canonical($0))" } ?? "documents/"
        let response = try await send(
            FilesHTTPRequest(
                endpoint: try await tunnelEndpoint(),
                method: .get,
                relativePath: path,
                headers: [:],
                body: .none,
                timeout: timeout
            ),
            maximumBodyBytes: Self.listBodyLimit
        )
        guard response.statusCode == 200 else {
            throw FilesTransferError(
                .rejected,
                "The tablet could not list that folder.",
                statusCode: response.statusCode
            )
        }
        return try Self.decodeListing(response.body, expectedParentID: folderID)
    }

    private func importCore(
        sourceURL: URL,
        destinationFolderID: UUID?
    ) async throws -> FilesUploadReceipt {
        let source = try FilesImportSource.validated(sourceURL)
        defer { source.close() }
        let before = try await listCore(folderID: destinationFolderID, timeout: .seconds(10))
        await cache.sweep(olderThan: Date().addingTimeInterval(-86_400), maximumEntries: 64)
        let endpoint = try await tunnelEndpoint()
        let multipart = try await cache.buildMultipartBody(for: source)
        let request = FilesHTTPRequest(
            endpoint: endpoint,
            method: .post,
            relativePath: "upload",
            headers: [
                "Content-Length": String(multipart.byteCount),
                "Content-Type": "multipart/form-data; boundary=\(multipart.boundary)",
            ],
            body: .file(multipart.url),
            timeout: .seconds(120)
        )

        let response: FilesHTTPResponse
        do {
            response = try await send(
                request,
                maximumBodyBytes: Self.confirmationBodyLimit
            )
        } catch is CancellationError {
            await cache.remove(multipart.url)
            // The request has crossed into the transport. Cancellation can no
            // longer prove that Xochitl did not accept the document, so never
            // turn this into a definite failure that encourages a retry.
            throw FilesTransferError(
                .ambiguousResult,
                "Mirror could not confirm whether the tablet received the file. " +
                    "Check the tablet, then refresh before retrying."
            )
        } catch let original as FilesTransferError where
            original.failure == .connection ||
            original.failure == .protocolViolation ||
            original.failure == .localFile {
            await cache.remove(multipart.url)
            return try await reconcileUnconfirmedUpload(
                before: before,
                destinationFolderID: destinationFolderID,
                sourceFileName: source.fileName,
                originalFailure: original
            )
        } catch {
            await cache.remove(multipart.url)
            throw error
        }
        await cache.remove(multipart.url)

        guard response.statusCode == 201 else {
            throw FilesTransferError(
                .rejected,
                "The tablet rejected the upload.",
                statusCode: response.statusCode
            )
        }
        guard response.body == Self.uploadSuccess else {
            return try await reconcileUnconfirmedUpload(
                before: before,
                destinationFolderID: destinationFolderID,
                sourceFileName: source.fileName,
                originalFailure: FilesTransferError(
                    .protocolViolation,
                    "The tablet returned an unexpected upload confirmation."
                )
            )
        }

        let after: [RemarkableLibraryItem]
        do {
            after = try await listCore(folderID: destinationFolderID, timeout: .seconds(5))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FilesTransferError(
                .ambiguousResult,
                "The tablet accepted the upload, but its new document could not be identified. Refresh before retrying."
            )
        }
        let item = try Self.resolveUploadedItem(
            before: before,
            after: after,
            destinationFolderID: destinationFolderID
        )
        return FilesUploadReceipt(
            sourceFileName: source.fileName,
            destinationFolderID: destinationFolderID,
            item: item
        )
    }

    private func reconcileUnconfirmedUpload(
        before: [RemarkableLibraryItem],
        destinationFolderID: UUID?,
        sourceFileName: String,
        originalFailure: FilesTransferError
    ) async throws -> FilesUploadReceipt {
        do {
            let after = try await listCore(folderID: destinationFolderID, timeout: .seconds(5))
            _ = try Self.resolveUploadedItem(
                before: before,
                after: after,
                destinationFolderID: destinationFolderID
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FilesTransferError(
                .ambiguousResult,
                "The upload response was lost and its result could not be reconciled. Refresh before retrying."
            )
        }
        _ = sourceFileName
        _ = originalFailure
        throw FilesTransferError(
            .ambiguousResult,
            "A new document appeared, but the tablet response was not exact. Refresh before retrying."
        )
    }

    private func exportCore(
        id: UUID,
        format: FilesExportFormat,
        destinationURL: URL,
        overwrite: Bool
    ) async throws -> FilesDownloadReceipt {
        let destination = try FilesDestination.validated(destinationURL, overwrite: overwrite)
        let partialURL = destination.parent.appending(
            path: ".\(destination.url.lastPathComponent).\(UUID().uuidString).partial"
        )
        let request = FilesHTTPRequest(
            endpoint: try await tunnelEndpoint(),
            method: .get,
            relativePath: "download/\(Self.canonical(id))/\(format.rawValue)",
            headers: [:],
            body: .none,
            timeout: .seconds(20)
        )

        do {
            let response = try await download(
                request,
                to: partialURL,
                maximumBytes: Self.maximumDownloadBytes
            )
            guard response.statusCode == 200 else {
                throw FilesTransferError(
                    .rejected,
                    "The tablet could not prepare that document export.",
                    statusCode: response.statusCode
                )
            }
            try FilesDestination.synchronize(partialURL)
            try Task.checkCancellation()
            try FilesDestination.publish(
                partialURL,
                to: destination.url,
                overwrite: overwrite
            )
            return FilesDownloadReceipt(
                bytesWritten: response.bytesWritten,
                suggestedFileName: FilesSafeFileName.sanitizeOptional(
                    response.suggestedFileName,
                    stripping: format.fileExtension
                ),
                savedURL: destination.url
            )
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: partialURL)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: partialURL)
            throw error
        }
    }

    private func send(
        _ request: FilesHTTPRequest,
        maximumBodyBytes: Int
    ) async throws -> FilesHTTPResponse {
        do {
            return try await httpTransport.response(
                for: request,
                maximumBodyBytes: maximumBodyBytes
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as FilesHTTPTransportError {
            throw Self.mapHTTPError(error)
        }
    }

    private func download(
        _ request: FilesHTTPRequest,
        to destinationURL: URL,
        maximumBytes: Int64
    ) async throws -> FilesHTTPDownloadResponse {
        do {
            return try await httpTransport.download(
                for: request,
                to: destinationURL,
                maximumBytes: maximumBytes
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as FilesHTTPTransportError {
            throw Self.mapHTTPError(error)
        }
    }

    private func tunnelEndpoint() async throws -> FilesLoopbackEndpoint {
        do {
            return try await tunnel.endpoint()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FilesTransferError(
                .connection,
                "The secure tablet file connection is unavailable."
            )
        }
    }

    private static func mapHTTPError(_ error: FilesHTTPTransportError) -> FilesTransferError {
        switch error {
        case .invalidRequest:
            FilesTransferError(.configuration, "The local tablet file request is invalid.")
        case .connection:
            FilesTransferError(.connection, "The tablet file service is unavailable through the secure connection.")
        case .responseTooLarge:
            FilesTransferError(.protocolViolation, "The tablet returned more file data than Mirror can safely accept.")
        case .localFile:
            FilesTransferError(.localFile, "Mirror could not read or write the local transfer file.")
        }
    }

    private static func decodeListing(
        _ data: Data,
        expectedParentID: UUID?
    ) throws -> [RemarkableLibraryItem] {
        let decoded: [FilesListingItemDTO]
        do {
            decoded = try JSONDecoder().decode([FilesListingItemDTO].self, from: data)
        } catch {
            throw FilesTransferError(.protocolViolation, "The tablet returned an invalid file listing.")
        }

        var identifiers = Set<UUID>()
        return try decoded.enumerated().map { offset, dto in
            let item = try dto.item(number: offset + 1)
            guard item.parentID == expectedParentID else {
                throw FilesTransferError(
                    .protocolViolation,
                    "The tablet returned an item outside the requested folder."
                )
            }
            guard identifiers.insert(item.id).inserted else {
                throw FilesTransferError(
                    .protocolViolation,
                    "The tablet returned a duplicate document identifier."
                )
            }
            return item
        }
    }

    private static func resolveUploadedItem(
        before: [RemarkableLibraryItem],
        after: [RemarkableLibraryItem],
        destinationFolderID: UUID?
    ) throws -> RemarkableLibraryItem {
        let beforeIDs = Set(before.map(\.id))
        let added = after.filter { !beforeIDs.contains($0.id) }
        guard added.count == 1,
              let item = added.first,
              item.kind == .document,
              item.parentID == destinationFolderID else {
            throw FilesTransferError(
                .ambiguousResult,
                "The uploaded document could not be identified uniquely. Refresh before retrying."
            )
        }
        return item
    }

    private static func canonical(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }
}

private struct FilesImportSource: Sendable {
    let descriptor: Int32
    let fileName: String
    let contentType: String
    let byteCount: Int64

    static func validated(_ url: URL) throws -> FilesImportSource {
        guard url.isFileURL else {
            throw FilesTransferError(.invalidRequest, "Choose a local PDF or EPUB file to send.")
        }
        let normalized = url.standardizedFileURL
        let descriptor = open(normalized.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw FilesTransferError(.invalidRequest, "The selected file is no longer available.")
        }
        var shouldClose = true
        defer {
            if shouldClose { Darwin.close(descriptor) }
        }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG else {
            throw FilesTransferError(.invalidRequest, "Choose one PDF or EPUB file to send.")
        }
        let byteCount = information.st_size
        guard byteCount >= 0,
              byteCount <= RemarkableFilesClient.maximumUploadBytes else {
            throw FilesTransferError(.invalidRequest, "The tablet file service accepts files up to 100 MB.")
        }

        let contentType: String
        switch normalized.pathExtension.lowercased() {
        case "pdf":
            contentType = "application/pdf"
        case "epub":
            contentType = "application/epub+zip"
        default:
            throw FilesTransferError(.invalidRequest, "Only PDF and DRM-free EPUB files can be sent to the tablet.")
        }
        let fileName = FilesSafeFileName.uploadName(normalized.lastPathComponent)
        shouldClose = false
        return FilesImportSource(
            descriptor: descriptor,
            fileName: fileName,
            contentType: contentType,
            byteCount: byteCount
        )
    }

    func close() {
        Darwin.close(descriptor)
    }
}

private struct FilesDestination: Sendable {
    let url: URL
    let parent: URL

    static func validated(_ url: URL, overwrite: Bool) throws -> FilesDestination {
        guard url.isFileURL,
              !url.lastPathComponent.isEmpty,
              url.lastPathComponent != ".",
              url.lastPathComponent != ".." else {
            throw FilesTransferError(.invalidRequest, "Choose where to save the downloaded file.")
        }
        let normalized = url.standardizedFileURL
        let parent = normalized.deletingLastPathComponent()
        var parentInfo = stat()
        guard lstat(parent.path, &parentInfo) == 0,
              parentInfo.st_mode & S_IFMT == S_IFDIR else {
            throw FilesTransferError(.invalidRequest, "Choose an available folder to save the file.")
        }

        var destinationInfo = stat()
        let exists = lstat(normalized.path, &destinationInfo) == 0
        if exists {
            guard overwrite else {
                throw FilesTransferError(.invalidRequest, "A file with that name already exists.")
            }
            guard destinationInfo.st_mode & S_IFMT == S_IFREG,
                  destinationInfo.st_nlink == 1 else {
                throw FilesTransferError(.invalidRequest, "Choose a different save location.")
            }
        }
        return FilesDestination(url: normalized, parent: parent)
    }

    static func synchronize(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    static func publish(_ partialURL: URL, to destinationURL: URL, overwrite: Bool) throws {
        let result = overwrite
            ? rename(partialURL.path, destinationURL.path)
            : renamex_np(partialURL.path, destinationURL.path, UInt32(RENAME_EXCL))
        guard result == 0 else {
            throw FilesTransferError(.localFile, "Mirror could not publish the downloaded file.")
        }
    }
}

private enum FilesSafeFileName {
    static func uploadName(_ value: String) -> String {
        sanitize(value, stripping: nil, fallback: "reMarkable document")
            .replacingOccurrences(of: "\"", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
    }

    static func sanitizeOptional(_ value: String?, stripping extension: String?) -> String? {
        guard let value else { return nil }
        return sanitize(value, stripping: `extension`, fallback: "reMarkable document")
    }

    static func sanitize(
        _ value: String,
        stripping extension: String?,
        fallback: String
    ) -> String {
        let leaf = value
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last
            .map(String.init) ?? ""
        var result = String(leaf.map { character in
            if character == "/" || character == ":" || character == "\0" ||
                character.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
                return Character("-")
            }
            return character
        }).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))

        if let `extension`, result.lowercased().hasSuffix(`extension`.lowercased()) {
            result.removeLast(`extension`.count)
            result = result.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        }
        if result.isEmpty || result == "." || result == ".." {
            result = fallback
        }
        while result.utf8.count > 180, !result.isEmpty {
            result.removeLast()
        }
        return result.isEmpty ? fallback : result
    }
}

private actor FilesGlobalOperationQueue {
    private var tail: Task<Void, Never>?

    func enqueue<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let predecessor = tail
        let task = Task<T, Error> {
            if let predecessor { await predecessor.value }
            try Task.checkCancellation()
            return try await operation()
        }
        tail = Task {
            _ = try? await task.value
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

private actor FilesTransferCache {
    struct MultipartBody: Sendable {
        let url: URL
        let boundary: String
        let byteCount: Int64
    }

    private let rootURL: URL

    init(rootURL: URL?) {
        self.rootURL = rootURL ?? URL.cachesDirectory
            .appending(path: "com.ifixrobots.ReMarkableMirror", directoryHint: .isDirectory)
            .appending(path: "files", directoryHint: .isDirectory)
    }

    func buildMultipartBody(for source: FilesImportSource) async throws -> MultipartBody {
        try prepareRoot()
        let boundary = "----ReMarkableMirror\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let destination = rootURL.appending(path: "\(UUID().uuidString).multipart")
        let descriptor = open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw FilesTransferError(.localFile, "Mirror could not create the upload staging file.")
        }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)

        do {
            let header = "--\(boundary)\r\n" +
                "Content-Disposition: form-data; name=\"file\"; filename=\"\(source.fileName)\"\r\n" +
                "Content-Type: \(source.contentType)\r\n\r\n"
            try output.write(contentsOf: Data(header.utf8))
            var copied: Int64 = 0
            var buffer = [UInt8](repeating: 0, count: 128 * 1_024)
            while true {
                try Task.checkCancellation()
                let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(source.descriptor, bytes.baseAddress, bytes.count)
                }
                if bytesRead == 0 { break }
                if bytesRead < 0 {
                    if errno == EINTR { continue }
                    throw FilesTransferError(.localFile, "Mirror could not read the selected source file.")
                }
                copied += Int64(bytesRead)
                guard copied <= source.byteCount else {
                    throw FilesTransferError(
                        .sourceFileChanged,
                        "The source file grew while Mirror was preparing its upload body."
                    )
                }
                try buffer.withUnsafeBytes { bytes in
                    try output.write(contentsOf: Data(bytes.prefix(bytesRead)))
                }
            }
            guard copied == source.byteCount else {
                throw FilesTransferError(
                    .sourceFileChanged,
                    "The source file shrank while Mirror was preparing its upload body."
                )
            }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            try output.synchronize()
            try output.close()
            var information = stat()
            guard lstat(destination.path, &information) == 0,
                  information.st_mode & S_IFMT == S_IFREG,
                  information.st_size >= 0 else {
                throw FilesTransferError(.localFile, "Mirror could not inspect the upload staging file.")
            }
            return MultipartBody(
                url: destination,
                boundary: boundary,
                byteCount: information.st_size
            )
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func remove(_ url: URL) {
        guard contains(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func sweep(olderThan cutoff: Date, maximumEntries: Int) {
        guard maximumEntries > 0 else { return }
        do {
            try prepareRoot()
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
            let contents = try FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
            let entries = contents.compactMap { url -> (URL, Date)? in
                guard contains(url),
                      let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true else { return nil }
                return (url, values.contentModificationDate ?? .distantPast)
            }.sorted { $0.1 > $1.1 }
            for (index, entry) in entries.enumerated()
                where entry.1 < cutoff || index >= maximumEntries {
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
        var information = stat()
        guard lstat(rootURL.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR,
              information.st_uid == getuid(),
              information.st_nlink >= 1,
              chmod(rootURL.path, S_IRWXU) == 0 else {
            throw FilesTransferError(.localFile, "Mirror's transfer cache is unavailable.")
        }
    }

    private func contains(_ url: URL) -> Bool {
        let root = rootURL.standardizedFileURL.path + "/"
        let candidate = url.standardizedFileURL.path
        return candidate.hasPrefix(root) && !candidate.dropFirst(root.count).contains("/")
    }
}

private struct FilesListingItemDTO: Decodable {
    let bookmarked: Bool
    let id: String?
    let modifiedClient: FilesJSONScalar?
    let parent: FilesJSONScalar?
    let type: String?
    let visibleName: String?
    let legacyVisibleName: String?
    let currentPage: FilesJSONScalar?
    let fileType: String?

    enum CodingKeys: String, CodingKey {
        case bookmarked = "Bookmarked"
        case id = "ID"
        case modifiedClient = "ModifiedClient"
        case parent = "Parent"
        case type = "Type"
        case visibleName = "VisibleName"
        case legacyVisibleName = "VissibleName"
        case currentPage = "CurrentPage"
        case fileType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookmarked = try container.decodeIfPresent(Bool.self, forKey: .bookmarked) ?? false
        id = try container.decodeIfPresent(String.self, forKey: .id)
        modifiedClient = try container.decodeIfPresent(FilesJSONScalar.self, forKey: .modifiedClient)
        parent = try container.decodeIfPresent(FilesJSONScalar.self, forKey: .parent)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        visibleName = try container.decodeIfPresent(String.self, forKey: .visibleName)
        legacyVisibleName = try container.decodeIfPresent(String.self, forKey: .legacyVisibleName)
        currentPage = try container.decodeIfPresent(FilesJSONScalar.self, forKey: .currentPage)
        fileType = try container.decodeIfPresent(String.self, forKey: .fileType)
    }

    func item(number: Int) throws -> RemarkableLibraryItem {
        guard let id, let identifier = UUID(uuidString: id) else {
            throw FilesTransferError(.protocolViolation, "Tablet item \(number) has an invalid identifier.")
        }
        let parentID: UUID?
        switch parent {
        case let .string(value):
            if value.isEmpty {
                parentID = nil
            } else if let identifier = UUID(uuidString: value) {
                parentID = identifier
            } else {
                throw FilesTransferError(.protocolViolation, "Tablet item \(number) has an invalid parent identifier.")
            }
        default:
            throw FilesTransferError(.protocolViolation, "Tablet item \(number) has an invalid parent value.")
        }
        guard visibleName != nil || legacyVisibleName != nil else {
            throw FilesTransferError(.protocolViolation, "Tablet item \(number) has no visible name.")
        }
        let kind: RemarkableLibraryItemKind
        switch type {
        case "DocumentType": kind = .document
        case "CollectionType": kind = .collection
        default:
            throw FilesTransferError(.protocolViolation, "Tablet item \(number) has an unknown type.")
        }
        if kind == .document, fileType?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw FilesTransferError(.protocolViolation, "Tablet document \(number) has no file type.")
        }
        let currentPageValue: Int?
        switch currentPage {
        case let .integer(value): currentPageValue = value
        case let .string(value): currentPageValue = Int(value)
        case nil: currentPageValue = nil
        }
        if currentPage != nil, currentPageValue == nil {
            throw FilesTransferError(.protocolViolation, "Tablet item \(number) has an invalid CurrentPage value.")
        }
        let modified: String?
        switch modifiedClient {
        case let .integer(value): modified = String(value)
        case let .string(value): modified = value
        case nil: modified = nil
        }
        return RemarkableLibraryItem(
            id: identifier,
            visibleName: visibleName,
            legacyVisibleName: legacyVisibleName,
            parentID: parentID,
            kind: kind,
            isBookmarked: bookmarked,
            modifiedClient: modified,
            currentPage: currentPageValue,
            fileType: fileType
        )
    }
}

private enum FilesJSONScalar: Decodable {
    case string(String)
    case integer(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else {
            throw DecodingError.typeMismatch(
                FilesJSONScalar.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected a string or integer scalar."
                )
            )
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
