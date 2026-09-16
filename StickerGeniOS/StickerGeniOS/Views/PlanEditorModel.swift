import Foundation
import AnimatedView

/// The part of the plan the user tapped to open the editor.
nonisolated enum PlanEditorFocus: Hashable {
    case layers
    case timing
}

/// The editable projection of a plan card, and the `PlanEdit` it turns into.
///
/// A plan holds more than the card draws — a text layer's font, a capture's frame grid, the
/// parameters of a `spin` — so this never rebuilds a plan. It records what the user touched and
/// leaves everything else named rather than restated, which is exactly the shape the server's edit
/// endpoint takes: an entry of `{ from: "part_0" }` means "keep this layer as it is".
nonisolated struct PlanEditorModel: Hashable {
    /// One motion effect on a layer.
    ///
    /// A kept effect carries the index it had in the plan, which is its only identity — specs have
    /// no id of their own, and naming the index is what lets the server hand back the original
    /// spec's parameters rather than the three fields this editor can show.
    nonisolated struct Effect: Identifiable, Hashable {
        let id = UUID()
        var origin: Int?
        var type: String
        var direction: String?
        var delay: Double
        var duration: Double
        var originalDelay: Double
        var originalDuration: Double

        /// The catalogue entry's wording where there is one, and the server's own spelling where
        /// the planner used an effect this build has no picker for.
        var label: String {
            PlanAnimationCatalog.effects.first { $0.type == type }?.label ?? type
        }

        var isRetimed: Bool { delay != originalDelay || duration != originalDuration }
    }

    /// What a layer is made of, as far as the editor is concerned.
    ///
    /// `keep` is not a source but the absence of a change: text, shapes, particles, kept artwork
    /// and captured frames all carry detail no picker here can author, so leaving one alone is
    /// expressed by never writing its source at all.
    nonisolated enum Source: Hashable {
        case keep
        case image
        case video
    }

    nonisolated struct Layer: Identifiable, Hashable {
        let id = UUID()
        /// The plan layer this row keeps, or nil for one the user added.
        var origin: String?
        var layerId: String
        var name: String
        var source: Source
        var prompt: String
        var motion: String
        var videoSeconds: Int
        /// The poses and moods of a sprite character, for the configuration editor. The editor
        /// cannot author a sprite's sheets, so the layer is always kept; this only names its parts.
        var sprite: StickerConfigurationEditor.Sprite?
        var effects: [Effect]
        /// How the untouched source reads on the card, for the "keep it as it is" option.
        var keptLabel: String
        var x: Double
        var y: Double
        var scaleX: Double
        var scaleY: Double

        /// What the layer was made of before the user touched the picker.
        var originalSource: Source = .keep

        /// Whether "leave it as it is" is a real third option. It is only offered for the sources
        /// the editor cannot author — text, shapes, particles, kept artwork, captured frames —
        /// because those are the ones with detail to lose.
        var canKeep: Bool { origin != nil && originalSource == .keep }
    }

    let original: Plan
    var title: String
    var summary: String
    var durationSeconds: Double
    var fps: Int
    var loop: StickerLoopBehavior
    var layers: [Layer]
    var configuration: AnimatedControlConfiguration?
    var posePreset: PosePreset?

    /// A plan may hold at most eight layers, and at most one of them may be a video clip.
    static let layerLimit = 12

    init(plan: Plan) {
        configuration = plan.configuration
        posePreset = plan.posePreset
        original = plan
        title = plan.title
        summary = plan.summary
        durationSeconds = plan.timing.durationSeconds
        fps = plan.timing.fps
        loop = plan.timing.loop
        layers = plan.layers.map(Self.layer(from:))
    }

    private static func layer(from layer: PlanLayer) -> Layer {
        let source: Source = switch layer.source {
        case .generate: .image
        case .video: .video
        default: .keep
        }
        let videoSeconds: Int = if case .video(_, _, let seconds) = layer.source { seconds } else { 3 }
        return Layer(
            origin: layer.layerId,
            layerId: layer.layerId,
            name: layer.name,
            source: source,
            // A layer with no prompt of its own — a caption, a burst, kept artwork — starts from its
            // name, so switching it to drawn artwork opens with something to edit rather than a
            // blank field the Save button is waiting on.
            prompt: layer.source.prompt ?? layer.name,
            motion: layer.source.motion ?? "",
            videoSeconds: videoSeconds,
            sprite: layer.source.sprite.map { StickerConfigurationEditor.Sprite(
                clips: $0.clips.map { .init(id: $0.id, label: $0.label) },
                expressions: $0.expressions.map { .init(id: $0.id, label: $0.label) }
            ) },
            effects: layer.animations.enumerated().map { index, animation in
                Effect(
                    origin: index,
                    type: animation.type,
                    delay: animation.delay,
                    duration: animation.duration,
                    originalDelay: animation.delay,
                    originalDuration: animation.duration
                )
            },
            keptLabel: layer.source.label,
            x: layer.x,
            y: layer.y,
            scaleX: layer.scaleX,
            scaleY: layer.scaleY,
            originalSource: source
        )
    }

    /// A layer the user just added: drawn artwork, centred, at the size the planner uses for a part.
    static func newLayer(existingIDs: Set<String>) -> Layer {
        var index = existingIDs.count + 1
        var layerId = "part_\(index)"
        while existingIDs.contains(layerId) {
            index += 1
            layerId = "part_\(index)"
        }
        return Layer(
            origin: nil,
            layerId: layerId,
            name: String(localized: "New layer"),
            source: .image,
            prompt: "",
            motion: "",
            videoSeconds: 3,
            effects: [],
            keptLabel: "",
            x: 0.5,
            y: 0.5,
            scaleX: 0.4,
            scaleY: 0.4
        )
    }

    var isAnimated: Bool { original.kind == .animated }
    /// At most one clip per plan, so the option is offered to the layer that already holds it only.
    var videoLayerID: UUID? { layers.first { $0.source == .video }?.id }

    /// What stops the edit from being saved, in the user's words. Nil when it is ready.
    var validationMessage: String? {
        if title.trimmed.isEmpty { return String(localized: "The plan needs a title.") }
        if summary.trimmed.isEmpty { return String(localized: "The plan needs a summary.") }
        if layers.isEmpty { return String(localized: "A plan needs at least one layer.") }
        if layers.count > Self.layerLimit {
            return String(localized: "A plan holds at most \(Self.layerLimit) layers.")
        }
        for layer in layers where layer.source != .keep {
            if layer.name.trimmed.isEmpty { return String(localized: "Every layer needs a name.") }
            if layer.prompt.trimmed.isEmpty {
                return String(localized: "“\(layer.name)” needs a description of what to draw.")
            }
            if layer.source == .video, layer.motion.trimmed.isEmpty {
                return String(localized: "“\(layer.name)” needs a description of how it moves.")
            }
        }
        if layers.filter({ $0.source == .video }).count > 1 {
            return String(localized: "A plan can have only one video layer.")
        }
        let layerIDs = Set(layers.map(\.layerId))
        do {
            try configuration?.keepingLayers(layerIDs)?.validated(layerIds: layerIDs, planned: true)
        } catch {
            return error.localizedDescription
        }
        return nil
    }

    /// What the user changed, and nothing else. Empty when the editor was opened and closed again.
    func edit() -> PlanEdit {
        var edit = PlanEdit()
        let kept = configuration?.keepingLayers(Set(layers.map(\.layerId)))
        if kept != original.configuration {
            edit.configuration = kept
            if kept == nil { edit.clearConfiguration = true }
        }
        if title.trimmed != original.title { edit.title = title.trimmed }
        if summary.trimmed != original.summary { edit.summary = summary.trimmed }

        var timing = PlanTimingEdit()
        if durationSeconds != original.timing.durationSeconds { timing.durationSeconds = durationSeconds }
        if fps != original.timing.fps { timing.fps = fps }
        if loop != original.timing.loop { timing.loop = loop }
        if timing != PlanTimingEdit() { edit.timing = timing }

        let entries = layers.map(layerEdit(for:))
        // The list is sent whole or not at all, so it has to be compared against the one that would
        // mean "nothing happened here": every original layer, in order, kept untouched.
        if entries != original.layers.map({ PlanLayerEdit(from: $0.layerId) }) {
            edit.layers = entries
        }
        return edit
    }

    private func layerEdit(for layer: Layer) -> PlanLayerEdit {
        guard let origin = layer.origin, let base = original.layers.first(where: { $0.layerId == origin }) else {
            return PlanLayerEdit(
                layerId: layer.layerId,
                name: layer.name.trimmed,
                source: source(for: layer) ?? .generate(prompt: layer.prompt.trimmed),
                x: layer.x,
                y: layer.y,
                scaleX: layer.scaleX,
                scaleY: layer.scaleY,
                animations: effectEdits(for: layer)
            )
        }
        var entry = PlanLayerEdit(from: origin)
        if layer.name.trimmed != base.name { entry.name = layer.name.trimmed }
        if let source = source(for: layer), source != Self.sourceEdit(of: base.source) {
            entry.source = source
        }
        let effects = effectEdits(for: layer)
        if effects != base.animations.indices.map({ PlanAnimationEdit(from: $0) }) {
            entry.animations = effects
        }
        return entry
    }

    private func source(for layer: Layer) -> PlanLayerSourceEdit? {
        switch layer.source {
        case .keep: nil
        case .image: .generate(prompt: layer.prompt.trimmed)
        case .video: .video(
            prompt: layer.prompt.trimmed,
            motion: layer.motion.trimmed,
            durationSeconds: layer.videoSeconds
        )
        }
    }

    /// The edit that would rewrite a source into exactly what it already is, for comparison.
    private static func sourceEdit(of source: PlanLayerSource) -> PlanLayerSourceEdit? {
        switch source {
        case .generate(let prompt): .generate(prompt: prompt)
        case .video(let prompt, let motion, let durationSeconds):
            .video(prompt: prompt, motion: motion, durationSeconds: durationSeconds)
        default: nil
        }
    }

    private func effectEdits(for layer: Layer) -> [PlanAnimationEdit] {
        layer.effects.map { effect in
            guard let origin = effect.origin else {
                return PlanAnimationEdit(spec: PlanAnimationSpecEdit(
                    type: effect.type,
                    delay: effect.delay,
                    duration: effect.duration,
                    direction: effect.direction
                ))
            }
            return PlanAnimationEdit(
                from: origin,
                delay: effect.delay == effect.originalDelay ? nil : effect.delay,
                duration: effect.duration == effect.originalDuration ? nil : effect.duration
            )
        }
    }
}

private extension String {
    nonisolated var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
