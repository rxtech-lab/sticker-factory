import AnimatedView
import SwiftUI

/// The pet as it stands on its page: the pose it struck for its last interaction, or its sticker
/// until it has struck one, with a pose a touch struck drawn over it for a while. A new pose fades
/// in over the old one. Every so often, as often as its agent chose, the pet plays its own
/// animation in that pose.
struct PetCurrentPose: View {
    let model: PetModel
    let pet: Pet

    var body: some View {
        PetAnimatedPose(
            animation: model.touchPose ?? model.animation,
            interval: model.animationInterval,
            playRequest: model.brain.playRequest
        ) {
            ZStack {
                if let touchPose = model.touchPose {
                    AnimatedIconFrame(document: touchPose.document, time: 0, assets: touchPose.assets.dictionary)
                        .id(touchPose.key)
                        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)))
                } else if let pose = model.pose {
                    Image(uiImage: pose)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .id(model.poseKey)
                        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)))
                } else {
                    StickerThumbnail(sticker: pet.sticker, api: model.api, detail: .preview)
                        .transition(.opacity)
                }
            }
            .animation(.snappy(duration: 0.35), value: model.touchPose?.key ?? model.poseKey)
        }
    }
}
