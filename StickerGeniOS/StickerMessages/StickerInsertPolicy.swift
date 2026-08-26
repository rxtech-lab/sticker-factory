import Foundation
import Messages

enum StickerInsertOutcome: Equatable, Sendable {
    case inserted
    /// The host refused a programmatic insert in this presentation context.
    case unavailableInContext
    case failed
    case noConversation
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

    static func hint(
        for outcome: StickerInsertOutcome,
        context: MSMessagesAppPresentationContext
    ) -> String? {
        switch outcome {
        case .inserted:
            return nil
        case .unavailableInContext, .noConversation:
            return "Press and hold a sticker to drag it in."
        case .failed:
            return context == .media
                ? "Press and hold a sticker to drag it in."
                : "That sticker couldn't be added. Try again."
        }
    }
}
