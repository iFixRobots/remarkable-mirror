import CryptoKit
import Foundation

enum TabletPrerequisiteAssetName: String, CaseIterable, Equatable, Hashable, Sendable {
    case transportWakeBinary = "rmmirror-transport-wake"
    case transportWakeService = "rmmirror-transport-wake.service"
    case transportWakeInstaller = "install-transport-wake.sh"
    case sleepGuard = "rmmirror-usb-sleep-guard.conf"
    case probe = "rmmirror-probe"
    case xoviArchive = "xovi-aarch64.tar.gz"
    case filesLoopback = "rmmirror-files-loopback.so"
    case prerequisiteInstaller = "install-mirror-prerequisites.sh"
    case contract = "rmmirror-prerequisites.env"

    fileprivate var sizeRange: ClosedRange<Int> {
        switch self {
        case .transportWakeBinary, .probe, .filesLoopback:
            1_024...32_000_000
        case .xoviArchive:
            1_000_000...256_000_000
        case .transportWakeService, .transportWakeInstaller, .sleepGuard,
             .prerequisiteInstaller, .contract:
            1...1_000_000
        }
    }
}

struct TabletPrerequisiteAsset: Equatable, Sendable {
    let name: TabletPrerequisiteAssetName
    let url: URL
    let sha256: String
}

protocol TabletPrerequisiteAssetProviding: Sendable {
    func loadAssets() throws -> [TabletPrerequisiteAssetName: TabletPrerequisiteAsset]
}

enum TabletPrerequisiteInstallPhase: String, Equatable, Sendable {
    case starting
    case acquiringLock = "acquiring_lock"
    case validatingContract = "validating_contract"
    case validatingStage = "validating_stage"
    case validatingTablet = "validating_tablet"
    case installingXovi = "installing_xovi"
    case publishingExtensions = "publishing_extensions"
    case installingProbe = "installing_probe"
    case retiringFrameStreams = "retiring_frame_streams"
    case installingTransport = "installing_transport"
    case validatingInstall = "validating_install"
    case validatingTransportStatus = "validating_transport_status"
    case validatingListeners = "validating_listeners"
    case complete

    var userFacingDescription: String {
        switch self {
        case .starting, .acquiringLock:
            "starting tablet setup"
        case .validatingContract, .validatingStage:
            "checking the setup package"
        case .validatingTablet:
            "checking tablet compatibility"
        case .installingXovi:
            "installing Xovi"
        case .publishingExtensions:
            "installing display and Files components"
        case .installingProbe:
            "installing the Mirror companion"
        case .retiringFrameStreams:
            "closing an older mirror session"
        case .installingTransport:
            "installing USB keep-awake"
        case .validatingInstall, .validatingTransportStatus, .validatingListeners:
            "verifying tablet setup"
        case .complete:
            "finishing tablet setup"
        }
    }

}

enum TabletPrerequisiteInstallationFailure: Error, Equatable, Sendable {
    case busy
    case assetsUnavailable
    case unsafeAsset(TabletPrerequisiteAssetName)
    case unsafeCredentialPath
    case unsafeUSBRoute
    case usbUnavailable
    case usbContextChanged
    case processUnavailable
    case stageCreationFailed
    case uploadFailed(TabletPrerequisiteAssetName)
    case installFailed
    case unsupportedTabletSoftware
    case incompatibleXovi
    case incompatibleInstallTarget
    case transactionFailed(TabletPrerequisiteInstallPhase)
    case invalidInstallResponse
    case cleanupFailed
    case postInstallVerificationFailed(PassiveRouteProbeDetail)

    var userFacingDescription: String {
        switch self {
        case .busy:
            "waiting for another tablet setup attempt"
        case .assetsUnavailable, .unsafeAsset:
            "checking the setup package"
        case .unsafeCredentialPath, .unsafeUSBRoute, .usbUnavailable,
             .usbContextChanged:
            "checking the direct USB-C connection"
        case .processUnavailable:
            "starting the tablet setup process"
        case .stageCreationFailed:
            "creating a private setup area"
        case .uploadFailed:
            "copying the setup package"
        case .installFailed:
            "running tablet setup"
        case .unsupportedTabletSoftware:
            "checking tablet software compatibility"
        case .incompatibleXovi:
            "checking the existing Xovi installation"
        case .incompatibleInstallTarget:
            "checking existing Mirror tablet files"
        case let .transactionFailed(phase):
            phase.userFacingDescription
        case .invalidInstallResponse:
            "confirming the setup result"
        case .cleanupFailed:
            "cleaning temporary setup files"
        case .postInstallVerificationFailed:
            "verifying tablet setup"
        }
    }

    var needsApplicationAttention: Bool {
        switch self {
        case .assetsUnavailable, .unsafeAsset, .processUnavailable:
            true
        default:
            false
        }
    }

    var needsProfileAttention: Bool {
        if case .unsafeCredentialPath = self { return true }
        return false
    }

    var needsXoviAttention: Bool {
        if case .incompatibleXovi = self { return true }
        return false
    }

    var needsInstallTargetAttention: Bool {
        if case .incompatibleInstallTarget = self { return true }
        return false
    }

    var needsUnsupportedSoftwareAttention: Bool {
        if case .unsupportedTabletSoftware = self { return true }
        return false
    }
}

protocol TabletPrerequisiteInstalling: Actor {
    func installOrRepair(
        identityURL: URL,
        knownHostsURL: URL,
        expectedUSBContext: DirectUSBRouteContext,
        generation: GenerationID
    ) async throws -> PassiveRouteCapability
}

/// Loads the complete tablet prerequisite payload from the app bundle. The
/// directory is exact by design: extra, missing, linked, malformed, oversized,
/// or wrong-architecture assets fail before any tablet process is launched.
struct BundledTabletPrerequisiteAssetProvider: TabletPrerequisiteAssetProviding {
    private static let resourceDirectoryName = "TabletPrerequisites"

    private let directoryURL: URL?

    init(bundle: Bundle = .main) {
        directoryURL = bundle.resourceURL?.appending(
            path: Self.resourceDirectoryName,
            directoryHint: .isDirectory
        )
    }

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    func loadAssets() throws -> [TabletPrerequisiteAssetName: TabletPrerequisiteAsset] {
        guard let directoryURL,
              SafeConnectionValue.isAbsoluteFileURL(directoryURL),
              let directoryValues = try? directoryURL.resourceValues(forKeys: [
                  .isDirectoryKey,
                  .isSymbolicLinkKey,
              ]),
              directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true,
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: directoryURL,
                  includingPropertiesForKeys: [
                      .isRegularFileKey,
                      .isSymbolicLinkKey,
                      .fileSizeKey,
                  ],
                  options: []
              ) else {
            throw TabletPrerequisiteInstallationFailure.assetsUnavailable
        }

        let expectedNames = Set(TabletPrerequisiteAssetName.allCases.map(\.rawValue))
        guard Set(contents.map(\.lastPathComponent)) == expectedNames,
              contents.count == expectedNames.count else {
            throw TabletPrerequisiteInstallationFailure.assetsUnavailable
        }

        var assets: [TabletPrerequisiteAssetName: TabletPrerequisiteAsset] = [:]
        for name in TabletPrerequisiteAssetName.allCases {
            let url = directoryURL.appending(path: name.rawValue)
            guard SafeConnectionValue.isAbsoluteFileURL(url),
                  let values = try? url.resourceValues(forKeys: [
                      .isRegularFileKey,
                      .isSymbolicLinkKey,
                      .fileSizeKey,
                  ]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let size = values.fileSize,
                  name.sizeRange.contains(size),
                  let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                  data.count == size else {
                throw TabletPrerequisiteInstallationFailure.unsafeAsset(name)
            }
            let digest = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            guard Self.validate(data: data, for: name) else {
                throw TabletPrerequisiteInstallationFailure.unsafeAsset(name)
            }
            assets[name] = TabletPrerequisiteAsset(
                name: name,
                url: url,
                sha256: digest
            )
        }
        guard let contractAsset = assets[.contract],
              let contractData = try? Data(
                  contentsOf: contractAsset.url,
                  options: [.mappedIfSafe]
              ),
              let expectedXoviHash = Self.contractValue(
                  "RMMIRROR_XOVI_ARCHIVE_SHA256",
                  in: contractData
              ),
              SafeConnectionValue.isLowercaseSHA256(expectedXoviHash),
              assets[.xoviArchive]?.sha256 == expectedXoviHash else {
            throw TabletPrerequisiteInstallationFailure.unsafeAsset(.xoviArchive)
        }
        return assets
    }

    private static func validate(
        data: Data,
        for name: TabletPrerequisiteAssetName
    ) -> Bool {
        switch name {
        case .transportWakeBinary, .probe:
            return isAArch64ELF(data, type: 2)
        case .filesLoopback:
            return isAArch64ELF(data, type: 3)
        case .xoviArchive:
            return data.count >= 2 && data[0] == 0x1f && data[1] == 0x8b
        case .transportWakeService:
            return text(data, contains: [
                "Type=simple",
                "ExecStart=/usr/libexec/rmmirror-transport-wake",
                "--wake-listen 127.0.0.1:51337",
                "--wake-listen 10.11.99.1:51337",
            ])
        case .transportWakeInstaller:
            return text(data, contains: [
                "#!/bin/sh",
                "set -eu",
                "expected_transport_version=0.6.0",
                "RMMIRROR_TRANSPORT_WAKE=installed",
                "rollback_install_transaction",
            ])
        case .sleepGuard:
            return text(data, contains: [
                "[Service]",
                "ExecCondition=/usr/libexec/rmmirror-transport-wake hold-system-sleep",
                "--udc-state-glob /sys/class/udc/*/state",
            ])
        case .prerequisiteInstaller:
            return text(data, contains: [
                "#!/bin/sh",
                "set -eu",
                "lock_directory=/run/rmmirror-prerequisites-install.lock",
                "require_hash rmmirror-prerequisites.env",
                "publish_extension framebuffer-spy.so",
                "publish_extension xovi-message-broker.so",
                "publish_extension rmmirror-files-loopback.so",
                "RMMIRROR_PREREQUISITES_INSTALL_FAILED=$failure_phase",
                "RMMIRROR_PREREQUISITES=installed",
            ])
        case .contract:
            return text(data, contains: [
                "RMMIRROR_PREREQUISITES_SCHEMA=rmmirror.prerequisites/v2",
                "RMMIRROR_TABLET_MODEL=chiappa",
                "RMMIRROR_TABLET_INSTALL_TARGETS=",
                "RMMIRROR_XOVI_RELEASE=",
                "RMMIRROR_XOVI_ARCHIVE_SHA256=",
                "RMMIRROR_PROBE_VERSION=0.4.9",
                "RMMIRROR_TRANSPORT_VERSION=0.6.0",
                "RMMIRROR_REQUIRED_EXTENSIONS=framebuffer-spy.so,xovi-message-broker.so,rmmirror-files-loopback.so",
            ])
        }
    }

    private static func text(_ data: Data, contains markers: [String]) -> Bool {
        guard !data.contains(0),
              let value = String(data: data, encoding: .utf8) else {
            return false
        }
        return markers.allSatisfy(value.contains)
    }

    private static func contractValue(_ key: String, in data: Data) -> String? {
        guard let value = String(data: data, encoding: .utf8) else { return nil }
        let prefix = "\(key)="
        let matches = value
            .split(whereSeparator: \Character.isNewline)
            .filter { $0.hasPrefix(prefix) }
        guard matches.count == 1 else { return nil }
        let result = String(matches[0].dropFirst(prefix.count))
        return result.isEmpty ? nil : result
    }

    private static func isAArch64ELF(_ data: Data, type: UInt16) -> Bool {
        guard data.count >= 64,
              data[0] == 0x7f,
              data[1] == 0x45,
              data[2] == 0x4c,
              data[3] == 0x46,
              data[4] == 2,
              data[5] == 1,
              uint16(data, at: 16) == type,
              uint16(data, at: 18) == 183,
              let programHeaderOffset = uint64(data, at: 32),
              let programHeaderSize = uint16(data, at: 54),
              let programHeaderCount = uint16(data, at: 56),
              programHeaderCount > 0,
              programHeaderCount <= 256,
              programHeaderSize >= 56,
              programHeaderOffset <= UInt64(Int.max) else {
            return false
        }
        let firstProgramHeader = Int(programHeaderOffset)
        let tableSize = Int(programHeaderSize) * Int(programHeaderCount)
        guard firstProgramHeader <= data.count,
              tableSize <= data.count - firstProgramHeader else {
            return false
        }
        for index in 0..<Int(programHeaderCount) {
            let offset = firstProgramHeader + index * Int(programHeaderSize)
            guard offset >= 0,
                  offset <= data.count - Int(programHeaderSize),
                  let headerType = uint32(data, at: offset),
                  headerType != 3 else {
                return false
            }
        }
        return true
    }

    private static func uint16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset <= data.count - 2 else { return nil }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        return UInt32(data[offset]) |
            UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 |
            UInt32(data[offset + 3]) << 24
    }

    private static func uint64(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset <= data.count - 8 else { return nil }
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(data[offset + index]) << UInt64(index * 8)
        }
        return value
    }

}

/// Installs or repairs the complete pinned tablet prerequisite set over the
/// exact direct USB-C attachment owned by Add This Mac or Repair Tablet Setup.
/// It never constructs a Wi-Fi route and never receives a tablet password.
actor TabletPrerequisiteInstaller: TabletPrerequisiteInstalling {
    static let completionMarker = "RMMIRROR_PREREQUISITES=installed\n"

    private static let sshExecutableURL = URL(filePath: "/usr/bin/ssh")
    private static let scpExecutableURL = URL(filePath: "/usr/bin/scp")
    private static let transferTimeout: Duration = .seconds(120)
    private static let commandTimeout: Duration = .seconds(180)
    private static let probeTimeout: Duration = .seconds(7)
    private static let outputLimit = 32_768

    private let assetProvider: any TabletPrerequisiteAssetProviding
    private let routeVerifier: any TabletKeyAuthorizationRouteVerifying
    private let processRunner: any ProcessRunning
    private let stageToken: @Sendable () -> String

    private var isInstalling = false

    init(
        assetProvider: any TabletPrerequisiteAssetProviding =
            BundledTabletPrerequisiteAssetProvider(),
        routeVerifier: any TabletKeyAuthorizationRouteVerifying,
        processRunner: any ProcessRunning,
        stageToken: @escaping @Sendable () -> String = {
            UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
    ) {
        self.assetProvider = assetProvider
        self.routeVerifier = routeVerifier
        self.processRunner = processRunner
        self.stageToken = stageToken
    }

    func installOrRepair(
        identityURL: URL,
        knownHostsURL: URL,
        expectedUSBContext: DirectUSBRouteContext,
        generation: GenerationID
    ) async throws -> PassiveRouteCapability {
        guard !isInstalling else {
            throw TabletPrerequisiteInstallationFailure.busy
        }
        isInstalling = true
        defer { isInstalling = false }

        let assets: [TabletPrerequisiteAssetName: TabletPrerequisiteAsset]
        do {
            assets = try assetProvider.loadAssets()
        } catch let failure as TabletPrerequisiteInstallationFailure {
            throw failure
        } catch {
            throw TabletPrerequisiteInstallationFailure.assetsUnavailable
        }
        try Self.validateAssetMetadata(assets)

        let route: SSHRoute
        do {
            route = try SSHRoute(
                kind: .usb,
                host: DeviceProfile.requiredHostKeyAlias,
                identityURL: identityURL,
                knownHostsURL: knownHostsURL,
                boundInterface: expectedUSBContext.interfaceName
            )
        } catch SSHRouteError.unsafeCredentialPath {
            throw TabletPrerequisiteInstallationFailure.unsafeCredentialPath
        } catch {
            throw TabletPrerequisiteInstallationFailure.unsafeUSBRoute
        }

        let token = stageToken()
        guard token.utf8.count == 32,
              token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw TabletPrerequisiteInstallationFailure.stageCreationFailed
        }
        let remoteStage = "/home/root/.rmmirror-prerequisite-stage-\(token)"
        var ownsStage = false

        do {
            try Task.checkCancellation()
            let stageExecution = try await runBound(
                Self.sshRequest(
                    route: route,
                    command: "set -eu; umask 077; test ! -e '\(remoteStage)'; mkdir '\(remoteStage)'; date +%s > '\(remoteStage)/.rmmirror-stage-created'",
                    generation: generation,
                    role: .tabletPrerequisiteStage
                ),
                timeout: Self.commandTimeout,
                expectedUSBContext: expectedUSBContext
            )
            guard Self.isSilentSuccess(stageExecution) else {
                throw TabletPrerequisiteInstallationFailure.stageCreationFailed
            }
            ownsStage = true

            for name in TabletPrerequisiteAssetName.allCases {
                guard let asset = assets[name] else {
                    throw TabletPrerequisiteInstallationFailure.assetsUnavailable
                }
                let uploadExecution = try await runBound(
                    Self.scpRequest(
                        route: route,
                        asset: asset,
                        remoteStage: remoteStage,
                        generation: generation
                    ),
                    timeout: Self.transferTimeout,
                    expectedUSBContext: expectedUSBContext
                )
                guard Self.isSilentSuccess(uploadExecution) else {
                    throw TabletPrerequisiteInstallationFailure.uploadFailed(name)
                }
            }

            let installExecution = try await runBound(
                Self.sshRequest(
                    route: route,
                    command: Self.installCommand(
                        remoteStage: remoteStage,
                        assets: assets
                    ),
                    generation: generation,
                    role: .tabletPrerequisiteInstall
                ),
                timeout: Self.commandTimeout,
                expectedUSBContext: expectedUSBContext
            )
            guard installExecution.outcome == .exited(status: 0) else {
                throw Self.installFailure(from: installExecution)
            }
            guard !installExecution.standardOutput.wasTruncated,
                  !installExecution.standardError.wasTruncated,
                  installExecution.standardError.data.isEmpty,
                  installExecution.standardOutput.data == Data(Self.completionMarker.utf8) else {
                throw TabletPrerequisiteInstallationFailure.invalidInstallResponse
            }

            try await removeStage(
                route: route,
                remoteStage: remoteStage,
                expectedUSBContext: expectedUSBContext,
                generation: generation
            )
            ownsStage = false

            let proofExecution = try await runBound(
                route.authenticationProbeRequest(generation: generation),
                timeout: Self.probeTimeout,
                expectedUSBContext: expectedUSBContext
            )
            guard !proofExecution.standardOutput.wasTruncated,
                  !proofExecution.standardError.wasTruncated,
                  proofExecution.standardError.data.isEmpty else {
                throw TabletPrerequisiteInstallationFailure
                    .postInstallVerificationFailed(.capabilityResponseInvalid)
            }
            let proof = PassiveRouteProbe.classify(proofExecution)
            guard proof.state == .authenticated,
                  proof.identityAuthenticated,
                  let capability = proof.capability,
                  capability.meetsRuntimeContract,
                  capability.transportOperational else {
                throw TabletPrerequisiteInstallationFailure
                    .postInstallVerificationFailed(proof.detail)
            }
            return capability
        } catch is CancellationError {
            if ownsStage {
                await cleanupAfterCancellation(
                    route: route,
                    remoteStage: remoteStage,
                    expectedUSBContext: expectedUSBContext,
                    generation: generation
                )
            }
            throw CancellationError()
        } catch let failure as TabletPrerequisiteInstallationFailure {
            if ownsStage {
                await cleanupIfSameTablet(
                    route: route,
                    remoteStage: remoteStage,
                    expectedUSBContext: expectedUSBContext,
                    generation: generation
                )
            }
            throw failure
        } catch {
            if ownsStage {
                await cleanupIfSameTablet(
                    route: route,
                    remoteStage: remoteStage,
                    expectedUSBContext: expectedUSBContext,
                    generation: generation
                )
            }
            throw TabletPrerequisiteInstallationFailure.processUnavailable
        }
    }

    private func runBound(
        _ request: ProcessRequest,
        timeout: Duration,
        expectedUSBContext: DirectUSBRouteContext
    ) async throws -> ProcessExecutionResult {
        try Task.checkCancellation()
        try await requireExactUSBContext(expectedUSBContext)
        let execution: ProcessExecutionResult
        do {
            execution = try await processRunner.run(request, timeout: timeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TabletPrerequisiteInstallationFailure.processUnavailable
        }
        try await requireExactUSBContext(expectedUSBContext)
        try Task.checkCancellation()
        return execution
    }

    private func removeStage(
        route: SSHRoute,
        remoteStage: String,
        expectedUSBContext: DirectUSBRouteContext,
        generation: GenerationID
    ) async throws {
        let execution = try await runBound(
            Self.cleanupRequest(
                route: route,
                remoteStage: remoteStage,
                generation: generation
            ),
            timeout: Self.commandTimeout,
            expectedUSBContext: expectedUSBContext
        )
        guard Self.isSilentSuccess(execution) else {
            throw TabletPrerequisiteInstallationFailure.cleanupFailed
        }
    }

    private func cleanupAfterCancellation(
        route: SSHRoute,
        remoteStage: String,
        expectedUSBContext: DirectUSBRouteContext,
        generation: GenerationID
    ) async {
        let cleanup = Task { [self] in
            await cleanupIfSameTablet(
                route: route,
                remoteStage: remoteStage,
                expectedUSBContext: expectedUSBContext,
                generation: generation
            )
        }
        await cleanup.value
    }

    private func cleanupIfSameTablet(
        route: SSHRoute,
        remoteStage: String,
        expectedUSBContext: DirectUSBRouteContext,
        generation: GenerationID
    ) async {
        guard case let .verified(current) = await routeVerifier.verify(),
              current == expectedUSBContext else {
            return
        }
        let request = Self.cleanupRequest(
            route: route,
            remoteStage: remoteStage,
            generation: generation
        )
        guard let execution = try? await processRunner.run(
            request,
            timeout: Self.commandTimeout
        ),
              case let .verified(afterCleanup) = await routeVerifier.verify(),
              afterCleanup == expectedUSBContext,
              Self.isSilentSuccess(execution) else {
            return
        }
    }

    private func requireExactUSBContext(
        _ expected: DirectUSBRouteContext
    ) async throws {
        switch await routeVerifier.verify() {
        case let .verified(current) where current == expected:
            return
        case .verified:
            throw TabletPrerequisiteInstallationFailure.usbContextChanged
        case .unavailable, .accessoryApprovalRequired:
            throw TabletPrerequisiteInstallationFailure.usbUnavailable
        case .unsafeRoute:
            throw TabletPrerequisiteInstallationFailure.unsafeUSBRoute
        }
    }

    private static func validateAssetMetadata(
        _ assets: [TabletPrerequisiteAssetName: TabletPrerequisiteAsset]
    ) throws {
        guard Set(assets.keys) == Set(TabletPrerequisiteAssetName.allCases),
              assets.count == TabletPrerequisiteAssetName.allCases.count else {
            throw TabletPrerequisiteInstallationFailure.assetsUnavailable
        }
        for name in TabletPrerequisiteAssetName.allCases {
            guard let asset = assets[name],
                  asset.name == name,
                  SafeConnectionValue.isAbsoluteFileURL(asset.url),
                  asset.url.lastPathComponent == name.rawValue,
                  SafeConnectionValue.isLowercaseSHA256(asset.sha256) else {
                throw TabletPrerequisiteInstallationFailure.unsafeAsset(name)
            }
        }
    }

    private static func sshRequest(
        route: SSHRoute,
        command: String,
        generation: GenerationID,
        role: ProcessRole
    ) -> ProcessRequest {
        ProcessRequest(
            executableURL: sshExecutableURL,
            arguments: route.baseArguments + [
                "-T",
                "root@\(route.host)",
                command,
            ],
            generation: generation,
            role: role,
            outputLimit: outputLimit
        )
    }

    private static func scpRequest(
        route: SSHRoute,
        asset: TabletPrerequisiteAsset,
        remoteStage: String,
        generation: GenerationID
    ) -> ProcessRequest {
        ProcessRequest(
            executableURL: scpExecutableURL,
            arguments: ["-O", "-q"] + route.baseArguments + [
                asset.url.path,
                "root@\(route.host):\(remoteStage)/\(asset.name.rawValue)",
            ],
            generation: generation,
            role: .tabletPrerequisiteUpload,
            outputLimit: outputLimit
        )
    }

    private static func cleanupRequest(
        route: SSHRoute,
        remoteStage: String,
        generation: GenerationID
    ) -> ProcessRequest {
        sshRequest(
            route: route,
            command: "rm -rf '\(remoteStage)'",
            generation: generation,
            role: .tabletPrerequisiteCleanup
        )
    }

    private static func installCommand(
        remoteStage: String,
        assets: [TabletPrerequisiteAssetName: TabletPrerequisiteAsset]
    ) -> String {
        let installerHash = assets[.prerequisiteInstaller]!.sha256
        return """
        set -eu
        stage='\(remoteStage)'
        test -d "$stage"
        test ! -L "$stage"
        test "$(sha256sum "$stage/install-mirror-prerequisites.sh" | cut -d' ' -f1)" = '\(installerHash)'
        chmod 0700 "$stage/install-mirror-prerequisites.sh"
        RMMIRROR_CONTRACT_SHA256='\(assets[.contract]!.sha256)' \
        RMMIRROR_TRANSPORT_WAKE_SHA256='\(assets[.transportWakeBinary]!.sha256)' \
        RMMIRROR_TRANSPORT_SERVICE_SHA256='\(assets[.transportWakeService]!.sha256)' \
        RMMIRROR_TRANSPORT_INSTALLER_SHA256='\(assets[.transportWakeInstaller]!.sha256)' \
        RMMIRROR_SLEEP_GUARD_SHA256='\(assets[.sleepGuard]!.sha256)' \
        RMMIRROR_PROBE_SHA256='\(assets[.probe]!.sha256)' \
        RMMIRROR_FILES_LOOPBACK_SHA256='\(assets[.filesLoopback]!.sha256)' \
        "$stage/install-mirror-prerequisites.sh"
        """
    }

    private static func isSilentSuccess(_ execution: ProcessExecutionResult) -> Bool {
        execution.outcome == .exited(status: 0) &&
            !execution.standardOutput.wasTruncated &&
            execution.standardOutput.data.isEmpty &&
            !execution.standardError.wasTruncated &&
            execution.standardError.data.isEmpty
    }

    private static func installFailure(
        from execution: ProcessExecutionResult
    ) -> TabletPrerequisiteInstallationFailure {
        guard !execution.standardError.wasTruncated,
              let standardError = String(
                  data: execution.standardError.data,
                  encoding: .utf8
              ) else {
            return .installFailed
        }
        let lines = standardError
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
        let permanentXoviFailures = Set([
            "rmmirror-prerequisite: xovi_incompatible",
            "rmmirror-prerequisite: xovi_version_mismatch",
            "rmmirror-prerequisite: xovi_asset_mismatch:xovi.so",
            "rmmirror-prerequisite: xovi_asset_mismatch:start",
            "rmmirror-prerequisite: xovi_asset_mismatch:stock",
            "rmmirror-prerequisite: xovi_asset_mismatch:inactive-extensions/framebuffer-spy.so",
            "rmmirror-prerequisite: xovi_asset_mismatch:inactive-extensions/xovi-message-broker.so",
        ])
        if lines.contains(where: permanentXoviFailures.contains) {
            return .incompatibleXovi
        }
        if lines.contains("rmmirror-prerequisite: install_target_incompatible") {
            return .incompatibleInstallTarget
        }
        let prefix = "RMMIRROR_PREREQUISITES_INSTALL_FAILED="
        guard let rawPhase = lines
            .reversed()
            .compactMap({ line -> String? in
                guard line.hasPrefix(prefix) else { return nil }
                return String(line.dropFirst(prefix.count))
            })
            .first,
              let phase = TabletPrerequisiteInstallPhase(rawValue: rawPhase) else {
            return .installFailed
        }
        return .transactionFailed(phase)
    }
}
