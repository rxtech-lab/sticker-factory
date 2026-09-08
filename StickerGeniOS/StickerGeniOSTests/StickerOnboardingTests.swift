import Testing
@testable import StickerGeniOS

@Suite("Sticker onboarding")
@MainActor
struct StickerOnboardingTests {
    @Test("First launch presents welcome outside UI automation")
    func welcomePresentationPolicy() {
        #expect(StickerOnboarding.shouldPresentWelcome(hasSeenWelcome: false, isUITesting: false))
        #expect(!StickerOnboarding.shouldPresentWelcome(hasSeenWelcome: true, isUITesting: false))
        #expect(!StickerOnboarding.shouldPresentWelcome(hasSeenWelcome: false, isUITesting: true))
        #expect(StickerOnboarding.shouldPresentWelcome(
            hasSeenWelcome: true,
            isUITesting: true,
            forceWelcome: true
        ))
    }

    @Test("Welcome covers the complete sticker workflow")
    func completeWorkflow() {
        #expect(StickerOnboarding.slides.map(\.id) == [
            "welcome",
            "generate",
            "confirm",
            "versions",
            "publish",
            "use"
        ])
    }
}
