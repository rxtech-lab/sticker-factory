import AnimatedView
import Foundation
import Observation
import OSLog
import UIKit

nonisolated struct StickerJobState: Sendable, Equatable {
    var jobID: String
    var sourceMessageID: String?
    var progress: Double = 0
    var message: String = String(localized: "Starting…")
    var lastEventID: Int64?
    var isTerminal = false
    var isFailed = false
    /// Why the job failed, in the server's words, when the failure arrived as an event.
    ///
    /// Separate from `message` — which any event may overwrite, and which starts out saying
    /// "Starting…" — because it is the only thing a screen can show for a job that failed after its
    /// request had already been accepted. A publish is exactly that: the call returns a job id, so
    /// nothing throws and the failure has no other way back to the person who pressed the button.
    var failureMessage: String?
    /// Set when the event stream itself died, as opposed to the generation failing.
    /// Surfaced in chat so a dead stream cannot look like silence.
    var streamErrorMessage: String?
}

@MainActor
@Observable
final class StickerStore {
    // `details`, `messages`, `jobs`, `streamingDocuments` and `computingStickerIDs` are the
    // live-turn state, written by the streaming half of the store in
    // `StickerStore+Streaming.swift`. They are read-only by convention, not by `private(set)`:
    // an extension in another file cannot reach a private setter.
    private(set) var stickers: [Sticker] = []
    var details: [String: StickerDetail] = [:]
    var messages: [String: [ChatMessage]] = [:]
    private(set) var nextMessageBeforeSequence: [String: Int] = [:]
    var jobs: [String: StickerJobState] = [:]
    var streamingDocuments: [String: AnimatedDocument] = [:]
    var computingStickerIDs: Set<String> = []
    private(set) var stoppingStickerIDs: Set<String> = []
    /// Stickers with a transcript fetch in flight. Every operation reloads the transcript, so this
    /// is only worth showing when there is nothing on screen yet — see `StickerChatView`.
    private(set) var loadingMessageStickerIDs: Set<String> = []
    private(set) var loadingOlderMessageStickerIDs: Set<String> = []
    /// Installed sticker packs, as the sections the Library renders under "My Stickers".
    ///
    /// Deliberately *alongside* `stickers` rather than replacing it: chat, creation, deletion and
    /// export all read `stickers`, and the sections endpoint caps its own-sticker list where the
    /// paged reload does not.
    private(set) var sections: [LibrarySection] = []
    /// Cursor for the next page of the user's own stickers. A refresh deliberately fetches only
    /// the first page; `LibraryView` asks for this cursor when its pagination sentinel appears.
    private(set) var nextStickerCursor: String?
    /// Remote results live beside the normal Library snapshot so cancelling search restores the
    /// user's shelf immediately instead of issuing another full reload.
    private(set) var librarySearchResults: [Sticker] = []
    private(set) var librarySearchSections: [LibrarySection] = []
    private(set) var activeLibrarySearchQuery: String?
    private(set) var nextLibrarySearchCursor: String?
    private(set) var isSearchingLibrary = false
    private(set) var isLoadingMoreLibrarySearchResults = false
    var isLoading = false
    private(set) var isLoadingMoreStickers = false
    var errorMessage: String?
    /// Why the last full library reload failed, still true right now.
    ///
    /// Deliberately separate from `errorMessage`: that one is the alert, and the alert is gone the
    /// moment the user taps OK. What is left behind on a dead network is an empty grid that looks
    /// exactly like an empty library — and, because the grid is what carries pull-to-refresh, one
    /// with no way back. This is what lets the Library say *why* it is empty and offer the retry.
    /// Cleared by the next successful load.
    private(set) var libraryLoadFailure: String?
    /// The same, for a remote search: a failed query leaves no results and no way to run it again.
    private(set) var librarySearchFailure: String?

    let api: StickerAPIClientProtocol

    /// The job lifecycle as this store sees it. Shares a category with the export sheet's own trace
    /// so one filter shows the whole chain: registered → streamed → applied → settled.
    static let log = Logger(subsystem: "app.rxlab.sticker-factory", category: "publish")

    /// The live event-stream task per sticker. Observation identity is the *task*, not the job
    /// id: a finished stream must be re-attachable, otherwise a turn that dies once can never
    /// recover and the chat stays silent until the user leaves and comes back.
    @ObservationIgnored var observations: [String: Task<Void, Never>] = [:]
    /// Which observation is the current one, per sticker. The job id cannot serve as this: a
    /// re-attach to the *same* job supersedes a live stream, and without a generation the cancelled
    /// one's teardown would tear down the stream that replaced it.
    @ObservationIgnored var observationGenerations: [String: Int] = [:]
    @ObservationIgnored var pollers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var reattachAttempts: [String: Int] = [:]
    /// A candidate is not the final result; streams can replay terminal events on reconnect.
    @ObservationIgnored var reportedGenerationJobs: Set<String> = []

    /// The in-flight full-library reload, if any. Launch drives `refresh()` from two places —
    /// `AppEnvironment.start()` and `LibraryView`'s appearance task — and the library is still
    /// empty while the first request is in flight, so without this both fire and the server sees
    /// the list endpoint hit twice per cold start.
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration = 0
    /// Invalidates late remote-search responses whenever the user changes or clears the query.
    @ObservationIgnored private var librarySearchGeneration = 0

    @ObservationIgnored var liveActivities: GenerationLiveActivityManager?

    /// Asked to request notification permission when a turn starts. The banners themselves come
    /// from the server, which is the only side still watching once iOS suspends the app.
    @ObservationIgnored let notifier: (any GenerationNotifying)?

    /// Called whenever a generation starts or ends — the two moments the user's credit balance
    /// moves. Wired in `AppEnvironment` to the subscription cache, so the count in the Library
    /// toolbar follows the work instead of waiting for a paywall or the next cold start.
    ///
    /// A closure rather than a direct reference, because generation knows nothing about billing
    /// and neither store should have to reach for the other. `SubscriptionStore.refresh()`
    /// coalesces overlapping calls, so firing this more than once per turn costs one request.
    @ObservationIgnored var onCreditsMayHaveChanged: (() -> Void)?

    init(api: StickerAPIClientProtocol, notifier: (any GenerationNotifying)? = nil) {
        self.api = api
        self.notifier = notifier
    }

    func reset() {
        for task in observations.values { task.cancel() }
        for task in pollers.values { task.cancel() }
        // A reload that outlives sign-out would repopulate the library we are clearing here.
        refreshTask?.cancel()
        refreshTask = nil
        // Invalidate a page response that may already be returning while reset clears the store.
        refreshGeneration &+= 1
        observations = [:]
        observationGenerations = [:]
        pollers = [:]
        reattachAttempts = [:]
        reportedGenerationJobs = []
        stickers = []
        details = [:]
        messages = [:]
        nextMessageBeforeSequence = [:]
        jobs = [:]
        streamingDocuments = [:]
        computingStickerIDs = []
        stoppingStickerIDs = []
        loadingMessageStickerIDs = []
        loadingOlderMessageStickerIDs = []
        sections = []
        nextStickerCursor = nil
        isLoadingMoreStickers = false
        librarySearchGeneration &+= 1
        librarySearchResults = []
        librarySearchSections = []
        activeLibrarySearchQuery = nil
        nextLibrarySearchCursor = nil
        isSearchingLibrary = false
        isLoadingMoreLibrarySearchResults = false
        errorMessage = nil
        libraryLoadFailure = nil
        librarySearchFailure = nil
    }

    func refresh() async {
        // Join whatever reload is already running instead of starting a second one. The task is
        // unstructured on purpose: a caller whose `.task` gets cancelled (a view disappearing)
        // must not tear the reload out from under the callers still waiting on it.
        if let refreshTask {
            await refreshTask.value
            return
        }
        let generation = refreshGeneration &+ 1
        refreshGeneration = generation
        let task = Task { await performRefresh() }
        refreshTask = task
        // Only clear the slot if it still holds *our* task — a `reset()` plus a new refresh can
        // land while this one is finishing, and nilling that one out would un-dedupe its joiners.
        defer { if refreshGeneration == generation { refreshTask = nil } }
        await task.value
    }

    private func performRefresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await api.listStickers(cursor: nil)
            var seenIDs = Set<String>()
            stickers = page.items.filter { seenIDs.insert($0.id).inserted }
            nextStickerCursor = Self.usableCursor(page.nextCursor)
            errorMessage = nil
            libraryLoadFailure = nil
        } catch {
            guard !Self.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            libraryLoadFailure = error.localizedDescription
        }
        await refreshSections()
    }

    /// Fetches exactly one continuation page and appends it to the current Library snapshot.
    ///
    /// Keeping the cursor until the request succeeds makes a transient failure retryable. The
    /// generation check prevents a slow continuation response from appending stale rows after a
    /// pull-to-refresh has replaced the first page.
    func loadMoreStickers() async {
        guard let cursor = nextStickerCursor, !isLoading, !isLoadingMoreStickers else { return }
        let generation = refreshGeneration
        isLoadingMoreStickers = true
        defer { isLoadingMoreStickers = false }
        do {
            let page = try await api.listStickers(cursor: cursor)
            guard generation == refreshGeneration else { return }
            var seenIDs = Set(stickers.map(\.id))
            stickers.append(contentsOf: page.items.filter { seenIDs.insert($0.id).inserted })
            let next = Self.usableCursor(page.nextCursor)
            // A repeated cursor would otherwise make the Library request the same page forever.
            nextStickerCursor = next == cursor ? nil : next
            errorMessage = nil
        } catch {
            guard generation == refreshGeneration, !Self.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Debounces a title query, then asks both authenticated Library endpoints for remote results.
    /// The owned-sticker page remains paginated; installed packs are already bounded server-side.
    func searchLibrary(query rawQuery: String, debounce: Duration = .milliseconds(300)) async {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            clearLibrarySearch()
            return
        }

        librarySearchGeneration &+= 1
        let generation = librarySearchGeneration
        activeLibrarySearchQuery = query
        librarySearchFailure = nil
        librarySearchResults = []
        librarySearchSections = []
        nextLibrarySearchCursor = nil
        isLoadingMoreLibrarySearchResults = false
        isSearchingLibrary = true
        defer {
            if generation == librarySearchGeneration { isSearchingLibrary = false }
        }

        do {
            try await Task.sleep(for: debounce)
            async let ownedRequest = api.searchStickers(query: query, cursor: nil)
            async let sectionsRequest = api.searchLibrarySections(query: query, status: .all)
            let (owned, sectionResponse) = try await (ownedRequest, sectionsRequest)
            guard generation == librarySearchGeneration, activeLibrarySearchQuery == query else { return }
            var seenIDs = Set<String>()
            AppTelemetry.event("search_completed", parameters: ["surface": "library", "result_count": owned.items.count])
            librarySearchResults = owned.items.filter { seenIDs.insert($0.id).inserted }
            librarySearchSections = sectionResponse.packSections
            nextLibrarySearchCursor = Self.usableCursor(owned.nextCursor)
            errorMessage = nil
            librarySearchFailure = nil
        } catch {
            guard generation == librarySearchGeneration, !Self.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            librarySearchFailure = error.localizedDescription
        }
    }

    func clearLibrarySearch() {
        librarySearchGeneration &+= 1
        activeLibrarySearchQuery = nil
        librarySearchFailure = nil
        librarySearchResults = []
        librarySearchSections = []
        nextLibrarySearchCursor = nil
        isSearchingLibrary = false
        isLoadingMoreLibrarySearchResults = false
    }

    func loadMoreLibrarySearchResults() async {
        guard let query = activeLibrarySearchQuery,
              let cursor = nextLibrarySearchCursor,
              !isSearchingLibrary,
              !isLoadingMoreLibrarySearchResults
        else { return }
        let generation = librarySearchGeneration
        isLoadingMoreLibrarySearchResults = true
        defer {
            if generation == librarySearchGeneration { isLoadingMoreLibrarySearchResults = false }
        }
        do {
            let page = try await api.searchStickers(query: query, cursor: cursor)
            guard generation == librarySearchGeneration, activeLibrarySearchQuery == query else { return }
            var seenIDs = Set(librarySearchResults.map(\.id))
            librarySearchResults.append(contentsOf: page.items.filter { seenIDs.insert($0.id).inserted })
            let next = Self.usableCursor(page.nextCursor)
            nextLibrarySearchCursor = next == cursor ? nil : next
            errorMessage = nil
        } catch {
            guard generation == librarySearchGeneration, !Self.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private static func usableCursor(_ cursor: String?) -> String? {
        guard let cursor, !cursor.isEmpty else { return nil }
        return cursor
    }

    /// Reloads the installed-pack sections.
    ///
    /// Kept separate from the paged own-sticker reload so a marketplace outage can never blank the
    /// user's own library: a failure here leaves the previous sections in place and surfaces the
    /// server's message through the Library alert.
    func refreshSections() async {
        do {
            sections = try await api.librarySections(status: .all).packSections
        } catch {
            guard !Self.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func create(
        kind: StickerKind,
        prompt: String,
        controllable: Bool = false,
        references: [PendingMediaAttachment]
    ) async throws -> Sticker {
        return try await AppTelemetry.measure(.createSticker) {
            let assetIDs = try await upload(references, stickerID: nil, kind: .reference)
            let title = String(prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
            let response = try await api.createSticker(
                .init(title: title, kind: kind, prompt: prompt, referenceAssetIds: assetIDs, controllable: controllable),
                idempotencyKey: UUID().uuidString
            )
            let detail = try await api.sticker(id: response.stickerId)
            stickers.removeAll { $0.id == detail.id }
            stickers.insert(detail.sticker, at: 0)
            reattachAttempts[detail.id] = 0
            observe(jobID: response.job.id, stickerID: detail.id, sourceMessageID: response.initialMessageId, startsGeneration: true)
            return detail.sticker
        }
    }

    /// Puts a picture the app is already holding into the sticker pack, published and ready to send.
    ///
    /// "Add to Sticker" has to end somewhere Messages can see, and Messages reads the *published*
    /// library — the extension mirrors the server and prunes anything the server does not list, so
    /// writing the file into the shared cache directly would survive exactly until the next
    /// refresh. The work is therefore the whole publish: import the image as a static project,
    /// render its PNG and system renditions, and register them.
    ///
    /// Nothing is generated. `importSticker` costs no model time, which is what makes this a
    /// reasonable thing to hang off a long-press.
    ///
    /// - Returns: the new sticker, already in `stickers` so the library shows it without a reload.
    @discardableResult
    func addImageToStickerPack(_ image: UIImage, title: String) async throws -> Sticker {
        return try await AppTelemetry.measure(.importSticker) {
            guard let data = image.pngData() else { throw MediaNormalizationError.unreadableImage }
            let attachment = try MediaNormalizer.reference(data: data, basename: "sticker-import")
            let assetIDs = try await upload([attachment], stickerID: nil, kind: .reference)
            guard let assetID = assetIDs.first else { throw MediaNormalizationError.unreadableImage }

            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let response = try await api.importSticker(
                .init(title: String((trimmed.isEmpty ? String(localized: "Sticker") : trimmed).prefix(64)), assetId: assetID),
                idempotencyKey: UUID().uuidString
            )

            let detail = try await api.sticker(id: response.stickerId)
            guard let revision = detail.revisions.first(where: { $0.id == response.revisionId }) else {
                throw StickerPublishError.importedRevisionUnavailable
            }
            // The image the renderer draws is the one the caller handed over, not a re-download of the
            // asset that was just uploaded from it — the bytes are the same and the round trip is not.
            // Sticker-only: a still has no video to encode, and nothing here is going to a share sheet.
            let registered = try await StickerPublisher(api: api).publish(
                stickerID: response.stickerId,
                revision: revision,
                assets: .init(images: [assetID: image]),
                verifiedAssetIDs: [assetID],
                selection: .sticker
            )

            let published = try await awaitPackPublish(stickerID: response.stickerId, jobID: registered.jobID)
            stickers.removeAll { $0.id == published.id }
            stickers.insert(published.sticker, at: 0)
            details[published.id] = published
            return published.sticker
        }
    }

    /// Waits for a registered export to actually land, and hands back the sticker once it has.
    ///
    /// Registering an export only queues it — the renditions are bound server-side — so returning
    /// here would report a sticker in the pack before there was anything in the pack. Watched
    /// directly rather than through `observe`, which would put this brand-new sticker into the
    /// computing state the chat screen draws, on a screen that is not about it.
    private func awaitPackPublish(stickerID: String, jobID: String) async throws -> StickerDetail {
        var failureMessage: String?
        do {
            for try await event in api.generationEvents(jobID: jobID, after: nil) {
                if event.type == .failed { failureMessage = event.data.message }
                if event.type == .failed || event.type == .completed { break }
            }
        } catch {
            // The stream is a latency optimisation, never the source of truth. A dropped connection
            // says nothing about the export, so it falls through to the poll below; a cancelled one
            // is the caller going away and has to stay cancelled.
            if Self.isCancellation(error) { throw error }
        }
        if let failureMessage { throw StickerPublishError.packPublishFailed(failureMessage) }

        for attempt in 0..<6 {
            if attempt > 0 { try await Task.sleep(for: .seconds(1)) }
            let detail = try await api.sticker(id: stickerID)
            if detail.activeRevision?.hasPublishedExports == true { return detail }
        }
        throw StickerPublishError.packPublishFailed(nil)
    }

    /// Records a freshly fetched detail, and keeps the library's own summary of the same sticker in
    /// step with it.
    ///
    /// The two are separate copies, and a turn can change what they disagree about: the server
    /// summarizes the finished chat into a new title, so a detail stored on its own would leave the
    /// renamed project sitting under its old name on the shelf until the whole library reloaded.
    func absorb(detail: StickerDetail) {
        details[detail.id] = detail
        if let index = stickers.firstIndex(where: { $0.id == detail.id }) {
            stickers[index] = detail.sticker
        }
        if let index = librarySearchResults.firstIndex(where: { $0.id == detail.id }) {
            librarySearchResults[index] = detail.sticker
        }
    }

    func loadDetail(stickerID: String) async {
        do {
            absorb(detail: try await api.sticker(id: stickerID))
            errorMessage = nil
        } catch {
            guard !Self.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func rename(stickerID: String, title: String) async -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        do {
            let detail = try await api.updateSticker(
                id: stickerID,
                request: .init(title: title),
                idempotencyKey: UUID().uuidString
            )
            absorb(detail: detail)
            errorMessage = nil
            AppTelemetry.event("sticker_renamed")
            return true
        } catch {
            AppTelemetry.failure(error, operation: "rename_sticker")
            guard !Self.isCancellation(error) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Refetches the transcript, and says whether it actually arrived.
    ///
    /// The answer matters to `finishObservation`: a refetch that never landed says nothing about
    /// whether the turn is over, and treating it as if it did is what ends a turn the server is
    /// still running.
    @discardableResult
    func loadMessages(stickerID: String) async -> Bool {
        loadingMessageStickerIDs.insert(stickerID)
        defer { loadingMessageStickerIDs.remove(stickerID) }
        do {
            let page = try await api.chatMessages(stickerID: stickerID, beforeSequence: nil)
            messages[stickerID] = page.items
            nextMessageBeforeSequence[stickerID] = page.nextBeforeSequence
            resumeLatestUnfinishedTurn(stickerID: stickerID, messages: page.items)
            errorMessage = nil
            return true
        } catch {
            guard !Self.isCancellation(error) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func loadOlderMessages(stickerID: String) async {
        guard let beforeSequence = nextMessageBeforeSequence[stickerID] else { return }
        // A second page request for the same cursor would prepend the same rows twice over — the
        // dedupe below saves the transcript, but the wasted round trip and the flicker are real.
        guard loadingOlderMessageStickerIDs.insert(stickerID).inserted else { return }
        defer { loadingOlderMessageStickerIDs.remove(stickerID) }
        do {
            let page = try await api.chatMessages(stickerID: stickerID, beforeSequence: beforeSequence)
            // Sort only the fetched page and prepend. Re-sorting the whole array by `sequence`
            // would reorder locally appended rows, whose sequences are synthetic.
            let older = page.items.sorted { $0.sequence < $1.sequence }
            var seen = Set<String>()
            messages[stickerID] = (older + (messages[stickerID] ?? [])).filter { seen.insert($0.id).inserted }
            nextMessageBeforeSequence[stickerID] = page.nextBeforeSequence
        } catch { errorMessage = error.localizedDescription }
    }

    func sendMessage(
        stickerID: String,
        content: String,
        references: [PendingMediaAttachment],
        mask: PendingMediaAttachment?,
        targetLayerID: String?,
        intent: ChatIntent = .edit,
        imagePlacement: ImagePlacement = .replace,
        baseRevisionID: String? = nil
    ) async throws {
        return try await AppTelemetry.measure(.sendMessage) {
            guard !computingStickerIDs.contains(stickerID) else { throw StickerStoreError.turnAlreadyComputing }
            computingStickerIDs.insert(stickerID)
            var startedObservation = false
            defer { if !startedObservation { computingStickerIDs.remove(stickerID) } }

            let optimisticID = "local-\(UUID().uuidString)"
            let optimisticSequence = nextLocalSequence(stickerID: stickerID)
            let optimisticCreatedAt = Date()
            messages[stickerID, default: []].append(.init(
                id: optimisticID,
                role: .user,
                kind: intent == .animate ? .animation : intent == .edit ? .imageEdit : .text,
                content: content,
                targetLayerId: targetLayerID,
                imagePlacement: imagePlacement,
                baseRevisionId: baseRevisionID,
                sequence: optimisticSequence,
                revisionId: nil,
                jobId: nil,
                status: .streaming,
                createdAt: optimisticCreatedAt,
                attachments: []
            ))

            do {
                let assets = try await upload(references, stickerID: stickerID, kind: .reference)
                let maskAsset: String?
                if let mask {
                    maskAsset = try await upload([mask], stickerID: stickerID, kind: .mask).first
                } else {
                    maskAsset = nil
                }
                var attachmentRequests = assets.map { ChatAttachmentRequest(assetId: $0, kind: .reference, targetLayerId: targetLayerID) }
                if let maskAsset { attachmentRequests.append(.init(assetId: maskAsset, kind: .mask, targetLayerId: targetLayerID)) }
                let response: SendChatMessageResponse
                do {
                    response = try await api.sendChatMessage(
                        stickerID: stickerID,
                        request: .init(
                            text: content,
                            intent: intent,
                            attachments: attachmentRequests,
                            targetLayerId: targetLayerID,
                            imagePlacement: imagePlacement,
                            baseRevisionId: baseRevisionID
                        ),
                        idempotencyKey: UUID().uuidString
                    )
                } catch {
                    // Only this one call can leave a turn running on the server that the client never
                    // learned about, so it is the only place that has to report the ambiguity.
                    throw SendMessageFailure(underlying: error, mayHaveBeenDelivered: Self.mayHaveBeenDelivered(error))
                }
                let persisted = ChatMessage(
                    id: response.message.id,
                    role: .user,
                    kind: intent == .animate ? .animation : intent == .edit ? .imageEdit : .text,
                    content: content,
                    targetLayerId: targetLayerID,
                    imagePlacement: imagePlacement,
                    baseRevisionId: baseRevisionID,
                    sequence: optimisticSequence,
                    revisionId: nil,
                    jobId: response.job.id,
                    status: response.message.status,
                    createdAt: optimisticCreatedAt,
                    attachments: attachmentRequests.map { .init(assetId: $0.assetId, kind: $0.kind, targetLayerId: $0.targetLayerId) }
                )
                if messages[stickerID]?.contains(where: { $0.id == persisted.id }) == true {
                    // A transcript refresh can receive the saved row before this send returns.
                    // Keep its authoritative sequence, timestamp and status, and discard any local echo.
                    messages[stickerID]?.removeAll { $0.id == optimisticID }
                } else if let index = messages[stickerID]?.firstIndex(where: { $0.id == optimisticID }) {
                    messages[stickerID]?[index] = persisted
                } else {
                    messages[stickerID, default: []].append(persisted)
                }
                reattachAttempts[stickerID] = 0
                observe(jobID: response.job.id, stickerID: stickerID, sourceMessageID: response.message.id, startsGeneration: true)
                // Only hand `computingStickerIDs` over to the stream if one is actually running,
                // otherwise the composer would stay disabled with nothing driving it.
                startedObservation = observations[stickerID] != nil
            } catch {
                messages[stickerID]?.removeAll { $0.id == optimisticID }
                throw error
            }
        }
    }

    /// Whether a failed send might still have reached the server.
    ///
    /// A structured error envelope or a non-2xx status means the server answered and refused, so
    /// nothing exists. Anything else — a dropped connection, a timeout, a 2xx body the client could
    /// not decode — leaves the outcome unknown, and the safe assumption is that it landed.
    private static func mayHaveBeenDelivered(_ error: any Error) -> Bool {
        if error is APIErrorEnvelope { return false }
        if case StickerAPIError.http = error { return false }
        return true
    }

    func retryFailedMessage(stickerID: String) async throws {
        return try await AppTelemetry.measure(.retryMessage) {
            guard let state = jobs[stickerID], state.isFailed, let sourceMessageID = state.sourceMessageID else {
                throw StickerStoreError.noRetryableTurn
            }
            let response = try await api.retryChatMessage(
                stickerID: stickerID,
                messageID: sourceMessageID,
                idempotencyKey: UUID().uuidString
            )
            if let index = messages[stickerID]?.firstIndex(where: { $0.id == response.messageId }) {
                messages[stickerID]?[index].status = .streaming
                messages[stickerID]?[index].jobId = response.job.id
            }
            reattachAttempts[stickerID] = 0
            observe(jobID: response.job.id, stickerID: stickerID, sourceMessageID: response.messageId, force: true, startsGeneration: true)
        }
    }

    /// Starts generating a proposed composition plan.
    ///
    /// The plan already lives on the server, so this carries no payload — it is a bare "go".
    func confirmPlan(stickerID: String, planID: String) async throws {
        return try await AppTelemetry.measure(.confirmPlan) {
            guard !computingStickerIDs.contains(stickerID) else { throw StickerStoreError.turnAlreadyComputing }
            let response = try await api.confirmPlan(
                stickerID: stickerID,
                planID: planID,
                idempotencyKey: UUID().uuidString
            )
            // Attach before reloading the transcript, not after: the reload sees a user message that is
            // already streaming and would otherwise open its own stream for the same job, which this
            // call would then immediately supersede.
            reattachAttempts[stickerID] = 0
            observe(jobID: response.job.id, stickerID: stickerID, sourceMessageID: response.message.id, force: true, startsGeneration: true)
            await loadMessages(stickerID: stickerID)
        }
    }

    func selectPlanVersion(stickerID: String, versionID: String, current: PlanRecord) async throws {
        guard !computingStickerIDs.contains(stickerID) else { throw StickerStoreError.turnAlreadyComputing }
        let response = try await api.selectPlanVersion(
            stickerID: stickerID, versionID: versionID,
            request: .init(currentPlanId: current.id, currentRevision: current.revision),
            idempotencyKey: UUID().uuidString
        )
        if let index = messages[stickerID]?.firstIndex(where: { $0.id == response.messageId }) {
            messages[stickerID]?[index].plan = response.plan
        } else {
            await loadMessages(stickerID: stickerID)
        }
    }

    /// Saves the user's own edit of the live plan card.
    ///
    /// The server keeps the version the edit started from, so this needs no undo of its own: an
    /// unwanted change is reversed by picking the previous version out of the same picker that
    /// restores an agent draft.
    func editPlan(stickerID: String, current: PlanRecord, edit: PlanEdit) async throws {
        guard !computingStickerIDs.contains(stickerID) else { throw StickerStoreError.turnAlreadyComputing }
        let response = try await api.editPlan(
            stickerID: stickerID, planID: current.id,
            request: .init(currentRevision: current.revision, edit: edit),
            idempotencyKey: UUID().uuidString
        )
        if let index = messages[stickerID]?.firstIndex(where: { $0.id == response.messageId }) {
            messages[stickerID]?[index].plan = response.plan
        } else {
            await loadMessages(stickerID: stickerID)
        }
    }

    /// Rejects a plan. The reason is optional but worth asking for: given one, the server keeps the
    /// conversation going — it posts the reason as the next message and the agent redrafts against
    /// it, which is why this attaches to the turn that comes back.
    func cancelPlan(stickerID: String, planID: String, reason: String? = nil) async throws {
        return try await AppTelemetry.measure(.cancelPlan) {
            // A reason starts a turn, and the server allows only one at a time. Say so here rather than
            // letting it come back as a 409 that would also have thrown the plan away.
            let hasReason = !(reason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            if hasReason, computingStickerIDs.contains(stickerID) { throw StickerStoreError.turnAlreadyComputing }
            let response = try await api.cancelPlan(
                stickerID: stickerID,
                planID: planID,
                reason: reason,
                idempotencyKey: UUID().uuidString
            )
            // Attached before the transcript reload for the same reason as `confirmPlan`: the reload
            // would otherwise see a streaming user message and open a second stream for one job.
            if let job = response.job, let message = response.message {
                reattachAttempts[stickerID] = 0
                observe(jobID: job.id, stickerID: stickerID, sourceMessageID: message.id, force: true, startsGeneration: true)
            }
            await loadMessages(stickerID: stickerID)
        }
    }

    func stopGeneration(stickerID: String) async throws {
        return try await AppTelemetry.measure(.stopGeneration) {
            guard let state = jobs[stickerID], computingStickerIDs.contains(stickerID) else { return }
            guard !stoppingStickerIDs.contains(stickerID) else { return }
            stoppingStickerIDs.insert(stickerID)
            defer { stoppingStickerIDs.remove(stickerID) }

            let response = try await api.cancelGeneration(jobID: state.jobID, idempotencyKey: UUID().uuidString)
            observations[stickerID]?.cancel()
            observations[stickerID] = nil
            var stopped = jobs[stickerID] ?? state
            stopped.message = response.state == .cancelled ? String(localized: "Stopped") : stopped.message
            stopped.progress = response.state == .cancelled ? 1 : stopped.progress
            stopped.isTerminal = true
            stopped.isFailed = response.state == .failed
            jobs[stickerID] = stopped
            streamingDocuments[stickerID] = nil
            computingStickerIDs.remove(stickerID)
            if response.state == .cancelled {
                markStreamingTools(stickerID: stickerID, jobID: state.jobID, status: .failed)
            }
            await loadMessages(stickerID: stickerID)
        }
    }

    /// Saves a document edited on device as a new revision.
    ///
    /// Unlike `transition`, a failure here is rethrown rather than parked in `errorMessage`: the
    /// editor is still on screen holding the only copy of the edit, and it needs to keep it and say
    /// so rather than silently dismissing.
    @discardableResult
    func saveEditedDocument(
        stickerID: String,
        parentRevisionID: String,
        document: AnimatedDocument,
        note: String? = nil
    ) async throws -> SaveEditedDocumentResponse {
        return try await AppTelemetry.measure(.saveDocument) {
            let response = try await api.saveEditedDocument(
                stickerID: stickerID,
                request: .init(parentRevisionId: parentRevisionID, document: document, note: note),
                // A fresh key per attempt, not per session: the server hashes the whole body against
                // it, so reusing one for a changed document is a conflict rather than a save.
                idempotencyKey: UUID().uuidString
            )
            details[stickerID] = try await api.sticker(id: stickerID)
            // The edit shows up in the transcript as its own message, and it retires any candidate it
            // moved past, so both have to be re-read rather than patched locally.
            streamingDocuments[stickerID] = nil
            await loadMessages(stickerID: stickerID)
            await refresh()
            return response
        }
    }

    func transition(stickerID: String, revisionID: String, action: RevisionAction) async throws {
        return try await AppTelemetry.measure(.revisionAction) {
            do {
                _ = try await api.transitionRevision(
                    stickerID: stickerID,
                    revisionID: revisionID,
                    action: action,
                    idempotencyKey: UUID().uuidString
                )
                details[stickerID] = try await api.sticker(id: stickerID)
                streamingDocuments[stickerID] = nil
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
                throw error
            }
        }
    }

    @discardableResult
    func delete(stickerID: String) async -> Bool {
        do {
            let response = try await api.deleteSticker(id: stickerID, idempotencyKey: UUID().uuidString)
            guard response.status == .deleting, response.job.state != .failed else {
                errorMessage = response.job.retryable
                    ? String(localized: "Project deletion could not start. Your sticker is unchanged; please try again.")
                    : String(localized: "Project deletion could not start. Your sticker is unchanged.")
                return false
            }
            observations[stickerID]?.cancel()
            observations[stickerID] = nil
            stopReconciliationPolling(stickerID: stickerID)
            stickers.removeAll { $0.id == stickerID }
            librarySearchResults.removeAll { $0.id == stickerID }
            details[stickerID] = nil
            messages[stickerID] = nil
            computingStickerIDs.remove(stickerID)
            AppTelemetry.event("sticker_deleted")
            return true
        } catch {
            AppTelemetry.failure(error, operation: "delete_sticker")
            errorMessage = error.localizedDescription
            return false
        }
    }
}
