import RxAuthSwift
import SwiftUI
import TipKit

@main
struct StickerGeniOSApp: App {
    /// APNs hands a device token to a `UIApplicationDelegate` and to nothing else, so a SwiftUI app
    /// that wants push has to keep one. It does nothing but forward — see `PushDeviceRegistry`.
    @UIApplicationDelegateAdaptor(PushApplicationDelegate.self) private var pushDelegate
    @State private var environment = AppEnvironment.live()

    init() {
        // UIKit's bars are outside SwiftUI's reach, so they are repainted before the first one
        // is ever built.
        PosterChrome.apply()
        StickerOnboarding.configureTips(
            isUITesting: ProcessInfo.processInfo.arguments.contains("--ui-testing")
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView(environment: environment)
                .task { await environment.start() }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { environment.handleIncomingURL(url) }
                }
                .onOpenURL { url in environment.handleIncomingURL(url) }
                .onReceive(NotificationCenter.default.publisher(for: .rxAuthSessionExpired)) { _ in
                    Task { await environment.sessionExpired() }
                }
        }
    }
}
