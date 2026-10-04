import Foundation
import UIKit
import UserNotifications

/// The notification API predates Swift concurrency, so its completion closure is not annotated
/// `Sendable`. This box documents the single transfer to MainActor that UIKit requires.
private nonisolated final class NotificationResponseCompletion: @unchecked Sendable {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    func callAsFunction() {
        handler()
    }
}

/// Permission, APNs enrolment, and what a tapped banner opens.
///
/// The banners themselves are the server's to send. Generation runs there, and the client's event
/// stream is gone the moment iOS suspends the app — which is exactly the moment a "your sticker is
/// ready" banner is worth having. A local notification could only ever fire for a turn the app was
/// still awake to watch, so what is left on this side is the three things only the app can do: ask
/// for permission at a moment that explains itself, hand APNs a device token, and route a tap.
///
/// The system pieces are injected so the policy can be tested without a device or a permission
/// prompt; nothing in the app passes them.
@MainActor
protocol GenerationNotifying: AnyObject {
    /// Called when a turn starts. Asking for permission here — rather than at launch — means the
    /// prompt arrives with an answer to "why?" already on screen: something is generating.
    func prepare()
}

@MainActor
final class GenerationNotifier: NSObject, GenerationNotifying {
    /// Set by `AppEnvironment` so tapping a banner lands on the sticker it is about.
    var onOpenSticker: (@MainActor (String) -> Void)?
    /// Set by `AppEnvironment` so tapping a "your pet grew" banner lands on the Pet tab.
    var onOpenPet: (@MainActor () -> Void)?

    /// Read back from `userInfo` on the delegate's queue, so it cannot be actor-isolated. The
    /// server writes the same key into every generation push.
    nonisolated static let stickerIDKey = "stickerID"

    private let requestAuthorization: @MainActor () async -> Bool
    private let registerForRemoteNotifications: @MainActor () -> Void
    /// The one authorization request, shared by every caller that arrives while it is still open.
    private var authorization: Task<Bool, Never>?
    /// The enrolment in flight. Nothing in the app reads it; it exists so a test can wait for a
    /// registration that has to clear an authorization check first.
    private(set) var enrolment: Task<Void, Never>?

    init(
        requestAuthorization: @escaping @MainActor () async -> Bool = GenerationNotifier.requestSystemAuthorization,
        registerForRemoteNotifications: @escaping @MainActor () -> Void = { UIApplication.shared.registerForRemoteNotifications() }
    ) {
        self.requestAuthorization = requestAuthorization
        self.registerForRemoteNotifications = registerForRemoteNotifications
    }

    /// Builds the notifier the app runs with and hands it to the system as the delegate, which has
    /// to happen before launch finishes for a tap on a banner to survive a cold start.
    static func live() -> GenerationNotifier {
        let notifier = GenerationNotifier()
        UNUserNotificationCenter.current().delegate = notifier
        return notifier
    }

    /// Asks once, then enrols with APNs so the server has somewhere to send.
    ///
    /// Registration is deliberately gated on the answer: asking APNs for a token the user has said
    /// no to earns one the server would push into a void, and re-registering every launch is what
    /// keeps a token reissued by a restore or an OS upgrade from going stale unnoticed.
    func prepare() {
        guard authorization == nil else { return }
        let authorization = Task { await self.requestAuthorization() }
        self.authorization = authorization
        enrolment = Task {
            guard await authorization.value else { return }
            self.registerForRemoteNotifications()
        }
    }

    private static func requestSystemAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        // Re-asking after an answer re-prompts nobody — the system returns the standing decision —
        // but reading it first keeps a denied install from looking like a fresh ask every launch.
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        default: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
    }
}

extension GenerationNotifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Read the payload out here: `userInfo` is not `Sendable`, but the id inside it is.
        let stickerID = response.notification.request.content.userInfo[Self.stickerIDKey] as? String
        let isPet = response.notification.request.content.userInfo["kind"] as? String == "pet-evolved"
        let completion = NotificationResponseCompletion(completionHandler)
        Task { @MainActor [weak self] in
            if isPet { self?.onOpenPet?() } else if let stickerID { self?.onOpenSticker?(stickerID) }
            // UIKit continues launch/background state restoration from this callback. The async
            // protocol witness can resume it on a cooperative-pool thread, which trips UIKit's
            // main-thread assertion when a banner is tapped. Finish explicitly on MainActor.
            completion()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // The chat screen already shows the candidate, the failure, and the retry button. A banner
        // over the thing it is announcing is noise — so a push that arrives while the app is in
        // front is swallowed. This is the whole of the "don't interrupt what they're watching" rule
        // now that the sending happens on the server, which cannot know what is on screen.
        []
    }
}
