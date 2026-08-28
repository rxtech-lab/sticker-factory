import Foundation
import Testing
@testable import AnimatedView

/// Guards the places that have to enumerate every channel by hand.
///
/// Most channel switches are exhaustive over `AnimationChannel` and the compiler catches an
/// omission. Three do not: the whole-track time transforms operate on nine arrays of nine different
/// element types, so they are written out longhand in `transformingEveryChannel`. Forgetting a
/// channel there is silent and nasty — a shortened document would keep keyframes past its own end
/// and fail validation with a message pointing somewhere else entirely.
struct ChannelCoverageTests {
    /// One keyframe on every channel, all at the same time so a transform is easy to check.
    private func animationWithEveryChannel(at time: Double) -> AnimatedLayerAnimation {
        AnimatedLayerAnimation(
            position: [.init(timeSeconds: time, x: 0.5, y: 0.5)],
            scale: [.init(timeSeconds: time, x: 1, y: 1)],
            rotation: [.init(timeSeconds: time, degrees: 0)],
            opacity: [.init(timeSeconds: time, value: 1)],
            effects: [.init(timeSeconds: time)],
            trim: [.init(timeSeconds: time)],
            wipe: [.init(timeSeconds: time)],
            sheen: [.init(timeSeconds: time)],
            glow: [.init(timeSeconds: time)]
        )
    }

    @Test func theFixtureItselfCoversEveryChannel() {
        // If this fails, `animationWithEveryChannel` is stale and the two tests below are quietly
        // checking fewer channels than they claim to.
        let animation = animationWithEveryChannel(at: 1)
        for channel in AnimationChannel.allCases {
            #expect(animation.count(of: channel) == 1, "\(channel.rawValue) is missing from the test fixture")
        }
        #expect(animation.keyframeCount == AnimationChannel.allCases.count)
    }

    @Test func rescalingTimesMovesEveryChannel() {
        let rescaled = animationWithEveryChannel(at: 2).rescalingTimes(by: 0.5)
        for channel in AnimationChannel.allCases {
            #expect(
                rescaled.times(on: channel) == [1],
                "\(channel.rawValue) was not rescaled — check transformingEveryChannel"
            )
        }
    }

    @Test func clampingTimesPullsEveryChannelInside() {
        let clamped = animationWithEveryChannel(at: 9).clampingTimes(to: 3)
        for channel in AnimationChannel.allCases {
            #expect(
                clamped.times(on: channel) == [3],
                "\(channel.rawValue) was not clamped — check transformingEveryChannel"
            )
        }
    }

    /// The wipe/sheen/glow channels have no anchor, exactly like effects, so a static bake drops
    /// them rather than folding them into a resting value.
    @Test func onlyTheAnchoredChannelsClaimToHaveAnchorValues() {
        #expect(AnimationChannel.allCases.filter(\.hasAnchorValue).map(\.rawValue).sorted()
            == ["opacity", "position", "rotation", "scale", "trim"])
    }

    /// Every channel needs a label and a symbol or the timeline draws a blank row.
    @Test func everyChannelIsPresentable() {
        for channel in AnimationChannel.allCases {
            #expect(!channel.label.isEmpty)
            #expect(!channel.symbolName.isEmpty)
        }
    }
}
