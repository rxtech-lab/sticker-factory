import Foundation
import AnimatedView

/// The user's own change to the live plan card.
///
/// Deliberately not a whole plan. A plan carries far more than the card renders — a text layer's
/// font and alignment, a capture's frame grid, every parameter of a `spin` or a `shine` — and a
/// client that posted back only the fields it draws would silently flatten all of it. So a layer
/// names the one it keeps (`from`) and states only what the user touched; the server rebuilds the
/// plan from the version it already holds and saves the result as a new version.
nonisolated struct PlanEditRequest: Codable, Sendable {
    /// The revision the editor opened on. A plan the agent rewrote since is refused, not overwritten.
    var currentRevision: Int
    var edit: PlanEdit
}

nonisolated struct PlanEdit: Codable, Hashable, Sendable {
    var title: String?
    var summary: String?
    var timing: PlanTimingEdit?
    /// The complete new layer list, in order. Absent leaves the layers untouched.
    var layers: [PlanLayerEdit]?

    var configuration: AnimatedControlConfiguration?
    var clearConfiguration: Bool?

    var isEmpty: Bool {
        title == nil && summary == nil && timing == nil && layers == nil && configuration == nil && clearConfiguration != true
    }
}

nonisolated struct PlanTimingEdit: Codable, Hashable, Sendable {
    var durationSeconds: Double?
    var fps: Int?
    var loop: StickerLoopBehavior?
}

nonisolated struct PlanLayerEdit: Codable, Hashable, Sendable {
    /// The plan layer this entry keeps, or nil for one the user added.
    var from: String?
    var layerId: String?
    var name: String?
    var source: PlanLayerSourceEdit?
    var x: Double?
    var y: Double?
    var scaleX: Double?
    var scaleY: Double?
    var rotationDegrees: Double?
    /// Present only when the motion changed; absent keeps the layer's effects exactly as they are.
    var animations: [PlanAnimationEdit]?
}

/// The two layer sources the editor can author: drawn artwork, or a generated clip.
///
/// Everything else a plan can hold — kept artwork, captured frames, text, shapes, particles — is
/// carried over by naming the layer rather than by rewriting its source, so none of it has to be
/// expressible here.
nonisolated enum PlanLayerSourceEdit: Codable, Hashable, Sendable {
    case generate(prompt: String)
    case video(prompt: String, motion: String, durationSeconds: Int)

    private enum CodingKeys: String, CodingKey { case kind, prompt, motion, durationSeconds }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let prompt = try container.decode(String.self, forKey: .prompt)
        switch try container.decode(String.self, forKey: .kind) {
        case "video":
            self = .video(
                prompt: prompt,
                motion: try container.decode(String.self, forKey: .motion),
                durationSeconds: try container.decode(Int.self, forKey: .durationSeconds)
            )
        default:
            self = .generate(prompt: prompt)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .generate(let prompt):
            try container.encode("generate", forKey: .kind)
            try container.encode(prompt, forKey: .prompt)
        case .video(let prompt, let motion, let durationSeconds):
            try container.encode("video", forKey: .kind)
            try container.encode(prompt, forKey: .prompt)
            try container.encode(motion, forKey: .motion)
            try container.encode(durationSeconds, forKey: .durationSeconds)
        }
    }
}

/// One motion effect in an edited layer: either one the plan already had, or a new one.
///
/// `from` is an index into the layer's original animations rather than an id, because effects have
/// no identity of their own. It is resolved against the stored plan, so a removal and an addition
/// in the same save cannot shift each other's meaning.
nonisolated struct PlanAnimationEdit: Codable, Hashable, Sendable {
    var from: Int?
    var spec: PlanAnimationSpecEdit?
    /// Retimes a kept effect without rewriting the parameters this app has no field for.
    var delay: Double?
    var duration: Double?
}

nonisolated struct PlanAnimationSpecEdit: Codable, Hashable, Sendable {
    var type: String
    var delay: Double
    var duration: Double
    /// Carried only by the directional types; the rest of the vocabulary rejects it.
    var direction: String?
}

/// The motion effects the plan editor offers.
///
/// A subset of the server's animation vocabulary, and the mirror of its `EDITABLE_ANIMATION_TYPES`:
/// every entry is either parameterless or takes a direction, so it can be added with one tap and no
/// numeric fields. Effects the planner wrote that are *not* in this list are still shown and kept —
/// an edit that never mentions an animation never rewrites it.
nonisolated enum PlanAnimationCatalog {
    nonisolated struct Effect: Identifiable, Hashable, Sendable {
        let type: String
        let label: String
        var needsDirection = false
        var id: String { type }
    }

    nonisolated struct Direction: Identifiable, Hashable, Sendable {
        let value: String
        let label: String
        var id: String { value }
    }

    static let effects: [Effect] = [
        .init(type: "fadeIn", label: String(localized: "Fade in")),
        .init(type: "fadeOut", label: String(localized: "Fade out")),
        .init(type: "popIn", label: String(localized: "Pop in")),
        .init(type: "popOut", label: String(localized: "Pop out")),
        .init(type: "slideIn", label: String(localized: "Slide in"), needsDirection: true),
        .init(type: "slideOut", label: String(localized: "Slide out"), needsDirection: true),
        .init(type: "spin", label: String(localized: "Spin")),
        .init(type: "wiggle", label: String(localized: "Wiggle")),
        .init(type: "pulse", label: String(localized: "Pulse")),
        .init(type: "bounce", label: String(localized: "Bounce")),
        .init(type: "float", label: String(localized: "Float")),
        .init(type: "blurIn", label: String(localized: "Blur in")),
        .init(type: "blurOut", label: String(localized: "Blur out")),
        .init(type: "wipeIn", label: String(localized: "Wipe in"), needsDirection: true),
        .init(type: "wipeOut", label: String(localized: "Wipe out"), needsDirection: true),
        .init(type: "shine", label: String(localized: "Shine")),
        .init(type: "bloomIn", label: String(localized: "Bloom in")),
        .init(type: "bloomOut", label: String(localized: "Bloom out")),
        .init(type: "bloomPulse", label: String(localized: "Bloom pulse"))
    ]

    static let directions: [Direction] = [
        .init(value: "up", label: String(localized: "Up")),
        .init(value: "down", label: String(localized: "Down")),
        .init(value: "left", label: String(localized: "Left")),
        .init(value: "right", label: String(localized: "Right"))
    ]
}

nonisolated struct EditPlanResponse: Codable, Sendable {
    var messageId: String
    var plan: PlanRecord
}
