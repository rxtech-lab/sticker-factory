import Foundation

/// What the list should do in response to a transcript or streaming change.
///
/// Nothing here ever asks the list to follow the bottom: the transcript does not
/// chase a streaming reply. The only movement is placing a freshly sent turn.
nonisolated enum MessageListPinningAction<ID: Hashable & Sendable>: Equatable {
    case none
    case clearPin
    /// Place this user message at the top of the viewport.
    case pinUserMessageToTop(ID)
    /// More content arrived under a held pin. The reserved tail spacing absorbs
    /// it, so the list deliberately does nothing — the turn stays where the user
    /// last saw it.
    case repinUserMessageToTop(ID)
    /// Stop re-asserting the position. The reserved spacing survives, because it
    /// is keyed off `pinnedUserMessageID` rather than off the pin being active.
    case releasePin
}

/// Decides when the latest user message is pinned to the top of the viewport.
///
/// Pure state machine — the view applies the returned action, which keeps the
/// scroll choreography testable without a running app.
///
/// Two levels of state, and the distinction matters:
/// - `pinnedUserMessageID` is **persistent**. It keeps the reserved tail spacer
///   sized, and survives the pin being released.
/// - `isPinningUserMessage` is **transient**. It says whether we are actively
///   re-asserting the scroll position.
///
/// Releasing the pin deliberately does *not* clear the id.
nonisolated struct MessageListPinningController<ID: Hashable & Sendable>: Equatable {
    private(set) var pinnedUserMessageID: ID?
    private(set) var isPinningUserMessage: Bool

    init(pinnedUserMessageID: ID? = nil, isPinningUserMessage: Bool = false) {
        self.pinnedUserMessageID = pinnedUserMessageID
        self.isPinningUserMessage = isPinningUserMessage
    }

    mutating func handleLastMessageChange(
        id: ID?,
        isUserMessage: Bool,
        isStreaming: Bool
    ) -> MessageListPinningAction<ID> {
        guard let id else {
            clear()
            return .clearPin
        }

        if isUserMessage {
            pinnedUserMessageID = id
            isPinningUserMessage = true
            return .pinUserMessageToTop(id)
        }

        guard isPinningUserMessage, let pinnedUserMessageID else { return .none }

        if isStreaming {
            return .repinUserMessageToTop(pinnedUserMessageID)
        }

        releasePin()
        return .releasePin
    }

    /// Re-establish the reservation for a transcript that arrives already
    /// populated — a reopened chat, a cold launch, a tab switch.
    ///
    /// The reserved tail space is what makes the newest turn readable from its
    /// start, and that is no less true a day later than a second later: without
    /// this, a reloaded transcript has no "just sent" moment to pin, so it comes
    /// back with the reservation gone and the reader dropped at the raw end of
    /// the content.
    ///
    /// Persistent state only — no action to apply, and deliberately not the
    /// re-asserting state: nothing is being sent, so there is no incoming content
    /// to hold a position against. The caller reserves the space and places once.
    mutating func restoreLatestTurn(id: ID) {
        pinnedUserMessageID = id
        isPinningUserMessage = false
    }

    mutating func handleStreamingChange(
        oldValue: Bool,
        newValue: Bool
    ) -> MessageListPinningAction<ID> {
        guard oldValue && !newValue else { return .none }
        guard isPinningUserMessage else { return .none }
        releasePin()
        return .releasePin
    }

    mutating func releasePin() {
        isPinningUserMessage = false
    }

    mutating func clear() {
        pinnedUserMessageID = nil
        isPinningUserMessage = false
    }
}
