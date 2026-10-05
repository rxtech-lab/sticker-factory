import AnimatedView
import SwiftUI

/// The pet's sticker resolved in the pose it holds now, with the artwork to draw it.
struct PetAnimation {
    /// Names the pose this was resolved for: `PetSnapshot.poseKey`.
    var key: String
    var stickerID: String
    var document: AnimatedDocument
    var assets: StickerRenderAssets
}

/// Shows `still` and, every `interval`, plays the pet's own animation through once over it.
///
/// The pet's agent picks the interval with each pose, so a lively pet moves often and a sleepy
/// one rarely. Nothing plays while the app is in the background or with Reduce Motion on, and a new
/// pose or interval starts the wait again.
struct PetAnimatedPose<Still: View>: View {
    let animation: PetAnimation?
    let interval: Duration
    /// Plays the animation once right away each time it changes, then goes back to waiting.
    var playRequest = 0
    @ViewBuilder var still: Still

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// Which play is on screen, so each starts from its first frame. Nil while holding still.
    @State private var play: Int?
    /// The `playRequest` already played, so only a new one plays at once.
    @State private var playedRequest = 0
    /// How long a newly loaded pose holds still before it first plays.
    private static var firstPlayDelay: Duration { .seconds(2) }

    private struct Schedule: Equatable {
        var key: String?
        var interval: Duration
        var isActive: Bool
        var playRequest: Int
    }

    var body: some View {
        ZStack {
            still
                .opacity(play == nil ? 1 : 0)
            if let animation, let play {
                AnimatedIconView(document: animation.document, assets: animation.assets.dictionary)
                    .id(play)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: play)
        .task(id: Schedule(
            key: animation?.key,
            interval: interval,
            isActive: scenePhase == .active && !reduceMotion,
            playRequest: playRequest
        )) {
            await playPeriodically()
        }
    }

    private func playPeriodically() async {
        play = nil
        let isRequested = playRequest != playedRequest
        playedRequest = playRequest
        guard let animation, scenePhase == .active, !reduceMotion else { return }
        let cycle = animation.document.renderedCycleDuration
        guard cycle > 0 else { return }
        var count = 0
        while true {
            // A new pose shows itself moving almost at once; after that the agent's interval holds.
            if count > 0 || !isRequested {
                do { try await Task.sleep(for: count == 0 ? min(interval, Self.firstPlayDelay) : interval) } catch { return }
            }
            count += 1
            play = count
            do { try await Task.sleep(for: .seconds(cycle)) } catch { return }
            play = nil
        }
    }
}
