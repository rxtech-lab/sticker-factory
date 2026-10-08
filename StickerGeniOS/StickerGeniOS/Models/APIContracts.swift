import AnimatedView
import Foundation

nonisolated struct Sticker: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var kind: StickerKind
    var status: StickerStatus
    var activeRevisionId: String?
    /// The revision whose controls this sticker can be posed with, when it has any.
    ///
    /// Only a published revision that carries a playback bundle gets an id here, so this is the one
    /// field that says "this sticker is controllable" without fetching its document — which is what
    /// the library and pack grids need to mark a member, and what the preview reads before asking
    /// the server for the bundle. Optional so a response from a server that predates it still
    /// decodes, and nil for every sticker that has no configuration.
    var playbackRevisionId: String?
    var createdAt: Date
    var updatedAt: Date
    var previewAsset: AssetRecord?
    /// The concept render of this draft's newest plan, for a draft that has not built any artwork
    /// of its own yet.
    ///
    /// Read only after `systemSticker` and `previewAsset`: a draft that has already built something
    /// shows what it built, and the plan sketch is what a grid tile falls back to instead of the
    /// kind glyph. Nil on every published sticker, and on a draft whose plan never rendered one.
    var planConceptAsset: AssetRecord?
    var systemSticker: SystemStickerRecord?
    /// The 512 px copies WhatsApp and Telegram accept, encoded and uploaded when this sticker was
    /// added to a pack.
    ///
    /// Optional with a default so a response from a server that predates them still decodes, and
    /// independently nil because the two messengers give an animation very different budgets — 500
    /// KB against 256 KB — so artwork routinely clears one and misses the other. Nil is what the
    /// pack screen reads to gray a member out: there is no fallback to re-encode from any more.
    var whatsappAsset: AssetRecord?
    var telegramAsset: AssetRecord?
    /// The emoji the creator filed this sticker under, when they chose one. A device-local choice
    /// in `MessengerEmojiStore` still overrides it.
    var messengerEmoji: String?
    /// The job still working on this sticker, when the listing was taken. Only enough to attach to
    /// its event stream — the stage and progress come from there. Nil when idle, and on a server
    /// that predates it.
    var generation: StickerGenerationSummary?

    init(
        id: String,
        title: String,
        kind: StickerKind,
        status: StickerStatus,
        activeRevisionId: String? = nil,
        playbackRevisionId: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        previewAsset: AssetRecord? = nil,
        planConceptAsset: AssetRecord? = nil,
        systemSticker: SystemStickerRecord? = nil,
        whatsappAsset: AssetRecord? = nil,
        telegramAsset: AssetRecord? = nil,
        messengerEmoji: String? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.status = status
        self.activeRevisionId = activeRevisionId
        self.playbackRevisionId = playbackRevisionId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.previewAsset = previewAsset
        self.planConceptAsset = planConceptAsset
        self.systemSticker = systemSticker
        self.whatsappAsset = whatsappAsset
        self.telegramAsset = telegramAsset
        self.messengerEmoji = messengerEmoji
    }

    /// Whether this sticker is posed rather than simply sent: it has controls, and the server is
    /// holding the bundle they are answered against.
    var isControllable: Bool { playbackRevisionId != nil }
}

nonisolated enum StickerStatus: String, Codable, CaseIterable, Hashable, Sendable { case draft, published, deleting }

nonisolated struct StickerGenerationSummary: Codable, Hashable, Sendable {
    var jobId: String
    /// Kept as a string: a job kind added on the server must not fail the whole library decode.
    var kind: String
    var state: String
}

nonisolated struct StickerDetail: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var kind: StickerKind
    var status: StickerStatus
    var activeRevisionId: String?
    var playbackRevisionId: String?
    var createdAt: Date
    var updatedAt: Date
    var previewAsset: AssetRecord?
    var planConceptAsset: AssetRecord?
    var systemSticker: SystemStickerRecord?
    var whatsappAsset: AssetRecord?
    var telegramAsset: AssetRecord?
    var messengerEmoji: String?
    var presets: CreationPresetDisplay?
    var revisions: [StickerRevision]
    /// The owner's pet is growing this sticker: it builds, accepts and publishes the new look on its
    /// own. Nil from servers that predate it.
    var petEvolving: Bool?

    var sticker: Sticker {
        .init(
            id: id,
            title: title,
            kind: kind,
            status: status,
            activeRevisionId: activeRevisionId,
            playbackRevisionId: playbackRevisionId,
            createdAt: createdAt,
            updatedAt: updatedAt,
            previewAsset: previewAsset,
            planConceptAsset: planConceptAsset,
            systemSticker: systemSticker,
            whatsappAsset: whatsappAsset,
            telegramAsset: telegramAsset,
            messengerEmoji: messengerEmoji
        )
    }
    var activeRevision: StickerRevision? { revisions.first { $0.id == activeRevisionId } }
}

nonisolated struct StickerRevision: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var parentRevisionId: String?
    var sourceMessageId: String?
    var candidateState: RevisionCandidateState
    var document: AnimatedDocument
    var masterAssetId: String?
    var previewAssetId: String?
    var pngAssetId: String?
    /// The sharing rendition of a revision published before APNG replaced GIF. Never written by
    /// this app any more, and still the only thing that finds those revisions' artwork.
    var gifAssetId: String?
    /// The sharing rendition every publish produces now.
    var apngAssetId: String?
    var mp4AssetId: String?
    var systemAssetId: String?
    var createdAt: Date
    var decidedAt: Date?

    /// The sharing rendition, whichever container this revision was published with. Exactly one of
    /// the two is ever set, so this is a fallback in name only.
    var sharingAssetId: String? { apngAssetId ?? gifAssetId }

    var state: RevisionCandidateState {
        get { candidateState }
        set { candidateState = newValue }
    }

    var containsMotion: Bool {
        document.hasMotion || document.configuration != nil
    }

    var canPublishExports: Bool {
        document.kind == .static || containsMotion
    }

    /// The MP4 is not part of this: it is published only when the person asked to share a video,
    /// because encoding one is the slowest step of a publish and nothing on the platform reads it.
    /// A sticker published without one is fully published — see `hasPublishedVideo`.
    var hasPublishedExports: Bool {
        guard systemAssetId != nil else { return false }
        return document.kind == .static
            ? pngAssetId != nil
            : sharingAssetId != nil
    }

    /// Whether the server holds a video for this revision, as opposed to one that can still be
    /// rendered on demand from the document.
    var hasPublishedVideo: Bool { mp4AssetId != nil }
}

nonisolated enum RevisionCandidateState: String, Codable, CaseIterable, Hashable, Sendable {
    case candidate, accepted, rejected, superseded

    var label: String {
        switch self {
        case .candidate: String(localized: "Candidate")
        case .accepted: String(localized: "Accepted")
        case .rejected: String(localized: "Rejected")
        case .superseded: String(localized: "Superseded")
        }
    }
}

nonisolated struct AssetRecord: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var stickerId: String?
    var kind: AssetKind
    var state: AssetState
    var mimeType: String
    var byteSize: Int?
    var width: Int?
    var height: Int?
    var frameCount: Int?
    var durationSeconds: Double?
    var fps: Double?
    var sha256: String?
    var hasAlpha: Bool?
    var createdAt: Date?
}

nonisolated enum AssetKind: String, Codable, CaseIterable, Hashable, Sendable {
    case reference, mask, master, preview, apng, mp4, system, playback
    /// The copy WhatsApp accepts: a transparent 512 px WebP, still or animated.
    case messengerWhatsApp = "messenger_whatsapp"
    /// The copy Telegram accepts: a transparent 512 px PNG for a static sticker, a VP9 WebM for an
    /// animated one. One kind for both containers, because a sticker has one Telegram rendition and
    /// its own `kind` already says which of the two it is.
    case messengerTelegram = "messenger_telegram"
    /// The sharing rendition before APNG replaced it. Nothing uploads one; the case stays so an
    /// asset published under the old kind still decodes.
    case gif
    case chatAttachment = "chat_attachment"
    /// A frame atlas: one transparent PNG holding a grid of frames lifted from a Live Photo.
    case sequence
    /// A generated clip for a video layer: an opaque 1:1 MP4 on a chroma backdrop that the app keys
    /// out at render time. Never shared into a pack on its own; the layer's poster is what the
    /// marketplace sees.
    case video
    /// A smaller copy of the sharing rendition, at 408 or 300 px, for WinkySticker's size control.
    ///
    /// Its own kind rather than `apng` because a static sticker has these too and they are ordinary
    /// still PNGs, and not `system` because nothing here is under Apple's 500 KB ceiling — that is
    /// the point of them.
    case attachment
    /// The WebP copy of the sharing rendition.
    ///
    /// Its own kind rather than `apng`, because the container is what distinguishes it and a
    /// static sticker has one too. Never a `system` rendition: `MSSticker.h` requires a file
    /// conforming to `kUTTypePNG`, `kUTTypeGIF` or `kUTTypeJPEG`, and WebP conforms to none of
    /// them — so this can only ever be an `.image`-mode attachment.
    case webp
}

/// How a frame atlas is packed, sent with the upload intent.
///
/// The atlas is a single still PNG, so the server cannot recover any of this by inspecting it — the
/// client's declaration is the only source, and it is what the document's sequence layer is
/// cross-checked against.
nonisolated struct SequenceMetadata: Codable, Hashable, Sendable {
    var columns: Int
    var rows: Int
    var frameCount: Int
    var frameRate: Double
}
nonisolated enum AssetState: String, Codable, Hashable, Sendable { case pending, ready, failed, deleted }

nonisolated struct SystemStickerRecord: Codable, Hashable, Sendable {
    var assetId: String
    var mimeType: String
    var byteSize: Int?
    var sha256: String?
}

nonisolated struct ChatMessage: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var role: ChatRole
    var kind: ChatMessageKind
    var content: String
    var targetLayerId: String?
    var imagePlacement: ImagePlacement
    var baseRevisionId: String?
    var sequence: Int
    var revisionId: String?
    var jobId: String?
    var status: ChatMessageStatus
    var createdAt: Date
    var attachments: [ChatAttachment]
    /// Present on `.plan` messages: the design the user is being asked to confirm.
    var plan: PlanRecord?
    var toolDetails: String?
}

nonisolated enum ChatRole: String, Codable, Hashable, Sendable { case user, assistant, system }
nonisolated enum ChatMessageKind: String, Codable, Hashable, Sendable {
    case text, image, imageEdit = "image_edit", animation, plan, export, status
    /// A revision saved from the on-device editor. Sits in the transcript to keep the revision
    /// chain unbroken, but nobody said it, so it renders as a divider rather than a bubble.
    case deviceEdit = "device_edit"
}

nonisolated struct PlanRecord: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var messageId: String
    var state: PlanState
    /// Bumped by every agent revision. A card rendered at an older revision is read-only.
    var revision: Int
    var jobId: String?
    var conceptAssetId: String?
    var animationPreviewAssetId: String?
    var decisionReason: String?
    var supersedesId: String?
    /// The saved version this active copy restores. Its build identity remains `id`.
    var sourceVersionId: String?
    var versionID: String { sourceVersionId ?? id }
    /// The server's verdict on whether this card may still be acted on. Trusted over `state`
    /// alone, because a card can be stale even while the plan itself is finalized.
    var actionable: Bool
    /// How many layers cost an image generation; the rest are drawn by the app.
    var generationCount: Int
    var plan: Plan

    /// The same card with its buttons removed, for history that must not be actionable.
    var readOnly: PlanRecord {
        var copy = self
        copy.actionable = false
        return copy
    }
}

nonisolated enum PlanState: String, Codable, Hashable, Sendable {
    case draft, finalized, confirmed, superseded, cancelled
}

nonisolated enum PosePreset: String, Codable, CaseIterable, Hashable, Sendable {
    case low, medium, high, ultra

    var label: String {
        switch self {
        case .low: String(localized: "Low")
        case .medium: String(localized: "Medium")
        case .high: String(localized: "High")
        case .ultra: String(localized: "Ultra")
        }
    }
}

nonisolated struct PlanPoseUpdate: Codable, Sendable {
    var planId: String
    var currentRevision: Int
    var posePreset: PosePreset
    var edit: PlanEdit?
}

nonisolated struct PlanConfigurationChanges: Codable, Hashable, Sendable {
    var upsertControls: [AnimatedControl]?
    var removeControlIds: [String]?
    var upsertVariants: [AnimatedVariant]?
    var removeVariantIds: [String]?
}

nonisolated struct Plan: Codable, Hashable, Sendable {
    var engine: ControllableEngineID?
    var baseRevisionId: String?
    var configurationChanges: PlanConfigurationChanges?
    var version: Int
    var title: String
    var summary: String
    var kind: StickerKind
    var timing: PlanTiming
    var layers: [PlanLayer]
    var conceptPrompt: String?
    var posePreset: PosePreset?
    var configuration: AnimatedControlConfiguration?
}

nonisolated struct PlanTiming: Codable, Hashable, Sendable {
    var durationSeconds: Double
    var fps: Int
    var loop: StickerLoopBehavior
}

nonisolated struct PlanLayer: Codable, Identifiable, Hashable, Sendable {
    var layerId: String
    var name: String
    var source: PlanLayerSource
    var x: Double
    var y: Double
    var scaleX: Double
    var scaleY: Double
    var rotationDegrees: Double
    var animations: [PlanAnimation]
    var id: String { layerId }
}

/// One pose of a planned sprite character: what the body does across its frames, and how long each holds.
nonisolated struct PlanSpriteClip: Codable, Hashable, Sendable, Identifiable {
    nonisolated struct Frame: Codable, Hashable, Sendable {
        var duration: Double
    }
    var id: String
    var label: String
    var prompt: String
    var frames: [Frame]
}

/// One face of a planned sprite character.
nonisolated struct PlanSpriteExpression: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var label: String
    var prompt: String
}

/// What a planned layer is made of. Only `.generate` costs an image generation.
nonisolated enum PlanLayerSource: Codable, Hashable, Sendable {
    case generate(prompt: String)
    /// Artwork this sticker already has, carried into the revised plan untouched and for free.
    case existing(assetId: String)
    case text(text: String, color: String)
    case shape(shape: String, fill: String)
    case particle(preset: String, color: String)
    /// Frames the user captured, played back in place. Costs no generation and needs no concept
    /// render — the footage is its own reference, which is what makes such a plan capture-led.
    case sequence(assetId: String, frameCount: Int)
    /// A short generated clip of the whole subject, for motion keyframes cannot express — a
    /// turnaround, a change of angle, physics. Costs a still *and* a video generation.
    case video(prompt: String, motion: String, durationSeconds: Int)
    /// A controllable character: a still, one sprite sheet per named pose, and a sheet of face
    /// expressions the sticker's mood and pose controls select between. Costs `1 + poses + 1`.
    case sprite(prompt: String, clips: [PlanSpriteClip], expressions: [PlanSpriteExpression])
    /// A layer kind this build does not know about, kept so the card still renders.
    case unknown(kind: String)

    private enum CodingKeys: String, CodingKey {
        case kind, prompt, assetId, text, color, shape, fill, preset, frameCount, motion, durationSeconds, clips, expressions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "generate":
            self = .generate(prompt: (try? container.decode(String.self, forKey: .prompt)) ?? "")
        case "existing":
            self = .existing(assetId: (try? container.decode(String.self, forKey: .assetId)) ?? "")
        case "text":
            self = .text(
                text: (try? container.decode(String.self, forKey: .text)) ?? "",
                color: (try? container.decode(String.self, forKey: .color)) ?? "#FFFFFF"
            )
        case "shape":
            self = .shape(
                shape: (try? container.decode(String.self, forKey: .shape)) ?? "circle",
                fill: (try? container.decode(String.self, forKey: .fill)) ?? "#FFFFFF"
            )
        case "particle":
            self = .particle(
                preset: (try? container.decode(String.self, forKey: .preset)) ?? "sparkles",
                color: (try? container.decode(String.self, forKey: .color)) ?? "#FFFFFF"
            )
        case "sequence":
            self = .sequence(
                assetId: (try? container.decode(String.self, forKey: .assetId)) ?? "",
                frameCount: (try? container.decode(Int.self, forKey: .frameCount)) ?? 1
            )
        case "video":
            self = .video(
                prompt: (try? container.decode(String.self, forKey: .prompt)) ?? "",
                motion: (try? container.decode(String.self, forKey: .motion)) ?? "",
                durationSeconds: (try? container.decode(Int.self, forKey: .durationSeconds)) ?? 3
            )
        case "sprite":
            self = .sprite(
                prompt: (try? container.decode(String.self, forKey: .prompt)) ?? "",
                clips: (try? container.decode([PlanSpriteClip].self, forKey: .clips)) ?? [],
                expressions: (try? container.decode([PlanSpriteExpression].self, forKey: .expressions)) ?? []
            )
        default:
            self = .unknown(kind: kind)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .generate(let prompt):
            try container.encode("generate", forKey: .kind)
            try container.encode(prompt, forKey: .prompt)
        case .existing(let assetId):
            try container.encode("existing", forKey: .kind)
            try container.encode(assetId, forKey: .assetId)
        case .text(let text, let color):
            try container.encode("text", forKey: .kind)
            try container.encode(text, forKey: .text)
            try container.encode(color, forKey: .color)
        case .shape(let shape, let fill):
            try container.encode("shape", forKey: .kind)
            try container.encode(shape, forKey: .shape)
            try container.encode(fill, forKey: .fill)
        case .particle(let preset, let color):
            try container.encode("particle", forKey: .kind)
            try container.encode(preset, forKey: .preset)
            try container.encode(color, forKey: .color)
        case .sequence(let assetId, let frameCount):
            try container.encode("sequence", forKey: .kind)
            try container.encode(assetId, forKey: .assetId)
            try container.encode(frameCount, forKey: .frameCount)
        case .video(let prompt, let motion, let durationSeconds):
            try container.encode("video", forKey: .kind)
            try container.encode(prompt, forKey: .prompt)
            try container.encode(motion, forKey: .motion)
            try container.encode(durationSeconds, forKey: .durationSeconds)
        case .sprite(let prompt, let clips, let expressions):
            try container.encode("sprite", forKey: .kind)
            try container.encode(prompt, forKey: .prompt)
            try container.encode(clips, forKey: .clips)
            try container.encode(expressions, forKey: .expressions)
        case .unknown(let kind):
            try container.encode(kind, forKey: .kind)
        }
    }

    var label: String {
        switch self {
        case .generate: String(localized: "Generated")
        case .existing: String(localized: "Kept")
        case .text(let text, _): String(localized: "Text “\(text)”")
        case .shape(let shape, _): Self.humanized(shape)
        case .particle(let preset, _): Self.humanized(preset)
        case .sequence(_, let frameCount):
            frameCount == 1
                ? String(localized: "Capture")
                : String(localized: "Capture · \(frameCount) frames")
        case .video(_, _, let durationSeconds): String(localized: "Video · \(durationSeconds)s")
        case .sprite(_, let clips, let expressions):
            String(localized: "Character · \(clips.count) poses · \(expressions.count) moods")
        case .unknown(let kind): Self.humanized(kind)
        }
    }

    /// The generated prompt, for the card. A video layer's prompt describes the whole subject the
    /// same way a generate prompt describes a part, and so does a sprite's.
    var prompt: String? {
        switch self {
        case .generate(let prompt), .video(let prompt, _, _), .sprite(let prompt, _, _): prompt.isEmpty ? nil : prompt
        default: nil
        }
    }

    /// The poses and moods a sprite offers, for the configuration editor. Nil for everything else.
    var sprite: (clips: [PlanSpriteClip], expressions: [PlanSpriteExpression])? {
        if case .sprite(_, let clips, let expressions) = self { return (clips, expressions) }
        return nil
    }

    /// What the subject or camera does, for a video layer. Nil for everything else.
    var motion: String? {
        if case .video(_, let motion, _) = self, !motion.isEmpty { return motion }
        return nil
    }

    var isVideo: Bool { if case .video = self { true } else { false } }

    /// The server's identifiers are camelCase, and `capitalized` alone flattens `roundedRectangle`
    /// into "Roundedrectangle". Split on the humps first.
    private static func humanized(_ raw: String) -> String {
        var words: [String] = []
        var current = ""
        for character in raw {
            if character.isUppercase, !current.isEmpty {
                words.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.map(\.localizedCapitalized).joined(separator: " ")
    }

    /// Whether the layer pays for an image generation. A video layer does — its clip is animated
    /// from a still that has to be drawn first — and then pays for the clip on top.
    var isGenerated: Bool {
        switch self {
        case .generate, .video, .sprite: true
        default: false
        }
    }

    /// Whether the layer is drawn artwork rather than something the app renders. Reused artwork
    /// counts: it costs nothing, but on the canvas it is a picture, not a glyph or a primitive.
    var isArtwork: Bool {
        switch self {
        case .generate, .existing, .video: true
        default: false
        }
    }

    /// Whether the built layer keeps its aspect: content fitted inside its box, never stretched.
    ///
    /// Mirrors the server's `layerScaleIsAspectLocked`. Pixels are square frames and glyphs are
    /// fitted, so the build squares an unequal `scaleX`/`scaleY` off to the smaller of the two;
    /// the schematic has to draw that box, or the user approves a footprint that never appears.
    var isAspectLocked: Bool {
        switch self {
        case .generate, .existing, .sequence, .video, .text: true
        default: false
        }
    }
}

/// One named motion effect on a planned layer.
///
/// Decoded permissively: the server owns the effect vocabulary and may add types this build has
/// never heard of, which must degrade to a readable chip rather than failing the whole transcript.
nonisolated struct PlanAnimation: Codable, Hashable, Sendable {
    var type: String
    var delay: Double
    var duration: Double

    private enum CodingKeys: String, CodingKey { case type, delay, duration }

    /// Spelled out because the permissive `init(from:)` below suppresses the memberwise one.
    init(type: String, delay: Double = 0, duration: Double = 0.5) {
        self.type = type
        self.delay = delay
        self.duration = duration
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? container.decode(String.self, forKey: .type)) ?? "effect"
        delay = (try? container.decode(Double.self, forKey: .delay)) ?? 0
        duration = (try? container.decode(Double.self, forKey: .duration)) ?? 0
    }

    /// e.g. "popIn +0.3s". The delay is what makes a staggered reveal legible at a glance.
    var label: String {
        delay > 0
            ? "\(type) +\(Self.format(delay))s"
            : type
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2g", value)
    }
}

nonisolated struct ConfirmPlanResponse: Codable, Sendable {
    var message: AcceptedMessageReference
    var job: GenerationJobReference
}

nonisolated struct SelectPlanVersionRequest: Codable, Sendable {
    var currentPlanId: String
    var currentRevision: Int
}

nonisolated struct SelectPlanVersionResponse: Codable, Sendable {
    var messageId: String
    var plan: PlanRecord
}

nonisolated struct CancelPlanRequest: Codable, Sendable {
    var reason: String?
}

nonisolated struct CancelPlanResponse: Codable, Sendable {
    var planId: String
    var state: PlanState
    /// The turn a rejection with a reason starts, so the agent can redraft against it right away.
    /// Absent when the plan was dismissed without one — then nothing follows the rejection.
    var message: AcceptedMessageReference?
    var job: GenerationJobReference?
}
nonisolated enum ChatMessageStatus: String, Codable, Hashable, Sendable {
    case complete, streaming, failed

    var label: String {
        switch self {
        case .complete: String(localized: "Complete")
        case .streaming: String(localized: "In progress")
        case .failed: String(localized: "Failed")
        }
    }
}

nonisolated struct ChatAttachment: Codable, Identifiable, Hashable, Sendable {
    var assetId: String
    var kind: ChatAttachmentKind
    var targetLayerId: String?
    var id: String { assetId }
}
nonisolated enum ChatAttachmentKind: String, Codable, Hashable, Sendable { case reference, mask }

nonisolated struct Page<Value: Codable & Sendable>: Codable, Sendable {
    var data: [Value]
    var nextCursor: String?
    var items: [Value] { data }
}

nonisolated struct ChatMessagePage: Codable, Sendable {
    var data: [ChatMessage]
    var nextBeforeSequence: Int?

    var items: [ChatMessage] { data }
}

/// Whether this account is counting down to deletion, and until when.
///
/// `deletionScheduledAt` is the instant both this server and the identity provider act on, so the
/// app can show the real date rather than computing "seven days from now" and drifting from it.
nonisolated struct AccountDeletionState: Codable, Equatable, Sendable {
    var pendingDeletion: Bool
    var deletionScheduledAt: Date?
    var deletionRequestedAt: Date?

    static let none = AccountDeletionState(pendingDeletion: false, deletionScheduledAt: nil, deletionRequestedAt: nil)
}

nonisolated struct APIErrorEnvelope: Codable, Error, Equatable, Sendable { var error: APIErrorBody }

/// Without this the server's own words never reach the user.
///
/// `Error.localizedDescription` on a type that is merely `Error` synthesises "The operation couldn't
/// be completed. (StickerGeniOS.APIErrorEnvelope error 1.)" — so every considered message the API
/// returns was replaced, at the last step before display, by a sentence that says nothing. The
/// conformance is the fix; it compiled and read fine without it, which is why it survived.
extension APIErrorEnvelope: LocalizedError {
    var errorDescription: String? { error.message }
    /// Surfaced separately so a user reporting a problem can quote something that finds the request
    /// in the server's logs.
    var failureReason: String? { "\(error.code) · \(error.requestId)" }
}
nonisolated struct APIErrorBody: Codable, Equatable, Sendable {
    var code: String
    var message: String
    var requestId: String
    var details: JSONValue?
}

nonisolated enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

nonisolated extension JSONValue {
    /// Indented, key-sorted JSON for a person to read — the pet diary's debug section. Falls back
    /// to a description rather than failing, since it is only ever shown, never parsed.
    var prettyPrinted: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
            return String(describing: self)
        }
        return text
    }
}

nonisolated struct CreateStickerRequest: Codable, Sendable {
    var presets: CreationPresetSubmission?
    var title: String
    var kind: StickerKind
    var prompt: String
    var referenceAssetIds: [String]
    /// Build the character as a sprite the viewer can pose and change the mood of.
    ///
    /// Stored on the project, not on this turn: every later plan for it has to keep the controls,
    /// so a revision two turns from now cannot quietly flatten the character back into one drawing.
    /// Animated only, and refused in quick mode.
    var controllable = false
    var posePreset: PosePreset?
    /// Let the subject travel around the canvas instead of resting in place.
    ///
    /// Stored on the project for the same reason `controllable` is: a sticker asked to hold still
    /// has to hold still on every later revision too. Animated only. Absent means still, which is
    /// also the column's default, so an older build that never sends it gets a sticker that stays
    /// where it was put.
    var motion: Bool?
}

/// Turns an image the app already holds into a static sticker project, with nothing generated.
///
/// The artwork exists — a concept render on screen, or a picture the user chose — so the ordinary
/// create path would spend a generation redrawing it. What comes back is an ordinary sticker with
/// an accepted, active root revision, ready to have its exports published.
nonisolated struct ImportStickerRequest: Codable, Sendable {
    var title: String
    var assetId: String
}

nonisolated struct ImportStickerResponse: Codable, Sendable {
    var stickerId: String
    var threadId: String
    var revisionId: String
}

nonisolated struct UpdateStickerRequest: Codable, Sendable {
    var title: String
}

nonisolated struct CreateStickerResponse: Codable, Sendable {
    var stickerId: String
    var threadId: String
    var initialMessageId: String
    var job: GenerationJobReference
}

nonisolated enum ChatIntent: String, Codable, Sendable { case generate, edit, animate, chat }

nonisolated struct ChatAttachmentRequest: Codable, Sendable {
    var assetId: String
    var kind: ChatAttachmentKind
    var targetLayerId: String?
}

nonisolated struct SendChatMessageRequest: Codable, Sendable {
    var planPoseUpdate: PlanPoseUpdate?
    var text: String
    var intent: ChatIntent
    var attachments: [ChatAttachmentRequest]
    var targetLayerId: String?
    var imagePlacement: ImagePlacement
    var baseRevisionId: String?
}

nonisolated enum ImagePlacement: String, Codable, Sendable { case add, replace }

nonisolated struct SendChatMessageResponse: Codable, Sendable {
    var message: AcceptedMessageReference
    var job: GenerationJobReference
}

nonisolated struct RetryChatMessageResponse: Codable, Sendable {
    var messageId: String
    var job: GenerationJobReference
}

nonisolated struct CancelGenerationResponse: Codable, Sendable {
    var jobId: String
    var state: GenerationJobState
}

/// The APNs device token, uploaded so the server can announce a turn the user walked away from.
///
/// `environment` travels with it because a sandbox token is rejected by the production APNs host
/// and vice versa, and only the build knows which one it was signed for.
nonisolated struct RegisterDeviceRequest: Codable, Sendable {
    var token: String
    var platform: String
    var environment: String
    var bundleId: String?
    var appVersion: String?
}

nonisolated struct DeleteStickerResponse: Codable, Sendable {
    var stickerId: String
    var status: StickerDeletionStatus
    var job: DeletionJobReference
}

nonisolated enum StickerDeletionStatus: String, Codable, Sendable {
    case deleting
    case deleteFailed = "delete_failed"
}

nonisolated struct DeletionJobReference: Codable, Sendable {
    var id: String
    var state: GenerationJobState
    var workflowRunId: String?
    var retryable: Bool
}

nonisolated struct AcceptedMessageReference: Codable, Sendable {
    var id: String
    var status: ChatMessageStatus
}

nonisolated struct GenerationJobReference: Codable, Sendable {
    var id: String
    var state: GenerationJobState
    var workflowRunId: String?
    var eventsUrl: String
}

nonisolated enum GenerationJobState: String, Codable, Sendable { case queued, running, waiting, succeeded, failed, cancelled }

nonisolated struct UploadIntentRequest: Codable, Sendable {
    var stickerId: String?
    var kind: AssetKind
    var mimeType: String
    var byteSize: Int
    var filename: String
    var sha256: String?
    /// Required for, and rejected on anything but, `kind == .sequence`.
    var sequence: SequenceMetadata?
}

nonisolated struct UploadIntentResponse: Codable, Sendable {
    var asset: AssetRecord
    var upload: PresignedUpload
}

nonisolated struct PresignedUpload: Codable, Sendable {
    var url: URL
    var expiresAt: Date
    var headers: [String: String]
}

nonisolated struct CompleteUploadRequest: Codable, Sendable { var sha256: String? }

nonisolated struct PublishExportsRequest: Codable, Sendable {
    var revisionId: String
    var pngAssetId: String?
    /// No `gifAssetId` twin: the server accepts only `apng` for a new publish, and this app has no
    /// way left to produce the other one.
    var apngAssetId: String?
    var mp4AssetId: String?
    var systemAssetId: String
    /// The 408 px and 300 px copies of the sharing rendition, sent as a pair or not at all. The
    /// server refuses one without the other rather than half-populating a sticker's size set.
    var attachmentMediumAssetId: String?
    var attachmentSmallAssetId: String?
    /// The WebP copy of the sharing rendition, when the encode succeeded.
    ///
    /// Optional on both ends and never load-bearing: the server publishes a complete sticker
    /// without it, and WinkySticker falls back to the APNG. Sent as `nil` rather than failing the
    /// publish when the encoder could not produce one.
    var webpAssetId: String?
    var mp4Background: StickerMP4BackgroundV1?
    /// Sent only as `.still`, and only for an animated sticker whose motion could not be squeezed
    /// under Apple's 500 KB ceiling at any rung of the export ladder. Omitting it means the ordinary
    /// case — an animated rendition for an animated sticker — which is what the server assumes.
    var systemRenditionKind: SystemRenditionKind?
    var playbackDocument: AnimatedDocument?
}

nonisolated enum SystemRenditionKind: String, Codable, Sendable {
    case animated
    case still
}

nonisolated struct PublishExportsResponse: Codable, Sendable {
    var job: GenerationJobReference
}

/// The messenger renditions for one already-published revision.
///
/// Its own request rather than more fields on `PublishExportsRequest`, because it is sent at a
/// different moment: a publish uploads the whole export set at once, while these arrive later, when
/// the sticker is put into a pack. Every field is optional — artwork that fits WhatsApp's ceiling
/// can still miss Telegram's, and binding the one that worked beats sending neither.
nonisolated struct MessengerRenditionsRequest: Codable, Sendable {
    var revisionId: String
    var whatsappAssetId: String?
    var telegramAssetId: String?
    var emoji: String?
}

/// A document edited on device, sent back as a new revision.
nonisolated struct SaveEditedDocumentRequest: Codable, Sendable {
    var parentRevisionId: String
    var document: AnimatedDocument
    var note: String?
}

/// Deliberately small: the server stores this response verbatim in the request's idempotency row,
/// so echoing the document back would keep a second copy of it around for a day.
nonisolated struct SaveEditedDocumentResponse: Codable, Sendable {
    var revisionId: String
    var parentRevisionId: String?
    var candidateState: RevisionCandidateState
    var createdAt: String
    var stickerStatus: StickerStatus
}

nonisolated struct RevisionTransitionResponse: Codable, Sendable {
    var revisionId: String
    var candidateState: RevisionCandidateState?
    var activeRevisionId: String?
    var revertedFromRevisionId: String?
}

nonisolated struct AssetDownload: Codable, Sendable {
    var url: URL
    var expiresAt: Date
    var asset: AssetRecord
}
