import RxAuthSwift
import Observation
import Security
import SwiftUI

/// Uses the main app's OAuth configuration, with Clip-local credential storage.
@MainActor @Observable
final class ClipAuthentication {
    private(set) var signedIn = false
    private(set) var signInManager: OAuthManager?
    private let nativeTokens = ClipNativeTokenStorage()
    var error: String?
    private var credentials: Credentials?
    private var refreshTask: Task<String, Error>?
    private var issuer: String { configuredValue("StickerFactoryOAuthIssuer").trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    private var redirect: String { configuredValue("StickerFactoryOAuthRedirectURI") }
    private var clientID: String { configuredValue("StickerFactoryIOSClientID") }
    private var tokenURL: URL? { URL(string: configuredValue("StickerFactoryAuthTokenURL")) }
    private func configuredValue(_ key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.contains("$("), !value.hasPrefix("CONFIGURE_") else { return "" }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private struct Credentials: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date
    }
    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double
    }
    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            if ProcessInfo.processInfo.arguments.contains("--clip-signed-in") {
                signedIn = true
            }
            return
        }
        #endif
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, let saved = try? JSONDecoder().decode(Credentials.self, from: data) {
            credentials = saved; signedIn = true
        }
    }
    func prepareSignIn() -> Bool {
        guard !clientID.isEmpty, URL(string: issuer)?.scheme == "https",
              tokenURL?.scheme == "https", URL(string: redirect)?.scheme != nil else {
            error = "Quick mode sign-in is not configured in this build."
            return false
        }
        error = nil
        try? nativeTokens.clearAll()
        signInManager = OAuthManager(configuration: .init(
            issuer: issuer,
            clientID: clientID,
            redirectURI: redirect,
            scopes: ["openid"],
            tokenPath: tokenURL!.path,
            passkeyChallengePath: "/api/oauth/passkey/authenticate/options",
            passkeyVerificationPath: "/api/oauth/passkey/authenticate/verify",
            passkeyRegistrationChallengePath: "/api/oauth/passkey/register/options",
            passkeyRegistrationVerificationPath: "/api/oauth/passkey/register/verify",
            passkeyUpgradeChallengePath: "/api/oauth/passkey/upgrade/options",
            passkeyUpgradeVerificationPath: "/api/oauth/passkey/upgrade/verify",
            passkeyAccountCreationOptionsPath: "/api/oauth/passkey/account-creation/options",
            passkeyAccountCreationVerifyPath: "/api/oauth/passkey/account-creation/verify",
            passkeyRelyingPartyIdentifier: "rxlab.app",
            keychainServiceName: "app.rxlab.stickerfactory.Clip.oauth"
        ), tokenStorage: nativeTokens)
        return true
    }

    func completeNativeSignIn() {
        do {
            guard let accessToken = nativeTokens.getAccessToken(),
                  let expiresAt = nativeTokens.getExpiresAt() else {
                throw MessagesStickerCreationError.unauthorized
            }
            try persist(Credentials(accessToken: accessToken,
                refreshToken: nativeTokens.refreshTokenForPersistence, expiresAt: expiresAt))
            signedIn = true
        } catch { self.error = error.localizedDescription }
    }

    func endSignIn() { signInManager = nil }

    func signOut() {
        // `init` never reads the keychain under UI testing, so there is nothing there to delete and
        // the delete's status says nothing about whether the session was cleared. It is not merely
        // redundant: the test build is signed with CODE_SIGNING_ALLOWED=NO, so the Clip carries no
        // application-identifier entitlement and every keychain call returns errSecMissingEntitlement
        // — which the guard below reads as a failed sign-out and leaves the user signed in.
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            clearSession()
            return
        }
        #endif
        let status = SecItemDelete(keychainQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            error = "Could not sign out. Please try again."
            return
        }
        clearSession()
    }

    /// Everything a sign-out drops apart from the persisted credential itself.
    private func clearSession() {
        refreshTask?.cancel()
        refreshTask = nil
        try? nativeTokens.clearAll()
        signInManager = nil
        credentials = nil
        error = nil
        signedIn = false
    }

    func token(forceRefresh: Bool = false) async throws -> String {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            if ProcessInfo.processInfo.arguments.contains("--clip-library-fixtures") {
                return "fixture.eyJzdWIiOiJjbGlwLWxpYnJhcnktdGVzdCJ9.signature"
            }
            throw MessagesStickerCreationError.unauthorized
        }
        #endif
        if !forceRefresh, let credentials, credentials.expiresAt.timeIntervalSinceNow > 90 { return credentials.accessToken }
        if let refreshTask { return try await refreshTask.value }
        guard let refresh = credentials?.refreshToken else {
            signedIn = false
            throw MessagesStickerCreationError.unauthorized
        }
        let task = Task { try await self.exchange(["grant_type": "refresh_token", "refresh_token": refresh]) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }
    private func exchange(_ fields: [String: String]) async throws -> String {
        var body = URLComponents()
        body.queryItems = (fields.merging(["client_id": clientID]) { _, new in new }).map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let tokenURL, tokenURL.scheme == "https", !clientID.isEmpty else {
            throw MessagesStickerCreationError.invalidConfiguration
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            if let status = (response as? HTTPURLResponse)?.statusCode, status == 400 || status == 401 {
                credentials = nil; signedIn = false
                SecItemDelete(keychainQuery as CFDictionary)
            }
            throw MessagesStickerCreationError.server(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 503,
                message: "Sign-in could not be refreshed. Please try again."
            )
        }
        let result = try JSONDecoder().decode(TokenResponse.self, from: data)
        let saved = Credentials(accessToken: result.access_token, refreshToken: result.refresh_token ?? credentials?.refreshToken,
            expiresAt: Date().addingTimeInterval(result.expires_in))
        try persist(saved)
        return saved.accessToken
    }
    private func persist(_ saved: Credentials) throws {
        let encoded = try JSONEncoder().encode(saved)
        let attributes = [kSecValueData as String: encoded]
        let status = SecItemUpdate(keychainQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = keychainQuery
            item[kSecValueData as String] = encoded
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw MessagesStickerCreationError.invalidConfiguration }
        } else if status != errSecSuccess { throw MessagesStickerCreationError.invalidConfiguration }
        credentials = saved
    }
    private var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.rxlab.stickerfactory.Clip.oauth",
            kSecAttrAccount as String: "session"
        ]
    }
}

/// Native sign-in hands credentials to the Clip's existing refresh owner. Hiding the refresh
/// token from RxAuth's timer prevents it from rotating the persisted token behind that owner.
private final class ClipNativeTokenStorage: TokenStorageProtocol, Sendable {
    private let storage = InMemoryTokenStorage()
    var refreshTokenForPersistence: String? { storage.getRefreshToken() }
    func saveAccessToken(_ token: String) throws { try storage.saveAccessToken(token) }
    func getAccessToken() -> String? { storage.getAccessToken() }
    func deleteAccessToken() throws { try storage.deleteAccessToken() }
    func saveRefreshToken(_ token: String) throws { try storage.saveRefreshToken(token) }
    func getRefreshToken() -> String? { nil }
    func deleteRefreshToken() throws { try storage.deleteRefreshToken() }
    func saveExpiresAt(_ date: Date) throws { try storage.saveExpiresAt(date) }
    func getExpiresAt() -> Date? { storage.getExpiresAt() }
    func isTokenExpired() -> Bool { storage.isTokenExpired() }
    func clearAll() throws { try storage.clearAll() }
}
