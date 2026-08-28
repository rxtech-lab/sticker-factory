import AnimatedView
import Foundation
import Observation

nonisolated struct PendingMediaAttachment: Identifiable, Sendable {
    var id = UUID()
    var data: Data
    var filename: String
    var mimeType: String
}

nonisolated struct StickerJobState: Sendable, Equatable {
    var jobID: String
    var sourceMessageID: String?
    var progress: Double = 0
    var message: String = "Starting…"
    var lastEventID: Int64?
    var isTerminal = false
    var isFailed = false
    /// Set when the event stream itself died, as opposed to the generation failing.
    /// Surfaced in chat so a dead stream cannot look like silence.
    var streamErrorMessage: String?
}

@MainActor
@Observable
final class StickerStore {
    private(set) var stickers: [Sticker] = []
    private(set) var details: [String: StickerDetail] = [:]
    private(set) var messages: [String: [ChatMessage]] = [:]
    private(set) var nextMessageBeforeSequence: [String: Int] = [:]
    private(set) var jobs: [String: StickerJobState] = [:]
    private(set) var streamingDocuments: [String: AnimatedDocument] = [:]
    private(set) var computingStickerIDs: Set<String> = []
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
    var isLoading = false
    var errorMessage: String?

    let api: StickerAPIClientProtocol

    /// The live event-stream task per sticker. Observation identity is the *task*, not the job
    /// id: a finished stream must be re-attachable, otherwise a turn that dies once can never
    /// recover and the chat stays silent until the user leaves and comes back.
    @ObservationIgnored private var observations: [String: Task<Void, Never>] = [:]
    /// Which observation is the current one, per sticker. The job id cannot serve as this: a
    /// re-attach to the *same* job supersedes a live stream, and without a generation the cancelled
    /// one's teardown would tear down the stream that replaced it.
    @ObservationIgnored private var observationGenerations: [String: Int] = [:]
    @ObservationIgnored private var pollers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var reattachAttempts: [String: Int] = [:]

    /// The in-flight full-library reload, if any. Launch drives `refresh()` from two places —
    /// `AppEnvironment.start()` and `LibraryView`'s appearance task — and the library is still
    /// empty while the first request is in flight, so without this both fire and the server sees
    /// the list endpoint hit twice per cold start.
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration = 0

    /// Asked to request notification permission when a turn starts. The banners themselves come
    /// from the server, which is the only side still watching once iOS suspends the app.
    @ObservationIgnored private let notifier: (any GenerationNotifying)?

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
        observations = [:]
        observationGenerations = [:]
        pollers = [:]
        reattachAttempts = [:]
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
        errorMessage = nil
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
            var loaded: [Sticker] = []
            var cursor: String?
            var seenCursors = Set<String>()
            repeat {
                let page = try await api.listStickers(cursor: cursor)
                loaded.append(contentsOf: page.items)
                guard let next = page.nextCursor, seenCursors.insert(next).inserted else {
                    cursor = nil
                    break
                }
                cursor = next
            } while cursor != nil
            var seenIDs = Set<String>()
            stickers = loaded.filter { seenIDs.insert($0.id).inserted }
            errorMessage = nil
        } catch {
            guard !Self.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
        await refreshSections()
    }

    /// Reloads the installed-pack sections.
    ///
    /// Kept separate from the paged own-sticker reload so a marketplace outage can never blank the
    /// user's own library: a failure here leaves the previous sections in place and says nothing.
    func refreshSections() async {
        do {
            sections = try await api.librarySections(status: .all).packSections
        } catch {
            guard !Self.isCancellation(error) else { return }
            // Intentionally silent: the user's own stickers loaded fine, and an error banner over
            // a working library would be worse than showing yesterday's pack list.
        }
    }

    @discardableResult
    func create(kind: StickerKind, prompt: String, references: [PendingMediaAttachment]) async throws -> Sticker {
        let assetIDs = try await upload(references, stickerID: nil, kind: .reference)
        let title = String(prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        let response = try await api.createSticker(
            .init(title: title, kind: kind, prompt: prompt, referenceAssetIds: assetIDs),
            idempotencyKey: UUID().uuidString
        )
        let detail = try await api.sticker(id: response.stickerId)
        stickers.removeAll { $0.id == detail.id }
        stickers.insert(detail.sticker, at: 0)
        reattachAttempts[detail.id] = 0
        observe(jobID: response.job.id, stickerID: detail.id, sourceMessageID: response.initialMessageId)
        return detail.sticker
    }

    /// Records a freshly fetched detail, and keeps the library's own summary of the same sticker in
    /// step with it.
    ///
    /// The two are separate copies, and a turn can change what they disagree about: the server
    /// summarizes the finished chat into a new title, so a detail stored on its own would leave the
    /// renamed project sitting under its old name on the shelf until the whole library reloaded.
    private func absorb(detail: StickerDetail) {
        details[detail.id] = detail
        if let index = stickers.firstIndex(where: { $0.id == detail.id }) {
            stickers[index] = detail.sticker
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
        }
        catch {
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
            if let index = messages[stickerID]?.firstIndex(where: { $0.id == optimisticID }) {
                messages[stickerID]?[index] = persisted
            } else {
                messages[stickerID, default: []].append(persisted)
            }
            reattachAttempts[stickerID] = 0
            observe(jobID: response.job.id, stickerID: stickerID, sourceMessageID: response.message.id)
            // Only hand `computingStickerIDs` over to the stream if one is actually running,
            // otherwise the composer would stay disabled with nothing driving it.
            startedObservation = observations[stickerID] != nil
        } catch {
            messages[stickerID]?.removeAll { $0.id == optimisticID }
            throw error
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
        observe(jobID: response.job.id, stickerID: stickerID, sourceMessageID: response.messageId, force: true)
    }

    /// Starts generating a proposed composition plan.
    ///
    /// The plan already lives on the server, so this carries no payload — it is a bare "go".
    func confirmPlan(stickerID: String, planID: String) async throws {
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
        observe(jobID: response.job.id, stickerID: stickerID, sourceMessageID: response.message.id, force: true)
        await loadMessages(stickerID: stickerID)
    }

    /// Rejects a plan. The reason is optional but worth asking for: given one, the server keeps the
    /// conversation going — it posts the reason as the next message and the agent redrafts against
    /// it, which is why this attaches to the turn that comes back.
    func cancelPlan(stickerID: String, planID: String, reason: String? = nil) async throws {
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
            observe(jobID: job.id, stickerID: stickerID, sourceMessageID: message.id, force: true)
        }
        await loadMessages(stickerID: stickerID)
    }

    func stopGeneration(stickerID: String) async throws {
        guard let state = jobs[stickerID], computingStickerIDs.contains(stickerID) else { return }
        guard !stoppingStickerIDs.contains(stickerID) else { return }
        stoppingStickerIDs.insert(stickerID)
        defer { stoppingStickerIDs.remove(stickerID) }

        let response = try await api.cancelGeneration(jobID: state.jobID, idempotencyKey: UUID().uuidString)
        observations[stickerID]?.cancel()
        observations[stickerID] = nil
        var stopped = jobs[stickerID] ?? state
        stopped.message = response.state == .cancelled ? "Stopped" : stopped.message
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

    func transition(stickerID: String, revisionID: String, action: RevisionAction) async throws {
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

    @discardableResult
    func delete(stickerID: String) async -> Bool {
        do {
            let response = try await api.deleteSticker(id: stickerID, idempotencyKey: UUID().uuidString)
            guard response.status == .deleting, response.job.state != .failed else {
                errorMessage = response.job.retryable
                    ? "Project deletion could not start. Your sticker is unchanged; please try again."
                    : "Project deletion could not start. Your sticker is unchanged."
                return false
            }
            observations[stickerID]?.cancel()
            observations[stickerID] = nil
            stopReconciliationPolling(stickerID: stickerID)
            stickers.removeAll { $0.id == stickerID }
            details[stickerID] = nil
            messages[stickerID] = nil
            computingStickerIDs.remove(stickerID)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func observeExternalJob(jobID: String, stickerID: String) {
        reattachAttempts[stickerID] = 0
        observe(jobID: jobID, stickerID: stickerID, sourceMessageID: nil, force: true)
    }

    private func upload(_ attachments: [PendingMediaAttachment], stickerID: String?, kind: AssetKind) async throws -> [String] {
        var values: [String] = []
        for attachment in attachments {
            values.append(try await api.upload(
                data: attachment.data,
                stickerID: stickerID,
                kind: kind,
                filename: attachment.filename,
                mimeType: attachment.mimeType,
                idempotencyKey: UUID().uuidString
            ))
        }
        return values
    }

    /// A view disappearing cancels its `.task`, which must read as "nothing happened" rather than
    /// as an error banner. Shared with `MarketplaceStore`, which needs the same distinction.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    /// Starts (or re-starts) the event stream for a job.
    ///
    /// Observation identity is the live `Task`, not the job id, so a stream that already died can
    /// always be re-attached. Callers read `observations[stickerID]` afterwards to know whether a
    /// stream is running.
    private func observe(jobID: String, stickerID: String, sourceMessageID: String?, force: Bool = false) {
        // Re-attach whenever the previous observation is gone, even for the same job id.
        if !force, jobs[stickerID]?.jobID == jobID, observations[stickerID] != nil { return }
        observations[stickerID]?.cancel()
        streamingDocuments[stickerID] = nil
        var state = jobs[stickerID]?.jobID == jobID
            ? jobs[stickerID]!
            : StickerJobState(jobID: jobID, sourceMessageID: sourceMessageID)
        state.sourceMessageID = sourceMessageID ?? state.sourceMessageID
        state.streamErrorMessage = nil
        state.isTerminal = false
        // A re-attach to a job id that previously failed is a fresh attempt, not the old failure
        // still standing — otherwise the failure banner sits over a turn that is already streaming.
        state.isFailed = false
        jobs[stickerID] = state
        computingStickerIDs.insert(stickerID)
        // Ask for permission — and enrol with APNs — as the first turn starts, so the prompt
        // arrives with its own reason already on screen rather than as a launch-time interrogation.
        notifier?.prepare()

        let generation = (observationGenerations[stickerID] ?? 0) &+ 1
        observationGenerations[stickerID] = generation
        observations[stickerID] = Task {
            var streamError: Error?
            // Whether the server said the turn was over, as opposed to the connection simply
            // ending. Only these two types are the server's word for it — `candidate` is posted
            // mid-turn by a plan build, which keeps working after it.
            var sawTurnEnd = false
            do {
                for try await event in api.generationEvents(jobID: jobID, after: jobs[stickerID]?.lastEventID) {
                    guard jobs[stickerID]?.jobID == jobID, observationGenerations[stickerID] == generation else { break }
                    // A stream that is delivering is a working one, so it clears the re-attach
                    // budget. That budget exists to stop a *failing* endpoint being hammered; left
                    // to accumulate across a whole turn it becomes a lifetime cap of three
                    // reconnects, which a plan build — minutes long, and reconnected every time the
                    // app is backgrounded — exhausts long before the server is finished.
                    reattachAttempts[stickerID] = 0
                    sawTurnEnd = sawTurnEnd || event.type == .completed || event.type == .failed
                    await apply(event: event, stickerID: stickerID, jobID: jobID)
                }
            } catch {
                if !Self.isCancellation(error) { streamError = error }
            }
            await finishObservation(
                stickerID: stickerID,
                jobID: jobID,
                generation: generation,
                error: streamError,
                sawTurnEnd: sawTurnEnd
            )
        }
    }

    /// Applies one event. Deliberately non-throwing: a payload this client cannot use must never
    /// end the stream, because the terminal event is what tells the chat the turn is over.
    private func apply(event: GenerationEvent, stickerID: String, jobID: String) async {
        var state = jobs[stickerID] ?? .init(jobID: jobID)
        state.progress = event.data.progress ?? state.progress
        state.message = event.data.message ?? state.message
        state.sourceMessageID = event.data.messageId ?? state.sourceMessageID
        state.lastEventID = event.id
        state.isTerminal = event.type == .completed || event.type == .failed || event.type == .candidate
        state.isFailed = event.type == .failed
        state.streamErrorMessage = nil
        jobs[stickerID] = state

        mergeToolCall(from: event, stickerID: stickerID)
        if let assistant = event.data.assistantMessage { upsert(message: assistant, stickerID: stickerID) }

        if let document = event.data.document, let validated = try? document.validated() {
            streamingDocuments[stickerID] = validated
        }
        if event.type == .candidate || event.type == .completed {
            streamingDocuments[stickerID] = nil
            if let detail = try? await api.sticker(id: stickerID) { absorb(detail: detail) }
            await loadMessages(stickerID: stickerID)
        }
        if event.type == .failed || event.data.cancelled == true {
            streamingDocuments[stickerID] = nil
            markStreamingTools(stickerID: stickerID, jobID: jobID, status: .failed)
        }
        if event.type == .failed,
           let sourceMessageID = state.sourceMessageID,
           let index = messages[stickerID]?.firstIndex(where: { $0.id == sourceMessageID }) {
            messages[stickerID]?[index].status = .failed
        }
    }

    /// Runs after the stream ends, however it ended.
    ///
    /// The stream is a latency optimisation, never the source of truth — so this always
    /// reconciles against the server. Without it, a stream that dies before the terminal event
    /// leaves the chat showing nothing at all until the user navigates away and back.
    private func finishObservation(
        stickerID: String,
        jobID: String,
        generation: Int,
        error: Error?,
        sawTurnEnd: Bool
    ) async {
        // A superseded stream finishing says nothing about the one that replaced it — even when
        // both are on the same job id, as a re-attach mid-turn is.
        guard observationGenerations[stickerID] == generation else { return }
        guard jobs[stickerID]?.jobID == jobID else { return }
        observations[stickerID] = nil
        streamingDocuments[stickerID] = nil

        await loadDetail(stickerID: stickerID)
        let reconciled = await loadMessages(stickerID: stickerID)

        // `loadMessages` may have re-attached a genuinely unfinished turn.
        guard jobs[stickerID]?.jobID == jobID, observations[stickerID] == nil else { return }

        // A stream ending is not a turn ending. Absent a terminal event, the server's word for it is
        // the source message's status — it leaves `streaming` when the turn ends, completion,
        // failure and cancellation alike. While that still says the turn is live, or while the
        // refetch that would have said otherwise never landed, the turn stays open and the
        // reconciliation poller keeps it fresh and re-attaches. Ending it here instead is what
        // strands a long plan build half-built: the transcript freezes on whichever tool row was
        // running, the composer drops back to idle, and nothing on screen can move again — the
        // poller only runs for a computing sticker, so it stops too.
        if !sawTurnEnd, !reconciled || isTurnLive(stickerID: stickerID, jobID: jobID) {
            // Silent for a stream the system merely cancelled — backgrounding does that on every
            // long turn, and the poller has it back within seconds.
            if let error { jobs[stickerID]?.streamErrorMessage = error.localizedDescription }
            return
        }

        computingStickerIDs.remove(stickerID)
        jobs[stickerID]?.isTerminal = true

        if let error, !hasAssistantTurn(stickerID: stickerID, jobID: jobID) {
            jobs[stickerID]?.streamErrorMessage = error.localizedDescription
            return
        }
    }

    /// Whether the server still says this job's turn is running.
    ///
    /// The source message's `streaming` status is the server's own word for it, and it is the only
    /// thing that stays true for the whole turn: a plan build posts tool rows and a candidate long
    /// before it is finished, so neither their presence nor the stream's liveness can stand in.
    private func isTurnLive(stickerID: String, jobID: String) -> Bool {
        messages[stickerID]?.contains {
            $0.role == .user && $0.jobId == jobID && $0.status == .streaming
        } ?? false
    }

    /// Whether the server has produced the assistant half of a turn. This, not the stream's
    /// liveness, is what says the turn is really over.
    private func hasAssistantTurn(stickerID: String, jobID: String) -> Bool {
        messages[stickerID]?.contains { $0.role == .assistant && $0.jobId == jobID } ?? false
    }

    /// Re-opens the event stream for the sticker's current job after a stream failure.
    func reattach(stickerID: String) {
        guard let state = jobs[stickerID] else { return }
        reattachAttempts[stickerID] = 0
        observe(jobID: state.jobID, stickerID: stickerID, sourceMessageID: state.sourceMessageID, force: true)
    }

    func dismissStreamError(stickerID: String) {
        jobs[stickerID]?.streamErrorMessage = nil
    }

    /// A safety net for the chat screen: while a turn is computing, refetch the transcript
    /// periodically so a stalled or dropped stream degrades to "a few seconds late" instead of
    /// "silent until you leave the screen".
    func startReconciliationPolling(stickerID: String) {
        guard pollers[stickerID] == nil else { return }
        pollers[stickerID] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self, !Task.isCancelled else { return }
                guard self.computingStickerIDs.contains(stickerID) else { continue }
                guard let jobID = self.jobs[stickerID]?.jobID else { continue }
                await self.loadMessages(stickerID: stickerID)
                await self.settleIfResolved(stickerID: stickerID, jobID: jobID)
            }
        }
    }

    /// Ends a turn the server has already answered but whose stream never said so.
    private func settleIfResolved(stickerID: String, jobID: String) async {
        guard observations[stickerID] == nil, hasAssistantTurn(stickerID: stickerID, jobID: jobID) else { return }
        if let detail = try? await api.sticker(id: stickerID) { absorb(detail: detail) }
        computingStickerIDs.remove(stickerID)
        jobs[stickerID]?.isTerminal = true
    }

    func stopReconciliationPolling(stickerID: String) {
        pollers[stickerID]?.cancel()
        pollers[stickerID] = nil
    }

    private func resumeLatestUnfinishedTurn(stickerID: String, messages: [ChatMessage]) {
        guard let source = messages.last(where: { $0.role == .user && $0.jobId != nil }),
              let jobID = source.jobId
        else { return }
        if jobs[stickerID]?.jobID == jobID, jobs[stickerID]?.isTerminal == true { return }
        let hasAssistant = hasAssistantTurn(stickerID: stickerID, jobID: jobID)
        switch source.status {
        case .streaming:
            // `streaming` is the server's own word for "this job has not finished": it flips the
            // source message to complete or failed when the turn ends, cancellation included. An
            // assistant message already in the transcript does not contradict that — a plan card is
            // posted mid-turn — so the status alone decides whether to re-attach.
            resume(jobID: jobID, stickerID: stickerID, sourceMessageID: source.id)
        case .failed:
            observations[stickerID]?.cancel()
            observations[stickerID] = nil
            streamingDocuments[stickerID] = nil
            computingStickerIDs.remove(stickerID)
            jobs[stickerID] = .init(
                jobID: jobID,
                sourceMessageID: source.id,
                progress: 1,
                message: "Generation failed. You can retry this request.",
                isTerminal: true,
                isFailed: true
            )
        case .complete:
            // Compatibility for transcripts created before active user turns
            // were represented as `streaming`: no assistant for the same job
            // still means the replay stream is the source of truth.
            guard !hasAssistant else { return }
            resume(jobID: jobID, stickerID: stickerID, sourceMessageID: source.id)
        }
    }

    /// Re-attaches to an unfinished turn, bounded so a server that fails the stream immediately
    /// cannot drive `finishObservation` → `loadMessages` → resume into a reconnect storm.
    ///
    /// The bound counts *consecutive* dead streams — a stream that delivers anything clears it — so
    /// it stays a guard against an endpoint that is refusing rather than a lifetime allowance a long
    /// turn spends simply by running long enough.
    private func resume(jobID: String, stickerID: String, sourceMessageID: String) {
        if jobs[stickerID]?.jobID == jobID, observations[stickerID] != nil { return }
        let attempts = reattachAttempts[stickerID, default: 0]
        guard attempts < 3 else { return }
        reattachAttempts[stickerID] = attempts + 1
        observe(jobID: jobID, stickerID: stickerID, sourceMessageID: sourceMessageID)
    }

    private func nextLocalSequence(stickerID: String) -> Int {
        (messages[stickerID]?.map(\.sequence).max() ?? 0) + 1
    }

    private func upsert(message: ChatMessage, stickerID: String) {
        if let index = messages[stickerID]?.firstIndex(where: { $0.id == message.id }) {
            messages[stickerID]?[index] = message
        } else {
            messages[stickerID, default: []].append(message)
        }
    }

    private func mergeToolCall(from event: GenerationEvent, stickerID: String) {
        guard let id = event.data.toolCallId,
              let name = event.data.toolName,
              let status = event.data.toolStatus
        else { return }
        if let index = messages[stickerID]?.firstIndex(where: { $0.id == id }) {
            messages[stickerID]?[index].status = status
            messages[stickerID]?[index].content = name
            return
        }
        messages[stickerID, default: []].append(.init(
            id: id,
            role: .system,
            kind: .status,
            content: name,
            targetLayerId: nil,
            imagePlacement: .replace,
            baseRevisionId: nil,
            sequence: nextLocalSequence(stickerID: stickerID),
            revisionId: nil,
            jobId: event.jobId,
            status: status,
            createdAt: event.createdAt,
            attachments: []
        ))
    }

    private func markStreamingTools(stickerID: String, jobID: String, status: ChatMessageStatus) {
        guard let indices = messages[stickerID]?.indices else { return }
        for index in indices where messages[stickerID]?[index].jobId == jobID
            && messages[stickerID]?[index].role == .system
            && messages[stickerID]?[index].kind == .status
            && messages[stickerID]?[index].status == .streaming
        {
            messages[stickerID]?[index].status = status
        }
    }
}

/// A chat send that failed, and whether the server might have accepted it anyway.
///
/// The distinction matters because the composer restores the user's text on failure. A request the
/// server *rejected* created nothing, so giving the text back is right. A request that timed out in
/// transit, or whose 2xx response failed to decode, very likely did create the message and start a
/// job — putting the text back there leaves the user staring at a turn that is already running,
/// one tap away from sending it a second time.
nonisolated struct SendMessageFailure: Error, LocalizedError {
    let underlying: any Error
    let mayHaveBeenDelivered: Bool
    var errorDescription: String? { underlying.localizedDescription }
}

nonisolated enum StickerStoreError: Error, LocalizedError {
    case turnAlreadyComputing
    case noRetryableTurn
    var errorDescription: String? {
        switch self {
        case .turnAlreadyComputing: "Wait for the current AI edit to finish before sending another."
        case .noRetryableTurn: "The failed AI turn no longer has a retryable source message."
        }
    }
}
