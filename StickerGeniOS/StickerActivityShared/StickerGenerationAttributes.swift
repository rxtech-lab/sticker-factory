import ActivityKit
import Foundation

/// Keep this content state in sync with the server's liveActivitySnapshot payload.
nonisolated struct StickerGenerationAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        var message: String
        var phase: String
        var eventID: Int64 = 0

        var isFinished: Bool { ["completed", "failed", "cancelled"].contains(phase) }
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
