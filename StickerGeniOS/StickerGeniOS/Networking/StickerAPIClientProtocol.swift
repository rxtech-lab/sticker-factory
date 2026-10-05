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

    // Pet
    /// The adopted pet, or nil.
    func pet() async throws -> Pet?
    /// Adopts a controllable sticker the account owns or has installed, replacing any previous pet.
    /// Not idempotency-keyed: adopting the same sticker twice lands on the same state. `context`
    /// is recorded as the world the pet was born into; nil adopts without one.
    func setPet(stickerID: String, context: PetContextPayload?) async throws -> Pet?
    /// Lets the pet go. Clearing an empty slot is not an error.
    func clearPet() async throws
    /// The library sections narrowed to stickers that can be posed — what a pet can be chosen from.
    /// Sections with nothing controllable in them are left out, apart from "My Stickers".
    func petCandidates(query: String?) async throws -> LibrarySectionsResponse
    /// The pet drawn by the server in its current pose: a transparent PNG `size` pixels square. What
    /// the widget and the watch show, since neither can run the animation engine.
    func petPose(size: Int) async throws -> Data
    /// The weather the pet is in, drawn by the server in the pet's style: a transparent PNG `size`
    /// pixels square. Fails until `Pet.weatherArt` names a drawing.
    func petWeatherArt(size: Int) async throws -> Data
    func petWeatherArt(size: Int, artKey: String) async throws -> Data
    func petItemArt(index: Int, size: Int) async throws -> Data
    func petItemArt(index: Int, size: Int, artKey: String) async throws -> Data
    /// Performs an action and returns the pet's updated stats, pose, and spoken response.
    func interactWithPet(_ action: PetAction) async throws -> Pet?
    /// Shows the pet a JPEG: uploads it, then asks the pet to look at it. Returns the pet with its
    /// reaction, the stats the picture moved, and the actions its new mood brought.
    func sendPetPhoto(jpeg: Data) async throws -> Pet?
    /// Picks `choiceID` for the pet's open encounter. Returns what it led to and the pet after it.
    func resolvePetEncounter(encounterID: String, choiceID: String) async throws -> ResolvePetEncounterResponse
    /// Gives the ill pet one dose of medicine, curing it. Refused while it is well or has none.
    func givePetMedicine() async throws -> Pet?
    /// Hands the server the phone's coarse context for the pet's life workflow to read on its next
    /// visit. Returns whether it was kept — false when there is no pet to keep it for — and what the
    /// owner's walk paid the pet, when these steps paid it out.
    func updatePetContext(_ context: PetContextPayload) async throws -> PetContextStoredResponse
    /// One page of the pet's diary, newest first. Pass the previous page's `nextCursor` for more.
    func petEvents(cursor: String?) async throws -> PetEventsResponse

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
    func pet() async throws -> Pet? { nil }
    func setPet(stickerID: String, context: PetContextPayload?) async throws -> Pet? { throw StickerAPIError.invalidResponse }
    /// Adopts without telling the server anything about the world the pet is born into.
    func setPet(stickerID: String) async throws -> Pet? { try await setPet(stickerID: stickerID, context: nil) }
    func updatePetContext(_ context: PetContextPayload) async throws -> PetContextStoredResponse {
        PetContextStoredResponse(stored: false)
    }
    func petEvents(cursor: String?) async throws -> PetEventsResponse { PetEventsResponse(events: [], nextCursor: nil) }
    func clearPet() async throws {}
    func petCandidates(query: String?) async throws -> LibrarySectionsResponse { throw StickerAPIError.invalidResponse }
    func petPose(size: Int) async throws -> Data { throw StickerAPIError.invalidResponse }
    func petWeatherArt(size: Int) async throws -> Data { throw StickerAPIError.invalidResponse }
    func petWeatherArt(size: Int, artKey: String) async throws -> Data {
        try await petWeatherArt(size: size)
    }
    func petItemArt(index: Int, size: Int) async throws -> Data { throw StickerAPIError.invalidResponse }
    func petItemArt(index: Int, size: Int, artKey: String) async throws -> Data {
        try await petItemArt(index: index, size: size)
    }
    func interactWithPet(_ action: PetAction) async throws -> Pet? { throw StickerAPIError.invalidResponse }
    func sendPetPhoto(jpeg: Data) async throws -> Pet? { throw StickerAPIError.invalidResponse }
    func resolvePetEncounter(encounterID: String, choiceID: String) async throws -> ResolvePetEncounterResponse {
        throw StickerAPIError.invalidResponse
    }
    func givePetMedicine() async throws -> Pet? { throw StickerAPIError.invalidResponse }

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
