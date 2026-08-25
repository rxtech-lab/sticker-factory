import RxAuthSwift
import SwiftUI

@main
struct StickerGeniOSApp: App {
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
