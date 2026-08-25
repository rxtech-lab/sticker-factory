import Darwin
import Foundation

nonisolated struct OAuthRefreshResponse: Decodable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var expiresIn: TimeInterval

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
    }
}

nonisolated protocol OAuthRefreshTransport: Sendable {
    func refresh(tokenURL: URL, clientID: String, refreshToken: String) async throws -> OAuthRefreshResponse
}

nonisolated struct URLSessionOAuthRefreshTransport: OAuthRefreshTransport {
    let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func refresh(tokenURL: URL, clientID: String, refreshToken: String) async throws -> OAuthRefreshResponse {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID),
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw TokenBrokerError.transientRefresh(nil) }
        guard response.statusCode == 200 else {
            if response.statusCode == 400 || response.statusCode == 401 {
                throw TokenBrokerError.refreshRejected(response.statusCode)
            }
            throw TokenBrokerError.transientRefresh(response.statusCode)
        }
        return try JSONDecoder().decode(OAuthRefreshResponse.self, from: data)
    }
}

nonisolated enum TokenBrokerError: Error, LocalizedError, Equatable {
    case missingSession
    case refreshRejected(Int?)
    case transientRefresh(Int?)
    case lockUnavailable

    var errorDescription: String? {
        switch self {
        case .missingSession: "Please open Sticker Factory and sign in again."
        case .refreshRejected: "Your session expired. Please sign in again."
        case .transientRefresh: "The authentication service is temporarily unavailable."
        case .lockUnavailable: "The shared session is temporarily unavailable."
        }
    }
}

actor SharedTokenBroker {
    private let vault: SharedTokenVaultProtocol
    private let transport: OAuthRefreshTransport
    private let tokenURL: URL
    private let clientID: String
    private let lockURL: URL?
    private let expiryLeeway: TimeInterval
    private var refreshTask: Task<String, Error>?
    private var isLoggingOut = false
    private var sessionEpoch: UInt64 = 0

    init(
        vault: SharedTokenVaultProtocol,
        transport: OAuthRefreshTransport,
        tokenURL: URL,
        clientID: String,
        lockURL: URL? = SharedTokenBroker.defaultLockURL(),
        expiryLeeway: TimeInterval = 90
    ) {
        self.vault = vault
        self.transport = transport
        self.tokenURL = tokenURL
        self.clientID = clientID
        self.lockURL = lockURL
        self.expiryLeeway = expiryLeeway
    }

    func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        guard !isLoggingOut else { throw TokenBrokerError.missingSession }
        let startingEpoch = sessionEpoch
        if !forceRefresh, let bundle = try vault.load(), !bundle.expires(within: expiryLeeway) {
            return bundle.accessToken
        }
        if let refreshTask {
            let token = try await refreshTask.value
            guard !isLoggingOut, sessionEpoch == startingEpoch else { throw TokenBrokerError.missingSession }
            return token
        }

        // Run the cross-process critical section outside actor isolation. A
        // second caller can then observe and await `refreshTask` instead of
        // blocking this actor on flock while the first network turn is awake.
        let vault = self.vault
        let transport = self.transport
        let tokenURL = self.tokenURL
        let clientID = self.clientID
        guard let lockURL = self.lockURL else { throw TokenBrokerError.lockUnavailable }
        let expiryLeeway = self.expiryLeeway
        let task = Task.detached(priority: nil) {
            let processLock = try AppGroupProcessLock(url: lockURL)
            try processLock.lock()
            defer { processLock.unlock() }

            // The extension may have rotated while this process waited.
            if !forceRefresh, let current = try vault.load(), !current.expires(within: expiryLeeway) {
                return current.accessToken
            }
            guard let current = try vault.load(), let refreshToken = current.refreshToken, !refreshToken.isEmpty else {
                throw TokenBrokerError.missingSession
            }
            do {
                let response = try await transport.refresh(tokenURL: tokenURL, clientID: clientID, refreshToken: refreshToken)
                let replacement = SharedTokenBundle(
                    accessToken: response.accessToken,
                    refreshToken: response.refreshToken ?? current.refreshToken,
                    idToken: response.idToken ?? current.idToken,
                    expiresAt: Date().addingTimeInterval(max(30, response.expiresIn)),
                    subject: JWTClaims.subject(in: response.accessToken) ?? current.subject
                )
                try vault.replace(with: replacement)
                return replacement.accessToken
            } catch {
                if case TokenBrokerError.refreshRejected = error {
                    try? vault.clear()
                    NotificationCenter.default.post(name: Notification.Name("rxAuthSessionExpired"), object: nil)
                }
                throw error
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        let token = try await task.value
        guard !isLoggingOut, sessionEpoch == startingEpoch else { throw TokenBrokerError.missingSession }
        return token
    }

    func currentBundle() throws -> SharedTokenBundle? { try vault.load() }
    func logout() async throws {
        guard !isLoggingOut else { return }
        isLoggingOut = true
        sessionEpoch &+= 1
        defer { isLoggingOut = false }
        if let refreshTask { _ = try? await refreshTask.value }
        guard let lockURL else { throw TokenBrokerError.lockUnavailable }
        let vault = self.vault
        try await Task.detached {
            let lock = try AppGroupProcessLock(url: lockURL)
            try lock.lock()
            defer { lock.unlock() }
            // Re-read while holding the cross-process lock so an extension
            // refresh that started before logout cannot resurrect credentials.
            _ = try vault.load()
            try vault.clear()
        }.value
    }

    static func defaultLockURL(
        fileManager: FileManager = .default,
        allowTemporaryFallback: Bool = AppConfiguration.allowsInsecureSharedStorage
    ) -> URL? {
        lockURL(
            containerURL: fileManager.containerURL(forSecurityApplicationGroupIdentifier: AppConfiguration.appGroupIdentifier),
            temporaryDirectory: fileManager.temporaryDirectory,
            allowTemporaryFallback: allowTemporaryFallback
        )
    }

    static func lockURL(containerURL: URL?, temporaryDirectory: URL, allowTemporaryFallback: Bool) -> URL? {
        if let containerURL { return containerURL.appending(path: AppConfiguration.refreshLockFilename) }
        guard allowTemporaryFallback else { return nil }
        return temporaryDirectory.appending(path: "sticker-factory-\(AppConfiguration.refreshLockFilename)")
    }
}

nonisolated final class AppGroupProcessLock: @unchecked Sendable {
    private let descriptor: Int32
    private var isLocked = false

    init(url: URL) throws {
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw TokenBrokerError.lockUnavailable }
        self.descriptor = descriptor
    }

    deinit { Darwin.close(descriptor) }

    func lock() throws {
        guard flock(descriptor, LOCK_EX) == 0 else { throw TokenBrokerError.lockUnavailable }
        isLocked = true
    }

    func unlock() {
        if isLocked { flock(descriptor, LOCK_UN) }
        isLocked = false
    }
}
