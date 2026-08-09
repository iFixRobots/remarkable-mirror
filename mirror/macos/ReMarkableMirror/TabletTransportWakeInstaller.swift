import CryptoKit
import Foundation

enum TabletTransportWakeAssetName: String, CaseIterable, Equatable, Hashable, Sendable {
    case binary = "rmmirror-transport-wake"
    case service = "rmmirror-transport-wake.service"
    case installer = "install-transport-wake.sh"
    case sleepGuard = "rmmirror-usb-sleep-guard.conf"

    fileprivate var sizeRange: ClosedRange<Int> {
        switch self {
        case .binary:
            1_024...32_000_000
        case .service, .installer, .sleepGuard:
            1...1_000_000
        }
    }
}

struct TabletTransportWakeAsset: Equatable, Sendable {
    let name: TabletTransportWakeAssetName
    let url: URL
    let sha256: String
}

protocol TabletTransportWakeAssetProviding: Sendable {
    func loadAssets() throws -> [TabletTransportWakeAssetName: TabletTransportWakeAsset]
}

enum TabletTransportWakeInstallationFailure: Error, Equatable, Sendable {
    case busy
    case assetsUnavailable
    case unsafeAsset(TabletTransportWakeAssetName)
    case unsafeCredentialPath
    case unsafeUSBRoute
    case usbUnavailable
    case usbContextChanged
    case processUnavailable
    case stageCreationFailed
    case uploadFailed(TabletTransportWakeAssetName)
    case installFailed
    case installStageValidationFailed
    case installerExecutionFailed
    case installAnchorValidationFailed
    case installTransportStatusValidationFailed
    case installListenerValidationFailed
    case invalidInstallResponse
    case cleanupFailed
    case postInstallVerificationFailed(PassiveRouteProbeDetail)
}

protocol TabletTransportWakeInstalling: Actor {
    func installOrUpgrade(
        identityURL: URL,
        knownHostsURL: URL,
        expectedUSBContext: DirectUSBRouteContext,
        generation: GenerationID
    ) async throws -> PassiveRouteCapability
}

/// Reads the four signed-app resources used by the transactional tablet-side
/// transport-wake installer. The resource directory is deliberately exact:
/// extra, missing, linked, malformed, or oversized assets fail closed before
/// any tablet process is launched.
struct BundledTabletTransportWakeAssetProvider: TabletTransportWakeAssetProviding {
    private static let resourceDirectoryName = "TabletTransportWake"

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

    func loadAssets() throws -> [TabletTransportWakeAssetName: TabletTransportWakeAsset] {
        guard let directoryURL,
              Self.isSafeAbsoluteFileURL(directoryURL),
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
            throw TabletTransportWakeInstallationFailure.assetsUnavailable
        }

        let expectedNames = Set(TabletTransportWakeAssetName.allCases.map(\.rawValue))
        guard Set(contents.map(\.lastPathComponent)) == expectedNames,
              contents.count == expectedNames.count else {
            throw TabletTransportWakeInstallationFailure.assetsUnavailable
        }

        var assets: [TabletTransportWakeAssetName: TabletTransportWakeAsset] = [:]
        for name in TabletTransportWakeAssetName.allCases {
            let url = directoryURL.appending(path: name.rawValue)
            guard Self.isSafeAbsoluteFileURL(url),
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
                  data.count == size,
                  Self.validate(data: data, for: name) else {
                throw TabletTransportWakeInstallationFailure.unsafeAsset(name)
            }
            let digest = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            assets[name] = TabletTransportWakeAsset(
                name: name,
                url: url,
                sha256: digest
            )
        }
        return assets
    }

    private static func validate(
        data: Data,
        for name: TabletTransportWakeAssetName
    ) -> Bool {
        switch name {
        case .binary:
            return isStaticAArch64Executable(data)
        case .service:
            return text(data, contains: [
                "Type=simple",
                "ExecStart=/usr/libexec/rmmirror-transport-wake",
                "--udc-state-glob /sys/class/udc/*/state",
                "--power-online /sys/class/power_supply/max77818-charger/online",
                "--wake-listen 127.0.0.1:51337",
                "--wake-listen 10.11.99.1:51337",
            ])
        case .installer:
            return text(data, contains: [
                "#!/bin/sh",
                "set -eu",
                "expected_transport_version=0.6.0",
                "carrier-qualified-power-hold/v1",
                "udc_configured_count",
                "wait_for_operational_status",
                "RMMIRROR_TRANSPORT_WAKE=installed",
                "rollback_install_transaction",
            ])
        case .sleepGuard:
            return text(data, contains: [
                "[Service]",
                "ExecCondition=/usr/libexec/rmmirror-transport-wake hold-system-sleep",
                "--udc-state-glob /sys/class/udc/*/state",
                "--power-online /sys/class/power_supply/max77818-charger/online",
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

    private static func isStaticAArch64Executable(_ data: Data) -> Bool {
        guard data.count >= 64,
              data[0] == 0x7f,
              data[1] == 0x45,
              data[2] == 0x4c,
              data[3] == 0x46,
              data[4] == 2,
              data[5] == 1,
              uint16(data, at: 16) == 2,
              uint16(data, at: 18) == 183,
              let programHeaderOffset = uint64(data, at: 32),
              let programHeaderSize = uint16(data, at: 54),
              let programHeaderCount = uint16(data, at: 56) else {
            return false
        }
        guard programHeaderCount == 0 || programHeaderSize >= 56 else { return false }
        for index in 0..<Int(programHeaderCount) {
            let offset = Int(programHeaderOffset) + index * Int(programHeaderSize)
            guard offset >= 0,
                  offset <= data.count - Int(programHeaderSize),
                  let type = uint32(data, at: offset),
                  type != 3 else {
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

    private static func isSafeAbsoluteFileURL(_ url: URL) -> Bool {
        url.isFileURL &&
            url.path.first == "/" &&
            url.path.utf8.count <= 4_096 &&
            !url.path.contains("\0") &&
            !url.path.contains("\r") &&
            !url.path.contains("\n")
    }
}

/// Installs or upgrades only the transport-wake prerequisite over the exact
/// direct USB-C attachment owned by Add This Mac or Repair USB-C. It never
/// constructs a Wi-Fi connection and it never starts or restarts Xochitl or Xovi.
actor TabletTransportWakeInstaller: TabletTransportWakeInstalling {
    static let completionMarker = "RMMIRROR_TRANSPORT_WAKE_DEPLOYED=1\n"

    private static let sshExecutableURL = URL(filePath: "/usr/bin/ssh")
    private static let scpExecutableURL = URL(filePath: "/usr/bin/scp")
    private static let transferTimeout: Duration = .seconds(60)
    private static let commandTimeout: Duration = .seconds(60)
    private static let probeTimeout: Duration = .seconds(7)
    private static let outputLimit = 32_768

    private let assetProvider: any TabletTransportWakeAssetProviding
    private let routeVerifier: any TabletKeyAuthorizationRouteVerifying
    private let processRunner: any ProcessRunning
    private let stageToken: @Sendable () -> String

    private var isInstalling = false

    init(
        assetProvider: any TabletTransportWakeAssetProviding =
            BundledTabletTransportWakeAssetProvider(),
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

    func installOrUpgrade(
        identityURL: URL,
        knownHostsURL: URL,
        expectedUSBContext: DirectUSBRouteContext,
        generation: GenerationID
    ) async throws -> PassiveRouteCapability {
        guard !isInstalling else {
            throw TabletTransportWakeInstallationFailure.busy
        }
        isInstalling = true
        defer { isInstalling = false }

        let assets: [TabletTransportWakeAssetName: TabletTransportWakeAsset]
        do {
            assets = try assetProvider.loadAssets()
        } catch let failure as TabletTransportWakeInstallationFailure {
            throw failure
        } catch {
            throw TabletTransportWakeInstallationFailure.assetsUnavailable
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
            throw TabletTransportWakeInstallationFailure.unsafeCredentialPath
        } catch {
            throw TabletTransportWakeInstallationFailure.unsafeUSBRoute
        }

        let token = stageToken()
        guard token.utf8.count == 32,
              token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw TabletTransportWakeInstallationFailure.stageCreationFailed
        }
        let remoteStage = "/home/root/.rmmirror-transport-stage-\(token)"
        var stageMayExist = false

        do {
            try Task.checkCancellation()
            stageMayExist = true
            let stageExecution = try await runBound(
                Self.sshRequest(
                    route: route,
                    command: "umask 077; test ! -e '\(remoteStage)'; mkdir '\(remoteStage)'",
                    generation: generation,
                    role: .transportWakeStage
                ),
                timeout: Self.commandTimeout,
                expectedUSBContext: expectedUSBContext
            )
            guard Self.isSilentSuccess(stageExecution) else {
                throw TabletTransportWakeInstallationFailure.stageCreationFailed
            }

            for name in TabletTransportWakeAssetName.allCases {
                guard let asset = assets[name] else {
                    throw TabletTransportWakeInstallationFailure.assetsUnavailable
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
                    throw TabletTransportWakeInstallationFailure.uploadFailed(name)
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
                    role: .transportWakeInstall
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
                throw TabletTransportWakeInstallationFailure.invalidInstallResponse
            }

            try await removeStage(
                route: route,
                remoteStage: remoteStage,
                expectedUSBContext: expectedUSBContext,
                generation: generation
            )
            stageMayExist = false

            let proofExecution = try await runBound(
                route.authenticationProbeRequest(generation: generation),
                timeout: Self.probeTimeout,
                expectedUSBContext: expectedUSBContext
            )
            guard !proofExecution.standardOutput.wasTruncated,
                  !proofExecution.standardError.wasTruncated,
                  proofExecution.standardError.data.isEmpty else {
                throw TabletTransportWakeInstallationFailure
                    .postInstallVerificationFailed(.capabilityResponseInvalid)
            }
            let proof = PassiveRouteProbe.classify(proofExecution)
            guard proof.state == .authenticated,
                  proof.identityAuthenticated,
                  let capability = proof.capability,
                  capability.isCurrent,
                  capability.transportOperational else {
                throw TabletTransportWakeInstallationFailure
                    .postInstallVerificationFailed(proof.detail)
            }
            return capability
        } catch is CancellationError {
            if stageMayExist {
                await cleanupAfterCancellation(
                    route: route,
                    remoteStage: remoteStage,
                    expectedUSBContext: expectedUSBContext,
                    generation: generation
                )
            }
            throw CancellationError()
        } catch let failure as TabletTransportWakeInstallationFailure {
            if stageMayExist {
                await cleanupIfSameTablet(
                    route: route,
                    remoteStage: remoteStage,
                    expectedUSBContext: expectedUSBContext,
                    generation: generation
                )
            }
            throw failure
        } catch {
            if stageMayExist {
                await cleanupIfSameTablet(
                    route: route,
                    remoteStage: remoteStage,
                    expectedUSBContext: expectedUSBContext,
                    generation: generation
                )
            }
            throw TabletTransportWakeInstallationFailure.processUnavailable
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
            throw TabletTransportWakeInstallationFailure.processUnavailable
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
            throw TabletTransportWakeInstallationFailure.cleanupFailed
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
            throw TabletTransportWakeInstallationFailure.usbContextChanged
        case .unavailable:
            throw TabletTransportWakeInstallationFailure.usbUnavailable
        case .accessoryApprovalRequired:
            throw TabletTransportWakeInstallationFailure.usbUnavailable
        case .unsafeRoute:
            throw TabletTransportWakeInstallationFailure.unsafeUSBRoute
        }
    }

    private static func validateAssetMetadata(
        _ assets: [TabletTransportWakeAssetName: TabletTransportWakeAsset]
    ) throws {
        guard Set(assets.keys) == Set(TabletTransportWakeAssetName.allCases),
              assets.count == TabletTransportWakeAssetName.allCases.count else {
            throw TabletTransportWakeInstallationFailure.assetsUnavailable
        }
        for name in TabletTransportWakeAssetName.allCases {
            guard let asset = assets[name],
                  asset.name == name,
                  asset.url.isFileURL,
                  asset.url.path.first == "/",
                  asset.url.lastPathComponent == name.rawValue,
                  !asset.url.path.contains("\0"),
                  !asset.url.path.contains("\r"),
                  !asset.url.path.contains("\n"),
                  asset.sha256.utf8.count == 64,
                  asset.sha256.utf8.allSatisfy({
                      (48...57).contains($0) || (97...102).contains($0)
                  }) else {
                throw TabletTransportWakeInstallationFailure.unsafeAsset(name)
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
        asset: TabletTransportWakeAsset,
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
            role: .transportWakeUpload,
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
            role: .transportWakeCleanup
        )
    }

    private static func installCommand(
        remoteStage: String,
        assets: [TabletTransportWakeAssetName: TabletTransportWakeAsset]
    ) -> String {
        let binaryHash = assets[.binary]!.sha256
        let serviceHash = assets[.service]!.sha256
        let installerHash = assets[.installer]!.sha256
        let sleepGuardHash = assets[.sleepGuard]!.sha256
        return """
        set -eu
        failure_phase=starting
        report_failure() {
          status=$?
          trap - EXIT
          if test "$status" -ne 0; then
            printf '%s\n' "RMMIRROR_TRANSPORT_WAKE_INSTALL_FAILED=$failure_phase" >&2
          fi
          exit "$status"
        }
        trap report_failure EXIT
        stage='\(remoteStage)'
        failure_phase=validating_stage
        test -d "$stage"
        test ! -L "$stage"
        test "$(sha256sum "$stage/rmmirror-transport-wake" | cut -d' ' -f1)" = '\(binaryHash)'
        test "$(sha256sum "$stage/rmmirror-transport-wake.service" | cut -d' ' -f1)" = '\(serviceHash)'
        test "$(sha256sum "$stage/install-transport-wake.sh" | cut -d' ' -f1)" = '\(installerHash)'
        test "$(sha256sum "$stage/rmmirror-usb-sleep-guard.conf" | cut -d' ' -f1)" = '\(sleepGuardHash)'
        chmod 0700 "$stage/install-transport-wake.sh"
        failure_phase=running_installer
        "$stage/install-transport-wake.sh" install >/dev/null
        failure_phase=validating_anchors
        test "$(sha256sum /usr/libexec/rmmirror-transport-wake | cut -d' ' -f1)" = '\(binaryHash)'
        test "$(sha256sum /usr/lib/systemd/system/rmmirror-transport-wake.service | cut -d' ' -f1)" = '\(serviceHash)'
        test "$(sha256sum /usr/lib/systemd/system/systemd-suspend-then-hibernate.service.d/50-rmmirror-usb-carrier.conf | cut -d' ' -f1)" = '\(sleepGuardHash)'
        systemctl is-active --quiet rmmirror-transport-wake.service
        test -L /usr/lib/systemd/system/multi-user.target.wants/rmmirror-transport-wake.service
        test "$(readlink /usr/lib/systemd/system/multi-user.target.wants/rmmirror-transport-wake.service)" = '../rmmirror-transport-wake.service'
        test "$(systemctl is-enabled rmmirror-transport-wake.service)" = 'static'
        multi_user_wants=$(systemctl show --property=Wants --value -- multi-user.target)
        case " $multi_user_wants " in
          *" rmmirror-transport-wake.service "*) ;;
          *) exit 1 ;;
        esac
        loaded_guard=$(systemctl show --property=DropInPaths --value -- systemd-suspend-then-hibernate.service)
        case " $loaded_guard " in
          *" /usr/lib/systemd/system/systemd-suspend-then-hibernate.service.d/50-rmmirror-usb-carrier.conf "*) ;;
          *) exit 1 ;;
        esac
        failure_phase=validating_transport_status
        grep -q '"schema":"rmmirror.transport-wake/v1"' /run/rmmirror-transport-wake.json
        grep -q '"usb_connection_policy":"carrier-qualified-power-hold/v1"' /run/rmmirror-transport-wake.json
        grep -q '"power_known":true' /run/rmmirror-transport-wake.json
        grep -q '"connection_known":true' /run/rmmirror-transport-wake.json
        grep -q '"usb_power_online":true' /run/rmmirror-transport-wake.json
        grep -q '"usb_connected":true' /run/rmmirror-transport-wake.json
        grep -q '"usb_data_qualified":true' /run/rmmirror-transport-wake.json
        grep -q '"state":"holding"' /run/rmmirror-transport-wake.json
        grep -q '"wake_lock_active":true' /run/rmmirror-transport-wake.json
        grep -q '"system_sleep_blocked":true' /run/rmmirror-transport-wake.json
        grep -q '"wake_endpoint_healthy":true' /run/rmmirror-transport-wake.json
        ! grep -q '"error":' /run/rmmirror-transport-wake.json
        failure_phase=validating_listeners
        listener_addresses=$(netstat -lnt 2>/dev/null | awk '$4 ~ /:51337$/ { print $4 }')
        test "$(printf '%s\n' "$listener_addresses" | grep -c '^127[.]0[.]0[.]1:51337$')" -eq 1
        test "$(printf '%s\n' "$listener_addresses" | grep -c '^10[.]11[.]99[.]1:51337$')" -eq 1
        test "$(printf '%s\n' "$listener_addresses" | grep -c ':51337$')" -eq 2
        failure_phase=complete
        trap - EXIT
        printf '%s\n' 'RMMIRROR_TRANSPORT_WAKE_DEPLOYED=1'
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
    ) -> TabletTransportWakeInstallationFailure {
        guard !execution.standardError.wasTruncated,
              let standardError = String(
                data: execution.standardError.data,
                encoding: .utf8
              ),
              let marker = standardError
                .split(whereSeparator: \Character.isNewline)
                .last(where: {
                    $0.hasPrefix("RMMIRROR_TRANSPORT_WAKE_INSTALL_FAILED=")
                })
                .map(String.init) else {
            return .installFailed
        }
        switch marker {
        case "RMMIRROR_TRANSPORT_WAKE_INSTALL_FAILED=validating_stage":
            return .installStageValidationFailed
        case "RMMIRROR_TRANSPORT_WAKE_INSTALL_FAILED=running_installer":
            return .installerExecutionFailed
        case "RMMIRROR_TRANSPORT_WAKE_INSTALL_FAILED=validating_anchors":
            return .installAnchorValidationFailed
        case "RMMIRROR_TRANSPORT_WAKE_INSTALL_FAILED=validating_transport_status":
            return .installTransportStatusValidationFailed
        case "RMMIRROR_TRANSPORT_WAKE_INSTALL_FAILED=validating_listeners":
            return .installListenerValidationFailed
        default:
            return .installFailed
        }
    }
}
