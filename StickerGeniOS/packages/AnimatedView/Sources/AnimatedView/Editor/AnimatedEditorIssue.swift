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

    private func layerIssues(_ layer: AnimatedLayer) -> [AnimatedEditorIssue] {
        var issues: [AnimatedEditorIssue] = []
        func add(_ suffix: String, _ severity: AnimatedEditorIssue.Severity, _ message: String) {
            issues.append(.init(id: "\(layer.id)-\(suffix)", severity: severity, message: message, layerID: layer.id))
        }

        let trimmedName = layer.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            add("name", .blocking, "This layer needs a name.")
        } else if layer.name.count > 80 {
            add("name", .blocking, "“\(trimmedName.prefix(20))…” is longer than 80 characters.")
        }

        if !layer.id.isAnimatedLayerID {
            add("id", .blocking, "“\(layer.id)” is not a usable layer id.")
        }
        if !layer.anchor.isValid {
            add("anchor", .blocking, "\(trimmedName) has a position, scale, or rotation outside the supported range.")
        }
        if !layer.animation.isValid {
            add("animation", .blocking, "\(trimmedName) has keyframes outside the supported range.")
        }
        if layer.animations.count > 12 {
            add("animations", .blocking, "\(trimmedName) has more than 12 preset animations.")
        }

        switch layer {
        case .image(let image):
            if !image.assetId.isAnimatedUUID { add("asset", .blocking, "\(trimmedName) has no valid image.") }
            if let mask = image.maskAssetId, !mask.isAnimatedUUID {
                add("mask", .blocking, "\(trimmedName)'s mask is not a valid image.")
            }
        case .text(let text):
            if text.text.isEmpty {
                add("text", .blocking, "\(trimmedName) has no text.")
            } else if text.text.count > 160 {
                add("text", .blocking, "\(trimmedName) is longer than 160 characters.")
            }
            if !text.paint.isValid { add("paint", .blocking, "\(trimmedName)'s colour is not valid.") }
        case .shape(let shape):
            // A shape with neither is not a subtle mistake — it renders as nothing at all.
            if shape.fill == nil, shape.stroke == nil {
                add("paint", .blocking, "\(trimmedName) needs a fill or a stroke to be visible.")
            }
            if let fill = shape.fill, !fill.isValid { add("fill", .blocking, "\(trimmedName)'s fill is not valid.") }
            if let stroke = shape.stroke, !stroke.isValid { add("stroke", .blocking, "\(trimmedName)'s stroke is not valid.") }
            if !shape.shape.isValid { add("shape", .blocking, "\(trimmedName)'s shape settings are out of range.") }
            if !(0...0.5).contains(shape.cornerRadius) {
                add("corner", .blocking, "\(trimmedName)'s corner radius must be between 0 and 0.5.")
            }
        case .svg(let svg):
            if !svg.source.isValid {
                add("source", .blocking, "\(trimmedName)'s artwork is empty, too large, or references a script or remote URL.")
            }
            if !(0...4).contains(svg.staggerSeconds) {
                add("stagger", .blocking, "\(trimmedName)'s stagger must be between 0 and 4 seconds.")
            }
            // Trim and tint are silently ignored in native mode, so a layer set up for a draw-on
            // that will never happen is worth flagging even though it is perfectly valid.
            if svg.renderMode == .native, !layer.animation.trim.isEmpty {
                add("render-mode", .warning, "\(trimmedName) draws in Native mode, which ignores its trim keyframes.")
            }
        case .particle(let particle):
            if !(1...64).contains(particle.count) {
                add("count", .blocking, "\(trimmedName) must have between 1 and 64 particles.")
            }
            if !particle.paint.isValid { add("paint", .blocking, "\(trimmedName)'s colour is not valid.") }
        case .sequence(let sequence):
            if !sequence.assetId.isAnimatedUUID {
                add("asset", .blocking, "\(trimmedName) has no valid capture.")
            }
            if let poster = sequence.posterAssetId, !poster.isAnimatedUUID {
                add("poster", .blocking, "\(trimmedName)'s still frame is not a valid image.")
            }
            if sequence.frameCount > sequence.rows * sequence.columns || sequence.frameCount < 1 {
                add("frames", .blocking, "\(trimmedName) claims more frames than its capture holds.")
            }
            if !(1...60).contains(sequence.frameRate) {
                add("rate", .blocking, "\(trimmedName) must play between 1 and 60 frames per second.")
            }
            // Advisory rather than blocking, unlike the server's identical rule: someone lowering
            // the document's frame rate mid-edit should be told what it costs, not stopped dead.
            if kind == .animated, Double(fps) < sequence.frameRate {
                add(
                    "rate-mismatch",
                    .warning,
                    "\(trimmedName) was captured at \(Int(sequence.frameRate)) fps but this sticker "
                        + "renders at \(fps), so some frames will be dropped."
                )
            }
        case .unsupported:
            add(
                "unsupported",
                .blocking,
                "\(trimmedName) was made with a newer version of Sticker Factory and cannot be shown here. "
                    + "Update the app to edit this sticker."
            )
        }

        // Warnings: legal documents that almost certainly are not what the author meant.
        if !layer.hidden, layer.animation.opacity.isEmpty, layer.anchor.opacity == 0 {
            add("invisible", .warning, "\(trimmedName) is fully transparent.")
        }
        if !layer.hidden, layer.animation.position.isEmpty, isOffCanvas(layer.anchor.position) {
            add("off-canvas", .warning, "\(trimmedName) sits outside the canvas.")
        }
        if !layer.supportsTrim, !layer.animation.trim.isEmpty {
            add("trim", .warning, "\(trimmedName) is a \(layer.type.rawValue) layer, which has no outline to trim.")
        }

        return issues
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
