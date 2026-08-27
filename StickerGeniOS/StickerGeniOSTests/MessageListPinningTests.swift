import Foundation
import Testing

@testable import StickerGeniOS

/// The pinning state machine behind the chat transcript.
///
/// Worth testing directly because the behaviour it drives — the user's message
/// jumping to the top and staying there while the sticker is generated — is
/// otherwise only observable by watching the app, and the failure modes are
/// subtle (a pin that never releases, or one that releases a frame too early).
@Suite("Message list pinning")
struct MessageListPinningTests {

    private typealias Controller = MessageListPinningController<Int>
    private typealias Action = MessageListPinningAction<Int>

    @Test("A new user message pins to the top")
    func userMessagePins() {
        var controller = Controller()
        let action = controller.handleLastMessageChange(id: 1, isUserMessage: true, isStreaming: false)
        #expect(action == .pinUserMessageToTop(1))
        #expect(controller.pinnedUserMessageID == 1)
        #expect(controller.isPinningUserMessage)
    }

    @Test("Assistant content arriving while streaming re-pins rather than releasing")
    func streamingRepins() {
        var controller = Controller()
        _ = controller.handleLastMessageChange(id: 1, isUserMessage: true, isStreaming: true)
        let action = controller.handleLastMessageChange(id: 2, isUserMessage: false, isStreaming: true)
        #expect(action == .repinUserMessageToTop(1))
        #expect(controller.isPinningUserMessage)
    }

    @Test("Assistant content arriving after streaming ends releases the pin")
    func nonStreamingContentReleases() {
        var controller = Controller()
        _ = controller.handleLastMessageChange(id: 1, isUserMessage: true, isStreaming: true)
        let action = controller.handleLastMessageChange(id: 2, isUserMessage: false, isStreaming: false)
        #expect(action == .releasePin)
        #expect(!controller.isPinningUserMessage)
    }

    @Test("Releasing the pin keeps the tracked id, so the tail spacer stays sized")
    func releaseKeepsTrackedID() {
        var controller = Controller()
        _ = controller.handleLastMessageChange(id: 1, isUserMessage: true, isStreaming: true)
        controller.releasePin()
        #expect(!controller.isPinningUserMessage)
        // This is the distinction the whole layout depends on: the reserved
        // space is keyed off the id, not off the transient flag.
        #expect(controller.pinnedUserMessageID == 1)
    }

    @Test("The end of streaming releases a held pin")
    func streamingEndReleases() {
        var controller = Controller()
        _ = controller.handleLastMessageChange(id: 1, isUserMessage: true, isStreaming: true)
        #expect(controller.handleStreamingChange(oldValue: true, newValue: false) == .releasePin)
    }

    @Test("Streaming starting is not a release")
    func streamingStartIsNoop() {
        var controller = Controller()
        #expect(controller.handleStreamingChange(oldValue: false, newValue: true) == .none)
    }

    @Test("With no pin held, the end of streaming moves nothing")
    func unpinnedStreamingEnd() {
        var controller = Controller()
        // The transcript never follows the bottom — see `MessageList`. With nothing
        // pinned there is no position to release, so a finished stream is inert.
        #expect(controller.handleStreamingChange(oldValue: true, newValue: false) == .none)
    }

    @Test("An emptied transcript clears the pin")
    func emptyTranscriptClears() {
        var controller = Controller()
        _ = controller.handleLastMessageChange(id: 1, isUserMessage: true, isStreaming: true)
        let action = controller.handleLastMessageChange(id: nil, isUserMessage: false, isStreaming: false)
        #expect(action == .clearPin)
        #expect(controller.pinnedUserMessageID == nil)
    }

    @Test("A reopened transcript reserves space without re-asserting the position")
    func restoreReservesWithoutPinning() {
        var controller = Controller()
        controller.restoreLatestTurn(id: 1)
        #expect(controller.pinnedUserMessageID == 1)
        // Nothing is being sent, so there is no incoming content to hold a position
        // against: the caller places once and leaves the reader alone.
        #expect(!controller.isPinningUserMessage)
    }
}

/// Identity the list depends on, on the app's own chat model.
@Suite("Chat message list identity")
struct ChatMessageListItemTests {

    @Test("A user message is the pin target; assistant and status rows are not")
    func userMessageIdentity() {
        let user = message(id: "m1", role: .user, kind: .animation)
        let assistant = message(id: "m2", role: .assistant, kind: .animation)
        let status = message(id: "m3", role: .system, kind: .status)

        #expect(user.messageID == "m1")
        #expect(user.isUserMessage)
        #expect(!assistant.isUserMessage)
        // Status rows are content, not chrome: they occupy the turn and count
        // toward it filling the viewport.
        #expect(!status.isMessageListAccessory)
    }

    @Test("A device edit is not a pin target even though it is posted as the user")
    func deviceEditIsNotAPinTarget() {
        let edit = message(id: "m1", role: .user, kind: .deviceEdit)

        #expect(!edit.isUserMessage)
        // Still content: it is a real row in the history, not chrome like a spinner.
        #expect(!edit.isMessageListAccessory)
    }

    private func message(id: String, role: ChatRole, kind: ChatMessageKind) -> ChatMessage {
        ChatMessage(
            id: id,
            role: role,
            kind: kind,
            content: "content",
            targetLayerId: nil,
            imagePlacement: .replace,
            baseRevisionId: nil,
            sequence: 1,
            revisionId: nil,
            jobId: nil,
            status: .complete,
            createdAt: Date(),
            attachments: []
        )
    }
}
