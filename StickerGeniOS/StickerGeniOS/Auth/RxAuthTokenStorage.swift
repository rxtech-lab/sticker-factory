import Foundation
import RxAuthSwift

/// Bridges RxAuthSwift's ordered storage callbacks into one atomic Keychain
/// replacement. RxAuth v1.2.0 calls access -> optional refresh -> optional
/// expiry; the old bundle remains visible to the Messages extension until the
/// staged rotation is complete.
nonisolated final class RxAuthSharedTokenStorage: TokenStorageProtocol, @unchecked Sendable {
    private let vault: SharedTokenVaultProtocol
    private let processLockURL: URL?
    private let lock = NSLock()
    private var staged: SharedTokenBundle?
    private var stagedAccountChange = false

    init(vault: SharedTokenVaultProtocol, processLockURL: URL? = SharedTokenBroker.defaultLockURL()) {
        self.vault = vault
        self.processLockURL = processLockURL
    }

    func saveAccessToken(_ token: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let current = try vault.load()
        let subject = JWTClaims.subject(in: token)
        let sameAccount = current?.subject != nil && current?.subject == subject
        stagedAccountChange = current?.subject != nil && current?.subject != subject
        staged = .init(
            accessToken: token,
            refreshToken: sameAccount ? current?.refreshToken : nil,
            idToken: sameAccount ? current?.idToken : nil,
            expiresAt: JWTClaims.expiration(in: token) ?? .distantPast,
            subject: subject
        )
    }

    func getAccessToken() -> String? {
        lock.lock()
        defer { lock.unlock() }
        // If the provider omitted expires_in, saveTokens has returned by the
        // time it asks for the token to fetch user info. A JWT exp claim lets
        // us commit the fully staged access/refresh pair here.
        if let staged, staged.expiresAt != .distantPast {
            try? commit(staged)
            self.staged = nil
            stagedAccountChange = false
            return staged.accessToken
        }
        return staged?.accessToken ?? (try? vault.load()?.accessToken)
    }

    func deleteAccessToken() throws {
        lock.lock()
        defer { lock.unlock() }
        var bundle = staged
        if bundle == nil { bundle = try vault.load() }
        bundle?.accessToken = ""
        bundle?.expiresAt = .distantPast
        if let bundle { try vault.replace(with: bundle) }
        staged = nil
    }

    func saveRefreshToken(_ token: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if staged == nil { staged = try vault.load() }
        staged?.refreshToken = token
    }

    func getRefreshToken() -> String? {
        // Deliberately hidden from OAuthManager. Its private five-minute timer
        // otherwise rotates outside the App Group flock. SharedTokenBroker is
        // the only refresh-token consumer in both processes.
        nil
    }

    func deleteRefreshToken() throws {
        lock.lock()
        defer { lock.unlock() }
        var bundle = staged
        if bundle == nil { bundle = try vault.load() }
        bundle?.refreshToken = nil
        if let bundle { try vault.replace(with: bundle) }
        staged = nil
    }

    func saveExpiresAt(_ date: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        var candidate = staged
        if candidate == nil { candidate = try vault.load() }
        guard var bundle = candidate else { return }
        bundle.expiresAt = date
        try commit(bundle)
        staged = nil
        stagedAccountChange = false
    }

    func getExpiresAt() -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return staged?.expiresAt ?? (try? vault.load()?.expiresAt)
    }

    func isTokenExpired() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (staged ?? (try? vault.load()))?.expires(within: 0) ?? true
    }

    func clearAll() throws {
        lock.lock()
        defer { lock.unlock() }
        staged = nil
        stagedAccountChange = false
        guard let processLockURL else { throw TokenBrokerError.lockUnavailable }
        let processLock = try AppGroupProcessLock(url: processLockURL)
        try processLock.lock()
        defer { processLock.unlock() }
        _ = try vault.load()
        try vault.clear()
    }

    private func commit(_ bundle: SharedTokenBundle) throws {
        guard let processLockURL else { throw TokenBrokerError.lockUnavailable }
        let processLock = try AppGroupProcessLock(url: processLockURL)
        try processLock.lock()
        defer { processLock.unlock() }
        if stagedAccountChange { SharedLogoutPurger.purge() }
        try vault.replace(with: bundle)
    }
}
