import Foundation

/// A chat send that failed, and whether the server might have accepted it anyway.
///
/// The distinction matters because the composer restores the user's text on failure. A request the
/// server *rejected* created nothing, so giving the text back is right. A request that timed out in
/// transit, or whose 2xx response failed to decode, very likely did create the message and start a
/// job — putting the text back there leaves the user staring at a turn that is already running,
/// one tap away from sending it a second time.
nonisolated struct SendMessageFailure: Error, LocalizedError {
    let underlying: any Error
    let mayHaveBeenDelivered: Bool
    var errorDescription: String? { underlying.localizedDescription }
}

nonisolated enum StickerStoreError: Error, LocalizedError {
    case turnAlreadyComputing
    case noRetryableTurn
    var errorDescription: String? {
        switch self {
        case .turnAlreadyComputing: String(localized: "Wait for the current AI edit to finish before sending another.")
        case .noRetryableTurn: String(localized: "The failed AI turn no longer has a retryable source message.")
        }
    }
}
