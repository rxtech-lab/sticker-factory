import RxAuthSwift
import SwiftUI

@main
struct StickerGeniOSApp: App {
    /// APNs hands a device token to a `UIApplicationDelegate` and to nothing else, so a SwiftUI app
    /// that wants push has to keep one. It does nothing but forward — see `PushDeviceRegistry`.
    @UIApplicationDelegateAdaptor(PushApplicationDelegate.self) private var pushDelegate
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            ContentView(environment: environment)
                .task { await environment.start() }
                .onReceive(NotificationCenter.default.publisher(for: .rxAuthSessionExpired)) { _ in
                    Task { await environment.sessionExpired() }
                }
        }
    }
}
