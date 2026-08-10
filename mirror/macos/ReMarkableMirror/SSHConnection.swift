import Darwin
import Foundation

struct GenerationID: Hashable, Sendable {
    let rawValue: UUID

    static func make() -> GenerationID {
        GenerationID(rawValue: UUID())
    }
}

enum ConnectionRoute: String, Codable, Equatable, Sendable {
    case usb
    case wifi
}

enum ManualConnectionTarget: Equatable, Sendable {
    case usb
    case wifi(host: String)

    var route: ConnectionRoute {
        switch self {
        case .usb: .usb
        case .wifi: .wifi
        }
    }
}

enum ProcessRole: String, Hashable, Sendable {
    case passiveProbe
    case wifiPairingDiscovery
    case wifiPairingEnable
    case wifiPairingWakeToken
    case wifiPairingVerification
    case frame
    case input
    case filesForward
    case wake
    case pairingKeyGeneration
    case pairingHostScan
    case pairingRouteCheck
    case tabletKeyAuthorization
    case tabletPrerequisiteStage
    case tabletPrerequisiteUpload
    case tabletPrerequisiteInstall
    case tabletPrerequisiteCleanup
}

enum ProcessIOMode: Equatable, Sendable {
    case collected
    case streaming
}

struct ProcessRequest: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let generation: GenerationID
    let role: ProcessRole
    let outputLimit: Int
    let ioMode: ProcessIOMode

    init(
        executableURL: URL,
        arguments: [String],
        generation: GenerationID,
        role: ProcessRole,
        outputLimit: Int,
        ioMode: ProcessIOMode = .collected
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.generation = generation
        self.role = role
        self.outputLimit = outputLimit
        self.ioMode = ioMode
    }
}

enum SSHRouteError: Error, Equatable, Sendable {
    case unsafeHost
    case unsafeCredentialPath
    case unsafeBoundInterface
    case invalidForward
}

enum BSDInterfaceName {
    static func isValid(_ value: String) -> Bool {
        let bytes = value.utf8
        guard !bytes.isEmpty,
              bytes.count < Int(IFNAMSIZ),
              let first = bytes.first,
              isASCIILetter(first) else {
            return false
        }
        return bytes.allSatisfy { isASCIILetter($0) || (48...57).contains($0) }
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte)
    }
}

enum OpenSSHConfigValue {
    static func quotedPath(_ path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

struct SSHRoute: Equatable, Sendable {
    static let executableURL = URL(filePath: "/usr/bin/ssh")
    static let frameStreamCommand =
        "/home/root/.local/bin/rmmirror-probe stream --interval 40ms --heartbeat-timeout 15s"
    static let inputSessionCommand =
        "/home/root/.local/bin/rmmirror-probe input --heartbeat-timeout 15s"

    let kind: ConnectionRoute
    let host: String
    let identityURL: URL
    let knownHostsURL: URL
    let boundInterface: String?

    init(
        kind: ConnectionRoute,
        host: String,
        identityURL: URL,
        knownHostsURL: URL,
        boundInterface: String? = nil
    ) throws {
        guard SafeConnectionValue.isHost(host) else {
            throw SSHRouteError.unsafeHost
        }
        guard Self.isSafeAbsoluteFileURL(identityURL),
              Self.isSafeAbsoluteFileURL(knownHostsURL) else {
            throw SSHRouteError.unsafeCredentialPath
        }
        if let boundInterface, !BSDInterfaceName.isValid(boundInterface) {
            throw SSHRouteError.unsafeBoundInterface
        }
        self.kind = kind
        self.host = host
        self.identityURL = identityURL
        self.knownHostsURL = knownHostsURL
        self.boundInterface = boundInterface
    }

    func authenticationProbeRequest(generation: GenerationID) -> ProcessRequest {
        ProcessRequest(
            executableURL: Self.executableURL,
            arguments: baseArguments
                + ["-T", "root@\(host)", PassiveRouteProbe.capabilityCommand],
            generation: generation,
            role: .passiveProbe,
            outputLimit: 32_768
        )
    }

    func frameStreamRequest(generation: GenerationID) -> ProcessRequest {
        ProcessRequest(
            executableURL: Self.executableURL,
            arguments: baseArguments + [
                "-C",
                "-T",
                "root@\(host)",
                Self.frameStreamCommand,
            ],
            generation: generation,
            role: .frame,
            outputLimit: 32_768,
            ioMode: .streaming
        )
    }

    func openFrameStream(
        generation: GenerationID,
        registry: OwnedProcessRegistry
    ) async throws -> OwnedStreamingProcess {
        try await registry.launchStreaming(
            frameStreamRequest(generation: generation),
            heartbeat: .newlineEveryThreeSeconds
        )
    }

    func inputSessionRequest(generation: GenerationID) -> ProcessRequest {
        ProcessRequest(
            executableURL: Self.executableURL,
            arguments: baseArguments + [
                "-T",
                "root@\(host)",
                Self.inputSessionCommand,
            ],
            generation: generation,
            role: .input,
            outputLimit: 32_768,
            ioMode: .streaming
        )
    }

    func openInputStream(
        generation: GenerationID,
        registry: OwnedProcessRegistry
    ) async throws -> OwnedStreamingProcess {
        try await registry.launchInteractive(
            inputSessionRequest(generation: generation)
        )
    }

    func forwardRequest(
        generation: GenerationID,
        role: ProcessRole,
        localPort: UInt16,
        targetHost: String,
        targetPort: UInt16
    ) throws -> ProcessRequest {
        guard role == .filesForward,
              localPort > 0,
              targetPort > 0,
              targetHost == "127.0.0.1" else {
            throw SSHRouteError.invalidForward
        }
        return ProcessRequest(
            executableURL: Self.executableURL,
            arguments: baseArguments + [
                "-o", "ExitOnForwardFailure=yes",
                "-L", "127.0.0.1:\(localPort):\(targetHost):\(targetPort)",
                "-N",
                "root@\(host)",
            ],
            generation: generation,
            role: role,
            outputLimit: 8_192
        )
    }

    var baseArguments: [String] {
        var arguments = [
            "-F", "/dev/null",
            "-i", identityURL.path,
        ]
        if let boundInterface {
            arguments += ["-o", "BindInterface=\(boundInterface)"]
        }
        arguments += [
            "-o", "BatchMode=yes",
            "-o", "IdentitiesOnly=yes",
            "-o", "IdentityAgent=none",
            "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "HostKeyAlgorithms=ssh-ed25519",
            "-o", "UserKnownHostsFile=\(OpenSSHConfigValue.quotedPath(knownHostsURL.path))",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "HostKeyAlias=\(DeviceProfile.requiredHostKeyAlias)",
            "-o", "CheckHostIP=no",
            "-o", "UpdateHostKeys=no",
            "-o", "ConnectTimeout=3",
            "-o", "ServerAliveInterval=3",
            "-o", "ServerAliveCountMax=3",
        ]
        return arguments
    }

    private static func isSafeAbsoluteFileURL(_ url: URL) -> Bool {
        url.isFileURL &&
            url.path.first == "/" &&
            !url.path.contains("\0") &&
            !url.path.contains("\n") &&
            !url.path.contains("\r")
    }
}
