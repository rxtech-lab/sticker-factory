import Darwin
import Foundation
import Security

/// The extension deliberately does not link RxAuthSwift. The main application owns
/// interactive Authorization Code + PKCE sign-in and writes this portable bundle.
struct SharedTokenBundle: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresAt: Date
    let subject: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken
        case refreshToken
        case idToken
        case expiresAt
        case subject
    }

    init(
        accessToken: String,
        refreshToken: String?,
        idToken: String?,
        expiresAt: Date,
        subject: String?
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresAt = expiresAt
        self.subject = subject
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        idToken = try container.decodeIfPresent(String.self, forKey: .idToken)
        subject = try container.decodeIfPresent(String.self, forKey: .subject)

        if let value = try? container.decode(Double.self, forKey: .expiresAt) {
            // Values above year 2001's Unix timestamp are Unix seconds; smaller
            // values are Foundation's seconds-since-reference-date representation.
            expiresAt = value > 978_307_200
                ? Date(timeIntervalSince1970: value)
                : Date(timeIntervalSinceReferenceDate: value)
        } else {
            let value = try container.decode(String.self, forKey: .expiresAt)
            let date = Self.iso8601Formatter(fractionalSeconds: true).date(from: value)
                ?? Self.iso8601Formatter(fractionalSeconds: false).date(from: value)
            guard let date else {
                throw DecodingError.dataCorruptedError(
                    forKey: .expiresAt,
                    in: container,
                    debugDescription: "expiresAt must be an ISO-8601 date or numeric timestamp"
                )
            }
            expiresAt = date
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accessToken, forKey: .accessToken)
        try container.encodeIfPresent(refreshToken, forKey: .refreshToken)
        try container.encodeIfPresent(idToken, forKey: .idToken)
        // Match JSONEncoder.DateEncodingStrategy.iso8601 used by the main app.
        // Fractional seconds are intentionally omitted for bidirectional decoding.
        try container.encode(Self.iso8601Formatter(fractionalSeconds: false).string(from: expiresAt), forKey: .expiresAt)
        try container.encodeIfPresent(subject, forKey: .subject)
    }

    var resolvedSubject: String? {
        subject ?? JWTClaims.decode(accessToken)?.subject
    }

    private static func iso8601Formatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }
}

struct AuthenticatedSession: Sendable {
    let accessToken: String
    let subject: String
}

enum SharedAuthenticationError: Error, LocalizedError, Sendable {
    case invalidConfiguration(String)
    case keychain(OSStatus)
    case missingCredentials
    case refreshUnavailable
    case refreshRejected
    case invalidRefreshResponse
    case appGroupUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let key):
            String(localized: "Sticker Factory is missing the \(key) configuration value.")
        case .keychain(let status):
            String(localized: "Shared credentials could not be read (Keychain status \(status)).")
        case .missingCredentials:
            String(localized: "Open Sticker Factory and sign in to use your stickers.")
        case .refreshUnavailable:
            String(localized: "Your sign-in has expired. Open Sticker Factory to sign in again.")
        case .refreshRejected:
            String(localized: "Your sign-in was revoked. Open Sticker Factory to sign in again.")
        case .invalidRefreshResponse:
            String(localized: "The authentication server returned an invalid token response.")
        case .appGroupUnavailable:
            String(localized: "The shared Sticker Factory container is unavailable.")
        }
    }
}

struct SharedAuthConfiguration: Sendable {
    static let appGroupIdentifier = "group.app.rxlab.stickerfactory"
    static let keychainService = "app.rxlab.sticker-factory.oauth"
    static let keychainAccount = "oauth-token-bundle"
    static let refreshLockFilename = "oauth-refresh.lock"

    let tokenURL: URL
    let clientID: String
    let accessGroup: String

    init(bundle: Bundle = .main) throws {
        tokenURL = try Self.requiredURL(named: "StickerFactoryAuthTokenURL", in: bundle)
        clientID = try Self.requiredString(named: "StickerFactoryIOSClientID", in: bundle)
        accessGroup = try Self.requiredString(named: "StickerFactoryKeychainAccessGroup", in: bundle)
    }

    init(tokenURL: URL, clientID: String, accessGroup: String) {
        self.tokenURL = tokenURL
        self.clientID = clientID
        self.accessGroup = accessGroup
    }

    private static func requiredString(named key: String, in bundle: Bundle) throws -> String {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.contains("$("),
              !value.hasPrefix("CONFIGURE_") else {
            throw SharedAuthenticationError.invalidConfiguration(key)
        }
        return value
    }

    private static func requiredURL(named key: String, in bundle: Bundle) throws -> URL {
        let value = try requiredString(named: key, in: bundle)
        guard let url = URL(string: value), url.scheme == "https" else {
            throw SharedAuthenticationError.invalidConfiguration(key)
        }
        return url
    }
}

protocol SharedTokenStorageProtocol: Sendable {
    func read() throws -> SharedTokenBundle?
    func replace(with bundle: SharedTokenBundle) throws
    func delete() throws
}

struct SharedKeychainTokenStorage: SharedTokenStorageProtocol, @unchecked Sendable {
    private let service: String
    private let account: String
    private let accessGroup: String

    init(
        service: String = SharedAuthConfiguration.keychainService,
        account: String = SharedAuthConfiguration.keychainAccount,
        accessGroup: String
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    func read() throws -> SharedTokenBundle? {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SharedAuthenticationError.keychain(status)
        }
        return try JSONDecoder().decode(SharedTokenBundle.self, from: data)
    }

    /// `SecItemUpdate` replaces the value in one Keychain transaction. The
    /// surrounding App Group file lock serializes refresh-token rotation across
    /// the application and Messages extension processes.
    func replace(with bundle: SharedTokenBundle) throws {
        let data = try JSONEncoder().encode(bundle)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw SharedAuthenticationError.keychain(updateStatus)
        }

        var addQuery = baseQuery
        attributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SharedAuthenticationError.keychain(addStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SharedAuthenticationError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}

protocol SharedOAuthRefreshTransport: Sendable {
    func refresh(tokenURL: URL, clientID: String, refreshToken: String) async throws -> RefreshTokenResponse
}

struct URLSessionSharedOAuthRefreshTransport: SharedOAuthRefreshTransport {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func refresh(tokenURL: URL, clientID: String, refreshToken: String) async throws -> RefreshTokenResponse {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID),
        ]

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SharedAuthenticationError.invalidRefreshResponse
        }
        if httpResponse.statusCode == 400 || httpResponse.statusCode == 401 {
            throw SharedAuthenticationError.refreshRejected
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw SharedAuthenticationError.invalidRefreshResponse
        }
        do {
            let payload = try JSONDecoder().decode(RefreshTokenResponse.self, from: data)
            guard !payload.accessToken.isEmpty else { throw SharedAuthenticationError.invalidRefreshResponse }
            return payload
        } catch let error as SharedAuthenticationError {
            throw error
        } catch {
            throw SharedAuthenticationError.invalidRefreshResponse
        }
    }
}

actor SharedTokenBroker {
    private let configuration: SharedAuthConfiguration
    private let storage: any SharedTokenStorageProtocol
    private let transport: any SharedOAuthRefreshTransport
    private let now: @Sendable () -> Date
    private let lockURL: URL?
    private var refreshTask: Task<AuthenticatedSession, Error>?
    private var isClearingCredentials = false
    private var sessionEpoch: UInt64 = 0

    init(
        configuration: SharedAuthConfiguration,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        storage = SharedKeychainTokenStorage(accessGroup: configuration.accessGroup)
        transport = URLSessionSharedOAuthRefreshTransport(session: session)
        self.now = now
        lockURL = Self.defaultLockURL()
    }

    init(
        configuration: SharedAuthConfiguration,
        storage: any SharedTokenStorageProtocol,
        transport: any SharedOAuthRefreshTransport,
        now: @escaping @Sendable () -> Date = Date.init,
        lockURL: URL
    ) {
        self.configuration = configuration
        self.storage = storage
        self.transport = transport
        self.now = now
        self.lockURL = lockURL
    }

    func authenticatedSession(forceRefresh: Bool = false) async throws -> AuthenticatedSession {
        guard !isClearingCredentials else { throw SharedAuthenticationError.missingCredentials }
        let startingEpoch = sessionEpoch
        guard let bundle = try storage.read() else {
            throw SharedAuthenticationError.missingCredentials
        }
        if !forceRefresh, Self.isUsable(bundle, now: now()) {
            return try Self.session(from: bundle)
        }
        if let refreshTask {
            let refreshed = try await refreshTask.value
            guard !isClearingCredentials, sessionEpoch == startingEpoch else {
                throw SharedAuthenticationError.missingCredentials
            }
            return refreshed
        }

        guard let lockURL else { throw SharedAuthenticationError.appGroupUnavailable }
        let configuration = self.configuration
        let storage = self.storage
        let transport = self.transport
        let now = self.now
        let task = Task.detached {
            try await Self.rotate(
                forceRefresh: forceRefresh,
                configuration: configuration,
                storage: storage,
                transport: transport,
                now: now,
                lockURL: lockURL
            )
        }
        refreshTask = task
        defer { refreshTask = nil }
        let refreshed = try await task.value
        guard !isClearingCredentials, sessionEpoch == startingEpoch else {
            throw SharedAuthenticationError.missingCredentials
        }
        return refreshed
    }

    func clearCredentials() async throws {
        guard !isClearingCredentials else { return }
        isClearingCredentials = true
        sessionEpoch &+= 1
        defer { isClearingCredentials = false }
        if let refreshTask { _ = try? await refreshTask.value }
        guard let lockURL else { throw SharedAuthenticationError.appGroupUnavailable }
        let storage = self.storage
        try await Task.detached {
            try Self.withInterprocessLock(at: lockURL) {
                _ = try storage.read()
                try storage.delete()
            }
        }.value
    }

    /// Returns identity context for an offline cache lookup without asserting
    /// that the access token is currently valid. Never use this token on a
    /// network request.
    func cachedSession() throws -> AuthenticatedSession? {
        guard let bundle = try storage.read() else { return nil }
        return try Self.session(from: bundle)
    }

    private nonisolated static func rotate(
        forceRefresh: Bool,
        configuration: SharedAuthConfiguration,
        storage: any SharedTokenStorageProtocol,
        transport: any SharedOAuthRefreshTransport,
        now: @escaping @Sendable () -> Date,
        lockURL: URL
    ) async throws -> AuthenticatedSession {
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw SharedAuthenticationError.appGroupUnavailable
        }
        defer { close(descriptor) }

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw SharedAuthenticationError.appGroupUnavailable
        }
        defer { flock(descriptor, LOCK_UN) }

        // Another process may have completed rotation while this one waited.
        guard let latest = try storage.read() else {
            throw SharedAuthenticationError.missingCredentials
        }
        if !forceRefresh, isUsable(latest, now: now()) {
            return try session(from: latest)
        }
        guard let refreshToken = latest.refreshToken, !refreshToken.isEmpty else {
            throw SharedAuthenticationError.refreshUnavailable
        }

        let payload: RefreshTokenResponse
        do {
            payload = try await transport.refresh(
                tokenURL: configuration.tokenURL,
                clientID: configuration.clientID,
                refreshToken: refreshToken
            )
        } catch SharedAuthenticationError.refreshRejected {
            try storage.delete()
            throw SharedAuthenticationError.refreshRejected
        } catch {
            throw error
        }

        let expiration = payload.expiresIn.map { now().addingTimeInterval($0) }
            ?? JWTClaims.decode(payload.accessToken)?.expiration
            ?? now().addingTimeInterval(300)
        let rotated = SharedTokenBundle(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken ?? latest.refreshToken,
            idToken: payload.idToken ?? latest.idToken,
            expiresAt: expiration,
            subject: JWTClaims.decode(payload.accessToken)?.subject ?? latest.resolvedSubject
        )
        try storage.replace(with: rotated)
        return try session(from: rotated)
    }

    private nonisolated static func defaultLockURL(fileManager: FileManager = .default) -> URL? {
        guard let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: SharedAuthConfiguration.appGroupIdentifier
        ) else { return nil }
        try? fileManager.createDirectory(at: containerURL, withIntermediateDirectories: true)
        return containerURL.appending(path: SharedAuthConfiguration.refreshLockFilename)
    }

    private nonisolated static func withInterprocessLock(
        at lockURL: URL,
        operation: () throws -> Void
    ) throws {
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SharedAuthenticationError.appGroupUnavailable }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw SharedAuthenticationError.appGroupUnavailable }
        defer { flock(descriptor, LOCK_UN) }
        try operation()
    }

    private nonisolated static func isUsable(_ bundle: SharedTokenBundle, now: Date) -> Bool {
        bundle.expiresAt.timeIntervalSince(now) > 60
    }

    private nonisolated static func session(from bundle: SharedTokenBundle) throws -> AuthenticatedSession {
        guard let subject = bundle.resolvedSubject, !subject.isEmpty else {
            throw SharedAuthenticationError.invalidRefreshResponse
        }
        return AuthenticatedSession(accessToken: bundle.accessToken, subject: subject)
    }
}

struct RefreshTokenResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresIn: TimeInterval?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
    }
}

private struct JWTClaims: Decodable, Sendable {
    let subject: String?
    let expirationSeconds: TimeInterval?

    private enum CodingKeys: String, CodingKey {
        case subject = "sub"
        case expirationSeconds = "exp"
    }

    var expiration: Date? {
        expirationSeconds.map(Date.init(timeIntervalSince1970:))
    }

    static func decode(_ token: String) -> JWTClaims? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var value = String(segments[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value) else { return nil }
        return try? JSONDecoder().decode(JWTClaims.self, from: data)
    }
}
