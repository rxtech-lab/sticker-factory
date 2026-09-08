import SwiftUI

/// Turns the wipe and sheen channel states into the gradients that draw them.
///
/// Kept apart from `AnimatedIconFrame` because the stop maths is fiddly, order-sensitive and worth
/// testing on its own: SwiftUI silently misbehaves on unsorted or out-of-range stop locations, and
/// an inverted window has to read as "hidden" rather than as a gradient running backwards.
enum SweepGeometry {
    /// Gradient stops for a wipe mask: opaque inside the window, clear outside, `softness` wide
    /// ramps at both edges.
    ///
    /// A mask reads its gradient's *alpha*, so white is "show" and clear is "hide".
    static func wipeStops(_ wipe: AnimatedWipe) -> [Gradient.Stop] {
        // A window that has closed past itself shows nothing. Without this the sorting below would
        // quietly reorder the edges and reveal the complement of what was asked for.
        guard !wipe.isEmptyWindow else { return [.init(color: .clear, location: 0), .init(color: .clear, location: 1)] }

        // Half the softness on each side of each edge, so `softness` is the total ramp width and a
        // hard edge (0) puts two stops on the same location — which SwiftUI renders as a clean cut.
        let feather = wipe.softness / 2
        let stops: [(Color, Double)] = [
            (.clear, wipe.start - feather),
            (.white, wipe.start + feather),
            (.white, wipe.end - feather),
            (.clear, wipe.end + feather)
        ]
        return normalised(stops)
    }

    /// Gradient stops for the sheen band: a white core fading to clear at `width / 2` either side.
    ///
    /// Returns `nil` when the band contributes nothing, so the renderer can skip the overlay
    /// entirely rather than compositing a fully transparent layer over every frame.
    static func sheenStops(_ sheen: AnimatedSheen) -> [Gradient.Stop]? {
        guard !sheen.isIdentity else { return nil }
        let half = sheen.width / 2
        let stops: [(Color, Double)] = [
            (.white.opacity(0), sheen.position - half),
            (.white.opacity(sheen.intensity), sheen.position),
            (.white.opacity(0), sheen.position + half)
        ]
        return normalised(stops)
    }

    /// Clamps stop locations into `0...1` and re-sorts.
    ///
    /// Both halves are load-bearing. Locations routinely fall outside the unit range — a sheen band
    /// starts fully off-canvas by construction, and a wipe at `start == 0` with any softness feathers
    /// to a negative location — and SwiftUI does not clamp them for you. Clamping alone is not
    /// enough either: it can collapse two stops onto one location and leave them in an order that no
    /// longer ascends, which renders as a hard reversal.
    private static func normalised(_ stops: [(Color, Double)]) -> [Gradient.Stop] {
        stops
            .map { ($0.0, min(max($0.1, 0), 1)) }
            .sorted { $0.1 < $1.1 }
            .map { Gradient.Stop(color: $0.0, location: $0.1) }
    }
}

extension View {
    /// Applies a layer's wipe, sheen and glow.
    ///
    /// All three live here rather than in `AnimatedIconFrame.layerView` because they belong in the
    /// layer's own coordinate space: `rotationEffect` does not change layout bounds, so a mask
    /// applied after it would wipe along the canvas axis instead of the artwork's. Attaching them to
    /// the content also means the wipe mask *chains* with an image layer's `maskAssetId` mask rather
    /// than replacing it — two `mask` modifiers multiply.
    @ViewBuilder
    func animatedSweeps(_ state: AnimatedLayerState, boxWidth: CGFloat) -> some View {
        if state.wipe.isIdentity, state.sheen.isIdentity, state.glow.isIdentity {
            // The overwhelmingly common case. Returning the content untouched keeps every existing
            // document off the offscreen-compositing path an unconditional group would force.
            self
        } else {
            ZStack {
                self
                if !state.glow.isIdentity {
                    // Bloom is `original + blurred`, so the halo goes *over* the crisp content, not
                    // under it. Two reasons it has to be this way round: an additive layer at the
                    // bottom of the group has nothing but empty backdrop to add to, and adding the
                    // blur on top is what blows out the artwork's own highlights the way a real
                    // bloom does. Outside the silhouette it adds to transparency, which is the halo.
                    //
                    // `opacity` before `blendMode`, never after: trailing opacity wraps the view in
                    // its own transparency layer and the blend then applies inside that layer
                    // instead of against the content below, which silently renders nothing at all.
                    self
                        .blur(radius: state.glow.radius * boxWidth)
                        .opacity(state.glow.amount)
                        .blendMode(.plusLighter)
                }
                if let stops = SweepGeometry.sheenStops(state.sheen) {
                    LinearGradient(
                        gradient: Gradient(stops: stops),
                        startPoint: AnimatedPaint.sweepUnitPoint(forAngle: state.sheen.angleDegrees, start: true),
                        endPoint: AnimatedPaint.sweepUnitPoint(forAngle: state.sheen.angleDegrees, start: false)
                    )
                    // `sourceAtop` clips to what is already drawn, so the highlight lands on the
                    // artwork and not on the empty space around it — and unlike masking with a
                    // second copy of the content, it costs no extra render. Particles and SVGs are
                    // expensive enough that drawing them twice for a glint is not worth it.
                    .blendMode(.sourceAtop)
                }
            }
            // Mandatory, not tidiness. Most layers carry `blendMode(.normal)`, which creates no
            // compositing group, so `plusLighter` and `sourceAtop` would otherwise blend against the
            // background and every layer underneath this one.
            //
            // `compositingGroup`, never `drawingGroup`: the latter is Metal-backed and the exporter
            // rasterises this very view through `ImageRenderer`, which is what guarantees the export
            // matches the preview.
            .compositingGroup()
            .animatedWipeMask(state.wipe)
        }
    }

    /// Applies the wipe mask, or nothing at all when there is no wipe.
    ///
    /// Skipping the modifier entirely matters, and `mask { Rectangle() }` is not an equivalent
    /// no-op: a mask clips to the *view's own bounds*, and a bloom halo is precisely the part of the
    /// drawing that extends beyond them. Masking unconditionally silently shaved the halo off and
    /// left the layer pixel-identical to an un-bloomed one.
    ///
    /// The corollary is that a layer which *is* wiping has its halo clipped to the layer box. That
    /// is the right trade — a wipe is a hard statement about what is visible — but it does mean a
    /// bloom reads slightly tighter while a wipe is running.
    @ViewBuilder
    fileprivate func animatedWipeMask(_ wipe: AnimatedWipe) -> some View {
        if wipe.isIdentity {
            self
        } else {
            mask {
                LinearGradient(
                    gradient: Gradient(stops: SweepGeometry.wipeStops(wipe)),
                    startPoint: AnimatedPaint.sweepUnitPoint(forAngle: wipe.angleDegrees, start: true),
                    endPoint: AnimatedPaint.sweepUnitPoint(forAngle: wipe.angleDegrees, start: false)
                )
            }
        }
    }
}
