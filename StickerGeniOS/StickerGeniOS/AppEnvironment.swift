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
    let marketplace: MarketplaceStore
    let subscription: SubscriptionStore
    private(set) var authenticationState: AuthenticationPresentationState
    private(set) var isUITesting: Bool
    /// A sticker the user asked for from outside the UI — today, by tapping a "sticker ready"
    /// banner. Held here rather than in a view so it survives whichever screen happens to be up;
    /// `StickerFactoryTabView` consumes it and clears it.
    var pendingStickerID: String?
    /// Strong-held: `UNUserNotificationCenter` keeps only a weak reference to its delegate.
    @ObservationIgnored private let notifier: GenerationNotifier?

    init(
        configuration: AppConfiguration,
        authManager: OAuthManager,
        tokenBroker: SharedTokenBroker,
        store: StickerStore,
        marketplace: MarketplaceStore? = nil,
        subscription: SubscriptionStore? = nil,
        authenticationState: AuthenticationPresentationState = .checking,
        isUITesting: Bool = false,
        notifier: GenerationNotifier? = nil
    ) {
        self.notifier = notifier
        self.configuration = configuration
        self.authManager = authManager
        self.tokenBroker = tokenBroker
        self.store = store
        self.marketplace = marketplace ?? MarketplaceStore(api: store.api)
        // Defaulted rather than required so previews and tests keep building without one; the
        // no-client store reports no paywall, which is what a preview wants anyway.
        self.subscription = subscription ?? SubscriptionStore()
        self.authenticationState = authenticationState
        self.isUITesting = isUITesting
        // Installing or removing a pack changes which sections the Library shows. Wiring it here
        // rather than having either store reach for the other keeps them independent.
        self.marketplace.onInstallsChanged = { [store] in await store.refreshSections() }
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
        let simulatesInsufficientCredits = arguments.contains("--ui-insufficient-credits")
        let api: StickerAPIClientProtocol = isUITesting
            ? MockStickerAPIClient(
                failCreationAsUpload: simulatesUploadFailure,
                failChatSendAsInsufficientCredits: simulatesInsufficientCredits
            )
            : StickerAPIClient(baseURL: configuration.apiBaseURL, tokenBroker: broker)
        // UI tests run with no notifier at all: a system permission alert over the app would fail
        // every test that follows it, and the mock generations are watched, never walked away from.
        let notifier = isUITesting ? nil : GenerationNotifier.live()
        let environment = AppEnvironment(
            configuration: configuration,
            authManager: manager,
            tokenBroker: broker,
            store: StickerStore(api: api, notifier: notifier),
            // UI tests run against the mock API with no billing at all: a paywall in front of a
            // scripted generation would fail every test that follows it.
            subscription: isUITesting ? SubscriptionStore() : SubscriptionStore(configuration: configuration, tokenBroker: broker),
            authenticationState: isUITesting
                ? (simulatesExpiredAuthentication ? .signedOut : .signedIn)
                : .checking,
            isUITesting: isUITesting,
            notifier: notifier
        )
        notifier?.onOpenSticker = { [weak environment] id in environment?.pendingStickerID = id }
        // Every 402 from the server, wherever it came from, raises the paywall. The error itself
        // still reaches whichever screen asked, so the user also reads the server's own words.
        if let live = api as? StickerAPIClient {
            let subscription = environment.subscription
            Task {
                await live.onSubscriptionRefusal { refusal in
                    Task { @MainActor in subscription.presentPaywall(for: refusal) }
                }
            }
        }
        // Hand the registry a client to upload with. The device token may already be waiting — APNs
        // answers on its own schedule — or may arrive long after this; whichever lands second sends.
        if !isUITesting { PushDeviceRegistry.shared.attach(api: api) }
        return environment
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
        if authenticationState == .signedIn {
            await store.refresh()
            bindSubscription()
        }
    }

    func authenticationCompleted() {
        synchronizeAuthenticationState()
        Task { await store.refresh() }
        bindSubscription()
    }

    /// Opens the exact project started in Messages. Unknown links — including the OAuth callback,
    /// which uses the same custom scheme — are deliberately ignored here and remain owned by the
    /// authentication library.
    func handleIncomingURL(_ url: URL) {
        guard let stickerID = StickerDeepLink.stickerID(from: url) else { return }
        pendingStickerID = stickerID
    }

    /// Points the subscription store at whoever is signed in.
    ///
    /// The rxlab user id comes from the shared token bundle's `subject` rather than from RxAuth's
    /// profile, because that bundle is what the access token was minted for — and the subscription
    /// service derives the same `sub` from that token, so anything else here would disagree with
    /// the server.
    private func bindSubscription() {
        guard subscription.isConfigured else { return }
        Task { [tokenBroker, subscription] in
            guard let subject = try? await tokenBroker.currentBundle()?.subject else { return }
            subscription.signedIn(rxlabUserID: subject)
        }
    }

    func sessionExpired() async {
        // Before the token is gone: dropping this device is an authenticated call, and a device
        // left registered would announce the departing account's stickers to whoever signs in next.
        await PushDeviceRegistry.shared.signedOut()
        // A rejected broker refresh has already invalidated the shared bundle,
        // but RxAuth still owns its in-memory state and refresh timer. Drive
        // both stores through their normal logout paths before presenting the
        // signed-out UI so a stale OAuthManager session cannot be restored.
        try? await tokenBroker.logout()
        await authManager.logout()
        SharedLogoutPurger.purge()
        store.reset()
        marketplace.reset()
        subscription.reset()
        // A banner tapped on the way out points at a library this account no longer has.
        pendingStickerID = nil
        authenticationState = .signedOut
    }

    func signOut() async {
        await PushDeviceRegistry.shared.signedOut()
        try? await tokenBroker.logout()
        await authManager.logout()
        SharedLogoutPurger.purge()
        store.reset()
        marketplace.reset()
        subscription.reset()
        // A banner tapped on the way out points at a library this account no longer has.
        pendingStickerID = nil
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
