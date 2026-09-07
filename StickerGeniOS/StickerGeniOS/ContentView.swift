import AnimatedView
import RxAuthSwift
import RxAuthSwiftUI
import SwiftUI

struct ContentView: View {
    @Bindable var environment: AppEnvironment

    var body: some View {
        Group {
            switch environment.authenticationState {
            case .checking:
                StickerBackground {
                    PosterProgress(message: String(localized: "Restoring your sticker library…"))
                }
            case .signedOut:
                RxSignInView(
                    manager: environment.authManager,
                    appearance: .init(
                        icon: .assetImage("PosterSignIn", nil),
                        title: LocalizedStringKey(AppConfiguration.defaultAppName),
                        subtitle: "Make expressive stickers from words and photos.",
                        signInButtonTitle: "Sign in with RxLab",
                        accentColor: AppColors.accent,
                        secondaryColor: AppColors.secondaryAccent,
                        showsAnimatedBackground: true
                    ),
                    style: .native,
                    onAuthSuccess: { environment.authenticationCompleted() }
                )
                .accessibilityIdentifier("rxauth-sign-in")
            case .signedIn:
                StickerFactoryTabView(environment: environment)
            }
        }
        // The poster look is a printed one: cream paper, near-black ink. It has no dark
        // counterpart on the web either, and inverting it would mean inventing a second palette
        // that agrees with nothing. So the app stays in daylight.
        .preferredColorScheme(.light)
        // Set once, here, so every label in the app inherits the rounded display face rather
        // than each view asking for it.
        .fontDesign(.rounded)
        .tint(AppColors.accent)
    }
}

struct StickerFactoryTabView: View {
    @Bindable var environment: AppEnvironment
    @AppStorage(StickerOnboarding.welcomeStorageKey) private var hasSeenWelcome = false
    @State private var selection = 0
    @State private var showingWelcome = false
    @State private var showingQuickMode = false
    /// Driven only from outside the UI — a tapped "sticker ready" banner. Tapping around the
    /// Library still pushes through its own `NavigationLink`s, which this path also records.
    @State private var libraryPath = NavigationPath()

    var body: some View {
        TabView(selection: $selection) {
            // Library stays tag 0 and the default selection: launch lands on the user's own work,
            // not on a store.
            NavigationStack(path: $libraryPath) {
                LibraryView(
                    store: environment.store,
                    marketplace: environment.marketplace,
                    subscription: environment.subscription
                )
                .navigationDestination(for: SharedPackDestination.self) { route in
                    SharedPackEntry(store: environment.marketplace, slug: route.slug)
                }
            }
                .tabItem { Label("Library", systemImage: "square.grid.2x2") }
                .tag(0)

            NavigationStack { MarketplaceView(store: environment.marketplace) }
                .tabItem { Label("Marketplace", systemImage: "bag") }
                .tag(1)

            NavigationStack {
                AccountView(environment: environment, onShowWelcome: { showingWelcome = true })
            }
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag(2)
        }
        .tint(AppColors.accent)
        .accessibilityIdentifier("sticker-factory-tabs")
        .sheet(isPresented: $showingQuickMode) {
            NavigationStack {
                QuickModeView(model: QuickModeModel(baseURL: environment.configuration.apiBaseURL, appClip: false) { force in
                    try await environment.tokenBroker.validAccessToken(forceRefresh: force)
                })
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showingQuickMode = false } } }
            }
        }
        .onChange(of: environment.pendingShareRoute) { _, _ in openShareRoute() }
        .onChange(of: environment.pendingStickerID) { _, _ in openPendingSticker() }
        .task {
            // A deep link can arrive before authentication finishes and before this tab hierarchy
            // exists. Consume it on first appearance as well as through `onChange`.
            openPendingSticker()
            openShareRoute()
            StickerOnboardingTips.setWelcomeCompleted(hasSeenWelcome)
            let arguments = ProcessInfo.processInfo.arguments
            if StickerOnboarding.shouldPresentWelcome(
                hasSeenWelcome: hasSeenWelcome,
                isUITesting: environment.isUITesting,
                forceWelcome: arguments.contains("--ui-show-welcome")
            ) {
                showingWelcome = true
            }
        }
        .sheet(isPresented: $showingWelcome) {
            StickerWelcomeSheet {
                hasSeenWelcome = true
                StickerOnboardingTips.setWelcomeCompleted(true)
                showingWelcome = false
            }
        }
        // Hosted once, at the root. A refusal can come from a chat turn, an export, or a publish —
        // all on different screens, some of them already inside their own sheet — and presenting
        // from each of them would mean a paywall that cannot open over whatever is in the way.
        .subscriptionPaywall(environment.subscription)
    }

    private func openShareRoute() {
        guard let route = environment.pendingShareRoute else { return }
        environment.pendingShareRoute = nil
        selection = 0
        switch route {
        case .quick: showingQuickMode = true
        case .pack(let slug):
            libraryPath = NavigationPath()
            libraryPath.append(SharedPackDestination(slug: slug))
        }
    }

    private func openPendingSticker() {
        guard let stickerID = environment.pendingStickerID else { return }
        environment.pendingStickerID = nil
        selection = 0
        // Replace the stack rather than push onto it: the external request is an instruction to be
        // at that sticker, not one level deeper into wherever the user already was.
        var path = NavigationPath()
        path.append(stickerID)
        libraryPath = path
    }
}

#Preview("Authenticated") {
    let configuration = AppConfiguration.live()
    let vault = SharedKeychainTokenVault(service: "preview", account: "preview", accessGroup: nil, allowUnsharedFallback: true)
    let broker = SharedTokenBroker(
        vault: vault,
        transport: URLSessionOAuthRefreshTransport(),
        tokenURL: configuration.oauthTokenURL,
        clientID: configuration.oauthClientID
    )
    let auth = OAuthManager(configuration: .init(
        issuer: configuration.oauthIssuer.absoluteString,
        clientID: configuration.oauthClientID,
        redirectURI: configuration.oauthRedirectURI
    ))
    ContentView(environment: .init(
        configuration: configuration,
        authManager: auth,
        tokenBroker: broker,
        store: .init(api: MockStickerAPIClient()),
        authenticationState: .signedIn,
        isUITesting: true
    ))
}

private struct SharedPackDestination: Hashable { let slug: String }

private struct SharedPackEntry: View {
    @Bindable var store: MarketplaceStore
    let slug: String
    @State private var packID: String?
    @State private var loaded = false
    var body: some View {
        Group {
            if let packID { PackDetailView(store: store, packID: packID) }
            else if loaded { ContentUnavailableView("Pack unavailable", systemImage: "photo", description: Text(store.errorMessage ?? "This pack is no longer available.")) }
            else { ProgressView("Loading pack…") }
        }.task(id: slug) { packID = await store.loadDetail(packID: slug)?.id; loaded = true }
    }
}
