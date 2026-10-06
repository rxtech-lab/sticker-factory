import SwiftUI

/// Both positions use the same stage bounds, so choosing a side cannot change its own measurements.
nonisolated enum PetDialoguePlacement {
    case above, below

    var overlap: CGFloat { self == .above ? 44 : 18 }

    func petSide(in stage: CGSize, bubbleHeight: CGFloat) -> CGFloat {
        min(260, stage.width, max(0, stage.height - bubbleHeight + overlap))
    }

    func frames(in stage: CGRect, bubbleSize: CGSize) -> (pet: CGRect, bubble: CGRect) {
        let side = petSide(in: stage.size, bubbleHeight: bubbleSize.height)
        let top = stage.midY - (bubbleSize.height + side - overlap) / 2
        let bubbleY = self == .above ? top : top + side - overlap
        let petY = self == .above ? top + bubbleSize.height - overlap : top
        return (CGRect(x: stage.midX - side / 2, y: petY, width: side, height: side),
                CGRect(x: stage.midX - bubbleSize.width / 2, y: bubbleY,
                       width: bubbleSize.width, height: bubbleSize.height))
    }

    static func preferred(in stage: CGRect, bubbleSize: CGSize, avoiding obstacles: [CGRect]) -> Self {
        guard stage.width > 0, stage.height > 0, bubbleSize.height > 0 else { return .below }
        func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
        func score(_ placement: Self) -> CGFloat {
            let bubble = placement.frames(in: stage, bubbleSize: bubbleSize).bubble
            let clipped = area(bubble) - area(bubble.intersection(stage))
            return clipped * 4 + obstacles.reduce(0) { result, obstacle in
                result + area(bubble.intersection(obstacle.insetBy(dx: -8, dy: -8)))
            }
        }
        // Prefer below on ties, and ignore tiny differences near an obstacle's edge.
        return score(.above) + 64 < score(.below) ? .above : .below
    }
}

/// Keep the pose and thinking views alive when their positions swap.
struct PetDialogueLayout: Layout {
    let placement: PetDialoguePlacement

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 260
        let bubble = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: proposal.height ?? bubble.height + 260 - placement.overlap)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let size = subviews[1].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        let frames = placement.frames(in: bounds, bubbleSize: size)
        subviews[0].place(at: frames.pet.origin, anchor: .topLeading, proposal: ProposedViewSize(frames.pet.size))
        subviews[1].place(at: frames.bubble.origin, anchor: .topLeading, proposal: ProposedViewSize(frames.bubble.size))
    }
}
