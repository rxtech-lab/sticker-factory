import Foundation
import Testing
@testable import StickerGeniOS

@Suite("Streaming haptics")
@MainActor
struct StreamHapticsTests {
    /// The throttle is the whole point of the type: a streamed reply arrives in chunks whose size
    /// and spacing are decided by the model and the network, and one tick per chunk is a buzz.
    @Test("A streamed reply ticks on accumulated text, held apart in time")
    func ticksAreRateLimited() {
        var instant = Date(timeIntervalSince1970: 1_000)
        var ticks = 0
        let haptics = StreamHaptics(now: { instant }, tick: { ticks += 1 })

        haptics.typed(characterCount: 4)
        #expect(ticks == 0, "A few characters is not yet a tick")

        haptics.typed(characterCount: 20)
        #expect(ticks == 1)

        haptics.typed(characterCount: 40)
        #expect(ticks == 1, "Enough new text, but too soon after the last tick")

        instant += 0.2
        haptics.typed(characterCount: 40)
        #expect(ticks == 2)

        // A refetch replacing the streamed text with the server's shorter canonical copy is not
        // the user backspacing, and must not tick its way back up to where it already was.
        instant += 1
        haptics.typed(characterCount: 5)
        #expect(ticks == 2)

        instant += 1
        haptics.typed(characterCount: 18)
        #expect(ticks == 3)
    }

    @Test("A new turn is measured from zero, not from the length of the last reply")
    func newTurnResetsTheBaseline() {
        var instant = Date(timeIntervalSince1970: 1_000)
        var ticks = 0
        let haptics = StreamHaptics(now: { instant }, tick: { ticks += 1 })

        haptics.typed(characterCount: 400)
        #expect(ticks == 1)

        haptics.beginTurn()
        instant += 1
        haptics.typed(characterCount: 12)
        #expect(ticks == 2, "The opening of the next reply must be felt too")
    }
}
