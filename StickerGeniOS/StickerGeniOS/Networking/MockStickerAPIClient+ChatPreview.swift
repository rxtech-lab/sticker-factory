import Foundation

extension MockStickerAPIClient {
    /// Transcripts the UI tests launch into, so tool and SVG progress cards render without a server.
    static func uiTestChatPreview() -> ChatMessagePage? {
        if ProcessInfo.processInfo.arguments.contains("--ui-svg-progress") {
            return .init(data: [ChatMessage(id: "svg-validation", role: .system, kind: .status,
                content: "validate_svg Cat [hero] #2", imagePlacement: .replace, sequence: 1, status: .failed,
                createdAt: .now, attachments: [], toolDetails:
                #"{"engine":"svg","message":"Missing walk pose","attempt":2,"maxAttempts":3,"durationMs":44165,"# +
                #""correction":"Trying again with the same reference (attempt 3 of 3)."}"#)],
            nextBeforeSequence: nil)
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-tool-preview") {
            let arguments = ProcessInfo.processInfo.arguments
            let toolName: String
            if arguments.contains("--ui-compose-preview") {
                toolName = "compose-part:0 Heart"
            } else if arguments.contains("--ui-layout-preview") {
                toolName = "adjust_layout"
            } else {
                toolName = "view_sticker"
            }
            return .init(data: [ChatMessage(
                id: "tool-preview", role: .system, kind: .status, content: toolName,
                imagePlacement: .replace, sequence: 1, status: .complete, createdAt: Date(),
                attachments: [], toolDetails: "{\"previewAssetId\":\"\(PreviewFixtures.borrowedAssetID)\"}"
            )], nextBeforeSequence: nil)
        }
        return nil
    }
}
