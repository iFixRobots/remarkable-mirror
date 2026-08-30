import Darwin
import Foundation

enum TabletBackupError: LocalizedError {
    case tabletUnreachable
    case tunnelFailed(reason: String)
    case unexpectedListing
    case documentFailed(name: String)
    case destinationFailed
    case backupEmpty
    case uploadRejected(name: String)

    var errorDescription: String? {
        switch self {
        case .tabletUnreachable:
            "The tablet isn’t answering over USB‑C. Turn on Settings > " +
                "Storage > USB web interface, reconnect the cable, and try again."
        case let .tunnelFailed(reason):
            "This tablet keeps its USB web interface private, so Mirror " +
                "connects through its secure SSH link — but that link " +
                "failed: \(reason) Reconnect the cable, keep the tablet " +
                "awake, and try again."
        case .unexpectedListing:
            "The tablet answered, but its document list couldn’t be read. " +
                "Toggle the USB web interface off and on, then try again."
        case let .documentFailed(name):
            "“\(name)” couldn’t be downloaded. Keep the tablet awake and " +
                "connected, then try the backup again."
        case .destinationFailed:
            "The backup folder couldn’t be created in Documents."
        case .backupEmpty:
            "That folder has no .rmdoc backup files in it."
        case let .uploadRejected(name):
            "The tablet didn’t accept “\(name)”. Keep it awake and " +
                "connected with the USB web interface on, then try again."
        }
    }
}

struct TabletBackupProgress: Sendable {
    let completed: Int
    let total: Int
}

/// Downloads every document from the tablet's stock USB web interface as a
/// full-fidelity .rmdoc archive. On a stock tablet the interface answers
/// directly at 10.11.99.1 — it only needs its Settings toggle and the
/// cable, no pairing. On a Mirror-provisioned tablet the interface is
/// rebound to loopback, so the service reaches it through the same SSH
/// local forward the Files feature uses.
struct TabletBackupService: Sendable {
    private static let directHost = "10.11.99.1"
    private static let directBase = URL(string: "http://\(directHost)")!
    private static let directProbeTimeoutMilliseconds: Int32 = 2_000

    private struct Entry {
        let id: String
        let name: String
        let isFolder: Bool
    }

    private struct ResolvedTransport: Sendable {
        let base: URL
        let registry: OwnedProcessRegistry?

        func shutDown() async {
            if let registry {
                try? await registry.shutdown()
            }
        }
    }

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 120
        session = URLSession(configuration: configuration)
    }

    /// Returns the number of documents saved and the destination folder.
    func backUpAllDocuments(
        onProgress: @Sendable @escaping (TabletBackupProgress) -> Void
    ) async throws -> (count: Int, destination: URL) {
        let transport = try await resolveTransport()
        do {
            let result = try await performBackup(
                base: transport.base,
                onProgress: onProgress
            )
            await transport.shutDown()
            return result
        } catch {
            await transport.shutDown()
            throw error
        }
    }

    private func performBackup(
        base: URL,
        onProgress: @Sendable @escaping (TabletBackupProgress) -> Void
    ) async throws -> (count: Int, destination: URL) {
        let documents = try await collectDocuments(
            base: base,
            folderID: "",
            path: []
        )
        let destination = try makeDestination()

        var completed = 0
        for document in documents {
            let folder = document.path.reduce(destination) {
                $0.appendingPathComponent($1, isDirectory: true)
            }
            try? FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true
            )
            let file = folder.appendingPathComponent(
                "\(document.name).rmdoc",
                isDirectory: false
            )
            do {
                let (data, response) = try await session.data(
                    from: base.appending(
                        path: "download/\(document.id)/rmdoc"
                    )
                )
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      !data.isEmpty else {
                    throw TabletBackupError.documentFailed(name: document.name)
                }
                try data.write(to: file)
            } catch let error as TabletBackupError {
                throw error
            } catch {
                throw TabletBackupError.documentFailed(name: document.name)
            }
            completed += 1
            onProgress(TabletBackupProgress(
                completed: completed,
                total: documents.count
            ))
        }
        return (documents.count, destination)
    }

    private struct FoundDocument {
        let id: String
        let name: String
        let path: [String]
    }

    private func collectDocuments(
        base: URL,
        folderID: String,
        path: [String]
    ) async throws -> [FoundDocument] {
        let listing = try await list(base: base, folderID: folderID)
        var found: [FoundDocument] = []
        for entry in listing {
            if entry.isFolder {
                found += try await collectDocuments(
                    base: base,
                    folderID: entry.id,
                    path: path + [entry.name]
                )
            } else {
                found.append(FoundDocument(
                    id: entry.id,
                    name: entry.name,
                    path: path
                ))
            }
        }
        return found
    }

    private func list(base: URL, folderID: String) async throws -> [Entry] {
        let url = base.appending(path: "documents/\(folderID)")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw TabletBackupError.tabletUnreachable
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let items = try? JSONSerialization.jsonObject(with: data)
                  as? [[String: Any]] else {
            throw TabletBackupError.unexpectedListing
        }
        return items.compactMap { item in
            guard let id = item["ID"] as? String,
                  let type = item["Type"] as? String else { return nil }
            let rawName = (item["VisibleName"] as? String) ?? "Untitled"
            return Entry(
                id: id,
                name: Self.safeName(rawName),
                isFolder: type == "CollectionType"
            )
        }
    }

    private func makeDestination() throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        let destination = documents
            .appendingPathComponent("reMarkable Backup", isDirectory: true)
            .appendingPathComponent(
                formatter.string(from: Date()),
                isDirectory: true
            )
        do {
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: true
            )
        } catch {
            throw TabletBackupError.destinationFailed
        }
        return destination
    }

    /// Uploads every .rmdoc in the folder back to the tablet through the
    /// stock USB web interface. The interface places uploads in the
    /// tablet's home; folder structure is not recreated.
    func restoreAllDocuments(
        from folder: URL,
        onProgress: @Sendable @escaping (TabletBackupProgress) -> Void
    ) async throws -> Int {
        let files = Self.rmdocFiles(under: folder)
        guard !files.isEmpty else { throw TabletBackupError.backupEmpty }

        let transport = try await resolveTransport()
        do {
            _ = try await list(base: transport.base, folderID: "")

            var completed = 0
            for file in files {
                try await upload(file, base: transport.base)
                completed += 1
                onProgress(TabletBackupProgress(
                    completed: completed,
                    total: files.count
                ))
            }
        } catch {
            await transport.shutDown()
            throw error
        }
        await transport.shutDown()
        return files.count
    }

    static func latestBackupFolder() -> URL? {
        let root = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("reMarkable Backup", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        )) ?? []
        return folders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .first
    }

    private func upload(_ file: URL, base: URL) async throws {
        let name = file.lastPathComponent
        guard let contents = try? Data(contentsOf: file) else {
            throw TabletBackupError.uploadRejected(name: name)
        }
        let boundary = "rmmirror-\(UUID().uuidString)"
        var request = URLRequest(url: base.appending(path: "upload"))
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        var body = Data(
            (
                "--\(boundary)\r\n" +
                "Content-Disposition: form-data; name=\"file\"; " +
                "filename=\"\(name)\"\r\n" +
                "Content-Type: application/zip\r\n\r\n"
            ).utf8
        )
        body.append(contents)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        let response: URLResponse
        do {
            (_, response) = try await session.upload(for: request, from: body)
        } catch {
            throw TabletBackupError.tabletUnreachable
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode,
              (200...299).contains(status) else {
            throw TabletBackupError.uploadRejected(name: name)
        }
    }

    private static func rmdocFiles(under folder: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )
        var files: [URL] = []
        while let item = enumerator?.nextObject() as? URL {
            if item.pathExtension.lowercased() == "rmdoc" {
                files.append(item)
            }
        }
        return files.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
    }

    private static func safeName(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    /// Picks how to reach the tablet's USB web interface. A stock tablet
    /// answers directly at 10.11.99.1:80 with no pairing. A provisioned
    /// tablet rebinds that interface to loopback, so when the pinned SSH
    /// credentials exist the service opens the same SSH local forward the
    /// Files feature uses and talks to the interface through it.
    private func resolveTransport() async throws -> ResolvedTransport {
        if await Self.directWebInterfaceAnswers() {
            return ResolvedTransport(base: Self.directBase, registry: nil)
        }

        let store = DeviceProfileStore()
        guard case .ready = await store.loadPendingSSHMaterial() else {
            throw TabletBackupError.tabletUnreachable
        }
        let paths = await store.paths()
        let route: SSHRoute
        do {
            route = try SSHRoute(
                kind: .usb,
                host: DeviceProfile.requiredHostKeyAlias,
                identityURL: paths.privateKey,
                knownHostsURL: paths.knownHosts
            )
        } catch {
            throw TabletBackupError.tunnelFailed(
                reason: "The pinned SSH credentials couldn’t be used."
            )
        }

        let registry = OwnedProcessRegistry()
        let tunnel = FilesSSHTunnel(
            route: route,
            generation: GenerationID.make(),
            processRegistry: registry
        )
        do {
            let endpoint = try await tunnel.endpoint()
            return ResolvedTransport(base: endpoint.baseURL, registry: registry)
        } catch {
            try? await registry.shutdown()
            throw TabletBackupError.tunnelFailed(
                reason: Self.tunnelFailureReason(error)
            )
        }
    }

    private static func tunnelFailureReason(_ error: any Error) -> String {
        switch error as? FilesSSHTunnelError {
        case .portAllocationFailed:
            "No local port could be reserved for the tunnel."
        case .listenerUnavailable:
            "The tunnel never started listening on this Mac."
        case .ownedForwardExited:
            "The SSH connection closed before the tunnel was ready."
        case nil:
            "The tunnel could not be opened."
        }
    }

    private static func directWebInterfaceAnswers() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: directPortIsOpen())
            }
        }
    }

    /// Non-blocking TCP connect to 10.11.99.1:80 with a short deadline.
    /// Open means the stock web interface is answering there; closed or
    /// timed out means it isn't (unplugged, toggled off, or loopback-bound
    /// on a provisioned tablet).
    private static func directPortIsOpen() -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return false
        }

        var address = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: UInt16(80).bigEndian,
            sin_addr: in_addr(s_addr: inet_addr(directHost)),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        if connectResult == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        let deadline = DispatchTime.now().uptimeNanoseconds +
            UInt64(directProbeTimeoutMilliseconds) * 1_000_000
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return false }
            let remaining = Int32(
                min((deadline - now + 999_999) / 1_000_000, UInt64(Int32.max))
            )
            var descriptors = [
                pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0),
            ]
            let pollResult = descriptors.withUnsafeMutableBufferPointer { buffer in
                Darwin.poll(buffer.baseAddress, nfds_t(buffer.count), remaining)
            }
            if pollResult == 0 { return false }
            if pollResult < 0 {
                if errno == EINTR { continue }
                return false
            }
            guard descriptors[0].revents & Int16(POLLNVAL | POLLERR | POLLHUP) == 0 else {
                return false
            }
            break
        }

        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0,
              socketError == 0 else {
            return false
        }
        return true
    }
}
