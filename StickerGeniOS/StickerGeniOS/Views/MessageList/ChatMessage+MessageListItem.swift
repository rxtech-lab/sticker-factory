import Foundation

/// Status rows are deliberately *not* accessories: a tool/status row is real
/// work the user can read, it occupies the turn, and counting it as content is
/// what lets a long generation eventually release the pin and follow the bottom.
/// Only the typing indicator is chrome, and that is rendered as trailing content
/// rather than as a message.
///
/// `StickerChatView` filters out the *phase* rows before building the list — the
/// navigation bar's title chip carries those — but the model's own tool calls
/// still come through here and are still content.
nonisolated extension ChatMessage: MessageListItem {
    var messageID: String { id }
    /// A device edit carries `role: .user` so the agent reads it as the user's doing, but it is a
    /// divider, not a turn. Pinning it to the top would reserve a viewport of empty space under a
    /// one-line rule and, worse, do it for an edit that nobody is waiting on a reply to.
    var isUserMessage: Bool { role == .user && kind != .deviceEdit }
}
