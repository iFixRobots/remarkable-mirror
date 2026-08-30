import Darwin
import Foundation

enum LocalPairingPreparationResult: Equatable, Sendable {
    case waitingForUSB
    case accessoryApprovalRequired
    case unsafeUSBRoute
    case waitingForSSHBanner
    case awaitingTabletAuthorization(DeviceProfile)
    case awaitingWiFiVerification(DeviceProfile)
    case alreadyReady(DeviceProfile)
    case failed(LocalPairingFailure)
}

enum LocalPairingFailure: Equatable, Sendable {
    case profileStorage
    case openSSHUnavailable
    case identityGeneration
    case hostIdentity
}

actor LocalPairingPreparer {
    private static let sshKeygenURL = URL(filePath: "/usr/bin/ssh-keygen")
    private static let sshURL = URL(filePath: "/usr/bin/ssh")

    private let profileStore: DeviceProfileStore
    private let processRegistry: OwnedProcessRegistry
    private let bannerProbe: any SSHBannerProbing
    private let directUSBRouteVerifier: DirectUSBRouteVerifier

    init(
        profileStore: DeviceProfileStore,
        processRegistry: OwnedProcessRegistry,
        bannerProbe: any SSHBannerProbing,
        directUSBRouteVerifier: DirectUSBRouteVerifier
    ) {
        self.profileStore = profileStore
        self.processRegistry = processRegistry
        self.bannerProbe = bannerProbe
        self.directUSBRouteVerifier = directUSBRouteVerifier
    }

    func prepare() async -> LocalPairingPreparationResult {
        switch await profileStore.load() {
        case let .ready(profile):
            return Self.preparationResult(forStoredProfile: profile)
        case .invalid:
            return .failed(.profileStorage)
        case .missing:
            break
        }

        let usbContext: DirectUSBRouteContext
        switch await directUSBRouteVerifier.verify() {
        case let .verified(context):
            usbContext = context
        case .unavailable:
            return .waitingForUSB
        case .accessoryApprovalRequired:
            return .accessoryApprovalRequired
        case .unsafeRoute:
            return .unsafeUSBRoute
        }

        guard let bannerTarget = Self.directUSBBannerTarget(for: usbContext) else {
            return .unsafeUSBRoute
        }
        let bannerResult: SSHBannerProbeResult
        do {
            bannerResult = try await bannerProbe.probe(target: bannerTarget)
        } catch {
            return .waitingForUSB
        }
        if let waitingResult = Self.waitingResult(afterVerifiedUSB: bannerResult) {
            return waitingResult
        }

        switch await directUSBRouteVerifier.verify() {
        case let .verified(currentContext) where currentContext == usbContext:
            break
        case .unavailable:
            return .waitingForUSB
        case .accessoryApprovalRequired:
            return .accessoryApprovalRequired
        case .unsafeRoute, .verified:
            return .unsafeUSBRoute
        }

        do {
            try await profileStore.prepareDirectories()
        } catch {
            return .failed(.profileStorage)
        }

        switch await profileStore.loadPendingSSHMaterial() {
        case let .ready(material):
            return await publishRecoveredProfile(hostIdentity: material.hostIdentity)
        case .invalid:
            return .failed(.profileStorage)
        case .missing:
            break
        }

        guard let hostIdentity = await scanHostIdentity(usbContext: usbContext) else {
            return .failed(.hostIdentity)
        }
        guard let identity = await generateIdentity() else {
            return .failed(.identityGeneration)
        }

        do {
            try await profileStore.publishSSHMaterial(
                privateKey: identity.privateKey,
                publicKey: identity.publicKey,
                hostIdentity: hostIdentity
            )
            let profile = DeviceProfile.pendingTabletAuthorization(
                id: UUID(),
                hostIdentity: hostIdentity
            )
            try await profileStore.save(profile)
            return .awaitingTabletAuthorization(profile)
        } catch {
            return .failed(.profileStorage)
        }
    }

    static func preparationResult(
        forStoredProfile profile: DeviceProfile
    ) -> LocalPairingPreparationResult {
        switch profile.pairingState {
        case .pendingTabletAuthorization:
            return .awaitingTabletAuthorization(profile)
        case .pendingWiFiVerification:
            return .awaitingWiFiVerification(profile)
        case .ready:
            return .alreadyReady(profile)
        }
    }

    static func waitingResult(
        afterVerifiedUSB bannerResult: SSHBannerProbeResult
    ) -> LocalPairingPreparationResult? {
        switch bannerResult {
        case .ssh:
            return nil
        case .noRoute, .portOpenNoBanner:
            return .waitingForSSHBanner
        }
    }

    private func publishRecoveredProfile(
        hostIdentity: KnownHostIdentity
    ) async -> LocalPairingPreparationResult {
        let profile = DeviceProfile.pendingTabletAuthorization(
            id: UUID(),
            hostIdentity: hostIdentity
        )
        do {
            try await profileStore.save(profile)
            return .awaitingTabletAuthorization(profile)
        } catch {
            return .failed(.profileStorage)
        }
    }

    private func scanHostIdentity(
        usbContext: DirectUSBRouteContext
    ) async -> KnownHostIdentity? {
        let interfaceName = usbContext.interfaceName
        guard SafeConnectionValue.isHost(interfaceName) else { return nil }
        let paths = await profileStore.paths()
        let stagingDirectory = paths.sshDirectory.appending(
            path: ".host-scan-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        do {
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        let knownHostsURL = stagingDirectory.appending(path: "known_hosts")
        guard Self.createSecureEmptyFile(knownHostsURL) else { return nil }
        guard let request = Self.hostIdentityAcquisitionRequest(
            interfaceName: interfaceName,
            knownHostsURL: knownHostsURL,
            generation: .make()
        ) else {
            return nil
        }
        do {
            let result = try await processRegistry.run(request, timeout: .seconds(5))
            let currentVerification = await directUSBRouteVerifier.verify()
            guard case .exited = result.outcome,
                  Self.matchesExpectedUSBContext(
                      currentVerification,
                      expected: usbContext
                  ) else {
                return nil
            }
            let knownHostsData = try Self.readGeneratedFile(
                knownHostsURL,
                maximumBytes: 65_536,
                requiredMode: 0o600
            )
            return try KnownHostIdentity(
                knownHostsData: knownHostsData,
                expectedAlias: DeviceProfile.requiredHostKeyAlias
            )
        } catch {
            return nil
        }
    }

    static func matchesExpectedUSBContext(
        _ verification: DirectUSBRouteVerification,
        expected: DirectUSBRouteContext
    ) -> Bool {
        guard case let .verified(currentContext) = verification else { return false }
        return currentContext == expected
    }

    static func directUSBBannerTarget(
        for context: DirectUSBRouteContext
    ) -> SSHBannerProbeTarget? {
        SSHBannerProbeTarget(
            host: DeviceProfile.requiredHostKeyAlias,
            boundInterface: context.interfaceName
        )
    }

    static func hostIdentityAcquisitionRequest(
        interfaceName: String,
        knownHostsURL: URL,
        generation: GenerationID
    ) -> ProcessRequest? {
        guard SafeConnectionValue.isHost(interfaceName),
              knownHostsURL.isFileURL,
              knownHostsURL.path.first == "/",
              !knownHostsURL.path.contains("\0"),
              !knownHostsURL.path.contains("\n"),
              !knownHostsURL.path.contains("\r") else {
            return nil
        }
        return ProcessRequest(
            executableURL: Self.sshURL,
            arguments: [
                "-F", "/dev/null",
                "-o", "BatchMode=yes",
                "-o", "IdentitiesOnly=yes",
                "-o", "IdentityAgent=none",
                "-o", "PubkeyAuthentication=no",
                "-o", "HostbasedAuthentication=no",
                "-o", "GSSAPIAuthentication=no",
                "-o", "PasswordAuthentication=no",
                "-o", "KbdInteractiveAuthentication=no",
                "-o", "PreferredAuthentications=none",
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "HostKeyAlgorithms=ssh-ed25519",
                "-o", "HashKnownHosts=no",
                "-o", "UserKnownHostsFile=\(OpenSSHConfigValue.quotedPath(knownHostsURL.path))",
                "-o", "GlobalKnownHostsFile=/dev/null",
                "-o", "HostKeyAlias=\(DeviceProfile.requiredHostKeyAlias)",
                "-o", "CheckHostIP=no",
                "-o", "UpdateHostKeys=no",
                "-o", "VerifyHostKeyDNS=no",
                "-o", "BindInterface=\(interfaceName)",
                "-o", "ConnectTimeout=3",
                "-o", "ConnectionAttempts=1",
                "-o", "NumberOfPasswordPrompts=0",
                "-o", "LogLevel=ERROR",
                "-T",
                "root@\(DeviceProfile.requiredHostKeyAlias)",
            ],
            generation: generation,
            role: .pairingHostScan,
            outputLimit: 8_192
        )
    }

    private static func createSecureEmptyFile(_ url: URL) -> Bool {
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return fchmod(descriptor, 0o600) == 0 && fsync(descriptor) == 0
    }

    private func generateIdentity() async -> GeneratedIdentity? {
        let paths = await profileStore.paths()
        let stagingDirectory = paths.sshDirectory.appending(
            path: ".pairing-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        do {
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        let privateKeyURL = stagingDirectory.appending(path: "identity_ed25519")
        let publicKeyURL = stagingDirectory.appending(path: "identity_ed25519.pub")
        let request = ProcessRequest(
            executableURL: Self.sshKeygenURL,
            arguments: [
                "-q",
                "-t", "ed25519",
                "-N", "",
                "-C", "reMarkable Mirror for Mac",
                "-f", privateKeyURL.path,
            ],
            generation: .make(),
            role: .pairingKeyGeneration,
            outputLimit: 8_192
        )

        do {
            let result = try await processRegistry.run(request, timeout: .seconds(5))
            guard result.outcome == .exited(status: 0) else { return nil }
            let privateKey = try Self.readGeneratedFile(
                privateKeyURL,
                maximumBytes: 32_768,
                requiredMode: 0o600
            )
            let publicKey = try Self.readGeneratedFile(
                publicKeyURL,
                maximumBytes: 16_384,
                requiredMode: nil
            )
            guard privateKey.starts(with: Data("-----BEGIN OPENSSH PRIVATE KEY-----".utf8)),
                  publicKey.starts(with: Data("ssh-ed25519 ".utf8)) else {
                return nil
            }
            return GeneratedIdentity(privateKey: privateKey, publicKey: publicKey)
        } catch {
            return nil
        }
    }

    private static func readGeneratedFile(
        _ url: URL,
        maximumBytes: Int,
        requiredMode: mode_t?
    ) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(descriptor) }

        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_uid == geteuid(),
              information.st_nlink == 1,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_size > 0,
              information.st_size <= maximumBytes else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if let requiredMode {
            guard information.st_mode & 0o777 == requiredMode else {
                throw CocoaError(.fileReadNoPermission)
            }
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw CocoaError(.fileReadUnknown)
            }
            guard data.count + count <= maximumBytes else {
                throw CocoaError(.fileReadTooLarge)
            }
            data.append(buffer, count: count)
        }
        return data
    }
}

private struct GeneratedIdentity: Sendable {
    let privateKey: Data
    let publicKey: Data
}
