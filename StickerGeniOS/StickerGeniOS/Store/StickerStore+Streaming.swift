import AnimatedView
import Foundation
import OSLog

/// The live half of the store: generation-job observation, the event stream it folds into
/// messages, and the reconciliation that settles a turn the stream never finished.
extension StickerStore {
    func observeExternalJob(jobID: String, stickerID: String) {
        reattachAttempts[stickerID] = 0
        observe(jobID: jobID, stickerID: stickerID, sourceMessageID: nil, force: true, startsGeneration: true)
    }

    func upload(_ attachments: [PendingMediaAttachment], stickerID: String?, kind: AssetKind) async throws -> [String] {
        var values: [String] = []
        for attachment in attachments {
            values.append(try await api.upload(
                data: attachment.data,
                stickerID: stickerID,
                // A lifted capture overrides whatever kind the caller asked for: it is a frame
                // atlas wherever it was picked, and the server validates it as one.
                kind: attachment.sequence == nil ? kind : .sequence,
                filename: attachment.filename,
                mimeType: attachment.mimeType,
                sequence: attachment.sequence,
                idempotencyKey: UUID().uuidString
            ))
        }
        return values
    }

    /// A view disappearing cancels its `.task`, which must read as "nothing happened" rather than
    /// as an error banner. Shared with `MarketplaceStore` and the document views, which need the
    /// same distinction. `URLSession` reports cancellation as `URLError.cancelled`, never as
    /// `CancellationError`, so checking only the latter misses every cancelled request.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    /// Starts (or re-starts) the event stream for a job.
    ///
    /// Observation identity is the live `Task`, not the job id, so a stream that already died can
    /// always be re-attached. Callers read `observations[stickerID]` afterwards to know whether a
    /// stream is running.
    func observe(jobID: String, stickerID: String, sourceMessageID: String?, force: Bool = false, startsGeneration: Bool = false) {
        liveActivities?.start(
            jobID: jobID, stickerID: stickerID,
            title: details[stickerID]?.sticker.title ?? stickers.first(where: { $0.id == stickerID })?.title ?? "Your sticker",
            startsGeneration: startsGeneration
        )
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
        state.failureMessage = nil
        jobs[stickerID] = state
        computingStickerIDs.insert(stickerID)
        // The server debits as the turn begins, so this is the earlier of the two moments the
        // balance moves. The later one is the turn settling, below.
        onCreditsMayHaveChanged?()
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
                    guard jobs[stickerID]?.jobID == jobID, observationGenerations[stickerID] == generation else {
                        // The stream outlived what it was watching. Worth a line of its own: the
                        // event being dropped here may be the terminal one, and every screen reading
                        // this job is left waiting for something that has already been thrown away.
                        Self.log.debug(
                            """
                            observation superseded job=\(jobID, privacy: .public) \
                            now=\(self.jobs[stickerID]?.jobID ?? "-", privacy: .public) \
                            dropped=\(event.type.rawValue, privacy: .public)
                            """
                        )
                        break
                    }
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
        // Replayed events must not charge the on-screen work meter twice on reconnect.
        if let lastEventID = jobs[stickerID]?.lastEventID, event.id <= lastEventID { return }
        await liveActivities?.apply(event)
        if event.type == .completed || event.type == .failed,
           reportedGenerationJobs.insert(jobID).inserted {
            AppTelemetry.event("generation_result", parameters: [
                "result": event.data.cancelled == true ? "cancelled" : event.type.rawValue
            ])
        }
        var state = jobs[stickerID] ?? .init(jobID: jobID)
        state.progress = event.data.progress ?? state.progress
        state.message = event.data.message ?? state.message
        state.sourceMessageID = event.data.messageId ?? state.sourceMessageID
        applyStatus(from: event.data, to: &state)
        state.lastEventID = event.id
        state.isTerminal = event.type == .completed || event.type == .failed || event.type == .candidate
        state.isFailed = event.type == .failed
        if event.type == .failed { state.failureMessage = event.data.message }
        state.streamErrorMessage = nil
        jobs[stickerID] = state
        if event.data.outputTokens != nil || event.data.note != nil || event.data.toolStatus != nil || event.data.stage != nil {
            Self.log.notice(
                """
                progress-meter job=\(jobID, privacy: .public) event=\(event.id) \
                tokenDelta=\(event.data.outputTokens ?? 0) totalOutputTokens=\(state.outputTokens) \
                hasIncomingNote=\(event.data.note != nil) hasDisplayNote=\(state.note != nil) \
                images=\(state.imagesDrawn) clips=\(state.clipsFilmed)
                """
            )
            Self.log.debug("""
                progress-meter incomingNote=\(event.data.note ?? "-", privacy: .private) \
                displayNote=\(state.note ?? "-", privacy: .private)
                """)
        }
        // Whatever this turn cost — including a refund for one that failed — is settled by now.
        if state.isTerminal { onCreditsMayHaveChanged?() }
        Self.log.debug(
            """
            event job=\(jobID, privacy: .public) id=\(event.id) type=\(event.type.rawValue, privacy: .public) \
            terminal=\(state.isTerminal) failed=\(state.isFailed)
            """
        )

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

    /// Folds one event's status fields into the job, on the same terms as the Live Activity:
    /// whichever of them the *newest* event carries is what the turn is doing now.
    ///
    /// Tool rows are left out on purpose. They are the transcript's job, and a tool that has just
    /// finished would otherwise stand as the current status until the next stage opens.
    private nonisolated func applyStatus(from data: GenerationEventData, to state: inout StickerJobState) {
        let previousStatus = state.statusDetail
        if let message = data.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            state.statusDetail = message
        } else if let stage = data.stage, !stage.isEmpty {
            state.statusDetail = StickerToolLabel.text(forStage: stage)
        }
        // A completed tool often follows "Saved the artwork" immediately. Keep that note
        // until a new stage or tool begins, so completion does not erase the useful detail.
        if state.statusDetail != previousStatus || data.toolStatus == .streaming {
            state.note = nil
        }
        if let note = data.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            state.note = note
        }
        // Deltas, so they are added rather than assigned. Nothing here can go backwards: the only
        // thing that resets these is a new job, which gets a new state.
        if let tokens = data.outputTokens, tokens > 0 { state.outputTokens += tokens }
        if let images = data.imagesDrawn, images > 0 { state.imagesDrawn += images }
        if let clips = data.clipsFilmed, clips > 0 { state.clipsFilmed += clips }
        // A count is only ever shown against the stage that reported it, so an explicit clear and a
        // new stage's count both wipe what was there. Counts that fail to make sense are dropped
        // rather than drawn: a bar at 7/5 is worse than no bar.
        if data.clearProgress == true {
            state.completedUnits = nil
            state.totalUnits = nil
            state.progressLabel = nil
        } else if let completed = data.completedUnits, let total = data.totalUnits,
                  total > 0, completed >= 0, completed <= total {
            state.completedUnits = completed
            state.totalUnits = total
            state.progressLabel = data.progressLabel ?? state.progressLabel
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
        Self.log.debug(
            """
            stream ended job=\(jobID, privacy: .public) sawTurnEnd=\(sawTurnEnd) \
            generation=\(generation)/\(self.observationGenerations[stickerID] ?? -1) \
            watching=\(self.jobs[stickerID]?.jobID ?? "-", privacy: .public) \
            error=\(error?.localizedDescription ?? "-", privacy: .public)
            """
        )
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
            Self.log.debug(
                """
                turn left open job=\(jobID, privacy: .public) reconciled=\(reconciled) \
                live=\(self.isTurnLive(stickerID: stickerID, jobID: jobID))
                """
            )
            // Silent for a stream the system merely cancelled — backgrounding does that on every
            // long turn, and the poller has it back within seconds.
            if let error { jobs[stickerID]?.streamErrorMessage = error.localizedDescription }
            return
        }

        Self.log.debug("turn settled job=\(jobID, privacy: .public)")
        computingStickerIDs.remove(stickerID)
        jobs[stickerID]?.isTerminal = true
        onCreditsMayHaveChanged?()

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
        onCreditsMayHaveChanged?()
    }

    func stopReconciliationPolling(stickerID: String) {
        pollers[stickerID]?.cancel()
        pollers[stickerID] = nil
    }

    func resumeLatestUnfinishedTurn(stickerID: String, messages: [ChatMessage]) {
        guard let source = messages.last(where: { $0.role == .user && $0.jobId != nil }),
              let jobID = source.jobId
        else { return }
        // Export jobs have no source chat message. Refreshing an older chat turn must not
        // replace the publish being observed, including its terminal failure and reason.
        if let current = jobs[stickerID], current.sourceMessageID == nil, current.jobID != jobID {
            return
        }
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
                message: String(localized: "Generation failed. You can retry this request."),
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

    func nextLocalSequence(stickerID: String) -> Int {
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
            if let details = event.data.toolDetails {
                messages[stickerID]?[index].toolDetails = details
            }
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
            attachments: [],
            toolDetails: event.data.toolDetails
        ))
    }

    func markStreamingTools(stickerID: String, jobID: String, status: ChatMessageStatus) {
        guard let indices = messages[stickerID]?.indices else { return }
        for index in indices where messages[stickerID]?[index].jobId == jobID
            && messages[stickerID]?[index].role == .system
            && messages[stickerID]?[index].kind == .status
            && messages[stickerID]?[index].status == .streaming {
            messages[stickerID]?[index].status = status
        }
    }
}
