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
    /// Set by tapping a "your pet grew" banner; `ContentView` switches to the Pet tab and clears it.
    var pendingOpenPet = false
    var pendingShareRoute: StickerShareRoute?
    var pendingStickerCreation: SharedStickerCreationRequest?
    var pendingTutorialLink: TutorialDeepLink?
    let tutorials: TutorialCoordinator
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
        self.tutorials = TutorialCoordinator(baseURL: configuration.apiBaseURL, store: store, marketplace: self.marketplace)
        // Defaulted rather than required so previews and tests keep building without one; the
        // no-client store reports no paywall, which is what a preview wants anyway.
        self.subscription = subscription ?? SubscriptionStore()
        self.authenticationState = authenticationState
        self.isUITesting = isUITesting
        // Installing or removing a pack changes which sections the Library shows. Wiring it here
        // rather than having either store reach for the other keeps them independent.
        self.marketplace.onInstallsChanged = { [store] in await store.refreshSections() }
        // Generating is what spends credits, so the count in the Library toolbar follows the work
        // rather than sitting on whatever the last paywall or cold start happened to read.
        let subscriptionStore = self.subscription
        self.store.onCreditsMayHaveChanged = { subscriptionStore.refresh() }
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
                // `write:profile` is what the identity provider requires to schedule or cancel a
                // deletion of this account (`grantsAccountDeletionScope`). Reading the pending
                // state deliberately needs no extra scope, but the button does — an install
                // authorized before this was added gets a consent screen on its next sign-in, and
                // until then the delete call comes back as ACCOUNT_DELETION_SCOPE_REQUIRED.
                scopes: ["openid", "write:profile"],
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
        let simulatesLibraryListingFailure = arguments.contains("--ui-library-list-failure")
        let api: StickerAPIClientProtocol = isUITesting
            ? MockStickerAPIClient(
                failCreationAsUpload: simulatesUploadFailure,
                failChatSendAsInsufficientCredits: simulatesInsufficientCredits,
                failLibraryListing: simulatesLibraryListingFailure
            )
            : StickerAPIClient(
                baseURL: configuration.apiBaseURL,
                tokenBroker: broker,
                appVersion: configuration.appVersion
            )
        // UI tests run with no notifier at all: a system permission alert over the app would fail
        // every test that follows it, and the mock generations are watched, never walked away from.
        let notifier = isUITesting ? nil : GenerationNotifier.live()
        var subscription = isUITesting
            ? SubscriptionStore()
            : SubscriptionStore(configuration: configuration, tokenBroker: broker)
        #if DEBUG
        if isUITesting, arguments.contains("--ui-balance-refresh") {
            subscription = SubscriptionStore(uiTestClient: BalanceRefreshFixture.makeClient())
        }
        if isUITesting, arguments.contains("--ui-subscription-unavailable") {
            subscription = SubscriptionConnectionFixture.makeStore()
        }
        if isUITesting, arguments.contains("--ui-free-generation-allowance") {
            subscription = SubscriptionConnectionFixture.makeStore(availableGenerations: 3)
        }
        #endif
        let environment = AppEnvironment(
            configuration: configuration,
            authManager: manager,
            tokenBroker: broker,
            store: StickerStore(api: api, notifier: notifier),
            // UI tests run against the mock API with no billing at all: a paywall in front of a
            // scripted generation would fail every test that follows it.
            subscription: subscription,
            authenticationState: isUITesting
                ? (simulatesExpiredAuthentication ? .signedOut : .signedIn)
                : .checking,
            isUITesting: isUITesting,
            notifier: notifier
        )
        notifier?.onOpenSticker = { [weak environment] id in environment?.pendingStickerID = id }
        notifier?.onOpenPet = { [weak environment] in environment?.pendingOpenPet = true }
        // Every 402 from the server, wherever it came from, raises the paywall. The error itself
        // still reaches whichever screen asked, so the user also reads the server's own words.
        if let live = api as? StickerAPIClient {
            environment.store.liveActivities = GenerationLiveActivityManager(api: live)
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
        // The widget and the watch show the pet from what the phone writes for them; see
        // `PetCompanionSync`. UI tests run on the mock and leave both alone.
        if !isUITesting { PetCompanionSync.shared.attach(api: api) }
        // With Location Tracking on and "Always" allowed, iOS wakes the app as the owner travels;
        // those moves go to the pet from here, even when the app was not running.
        if !isUITesting { PetContextProvider.shared.attachBackgroundUploads(api: api) }
        #if DEBUG
        if isUITesting, let value = ProcessInfo.processInfo.environment["TUTORIAL_DEEP_LINK"], let url = URL(string: value) {
            environment.handleIncomingURL(url)
        }
        #endif
        return environment
    }

    func start() async {
        // Unauthenticated and needed by the plan editor whether or not the library loads, so it is
        // asked for before anything else can decide not to.
        store.loadConfigurationLimits()
        if isUITesting {
            subscription.refresh()
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
            store.liveActivities?.resume()
            subscription.refresh()
            Task { await PetCompanionSync.shared.refresh() }
            await store.refresh()
        }
    }

    /// Reloads what may have moved while the app was not in front of the user.
    ///
    /// Credits are the reason: they are spent by the server, which keeps working through a
    /// backgrounded app, and they can be spent from another device entirely — so the count in the
    /// toolbar is the one number on screen that can go stale without anything happening here.
    func enteredForeground() {
        guard authenticationState == .signedIn else { return }
        store.liveActivities?.resume()
        subscription.refresh()
        // The pet reads stickers sent from Messages while the app is away; this is the moment the
        // widget and the watch catch up even if the silent push never came.
        Task { await PetCompanionSync.shared.refresh() }
        // The pet's sense of the weather and the day's walking. Never prompts — only sources the
        // user already connected in the Pet tab are read — and at most every half hour.
        if !isUITesting {
            let api = store.api
            Task {
                await PetContextProvider.shared.refreshPermissions()
                await PetContextProvider.shared.syncIfNeeded(api: api)
            }
        }
    }

    func authenticationCompleted() {
        AppTelemetry.event("login", parameters: ["method": "rxlab"])
        synchronizeAuthenticationState()
        Task { await store.refresh() }
        Task { await PetCompanionSync.shared.refresh() }
        subscription.reset()
        subscription.refresh()
    }

    /// Opens the exact project started in Messages. Unknown links — including the OAuth callback,
    /// which uses the same custom scheme — are deliberately ignored here and remain owned by the
    /// authentication library.
    func handleIncomingURL(_ url: URL) {
        if let link = TutorialDeepLink(url: url) { pendingTutorialLink = link; return }
        if let request = SharedStickerCreationHandoff.consume(url) {
            AppTelemetry.event("deep_link_opened", parameters: ["destination": "create_from_share"])
            pendingStickerCreation = request; return
        }
        if let route = StickerShareRoute(url: url) {
            AppTelemetry.event("deep_link_opened", parameters: ["destination": "shared_content"])
            pendingShareRoute = route; return
        }
        guard let stickerID = StickerDeepLink.stickerID(from: url) else { return }
        AppTelemetry.event("deep_link_opened", parameters: ["destination": "sticker"])
        pendingStickerID = stickerID
    }

    func sessionExpired() async {
        // Before the token is gone: dropping this device is an authenticated call, and a device
        // left registered would announce the departing account's stickers to whoever signs in next.
        await store.liveActivities?.signedOut()
        await PushDeviceRegistry.shared.signedOut()
        await PetCompanionSync.shared.signedOut()
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
        pendingStickerCreation = nil
        authenticationState = .signedOut
    }

    func signOut() async {
        AppTelemetry.event("logout")
        await store.liveActivities?.signedOut()
        await PushDeviceRegistry.shared.signedOut()
        await PetCompanionSync.shared.signedOut()
        try? await tokenBroker.logout()
        await authManager.logout()
        SharedLogoutPurger.purge()
        store.reset()
        marketplace.reset()
        subscription.reset()
        // A banner tapped on the way out points at a library this account no longer has.
        pendingStickerID = nil
        pendingStickerCreation = nil
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
