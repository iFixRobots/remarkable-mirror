import Foundation
import LocalAuthentication
import Security

enum KeychainReadResult: Equatable, Sendable {
    case found(Data)
    case notFound
    case failure(OSStatus)
}

struct KeychainBackend: Sendable {
    let read: @Sendable (_ service: String, _ account: String) async -> KeychainReadResult
    let add: @Sendable (_ service: String, _ account: String, _ data: Data) async -> OSStatus
    let update: @Sendable (_ service: String, _ account: String, _ data: Data) async -> OSStatus
    let delete: @Sendable (_ service: String, _ account: String) async -> OSStatus
    let deleteAll: @Sendable (_ service: String) async -> OSStatus

    init(
        read: @escaping @Sendable (
            _ service: String,
            _ account: String
        ) async -> KeychainReadResult,
        add: @escaping @Sendable (
            _ service: String,
            _ account: String,
            _ data: Data
        ) async -> OSStatus,
        update: @escaping @Sendable (
            _ service: String,
            _ account: String,
            _ data: Data
        ) async -> OSStatus,
        delete: @escaping @Sendable (
            _ service: String,
            _ account: String
        ) async -> OSStatus,
        deleteAll: @escaping @Sendable (
            _ service: String
        ) async -> OSStatus = { _ in errSecUnimplemented }
    ) {
        self.read = read
        self.add = add
        self.update = update
        self.delete = delete
        self.deleteAll = deleteAll
    }

    static let system = KeychainBackend(
        read: { service, account in
            var query = noninteractiveQuery(service: service, account: account)
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                guard let data = item as? Data else { return .failure(errSecDecode) }
                return .found(data)
            case errSecItemNotFound:
                return .notFound
            default:
                return .failure(status)
            }
        },
        add: { service, account, data in
            var query = noninteractiveQuery(service: service, account: account)
            query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            query[kSecValueData] = data
            return SecItemAdd(query as CFDictionary, nil)
        },
        update: { service, account, data in
            let query = noninteractiveQuery(service: service, account: account)
            let attributes: [CFString: Any] = [
                kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                kSecValueData: data,
            ]
            return SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        },
        delete: { service, account in
            SecItemDelete(
                noninteractiveQuery(
                    service: service,
                    account: account
                ) as CFDictionary
            )
        },
        deleteAll: { service in
            var query = serviceQuery(service: service)
            query[kSecUseAuthenticationContext] = noninteractiveContext()
            return SecItemDelete(query as CFDictionary)
        }
    )

    private static func noninteractiveQuery(
        service: String,
        account: String
    ) -> [CFString: Any] {
        var query = baseQuery(service: service, account: account)
        query[kSecUseAuthenticationContext] = noninteractiveContext()
        return query
    }

    private static func noninteractiveContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    private static func baseQuery(service: String, account: String) -> [CFString: Any] {
        var query = serviceQuery(service: service)
        query[kSecAttrAccount] = account
        return query
    }

    private static func serviceQuery(service: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrSynchronizable: false,
            kSecAttrService: service,
            kSecUseDataProtectionKeychain: true,
        ]
    }
}

enum KeychainSecretStoreError: Error, Equatable, Sendable {
    case invalidToken
    case notFound
    case accessDenied
    case unavailable(OSStatus)
}

actor KeychainSecretStore {
    private static let wakeTokenService = "com.ifixrobots.ReMarkableMirror.wake-token"
    private let backend: KeychainBackend

    init(backend: KeychainBackend = .system) {
        self.backend = backend
    }

    func storeWakeToken(_ token: Data, profileID: UUID) async throws {
        guard Self.isValidWakeToken(token) else {
            throw KeychainSecretStoreError.invalidToken
        }
        let account = profileID.uuidString
        let updateStatus = await backend.update(Self.wakeTokenService, account, token)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            let addStatus = await backend.add(Self.wakeTokenService, account, token)
            if addStatus == errSecSuccess { return }
            if addStatus == errSecDuplicateItem {
                let retryStatus = await backend.update(Self.wakeTokenService, account, token)
                guard retryStatus == errSecSuccess else { throw Self.map(retryStatus) }
                return
            }
            throw Self.map(addStatus)
        default:
            throw Self.map(updateStatus)
        }
    }

    func readWakeToken(profileID: UUID) async throws -> Data {
        switch await backend.read(Self.wakeTokenService, profileID.uuidString) {
        case let .found(data):
            guard Self.isValidWakeToken(data) else {
                throw KeychainSecretStoreError.invalidToken
            }
            return data
        case .notFound:
            throw KeychainSecretStoreError.notFound
        case let .failure(status):
            throw Self.map(status)
        }
    }

    func deleteWakeToken(profileID: UUID) async throws {
        let status = await backend.delete(Self.wakeTokenService, profileID.uuidString)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.map(status)
        }
    }

    /// Removes every wake token owned by this app. This is intentionally
    /// service-scoped so an explicit local reset can also clean credentials
    /// whose profile file is missing or corrupt.
    func deleteAllWakeTokens() async throws {
        let status = await backend.deleteAll(Self.wakeTokenService)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.map(status)
        }
    }

    private static func isValidWakeToken(_ data: Data) -> Bool {
        data.count == 64 && data.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }

    private static func map(_ status: OSStatus) -> KeychainSecretStoreError {
        switch status {
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
            .accessDenied
        default:
            .unavailable(status)
        }
    }
}
