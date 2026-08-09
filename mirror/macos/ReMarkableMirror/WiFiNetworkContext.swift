import CryptoKit
import Darwin
import Foundation
import Security
import SystemConfiguration

enum WiFiNetworkContextError: Error, Equatable, Sendable {
    case currentNetworkUnavailable
    case currentNetworkChanged
    case invalidStoredDigest
    case invalidStoredSecret
    case invalidGeneratedSecret
    case randomGenerationFailed(OSStatus)
    case keychainAccessDenied
    case keychainUnavailable(OSStatus)
    case keychainRaceLost
}

struct WiFiNetworkContextDigest: Equatable, Sendable {
    static let prefix = "hmac-sha256:"

    let storageValue: String

    init(storageValue: String) throws {
        let encoded = storageValue.dropFirst(Self.prefix.count)
        guard storageValue.hasPrefix(Self.prefix),
              encoded.count == SHA256.byteCount * 2,
              encoded.allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase }) else {
            throw WiFiNetworkContextError.invalidStoredDigest
        }
        self.storageValue = storageValue
    }

    fileprivate init(authenticationCode: HMAC<SHA256>.MAC) {
        storageValue = Self.prefix + authenticationCode.map { String(format: "%02x", $0) }.joined()
    }

    fileprivate var authenticationCode: Data {
        let encoded = storageValue.dropFirst(Self.prefix.count)
        var result = Data()
        result.reserveCapacity(SHA256.byteCount)

        var index = encoded.startIndex
        while index < encoded.endIndex {
            let next = encoded.index(index, offsetBy: 2)
            result.append(UInt8(encoded[index..<next], radix: 16)!)
            index = next
        }
        return result
    }
}

struct CurrentWiFiNetworkContextMaterial: Equatable, Sendable {
    let interfaceName: String
    fileprivate let routerAddress: UInt32
    fileprivate let networkAddress: UInt32
    fileprivate let netmask: UInt32
}

struct CurrentWiFiNetworkContextSource: Sendable {
    private struct InterfaceAddress: Equatable {
        let address: UInt32
        let netmask: UInt32
    }

    static let system = CurrentWiFiNetworkContextSource()

    func read() -> CurrentWiFiNetworkContextMaterial? {
        guard let route = Self.currentDefaultIPv4Route(),
              Self.isUsableIPv4Host(route.routerAddress) else {
            return nil
        }
        let interfaceName = route.interfaceName
        guard Self.isValidBSDInterfaceName(interfaceName),
              Self.isEnabledWiFiInterface(interfaceName),
              let interfaceAddress = Self.currentIPv4Address(
                  interfaceName: interfaceName
              ),
              Self.isValidNetmask(interfaceAddress.netmask) else {
            return nil
        }

        let networkAddress = interfaceAddress.address & interfaceAddress.netmask
        let broadcastAddress = networkAddress | ~interfaceAddress.netmask
        guard route.routerAddress & interfaceAddress.netmask == networkAddress,
              route.routerAddress != interfaceAddress.address,
              route.routerAddress != networkAddress,
              route.routerAddress != broadcastAddress,
              interfaceAddress.address != networkAddress,
              interfaceAddress.address != broadcastAddress else {
            return nil
        }

        return CurrentWiFiNetworkContextMaterial(
            interfaceName: interfaceName,
            routerAddress: route.routerAddress,
            networkAddress: networkAddress,
            netmask: interfaceAddress.netmask
        )
    }

    private static func currentDefaultIPv4Route() -> (
        interfaceName: String,
        routerAddress: UInt32
    )? {
        guard let store = SCDynamicStoreCreate(
            nil,
            "com.ifixrobots.ReMarkableMirror.wifi-context" as CFString,
            nil,
            nil
        ),
        let value = SCDynamicStoreCopyValue(
            store,
            "State:/Network/Global/IPv4" as CFString
        ) as? [String: Any],
        let interfaceName = value[
            kSCDynamicStorePropNetPrimaryInterface as String
        ] as? String,
        let router = value[kSCPropNetIPv4Router as String] as? String,
        let routerAddress = parseIPv4Address(router) else {
            return nil
        }
        return (interfaceName, routerAddress)
    }

    private static func isEnabledWiFiInterface(_ interfaceName: String) -> Bool {
        guard let preferences = SCPreferencesCreate(
            nil,
            "com.ifixrobots.ReMarkableMirror.wifi-context" as CFString,
            nil
        ),
        let networkSet = SCNetworkSetCopyCurrent(preferences),
        let services = SCNetworkSetCopyServices(networkSet) as? [SCNetworkService] else {
            return false
        }

        return services.contains { service in
            guard SCNetworkServiceGetEnabled(service),
                  let interface = SCNetworkServiceGetInterface(service),
                  SCNetworkInterfaceGetBSDName(interface) as String? == interfaceName,
                  let interfaceType = SCNetworkInterfaceGetInterfaceType(interface) as String?
            else {
                return false
            }
            return interfaceType == (kSCNetworkInterfaceTypeIEEE80211 as String)
        }
    }

    private static func currentIPv4Address(
        interfaceName: String
    ) -> InterfaceAddress? {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return nil }
        defer { freeifaddrs(firstAddress) }

        var result: InterfaceAddress?
        var current: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let entry = current {
            defer { current = entry.pointee.ifa_next }

            guard entry.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET),
                  entry.pointee.ifa_netmask?.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.pointee.ifa_name) == interfaceName,
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.pointee.ifa_flags & UInt32(IFF_RUNNING) != 0,
                  entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else {
                continue
            }

            let address = entry.pointee.ifa_addr!.withMemoryRebound(
                to: sockaddr_in.self,
                capacity: 1
            ) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let netmask = entry.pointee.ifa_netmask!.withMemoryRebound(
                to: sockaddr_in.self,
                capacity: 1
            ) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }

            guard isUsableIPv4Host(address) else { continue }
            let candidate = InterfaceAddress(address: address, netmask: netmask)
            guard result == nil else { return nil }
            result = candidate
        }
        return result
    }

    private static func parseIPv4Address(_ value: String) -> UInt32? {
        var address = in_addr()
        guard value.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else {
            return nil
        }
        return UInt32(bigEndian: address.s_addr)
    }

    private static func isUsableIPv4Host(_ address: UInt32) -> Bool {
        address != 0 &&
            address != UInt32.max &&
            address & 0xff00_0000 != 0x7f00_0000 &&
            address & 0xffff_0000 != 0xa9fe_0000 &&
            address & 0xf000_0000 != 0xe000_0000
    }

    private static func isValidNetmask(_ netmask: UInt32) -> Bool {
        guard netmask != 0 else { return false }
        let hostBits = ~netmask
        return hostBits & (hostBits &+ 1) == 0
    }

    private static func isValidBSDInterfaceName(_ value: String) -> Bool {
        let bytes = value.utf8
        guard !bytes.isEmpty,
              bytes.count < Int(IFNAMSIZ),
              let first = bytes.first,
              Self.isASCIILetter(first) else {
            return false
        }
        return bytes.allSatisfy { Self.isASCIILetter($0) || (48...57).contains($0) }
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte)
    }
}

struct WiFiNetworkContextSecretGenerator: Sendable {
    let generate: @Sendable () throws -> Data

    init(generate: @escaping @Sendable () throws -> Data) {
        self.generate = generate
    }

    static let system = WiFiNetworkContextSecretGenerator {
        var secret = Data(count: WiFiNetworkContextSecretStore.secretByteCount)
        let status = secret.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else {
                return errSecAllocate
            }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw WiFiNetworkContextError.randomGenerationFailed(status)
        }
        return secret
    }
}

actor WiFiNetworkContextSecretStore {
    static let secretByteCount = 32

    private static let service = "com.ifixrobots.ReMarkableMirror.wifi-context-secret"
    private static let account = "installation-v1"

    private let backend: KeychainBackend
    private let generator: WiFiNetworkContextSecretGenerator

    init(
        backend: KeychainBackend = .system,
        generator: WiFiNetworkContextSecretGenerator = .system
    ) {
        self.backend = backend
        self.generator = generator
    }

    func readOrCreate() async throws -> Data {
        switch await backend.read(Self.service, Self.account) {
        case let .found(secret):
            return try Self.validatedStoredSecret(secret)
        case .notFound:
            return try await create()
        case let .failure(status):
            throw Self.mapKeychainFailure(status)
        }
    }

    private func create() async throws -> Data {
        let generated = try generator.generate()
        guard generated.count == Self.secretByteCount else {
            throw WiFiNetworkContextError.invalidGeneratedSecret
        }

        let status = await backend.add(Self.service, Self.account, generated)
        switch status {
        case errSecSuccess:
            return generated
        case errSecDuplicateItem:
            return try await readWinnerOfConcurrentCreation()
        default:
            throw Self.mapKeychainFailure(status)
        }
    }

    private func readWinnerOfConcurrentCreation() async throws -> Data {
        switch await backend.read(Self.service, Self.account) {
        case let .found(secret):
            return try Self.validatedStoredSecret(secret)
        case .notFound:
            throw WiFiNetworkContextError.keychainRaceLost
        case let .failure(status):
            throw Self.mapKeychainFailure(status)
        }
    }

    private static func validatedStoredSecret(_ secret: Data) throws -> Data {
        guard secret.count == secretByteCount else {
            throw WiFiNetworkContextError.invalidStoredSecret
        }
        return secret
    }

    private static func mapKeychainFailure(_ status: OSStatus) -> WiFiNetworkContextError {
        switch status {
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
            .keychainAccessDenied
        default:
            .keychainUnavailable(status)
        }
    }
}

struct WiFiNetworkContextIdentity: Equatable, Sendable {
    let interfaceName: String
    let digest: WiFiNetworkContextDigest
}

struct WiFiNetworkContextMatch: Equatable, Sendable {
    let interfaceName: String
    let isMatch: Bool
}

struct WiFiNetworkContextProvider: Sendable {
    private static let authenticationDomain = Data(
        "com.ifixrobots.ReMarkableMirror.wifi-context/v3\0".utf8
    )

    private let source: CurrentWiFiNetworkContextSource
    private let secretStore: WiFiNetworkContextSecretStore

    init(
        source: CurrentWiFiNetworkContextSource = .system,
        secretStore: WiFiNetworkContextSecretStore = WiFiNetworkContextSecretStore()
    ) {
        self.source = source
        self.secretStore = secretStore
    }

    func currentContext() async throws -> WiFiNetworkContextIdentity {
        let current = try currentMaterial()
        let secret = try await secretStore.readOrCreate()
        try requireCurrentMaterial(current)
        let message = Self.authenticationMessage(for: current)
        let code = HMAC<SHA256>.authenticationCode(
            for: message,
            using: SymmetricKey(data: secret)
        )
        return WiFiNetworkContextIdentity(
            interfaceName: current.interfaceName,
            digest: WiFiNetworkContextDigest(authenticationCode: code)
        )
    }

    func matchCurrentNetwork(storedDigest: String) async throws -> WiFiNetworkContextMatch {
        let expected = try WiFiNetworkContextDigest(storageValue: storedDigest)
        let current = try currentMaterial()
        let secret = try await secretStore.readOrCreate()
        try requireCurrentMaterial(current)
        let message = Self.authenticationMessage(for: current)
        let isMatch = HMAC<SHA256>.isValidAuthenticationCode(
            expected.authenticationCode,
            authenticating: message,
            using: SymmetricKey(data: secret)
        )
        return WiFiNetworkContextMatch(
            interfaceName: current.interfaceName,
            isMatch: isMatch
        )
    }

    private func currentMaterial() throws -> CurrentWiFiNetworkContextMaterial {
        guard let current = source.read() else {
            throw WiFiNetworkContextError.currentNetworkUnavailable
        }
        return current
    }

    private func requireCurrentMaterial(
        _ expected: CurrentWiFiNetworkContextMaterial
    ) throws {
        guard let current = source.read() else {
            throw WiFiNetworkContextError.currentNetworkUnavailable
        }
        guard current == expected else {
            throw WiFiNetworkContextError.currentNetworkChanged
        }
    }

    private static func authenticationMessage(
        for current: CurrentWiFiNetworkContextMaterial
    ) -> Data {
        var message = Self.authenticationDomain
        let interfaceBytes = Data(current.interfaceName.utf8)
        message.append(UInt8(interfaceBytes.count))
        message.append(interfaceBytes)
        appendNetworkUInt32(current.routerAddress, to: &message)
        appendNetworkUInt32(current.networkAddress, to: &message)
        appendNetworkUInt32(current.netmask, to: &message)
        return message
    }

    private static func appendNetworkUInt32(_ value: UInt32, to data: inout Data) {
        var networkValue = value.bigEndian
        withUnsafeBytes(of: &networkValue) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}
