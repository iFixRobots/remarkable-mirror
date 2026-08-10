import CryptoKit
import Foundation

struct DeviceProfile: Codable, Equatable, Sendable {
    static let currentSchema = "rmmirror.macos-device-profile/v1"
    static let requiredHostKeyAlias = "10.11.99.1"

    let schema: String
    let profileID: UUID
    let pairingState: PairingState
    let sshHostKeyAlias: String
    let sshFingerprint: String
    let identityFile: String
    let knownHostsFile: String
    let wifi: VerifiedWiFiRoute?
    let lastVerified: VerifiedTabletCapability?

    enum PairingState: String, Codable, Sendable {
        case pendingTabletAuthorization
        case pendingWiFiVerification
        case ready
    }

    static func pendingTabletAuthorization(
        id: UUID,
        hostIdentity: KnownHostIdentity
    ) -> DeviceProfile {
        DeviceProfile(
            schema: currentSchema,
            profileID: id,
            pairingState: .pendingTabletAuthorization,
            sshHostKeyAlias: hostIdentity.alias,
            sshFingerprint: hostIdentity.fingerprint,
            identityFile: DeviceProfileStore.privateKeyFileName,
            knownHostsFile: DeviceProfileStore.knownHostsFileName,
            wifi: nil,
            lastVerified: nil
        )
    }

    static func ready(
        from pendingWiFiVerification: DeviceProfile,
        wifi: VerifiedWiFiRoute,
        capability: VerifiedTabletCapability
    ) throws -> DeviceProfile {
        let pendingWiFiVerification = try pendingWiFiVerification.validated()
        guard pendingWiFiVerification.pairingState == .pendingWiFiVerification,
              let authenticatedUSBCapability = pendingWiFiVerification.lastVerified else {
            throw DeviceProfileValidationError.inconsistentPairingState
        }
        try capability.validate()
        guard capability.matchesTabletState(of: authenticatedUSBCapability) else {
            throw DeviceProfileValidationError.capabilityMismatch
        }
        guard capability.verifiedAt >= authenticatedUSBCapability.verifiedAt else {
            throw DeviceProfileValidationError.staleVerification
        }

        return try DeviceProfile(
            schema: pendingWiFiVerification.schema,
            profileID: pendingWiFiVerification.profileID,
            pairingState: .ready,
            sshHostKeyAlias: pendingWiFiVerification.sshHostKeyAlias,
            sshFingerprint: pendingWiFiVerification.sshFingerprint,
            identityFile: pendingWiFiVerification.identityFile,
            knownHostsFile: pendingWiFiVerification.knownHostsFile,
            wifi: wifi,
            lastVerified: capability.canonicalizedForStorage()
        ).validated()
    }

    static func pendingWiFiVerification(
        from pendingTabletAuthorization: DeviceProfile,
        authenticatedUSBCapability: VerifiedTabletCapability
    ) throws -> DeviceProfile {
        let pendingTabletAuthorization = try pendingTabletAuthorization.validated()
        guard pendingTabletAuthorization.pairingState == .pendingTabletAuthorization else {
            throw DeviceProfileValidationError.inconsistentPairingState
        }

        return try DeviceProfile(
            schema: pendingTabletAuthorization.schema,
            profileID: pendingTabletAuthorization.profileID,
            pairingState: .pendingWiFiVerification,
            sshHostKeyAlias: pendingTabletAuthorization.sshHostKeyAlias,
            sshFingerprint: pendingTabletAuthorization.sshFingerprint,
            identityFile: pendingTabletAuthorization.identityFile,
            knownHostsFile: pendingTabletAuthorization.knownHostsFile,
            wifi: nil,
            lastVerified: authenticatedUSBCapability.canonicalizedForStorage()
        ).validated()
    }

    /// Updates the transitional proof after the already-authorized app key
    /// authenticates over an exact bound USB route. A timestamp-only reproof
    /// is intentionally a no-op; a changed tablet boot or software component
    /// becomes the new checkpoint that the immediately following Wi-Fi proof
    /// must match.
    func refreshingPendingWiFiVerification(
        with authenticatedUSBCapability: VerifiedTabletCapability
    ) throws -> DeviceProfile {
        let pending = try validated()
        guard pending.pairingState == .pendingWiFiVerification,
              let currentCapability = pending.lastVerified else {
            throw DeviceProfileValidationError.inconsistentPairingState
        }
        try authenticatedUSBCapability.validate()
        if authenticatedUSBCapability.matchesTabletState(of: currentCapability) {
            return pending
        }
        guard authenticatedUSBCapability.verifiedAt >= currentCapability.verifiedAt else {
            throw DeviceProfileValidationError.staleVerification
        }

        return try DeviceProfile(
            schema: pending.schema,
            profileID: pending.profileID,
            pairingState: pending.pairingState,
            sshHostKeyAlias: pending.sshHostKeyAlias,
            sshFingerprint: pending.sshFingerprint,
            identityFile: pending.identityFile,
            knownHostsFile: pending.knownHostsFile,
            wifi: nil,
            lastVerified: authenticatedUSBCapability.canonicalizedForStorage()
        ).validated()
    }

    func refreshingLastVerified(
        with capability: VerifiedTabletCapability
    ) throws -> DeviceProfile {
        let ready = try validated()
        guard ready.pairingState == .ready,
              let wifi = ready.wifi,
              let currentCapability = ready.lastVerified else {
            throw DeviceProfileValidationError.inconsistentPairingState
        }
        try capability.validate()
        guard capability.verifiedAt >= currentCapability.verifiedAt else {
            throw DeviceProfileValidationError.staleVerification
        }

        return try DeviceProfile(
            schema: ready.schema,
            profileID: ready.profileID,
            pairingState: ready.pairingState,
            sshHostKeyAlias: ready.sshHostKeyAlias,
            sshFingerprint: ready.sshFingerprint,
            identityFile: ready.identityFile,
            knownHostsFile: ready.knownHostsFile,
            wifi: wifi,
            lastVerified: capability.canonicalizedForStorage()
        ).validated()
    }

    func validated() throws -> DeviceProfile {
        guard schema == Self.currentSchema else {
            throw DeviceProfileValidationError.unsupportedSchema
        }
        guard sshHostKeyAlias == Self.requiredHostKeyAlias else {
            throw DeviceProfileValidationError.invalidHostAlias
        }
        guard Self.isValidFingerprint(sshFingerprint) else {
            throw DeviceProfileValidationError.invalidFingerprint
        }
        guard identityFile == DeviceProfileStore.privateKeyFileName,
              knownHostsFile == DeviceProfileStore.knownHostsFileName else {
            throw DeviceProfileValidationError.invalidCredentialReference
        }

        switch pairingState {
        case .pendingTabletAuthorization:
            guard wifi == nil, lastVerified == nil else {
                throw DeviceProfileValidationError.inconsistentPairingState
            }
        case .pendingWiFiVerification:
            guard wifi == nil, let lastVerified else {
                throw DeviceProfileValidationError.inconsistentPairingState
            }
            try lastVerified.validate()
        case .ready:
            guard let wifi, let lastVerified else {
                throw DeviceProfileValidationError.inconsistentPairingState
            }
            try wifi.validate()
            try lastVerified.validate()
        }

        return self
    }

    private static func isValidFingerprint(_ value: String) -> Bool {
        guard value.hasPrefix("SHA256:") else { return false }
        let encoded = String(value.dropFirst("SHA256:".count))
        guard encoded.count == 43,
              encoded.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/") }),
              let decoded = Data(base64Encoded: encoded + "=") else {
            return false
        }
        return decoded.count == 32
    }
}

struct VerifiedWiFiRoute: Codable, Equatable, Sendable {
    let host: String
    let contextDigest: String

    fileprivate func validate() throws {
        guard TabletWiFiPairingProbe.isGlobalIPv4Host(host) else {
            throw DeviceProfileValidationError.invalidWiFiRoute
        }
        guard (try? WiFiNetworkContextDigest(storageValue: contextDigest)) != nil else {
            throw DeviceProfileValidationError.invalidWiFiRoute
        }
    }
}

struct VerifiedTabletCapability: Codable, Equatable, Sendable {
    let verifiedAt: Date
    let bootID: UUID
    let activeRoot: String
    let osVersion: String
    let osBuild: String
    let kernelRelease: String
    let probeVersion: String
    let transportVersion: String
    let transportSchema: String
    let xoviVersion: String

    fileprivate func validate() throws {
        guard verifiedAt.timeIntervalSince1970.isFinite,
              verifiedAt.timeIntervalSince1970 > 0,
              activeRoot.first == "/",
              !activeRoot.contains(where: \Character.isWhitespace),
              SafeConnectionValue.isOpaque(osVersion),
              SafeConnectionValue.isOpaque(osBuild),
              SafeConnectionValue.isOpaque(kernelRelease),
              SafeConnectionValue.isToken(probeVersion, allowsSlash: false),
              SafeConnectionValue.isToken(transportVersion, allowsSlash: false),
              SafeConnectionValue.isToken(transportSchema, allowsSlash: true),
              SafeConnectionValue.isToken(xoviVersion, allowsSlash: false) else {
            throw DeviceProfileValidationError.invalidCapability
        }
    }

    fileprivate func canonicalizedForStorage() -> VerifiedTabletCapability {
        VerifiedTabletCapability(
            verifiedAt: Date(
                timeIntervalSince1970: verifiedAt.timeIntervalSince1970.rounded(.down)
            ),
            bootID: bootID,
            activeRoot: activeRoot,
            osVersion: osVersion,
            osBuild: osBuild,
            kernelRelease: kernelRelease,
            probeVersion: probeVersion,
            transportVersion: transportVersion,
            transportSchema: transportSchema,
            xoviVersion: xoviVersion
        )
    }

    fileprivate func matchesTabletState(
        of other: VerifiedTabletCapability
    ) -> Bool {
        bootID == other.bootID
            && activeRoot == other.activeRoot
            && osVersion == other.osVersion
            && osBuild == other.osBuild
            && kernelRelease == other.kernelRelease
            && probeVersion == other.probeVersion
            && transportVersion == other.transportVersion
            && transportSchema == other.transportSchema
            && xoviVersion == other.xoviVersion
    }
}

enum DeviceProfileValidationError: Error, Equatable, Sendable {
    case unsupportedSchema
    case invalidHostAlias
    case invalidFingerprint
    case invalidCredentialReference
    case inconsistentPairingState
    case invalidWiFiRoute
    case invalidCapability
    case capabilityMismatch
    case staleVerification
}

struct KnownHostIdentity: Equatable, Sendable {
    static let algorithm = "ssh-ed25519"

    let alias: String
    let keyBlob: Data
    let fingerprint: String

    init(alias: String, keyBlob: Data) throws {
        guard alias == DeviceProfile.requiredHostKeyAlias else {
            throw KnownHostIdentityError.invalidAlias
        }
        try Self.validateEd25519Blob(keyBlob)

        self.alias = alias
        self.keyBlob = keyBlob
        let digest = Data(SHA256.hash(data: keyBlob))
        self.fingerprint = "SHA256:" + digest.base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    init(knownHostsData: Data, expectedAlias: String) throws {
        guard knownHostsData.count <= 65_536,
              let text = String(data: knownHostsData, encoding: .utf8) else {
            throw KnownHostIdentityError.invalidEncoding
        }
        let lines = text
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
        guard lines.count == 1 else {
            throw KnownHostIdentityError.invalidEntryCount
        }

        let fields = lines[0].split(whereSeparator: \Character.isWhitespace)
        guard fields.count == 3,
              fields[0] == Substring(expectedAlias),
              fields[1] == Substring(Self.algorithm),
              let blob = Data(base64Encoded: String(fields[2])) else {
            throw KnownHostIdentityError.invalidEntry
        }
        try self.init(alias: expectedAlias, keyBlob: blob)
    }

    var knownHostsData: Data {
        Data("\(alias) \(Self.algorithm) \(keyBlob.base64EncodedString())\n".utf8)
    }

    private static func validateEd25519Blob(_ data: Data) throws {
        var reader = SSHWireReader(data: data)
        guard try reader.readField() == Data(algorithm.utf8),
              try reader.readField().count == 32,
              reader.isAtEnd else {
            throw KnownHostIdentityError.invalidKeyBlob
        }
    }
}

enum KnownHostIdentityError: Error, Equatable, Sendable {
    case invalidAlias
    case invalidEncoding
    case invalidEntryCount
    case invalidEntry
    case invalidKeyBlob
}

private struct SSHWireReader {
    let data: Data
    private(set) var offset = 0

    var isAtEnd: Bool { offset == data.count }

    mutating func readField() throws -> Data {
        guard offset + 4 <= data.count else {
            throw KnownHostIdentityError.invalidKeyBlob
        }
        let length = data[offset..<(offset + 4)].reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        offset += 4
        guard length <= 16_384,
              offset + Int(length) <= data.count else {
            throw KnownHostIdentityError.invalidKeyBlob
        }
        let field = data[offset..<(offset + Int(length))]
        offset += Int(length)
        return Data(field)
    }
}

enum SafeConnectionValue {
    static func isAbsoluteFileURL(_ url: URL) -> Bool {
        url.isFileURL &&
            url.path.first == "/" &&
            url.path.utf8.count <= 4_096 &&
            !url.path.contains("\0") &&
            !url.path.contains("\r") &&
            !url.path.contains("\n")
    }

    static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    static func isHost(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= 255,
              value.first != "-",
              value.allSatisfy({ character in
                  character.isASCII &&
                      !character.isWhitespace &&
                      !character.isNewline &&
                      !containsControl(character)
              }) else {
            return false
        }
        return value.allSatisfy { character in
            character.isLetter || character.isNumber || "._-:+=".contains(character)
        }
    }

    static func isOpaque(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            value.count <= 256 &&
            !value.contains(where: containsControl)
    }

    static func isToken(_ value: String, allowsSlash: Bool) -> Bool {
        guard isOpaque(value), !value.contains(where: \Character.isWhitespace) else { return false }
        let allowedPunctuation = allowsSlash ? "._-:+/=" : "._-:+="
        return value.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || allowedPunctuation.contains(character))
        }
    }

    private static func containsControl(_ character: Character) -> Bool {
        character.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
