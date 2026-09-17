import AnimatedView
import CoreGraphics
import Foundation
import UIKit

actor MockStickerAPIClient: StickerAPIClientProtocol {
    private var stickers = [PreviewFixtures.sticker]
    private var detail = PreviewFixtures.detail
    private var messages = PreviewFixtures.messages
    private var packs = [PreviewFixtures.pack]
    private var packDetails = [PreviewFixtures.packDetail.id: PreviewFixtures.packDetail]
    /// Readable so a test can assert the app enrolled this device for push.
    private(set) var registeredDeviceTokens: [String] = []
    /// Survives across calls so a UI test can request deletion, see the pending state, and cancel.
    private var accountDeletion: AccountDeletionState = .none
    /// Readable so a test can assert which renditions an export actually produced — a publish that
    /// was never going to share a video does not encode one.
    private(set) var uploadedKinds: [AssetKind] = []
    private(set) var publishedExportRequests: [PublishExportsRequest] = []
    /// Every messenger bind this mock was asked to make, in order, for tests to assert against.
    private(set) var messengerRenditionRequests: [(stickerID: String, request: MessengerRenditionsRequest)] = []
    /// Upload calls recorded with their idempotency key, so a test can prove the key is stable
    /// across two runs over identical bytes rather than a fresh UUID that defeats the replay.
    private(set) var uploadCalls: [(kind: AssetKind, byteCount: Int, idempotencyKey: String)] = []
    private let failCreationAsUpload: Bool
    private let failChatSendAsInsufficientCredits: Bool
    private let failLibraryListing: Bool

    init(
        failCreationAsUpload: Bool = false,
        failChatSendAsInsufficientCredits: Bool = false,
        failLibraryListing: Bool = false
    ) {
        self.failCreationAsUpload = failCreationAsUpload
        self.failChatSendAsInsufficientCredits = failChatSendAsInsufficientCredits
        self.failLibraryListing = failLibraryListing
        if ProcessInfo.processInfo.arguments.contains("--ui-tutorial-capture") {
            var samples: [Sticker] = []
            for index in 0..<3 {
                var sticker = PreviewFixtures.borrowedSticker
                sticker.id = "tutorial-\(index)"
                sticker.title = ["Winky wave", "Little sparkle", "Happy hello"][index]
                sticker.playbackRevisionId = nil
                sticker.whatsappAsset?.id = "tutorial-webp"
                sticker.telegramAsset?.id = PreviewFixtures.borrowedAssetID
                samples.append(sticker)
            }
            stickers += samples
            var pack = PreviewFixtures.packDetail
            pack.title = "Winky friends"; pack.summary = "Three little ways to say hello."
            pack.stickers = samples; pack.coverStickers = samples; pack.itemCount = samples.count
            packs = [pack.pack]; packDetails = [pack.id: pack]
            for index in detail.revisions.indices {
                detail.revisions[index].document = PreviewFixtures.configurableDocument
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-working-progress") {
            let source = PreviewFixtures.messages[0]
            messages = [source]
            for (index, tool) in [("working-plan", "view_plan_image"), ("working-sticker", "view_sticker")].enumerated() {
                messages.append(.init(id: tool.0, role: .system, kind: .status, content: tool.1,
                    imagePlacement: .replace, sequence: source.sequence + index + 1,
                    jobId: source.jobId, status: .complete, createdAt: .now, attachments: []))
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-configurable-sticker") {
            for i in detail.revisions.indices { detail.revisions[i].document = PreviewFixtures.configurableDocument }
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-plan-versions")
            || ProcessInfo.processInfo.arguments.contains("--ui-sprite-plan") {
            // Only the latest card is loaded; the older version comes from the history endpoint.
            var message = PreviewFixtures.messages[0]
            message.id = "message-plan-current"
            message.role = .assistant
            message.kind = .plan
            message.jobId = nil
            message.plan = PreviewFixtures.planVersions[1]
            if ProcessInfo.processInfo.arguments.contains("--ui-sprite-plan") {
                message.plan?.plan.layers[0].source = .sprite(
                    prompt: "A friendly character",
                    clips: [.init(id: "idle", label: "Idle", prompt: "Standing still", frames: [.init(duration: 1)])],
                    expressions: [.init(id: "happy", label: "Happy", prompt: "Smiling")]
                )
                message.plan?.plan.configuration = .init(controls: [
                    .init(id: "pose", label: "Pose", type: .choice, defaultValue: .string("idle"),
                          options: [.init(id: "idle", label: "Idle")])
                ], variants: [
                    .init(id: "idle", selections: ["pose": "idle"], layers: [.init(layerId: "hero", clip: "idle")])
                ])
            }
            messages = [message]
            detail.revisions = []
        }
    }

    func listStickers(cursor: String?) async throws -> Page<Sticker> {
        if failLibraryListing { throw Self.libraryListingError }
        return .init(data: stickers, nextCursor: nil)
    }

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

    private var createdPresets: [String: CreationPresetDisplay] = [:]
    private var createdRequests: [String: CreateStickerRequest] = [:]
    private var catalogAttempts = 0
    private var creationCatalogChanged = false
    private var createdChatMessages: [String: [ChatMessage]] = [:]

    /// The budget the UI tests edit against. Mirrors the server's own numbers rather than
    /// inventing looser ones, so a test that walks into a cap sees the cap the app ships with.
    func configurationLimits() async throws -> ConfigurationLimits {
        .init(controls: 16, controlOptions: 8, controlOptionsMinimum: 2,
              variants: 128, layerCombinations: 64, preparedStates: 256, planLayers: 12)
    }

    func creationPresets(refresh: Bool) async throws -> CreationPresetCatalog {
        catalogAttempts += 1
        if ProcessInfo.processInfo.arguments.contains("--ui-creation-catalog-failure"), catalogAttempts == 1 {
            throw StickerAPIError.http(503)
        }
        return try MockCreationPresetCatalog.load(changed: creationCatalogChanged)
    }

    func createSticker(_ request: CreateStickerRequest, idempotencyKey: String) async throws -> CreateStickerResponse {
        if failCreationAsUpload { throw StickerAPIError.uploadFailed(status: 403) }
        if ProcessInfo.processInfo.arguments.contains("--ui-creation-catalog-changed"), !creationCatalogChanged {
            creationCatalogChanged = true
            throw APIErrorEnvelope(error: .init(
                code: "CREATION_PRESETS_CHANGED", message: "Review updated options", requestId: "mock", details: nil
            ))
        }
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
        createdRequests[value.id] = request
        if let selected = request.presets {
            let catalog = try await creationPresets(refresh: false)
            createdPresets[value.id] = .init(catalogVersion: selected.catalogVersion, selections: catalog.groups.compactMap { group in
                let ids = selected.selections.first(where: { $0.groupId == group.id })?.optionIds ?? []
                let options = group.options.filter { ids.contains($0.id) }
                return options.isEmpty ? nil : .init(groupId: group.id, title: group.title, options: options)
            })
        }
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
                previewAsset: sticker.previewAsset, systemSticker: sticker.systemSticker, presets: createdPresets[id], revisions: []
            )
        }
        return detail
    }

    /// The borrowed fixture is the only controllable one. Its bundle carries no assets because the
    /// configurable document is shapes, text, and inline SVG — nothing this mock would have to
    /// serve bytes for — which is exactly what the preview's controls need to move.
    func stickerPlayback(stickerID: String, revisionID: String?) async throws -> StickerPlaybackBundle {
        guard stickerID == PreviewFixtures.borrowedSticker.id,
              let playbackRevisionID = PreviewFixtures.borrowedSticker.playbackRevisionId,
              revisionID == nil || revisionID == playbackRevisionID else {
            throw StickerAPIError.http(404)
        }
        return .init(
            stickerId: stickerID,
            revisionId: playbackRevisionID,
            version: 1,
            document: PreviewFixtures.configurableDocument,
            assets: []
        )
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

    func planVersions(stickerID: String) async throws -> Page<PlanRecord> {
        if ProcessInfo.processInfo.arguments.contains("--ui-plan-versions") {
            return .init(data: PreviewFixtures.planVersions, nextCursor: nil)
        }
        return .init(data: messages.compactMap(\.plan), nextCursor: nil)
    }

    func selectPlanVersion(stickerID: String, versionID: String, request: SelectPlanVersionRequest, idempotencyKey: String) async throws -> SelectPlanVersionResponse {
        guard let index = messages.lastIndex(where: { $0.plan != nil }),
              messages[index].plan?.id == request.currentPlanId,
              messages[index].plan?.revision == request.currentRevision,
              var selected = PreviewFixtures.planVersions.first(where: { $0.id == versionID }) else {
            throw StickerAPIError.http(409)
        }
        selected.sourceVersionId = selected.id
        selected.id = UUID().uuidString
        selected.messageId = messages[index].id
        selected.state = .finalized
        selected.actionable = true
        selected.jobId = nil
        messages[index].plan = selected
        return .init(messageId: messages[index].id, plan: selected)
    }

    func editPlan(stickerID: String, planID: String, request: PlanEditRequest, idempotencyKey: String) async throws -> EditPlanResponse {
        guard let index = messages.lastIndex(where: { $0.plan != nil }),
              var record = messages[index].plan,
              record.id == planID, record.revision == request.currentRevision, record.actionable else {
            throw StickerAPIError.http(409)
        }
        record.plan = Self.applying(request.edit, to: record.plan)
        record.id = UUID().uuidString
        record.supersedesId = planID
        record.sourceVersionId = nil
        record.revision = 1
        let variantArtwork = record.plan.configuration?.variants.flatMap(\.layers).filter {
            $0.source?.kind == .generate || $0.source?.kind == .frames
        }.count ?? 0
        // A sprite buys a sheet per pose plus one of expressions, on top of the still every drawn
        // layer costs — the same sum `planGenerationCount` computes on the server.
        let spriteSheets = record.plan.layers.reduce(0) { total, layer in
            guard let sprite = layer.source.sprite else { return total }
            return total + sprite.clips.count + 1
        }
        record.generationCount = record.plan.layers.filter(\.source.isGenerated).count + variantArtwork + spriteSheets
        messages[index].plan = record
        return .init(messageId: messages[index].id, plan: record)
    }

    /// The server's `applyPlanEdit`, in miniature: keep what the edit did not mention.
    private static func applying(_ edit: PlanEdit, to plan: Plan) -> Plan {
        var next = plan
        if edit.clearConfiguration == true {
            next.configuration = nil
        } else if let configuration = edit.configuration {
            next.configuration = configuration
        }
        if let title = edit.title { next.title = title }
        if let summary = edit.summary { next.summary = summary }
        if let timing = edit.timing {
            if let duration = timing.durationSeconds { next.timing.durationSeconds = duration }
            if let fps = timing.fps { next.timing.fps = fps }
            if let loop = timing.loop { next.timing.loop = loop }
        }
        guard let layers = edit.layers else { return next }
        next.layers = layers.map { entry in
            let base = entry.from.flatMap { id in plan.layers.first { $0.layerId == id } }
            let animations = entry.animations.map { edits in
                edits.compactMap { animation -> PlanAnimation? in
                    if let index = animation.from {
                        guard let existing = base?.animations, index < existing.count else { return nil }
                        var kept = existing[index]
                        if let delay = animation.delay { kept.delay = delay }
                        if let duration = animation.duration { kept.duration = duration }
                        return kept
                    }
                    return animation.spec.map { PlanAnimation(type: $0.type, delay: $0.delay, duration: $0.duration) }
                }
            }
            return PlanLayer(
                layerId: base?.layerId ?? entry.layerId ?? UUID().uuidString,
                name: entry.name ?? base?.name ?? "Layer",
                source: entry.source.map(Self.source) ?? base?.source ?? .generate(prompt: ""),
                x: entry.x ?? base?.x ?? 0.5,
                y: entry.y ?? base?.y ?? 0.5,
                scaleX: entry.scaleX ?? base?.scaleX ?? 0.4,
                scaleY: entry.scaleY ?? base?.scaleY ?? 0.4,
                rotationDegrees: entry.rotationDegrees ?? base?.rotationDegrees ?? 0,
                animations: animations ?? base?.animations ?? []
            )
        }
        return next
    }

    private static func source(_ edit: PlanLayerSourceEdit) -> PlanLayerSource {
        switch edit {
        case .generate(let prompt): .generate(prompt: prompt)
        case .video(let prompt, let motion, let durationSeconds):
            .video(prompt: prompt, motion: motion, durationSeconds: durationSeconds)
        }
    }

    func chatMessages(stickerID: String, beforeSequence: Int?) async throws -> ChatMessagePage {
        if let request = createdRequests[stickerID] {
            return .init(data: [.init(id: "initial-\(stickerID)", role: .user, kind: .text, content: request.prompt,
                imagePlacement: .replace, sequence: 1, status: .complete, createdAt: .now, attachments: [])]
                + (createdChatMessages[stickerID] ?? []), nextBeforeSequence: nil)
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
        let eligible = beforeSequence.map { sequence in messages.filter { $0.sequence < sequence } } ?? messages
        return .init(data: eligible, nextBeforeSequence: nil)
    }

    func sendChatMessage(stickerID: String, request: SendChatMessageRequest, idempotencyKey: String) async throws -> SendChatMessageResponse {
        if failChatSendAsInsufficientCredits {
            throw APIErrorEnvelope(error: .init(
                code: "INSUFFICIENT_CREDITS",
                message: "You do not have enough points for this. Top up or upgrade your plan to keep creating.",
                requestId: "ui-test-insufficient-credits",
                details: nil
            ))
        }
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
        if createdRequests[stickerID] != nil { createdChatMessages[stickerID, default: []].append(message) }
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
            job: .init(
                id: "44444444-4444-4444-8444-444444444444",
                state: .queued,
                workflowRunId: "mock-compose",
                eventsUrl: "/api/v1/jobs/mock-compose/events"
            )
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

    /// Scheduling and cancelling move the same in-memory state a real account would, so a UI test
    /// can walk the whole round trip — request, see the pending row, keep the account.
    func accountDeletionState() async throws -> AccountDeletionState {
        accountDeletion
    }

    func requestAccountDeletion() async throws -> AccountDeletionState {
        if !accountDeletion.pendingDeletion {
            let now = Date()
            accountDeletion = AccountDeletionState(
                pendingDeletion: true,
                deletionScheduledAt: now.addingTimeInterval(7 * 24 * 60 * 60),
                deletionRequestedAt: now
            )
        }
        return accountDeletion
    }

    func cancelAccountDeletion() async throws -> AccountDeletionState {
        accountDeletion = .none
        return accountDeletion
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
        return .init(job: .init(
            id: UUID().uuidString,
            state: .queued,
            workflowRunId: "mock-export",
            eventsUrl: "/api/v1/jobs/mock-export/events"
        ))
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
        if failLibraryListing { throw Self.libraryListingError }
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

    private static var libraryListingError: APIErrorEnvelope {
        APIErrorEnvelope(error: .init(
            code: "IOS_APP_UPDATE_REQUIRED",
            message: "Update Winky Sticker Factory to version 1.2 or later to view your stickers.",
            requestId: "ui-test-app-version",
            details: nil
        ))
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
        uploadCalls.append((kind, data.count, idempotencyKey))
        return UUID().uuidString
    }

    /// Records the bind and answers with the sticker as the server would leave it.
    ///
    /// The asset records are synthesised from the ids the caller sent, so a test can assert that a
    /// sticker which fitted only one messenger comes back supporting exactly that one — the state
    /// the pack screen grays for.
    func bindMessengerRenditions(stickerID: String, request: MessengerRenditionsRequest, idempotencyKey: String) async throws -> Sticker {
        messengerRenditionRequests.append((stickerID, request))
        var sticker = stickers.first { $0.id == stickerID } ?? PreviewFixtures.sticker
        if let assetID = request.whatsappAssetId {
            sticker.whatsappAsset = Self.mockRendition(assetID, stickerID: stickerID, kind: .messengerWhatsApp, mimeType: "image/webp")
        }
        if let assetID = request.telegramAssetId {
            let mimeType = sticker.kind == .animated ? "video/webm" : "image/png"
            sticker.telegramAsset = Self.mockRendition(assetID, stickerID: stickerID, kind: .messengerTelegram, mimeType: mimeType)
        }
        if let emoji = request.emoji { sticker.messengerEmoji = emoji }
        if let index = stickers.firstIndex(where: { $0.id == stickerID }) { stickers[index] = sticker }
        return sticker
    }

    private static func mockRendition(_ id: String, stickerID: String, kind: AssetKind, mimeType: String) -> AssetRecord {
        .init(
            id: id,
            stickerId: stickerID,
            kind: kind,
            state: .ready,
            mimeType: mimeType,
            byteSize: 64_000,
            width: 512,
            height: 512,
            frameCount: mimeType == "video/webm" ? nil : 1,
            durationSeconds: nil,
            fps: nil,
            sha256: nil,
            hasAlpha: true,
            createdAt: Date()
        )
    }
    /// Only the borrowed fixture has artwork: a transparent PNG drawn once into the temporary
    /// directory and served as a file URL, which `URLSession` reads like any other. Everything
    /// else is 404, as it always was.
    func assetDownload(assetID: String) async throws -> AssetDownload {
        if ProcessInfo.processInfo.arguments.contains("--ui-tutorial-capture") {
            if assetID == "tutorial-webp", let url = Bundle.main.url(forResource: "tutorial-demo", withExtension: "webp") {
                return .init(
                    url: url,
                    expiresAt: .now.addingTimeInterval(3600),
                    asset: .init(
                        id: assetID, kind: .messengerWhatsApp, state: .ready,
                        mimeType: "image/webp", width: 512, height: 512, hasAlpha: true
                    )
                )
            }
            if [PreviewFixtures.borrowedAssetID, PreviewFixtures.planHistoryAssetID, PreviewFixtures.imageAssetID].contains(assetID) {
                let url = FileManager.default.temporaryDirectory.appending(path: "tutorial-artwork.png")
                if let data = UIImage(named: "FeatureControllableAnimation")?.pngData() { try data.write(to: url, options: .atomic) }
                return .init(
                    url: url,
                    expiresAt: .now.addingTimeInterval(3600),
                    asset: .init(id: assetID, kind: .master, state: .ready, mimeType: "image/png", hasAlpha: true)
                )
            }
        }
        guard assetID == PreviewFixtures.borrowedAssetID || assetID == PreviewFixtures.planHistoryAssetID else {
            throw StickerAPIError.http(404)
        }
        let url = try Self.fixtureArtworkURL(isHistoricalPlan: assetID == PreviewFixtures.planHistoryAssetID)
        return .init(
            url: url,
            expiresAt: Date().addingTimeInterval(3_600),
            asset: .init(
                id: assetID,
                stickerId: PreviewFixtures.borrowedSticker.id,
                kind: .master,
                state: .ready,
                mimeType: "image/png",
                width: 256,
                height: 256,
                hasAlpha: true
            )
        )
    }

    private static func fixtureArtworkURL(isHistoricalPlan: Bool = false) throws -> URL {
        let filename = isHistoricalPlan ? "mock-historical-plan.png" : "mock-borrowed-sticker.png"
        let url = FileManager.default.temporaryDirectory.appending(path: filename)
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { return url }
        let side = 256
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw StickerAPIError.http(500) }
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(isHistoricalPlan
            ? CGColor(red: 1, green: 0.55, blue: 0.33, alpha: 1)
            : CGColor(red: 0.85, green: 1, blue: 0.33, alpha: 1))
        context.fillEllipse(in: CGRect(x: 24, y: 40, width: 208, height: 176))
        context.setFillColor(CGColor(red: 0.1, green: 0.09, blue: 0.09, alpha: 1))
        context.fillEllipse(in: CGRect(x: 84, y: 130, width: 20, height: 20))
        context.fillEllipse(in: CGRect(x: 152, y: 130, width: 20, height: 20))
        guard let image = context.makeImage(), let data = UIImage(cgImage: image).pngData() else { throw StickerAPIError.http(500) }
        try data.write(to: url, options: .atomic)
        return url
    }

    nonisolated func generationEvents(jobID: String, after lastEventID: Int64?) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                if ProcessInfo.processInfo.arguments.contains("--ui-working-progress") {
                    let updates: [GenerationEventData] = [
                        .init(message: "Finishing up", stage: "finalizing",
                              completedUnits: 2, totalUnits: 6, progressLabel: "Review checks"),
                        .init(toolCallId: "working-plan", toolName: "view_plan_image", toolStatus: .complete),
                        .init(toolCallId: "working-sticker", toolName: "view_sticker", toolStatus: .complete)
                    ]
                    for (index, data) in updates.enumerated() where Int64(index + 1) > (lastEventID ?? 0) {
                        continuation.yield(.init(id: Int64(index + 1), jobId: jobID, type: .progress, createdAt: .now, data: data))
                    }
                    do { try await Task.sleep(for: .seconds(60)) } catch {}
                    continuation.finish()
                    return
                }
                let events: [(GenerationEventType, Double, String)] = [
                    (.queued, 0.05, "Queued securely"),
                    (.started, 0.2, "Generating one candidate"),
                    (.progress, 0.7, "Checking transparency"),
                    (.document, 0.9, "Streaming a valid preview"),
                    (.candidate, 1, "Candidate ready")
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
