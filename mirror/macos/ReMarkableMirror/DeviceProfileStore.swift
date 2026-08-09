import Darwin
import Foundation

enum DeviceProfileLoadResult: Equatable, Sendable {
    case missing
    case ready(DeviceProfile)
    case invalid(DeviceProfileLoadFailure)
}

enum DeviceProfileLoadFailure: Equatable, Sendable {
    case unsupportedVersion
    case corrupt
    case pinnedIdentityMismatch
    case insecureStorage
    case accessDenied
    case unavailable
}

enum DeviceProfileStoreError: Error, Equatable, Sendable {
    case invalidProfile
    case profileChanged
    case staleVerification
    case insecureStorage
    case accessDenied
    case existingCredentialConflict
    case unavailable
}

struct DeviceProfilePaths: Equatable, Sendable {
    let root: URL
    let profile: URL
    let sshDirectory: URL
    let privateKey: URL
    let publicKey: URL
    let knownHosts: URL
}

struct PendingSSHMaterial: Equatable, Sendable {
    let publicKey: Data
    let hostIdentity: KnownHostIdentity
}

enum PendingSSHMaterialLoadResult: Equatable, Sendable {
    case missing
    case ready(PendingSSHMaterial)
    case invalid
}

actor DeviceProfileStore {
    static let profileFileName = "device-profile.json"
    static let privateKeyFileName = "identity_ed25519"
    static let publicKeyFileName = "identity_ed25519.pub"
    static let knownHostsFileName = "known_hosts"
    static let maximumProfileBytes = 16_384

    private static let productDirectoryName = "com.ifixrobots.ReMarkableMirror"
    private static let retiredDirectoryPrefix = ".\(productDirectoryName).reset-"
    private let rootURL: URL

    init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? URL.applicationSupportDirectory
            .appending(path: Self.productDirectoryName, directoryHint: .isDirectory)
    }

    func paths() -> DeviceProfilePaths {
        let sshDirectory = rootURL.appending(path: "ssh", directoryHint: .isDirectory)
        return DeviceProfilePaths(
            root: rootURL,
            profile: rootURL.appending(path: Self.profileFileName),
            sshDirectory: sshDirectory,
            privateKey: sshDirectory.appending(path: Self.privateKeyFileName),
            publicKey: sshDirectory.appending(path: Self.publicKeyFileName),
            knownHosts: sshDirectory.appending(path: Self.knownHostsFileName)
        )
    }

    func prepareDirectories() throws {
        let paths = paths()
        try Self.ensureSecureDirectory(paths.root)
        try Self.ensureSecureDirectory(paths.sshDirectory)
    }

    func load() -> DeviceProfileLoadResult {
        let paths = paths()
        do {
            guard Self.pathExists(paths.root) else { return .missing }
            try Self.validateSecureDirectory(paths.root)
            guard Self.pathExists(paths.profile) else { return .missing }

            let profileData = try Self.secureRead(
                paths.profile,
                maximumBytes: Self.maximumProfileBytes,
                exactMode: 0o600
            )
            try Self.validateJSONShape(profileData)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let profile: DeviceProfile
            do {
                profile = try decoder.decode(DeviceProfile.self, from: profileData).validated()
            } catch DeviceProfileValidationError.unsupportedSchema {
                return .invalid(.unsupportedVersion)
            } catch {
                return .invalid(.corrupt)
            }

            try Self.validateSecureDirectory(paths.sshDirectory)
            _ = try Self.secureRead(paths.privateKey, maximumBytes: 32_768, exactMode: 0o600)
            _ = try Self.secureRead(paths.publicKey, maximumBytes: 16_384, exactMode: 0o600)
            let knownHostsData = try Self.secureRead(
                paths.knownHosts,
                maximumBytes: 65_536,
                exactMode: 0o600
            )
            let identity = try KnownHostIdentity(
                knownHostsData: knownHostsData,
                expectedAlias: profile.sshHostKeyAlias
            )
            guard identity.fingerprint == profile.sshFingerprint else {
                return .invalid(.pinnedIdentityMismatch)
            }
            return .ready(profile)
        } catch let error as DeviceProfileStoreError {
            switch error {
            case .insecureStorage, .existingCredentialConflict:
                return .invalid(.insecureStorage)
            case .accessDenied:
                return .invalid(.accessDenied)
            case .invalidProfile, .profileChanged, .staleVerification:
                return .invalid(.corrupt)
            case .unavailable:
                return .invalid(.unavailable)
            }
        } catch is KnownHostIdentityError {
            return .invalid(.pinnedIdentityMismatch)
        } catch {
            return .invalid(.unavailable)
        }
    }

    func save(_ profile: DeviceProfile) throws {
        do {
            _ = try profile.validated()
        } catch {
            throw DeviceProfileStoreError.invalidProfile
        }
        try prepareDirectories()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(profile)
        } catch {
            throw DeviceProfileStoreError.invalidProfile
        }
        guard !data.isEmpty, data.count <= Self.maximumProfileBytes else {
            throw DeviceProfileStoreError.invalidProfile
        }

        try Self.secureWrite(
            data,
            to: paths().profile,
            allowReplacement: true,
            mode: 0o600
        )
    }

    func markTabletAuthorized(
        expectedPending: DeviceProfile,
        authenticatedUSBCapability: VerifiedTabletCapability
    ) throws -> DeviceProfile {
        try requireCurrentProfile(expectedPending)

        let pendingWiFiVerification: DeviceProfile
        do {
            pendingWiFiVerification = try DeviceProfile.pendingWiFiVerification(
                from: expectedPending,
                authenticatedUSBCapability: authenticatedUSBCapability
            )
        } catch {
            throw DeviceProfileStoreError.invalidProfile
        }

        try save(pendingWiFiVerification)
        return pendingWiFiVerification
    }

    func promoteToReady(
        expectedPendingWiFiVerification: DeviceProfile,
        wifi: VerifiedWiFiRoute,
        capability: VerifiedTabletCapability
    ) throws -> DeviceProfile {
        try requireCurrentProfile(expectedPendingWiFiVerification)

        let promoted: DeviceProfile
        do {
            promoted = try DeviceProfile.ready(
                from: expectedPendingWiFiVerification,
                wifi: wifi,
                capability: capability
            )
        } catch DeviceProfileValidationError.staleVerification {
            throw DeviceProfileStoreError.staleVerification
        } catch {
            throw DeviceProfileStoreError.invalidProfile
        }

        try save(promoted)
        return promoted
    }

    func refreshPendingWiFiVerification(
        expected: DeviceProfile,
        capability: VerifiedTabletCapability
    ) throws -> DeviceProfile {
        try requireCurrentProfile(expected)

        let refreshed: DeviceProfile
        do {
            refreshed = try expected.refreshingPendingWiFiVerification(
                with: capability
            )
        } catch DeviceProfileValidationError.staleVerification {
            throw DeviceProfileStoreError.staleVerification
        } catch {
            throw DeviceProfileStoreError.invalidProfile
        }
        guard refreshed != expected else { return expected }

        try save(refreshed)
        return refreshed
    }

    func refreshLastVerified(
        expectedReady: DeviceProfile,
        capability: VerifiedTabletCapability
    ) throws -> DeviceProfile {
        try requireCurrentProfile(expectedReady)

        let refreshed: DeviceProfile
        do {
            refreshed = try expectedReady.refreshingLastVerified(with: capability)
        } catch DeviceProfileValidationError.staleVerification {
            throw DeviceProfileStoreError.staleVerification
        } catch {
            throw DeviceProfileStoreError.invalidProfile
        }

        try save(refreshed)
        return refreshed
    }

    func publishSSHMaterial(
        privateKey: Data,
        publicKey: Data,
        hostIdentity: KnownHostIdentity
    ) throws {
        guard !privateKey.isEmpty, privateKey.count <= 32_768,
              !publicKey.isEmpty, publicKey.count <= 16_384 else {
            throw DeviceProfileStoreError.invalidProfile
        }
        try prepareDirectories()
        let paths = paths()
        let destinations = [paths.privateKey, paths.publicKey, paths.knownHosts]
        let existing = destinations.map(Self.pathExists)

        if existing.allSatisfy({ $0 }) {
            let currentPrivate = try Self.secureRead(paths.privateKey, maximumBytes: 32_768, exactMode: 0o600)
            let currentPublic = try Self.secureRead(paths.publicKey, maximumBytes: 16_384, exactMode: 0o600)
            let currentHost = try Self.secureRead(paths.knownHosts, maximumBytes: 65_536, exactMode: 0o600)
            guard currentPrivate == privateKey,
                  currentPublic == publicKey,
                  currentHost == hostIdentity.knownHostsData else {
                throw DeviceProfileStoreError.existingCredentialConflict
            }
            return
        }
        guard existing.allSatisfy({ !$0 }) else {
            throw DeviceProfileStoreError.existingCredentialConflict
        }

        var published: [URL] = []
        do {
            for (url, data) in [
                (paths.privateKey, privateKey),
                (paths.publicKey, publicKey),
                (paths.knownHosts, hostIdentity.knownHostsData),
            ] {
                try Self.secureWrite(data, to: url, allowReplacement: false, mode: 0o600)
                published.append(url)
            }
        } catch {
            for url in published {
                _ = unlink(url.path)
            }
            throw error
        }
    }

    func loadPendingSSHMaterial() -> PendingSSHMaterialLoadResult {
        let paths = paths()
        let destinations = [paths.privateKey, paths.publicKey, paths.knownHosts]
        let existing = destinations.map(Self.pathExists)
        if existing.allSatisfy({ !$0 }) { return .missing }
        guard existing.allSatisfy({ $0 }) else { return .invalid }

        do {
            _ = try Self.secureRead(paths.privateKey, maximumBytes: 32_768, exactMode: 0o600)
            let publicKey = try Self.secureRead(
                paths.publicKey,
                maximumBytes: 16_384,
                exactMode: 0o600
            )
            let knownHosts = try Self.secureRead(
                paths.knownHosts,
                maximumBytes: 65_536,
                exactMode: 0o600
            )
            let hostIdentity = try KnownHostIdentity(
                knownHostsData: knownHosts,
                expectedAlias: DeviceProfile.requiredHostKeyAlias
            )
            return .ready(PendingSSHMaterial(
                publicKey: publicKey,
                hostIdentity: hostIdentity
            ))
        } catch {
            return .invalid
        }
    }

    func resetLocalSetup() throws {
        let parent = rootURL.deletingLastPathComponent()
        try Self.removeRetiredDirectories(in: parent)
        guard Self.pathExists(rootURL) else { return }
        try Self.validateSecureDirectory(rootURL)

        let retired = parent.appending(
            path: "\(Self.retiredDirectoryPrefix)\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        guard !Self.pathExists(retired) else {
            throw DeviceProfileStoreError.existingCredentialConflict
        }
        guard rename(rootURL.path, retired.path) == 0 else {
            throw Self.mapPOSIXError(errno)
        }
        try Self.synchronizeDirectory(parent)
        try Self.removeRetiredDirectories(in: parent)
    }

    private static func removeRetiredDirectories(in parent: URL) throws {
        var parentInformation = stat()
        guard lstat(parent.path, &parentInformation) == 0 else {
            if errno == ENOENT { return }
            throw mapPOSIXError(errno)
        }
        guard parentInformation.st_mode & S_IFMT == S_IFDIR else {
            throw DeviceProfileStoreError.unavailable
        }

        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted()
        } catch {
            throw mapFileManagerError(error)
        }

        let retiredDirectories = names
            .filter(isRetiredDirectoryName)
            .map { parent.appending(path: $0, directoryHint: .isDirectory) }
        for retired in retiredDirectories {
            try validateSecureDirectory(retired)
        }
        for retired in retiredDirectories {
            do {
                try FileManager.default.removeItem(at: retired)
            } catch {
                throw mapFileManagerError(error)
            }
        }
        if !retiredDirectories.isEmpty {
            try synchronizeDirectory(parent)
        }
    }

    private static func isRetiredDirectoryName(_ name: String) -> Bool {
        guard name.hasPrefix(retiredDirectoryPrefix) else { return false }
        let suffix = String(name.dropFirst(retiredDirectoryPrefix.count))
        guard suffix.utf8.count == 36,
              let identifier = UUID(uuidString: suffix) else {
            return false
        }
        return identifier.uuidString == suffix
    }

    private func requireCurrentProfile(_ expected: DeviceProfile) throws {
        switch load() {
        case .ready(let current) where current == expected:
            return
        case .ready, .missing:
            throw DeviceProfileStoreError.profileChanged
        case .invalid(.insecureStorage):
            throw DeviceProfileStoreError.insecureStorage
        case .invalid(.accessDenied):
            throw DeviceProfileStoreError.accessDenied
        case .invalid(.unavailable):
            throw DeviceProfileStoreError.unavailable
        case .invalid(.unsupportedVersion),
             .invalid(.corrupt),
             .invalid(.pinnedIdentityMismatch):
            throw DeviceProfileStoreError.invalidProfile
        }
    }

    private static func validateJSONShape(_ data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw DeviceProfileStoreError.invalidProfile
        }
        guard let root = object as? [String: Any] else {
            throw DeviceProfileStoreError.invalidProfile
        }
        try requireAllowedKeys(
            root,
            allowed: [
                "schema", "profileID", "pairingState", "sshHostKeyAlias",
                "sshFingerprint", "identityFile", "knownHostsFile", "wifi", "lastVerified",
            ]
        )
        if let wifi = root["wifi"] as? [String: Any] {
            try requireAllowedKeys(wifi, allowed: ["host", "contextDigest"])
        } else if root.keys.contains("wifi"), !(root["wifi"] is NSNull) {
            throw DeviceProfileStoreError.invalidProfile
        }
        if let verified = root["lastVerified"] as? [String: Any] {
            try requireAllowedKeys(
                verified,
                allowed: [
                    "verifiedAt", "bootID", "activeRoot", "osVersion", "osBuild",
                    "kernelRelease", "probeVersion", "transportVersion", "transportSchema",
                    "xoviVersion",
                ]
            )
        } else if root.keys.contains("lastVerified"), !(root["lastVerified"] is NSNull) {
            throw DeviceProfileStoreError.invalidProfile
        }
    }

    private static func requireAllowedKeys(
        _ object: [String: Any],
        allowed: Set<String>
    ) throws {
        guard Set(object.keys).isSubset(of: allowed) else {
            throw DeviceProfileStoreError.invalidProfile
        }
    }

    private static func pathExists(_ url: URL) -> Bool {
        var information = stat()
        return lstat(url.path, &information) == 0
    }

    private static func ensureSecureDirectory(_ url: URL) throws {
        if pathExists(url) {
            try validateSecureDirectory(url)
            return
        }

        guard mkdir(url.path, 0o700) == 0 else {
            if errno == EEXIST {
                try validateSecureDirectory(url)
                return
            }
            throw mapPOSIXError(errno)
        }
        try validateSecureDirectory(url)
    }

    private static func validateSecureDirectory(_ url: URL) throws {
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            throw mapPOSIXError(errno)
        }
        guard information.st_uid == geteuid(),
              information.st_nlink == 2 || information.st_nlink > 0,
              information.st_mode & S_IFMT == S_IFDIR,
              information.st_mode & 0o777 == 0o700 else {
            throw DeviceProfileStoreError.insecureStorage
        }
    }

    private static func secureRead(
        _ url: URL,
        maximumBytes: Int,
        exactMode: mode_t
    ) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw DeviceProfileStoreError.insecureStorage }
            throw mapPOSIXError(errno)
        }
        defer { close(descriptor) }

        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw mapPOSIXError(errno)
        }
        guard information.st_uid == geteuid(),
              information.st_nlink == 1,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_mode & 0o777 == exactMode else {
            throw DeviceProfileStoreError.insecureStorage
        }
        guard information.st_size > 0,
              information.st_size <= maximumBytes else {
            throw DeviceProfileStoreError.invalidProfile
        }

        var result = Data()
        result.reserveCapacity(Int(information.st_size))
        var buffer = [UInt8](repeating: 0, count: min(4_096, maximumBytes))
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw mapPOSIXError(errno)
            }
            guard result.count + count <= maximumBytes else {
                throw DeviceProfileStoreError.invalidProfile
            }
            result.append(buffer, count: count)
        }
        guard !result.isEmpty else { throw DeviceProfileStoreError.invalidProfile }
        return result
    }

    private static func secureWrite(
        _ data: Data,
        to destination: URL,
        allowReplacement: Bool,
        mode: mode_t
    ) throws {
        guard !data.isEmpty else { throw DeviceProfileStoreError.invalidProfile }
        if pathExists(destination) {
            guard allowReplacement else {
                throw DeviceProfileStoreError.existingCredentialConflict
            }
            _ = try secureRead(destination, maximumBytes: max(data.count, 65_536), exactMode: mode)
        }

        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode
        )
        guard descriptor >= 0 else { throw mapPOSIXError(errno) }

        var descriptorIsOpen = true
        var shouldRemoveTemporary = true
        defer {
            if descriptorIsOpen {
                close(descriptor)
            }
            if shouldRemoveTemporary {
                _ = unlink(temporary.path)
            }
        }

        guard fchmod(descriptor, mode) == 0 else { throw mapPOSIXError(errno) }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else {
                throw DeviceProfileStoreError.invalidProfile
            }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw mapPOSIXError(errno)
                }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw mapPOSIXError(errno) }

        var information = stat()
        guard fstat(descriptor, &information) == 0 else { throw mapPOSIXError(errno) }
        guard information.st_uid == geteuid(),
              information.st_nlink == 1,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_mode & 0o777 == mode else {
            throw DeviceProfileStoreError.insecureStorage
        }
        guard Darwin.close(descriptor) == 0 else { throw mapPOSIXError(errno) }
        descriptorIsOpen = false

        guard rename(temporary.path, destination.path) == 0 else {
            throw mapPOSIXError(errno)
        }
        shouldRemoveTemporary = false
        try synchronizeDirectory(destination.deletingLastPathComponent())
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY)
        guard descriptor >= 0 else { throw mapPOSIXError(errno) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw mapPOSIXError(errno) }
    }

    private static func mapPOSIXError(_ code: Int32) -> DeviceProfileStoreError {
        switch code {
        case EACCES, EPERM:
            .accessDenied
        case ELOOP:
            .insecureStorage
        default:
            .unavailable
        }
    }

    private static func mapFileManagerError(_ error: Error) -> DeviceProfileStoreError {
        let cocoaError = error as NSError
        if cocoaError.domain == NSCocoaErrorDomain,
           (cocoaError.code == CocoaError.Code.fileReadNoPermission.rawValue ||
            cocoaError.code == CocoaError.Code.fileWriteNoPermission.rawValue) {
            return .accessDenied
        }
        return .unavailable
    }
}
