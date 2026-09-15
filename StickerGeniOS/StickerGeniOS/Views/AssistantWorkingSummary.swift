import Foundation

/// Detail for the dots card, scoped to this turn and separate from the title's status.
nonisolated struct AssistantWorkingSummary {
    var note: String?
    var completedSteps: Int

    init(job: StickerJobState?, messages: [ChatMessage], titleStatus: String?) {
        let tools = messages.filter {
            job != nil && $0.jobId == job?.jobID && $0.role == .system && $0.kind == .status
                && !StickerToolLabel.isPhase($0.content)
        }
        completedSteps = Set(tools.filter { $0.status == .complete }.map(\.id)).count
        func distinct(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  Self.normalized(text) != Self.normalized(titleStatus ?? "") else { return nil }
            return text
        }
        if let detail = distinct(job?.note) {
            note = detail
        } else if let tool = tools.last(where: { $0.status == .streaming }),
                  let detail = distinct(StickerToolLabel.text(for: tool.content)) {
            note = detail
        } else if let tool = tools.last(where: { $0.status == .complete }),
                  let detail = distinct(StickerToolLabel.text(for: tool.content)) {
            note = String(localized: "Last finished: \(detail)")
        } else if tools.isEmpty && job?.statusDetail == nil {
            note = distinct(String(localized: "Waiting for the first update…"))
        } else {
            note = nil
        }
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }
}
