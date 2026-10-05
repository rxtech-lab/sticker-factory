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

struct PetItemPresentation: ViewModifier {
    let item: PetModel.UsedItem?
    let isVisible: Bool

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if let item, isVisible {
                    PetUsedItemOverlay(item: item)
                        .id(item.id)
                        .offset(x: 12, y: -12)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: item?.id)
    }
}

/// The selected object floats beside the pet while it reacts, without covering its dialogue.
struct PetUsedItemOverlay: View {
    let item: PetModel.UsedItem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasArrived = false
    @State private var startedAt = Date.now

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let wave = reduceMotion ? 0 : sin(context.date.timeIntervalSince(startedAt) * .pi * 2 / 1.4)
            ZStack {
                Group {
                    if let image = item.image {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else {
                        Image(systemName: "shippingbox.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(AppColors.ink)
                    }
                }
                .frame(width: 88, height: 88)
                .rotationEffect(.degrees(wave * 8))
                .scaleEffect(1 + wave * 0.05)
                .offset(y: wave * -6)
                .shadow(color: .black.opacity(0.12), radius: 5, y: 4)

                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.yellow)
                    .scaleEffect(1 + wave * 0.15)
                    .opacity(0.7 + wave * 0.25)
                    .offset(x: -38, y: -36)
            }
            .frame(width: 104, height: 104)
            .scaleEffect(hasArrived || reduceMotion ? 1 : 0.35)
            .offset(x: hasArrived || reduceMotion ? 0 : 32, y: hasArrived || reduceMotion ? 0 : 20)
            .opacity(hasArrived ? 1 : 0)
        }
        .allowsHitTesting(false)
        .accessibilityLabel(Text(item.title))
        .accessibilityIdentifier("pet-used-item")
        .task {
            // Let the sheet finish closing before the object arrives beside the pet.
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            startedAt = .now
            withAnimation(reduceMotion ? .easeIn(duration: 0.2) : .spring(duration: 0.5, bounce: 0.35)) {
                hasArrived = true
            }
            Haptics.tap(.soft)
        }
    }
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
