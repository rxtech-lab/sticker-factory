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
        StickerOnboarding.configureTips(
            isUITesting: ProcessInfo.processInfo.arguments.contains("--ui-testing")
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView(environment: environment)
                .task { await environment.start() }
                .onOpenURL { url in environment.handleIncomingURL(url) }
                .onReceive(NotificationCenter.default.publisher(for: .rxAuthSessionExpired)) { _ in
                    Task { await environment.sessionExpired() }
                }
        }
    }
}
