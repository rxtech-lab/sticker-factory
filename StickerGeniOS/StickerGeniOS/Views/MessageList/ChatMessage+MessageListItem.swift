import Foundation

/// Status rows are deliberately *not* accessories: a tool/status row is real
/// work the user can read, it occupies the turn, and counting it as content is
/// what lets a long generation eventually release the pin and follow the bottom.
/// Only the typing indicator is chrome, and that is rendered as trailing content
/// rather than as a message.
nonisolated extension ChatMessage: MessageListItem {
    var messageID: String { id }
    var isUserMessage: Bool { role == .user }
}
