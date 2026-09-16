// The server's generation event stream: the envelope every SSE frame carries, its payload, and the
// event types a turn can report. Split out of `APIContracts.swift` so the streaming wire format has
// one file of its own.
//
// Everything below the envelope decodes leniently on purpose — a throw here would abort the stream
// and the terminal event that ends a turn would never arrive.

import AnimatedView
import Foundation

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
    var message: String?
    var progress: Double?
    var stage: String?
    var completedUnits: Int?
    var totalUnits: Int?
    var progressLabel: String?
    var clearProgress: Bool?
    /// One short, human line about what the turn is doing inside the current stage — see
    /// `reportTurnNote` on the server. Written for the screen, not derived from a log payload.
    var note: String?
    /// What this one model call spent, as a delta the reader adds up — see `reportTurnWork` on the
    /// server. A turn's totals are the sum of these, and the stream delivers each event once.
    var outputTokens: Int?
    var imagesDrawn: Int?
    var clipsFilmed: Int?
    var messageId: String?
    var revisionId: String?
    var document: AnimatedDocument?
    var toolCallId: String?
    var toolName: String?
    var toolStatus: ChatMessageStatus?
    var toolDetails: String?
    var cancelled: Bool?
    /// The assistant turn, shipped inline so the chat can render it without a refetch.
    var assistantMessage: ChatMessage?

    enum CodingKeys: String, CodingKey {
        case message, progress, stage, messageId, revisionId, document
        case completedUnits, totalUnits, progressLabel, clearProgress
        case note, outputTokens, imagesDrawn, clipsFilmed
        case toolCallId, toolName, toolStatus, toolDetails, cancelled, assistantMessage
    }
}

nonisolated extension GenerationEventData {
    private enum LegacyProgressKeys: String, CodingKey { case completedParts, totalParts }
    /// Every field is optional *and* failure-tolerant: a payload shape this app version does not
    /// understand degrades that one field to `nil` instead of poisoning the whole event. Forward
    /// compatible metadata is ignored entirely.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyProgressKeys.self)
        self.init(
            message: (try? c.decodeIfPresent(String.self, forKey: .message)) ?? nil,
            progress: (try? c.decodeIfPresent(Double.self, forKey: .progress)) ?? nil,
            stage: (try? c.decodeIfPresent(String.self, forKey: .stage)) ?? nil,
            completedUnits: (try? c.decodeIfPresent(Int.self, forKey: .completedUnits))
                ?? (try? legacy.decodeIfPresent(Int.self, forKey: .completedParts)),
            totalUnits: (try? c.decodeIfPresent(Int.self, forKey: .totalUnits))
                ?? (try? legacy.decodeIfPresent(Int.self, forKey: .totalParts)),
            progressLabel: (try? c.decodeIfPresent(String.self, forKey: .progressLabel)) ?? nil,
            clearProgress: (try? c.decodeIfPresent(Bool.self, forKey: .clearProgress)) ?? nil,
            note: (try? c.decodeIfPresent(String.self, forKey: .note)) ?? nil,
            outputTokens: (try? c.decodeIfPresent(Int.self, forKey: .outputTokens)) ?? nil,
            imagesDrawn: (try? c.decodeIfPresent(Int.self, forKey: .imagesDrawn)) ?? nil,
            clipsFilmed: (try? c.decodeIfPresent(Int.self, forKey: .clipsFilmed)) ?? nil,
            messageId: (try? c.decodeIfPresent(String.self, forKey: .messageId)) ?? nil,
            revisionId: (try? c.decodeIfPresent(String.self, forKey: .revisionId)) ?? nil,
            document: (try? c.decodeIfPresent(AnimatedDocument.self, forKey: .document)) ?? nil,
            toolCallId: (try? c.decodeIfPresent(String.self, forKey: .toolCallId)) ?? nil,
            toolName: (try? c.decodeIfPresent(String.self, forKey: .toolName)) ?? nil,
            toolStatus: (try? c.decodeIfPresent(ChatMessageStatus.self, forKey: .toolStatus)) ?? nil,
            toolDetails: (try? c.decodeIfPresent(String.self, forKey: .toolDetails)) ?? nil,
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
