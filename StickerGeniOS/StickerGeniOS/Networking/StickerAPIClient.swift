import AnimatedView
import CryptoKit
import Foundation
import os

nonisolated protocol StickerAPIClientProtocol: Sendable {
    func listStickers(cursor: String?) async throws -> Page<Sticker>
    func searchStickers(query: String, cursor: String?) async throws -> Page<Sticker>
    /// The owner's published stickers, paged, and optionally narrowed by a title query.
    ///
    /// Filtered server-side rather than by sieving `listStickers`: a page of thirty may contain no
    /// published sticker at all, and a client-side filter turns that into an empty picker.
    func publishedStickers(query: String?, cursor: String?) async throws -> Page<Sticker>
    func createSticker(_ request: CreateStickerRequest, idempotencyKey: String) async throws -> CreateStickerResponse
    func importSticker(_ request: ImportStickerRequest, idempotencyKey: String) async throws -> ImportStickerResponse
    func sticker(id: String) async throws -> StickerDetail
    /// The document and artwork a controllable sticker is posed from.
    ///
    /// Readable for a sticker this account owns and for a member of a pack it has installed — the
    /// same audience the Messages extension fetches under. A pack that has only been *browsed* is
    /// not one of them, so a marketplace screen must not ask on behalf of a pack the reader has
    /// not added.
    func stickerPlayback(stickerID: String, revisionID: String?) async throws -> StickerPlaybackBundle
    func updateSticker(id: String, request: UpdateStickerRequest, idempotencyKey: String) async throws -> StickerDetail
    func deleteSticker(id: String, idempotencyKey: String) async throws -> DeleteStickerResponse
    func chatMessages(stickerID: String, beforeSequence: Int?) async throws -> ChatMessagePage
    func planVersions(stickerID: String) async throws -> Page<PlanRecord>
    func selectPlanVersion(stickerID: String, versionID: String, request: SelectPlanVersionRequest, idempotencyKey: String) async throws -> SelectPlanVersionResponse
    func editPlan(stickerID: String, planID: String, request: PlanEditRequest, idempotencyKey: String) async throws -> EditPlanResponse
    func sendChatMessage(stickerID: String, request: SendChatMessageRequest, idempotencyKey: String) async throws -> SendChatMessageResponse
    func retryChatMessage(stickerID: String, messageID: String, idempotencyKey: String) async throws -> RetryChatMessageResponse
    func confirmPlan(stickerID: String, planID: String, idempotencyKey: String) async throws -> ConfirmPlanResponse
    func cancelPlan(stickerID: String, planID: String, reason: String?, idempotencyKey: String) async throws -> CancelPlanResponse
    func cancelGeneration(jobID: String, idempotencyKey: String) async throws -> CancelGenerationResponse
    func transitionRevision(stickerID: String, revisionID: String, action: RevisionAction, idempotencyKey: String) async throws -> RevisionTransitionResponse
    func registerExport(stickerID: String, request: PublishExportsRequest, idempotencyKey: String) async throws -> PublishExportsResponse
    func bindMessengerRenditions(stickerID: String, request: MessengerRenditionsRequest, idempotencyKey: String) async throws -> Sticker
    func saveEditedDocument(stickerID: String, request: SaveEditedDocumentRequest, idempotencyKey: String) async throws -> SaveEditedDocumentResponse
    func upload(data: Data, stickerID: String?, kind: AssetKind, filename: String, mimeType: String, sequence: SequenceMetadata?, idempotencyKey: String) async throws -> String
    func assetDownload(assetID: String) async throws -> AssetDownload
    func generationEvents(jobID: String, after lastEventID: Int64?) -> AsyncThrowingStream<GenerationEvent, Error>

    // Push
    func registerDevice(token: String, environment: PushEnvironment, bundleID: String?, appVersion: String?) async throws
    func unregisterDevice(token: String) async throws

    // Account
    /// Whether this account is counting down to deletion.
    func accountDeletionState() async throws -> AccountDeletionState
    /// Starts the grace period, here and at the identity provider. Idempotent: re-requesting keeps
    /// the original deadline rather than pushing it a week further out.
    func requestAccountDeletion() async throws -> AccountDeletionState
    /// Stops a pending deletion. Available for the whole grace period.
    func cancelAccountDeletion() async throws -> AccountDeletionState

    // Marketplace
    func marketplacePacks(sort: PackSort, query: String?, cursor: String?) async throws -> Page<StickerPack>
    func myPacks(query: String?, cursor: String?) async throws -> Page<StickerPack>
    func packsByCreator(handle: String, cursor: String?) async throws -> CreatorPacksResponse
    func pack(id: String) async throws -> StickerPackDetail
    func createPack(_ request: CreatePackRequest, idempotencyKey: String) async throws -> StickerPackDetail
    func updatePack(id: String, request: UpdatePackRequest, idempotencyKey: String) async throws -> StickerPackDetail
    func setPackItems(id: String, stickerIDs: [String], idempotencyKey: String) async throws -> StickerPackDetail
    func publishPack(id: String, idempotencyKey: String) async throws -> StickerPackDetail
    func unpublishPack(id: String, state: PackState, idempotencyKey: String) async throws -> StickerPackDetail
    func deletePack(id: String, idempotencyKey: String) async throws -> DeletePackResponse
    func installPack(id: String, idempotencyKey: String) async throws -> InstallPackResponse
    func uninstallPack(id: String, idempotencyKey: String) async throws -> InstallPackResponse
    func librarySections(status: LibrarySectionStatus) async throws -> LibrarySectionsResponse
    func searchLibrarySections(query: String, status: LibrarySectionStatus) async throws -> LibrarySectionsResponse
}

nonisolated enum PackSort: String, Sendable, CaseIterable { case recent, popular }

/// `published` is what the Messages extension needs; the app's Library also wants drafts, which
/// are projects in progress rather than junk.
nonisolated enum LibrarySectionStatus: String, Sendable { case published, all }

nonisolated enum RevisionAction: String, Sendable { case accept, reject, revert }

actor StickerAPIClient: StickerAPIClientProtocol {
    nonisolated static let log = Logger(subsystem: "app.rxlab.sticker-factory", category: "events")
    /// Every way a request can fail, said out loud.
    ///
    /// These are error paths only, and they log the server's message and the offending response
    /// body verbatim — which is the entire point, since the alternative is a banner that says an
    /// operation could not be completed and nothing anywhere that says why.
    nonisolated static let networkLog = Logger(subsystem: "app.rxlab.sticker-factory", category: "api")

    private let baseURL: URL
    private let tokenBroker: SharedTokenBroker
    private let session: URLSession
    private let appVersion: String?
    private let acceptLanguage: String?
    private let appTransactionProvider: @Sendable () async -> String?
    /// Asks StoreKit again after the server has said the proof was missing. Separate from the
    /// provider so the ordinary path stays a cache read and only a refusal pays for a new one.
    private let appTransactionRefresher: @Sendable () async -> String?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// Called when the server declines a request for want of credits or a plan.
    ///
    /// Hooked here rather than at each of the half-dozen call sites because a refusal can come back
    /// from a generation, an export, or a pack publish, and every one of them would otherwise have
    /// to recognise it separately — and the one that got forgotten would leave the user staring at
    /// "you do not have enough credits" with no way to buy any. The error still propagates as
    /// normal, so callers keep showing the server's own words; this only raises the paywall behind
    /// them.
    private var onSubscriptionRefusal: (@Sendable (SubscriptionRefusal) -> Void)?

    init(
        baseURL: URL,
        tokenBroker: SharedTokenBroker,
        session: URLSession = .shared,
        appVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        acceptLanguage: String? = Locale.preferredLanguages.first,
        // Resolved through the shared cache rather than by reading `AppTransaction.shared` here.
        // This ran on the calling task, so anything that cancelled a caller — stopping a turn
        // cancels its event stream — resolved to `nil`, and the next billing write went out with no
        // proof and came back 403. See `QuickAppTransaction`.
        appTransactionProvider: @escaping @Sendable () async -> String? = QuickAppTransaction.proof,
        appTransactionRefresher: @escaping @Sendable () async -> String? = QuickAppTransaction.refreshedProof
    ) {
        self.baseURL = baseURL
        self.tokenBroker = tokenBroker
        self.session = session
        self.appVersion = appVersion
        self.acceptLanguage = acceptLanguage
        self.appTransactionProvider = appTransactionProvider
        self.appTransactionRefresher = appTransactionRefresher
        encoder = JSONEncoder.api
        decoder = JSONDecoder.api
    }

    func onSubscriptionRefusal(_ handler: @escaping @Sendable (SubscriptionRefusal) -> Void) {
        onSubscriptionRefusal = handler
    }

    func listStickers(cursor: String?) async throws -> Page<Sticker> {
        try await send(path: "api/v1/stickers", query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
    }

    func searchStickers(query: String, cursor: String?) async throws -> Page<Sticker> {
        var items = [URLQueryItem(name: "q", value: query)]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await send(path: "api/v1/stickers", query: items)
    }

    func publishedStickers(query: String?, cursor: String?) async throws -> Page<Sticker> {
        var items = [URLQueryItem(name: "status", value: "published")]
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await send(path: "api/v1/stickers", query: items)
    }

    func createSticker(_ request: CreateStickerRequest, idempotencyKey: String) async throws -> CreateStickerResponse {
        try await send(path: "api/v1/stickers", method: "POST", body: request, idempotencyKey: idempotencyKey)
    }

    func importSticker(_ request: ImportStickerRequest, idempotencyKey: String) async throws -> ImportStickerResponse {
        try await send(path: "api/v1/stickers/import", method: "POST", body: request, idempotencyKey: idempotencyKey)
    }

    func sticker(id: String) async throws -> StickerDetail {
        try await send(path: "api/v1/stickers/\(id)")
    }

    func stickerPlayback(stickerID: String, revisionID: String?) async throws -> StickerPlaybackBundle {
        try await send(
            path: "api/v1/stickers/\(stickerID)/playback",
            query: revisionID.map { [URLQueryItem(name: "revisionId", value: $0)] } ?? []
        )
    }

    func updateSticker(id: String, request: UpdateStickerRequest, idempotencyKey: String) async throws -> StickerDetail {
        try await send(
            path: "api/v1/stickers/\(id)",
            method: "PATCH",
            body: request,
            idempotencyKey: idempotencyKey
        )
    }

    func deleteSticker(id: String, idempotencyKey: String) async throws -> DeleteStickerResponse {
        try await send(path: "api/v1/stickers/\(id)", method: "DELETE", idempotencyKey: idempotencyKey)
    }

    func chatMessages(stickerID: String, beforeSequence: Int?) async throws -> ChatMessagePage {
        try await send(
            path: "api/v1/stickers/\(stickerID)/chat/messages",
            query: beforeSequence.map { [URLQueryItem(name: "beforeSequence", value: String($0))] } ?? []
        )
    }

    func planVersions(stickerID: String) async throws -> Page<PlanRecord> {
        try await send(path: "api/v1/stickers/\(stickerID)/plans")
    }

    func selectPlanVersion(stickerID: String, versionID: String, request: SelectPlanVersionRequest, idempotencyKey: String) async throws -> SelectPlanVersionResponse {
        try await send(
            path: "api/v1/stickers/\(stickerID)/plans/\(versionID)/select",
            method: "POST", body: request, idempotencyKey: idempotencyKey
        )
    }

    func editPlan(stickerID: String, planID: String, request: PlanEditRequest, idempotencyKey: String) async throws -> EditPlanResponse {
        try await send(
            path: "api/v1/stickers/\(stickerID)/plans/\(planID)/edit",
            method: "POST", body: request, idempotencyKey: idempotencyKey
        )
    }

    func sendChatMessage(stickerID: String, request: SendChatMessageRequest, idempotencyKey: String) async throws -> SendChatMessageResponse {
        try await send(
            path: "api/v1/stickers/\(stickerID)/chat/messages",
            method: "POST",
            body: request,
            idempotencyKey: idempotencyKey
        )
    }

    func retryChatMessage(stickerID: String, messageID: String, idempotencyKey: String) async throws -> RetryChatMessageResponse {
        try await send(
            path: "api/v1/stickers/\(stickerID)/chat/messages/\(messageID)/retry",
            method: "POST",
            idempotencyKey: idempotencyKey
        )
    }

    func confirmPlan(stickerID: String, planID: String, idempotencyKey: String) async throws -> ConfirmPlanResponse {
        try await send(
            path: "api/v1/stickers/\(stickerID)/plans/\(planID)/confirm",
            method: "POST",
            idempotencyKey: idempotencyKey
        )
    }

    func cancelPlan(stickerID: String, planID: String, reason: String?, idempotencyKey: String) async throws -> CancelPlanResponse {
        // The body is omitted entirely when there is no reason: the server only parses one when
        // content-length is non-zero, and an empty `reason` is not a valid request.
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            return try await send(
                path: "api/v1/stickers/\(stickerID)/plans/\(planID)/cancel",
                method: "POST",
                idempotencyKey: idempotencyKey
            )
        }
        return try await send(
            path: "api/v1/stickers/\(stickerID)/plans/\(planID)/cancel",
            method: "POST",
            body: CancelPlanRequest(reason: trimmed),
            idempotencyKey: idempotencyKey
        )
    }

    func cancelGeneration(jobID: String, idempotencyKey: String) async throws -> CancelGenerationResponse {
        try await send(
            path: "api/v1/jobs/\(jobID)/cancel",
            method: "POST",
            idempotencyKey: idempotencyKey
        )
    }

    /// Tells the server where to push this install's "sticker ready" banners.
    ///
    /// No idempotency key: the token is a better one than anything the client could invent, and the
    /// server upserts on it.
    func registerDevice(token: String, environment: PushEnvironment, bundleID: String?, appVersion: String?) async throws {
        let _: EmptyResponse = try await send(
            path: "api/v1/devices",
            method: "POST",
            body: RegisterDeviceRequest(
                token: token,
                platform: "ios",
                environment: environment.rawValue,
                bundleId: bundleID,
                appVersion: appVersion
            )
        )
    }

    func registerLiveActivity(activityID: String, jobID: String, token: String) async throws -> LiveActivitySnapshot {
        try await send(path: "api/v1/live-activities", method: "POST", body: [
            "activityId": activityID, "jobId": jobID, "token": token,
            "environment": PushEnvironment.current.rawValue
        ])
    }

    func liveActivitySnapshot(jobID: String) async throws -> LiveActivitySnapshot {
        try await send(path: "api/v1/live-activities", query: [URLQueryItem(name: "jobId", value: jobID)])
    }

    func unregisterLiveActivity(activityID: String) async throws {
        let _: EmptyResponse = try await send(path: "api/v1/live-activities", method: "DELETE", body: ["activityId": activityID])
    }

    func unregisterDevice(token: String) async throws {
        let _: EmptyResponse = try await send(path: "api/v1/devices/\(token)", method: "DELETE")
    }

    func accountDeletionState() async throws -> AccountDeletionState {
        try await send(path: "api/v1/account/deletion")
    }

    func requestAccountDeletion() async throws -> AccountDeletionState {
        try await send(path: "api/v1/account/deletion", method: "POST")
    }

    func cancelAccountDeletion() async throws -> AccountDeletionState {
        try await send(path: "api/v1/account/deletion", method: "DELETE")
    }

    func transitionRevision(stickerID: String, revisionID: String, action: RevisionAction, idempotencyKey: String) async throws -> RevisionTransitionResponse {
        try await send(
            path: "api/v1/stickers/\(stickerID)/revisions/\(revisionID)/\(action.rawValue)",
            method: "POST",
            idempotencyKey: idempotencyKey
        )
    }

    func registerExport(stickerID: String, request: PublishExportsRequest, idempotencyKey: String) async throws -> PublishExportsResponse {
        try await send(
            path: "api/v1/stickers/\(stickerID)/exports",
            method: "POST",
            body: request,
            idempotencyKey: idempotencyKey
        )
    }

    /// Attaches the WhatsApp and Telegram renditions to an already-published sticker.
    ///
    /// Answers with the whole sticker rather than an acknowledgement, because the caller has just
    /// made it sendable and would otherwise have to re-list the pack to find that out. Unlike
    /// `registerExport` there is no job to watch: nothing is rendered on the server, so the write
    /// is finished when the call returns.
    func bindMessengerRenditions(stickerID: String, request: MessengerRenditionsRequest, idempotencyKey: String) async throws -> Sticker {
        try await send(
            path: "api/v1/stickers/\(stickerID)/messenger-renditions",
            method: "POST",
            body: request,
            idempotencyKey: idempotencyKey
        )
    }

    /// Saves an edited document as a new revision.
    ///
    /// The caller mints a fresh idempotency key per attempt, not per editing session: the server
    /// hashes the whole body against the key, so re-sending a *changed* document under a reused key
    /// is a conflict rather than a save.
    func saveEditedDocument(stickerID: String, request: SaveEditedDocumentRequest, idempotencyKey: String) async throws -> SaveEditedDocumentResponse {
        try await send(
            path: "api/v1/stickers/\(stickerID)/revisions",
            method: "POST",
            body: request,
            idempotencyKey: idempotencyKey
        )
    }

    // MARK: - Marketplace

    func marketplacePacks(sort: PackSort, query: String?, cursor: String?) async throws -> Page<StickerPack> {
        var items = [URLQueryItem(name: "sort", value: sort.rawValue)]
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await send(path: "api/v1/packs", query: items)
    }

    /// The authoring list. Unlike browse it includes drafts, so it must never back a public view.
    func myPacks(query: String?, cursor: String?) async throws -> Page<StickerPack> {
        var items = [URLQueryItem(name: "mine", value: "true")]
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await send(path: "api/v1/packs", query: items)
    }

    func packsByCreator(handle: String, cursor: String?) async throws -> CreatorPacksResponse {
        try await send(
            path: "api/v1/creators/\(handle)",
            query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []
        )
    }

    /// `id` accepts the uuid or the public slug, so a shared link resolves directly.
    func pack(id: String) async throws -> StickerPackDetail {
        try await send(path: "api/v1/packs/\(id)")
    }

    func createPack(_ request: CreatePackRequest, idempotencyKey: String) async throws -> StickerPackDetail {
        try await send(path: "api/v1/packs", method: "POST", body: request, idempotencyKey: idempotencyKey)
    }

    func updatePack(id: String, request: UpdatePackRequest, idempotencyKey: String) async throws -> StickerPackDetail {
        try await send(path: "api/v1/packs/\(id)", method: "PATCH", body: request, idempotencyKey: idempotencyKey)
    }

    /// Replaces the whole membership in order — this is both "set items" and "reorder".
    func setPackItems(id: String, stickerIDs: [String], idempotencyKey: String) async throws -> StickerPackDetail {
        try await send(
            path: "api/v1/packs/\(id)/items",
            method: "PUT",
            body: ReorderPackItemsRequest(stickerIds: stickerIDs),
            idempotencyKey: idempotencyKey
        )
    }

    func publishPack(id: String, idempotencyKey: String) async throws -> StickerPackDetail {
        try await send(path: "api/v1/packs/\(id)/publish", method: "POST", idempotencyKey: idempotencyKey)
    }

    func unpublishPack(id: String, state: PackState, idempotencyKey: String) async throws -> StickerPackDetail {
        try await send(
            path: "api/v1/packs/\(id)/unpublish",
            method: "POST",
            body: UnpublishPackRequest(state: state == .unlisted ? "unlisted" : "draft"),
            idempotencyKey: idempotencyKey
        )
    }

    func deletePack(id: String, idempotencyKey: String) async throws -> DeletePackResponse {
        try await send(path: "api/v1/packs/\(id)", method: "DELETE", idempotencyKey: idempotencyKey)
    }

    func installPack(id: String, idempotencyKey: String) async throws -> InstallPackResponse {
        try await send(path: "api/v1/packs/\(id)/install", method: "POST", idempotencyKey: idempotencyKey)
    }

    func uninstallPack(id: String, idempotencyKey: String) async throws -> InstallPackResponse {
        try await send(path: "api/v1/packs/\(id)/install", method: "DELETE", idempotencyKey: idempotencyKey)
    }

    func librarySections(status: LibrarySectionStatus) async throws -> LibrarySectionsResponse {
        try await send(path: "api/v1/library/sections", query: [URLQueryItem(name: "status", value: status.rawValue)])
    }

    func searchLibrarySections(query: String, status: LibrarySectionStatus) async throws -> LibrarySectionsResponse {
        try await send(path: "api/v1/library/sections", query: [
            URLQueryItem(name: "status", value: status.rawValue),
            URLQueryItem(name: "q", value: query)
        ])
    }

    // MARK: - Uploads

    func upload(data: Data, stickerID: String?, kind: AssetKind, filename: String, mimeType: String, sequence: SequenceMetadata?, idempotencyKey: String) async throws -> String {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let intent: UploadIntentResponse = try await send(
            path: "api/v1/uploads",
            method: "POST",
            body: UploadIntentRequest(
                stickerId: stickerID,
                kind: kind,
                mimeType: mimeType,
                byteSize: data.count,
                filename: filename,
                sha256: digest,
                sequence: sequence
            ),
            idempotencyKey: idempotencyKey
        )

        var upload = URLRequest(url: intent.upload.url)
        upload.httpMethod = "PUT"
        // These files can be close to the upload limit. Use URLSession's upload path instead of
        // attaching the whole rendition as an ordinary request body, and give storage enough time
        // to acknowledge it on a slow connection.
        upload.timeoutInterval = 180
        upload.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        for (name, value) in intent.upload.headers { upload.setValue(value, forHTTPHeaderField: name) }
        do {
            let (uploadBody, uploadResponse) = try await session.upload(for: upload, from: data)
            guard let http = uploadResponse as? HTTPURLResponse else { throw StickerAPIError.invalidResponse }
            guard (200...299).contains(http.statusCode) else {
                // Storage rejects for reasons the app can do something about — an expired presign,
                // a content type that disagrees with what was declared, or a body larger than the
                // policy allows. Record the response so none of those becomes a generic banner.
                let body = String(data: uploadBody.prefix(1_024), encoding: .utf8) ?? "<\(uploadBody.count) bytes>"
                Self.networkLog.error(
                    """
                    PUT storage → \(http.statusCode, privacy: .public) asset=\(intent.asset.id, privacy: .public) \
                    kind=\(kind.rawValue, privacy: .public) mime=\(mimeType, privacy: .public) \
                    bytes=\(data.count, privacy: .public), body: \(body, privacy: .public)
                    """
                )
                throw StickerAPIError.uploadFailed(status: http.statusCode)
            }
        } catch let error as StickerAPIError {
            throw error
        } catch {
            // A storage PUT can finish even when its response is lost. The completion endpoint
            // verifies the stored size, checksum, and media before accepting it, so it is safe to
            // use that verification to recover an ambiguous transport result.
            Self.networkLog.error(
                """
                PUT storage response lost asset=\(intent.asset.id, privacy: .public) \
                kind=\(kind.rawValue, privacy: .public) bytes=\(data.count, privacy: .public): \
                \(error.localizedDescription, privacy: .public); verifying object
                """
            )
            try await completeUpload(assetID: intent.asset.id, digest: digest, idempotencyKey: idempotencyKey)
            return intent.asset.id
        }

        try await completeUpload(assetID: intent.asset.id, digest: digest, idempotencyKey: idempotencyKey)
        return intent.asset.id
    }

    private func completeUpload(assetID: String, digest: String, idempotencyKey: String) async throws {
        let _: AssetRecord = try await send(
            path: "api/v1/uploads/\(assetID)/complete",
            method: "POST",
            body: CompleteUploadRequest(sha256: digest),
            idempotencyKey: idempotencyKey
        )
    }

    func assetDownload(assetID: String) async throws -> AssetDownload {
        try await send(path: "api/v1/assets/\(assetID)/download")
    }

    nonisolated func generationEvents(jobID: String, after lastEventID: Int64?) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var cursor = lastEventID
                var failures = 0
                while !Task.isCancelled {
                    do {
                        let outcome = try await self.consumeEventStream(jobID: jobID, after: cursor) { event in
                            cursor = max(cursor ?? 0, event.id)
                            continuation.yield(event)
                        } advanceCursor: { eventID in
                            cursor = max(cursor ?? 0, eventID)
                        }
                        switch outcome {
                        case .terminal:
                            continuation.finish()
                            return
                        case .windowExpired:
                            // A healthy 25s SSE window closed; reconnect immediately from the cursor.
                            failures = 0
                        case .unauthorized:
                            // The token was force-refreshed. Back off like any other failure so a
                            // persistently rejecting endpoint cannot spin without limit.
                            failures += 1
                            if failures >= 5 {
                                continuation.finish(throwing: StickerAPIError.http(401))
                                return
                            }
                            try? await Task.sleep(for: .milliseconds(min(4_000, failures * 500)))
                        }
                    } catch is CancellationError {
                        continuation.finish()
                        return
                    } catch {
                        failures += 1
                        Self.log.error("""
                            event stream job=\(jobID, privacy: .public) attempt=\(failures) \
                            error=\(String(describing: error), privacy: .public)
                            """)
                        if failures >= 5 {
                            continuation.finish(throwing: error)
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(min(4_000, failures * 500)))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Why a single SSE connection ended. The caller reconnects for anything but `.terminal`.
    private enum EventStreamOutcome {
        case terminal
        case windowExpired
        case unauthorized
    }

    /// Consumes one SSE connection.
    ///
    /// A malformed frame must never end the turn: the job's terminal `candidate`/`completed`
    /// event is what triggers the client's refetch, so throwing out of this loop on a single
    /// undecodable payload would strand the chat with no assistant message. Bad frames are
    /// logged, their id is still consumed so the reconnect does not replay them, and the loop
    /// continues.
    private func consumeEventStream(
        jobID: String,
        after lastEventID: Int64?,
        receive: (GenerationEvent) -> Void,
        advanceCursor: (Int64) -> Void
    ) async throws -> EventStreamOutcome {
        var request = try await authorizedRequest(path: "api/v1/jobs/\(jobID)/events")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Defeat any intermediary that would buffer a compressed body instead of flushing frames.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 60
        if let lastEventID { request.setValue(String(lastEventID), forHTTPHeaderField: "Last-Event-ID") }

        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw StickerAPIError.invalidResponse }
        Self.log.debug("event stream open job=\(jobID, privacy: .public) status=\(response.statusCode) after=\(lastEventID ?? 0)")
        if response.statusCode == 401 {
            _ = try await tokenBroker.validAccessToken(forceRefresh: true)
            return .unauthorized
        }
        guard (200...299).contains(response.statusCode) else { throw StickerAPIError.http(response.statusCode) }
        let terminalHeader = SSEStreamTermination.isTerminal(jobState: response.value(forHTTPHeaderField: "x-job-state"))

        var dataLines: [String] = []
        var frameID: Int64?
        var received = 0
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.isEmpty {
                defer {
                    dataLines.removeAll(keepingCapacity: true)
                    frameID = nil
                }
                guard !dataLines.isEmpty else { continue }
                let data = Data(dataLines.joined(separator: "\n").utf8)
                do {
                    let event = try decoder.decode(GenerationEvent.self, from: data)
                    received += 1
                    Self.log.debug("event job=\(jobID, privacy: .public) id=\(event.id) type=\(event.type.rawValue, privacy: .public)")
                    receive(event)
                    if event.type == .completed || event.type == .failed { return .terminal }
                } catch {
                    Self.log.error("""
                        undecodable event job=\(jobID, privacy: .public) id=\(frameID ?? -1) \
                        error=\(String(describing: error), privacy: .public)
                        """)
                    if let frameID { advanceCursor(frameID) }
                }
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("id:") {
                frameID = Int64(String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces))
            }
        }
        Self.log.debug("event stream closed job=\(jobID, privacy: .public) received=\(received) terminalHeader=\(terminalHeader)")
        return terminalHeader ? .terminal : .windowExpired
    }

    private func send<Response: Decodable & Sendable>(
        path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        idempotencyKey: String? = nil
    ) async throws -> Response {
        try await send(path: path, method: method, query: query, bodyData: nil, idempotencyKey: idempotencyKey)
    }

    private func send<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: Body,
        idempotencyKey: String? = nil
    ) async throws -> Response {
        try await send(path: path, method: method, query: query, bodyData: try encoder.encode(body), idempotencyKey: idempotencyKey)
    }

    private func send<Response: Decodable & Sendable>(
        path: String,
        method: String,
        query: [URLQueryItem],
        bodyData: Data?,
        idempotencyKey: String?
    ) async throws -> Response {
        var request = try await authorizedRequest(path: path, query: query)
        request.httpMethod = method
        request.httpBody = bodyData
        if bodyData != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }

        let context = "\(method) \(path)"
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Transport failures never reach `decode`, so without this a dropped connection or a
            // TLS refusal leaves no trace at all. A cancelled request is a view going away, not a
            // fault, and logging it as one would bury the failures that matter.
            let cancelled = error is CancellationError
                || (error as NSError).code == NSURLErrorCancelled
            if !cancelled {
                Self.networkLog.error("\(context, privacy: .public): transport failure — \(String(describing: error), privacy: .public)")
            }
            throw error
        }
        guard let response = response as? HTTPURLResponse else { throw StickerAPIError.invalidResponse }
        if response.statusCode == 401 {
            request.setValue("Bearer \(try await tokenBroker.validAccessToken(forceRefresh: true))", forHTTPHeaderField: "Authorization")
            let (retryData, retryResponse) = try await session.data(for: request)
            return try decode(retryData, response: retryResponse, context: "\(context) (retried after 401)")
        }
        // A refusal for want of Apple's signed billing environment is recoverable, and recovering it
        // here is the difference between a turn that goes through and a user retyping their message:
        // the request never reached billing, so nothing was reserved and nothing was charged, and it
        // still carries its idempotency key. The one thing that changed is that StoreKit was
        // unreachable — or the resolving task was cancelled — when this request was built, so the
        // only thing worth doing differently is asking StoreKit again.
        if response.statusCode == 403,
           Self.refusedForMissingBillingProof(data),
           let refreshed = await appTransactionRefresher() {
            request.setValue(refreshed, forHTTPHeaderField: "X-StoreKit-App-Transaction")
            let (retryData, retryResponse) = try await session.data(for: request)
            return try decode(retryData, response: retryResponse, context: "\(context) (retried with refreshed billing proof)")
        }
        return try decode(data, response: response, context: context)
    }

    /// Whether a 403 is the server saying it never saw Apple's proof, rather than a refusal that
    /// asking again cannot fix — a client id that may not use this API, or a proof Apple itself
    /// declined to verify. Only the first is worth a second attempt.
    private static func refusedForMissingBillingProof(_ data: Data) -> Bool {
        struct Refusal: Decodable {
            struct Body: Decodable { let code: String }
            let error: Body
        }
        return (try? JSONDecoder().decode(Refusal.self, from: data))?.error.code == "BILLING_ENVIRONMENT_REQUIRED"
    }

    private func authorizedRequest(path: String, query: [URLQueryItem] = []) async throws -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(try await tokenBroker.validAccessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Apple signs the environment; a plain sandbox/production header is not proof.
        // Keep reads usable if StoreKit is unavailable. Billing writes fail closed on the server,
        // and `send` retries one that failed only because this came back empty.
        request.setValue(await appTransactionProvider(), forHTTPHeaderField: "X-StoreKit-App-Transaction")
        Self.addClientMetadataHeaders(
            to: &request,
            appVersion: appVersion,
            acceptLanguage: acceptLanguage
        )
        // Announces which document contract this build can decode. Without it the server assumes the
        // oldest shipped one and degrades any newer layer kind to something this client can draw —
        // which is what keeps a version bump from bricking builds already in the field. Sent on
        // every request rather than only the ones that return documents, so a new endpoint that
        // starts returning one cannot forget.
        request.setValue(String(AnimatedDocument.currentVersion), forHTTPHeaderField: "X-Sticker-Contract")
        return request
    }

    static func addClientMetadataHeaders(
        to request: inout URLRequest,
        appVersion: String?,
        acceptLanguage: String?
    ) {
        if let appVersion, !appVersion.isEmpty, !appVersion.contains("$(") {
            request.setValue(appVersion, forHTTPHeaderField: "X-iOS-App-Version")
        }
        if let acceptLanguage, !acceptLanguage.isEmpty {
            request.setValue(acceptLanguage, forHTTPHeaderField: "Accept-Language")
        }
    }

    private func decode<Response: Decodable>(_ data: Data, response: URLResponse, context: String) throws -> Response {
        guard let response = response as? HTTPURLResponse else {
            Self.networkLog.error("\(context, privacy: .public): no HTTP response")
            throw StickerAPIError.invalidResponse
        }
        guard (200...299).contains(response.statusCode) else {
            if let envelope = try? decoder.decode(APIErrorEnvelope.self, from: data) {
                Self.networkLog.error(
                    """
                    \(context, privacy: .public) → \(response.statusCode, privacy: .public) \
                    \(envelope.error.code, privacy: .public): \(envelope.error.message, privacy: .public) \
                    [request \(envelope.error.requestId, privacy: .public)] \
                    details=\(String(describing: envelope.error.details), privacy: .public)
                    """
                )
                if let refusal = SubscriptionRefusal(code: envelope.error.code, details: envelope.error.details) {
                    onSubscriptionRefusal?(refusal)
                }
                throw envelope
            }
            // Not an envelope, so the raw body is the only account of what went wrong — usually a
            // proxy or an auth layer that never reached the app's error format.
            let body = String(data: data.prefix(2_048), encoding: .utf8) ?? "<\(data.count) bytes>"
            Self.networkLog.error("""
                \(context, privacy: .public) → \(response.statusCode, privacy: .public), \
                body: \(body, privacy: .public)
                """)
            throw StickerAPIError.http(response.statusCode)
        }
        if Response.self == EmptyResponse.self, data.isEmpty, let empty = EmptyResponse() as? Response { return empty }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            // `DecodingError.localizedDescription` is "The data couldn't be read because it isn't in
            // the correct format" and never names the key. `String(describing:)` prints the coding
            // path, which is the entire answer to a contract drift.
            Self.networkLog.error("""
                \(context, privacy: .public): undecodable \(String(describing: Response.self), privacy: .public) \
                — \(String(describing: error), privacy: .public)
                """)
            throw error
        }
    }
}

nonisolated enum SSEStreamTermination {
    static func isTerminal(jobState: String?) -> Bool {
        guard let jobState else { return false }
        return ["succeeded", "failed", "cancelled"].contains(jobState)
    }
}

nonisolated struct EmptyResponse: Codable, Sendable {}

nonisolated enum StickerAPIError: Error, LocalizedError, Equatable {
    case invalidResponse
    case http(Int)
    /// Carries the status, because "upload failed" alone cannot distinguish an expired presign
    /// from a rejected content type, and those are fixed in different places.
    case uploadFailed(status: Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: String(localized: "The server returned an invalid response.")
        case .http(let code): String(localized: "The request failed (HTTP \(code)).")
        case .uploadFailed(let status): String(localized: "The media upload could not be completed (HTTP \(status)).")
        }
    }
}

extension JSONEncoder {
    nonisolated static var api: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    nonisolated static var api: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let whole = ISO8601DateFormatter()
            whole.formatOptions = [.withInternetDateTime]
            if let date = whole.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date")
        }
        return decoder
    }
}
