import AnimatedView
import Foundation

nonisolated struct Sticker: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var kind: StickerKind
    var status: StickerStatus
    var activeRevisionId: String?
    var createdAt: Date
    var updatedAt: Date
    var previewAsset: AssetRecord?
    var systemSticker: SystemStickerRecord?
}

nonisolated enum StickerStatus: String, Codable, CaseIterable, Hashable, Sendable { case draft, published, deleting }

nonisolated struct StickerDetail: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var kind: StickerKind
    var status: StickerStatus
    var activeRevisionId: String?
    var createdAt: Date
    var updatedAt: Date
    var previewAsset: AssetRecord?
    var systemSticker: SystemStickerRecord?
    var revisions: [StickerRevision]

    var sticker: Sticker {
        .init(
            id: id,
            title: title,
            kind: kind,
            status: status,
            activeRevisionId: activeRevisionId,
            createdAt: createdAt,
            updatedAt: updatedAt,
            previewAsset: previewAsset,
            systemSticker: systemSticker
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
    var gifAssetId: String?
    var mp4AssetId: String?
    var systemAssetId: String?
    var createdAt: Date
    var decidedAt: Date?

    var state: RevisionCandidateState {
        get { candidateState }
        set { candidateState = newValue }
    }

    var containsMotion: Bool {
        document.kind == .animated && document.layers.contains { !$0.animation.allKeyframes.isEmpty }
    }

    var canPublishExports: Bool {
        document.kind == .static || containsMotion
    }

    var hasPublishedExports: Bool {
        guard systemAssetId != nil else { return false }
        return document.kind == .static
            ? pngAssetId != nil
            : gifAssetId != nil && mp4AssetId != nil
    }
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
    var frameCount: Int? = nil
    var durationSeconds: Double? = nil
    var fps: Double? = nil
    var sha256: String?
    var hasAlpha: Bool?
    var createdAt: Date?
}

nonisolated enum AssetKind: String, Codable, CaseIterable, Hashable, Sendable {
    case reference, mask, master, preview, gif, mp4, system
    case chatAttachment = "chat_attachment"
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
    var plan: PlanRecord? = nil
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
    var decisionReason: String?
    var supersedesId: String?
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

nonisolated struct Plan: Codable, Hashable, Sendable {
    var version: Int
    var title: String
    var summary: String
    var kind: StickerKind
    var timing: PlanTiming
    var layers: [PlanLayer]
    var conceptPrompt: String?
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

/// What a planned layer is made of. Only `.generate` costs an image generation.
nonisolated enum PlanLayerSource: Codable, Hashable, Sendable {
    case generate(prompt: String)
    /// Artwork this sticker already has, carried into the revised plan untouched and for free.
    case existing(assetId: String)
    case text(text: String, color: String)
    case shape(shape: String, fill: String)
    case particle(preset: String, color: String)
    /// A layer kind this build does not know about, kept so the card still renders.
    case unknown(kind: String)

    private enum CodingKeys: String, CodingKey { case kind, prompt, assetId, text, color, shape, fill, preset }

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
        case .unknown(let kind): Self.humanized(kind)
        }
    }

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

    var isGenerated: Bool { if case .generate = self { true } else { false } }

    /// Whether the layer is drawn artwork rather than something the app renders. Reused artwork
    /// counts: it costs nothing, but on the canvas it is a picture, not a glyph or a primitive.
    var isArtwork: Bool {
        switch self {
        case .generate, .existing: true
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

nonisolated struct APIErrorEnvelope: Codable, Error, Equatable, Sendable { var error: APIErrorBody }
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
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else {
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

nonisolated struct CreateStickerRequest: Codable, Sendable {
    var title: String
    var kind: StickerKind
    var prompt: String
    var referenceAssetIds: [String]
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
    var gifAssetId: String?
    var mp4AssetId: String?
    var systemAssetId: String
    var mp4Background: StickerMP4BackgroundV1?
    /// Sent only as `.still`, and only for an animated sticker whose motion could not be squeezed
    /// under Apple's 500 KB ceiling at any rung of the export ladder. Omitting it means the ordinary
    /// case — an animated rendition for an animated sticker — which is what the server assumes.
    var systemRenditionKind: SystemRenditionKind?
}

nonisolated enum SystemRenditionKind: String, Codable, Sendable {
    case animated
    case still
}

nonisolated struct PublishExportsResponse: Codable, Sendable {
    var job: GenerationJobReference
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

nonisolated struct GenerationEvent: Codable, Identifiable, Hashable, Sendable {
    var id: Int64
    var jobId: String
    var type: GenerationEventType
    var createdAt: Date
    var data: GenerationEventData

    enum CodingKeys: String, CodingKey { case id, jobId, type, createdAt, data }
}

nonisolated extension GenerationEvent {
    /// Only the envelope is strict. Everything below it degrades rather than throws, because a
    /// throw here aborts the whole event stream and the terminal event that ends a turn would
    /// never be delivered.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(Int64.self, forKey: .id),
            jobId: try container.decode(String.self, forKey: .jobId),
            type: try container.decode(GenerationEventType.self, forKey: .type),
            createdAt: (try? container.decode(Date.self, forKey: .createdAt)) ?? Date(),
            data: (try? container.decode(GenerationEventData.self, forKey: .data)) ?? .init()
        )
    }
}

nonisolated struct GenerationEventData: Codable, Hashable, Sendable {
    var message: String? = nil
    var progress: Double? = nil
    var messageId: String? = nil
    var revisionId: String? = nil
    var document: AnimatedDocument? = nil
    var toolCallId: String? = nil
    var toolName: String? = nil
    var toolStatus: ChatMessageStatus? = nil
    var cancelled: Bool? = nil
    /// The assistant turn, shipped inline so the chat can render it without a refetch.
    var assistantMessage: ChatMessage? = nil

    enum CodingKeys: String, CodingKey {
        case message, progress, messageId, revisionId, document
        case toolCallId, toolName, toolStatus, cancelled, assistantMessage
    }
}

nonisolated extension GenerationEventData {
    /// Every field is optional *and* failure-tolerant: a payload shape this app version does not
    /// understand degrades that one field to `nil` instead of poisoning the whole event. Forward
    /// compatible metadata is ignored entirely.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            message: (try? c.decodeIfPresent(String.self, forKey: .message)) ?? nil,
            progress: (try? c.decodeIfPresent(Double.self, forKey: .progress)) ?? nil,
            messageId: (try? c.decodeIfPresent(String.self, forKey: .messageId)) ?? nil,
            revisionId: (try? c.decodeIfPresent(String.self, forKey: .revisionId)) ?? nil,
            document: (try? c.decodeIfPresent(AnimatedDocument.self, forKey: .document)) ?? nil,
            toolCallId: (try? c.decodeIfPresent(String.self, forKey: .toolCallId)) ?? nil,
            toolName: (try? c.decodeIfPresent(String.self, forKey: .toolName)) ?? nil,
            toolStatus: (try? c.decodeIfPresent(ChatMessageStatus.self, forKey: .toolStatus)) ?? nil,
            cancelled: (try? c.decodeIfPresent(Bool.self, forKey: .cancelled)) ?? nil,
            assistantMessage: (try? c.decodeIfPresent(ChatMessage.self, forKey: .assistantMessage)) ?? nil
        )
    }
}

nonisolated enum GenerationEventType: String, Codable, Hashable, Sendable {
    case queued, started, progress, document, candidate, waiting, completed, failed
    /// An event type introduced by a newer server. Decoding must never fail on one:
    /// a throw would end the stream and strand the turn.
    case unknown
}

nonisolated extension GenerationEventType {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

nonisolated struct AssetDownload: Codable, Sendable {
    var url: URL
    var expiresAt: Date
    var asset: AssetRecord
}

nonisolated enum StickerExportFormat: String, Codable, CaseIterable, Hashable, Sendable { case png, gif, apng, mp4 }

nonisolated struct LocalExportMetadata: Codable, Hashable, Sendable {
    var format: StickerExportFormat
    var width: Int
    var height: Int
    var byteCount: Int
    var durationSeconds: Double?
    var fps: Int?
    var hasAlpha: Bool
}
