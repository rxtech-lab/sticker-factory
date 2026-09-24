import AnimatedView
import Foundation

nonisolated protocol StickerAPIClientProtocol: Sendable {
    func creationPresets(refresh: Bool) async throws -> CreationPresetCatalog
    func configurationLimits() async throws -> ConfigurationLimits
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
    /// The same upload, reporting bytes handed to storage as they go. `onProgress` is called off
    /// the main actor, often, with `(sent, total)`.
    func upload(
        data: Data,
        stickerID: String?,
        kind: AssetKind,
        filename: String,
        mimeType: String,
        sequence: SequenceMetadata?,
        idempotencyKey: String,
        onProgress: UploadProgressHandler?
    ) async throws -> String
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

extension StickerAPIClientProtocol {
    func creationPresets(refresh: Bool) async throws -> CreationPresetCatalog { throw StickerAPIError.invalidResponse }
    func configurationLimits() async throws -> ConfigurationLimits { throw StickerAPIError.invalidResponse }

    /// Clients that cannot observe the transfer still upload; they just never report partway.
    func upload(
        data: Data,
        stickerID: String?,
        kind: AssetKind,
        filename: String,
        mimeType: String,
        sequence: SequenceMetadata?,
        idempotencyKey: String,
        onProgress: UploadProgressHandler?
    ) async throws -> String {
        let assetID = try await upload(
            data: data,
            stickerID: stickerID,
            kind: kind,
            filename: filename,
            mimeType: mimeType,
            sequence: sequence,
            idempotencyKey: idempotencyKey
        )
        onProgress?(Int64(data.count), Int64(data.count))
        return assetID
    }
}
