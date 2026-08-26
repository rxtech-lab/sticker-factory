import Foundation
import Security

nonisolated struct SharedTokenBundle: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var expiresAt: Date
    var subject: String?

    var isUsable: Bool { !accessToken.isEmpty && expiresAt > Date() }
    func expires(within interval: TimeInterval, now: Date = Date()) -> Bool {
        expiresAt <= now.addingTimeInterval(interval)
    }
}

nonisolated protocol SharedTokenVaultProtocol: Sendable {
    func load() throws -> SharedTokenBundle?
    func replace(with bundle: SharedTokenBundle) throws
    func clear() throws
}

nonisolated enum TokenVaultError: Error, LocalizedError {
    case keychain(OSStatus)
    case invalidPayload
    case missingSharedAccessGroup

    var errorDescription: String? {
        switch self {
        case .keychain(let status): "The secure token store failed (\(status))."
        case .invalidPayload: "The secure token bundle is invalid."
        case .missingSharedAccessGroup: "The shared Keychain access group is not configured."
        }
    }
}

nonisolated final class SharedKeychainTokenVault: SharedTokenVaultProtocol, @unchecked Sendable {
    private let service: String
    private let account: String
    private let accessGroup: String?
    private let allowUnsharedFallback: Bool
    private let lock = NSLock()

    init(
        service: String = AppConfiguration.keychainService,
        account: String = AppConfiguration.keychainAccount,
        accessGroup: String? = SharedKeychainTokenVault.configuredAccessGroup(),
        allowUnsharedFallback: Bool = AppConfiguration.allowsInsecureSharedStorage
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
        self.allowUnsharedFallback = allowUnsharedFallback
    }

    func load() throws -> SharedTokenBundle? {
        try validateConfiguration()
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked()
    }

    func replace(with bundle: SharedTokenBundle) throws {
        try validateConfiguration()
        lock.lock()
        defer { lock.unlock() }
        try replaceUnlocked(with: bundle)
    }

    func clear() throws {
        try validateConfiguration()
        lock.lock()
        defer { lock.unlock() }
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenVaultError.keychain(status)
        }
    }

    /// Mutates and replaces the one encrypted JSON item while holding a
    /// process-local lock. Cross-process token rotation is coordinated by
    /// `SharedTokenBroker`'s App Group file lock.
    func update(_ transform: (inout SharedTokenBundle?) throws -> Void) throws {
        try validateConfiguration()
        lock.lock()
        defer { lock.unlock() }
        var value = try loadUnlocked()
        try transform(&value)
        if let value {
            try replaceUnlocked(with: value)
        } else {
            let status = SecItemDelete(baseQuery() as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw TokenVaultError.keychain(status)
            }
        }
    }

    private func loadUnlocked() throws -> SharedTokenBundle? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw TokenVaultError.keychain(status)
        }
        return try TokenBundleCodec.decode(data)
    }

    private func replaceUnlocked(with bundle: SharedTokenBundle) throws {
        let data = try TokenBundleCodec.encode(bundle)
        let query = baseQuery()
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insertion = query
            insertion[kSecValueData as String] = data
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let insertionStatus = SecItemAdd(insertion as CFDictionary, nil)
            guard insertionStatus == errSecSuccess else { throw TokenVaultError.keychain(insertionStatus) }
        } else if updateStatus != errSecSuccess {
            throw TokenVaultError.keychain(updateStatus)
        }
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    private func validateConfiguration() throws {
        guard accessGroup != nil || allowUnsharedFallback else {
            throw TokenVaultError.missingSharedAccessGroup
        }
    }

    private static func configuredAccessGroup(bundle: Bundle = .main) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: AppConfiguration.keychainAccessGroupInfoKey) as? String,
              !value.isEmpty,
              !value.contains("$(")
        else { return nil }
        return value
    }
}

nonisolated enum TokenBundleCodec {
    static func encode(_ bundle: SharedTokenBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(bundle)
    }

    static func decode(_ data: Data) throws -> SharedTokenBundle {
        let isoDecoder = JSONDecoder()
        isoDecoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let wholeSeconds = ISO8601DateFormatter()
            wholeSeconds.formatOptions = [.withInternetDateTime]
            if let date = wholeSeconds.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "expiresAt is not a supported ISO-8601 value"
            )
        }
        if let decoded = try? isoDecoder.decode(SharedTokenBundle.self, from: data) { return decoded }

        let secondsDecoder = JSONDecoder()
        secondsDecoder.dateDecodingStrategy = .secondsSince1970
        if let decoded = try? secondsDecoder.decode(SharedTokenBundle.self, from: data) { return decoded }

        let referenceDecoder = JSONDecoder()
        referenceDecoder.dateDecodingStrategy = .deferredToDate
        guard let decoded = try? referenceDecoder.decode(SharedTokenBundle.self, from: data) else {
            throw TokenVaultError.invalidPayload
        }
        return decoded
    }
}

nonisolated enum JWTClaims {
    static func subject(in token: String) -> String? {
        payload(in: token)?["sub"] as? String
    }

    static func expiration(in token: String) -> Date? {
        guard let seconds = payload(in: token)?["exp"] as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func payload(in token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
