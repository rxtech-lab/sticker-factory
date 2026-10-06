import Foundation
import Testing

@testable import StickerGeniOS

/// Back-to-back tool calls fold under the first one; anything else in between breaks the run.
@Suite("Folded tool calls")
struct FoldedToolCallsTests {
    private func message(_ id: String, role: ChatRole = .system, kind: ChatMessageKind = .status) -> ChatMessage {
        ChatMessage(
            id: id, role: role, kind: kind, content: id, imagePlacement: .replace,
            sequence: 0, status: .complete, createdAt: Date(), attachments: []
        )
    }

    @Test("A run keeps its first call in the list and hands the rest to it")
    func consecutiveCallsFold() {
        let folded = FoldedToolCalls([
            message("user", role: .user, kind: .text),
            message("create_plan"), message("finalize_plan"), message("update_plan"),
            message("reply", role: .assistant, kind: .text)
        ])
        #expect(folded.messages.map(\.id) == ["user", "create_plan", "reply"])
        #expect(folded.runs["create_plan"]?.map(\.id) == ["create_plan", "finalize_plan", "update_plan"])
    }

    @Test("A lone call is not a run, and a message between calls splits them")
    func separatedCallsStayApart() {
        let folded = FoldedToolCalls([
            message("view_sticker"),
            message("reply", role: .assistant, kind: .text),
            message("edit_layers")
        ])
        #expect(folded.messages.map(\.id) == ["view_sticker", "reply", "edit_layers"])
        #expect(folded.runs.isEmpty)
    }
}
