import Foundation
import Messages

enum StickerInsertOutcome: Equatable, Sendable {
    case inserted
    /// The host refused a programmatic insert in this presentation context.
    case unavailableInContext
    case failed
    case noConversation
}

/// Filters the duplicate callbacks that a quick double tap (or a re-entrant host gesture) can
/// produce without preventing someone from choosing two different stickers in quick succession.
struct StickerInsertGate {
    static let duplicateWindow: TimeInterval = 0.6

    private var lastAcceptedStickerURL: URL?
    private var lastAcceptedUptime: TimeInterval?

    mutating func shouldInsert(stickerURL: URL, uptime: TimeInterval) -> Bool {
        if lastAcceptedStickerURL == stickerURL,
           let lastAcceptedUptime,
           uptime >= lastAcceptedUptime,
           uptime - lastAcceptedUptime < Self.duplicateWindow {
            return false
        }

        lastAcceptedStickerURL = stickerURL
        lastAcceptedUptime = uptime
        return true
    }
}

/// Pure branching for insert results so it stays testable without a real `MSConversation`.
enum StickerInsertPolicy {
    /// `NSError` is not `Sendable`, so callers reduce it to these scalars inside the
    /// completion handler before hopping back to the main actor.
    static func outcome(domain: String?, code: Int?) -> StickerInsertOutcome {
        guard let domain, let code else { return .inserted }
        // Apple does not document which domain `insertSticker:` reports under, and
        // MSMessageError.h declares both.
        let messagesDomains: Set<String> = [MSMessagesErrorDomain, MSStickersErrorDomain]
        if messagesDomains.contains(domain),
           code == MSMessageErrorCode.apiUnavailableInPresentationContext.rawValue {
            return .unavailableInContext
        }
        return .failed
    }

    /// Which app is asking, because the recovery advice is not the same.
    ///
    /// Telling someone to peel and drag is right in the sticker app and actively wrong in the
    /// full-size one: peel/drag is `MSStickerView`'s own gesture and inserts the ≤500 KB
    /// `MSSticker`, so following that hint silently sends the small image they opened the
    /// full-size app to avoid.
    enum StickerInsertSurface: Sendable {
        case sticker
        case fullSize
    }

    static func hint(
        for outcome: StickerInsertOutcome,
        context: MSMessagesAppPresentationContext,
        surface: StickerInsertSurface = .sticker
    ) -> String? {
        switch (surface, outcome) {
        case (_, .inserted):
            return nil
        case (.sticker, .unavailableInContext), (.sticker, .noConversation):
            return String(localized: "Press and hold a sticker to drag it in.")
        case (.sticker, .failed):
            return context == .media
                ? String(localized: "Press and hold a sticker to drag it in.")
                : String(localized: "That sticker couldn't be added. Try again.")
        case (.fullSize, .unavailableInContext), (.fullSize, .noConversation):
            return String(localized: "Open a conversation to send a full-size image.")
        case (.fullSize, .failed):
            return String(localized: "That image couldn't be sent. Try again.")
        }
    }
}
