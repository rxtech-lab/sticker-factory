import ActivityKit
import Foundation

nonisolated enum GenerationMascotPose: String, CaseIterable, Sendable {
    case queued, running, waiting, stale, completed, failed, cancelled

    var assetName: String { "ActivityMascot" + rawValue.capitalized }
}

/// Keep this content state in sync with the server's liveActivitySnapshot payload.
nonisolated struct StickerGenerationAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        var message: String
        var phase: String
        var eventID: Int64 = 0
        var completedUnits: Int?
        var totalUnits: Int?
        var progressLabel: String?

        enum CodingKeys: String, CodingKey {
            case message, phase, eventID, completedUnits, totalUnits, progressLabel
        }

        /// Counts apply to the current measurable stage, not to the entire generation.
        var unitProgress: Double? {
            guard !isFinished, let completedUnits, let totalUnits,
                  totalUnits > 0, completedUnits >= 0, completedUnits <= totalUnits else { return nil }
            return Double(completedUnits) / Double(totalUnits)
        }

        var progressCountText: String? {
            guard unitProgress != nil, let completedUnits, let totalUnits else { return nil }
            return "\(completedUnits)/\(totalUnits)"
        }

        var isFinished: Bool { ["completed", "failed", "cancelled"].contains(phase) }

        /// Terminal phases deliberately win over stale delivery so the final outcome is never
        /// replaced by an out-of-date pose. Unrecognized working phases use the focused pose.
        func mascotPose(isStale: Bool) -> GenerationMascotPose {
            switch phase {
            case "completed": return .completed
            case "failed": return .failed
            case "cancelled": return .cancelled
            default: break
            }
            if isStale { return .stale }
            switch phase {
            case "queued": return .queued
            case "waiting": return .waiting
            default: return .running
            }
        }

        var symbol: String {
            switch phase {
            case "completed": "checkmark.circle.fill"
            case "failed": "exclamationmark.circle.fill"
            case "cancelled": "stop.circle.fill"
            case "waiting": "pause.circle.fill"
            default: "sparkles"
            }
        }
    }

    var jobID: String
    var stickerID: String
    var title: String
    var startedAt: Date

    var stickerURL: URL? { URL(string: "stickerfactory://sticker/\(stickerID)") }
}

nonisolated extension StickerGenerationAttributes.ContentState {
    private enum LegacyProgressKeys: String, CodingKey { case completedParts, totalParts }

    /// Activities and pushes can outlive the app/server version that created them.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyProgressKeys.self)
        self.init(
            message: try values.decode(String.self, forKey: .message),
            phase: try values.decode(String.self, forKey: .phase),
            eventID: try values.decodeIfPresent(Int64.self, forKey: .eventID) ?? 0,
            completedUnits: try values.decodeIfPresent(Int.self, forKey: .completedUnits)
                ?? legacy.decodeIfPresent(Int.self, forKey: .completedParts),
            totalUnits: try values.decodeIfPresent(Int.self, forKey: .totalUnits)
                ?? legacy.decodeIfPresent(Int.self, forKey: .totalParts),
            progressLabel: try values.decodeIfPresent(String.self, forKey: .progressLabel)
        )
    }
}
