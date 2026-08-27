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
                    ProgressView("Restoring your sticker library…")
                        .controlSize(.large)
                }
            case .signedOut:
                RxSignInView(
                    manager: environment.authManager,
                    appearance: .init(
                        icon: .systemImage("face.smiling.inverse"),
                        title: "Sticker Factory",
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
    }
}

struct StickerFactoryTabView: View {
    @Bindable var environment: AppEnvironment
    @State private var selection = 0
    /// Driven only from outside the UI — a tapped "sticker ready" banner. Tapping around the
    /// Library still pushes through its own `NavigationLink`s, which this path also records.
    @State private var libraryPath = NavigationPath()

    var body: some View {
        TabView(selection: $selection) {
            // Library stays tag 0 and the default selection: launch lands on the user's own work,
            // not on a store.
            NavigationStack(path: $libraryPath) {
                LibraryView(store: environment.store, marketplace: environment.marketplace)
            }
                .tabItem { Label("Library", systemImage: "square.grid.2x2") }
                .tag(0)

            NavigationStack { MarketplaceView(store: environment.marketplace, library: environment.store) }
                .tabItem { Label("Marketplace", systemImage: "bag") }
                .tag(1)

            NavigationStack { AccountView(environment: environment) }
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag(2)
        }
        .tint(AppColors.accent)
        .accessibilityIdentifier("sticker-factory-tabs")
        .onChange(of: environment.pendingStickerID) { _, stickerID in
            guard let stickerID else { return }
            environment.pendingStickerID = nil
            selection = 0
            // Replace the stack rather than push onto it: the banner is an instruction to be *at*
            // that sticker, not to go one level deeper into wherever the user already was.
            var path = NavigationPath()
            path.append(stickerID)
            libraryPath = path
        }
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
