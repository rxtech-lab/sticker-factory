import Foundation
import Observation
import RxAuthSwift

nonisolated enum AuthenticationPresentationState: Sendable { case checking, signedOut, signedIn }

@MainActor
@Observable
final class AppEnvironment {
    let configuration: AppConfiguration
    let authManager: OAuthManager
    let tokenBroker: SharedTokenBroker
    let store: StickerStore
    private(set) var authenticationState: AuthenticationPresentationState
    private(set) var isUITesting: Bool

    init(
        configuration: AppConfiguration,
        authManager: OAuthManager,
        tokenBroker: SharedTokenBroker,
        store: StickerStore,
        authenticationState: AuthenticationPresentationState = .checking,
        isUITesting: Bool = false
    ) {
        self.configuration = configuration
        self.authManager = authManager
        self.tokenBroker = tokenBroker
        self.store = store
        self.authenticationState = authenticationState
        self.isUITesting = isUITesting
    }

    static func live() -> AppEnvironment {
        let configuration = AppConfiguration.live()
        let vault = SharedKeychainTokenVault()
        let rxStorage = RxAuthSharedTokenStorage(vault: vault)
        let manager = OAuthManager(
            configuration: .init(
                issuer: configuration.oauthIssuer.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                clientID: configuration.oauthClientID,
                redirectURI: configuration.oauthRedirectURI,
                scopes: ["openid"],
                passkeyChallengePath: "/api/oauth/passkey/authenticate/options",
                passkeyVerificationPath: "/api/oauth/passkey/authenticate/verify",
                passkeyRegistrationChallengePath: "/api/oauth/passkey/register/options",
                passkeyRegistrationVerificationPath: "/api/oauth/passkey/register/verify",
                passkeyUpgradeChallengePath: "/api/oauth/passkey/upgrade/options",
                passkeyUpgradeVerificationPath: "/api/oauth/passkey/upgrade/verify",
                passkeyAccountCreationOptionsPath: "/api/oauth/passkey/account-creation/options",
                passkeyAccountCreationVerifyPath: "/api/oauth/passkey/account-creation/verify",
                passkeyRelyingPartyIdentifier: "rxlab.app",
                keychainServiceName: AppConfiguration.keychainService
            ),
            tokenStorage: rxStorage
        )
        let broker = SharedTokenBroker(
            vault: vault,
            transport: URLSessionOAuthRefreshTransport(),
            tokenURL: configuration.oauthTokenURL,
            clientID: configuration.oauthClientID
        )
        let arguments = ProcessInfo.processInfo.arguments
        let isUITesting = arguments.contains("--ui-testing")
        let simulatesExpiredAuthentication = arguments.contains("--ui-auth-expired")
        let simulatesUploadFailure = arguments.contains("--ui-upload-failure")
        let api: StickerAPIClientProtocol = isUITesting
            ? MockStickerAPIClient(failCreationAsUpload: simulatesUploadFailure)
            : StickerAPIClient(baseURL: configuration.apiBaseURL, tokenBroker: broker)
        return .init(
            configuration: configuration,
            authManager: manager,
            tokenBroker: broker,
            store: StickerStore(api: api),
            authenticationState: isUITesting
                ? (simulatesExpiredAuthentication ? .signedOut : .signedIn)
                : .checking,
            isUITesting: isUITesting
        )
    }

    func start() async {
        if isUITesting {
            await store.refresh()
            return
        }
        // Refresh through the extension-safe broker before RxAuth restores
        // user info. The injected storage intentionally hides refresh tokens
        // from OAuthManager's private timer.
        if (try? await tokenBroker.currentBundle()) != nil {
            _ = try? await tokenBroker.validAccessToken()
        }
        await authManager.checkExistingAuth()
        synchronizeAuthenticationState()
        if authenticationState == .signedIn { await store.refresh() }
    }

    func authenticationCompleted() {
        synchronizeAuthenticationState()
        Task { await store.refresh() }
    }

    func sessionExpired() async {
        // A rejected broker refresh has already invalidated the shared bundle,
        // but RxAuth still owns its in-memory state and refresh timer. Drive
        // both stores through their normal logout paths before presenting the
        // signed-out UI so a stale OAuthManager session cannot be restored.
        try? await tokenBroker.logout()
        await authManager.logout()
        SharedLogoutPurger.purge()
        store.reset()
        authenticationState = .signedOut
    }

    func signOut() async {
        try? await tokenBroker.logout()
        await authManager.logout()
        SharedLogoutPurger.purge()
        store.reset()
        authenticationState = .signedOut
    }

    private func synchronizeAuthenticationState() {
        switch authManager.authState {
        case .unknown: authenticationState = .checking
        case .authenticated: authenticationState = .signedIn
        case .unauthenticated: authenticationState = .signedOut
        }
    }
}
