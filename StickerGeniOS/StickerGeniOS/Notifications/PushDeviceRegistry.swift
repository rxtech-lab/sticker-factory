import Foundation
import OSLog
import UIKit

/// Which APNs host will accept this build's tokens.
///
/// A token minted under the sandbox entitlement is rejected by production and vice versa, so the
/// server stores it alongside the token rather than guessing. Debug builds carry the development
/// entitlement; TestFlight and the App Store re-sign to production.
nonisolated enum PushEnvironment: String, Sendable {
    case sandbox, production

    static var current: PushEnvironment {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }
}

/// Where the APNs device token goes.
///
/// APNs delivers the token to a `UIApplicationDelegate` callback and nowhere else, which is a
/// process-wide place with no access to whatever the app has built by then — so this is the seam
/// between the two. `PushApplicationDelegate` drops the token in; `AppEnvironment` attaches an API
/// client, whenever that happens to be; whichever arrives second sends the registration.
///
/// Registration is repeated on every launch rather than kept: iOS reissues tokens after a restore,
/// a reinstall, or an OS upgrade, and a stale one is indistinguishable from a live one until a push
/// to it silently bounces. `registered` only suppresses re-sending the *same* token to the *same*
/// account within a session.
@MainActor
final class PushDeviceRegistry {
    static let shared = PushDeviceRegistry()

    private static let log = Logger(subsystem: "app.rxlab.sticker-factory", category: "push")

    private(set) var deviceToken: String?
    private var api: (any StickerAPIClientProtocol)?
    private var registered: String?
    /// The upload in flight. Nothing in the app reads it; tests await it.
    private(set) var work: Task<Void, Never>?

    init() {}

    /// Hands over the client the token should be uploaded with. Safe to call before the token
    /// exists, which is the usual order: the app is built long before APNs answers.
    func attach(api: any StickerAPIClientProtocol) {
        self.api = api
        flush()
    }

    func received(deviceToken token: String) {
        // A reissued token invalidates whatever was registered under the old one.
        if token != deviceToken { registered = nil }
        deviceToken = token
        flush()
    }

    func failed(with error: Error) {
        // Not an error the user can act on — no notifications is the outcome, and the app works.
        Self.log.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }

    /// Signing out: drop this device from the account that is leaving, so its stickers stop
    /// announcing themselves on a phone the next person is holding.
    func signedOut() async {
        let api = api
        let token = deviceToken
        registered = nil
        work?.cancel()
        work = nil
        guard let api, let token else { return }
        try? await api.unregisterDevice(token: token)
    }

    private func flush() {
        guard let api, let deviceToken, registered != deviceToken, work == nil else { return }
        work = Task { [weak self] in
            defer { self?.work = nil }
            do {
                try await api.registerDevice(
                    token: deviceToken,
                    environment: PushEnvironment.current,
                    bundleID: Bundle.main.bundleIdentifier,
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                )
                self?.registered = deviceToken
            } catch {
                // The next launch asks APNs again and this runs again. A missed registration costs
                // notifications until then, and nothing else.
                Self.log.error("Device token registration failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// The only object iOS will hand an APNs device token to.
///
/// Kept to exactly that: SwiftUI owns the app's lifecycle, and everything this delegate learns is
/// forwarded straight into `PushDeviceRegistry` rather than acted on here.
final class PushApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in PushDeviceRegistry.shared.received(deviceToken: hex) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in PushDeviceRegistry.shared.failed(with: error) }
    }

    /// The server's silent "your pet moved" push, and the "your pet grew" banner that carries the same
    /// wake-up: long enough to redraw the widget and the watch.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        guard ["pet-status", "pet-evolved", "pet-encounter"].contains(userInfo["kind"] as? String) else { return .noData }
        return await PetCompanionSync.shared.refresh() ? .newData : .failed
    }
}
