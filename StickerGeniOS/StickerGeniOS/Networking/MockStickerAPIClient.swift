import AnimatedView
import Foundation

actor MockStickerAPIClient: StickerAPIClientProtocol {
    private var stickers = [PreviewFixtures.sticker]
    private var detail = PreviewFixtures.detail
    private var messages = PreviewFixtures.messages
    private let failCreationAsUpload: Bool

    init(failCreationAsUpload: Bool = false) {
        self.failCreationAsUpload = failCreationAsUpload
    }

    func listStickers(cursor: String?) async throws -> Page<Sticker> { .init(data: stickers, nextCursor: nil) }

    func createSticker(_ request: CreateStickerRequest, idempotencyKey: String) async throws -> CreateStickerResponse {
        if failCreationAsUpload { throw StickerAPIError.uploadFailed }
        let value = Sticker(
            id: UUID().uuidString,
            title: request.title,
            kind: request.kind,
            status: .draft,
            activeRevisionId: nil,
            createdAt: Date(),
            updatedAt: Date(),
            previewAsset: nil,
            systemSticker: nil
        )
        stickers.insert(value, at: 0)
        return .init(
            stickerId: value.id,
            threadId: "thread-\(value.id)",
            initialMessageId: UUID().uuidString,
            job: .init(id: UUID().uuidString, state: .queued, workflowRunId: "mock-workflow", eventsUrl: "/api/v1/jobs/mock/events")
        )
    }

    func sticker(id: String) async throws -> StickerDetail {
        guard id == detail.sticker.id else {
            let sticker = stickers.first(where: { $0.id == id }) ?? PreviewFixtures.sticker
            return .init(
                id: sticker.id, title: sticker.title, kind: sticker.kind, status: sticker.status,
                activeRevisionId: sticker.activeRevisionId, createdAt: sticker.createdAt, updatedAt: sticker.updatedAt,
                previewAsset: sticker.previewAsset, systemSticker: sticker.systemSticker, revisions: []
            )
        }
        return detail
    }

    func deleteSticker(id: String, idempotencyKey: String) async throws -> DeleteStickerResponse {
        stickers.removeAll { $0.id == id }
        return .init(
            stickerId: id,
            status: .deleting,
            job: .init(id: UUID().uuidString, state: .queued, workflowRunId: "mock-delete", retryable: false)
        )
    }

    func chatMessages(stickerID: String, beforeSequence: Int?) async throws -> ChatMessagePage {
        let eligible = beforeSequence.map { sequence in messages.filter { $0.sequence < sequence } } ?? messages
        return .init(data: eligible, nextBeforeSequence: nil)
    }

    func sendChatMessage(stickerID: String, request: SendChatMessageRequest, idempotencyKey: String) async throws -> SendChatMessageResponse {
        let message = ChatMessage(
            id: UUID().uuidString,
            role: .user,
            kind: request.intent == .animate ? .animation : request.intent == .edit ? .imageEdit : .text,
            content: request.text,
            targetLayerId: request.targetLayerId,
            imagePlacement: request.imagePlacement,
            baseRevisionId: request.baseRevisionId,
            sequence: messages.count + 1,
            revisionId: nil,
            jobId: "33333333-3333-4333-8333-333333333333",
            status: .complete,
            createdAt: Date(),
            attachments: request.attachments.map { .init(assetId: $0.assetId, kind: $0.kind, targetLayerId: $0.targetLayerId) }
        )
        messages.append(message)
        return .init(
            message: .init(id: message.id, status: .complete),
            job: .init(id: message.jobId!, state: .queued, workflowRunId: "mock-workflow", eventsUrl: "/api/v1/jobs/mock/events")
        )
    }

    func retryChatMessage(stickerID: String, messageID: String, idempotencyKey: String) async throws -> RetryChatMessageResponse {
        .init(
            messageId: messageID,
            job: .init(id: UUID().uuidString, state: .queued, workflowRunId: "mock-retry", eventsUrl: "/api/v1/jobs/mock-retry/events")
        )
    }

    func confirmPlan(stickerID: String, planID: String, idempotencyKey: String) async throws -> ConfirmPlanResponse {
        if let index = messages.firstIndex(where: { $0.plan?.id == planID }) {
            messages[index].plan?.state = .confirmed
            messages[index].plan?.actionable = false
        }
        let messageID = UUID().uuidString
        messages.append(.init(
            id: messageID,
            role: .user,
            kind: .text,
            content: "Build this plan.",
            targetLayerId: nil,
            imagePlacement: .replace,
            baseRevisionId: nil,
            sequence: (messages.map(\.sequence).max() ?? 0) + 1,
            revisionId: nil,
            jobId: "44444444-4444-4444-8444-444444444444",
            status: .streaming,
            createdAt: Date(),
            attachments: []
        ))
        return .init(
            message: .init(id: messageID, status: .streaming),
            job: .init(id: "44444444-4444-4444-8444-444444444444", state: .queued, workflowRunId: "mock-compose", eventsUrl: "/api/v1/jobs/mock-compose/events")
        )
    }

    func cancelPlan(stickerID: String, planID: String, reason: String?, idempotencyKey: String) async throws -> CancelPlanResponse {
        if let index = messages.firstIndex(where: { $0.plan?.id == planID }) {
            messages[index].plan?.state = .cancelled
            messages[index].plan?.actionable = false
            messages[index].plan?.decisionReason = reason
        }
        return .init(planId: planID, state: .cancelled)
    }

    func cancelGeneration(jobID: String, idempotencyKey: String) async throws -> CancelGenerationResponse {
        .init(jobId: jobID, state: .cancelled)
    }

    func transitionRevision(stickerID: String, revisionID: String, action: RevisionAction, idempotencyKey: String) async throws -> RevisionTransitionResponse {
        if let index = detail.revisions.firstIndex(where: { $0.id == revisionID }) {
            switch action {
            case .accept, .revert:
                detail.revisions = detail.revisions.map {
                    var copy = $0
                    if copy.state == .accepted { copy.state = .superseded }
                    return copy
                }
                detail.revisions[index].state = .accepted
                detail.activeRevisionId = revisionID
            case .reject:
                detail.revisions[index].state = .rejected
            }
        }
        return .init(
            revisionId: revisionID,
            candidateState: action == .reject ? .rejected : .accepted,
            activeRevisionId: action == .reject ? detail.activeRevisionId : revisionID,
            revertedFromRevisionId: action == .revert ? revisionID : nil
        )
    }

    func registerExport(stickerID: String, request: PublishExportsRequest, idempotencyKey: String) async throws -> PublishExportsResponse {
        .init(job: .init(id: UUID().uuidString, state: .queued, workflowRunId: "mock-export", eventsUrl: "/api/v1/jobs/mock-export/events"))
    }

    func saveEditedDocument(stickerID: String, request: SaveEditedDocumentRequest, idempotencyKey: String) async throws -> SaveEditedDocumentResponse {
        .init(
            revisionId: UUID().uuidString,
            parentRevisionId: request.parentRevisionId,
            candidateState: .accepted,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            stickerStatus: .draft
        )
    }

    func upload(data: Data, stickerID: String?, kind: AssetKind, filename: String, mimeType: String, idempotencyKey: String) async throws -> String { UUID().uuidString }
    func assetDownload(assetID: String) async throws -> AssetDownload { throw StickerAPIError.http(404) }

    nonisolated func generationEvents(jobID: String, after lastEventID: Int64?) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let events: [(GenerationEventType, Double, String)] = [
                    (.queued, 0.05, "Queued securely"),
                    (.started, 0.2, "Generating one candidate"),
                    (.progress, 0.7, "Checking transparency"),
                    (.document, 0.9, "Streaming a valid preview"),
                    (.candidate, 1, "Candidate ready"),
                ]
                for (index, value) in events.enumerated() {
                    try? await Task.sleep(for: .milliseconds(180))
                    continuation.yield(.init(
                        id: Int64(index + 1),
                        jobId: jobID,
                        type: value.0,
                        createdAt: Date(),
                        data: .init(
                            message: value.2,
                            progress: value.1,
                            messageId: nil,
                            revisionId: value.0 == .candidate ? PreviewFixtures.candidate.id : nil,
                            document: value.0 == .document ? PreviewFixtures.animatedDocument : nil
                        )
                    ))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
