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
                .telemetryScreen("sign_in")
            case .signedIn:
                StickerFactoryTabView(environment: environment)
            }
        }
        // The poster look is a printed one: cream paper, near-black ink. It has no dark
        // counterpart on the web either, and inverting it would mean inventing a second palette
        // that agrees with nothing. So the app stays in daylight.
        .environment(\.tutorialCoordinator, environment.tutorials)
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
    /// The welcome tour and the unread feature cards, as one sheet that advances from the first
    /// to the second. One sheet rather than two: a card sheet presented from the tour's dismissal
    /// lands while the tour is still tearing down and is dropped, and the steps are captured when
    /// the sheet goes up so the set cannot shift underneath it as each card is acknowledged.
    @State private var launchFlow: LaunchFlowPresentation?
    // Keep background alerts deferred through the sheet dismissal animation as well.
    @State private var defersLibraryErrors = true
    @State private var featureStore = FeatureAnnouncementStore()
    @State private var showingQuickMode = false
    @State private var tutorialRequest: TutorialRequest?
    @State private var tutorialAfterLaunch = false
    @State private var pendingTutorialAction: TutorialAction?
    /// Driven only from outside the UI — a tapped "sticker ready" banner. Tapping around the
    /// Library still pushes through its own `NavigationLink`s, which this path also records.
    @State private var libraryPath = NavigationPath()

    var body: some View {
        TabView(selection: $selection) {
            // First in the bar, but valued 3: values are what deep links and tutorials route by,
            // and renumbering them to match the order would move every one of those destinations.
            // The pet is the app's companion, so on iOS 27 it gets the bar's prominent slot.
            Tab("Pet", systemImage: "pawprint.fill", value: 3, role: petTabRole) {
                NavigationStack {
                    PetView(api: environment.store.api)
                }
            }

            // Library stays value 0 and the default selection: launch lands on the user's own
            // work, not on a store.
            Tab("Library", systemImage: "square.grid.2x2", value: 0) {
                NavigationStack(path: $libraryPath) {
                    LibraryView(
                        store: environment.store,
                        marketplace: environment.marketplace,
                        subscription: environment.subscription,
                        defersErrors: defersLibraryErrors
                    )
                    .navigationDestination(for: SharedPackDestination.self) { route in
                        SharedPackEntry(store: environment.marketplace, slug: route.slug)
                    }
                }
            }

            // Owns its own navigation stack: creating a pack lands on that pack, which the
            // composer can only ask for from inside the stack.
            Tab("Sticker Packs", systemImage: "square.stack.3d.up", value: 1) {
                MarketplaceView(store: environment.marketplace)
            }

            Tab("Account", systemImage: "person.crop.circle", value: 2) {
                NavigationStack {
                    AccountView(
                        environment: environment,
                        onShowWelcome: {
                            defersLibraryErrors = true
                            launchFlow = .init(steps: [.welcome])
                        },
                        onShowFeatures: {
                            defersLibraryErrors = true
                            launchFlow = .init(steps: [.featureCards(FeatureAnnouncement.all)])
                        }
                    )
                }
            }
        }
        .tint(AppColors.accent)
        .accessibilityIdentifier("sticker-factory-tabs")
        .onChange(of: selection) { _, tab in
            // The tab bar is UIKit's, so its buttons never reach the app's styles. Watching the
            // selection is what makes the most-pressed control in the app answer at all.
            Haptics.selection()
            let names = [0: "library", 1: "marketplace", 2: "account", 3: "pet"]
            AppTelemetry.event("tab_selected", parameters: ["tab": names[tab] ?? "unknown"])
        }
        .sheet(isPresented: $showingQuickMode) {
            NavigationStack {
                QuickModeView(model: QuickModeModel(baseURL: environment.configuration.apiBaseURL, appClip: false) { force in
                    try await environment.tokenBroker.validAccessToken(forceRefresh: force)
                })
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            Haptics.tap(.light)
                            showingQuickMode = false
                        }
                    }
                }
            }
        }
        .onChange(of: environment.pendingTutorialLink) { _, _ in openTutorialLink() }
        .onChange(of: environment.tutorials.navigation?.id) { _, _ in openTutorialDestination() }
        .onChange(of: environment.pendingShareRoute) { _, _ in openShareRoute() }
        .onChange(of: environment.pendingStickerID) { _, _ in openPendingSticker() }
        .onChange(of: environment.pendingOpenPet) { _, _ in openPendingPet() }
        .task {
            // A deep link can arrive before authentication finishes and before this tab hierarchy
            // exists. Consume it on first appearance as well as through `onChange`.
            openPendingSticker()
            openPendingPet()
            openShareRoute()
            StickerOnboardingTips.setWelcomeCompleted(hasSeenWelcome)
            presentLaunchFlowIfNeeded()
            openTutorialLink()
            defersLibraryErrors = launchFlow != nil
        }
        .sheet(item: $tutorialRequest, onDismiss: {
            defersLibraryErrors = false
            if let action = pendingTutorialAction {
                pendingTutorialAction = nil
                environment.tutorials.open(action)
            }
        }, content: { request in
            TutorialSheet(coordinator: environment.tutorials, request: request) { action in
                pendingTutorialAction = action; tutorialRequest = nil
            }
        })
        .sheet(item: $launchFlow, onDismiss: {
            if tutorialAfterLaunch {
                tutorialAfterLaunch = false
                tutorialRequest = .init()
            } else {
                defersLibraryErrors = false
                openTutorialLink()
            }
        }, content: { flow in
            LaunchFlowView(
                steps: flow.steps,
                allowsWelcomeTutorial: flow.steps.count == 1 && hasSeenWelcome,
                onReadTutorial: { tutorialAfterLaunch = true; launchFlow = nil },
                onWelcomeSeen: {
                    AppTelemetry.event("tutorial_complete")
                    hasSeenWelcome = true
                    StickerOnboardingTips.setWelcomeCompleted(true)
                },
                onCardAcknowledged: { featureStore.markRead($0) },
                onFinished: { launchFlow = nil }
            )
        })
        // Hosted once, at the root. A refusal can come from a chat turn, an export, or a publish —
        // all on different screens, some of them already inside their own sheet — and presenting
        // from each of them would mean a paywall that cannot open over whatever is in the way.
        .subscriptionPaywall(environment.subscription)
    }

    /// `.prominent` arrived in iOS 27; on iOS 26 the pet stays an ordinary tab. The compiler
    /// check keeps the app building with the iOS 26 SDK (Xcode 26 / Swift 6.3), where the
    /// member doesn't exist at all.
    private var petTabRole: TabRole? {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) { return .prominent }
        #endif
        return nil
    }

    /// Puts up whatever this launch owes: the welcome tour on a first launch, then any feature
    /// cards this device has not acknowledged. Both follow the same automation rule — suppressed
    /// while UI tests run unless a test asks for them by flag.
    private func presentLaunchFlowIfNeeded() {
        guard launchFlow == nil else { return }
        let arguments = ProcessInfo.processInfo.arguments
        var steps: [LaunchStep] = []
        if StickerOnboarding.shouldPresentWelcome(
            hasSeenWelcome: hasSeenWelcome,
            isUITesting: environment.isUITesting,
            forceWelcome: arguments.contains("--ui-show-welcome")
        ) {
            steps.append(.welcome)
        }
        let forceCards = arguments.contains("--ui-show-feature-cards")
        let cards = forceCards ? FeatureAnnouncement.all : featureStore.unread
        if FeatureAnnouncementStore.shouldPresent(
            unreadCount: cards.count,
            isUITesting: environment.isUITesting,
            force: forceCards
        ), !cards.isEmpty {
            steps.append(.featureCards(cards))
        }
        guard !steps.isEmpty else { return }
        launchFlow = LaunchFlowPresentation(steps: steps)
    }

    private func openTutorialLink() {
        guard launchFlow == nil, let link = environment.pendingTutorialLink else { return }
        environment.pendingTutorialLink = nil
        switch link {
        case .tutorial(let request): tutorialRequest = request
        case .action(let action): environment.tutorials.open(action)
        }
    }

    private func openTutorialDestination() {
        let tutorials = environment.tutorials
        guard let route = tutorials.navigation else { return }
        tutorials.navigation = nil
        switch route.action {
        case .create:
            selection = 0; tutorials.creationRequest = route
        case .library:
            selection = 0; libraryPath = NavigationPath()
        case .packs, .newPack:
            selection = 1; tutorials.packRequest = route
        case .pack:
            selection = 1; tutorials.packRequest = route
            if route.context.packID == nil { tutorials.selectionNotice = TutorialCopy.text("Choose a pack to try this feature.") }
        case .sticker:
            selection = 0
            if let id = route.context.stickerID {
                tutorials.stickerRequest = route
                environment.pendingStickerID = id
            } else {
                libraryPath = NavigationPath()
                tutorials.selectionNotice = TutorialCopy.text("Choose a sticker to try this feature.")
            }
        }
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

    private func openPendingPet() {
        guard environment.pendingOpenPet else { return }
        environment.pendingOpenPet = false
        selection = 3
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
            if let packID {
                PackDetailView(store: store, packID: packID)
            } else if loaded {
                ContentUnavailableView(
                    "Pack unavailable",
                    systemImage: "photo",
                    description: Text(store.errorMessage ?? "This pack is no longer available.")
                )
            } else {
                ProgressView("Loading pack…")
            }
        }
        .task(id: slug) {
            packID = await store.loadDetail(packID: slug)?.id
            loaded = true
        }
    }
}
