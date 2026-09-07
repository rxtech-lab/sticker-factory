import Foundation
import SwiftUI
import Testing
@testable import StickerGeniOS

@Suite("Feature announcements")
@MainActor
struct FeatureAnnouncementTests {
    private func makeStore() -> (FeatureAnnouncementStore, UserDefaults) {
        let suite = "feature-cards-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (FeatureAnnouncementStore(defaults: defaults), defaults)
    }

    private func card(_ id: String) -> FeatureAnnouncement {
        .init(id: id, icon: "✦", accent: .red, title: id, message: id)
    }

    @Test("Shipped cards have stable, unique ids, and the messenger cards are among them")
    func shippedIDs() {
        let ids = FeatureAnnouncement.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains("whatsapp-sticker-import"))
        #expect(ids.contains("telegram-sticker-import"))
        #expect(ids.allSatisfy { !$0.isEmpty && $0 == $0.lowercased() && !$0.contains(" ") })
    }

    @Test("A fresh device has every card unread, and each acknowledgement removes one card only")
    func individualAcknowledgement() {
        let (store, _) = makeStore()
        let cards = [card("one"), card("two"), card("three")]
        #expect(store.unread(from: cards).map(\.id) == ["one", "two", "three"])

        store.markRead("one")
        #expect(store.unread(from: cards).map(\.id) == ["two", "three"])

        // An interrupted flow: "two" was never acknowledged, so it stays.
        store.markRead("three")
        #expect(store.unread(from: cards).map(\.id) == ["two"])

        store.markRead("one")
        #expect(store.readIDs == ["one", "three"])
    }

    @Test("A card appended later is new to a device that read everything before it")
    func appendedCard() {
        let (store, _) = makeStore()
        let original = [card("one"), card("two")]
        for card in original { store.markRead(card.id) }
        #expect(store.unread(from: original).isEmpty)

        let updated = original + [card("three")]
        #expect(store.unread(from: updated).map(\.id) == ["three"])
    }

    @Test("Read state lives in its own defaults key, untouched by other keys")
    func persistence() {
        let (store, defaults) = makeStore()
        store.markRead("one")
        #expect(defaults.stringArray(forKey: FeatureAnnouncementStore.readIDsKey) == ["one"])
        // Another store over the same defaults — a relaunch, or a different account — sees it.
        #expect(FeatureAnnouncementStore(defaults: defaults).readIDs == ["one"])
    }

    @Test("Presentation follows the welcome tour's automation rule")
    func presentationPolicy() {
        #expect(FeatureAnnouncementStore.shouldPresent(unreadCount: 2, isUITesting: false))
        #expect(!FeatureAnnouncementStore.shouldPresent(unreadCount: 0, isUITesting: false))
        #expect(!FeatureAnnouncementStore.shouldPresent(unreadCount: 2, isUITesting: true))
        #expect(FeatureAnnouncementStore.shouldPresent(unreadCount: 0, isUITesting: true, force: true))
    }
}
