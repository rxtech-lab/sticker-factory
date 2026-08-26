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
                        accentColor: .purple,
                        secondaryColor: .pink,
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

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { LibraryView(store: environment.store) }
                .tabItem { Label("Library", systemImage: "square.grid.2x2") }
                .tag(0)

            NavigationStack { AccountView(environment: environment) }
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag(1)
        }
        .tint(.purple)
        .accessibilityIdentifier("sticker-factory-tabs")
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
