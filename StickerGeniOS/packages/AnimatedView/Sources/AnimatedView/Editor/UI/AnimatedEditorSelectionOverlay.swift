#if os(iOS)
import SwiftUI

/// The outline around the selected layer.
///
/// Its transform chain mirrors `AnimatedIconFrame.layerView` exactly — scale, then rotate, then
/// position — because an outline that tracked the artwork only approximately would be worse than
/// none: it would make correct drags look like they had missed.
struct AnimatedEditorSelectionOverlay: View {
    let layer: AnimatedLayer
    let state: AnimatedLayerState
    let canvasSize: CGSize

    private var box: CGSize {
        AnimatedCanvasGeometry.layoutBox(canvasSize: canvasSize, isParticle: layer.type == .particle)
    }

    private var scale: AnimatedPoint {
        AnimatedCanvasGeometry.renderedScale(state.scale, isText: layer.isText)
    }

    /// Whether the corners are far enough apart to be told apart. Asked of the same function the
    /// stage's drag uses, so a handle is drawn exactly when it can be grabbed.
    private var showsHandles: Bool {
        AnimatedCanvasGeometry.handlesAreGrabbable(
            layer: layer,
            state: state,
            in: CGRect(origin: .zero, size: canvasSize)
        )
    }

    var body: some View {
        Rectangle()
            .strokeBorder(.tint, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .overlay(alignment: .topLeading) { handle }
            .overlay(alignment: .topTrailing) { handle }
            .overlay(alignment: .bottomLeading) { handle }
            .overlay(alignment: .bottomTrailing) { handle }
            .frame(width: box.width, height: box.height)
            .scaleEffect(x: scale.x, y: scale.y)
            .rotationEffect(.degrees(state.rotationDegrees))
            .position(
                x: state.position.x * canvasSize.width,
                y: state.position.y * canvasSize.height
            )
            // The outline is a chrome affordance, not artwork: it must never intercept the taps and
            // drags meant for the layer underneath it.
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// A corner grip, counter-scaled so it stays the same size on screen.
    ///
    /// Without the inverse scale a layer at 8× would show enormous handles and one at 0.05× would
    /// show invisible ones, since the whole overlay is inside the `scaleEffect`.
    ///
    /// Drawn as a filled disc rather than the flush square it used to be: these are draggable now,
    /// and something you are meant to grab should not look like a corner tick mark.
    @ViewBuilder
    private var handle: some View {
        if showsHandles {
            Circle()
                .fill(.background)
                .overlay { Circle().strokeBorder(.tint, lineWidth: 2.5) }
                .frame(width: 13, height: 13)
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                // A circle is rotation-invariant, so undoing the overlay's scale is enough to keep
                // the grip the same size on screen at any zoom.
                .scaleEffect(x: 1 / max(abs(scale.x), 0.01), y: 1 / max(abs(scale.y), 0.01))
        }
    }
}

/// A caption naming what the next gesture will touch, shown under the stage.
///
/// The same drag can move an anchor, edit an existing keyframe, or create a new one depending on
/// the channel and where the playhead is. Without saying which, the behaviour reads as arbitrary.
struct AnimatedEditTargetCaption: View {
    let editor: AnimatedDocumentEditor
    var channel: AnimationChannel = .position

    var body: some View {
        if let layer = editor.selectedLayer,
           let target = editor.editTarget(for: channel) {
            Label {
                Text(AnimatedEditTargetResolver.caption(
                    for: target,
                    channel: channel,
                    total: layer.animation.count(of: channel)
                ))
            } icon: {
                Image(systemName: symbol(for: target))
            }
            .font(.caption)
            .foregroundStyle(target.isEditable ? .secondary : Color.orange)
        }
    }

    private func symbol(for target: AnimatedEditTarget) -> String {
        switch target {
        case .anchor: "scope"
        case .keyframe: "diamond.fill"
        case .newKeyframe: "diamond"
        case .blockedByDeclarative: "wand.and.stars"
        }
    }
}
#endif
