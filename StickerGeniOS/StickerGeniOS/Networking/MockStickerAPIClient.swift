import AnimatedView
import Foundation

actor MockStickerAPIClient: StickerAPIClientProtocol {
    private var stickers = [PreviewFixtures.sticker]
    private var detail = PreviewFixtures.detail
    private var messages = PreviewFixtures.messages
    private var packs = [PreviewFixtures.pack]
    private var packDetails = [PreviewFixtures.packDetail.id: PreviewFixtures.packDetail]
    /// Readable so a test can assert the app enrolled this device for push.
    private(set) var registeredDeviceTokens: [String] = []
    /// Readable so a test can assert which renditions an export actually produced — a publish that
    /// was never going to share a video does not encode one.
    private(set) var uploadedKinds: [AssetKind] = []
    private(set) var publishedExportRequests: [PublishExportsRequest] = []
    private let failCreationAsUpload: Bool

    init(failCreationAsUpload: Bool = false) {
        self.failCreationAsUpload = failCreationAsUpload
    }

    func listStickers(cursor: String?) async throws -> Page<Sticker> { .init(data: stickers, nextCursor: nil) }

    func searchStickers(query: String, cursor: String?) async throws -> Page<Sticker> {
        .init(
            data: stickers.filter { $0.title.localizedCaseInsensitiveContains(query) },
            nextCursor: nil
        )
    }

    func publishedStickers(query: String?, cursor: String?) async throws -> Page<Sticker> {
        let published = stickers.filter { $0.status == .published }
        guard let query, !query.isEmpty else { return .init(data: published, nextCursor: nil) }
        return .init(
            data: published.filter { $0.title.localizedCaseInsensitiveContains(query) },
            nextCursor: nil
        )
    }

    func createSticker(_ request: CreateStickerRequest, idempotencyKey: String) async throws -> CreateStickerResponse {
        if failCreationAsUpload { throw StickerAPIError.uploadFailed(status: 403) }
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

    func importSticker(_ request: ImportStickerRequest, idempotencyKey: String) async throws -> ImportStickerResponse {
        let value = Sticker(
            id: UUID().uuidString,
            title: request.title,
            kind: .static,
            status: .draft,
            activeRevisionId: UUID().uuidString,
            createdAt: Date(),
            updatedAt: Date(),
            previewAsset: nil,
            systemSticker: nil
        )
        stickers.insert(value, at: 0)
        return .init(
            stickerId: value.id,
            threadId: "thread-\(value.id)",
            revisionId: value.activeRevisionId ?? UUID().uuidString
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

    func updateSticker(id: String, request: UpdateStickerRequest, idempotencyKey: String) async throws -> StickerDetail {
        let updatedAt = Date()
        if let index = stickers.firstIndex(where: { $0.id == id }) {
            stickers[index].title = request.title
            stickers[index].updatedAt = updatedAt
        }
        if detail.id == id {
            detail.title = request.title
            detail.updatedAt = updatedAt
        }
        return try await sticker(id: id)
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
        // A reason is a request for a better plan, so the mock starts the redraft the server would.
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            return .init(planId: planID, state: .cancelled)
        }
        let messageID = UUID().uuidString
        let jobID = "55555555-5555-4555-8555-555555555555"
        messages.append(.init(
            id: messageID,
            role: .user,
            kind: .text,
            content: trimmed,
            targetLayerId: nil,
            imagePlacement: .replace,
            baseRevisionId: nil,
            sequence: (messages.map(\.sequence).max() ?? 0) + 1,
            revisionId: nil,
            jobId: jobID,
            status: .streaming,
            createdAt: Date(),
            attachments: []
        ))
        return .init(
            planId: planID,
            state: .cancelled,
            message: .init(id: messageID, status: .streaming),
            job: .init(id: jobID, state: .queued, workflowRunId: "mock-replan", eventsUrl: "/api/v1/jobs/mock-replan/events")
        )
    }

    func cancelGeneration(jobID: String, idempotencyKey: String) async throws -> CancelGenerationResponse {
        .init(jobId: jobID, state: .cancelled)
    }

    func registerDevice(token: String, environment: PushEnvironment, bundleID: String?, appVersion: String?) async throws {
        registeredDeviceTokens.append(token)
    }

    func unregisterDevice(token: String) async throws {
        registeredDeviceTokens.removeAll { $0 == token }
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
        publishedExportRequests.append(request)
        return .init(job: .init(id: UUID().uuidString, state: .queued, workflowRunId: "mock-export", eventsUrl: "/api/v1/jobs/mock-export/events"))
    }

    // MARK: - Marketplace

    func marketplacePacks(sort: PackSort, query: String?, cursor: String?) async throws -> Page<StickerPack> {
        let visible = Self.matching(query, in: packs).filter { !$0.isMine || $0.state == .published }
        return .init(
            data: sort == .popular ? visible.sorted { $0.installCount > $1.installCount } : visible,
            nextCursor: nil
        )
    }

    func myPacks(query: String?, cursor: String?) async throws -> Page<StickerPack> {
        .init(data: Self.matching(query, in: packs.filter(\.isMine)), nextCursor: nil)
    }

    /// The server matches a pack by title; the mock matches the same way so a search behaves the
    /// same in previews as it does against a real backend.
    private static func matching(_ query: String?, in packs: [StickerPack]) -> [StickerPack] {
        guard let query, !query.isEmpty else { return packs }
        return packs.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    func packsByCreator(handle: String, cursor: String?) async throws -> CreatorPacksResponse {
        .init(
            creator: PreviewFixtures.creator,
            data: packs.filter { $0.creator.handle == handle },
            nextCursor: nil
        )
    }

    func pack(id: String) async throws -> StickerPackDetail {
        if let stored = packDetails[id] { return stored }
        if let stored = packDetails.values.first(where: { $0.slug == id }) { return stored }
        throw StickerAPIError.invalidResponse
    }

    func createPack(_ request: CreatePackRequest, idempotencyKey: String) async throws -> StickerPackDetail {
        let id = UUID().uuidString
        let members = stickers.filter { request.stickerIds.contains($0.id) }
        let detail = StickerPackDetail(
            id: id,
            slug: "\(request.title.lowercased().replacingOccurrences(of: " ", with: "-"))-mock",
            title: request.title,
            summary: request.summary,
            state: request.state == "published" ? .published : .draft,
            creator: .init(handle: "you-000000", displayName: "You", bio: nil, packCount: 1, isSelf: true),
            itemCount: members.count,
            installCount: 0,
            installed: false,
            isMine: true,
            coverStickers: Array(members.prefix(4)),
            monetization: .init(kind: "free", priceCents: 0, currency: "USD"),
            publishedAt: request.state == "published" ? Date() : nil,
            createdAt: Date(),
            updatedAt: Date(),
            stickers: members
        )
        packDetails[id] = detail
        packs.insert(detail.pack, at: 0)
        return detail
    }

    func updatePack(id: String, request: UpdatePackRequest, idempotencyKey: String) async throws -> StickerPackDetail {
        var detail = try await pack(id: id)
        if let title = request.title { detail.title = title }
        detail.summary = request.summary
        detail.updatedAt = Date()
        return store(detail)
    }

    func setPackItems(id: String, stickerIDs: [String], idempotencyKey: String) async throws -> StickerPackDetail {
        var detail = try await pack(id: id)
        // Preserve the caller's order rather than the library's — that is the whole point of the call.
        detail.stickers = stickerIDs.compactMap { wanted in stickers.first { $0.id == wanted } }
        detail.itemCount = detail.stickers.count
        detail.coverStickers = Array(detail.stickers.prefix(4))
        return store(detail)
    }

    func publishPack(id: String, idempotencyKey: String) async throws -> StickerPackDetail {
        var detail = try await pack(id: id)
        detail.state = .published
        detail.publishedAt = detail.publishedAt ?? Date()
        return store(detail)
    }

    func unpublishPack(id: String, state: PackState, idempotencyKey: String) async throws -> StickerPackDetail {
        var detail = try await pack(id: id)
        detail.state = state == .unlisted ? .unlisted : .draft
        return store(detail)
    }

    func deletePack(id: String, idempotencyKey: String) async throws -> DeletePackResponse {
        packDetails[id] = nil
        packs.removeAll { $0.id == id }
        return .init(packId: id)
    }

    func installPack(id: String, idempotencyKey: String) async throws -> InstallPackResponse {
        try setInstalled(id: id, installed: true)
        return .init(packId: id, installed: true)
    }

    func uninstallPack(id: String, idempotencyKey: String) async throws -> InstallPackResponse {
        try setInstalled(id: id, installed: false)
        return .init(packId: id, installed: false)
    }

    func librarySections(status: LibrarySectionStatus) async throws -> LibrarySectionsResponse {
        let mine = LibrarySection(
            id: "mine",
            kind: .mine,
            title: "My Stickers",
            packId: nil,
            packSlug: nil,
            creator: nil,
            installedAt: nil,
            updatedAt: Date(),
            stickers: status == .all ? stickers : stickers.filter { $0.status == .published }
        )
        let installed = packs.filter(\.installed).map { pack in
            LibrarySection(
                id: "pack:\(pack.id)",
                kind: .pack,
                title: pack.title,
                packId: pack.id,
                packSlug: pack.slug,
                creator: pack.creator,
                installedAt: Date(),
                updatedAt: pack.updatedAt,
                stickers: packDetails[pack.id]?.stickers ?? pack.coverStickers
            )
        }
        return .init(sections: [mine] + installed, generatedAt: Date())
    }

    func searchLibrarySections(query: String, status: LibrarySectionStatus) async throws -> LibrarySectionsResponse {
        let response = try await librarySections(status: status)
        let sections = response.sections.compactMap { section -> LibrarySection? in
            var copy = section
            copy.stickers = section.stickers.filter { $0.title.localizedCaseInsensitiveContains(query) }
            return copy.kind == .mine || !copy.stickers.isEmpty ? copy : nil
        }
        return .init(sections: sections, generatedAt: response.generatedAt)
    }

    @discardableResult
    private func store(_ detail: StickerPackDetail) -> StickerPackDetail {
        packDetails[detail.id] = detail
        if let index = packs.firstIndex(where: { $0.id == detail.id }) {
            packs[index] = detail.pack
        }
        return detail
    }

    private func setInstalled(id: String, installed: Bool) throws {
        guard var detail = packDetails[id] else { throw StickerAPIError.invalidResponse }
        detail.installed = installed
        detail.installCount = max(0, detail.installCount + (installed ? 1 : -1))
        store(detail)
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

    func upload(data: Data, stickerID: String?, kind: AssetKind, filename: String, mimeType: String, sequence: SequenceMetadata?, idempotencyKey: String) async throws -> String {
        uploadedKinds.append(kind)
        return UUID().uuidString
    }
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
