import SwiftUI

@main
struct WinkyWatchApp: App {
    @State private var model = WatchPetModel()

    var body: some Scene {
        WindowGroup {
            WatchPetView(model: model)
        }
    }
}
