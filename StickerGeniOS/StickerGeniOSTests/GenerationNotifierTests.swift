import Foundation
import Testing
@testable import StickerGeniOS

/// What is left on the client now that the banners are sent from the server: asking once, and
/// enrolling with APNs only when the answer was yes.
@Suite("Generation notifications")
@MainActor
struct GenerationNotifierTests {
    @Test("A granted permission enrols the device for push")
    func registersWhenAuthorized() async {
        var registrations = 0
        let notifier = GenerationNotifier(
            requestAuthorization: { true },
            registerForRemoteNotifications: { registrations += 1 }
        )

        notifier.prepare()
        await notifier.enrolment?.value

        #expect(registrations == 1)
    }

    /// A token minted for a user who said no is one the server would push into a void, and every
    /// send to it counts against the app's standing with APNs.
    @Test("A refused permission enrols nothing")
    func unauthorizedNeverRegisters() async {
        var registrations = 0
        let notifier = GenerationNotifier(
            requestAuthorization: { false },
            registerForRemoteNotifications: { registrations += 1 }
        )

        notifier.prepare()
        await notifier.enrolment?.value

        #expect(registrations == 0)
    }

    /// Permission is asked for once per launch, however many turns run. Without the shared task,
    /// a user who fires off three generations gets the ask three times over.
    @Test("Permission is asked for once, no matter how many turns run")
    func authorizationIsRequestedOnce() async {
        var requests = 0
        let notifier = GenerationNotifier(
            requestAuthorization: { requests += 1; return true },
            registerForRemoteNotifications: {}
        )

        notifier.prepare()
        await notifier.enrolment?.value
        notifier.prepare()
        await notifier.enrolment?.value

        #expect(requests == 1)
    }
}

/// The device token's path from the APNs callback to the server.
@Suite("Push device registration")
@MainActor
struct PushDeviceRegistryTests {
    @Test("A token that arrives before the client is uploaded once the client attaches")
    func uploadsWhenBothHaveArrived() async {
        let api = MockStickerAPIClient()
        let registry = PushDeviceRegistry()

        registry.received(deviceToken: "abc123")
        registry.attach(api: api)
        await registry.work?.value

        #expect(await api.registeredDeviceTokens == ["abc123"])
    }

    /// The app re-registers on every launch — iOS reissues tokens after a restore or an upgrade —
    /// so the unchanged case has to be free, or every launch is a needless write.
    @Test("The same token is not uploaded twice in a session")
    func uploadsEachTokenOnce() async {
        let api = MockStickerAPIClient()
        let registry = PushDeviceRegistry()

        registry.attach(api: api)
        registry.received(deviceToken: "abc123")
        await registry.work?.value
        registry.received(deviceToken: "abc123")
        await registry.work?.value

        #expect(await api.registeredDeviceTokens == ["abc123"])
    }

    @Test("A reissued token replaces the one already registered")
    func reissuedTokenIsUploaded() async {
        let api = MockStickerAPIClient()
        let registry = PushDeviceRegistry()

        registry.attach(api: api)
        registry.received(deviceToken: "abc123")
        await registry.work?.value
        registry.received(deviceToken: "def456")
        await registry.work?.value

        #expect(await api.registeredDeviceTokens == ["abc123", "def456"])
    }

    /// Otherwise the next person to hold the phone gets banners about someone else's stickers.
    @Test("Signing out drops the device from the account that is leaving")
    func signOutUnregisters() async {
        let api = MockStickerAPIClient()
        let registry = PushDeviceRegistry()

        registry.attach(api: api)
        registry.received(deviceToken: "abc123")
        await registry.work?.value
        await registry.signedOut()

        #expect(await api.registeredDeviceTokens.isEmpty)
    }
}
