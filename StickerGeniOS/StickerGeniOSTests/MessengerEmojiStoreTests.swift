import Foundation
import Testing
@testable import StickerGeniOS

@Suite("Messenger emoji store")
@MainActor
struct MessengerEmojiStoreTests {
    private func makeStore() -> MessengerEmojiStore {
        let suite = "messenger-emoji-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return MessengerEmojiStore(defaults: defaults)
    }

    @Test("Every sticker starts on the default emoji and remembers its own")
    func defaultsAndPersistence() {
        let store = makeStore()
        #expect(store.emoji(for: "a") == "🙂")
        store.setEmoji("🐱", for: "a")
        #expect(store.emoji(for: "a") == "🐱")
        #expect(store.emoji(for: "b") == "🙂")
        store.setEmoji("", for: "a")
        #expect(store.emoji(for: "a") == "🙂")
    }

    /// Three sources, in order. The creator's choice travels with the pack, so a sticker installed
    /// from someone else arrives labelled the way they labelled it — but a reader who picks their
    /// own emoji here still wins on their own phone.
    @Test("A device choice overrides the creator's, which overrides the default")
    func resolutionOrder() {
        let store = makeStore()
        let plain = PreviewFixtures.sticker
        var labelled = plain
        labelled.messengerEmoji = "🐱"

        #expect(store.emoji(for: plain) == "🙂")
        #expect(store.emoji(for: labelled) == "🐱")

        store.setEmoji("🐶", for: labelled.id)
        #expect(store.emoji(for: labelled) == "🐶")

        // Clearing the device choice falls back to the creator's rather than to the default.
        store.setEmoji("", for: labelled.id)
        #expect(store.emoji(for: labelled) == "🐱")
    }

    @Test("A creator's emoji is held to the same one-emoji rule as a typed one")
    func creatorEmojiIsValidated() {
        let store = makeStore()
        var sticker = PreviewFixtures.sticker
        sticker.messengerEmoji = "not an emoji"
        #expect(store.emoji(for: sticker) == "🙂")
    }

    @Test("storedEmoji reports nothing when this device has made no choice")
    func storedEmojiIsNilByDefault() {
        let store = makeStore()
        #expect(store.storedEmoji(for: "a") == nil)
        store.setEmoji("🐱", for: "a")
        #expect(store.storedEmoji(for: "a") == "🐱")
    }

    @Test("Only the first emoji of whatever was typed is kept")
    func singleEmoji() {
        #expect(MessengerEmojiStore.singleEmoji("🐱🐶") == "🐱")
        #expect(MessengerEmojiStore.singleEmoji("hello 👋🏽 there") == "👋🏽")
        #expect(MessengerEmojiStore.singleEmoji("👨‍👩‍👧") == "👨‍👩‍👧")
        #expect(MessengerEmojiStore.singleEmoji("abc") == nil)
        #expect(MessengerEmojiStore.singleEmoji("") == nil)
        #expect(MessengerEmojiStore.singleEmoji("1") == nil)
    }
}
