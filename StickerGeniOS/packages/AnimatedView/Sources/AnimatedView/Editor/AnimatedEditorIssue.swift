import Foundation

/// Something wrong with the document, reported without stopping the user from working.
///
/// Editing is not a form submission. A half-typed layer name is empty for a moment, a text layer is
/// blank between clearing it and typing the replacement, and a shape can have its fill turned off
/// on the way to turning on a stroke. Blocking any of those would make the editor fight the user.
///
/// So the document is allowed to sit invalid indefinitely and this drives a non-modal banner
/// instead. Only the host's save or export path calls `validated()`, and by then the banner has
/// been saying what is wrong the whole time.
public struct AnimatedEditorIssue: Identifiable, Hashable, Sendable {
    public enum Severity: Int, Comparable, Sendable {
        /// Worth knowing, but the document would still save.
        case warning
        /// `validated()` would throw. Saving is not possible until it is fixed.
        case blocking

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var id: String
    public var severity: Severity
    public var message: String
    public var layerID: String?

    public init(id: String, severity: Severity, message: String, layerID: String? = nil) {
        self.id = id
        self.severity = severity
        self.message = message
        self.layerID = layerID
    }
}

extension AnimatedDocument {
    /// Everything currently wrong with this document, worst first.
    ///
    /// `validated()` is the source of truth for what blocks a save, but it reports only the *first*
    /// problem and collapses every per-layer failure into a single `.invalidLayer(id)`. That is the
    /// right shape for a gatekeeper and the wrong shape for a UI, so the per-layer checks are
    /// re-run here in detail — a user fixing three broken layers should see three messages, not
    /// solve one and discover the next.
    public var editorIssues: [AnimatedEditorIssue] {
        var issues: [AnimatedEditorIssue] = []

        do {
            _ = try validated()
        } catch let error as AnimatedDocumentError {
            // Per-layer failures are expanded below; everything else is reported as-is.
            if case .invalidLayer = error {} else {
                issues.append(.init(
                    id: "document",
                    severity: .blocking,
                    message: error.errorDescription ?? "This sticker is not valid."
                ))
            }
        } catch {
            issues.append(.init(id: "document", severity: .blocking, message: error.localizedDescription))
        }

        for layer in layers {
            issues.append(contentsOf: layerIssues(layer))
        }

        // Budget warnings. These are not failures — they are the ceiling coming into view, and the
        // user would rather know before an insert starts being refused.
        let keyframes = totalKeyframeCount
        if keyframes > Int(Double(Self.maximumKeyframeCount) * 0.9), keyframes <= Self.maximumKeyframeCount {
            issues.append(.init(
                id: "keyframe-budget",
                severity: .warning,
                message: "Using \(keyframes) of \(Self.maximumKeyframeCount) keyframes."
            ))
        }
        if layers.count == Self.maximumLayerCount {
            issues.append(.init(
                id: "layer-budget",
                severity: .warning,
                message: "This sticker is at its limit of \(Self.maximumLayerCount) layers."
            ))
        }

        return issues.sorted { $0.severity > $1.severity }
    }

    /// Gathers one layer's issues, stamping each with the layer it came from.
    private struct LayerIssues {
        let layer: AnimatedLayer
        /// The layer's trimmed name, which every message reads back to the author.
        let name: String
        private(set) var issues: [AnimatedEditorIssue] = []

        init(_ layer: AnimatedLayer) {
            self.layer = layer
            name = layer.name.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        mutating func add(_ suffix: String, _ severity: AnimatedEditorIssue.Severity, _ message: String) {
            issues.append(.init(id: "\(layer.id)-\(suffix)", severity: severity, message: message, layerID: layer.id))
        }
    }

    private func layerIssues(_ layer: AnimatedLayer) -> [AnimatedEditorIssue] {
        var found = LayerIssues(layer)
        appendStructuralIssues(to: &found)
        appendContentIssues(to: &found)
        appendAdvisoryIssues(to: &found)
        return found.issues
    }

    /// Identity, transform and animation limits — the checks that apply whatever the layer holds.
    private func appendStructuralIssues(to found: inout LayerIssues) {
        let layer = found.layer
        if found.name.isEmpty {
            found.add("name", .blocking, "This layer needs a name.")
        } else if layer.name.count > 80 {
            found.add("name", .blocking, "“\(found.name.prefix(20))…” is longer than 80 characters.")
        }

        if !layer.id.isAnimatedLayerID {
            found.add("id", .blocking, "“\(layer.id)” is not a usable layer id.")
        }
        if !layer.anchor.isValid {
            found.add("anchor", .blocking, "\(found.name) has a position, scale, or rotation outside the supported range.")
        }
        if !layer.animation.isValid {
            found.add("animation", .blocking, "\(found.name) has keyframes outside the supported range.")
        }
        if layer.animations.count > 12 {
            found.add("animations", .blocking, "\(found.name) has more than 12 preset animations.")
        }
    }

    private func appendContentIssues(to found: inout LayerIssues) {
        switch found.layer {
        case .image(let image): appendImageIssues(image, to: &found)
        case .text(let text): appendTextIssues(text, to: &found)
        case .shape(let shape): appendShapeIssues(shape, to: &found)
        case .svg(let svg): appendSVGIssues(svg, to: &found)
        case .particle(let particle): appendParticleIssues(particle, to: &found)
        case .sequence(let sequence): appendSequenceIssues(sequence, to: &found)
        case .video(let video): appendVideoIssues(video, to: &found)
        case .sprite(let sprite): appendSpriteIssues(sprite, to: &found)
        case .unsupported:
            found.add(
                "unsupported",
                .blocking,
                "\(found.name) was made with a newer version of Sticker Factory and cannot be shown here. "
                    + "Update the app to edit this sticker."
            )
        }
    }

    private func appendImageIssues(_ image: AnimatedImageLayer, to found: inout LayerIssues) {
        if !image.assetId.isAnimatedUUID { found.add("asset", .blocking, "\(found.name) has no valid image.") }
        if let mask = image.maskAssetId, !mask.isAnimatedUUID {
            found.add("mask", .blocking, "\(found.name)'s mask is not a valid image.")
        }
    }

    private func appendTextIssues(_ text: AnimatedTextLayer, to found: inout LayerIssues) {
        if text.text.isEmpty {
            found.add("text", .blocking, "\(found.name) has no text.")
        } else if text.text.count > 160 {
            found.add("text", .blocking, "\(found.name) is longer than 160 characters.")
        }
        if !text.paint.isValid { found.add("paint", .blocking, "\(found.name)'s colour is not valid.") }
    }

    private func appendShapeIssues(_ shape: AnimatedShapeLayer, to found: inout LayerIssues) {
        // A shape with neither is not a subtle mistake — it renders as nothing at all.
        if shape.fill == nil, shape.stroke == nil {
            found.add("paint", .blocking, "\(found.name) needs a fill or a stroke to be visible.")
        }
        if let fill = shape.fill, !fill.isValid { found.add("fill", .blocking, "\(found.name)'s fill is not valid.") }
        if let stroke = shape.stroke, !stroke.isValid { found.add("stroke", .blocking, "\(found.name)'s stroke is not valid.") }
        if !shape.shape.isValid { found.add("shape", .blocking, "\(found.name)'s shape settings are out of range.") }
        if !(0...0.5).contains(shape.cornerRadius) {
            found.add("corner", .blocking, "\(found.name)'s corner radius must be between 0 and 0.5.")
        }
    }

    private func appendSVGIssues(_ svg: AnimatedSVGLayer, to found: inout LayerIssues) {
        if !svg.source.isValid {
            found.add("source", .blocking, "\(found.name)'s artwork is empty, too large, or references a script or remote URL.")
        }
        if !(0...4).contains(svg.staggerSeconds) {
            found.add("stagger", .blocking, "\(found.name)'s stagger must be between 0 and 4 seconds.")
        }
        // Trim and tint are silently ignored in native mode, so a layer set up for a draw-on
        // that will never happen is worth flagging even though it is perfectly valid.
        if svg.renderMode == .native, !found.layer.animation.trim.isEmpty {
            found.add("render-mode", .warning, "\(found.name) draws in Native mode, which ignores its trim keyframes.")
        }
    }

    private func appendParticleIssues(_ particle: AnimatedParticleLayer, to found: inout LayerIssues) {
        if !(1...64).contains(particle.count) {
            found.add("count", .blocking, "\(found.name) must have between 1 and 64 particles.")
        }
        if !particle.paint.isValid { found.add("paint", .blocking, "\(found.name)'s colour is not valid.") }
    }

    private func appendSequenceIssues(_ sequence: AnimatedSequenceLayer, to found: inout LayerIssues) {
        if !sequence.assetId.isAnimatedUUID {
            found.add("asset", .blocking, "\(found.name) has no valid capture.")
        }
        if let poster = sequence.posterAssetId, !poster.isAnimatedUUID {
            found.add("poster", .blocking, "\(found.name)'s still frame is not a valid image.")
        }
        if sequence.frameCount > sequence.rows * sequence.columns || sequence.frameCount < 1 {
            found.add("frames", .blocking, "\(found.name) claims more frames than its capture holds.")
        }
        if !(1...60).contains(sequence.frameRate) {
            found.add("rate", .blocking, "\(found.name) must play between 1 and 60 frames per second.")
        }
        // Advisory rather than blocking, unlike the server's identical rule: someone lowering
        // the document's frame rate mid-edit should be told what it costs, not stopped dead.
        if kind == .animated, Double(fps) < sequence.frameRate {
            found.add(
                "rate-mismatch",
                .warning,
                "\(found.name) was captured at \(Int(sequence.frameRate)) fps but this sticker "
                    + "renders at \(fps), so some frames will be dropped."
            )
        }
    }

    private func appendVideoIssues(_ video: AnimatedVideoLayer, to found: inout LayerIssues) {
        if !video.assetId.isAnimatedUUID {
            found.add("asset", .blocking, "\(found.name) has no valid clip.")
        }
        if !video.posterAssetId.isAnimatedUUID {
            found.add("poster", .blocking, "\(found.name)'s still frame is not a valid image.")
        }
        if !(1...600).contains(video.frameCount) {
            found.add("frames", .blocking, "\(found.name) must have between 1 and 600 frames.")
        }
        if !(1...60).contains(video.frameRate) {
            found.add("rate", .blocking, "\(found.name) must play between 1 and 60 frames per second.")
        }
        if kind == .animated, Double(fps) < video.frameRate {
            found.add(
                "rate-mismatch",
                .warning,
                "\(found.name) was generated at \(Int(video.frameRate)) fps but this sticker "
                    + "renders at \(fps), so some frames will be dropped."
            )
        }
    }

    private func appendSpriteIssues(_ sprite: AnimatedSpriteLayer, to found: inout LayerIssues) {
        if !sprite.posterAssetId.isAnimatedUUID {
            found.add("poster", .blocking, "\(found.name)'s still frame is not a valid image.")
        }
        let clipIDs = Set(sprite.clips.map(\.id))
        if sprite.clips.isEmpty || sprite.clips.contains(where: { !$0.isValid }) || clipIDs.count != sprite.clips.count {
            found.add("clips", .blocking, "\(found.name) has a pose whose frames or sheet are not valid.")
        }
        if !sprite.expressions.isValid || Set(sprite.expressions.tiles.map(\.id)).count != sprite.expressions.tiles.count {
            found.add("expressions", .blocking, "\(found.name) has an expression sheet that is not valid.")
        }
        if !sprite.clips.contains(where: { $0.id == sprite.clipId }) {
            found.add("clip", .blocking, "\(found.name) is set to a pose it does not have.")
        }
        if !sprite.expressions.tiles.contains(where: { $0.id == sprite.expressionId }) {
            found.add("expression", .blocking, "\(found.name) is set to an expression it does not have.")
        }
        // Advisory, as for a capture: a frame shorter than one render tick is never shown, so a
        // blink the plan timed would vanish, but lowering the frame rate mid-edit should not stop
        // the author dead.
        let shortest = sprite.clips.flatMap(\.frames).map(\.duration).min()
        if kind == .animated, let shortest, 1 / Double(max(fps, 1)) > shortest + 1e-9 {
            found.add(
                "rate-mismatch",
                .warning,
                "\(found.name) has a \(String(format: "%.2f", shortest))s frame but this sticker renders at \(fps) fps, "
                    + "so that frame will be skipped."
            )
        }
    }

    /// Warnings: legal documents that almost certainly are not what the author meant.
    private func appendAdvisoryIssues(to found: inout LayerIssues) {
        let layer = found.layer
        if !layer.hidden, layer.animation.opacity.isEmpty, layer.anchor.opacity == 0 {
            found.add("invisible", .warning, "\(found.name) is fully transparent.")
        }
        if !layer.hidden, layer.animation.position.isEmpty, isOffCanvas(layer.anchor.position) {
            found.add("off-canvas", .warning, "\(found.name) sits outside the canvas.")
        }
        if !layer.supportsTrim, !layer.animation.trim.isEmpty {
            found.add("trim", .warning, "\(found.name) is a \(layer.type.rawValue) layer, which has no outline to trim.")
        }
    }

    /// Whether a resting position puts a layer's centre beyond the canvas edge.
    ///
    /// Only the centre, and only for a layer with no position keyframes — a layer that animates in
    /// from off-screen is *supposed* to start out there, and flagging it would make the warning
    /// noise that gets ignored.
    private func isOffCanvas(_ point: AnimatedPoint) -> Bool {
        !(0...1).contains(point.x) || !(0...1).contains(point.y)
    }
}
