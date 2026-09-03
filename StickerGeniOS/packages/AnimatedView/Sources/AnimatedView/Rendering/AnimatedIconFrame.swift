import SwiftUI

/// One deterministic frame of a document.
///
/// A pure function of `(document, time, assets)`. Nothing here reads the clock, and nothing is
/// randomised — that is what lets the exporter rasterise frames off-screen and get pixels identical
/// to what the player showed. `AnimatedIconView` is just this view driven by a `TimelineView`.
public struct AnimatedIconFrame: View {
    /// The box every layer's content is fitted into before its own scale is applied.
    ///
    /// One factor for all layer kinds, so a layer's `scale` means the same thing whether it is an
    /// image, a glyph, a shape, or an SVG. Anything that lays out or previews a document — a plan
    /// card's schematic, a server-side layout check — has to use this same number or the preview
    /// and the render disagree.
    /// `nonisolated` so the editor's pure geometry — which must compile and be tested off the main
    /// actor — can share this exact number rather than keeping a second copy of it that could drift.
    public nonisolated static let layerFit: CGFloat = 0.86

    public var document: AnimatedDocument
    /// Wall-clock seconds since playback started. Loop mapping and `speed` are applied internally.
    public var time: Double
    public var assets: any AnimatedAssetProvider

    /// Set when the caller already holds a position inside the authored timeline, bypassing
    /// `mappedTime`. See ``init(document:documentTime:assets:)``.
    private var resolvedDocumentTime: Double?

    public init(document: AnimatedDocument, time: Double, assets: any AnimatedAssetProvider = EmptyAnimatedAssets()) {
        self.document = document
        self.time = time
        self.assets = assets
        self.resolvedDocumentTime = nil
    }

    /// Renders one explicit instant of the *authored* timeline.
    ///
    /// The difference from `init(document:time:)` matters as soon as `speed` is not 1.
    /// `AnimationInterpolator.mappedTime` multiplies wall-clock time by `speed` on the way in, so a
    /// caller holding a document time — an editor playhead, a keyframe's `timeSeconds`, a filmstrip
    /// tick — would have it scaled a second time and land on the wrong frame.
    ///
    /// `documentTime` is used verbatim: no `speed`, no loop wrapping. Anything outside
    /// `0...durationSeconds` simply clamps to the nearest keyframe, the way the interpolator
    /// already treats times beyond the ends of a channel.
    public init(
        document: AnimatedDocument,
        documentTime: Double,
        assets: any AnimatedAssetProvider = EmptyAnimatedAssets()
    ) {
        self.document = document
        self.time = documentTime
        self.assets = assets
        self.resolvedDocumentTime = documentTime
    }

    /// The instant this frame samples, after whichever time convention it was built with.
    /// Internal rather than private so tests can pin down that the two initialisers differ exactly
    /// where they should.
    var documentTime: Double {
        resolvedDocumentTime ?? AnimationInterpolator.mappedTime(time, document: document)
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                AnimatedBackgroundView(background: document.background, assets: assets)
                ForEach(document.layers) { layer in
                    if !layer.hidden {
                        layerView(layer, canvasSize: geometry.size)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .aspectRatio(document.canvas.aspectRatio, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Animated icon")
    }

    @ViewBuilder
    private func layerView(_ layer: AnimatedLayer, canvasSize: CGSize) -> some View {
        let state = AnimationInterpolator.state(for: layer, atDocumentTime: documentTime)
        // Glyphs are fitted, never stretched. Squashing a photo is a legitimate effect; squashing
        // letters just looks broken, and a per-element layout naturally asks for a narrow slot and a
        // tall one, which non-uniform scaling would render as slivers.
        let scale = layer.isText
            ? CGSize(width: min(state.scale.x, state.scale.y), height: min(state.scale.x, state.scale.y))
            : CGSize(width: state.scale.x, height: state.scale.y)

        layerContent(layer, state: state, canvasSize: canvasSize)
            .scaleEffect(x: scale.width, y: scale.height)
            .rotationEffect(.degrees(state.rotationDegrees))
            .opacity(state.opacity)
            .blur(radius: state.effects.blurRadius)
            .hueRotation(.degrees(state.effects.hueDegrees))
            .saturation(state.effects.saturation)
            .blendMode(layer.blendMode.swiftUI)
            .position(
                x: state.position.x * canvasSize.width,
                y: state.position.y * canvasSize.height
            )
    }

    @ViewBuilder
    private func layerContent(_ layer: AnimatedLayer, state: AnimatedLayerState, canvasSize: CGSize) -> some View {
        let box = CGSize(width: canvasSize.width * Self.layerFit, height: canvasSize.height * Self.layerFit)
        // Wipe, sheen and glow wrap the artwork itself rather than the transformed layer, so they
        // are expressed in the layer's own coordinates. Every layer kind gets them, including images
        // and text, which `trim` can never reach.
        //
        // Two caveats worth knowing rather than working around: a text layer is framed to the whole
        // box regardless of how wide the glyphs actually are, so a wipe across a short centred word
        // appears to start late; and a particle layer is framed to the canvas rather than the box,
        // so its wipe spans a slightly different extent than every other kind's.
        Group {
            switch layer {
            case .image(let imageLayer):
                imageContent(imageLayer, box: box)
            case .text(let textLayer):
                textContent(textLayer, box: box)
            case .shape(let shapeLayer):
                shapeContent(shapeLayer, state: state, box: box)
            case .svg(let svgLayer):
                svgContent(svgLayer, state: state, box: box)
            case .particle(let particleLayer):
                ParticleCanvas(
                    layer: particleLayer,
                    time: documentTime,
                    duration: max(document.durationSeconds, 1)
                )
                .frame(width: canvasSize.width, height: canvasSize.height)
            case .sequence(let sequenceLayer):
                sequenceContent(sequenceLayer, box: box)
            case .video(let videoLayer):
                videoContent(videoLayer, box: box)
            case .unsupported:
                // Drawn as nothing rather than as a placeholder: the layer came from a newer build
                // and we have no idea how large it is meant to be, so inventing a box in the middle
                // of the canvas would misrepresent the sticker worse than omitting it. The editor
                // reports it as a blocking issue, which is where the user should hear about it.
                EmptyView()
            }
        }
        .animatedSweeps(state, boxWidth: box.width)
    }

    @ViewBuilder
    private func imageContent(_ layer: AnimatedImageLayer, box: CGSize) -> some View {
        if let image = assets.image(for: layer.assetId) {
            Image(platformImage: image)
                .resizable()
                .aspectRatio(contentMode: layer.contentMode == .fit ? .fit : .fill)
                .frame(width: box.width, height: box.height)
                .clipped()
                .mask {
                    if let maskID = layer.maskAssetId, let mask = assets.image(for: maskID) {
                        Image(platformImage: mask).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Rectangle()
                    }
                }
        } else {
            // A deterministic placeholder rather than nothing, so a document whose assets have not
            // loaded still lays out at the right size and the layer stays visible while it fetches.
            RoundedRectangle(cornerRadius: box.width * 0.12, style: .continuous)
                .fill(.purple.gradient)
                .overlay {
                    AnimatedCartoonSymbol("wand.and.stars")
                        .font(.system(size: box.width * 0.28, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: box.width * 0.74, height: box.height * 0.74)
        }
    }

    @ViewBuilder
    private func sequenceContent(_ layer: AnimatedSequenceLayer, box: CGSize) -> some View {
        // `documentTime` is what the whole timing design hangs on: it already has `speed` and the
        // document's loop folded in, so the footage inherits both for free. See
        // `AnimationInterpolator.sequenceFrameIndex`.
        let index = AnimationInterpolator.sequenceFrameIndex(layer, atDocumentTime: documentTime)
        if let tile = FrameAtlasCache.shared.tile(for: layer, index: index, assets: assets) {
            Image(platformImage: tile)
                .resizable()
                .aspectRatio(contentMode: layer.contentMode == .fit ? .fit : .fill)
                .frame(width: box.width, height: box.height)
                .clipped()
        } else {
            // The same placeholder an image layer uses, for the same reason: a layer whose asset has
            // not loaded should still lay out at the right size and stay visible while it fetches.
            RoundedRectangle(cornerRadius: box.width * 0.12, style: .continuous)
                .fill(.purple.gradient)
                .overlay {
                    AnimatedCartoonSymbol("livephoto")
                        .font(.system(size: box.width * 0.28, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: box.width * 0.74, height: box.height * 0.74)
        }
    }

    @ViewBuilder
    private func videoContent(_ layer: AnimatedVideoLayer, box: CGSize) -> some View {
        let index = AnimationInterpolator.videoFrameIndex(layer, atDocumentTime: documentTime)
        if let frame = VideoFrameCache.shared.frame(for: layer, index: index, assets: assets) {
            Image(platformImage: frame)
                .resizable()
                .aspectRatio(contentMode: layer.contentMode == .fit ? .fit : .fill)
                .frame(width: box.width, height: box.height)
                .clipped()
        } else if let poster = assets.image(for: layer.posterAssetId) {
            // The still the clip was animated from, while the clip itself downloads and decodes.
            // Not a placeholder: it is the exact subject at the exact size, so the layout is right
            // and only the motion is missing.
            Image(platformImage: poster)
                .resizable()
                .aspectRatio(contentMode: layer.contentMode == .fit ? .fit : .fill)
                .frame(width: box.width, height: box.height)
                .clipped()
        } else {
            RoundedRectangle(cornerRadius: box.width * 0.12, style: .continuous)
                .fill(.purple.gradient)
                .overlay {
                    AnimatedCartoonSymbol("video")
                        .font(.system(size: box.width * 0.28, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: box.width * 0.74, height: box.height * 0.74)
        }
    }

    private func textContent(_ layer: AnimatedTextLayer, box: CGSize) -> some View {
        // Sized to fill the same base box as every other layer kind rather than pinned to a fixed
        // font size, so `scale` means the same thing for text as for an image. The huge base size
        // never renders as-is; `minimumScaleFactor` shrinks it to the box.
        Text(layer.text)
            .font(font(layer, box: box))
            .foregroundStyle(layer.paint.shapeStyle)
            .multilineTextAlignment(textAlignment(layer.alignment))
            .lineLimit(3)
            .minimumScaleFactor(0.01)
            .frame(width: box.width, height: box.height)
    }

    @ViewBuilder
    private func shapeContent(_ layer: AnimatedShapeLayer, state: AnimatedLayerState, box: CGSize) -> some View {
        let resolved = AnimatedShape(
            kind: layer.shape,
            cornerRadius: layer.cornerRadius,
            customPath: customPath(for: layer.shape)
        )
        let coverage = max(0, state.trim.end - state.trim.start)
        ZStack {
            if let fill = layer.fill {
                // Trimming a fill would carve a partial blob out of the shape; trim belongs to the
                // outline. The fill instead arrives with the stroke, which is what a draw-on reads as.
                resolved.fill(fill.shapeStyle).opacity(coverage)
            }
            if let stroke = layer.stroke {
                resolved
                    .trim(from: state.trim.start, to: state.trim.end)
                    .stroke(stroke.paint.shapeStyle, style: strokeStyle(stroke, box: box))
            }
        }
        .frame(width: box.width, height: box.height)
    }

    @ViewBuilder
    private func svgContent(_ layer: AnimatedSVGLayer, state: AnimatedLayerState, box: CGSize) -> some View {
        if let parsed = SVGCache.shared.document(for: layer.source, assets: assets) {
            let viewBox = parsed.drawing.viewBox
            let scale = layer.contentMode == .fit
                ? min(box.width / max(viewBox.width, 1), box.height / max(viewBox.height, 1))
                : max(box.width / max(viewBox.width, 1), box.height / max(viewBox.height, 1))
            Group {
                switch layer.renderMode {
                case .native:
                    // Rendered by SVGView itself: highest fidelity, but opaque to trim and tint.
                    parsed.root.node.toSwiftUI()
                        .frame(width: viewBox.width, height: viewBox.height)
                case .vector:
                    SVGVectorView(
                        drawing: parsed.drawing,
                        passthroughNodes: parsed.passthroughNodes,
                        trim: state.trim,
                        tint: layer.tint,
                        strokeOverride: layer.strokeOverride,
                        staggerFraction: staggerFraction(for: layer),
                        strokeScale: box.width / max(scale, 0.0001)
                    )
                }
            }
            .scaleEffect(scale)
            .frame(width: box.width, height: box.height)
            .clipped()
        } else {
            Color.clear.frame(width: box.width, height: box.height)
        }
    }

    /// The stagger expressed as a fraction of the trim window, which is what `SVGVectorView` needs.
    ///
    /// `staggerSeconds` is authored in seconds because that is what an author can reason about
    /// alongside a spec's `duration`, but trim is a 0–1 sweep, so it has to be converted against the
    /// document's length.
    private func staggerFraction(for layer: AnimatedSVGLayer) -> Double {
        guard layer.staggerSeconds > 0, document.durationSeconds > 0 else { return 0 }
        let fraction = layer.staggerSeconds / document.durationSeconds
        // Leave at least a sliver of window for the last subpath: a stagger large enough to consume
        // the whole sweep would mean nothing ever finishes drawing.
        let count = max(1, SVGCache.shared.drawing(for: layer.source, assets: assets)?.subpathCount ?? 1)
        return min(fraction, 0.9 / Double(max(count - 1, 1)))
    }

    private func customPath(for kind: AnimatedShapeKind) -> Path? {
        guard case .path(let d) = kind else { return nil }
        return SVGCache.shared.path(forPathData: d)
    }

    private func strokeStyle(_ stroke: AnimatedStroke, box: CGSize) -> StrokeStyle {
        StrokeStyle(
            lineWidth: stroke.width * box.width,
            lineCap: stroke.lineCap.cgLineCap,
            lineJoin: stroke.lineJoin.cgLineJoin,
            dash: stroke.dash.map { CGFloat($0 * box.width) }
        )
    }

    private func font(_ layer: AnimatedTextLayer, box: CGSize) -> Font {
        // Deliberately larger than the box: an upper bound that `minimumScaleFactor` shrinks until
        // the text fits, which is what makes a text layer fill its box the way an image does.
        let size = box.width
        let weight: Font.Weight = switch layer.weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
        return switch layer.font {
        case .rounded: .system(size: size, weight: weight, design: .rounded)
        case .serif: .system(size: size, weight: weight, design: .serif)
        case .monospaced: .system(size: size, weight: weight, design: .monospaced)
        case .system: .system(size: size, weight: weight)
        }
    }

    private func textAlignment(_ value: AnimatedTextAlignment) -> TextAlignment {
        switch value {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
