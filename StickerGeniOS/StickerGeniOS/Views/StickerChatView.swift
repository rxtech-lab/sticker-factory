import AnimatedView
import PhotosUI
import SwiftUI
import UIKit

struct StickerChatView: View {
    @Bindable var store: StickerStore
    let stickerID: String

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var referenceItems: [PhotosPickerItem] = []
    @State private var references: [PendingMediaAttachment] = []
    @State private var privacyAccepted = false
    @State private var showingPrivacy = false
    @State private var localError: String?
    /// Non-failure guidance shown under the composer. Distinct from `localError` so an ordinary
    /// next step is never dressed up as something going wrong.
    @State private var localHint: String?
    @State private var assetStore = StickerAssetStore()
    @State private var exportModel = StickerExportModel()
    @State private var showingVersions = false
    @State private var showingExport = false
    @State private var showingComparison = false
    @State private var confirmingDelete = false
    @State private var showingCandidate = false
    @State private var isDeciding = false
    @State private var isConfirmingPlan = false
    /// A retry is in flight. Held here rather than read off the job, because the job only stops
    /// looking failed once the replacement stream opens — well after the tap.
    @State private var isRetrying = false
    @State private var presentedDocument: PresentedStickerDocument?
    /// Measured, not fixed: the bar grows with reference chips, a multi-line draft and the
    /// candidate banner, and the transcript has to keep exactly that much room free under it.
    @State private var bottomBarHeight: CGFloat = 0
    @State private var streamHaptics = StreamHaptics()
    /// Set when the user stops the turn themselves. Stopping already answers the tap with its own
    /// beat, and the turn ending is that same action arriving — not news.
    @State private var stoppedByUser = false
    /// Whether a turn has streamed while this screen has been open. Gates the candidate haptic:
    /// opening a chat that already had a candidate waiting is not an arrival, and announcing it
    /// with the same buzz as one that just landed would make the buzz mean nothing.
    @State private var hasStreamedTurn = false
    /// Candidates the user has already turned down, hidden from the moment they tap rather than
    /// when the round trip lands. The banner and the sheet are a decision waiting to be made;
    /// leaving either up after it has been made reads as the tap not registering.
    @State private var rejectedRevisionIDs: Set<String> = []

    private var detail: StickerDetail? { store.details[stickerID] }
    private var candidate: StickerRevision? {
        detail?.revisions.first { $0.state == .candidate && !rejectedRevisionIDs.contains($0.id) }
    }
    private var activeRevision: StickerRevision? { detail?.activeRevision }
    private var messages: [ChatMessage] { store.messages[stickerID] ?? [] }
    private var isComputing: Bool { store.computingStickerIDs.contains(stickerID) }
    /// Only for a transcript with nothing in it yet. Every accept, save and stop reloads the
    /// messages too, and flashing a skeleton over a transcript the reader is already reading
    /// would be worse than the moment of stale content it replaces.
    private var isLoadingTranscript: Bool {
        messages.isEmpty && store.loadingMessageStickerIDs.contains(stickerID)
    }
    private var canSend: Bool {
        (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !references.isEmpty) && !isComputing
    }
    /// Whether a plan card is live is the server's call: only it knows whether the card is still
    /// showing the current revision of a draft the agent may have rewritten since. Taking the
    /// newest on top of that keeps scrolled-up history inert even if two cards ever both qualify.
    private var actionablePlanID: String? {
        messages.compactMap(\.plan).last(where: \.actionable)?.id
    }
    private var mediaPreloadToken: String {
        let revisionIDs = messages.compactMap(\.revisionId)
        let attachmentIDs = messages.flatMap(\.attachments).map(\.assetId)
        return (revisionIDs + attachmentIDs).joined(separator: ":")
    }
    /// How much the assistant has written in the turn being streamed, as a haptic trigger only.
    /// Zero while nothing is computing, so a transcript arriving from a refetch never ticks.
    private var streamedCharacterCount: Int {
        guard isComputing else { return 0 }
        return messages.last(where: { $0.role == .assistant })?.content.count ?? 0
    }
    /// The tool rows and their states as one value, so a tool starting or finishing is a change.
    private var toolCallSignature: String {
        messages.filter { $0.kind == .status }
            .map { "\($0.id):\($0.status.rawValue)" }
            .joined(separator: ",")
    }

    /// The revision the sticker actions operate on. Nothing renders it — the assistant attaches
    /// the sticker to its own message — but export needs its assets loaded and verified.
    private var workingDocument: AnimatedDocument? {
        candidate?.document ?? activeRevision?.document
    }

    var body: some View {
        StickerBackground {
            // The composer floats over the transcript rather than sitting in a bar below it:
            // it carries its own glass and nothing else paints behind it, so the messages
            // stay full-height and simply scroll under it.
            ZStack(alignment: .bottom) {
                ZStack {
                    transcript
                        .opacity(isLoadingTranscript ? 0 : 1)
                    if isLoadingTranscript {
                        TranscriptSkeleton()
                            .padding(.top, 16)
                            .padding(.bottom, bottomBarHeight)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: isLoadingTranscript)
                bottomBar
            }
        }
        .navigationTitle(detail?.title ?? "Sticker")
        .navigationBarTitleDisplayMode(.inline)
        // Chat is the whole detail screen; the tab bar would sit under the composer.
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                StickerChatActionsMenu(
                    candidate: candidate,
                    activeRevision: activeRevision,
                    isBusy: isDeciding,
                    onAcceptCandidate: { if let candidate { Task { await acceptCandidate(candidate) } } },
                    onRejectCandidate: { if let candidate { Task { await rejectCandidate(candidate) } } },
                    onCompare: { showingComparison = true },
                    onExport: { showingExport = true },
                    onViewVersions: { showingVersions = true },
                    onDelete: { confirmingDelete = true }
                )
            }
        }
        .task {
            await store.loadDetail(stickerID: stickerID)
            await store.loadMessages(stickerID: stickerID)
            store.startReconciliationPolling(stickerID: stickerID)
            await preloadMessageMedia()
        }
        .onDisappear { store.stopReconciliationPolling(stickerID: stickerID) }
        .task(id: mediaPreloadToken) { await preloadMessageMedia() }
        .task(id: workingDocument) {
            if let document = workingDocument { await assetStore.preload(document: document, api: store.api) }
        }
        .onChange(of: referenceItems) { _, items in Task { await loadReferences(items) } }
        // MARK: Haptics for the live turn
        .onChange(of: isComputing) { _, computing in
            if computing {
                hasStreamedTurn = true
                streamHaptics.beginTurn()
            } else {
                turnEnded()
            }
        }
        .onChange(of: streamedCharacterCount) { _, count in
            guard isComputing else { return }
            streamHaptics.typed(characterCount: count)
        }
        // A tool starting or landing is a distinct beat in the turn, and rare enough — a handful
        // per turn — that it needs no throttling of its own.
        .onChange(of: toolCallSignature) { _, _ in
            guard isComputing else { return }
            Haptics.tap(.soft, intensity: 0.5)
        }
        .onChange(of: store.jobs[stickerID]?.streamErrorMessage) { oldValue, newValue in
            if oldValue == nil, newValue != nil { Haptics.warning() }
        }
        .alert("Using personal photos", isPresented: $showingPrivacy) {
            Button("Continue") { privacyAccepted = true }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Reference images are uploaded privately and become part of this sticker’s persistent chat and revision history until project deletion.")
        }
        .sheet(isPresented: $showingCandidate) {
            if let candidate {
                CandidateReadySheet(
                    revision: candidate,
                    assets: assetStore.images,
                    isBusy: isDeciding,
                    onAccept: { Task { await acceptCandidate(candidate) } },
                    // Comparison is a second sheet: let this one finish leaving before it
                    // arrives, or the presentation lands on a view that is on its way out.
                    onCompare: {
                        Task {
                            try? await Task.sleep(for: .milliseconds(350))
                            showingComparison = true
                        }
                    },
                    onReject: { Task { await rejectCandidate(candidate) } }
                )
            }
        }
        // The banner is the only way back into the sheet; leaving it open once the candidate
        // is gone would offer a decision that no longer exists.
        .onChange(of: candidate?.id) { oldValue, newValue in
            if newValue == nil {
                showingCandidate = false
            } else if oldValue == nil, hasStreamedTurn {
                Haptics.success()
            }
        }
        // A turn only starts because the user asked for one — by sending a message, or by turning a
        // plan down with a reason. Their attention is on the transcript at that point, so an
        // undecided candidate's sheet must get out of the way. The banner stays: the decision is
        // still theirs to make, just not on top of the work they just asked for.
        .onChange(of: isComputing) { _, newValue in
            if newValue { showingCandidate = false }
        }
        .sheet(isPresented: $showingVersions) {
            NavigationStack {
                StickerVersionsSheet(store: store, stickerID: stickerID, assets: assetStore.images)
            }
        }
        .sheet(isPresented: $showingComparison) {
            NavigationStack {
                RevisionComparisonView(store: store, stickerID: stickerID, assets: assetStore.images)
            }
        }
        .sheet(isPresented: $showingExport) {
            NavigationStack {
                if let revision = activeRevision {
                    StickerExportSheet(
                        store: store,
                        model: exportModel,
                        stickerID: stickerID,
                        revision: revision,
                        assetStore: assetStore
                    )
                } else {
                    EmptyStateView(
                        symbol: "shippingbox",
                        title: "Nothing to export yet",
                        message: "Accept a candidate first, then export and publish it."
                    )
                }
            }
        }
        .fullScreenCover(item: $presentedDocument) { presented in
            FullScreenStickerPlayer(
                document: presented.document,
                assets: assetStore.images,
                // Editing needs a revision to parent the save onto. A bubble whose document came
                // from a live generation stream has none yet, so that one opens view-only.
                editing: presented.revisionID.map {
                    .init(store: store, stickerID: stickerID, revisionID: $0, assetStore: assetStore)
                }
            )
        }
        .confirmationDialog("Delete this sticker project?", isPresented: $confirmingDelete) {
            Button("Delete project", role: .destructive) {
                Haptics.tap(.heavy)
                Task {
                    if await store.delete(stickerID: stickerID) { dismiss() } else { Haptics.failure() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletion starts a durable purge of the private source images, transcript, revisions, and exports.")
        }
    }

    // MARK: - Transcript

    /// The transcript pins the newest user message to the top of the viewport when it is
    /// sent, so the turn being worked on is the thing on screen. The space under the turn
    /// is computed from the live viewport height rather than being a fixed padding, and
    /// the list never scrolls itself afterwards — a reply that outgrows the viewport waits
    /// below the fold until the reader goes there. See `MessageList`.
    private var transcript: some View {
        MessageList(
            messages: messages,
            isStreaming: isComputing
        ) { message in
            transcriptRow(message)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        } leadingContent: {
            if store.loadingOlderMessageStickerIDs.contains(stickerID) {
                // Replaces the button rather than sitting beside it: leaving a tappable control
                // above a page that is already on its way just invites a second request.
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading earlier messages…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("loading-older-chat-messages")
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            } else if store.nextMessageBeforeSequence[stickerID] != nil {
                Button("Load earlier messages", systemImage: "clock.arrow.circlepath") {
                    Task { await store.loadOlderMessages(stickerID: stickerID) }
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("load-older-chat-messages")
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        } trailingContent: {
            transcriptTail
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentMargins(.top, 16, for: .scrollContent)
        .contentMargins(.bottom, bottomBarHeight, for: .scrollContent)
    }

    /// Everything that belongs to the newest turn but is not itself a message. It sits
    /// above the reserved tail space, so it is measured as part of the pinned turn.
    @ViewBuilder
    private var transcriptTail: some View {
        if isComputing {
            AssistantTypingIndicator()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }

        if let job = store.jobs[stickerID], job.isFailed, job.sourceMessageID != nil {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(job.message)
                    .font(.callout)
                Spacer()
                // The retry request itself takes a moment, and until the new job's stream opens
                // nothing else on screen moves — so the button becomes the progress it started.
                if isRetrying {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Retrying…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("retrying-failed-generation")
                    .transition(.opacity)
                } else {
                    Button("Retry") {
                        Haptics.tap(.light)
                        Task { await retryFailedTurn() }
                    }
                        .buttonStyle(.glassProminent)
                        .accessibilityIdentifier("retry-failed-generation")
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isRetrying)
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func transcriptRow(_ message: ChatMessage) -> some View {
        if message.kind == .deviceEdit {
            // The divider says an edit happened; the sticker under it says what the edit produced,
            // so the transcript reads the same for a hand edit as for a generated turn.
            VStack(alignment: .leading, spacing: 10) {
                TranscriptDivider(text: message.content)

                if let document = revisionDocument(for: message) {
                    HStack(spacing: 0) {
                        Button {
                            Haptics.tap(.light)
                            presentedDocument = .init(document: document, revisionID: message.revisionId)
                        } label: {
                            // Sized outright rather than left to `aspectRatio` inside a full-width
                            // row: an unbounded height proposal there resolves to the row's width,
                            // which reserves a screenful of empty space under the sticker.
                            StickerAttachment(document: document, assets: assetStore.images)
                                .frame(width: 200, height: 200)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("show-sticker-attachment")

                        Spacer(minLength: 0)
                    }
                }
            }
        } else if let record = message.plan {
            PlanCard(
                record: record.id == actionablePlanID ? record : record.readOnly,
                isBusy: isConfirmingPlan || isComputing,
                onConfirm: { Task { await confirmPlan(record) } },
                onReject: { reason in Task { await rejectPlan(record, reason: reason) } }
            )
        } else {
            ChatBubble(
                message: message,
                sticker: revisionDocument(for: message),
                assets: assetStore.images,
                onOpenSticker: {
                    Haptics.tap(.light)
                    presentedDocument = .init(document: $0, revisionID: message.revisionId)
                }
            )
        }
    }

    // MARK: - Bottom bar

    /// Everything that floats over the foot of the transcript: connection trouble, the
    /// candidate decision, and the composer itself — in that order, closest thing to the
    /// thumb last. Its measured height becomes the transcript's bottom content margin.
    private var bottomBar: some View {
        VStack(spacing: 10) {
            streamErrorBanner

            if candidate != nil {
                CandidateReadyBanner(isBusy: isDeciding) {
                    Haptics.tap(.light)
                    showingCandidate = true
                }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            composer
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.25), value: candidate?.id)
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.height
        } action: { height in
            bottomBarHeight = height
        }
    }

    @ViewBuilder
    private var streamErrorBanner: some View {
        if let message = store.jobs[stickerID]?.streamErrorMessage {
            HStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lost the live connection")
                        .font(.subheadline.weight(.semibold))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button("Reconnect") { store.reattach(stickerID: stickerID) }
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("reconnect-stream")
                Button {
                    store.dismissStreamError(stickerID: stickerID)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss connection warning")
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            .accessibilityIdentifier("stream-error-banner")
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !references.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(references) { reference in
                            ComposerMediaChip(media: reference) {
                                Haptics.selection()
                                references.removeAll { $0.id == reference.id }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.never)
            }

            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    if privacyAccepted {
                        PhotosPicker(
                            selection: $referenceItems,
                            maxSelectionCount: 8,
                            matching: .images,
                            preferredItemEncoding: .compatible
                        ) {
                            Label("Photo Library", systemImage: "photo.on.rectangle")
                        }
                    } else {
                        Button("Add photos") { showingPrivacy = true }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.title3.weight(.medium))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppColors.accent)
                .accessibilityLabel("Add photos")
                .accessibilityIdentifier("add-chat-attachment")

                TextField("Message Sticker Factory", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("chat-composer")

                Button {
                    // Fired here rather than after the request: the tap is what the feel belongs
                    // to, and the send is a round trip away.
                    Haptics.tap(isComputing ? .rigid : .light)
                    if isComputing {
                        stoppedByUser = true
                        Task { await stop() }
                    } else {
                        // Emptied in the tap's own update rather than inside the send: the composer
                        // is answering the tap, and nothing about when it clears should depend on
                        // where the request happens to suspend.
                        let draft = takeComposerDraft()
                        Task { await send(draft) }
                    }
                } label: {
                    Image(systemName: isComputing ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(isComputing ? Color.red : AppColors.accent)
                }
                .buttonStyle(.plain)
                .disabled(isComputing ? store.stoppingStickerIDs.contains(stickerID) : !canSend)
                .accessibilityLabel(isComputing ? "Stop" : "Send")
                .accessibilityIdentifier(isComputing ? "stop-streaming" : "send-chat-message")
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))

            if let error = localError ?? store.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let localHint {
                Text(localHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// A device edit is authored as `role: .user` so the agent reads it as the user's doing, but it
    /// still owns the revision it saved — so it gets the same attachment an assistant turn would.
    private func revisionDocument(for message: ChatMessage) -> AnimatedDocument? {
        guard message.role == .assistant || message.kind == .deviceEdit else { return nil }
        guard let revisionID = message.revisionId else { return nil }
        return detail?.revisions.first(where: { $0.id == revisionID })?.document
    }

    private func preloadMessageMedia() async {
        for message in messages {
            for attachment in message.attachments {
                await assetStore.load(assetID: attachment.assetId, api: store.api)
            }
            if let document = revisionDocument(for: message) {
                await assetStore.preload(document: document, api: store.api)
            }
        }
    }

    private func loadReferences(_ items: [PhotosPickerItem]) async {
        var loaded: [PendingMediaAttachment] = []
        for (index, item) in items.prefix(8).enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            do { loaded.append(try MediaNormalizer.reference(data: data, basename: "chat-reference-\(index)")) }
            catch { localError = error.localizedDescription }
        }
        references = loaded
        if !loaded.isEmpty { Haptics.selection() }
    }

    /// What the composer held, taken out of it.
    ///
    /// Sending empties the composer before it has anywhere to put what it took, so the draft travels
    /// with the request that is trying to deliver it — and comes back if that request is refused.
    private struct ComposerDraft {
        var text: String
        var referenceItems: [PhotosPickerItem]
        var references: [PendingMediaAttachment]
    }

    private func takeComposerDraft() -> ComposerDraft {
        let draft = ComposerDraft(text: text, referenceItems: referenceItems, references: references)
        text = ""
        referenceItems = []
        references = []
        return draft
    }

    private func send(_ draft: ComposerDraft) async {
        let submittedText = draft.text
        let submittedReferenceItems = draft.referenceItems
        let submittedReferences = draft.references
        let value = submittedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = value.isEmpty ? "Use these reference images for the sticker." : value
        let baseRevisionID = detail?.revisions.first(where: { $0.state == .candidate })?.id ?? detail?.activeRevisionId

        localError = nil
        localHint = nil

        do {
            try await store.sendMessage(
                stickerID: stickerID,
                content: content,
                references: submittedReferences,
                mask: nil,
                targetLayerID: nil,
                intent: .chat,
                imagePlacement: .replace,
                baseRevisionID: baseRevisionID
            )
            localError = nil
        } catch {
            // Giving the text back is only correct when the send certainly never became a turn. If
            // it may have landed, the turn is already running: restoring the composer would show the
            // user their message twice and invite them to send a duplicate. Refetch instead, so the
            // real message and its job appear without waiting for the reconciliation poller.
            if (error as? SendMessageFailure)?.mayHaveBeenDelivered == true {
                await store.loadMessages(stickerID: stickerID)
                await store.loadDetail(stickerID: stickerID)
            } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Only into a composer still empty from the send. Once the user has started typing
                // again, the refused message must not shove itself in front of what they are writing
                // now — losing a rejected draft beats mangling a live one.
                text = submittedText
                referenceItems = Array((submittedReferenceItems + referenceItems).prefix(8))
                references = Array((submittedReferences + references).prefix(8))
            }
            localError = error.localizedDescription
            Haptics.failure()
        }
    }

    /// The single beat that says the turn is over. A candidate announces itself through
    /// `candidate`'s own handler, so this stays quiet whenever one arrived with the turn.
    private func turnEnded() {
        if stoppedByUser {
            stoppedByUser = false
        } else if store.jobs[stickerID]?.isFailed == true {
            Haptics.failure()
        } else if candidate == nil {
            Haptics.tap(.soft)
        }
    }

    private func acceptCandidate(_ revision: StickerRevision) async {
        isDeciding = true
        defer { isDeciding = false }
        do {
            try await store.transition(stickerID: stickerID, revisionID: revision.id, action: .accept)
            exportModel.invalidateExports()
            Haptics.success()
            localError = nil
            localHint = detail?.kind == .animated && !revision.containsMotion
                // Nothing to navigate to any more — say what to do next, right where they type it.
                ? "Accepted. Describe how it should move to add motion before exporting."
                : nil
        } catch {
            localError = error.localizedDescription
            Haptics.failure()
        }
    }

    private func rejectCandidate(_ revision: StickerRevision) async {
        isDeciding = true
        defer { isDeciding = false }
        // The decision is made the moment they tap, so the sheet leaves and the banner goes with
        // it — not a round trip later, when the reloaded detail happens to drop the candidate.
        rejectedRevisionIDs.insert(revision.id)
        showingCandidate = false
        do {
            try await store.transition(stickerID: stickerID, revisionID: revision.id, action: .reject)
            // Deliberately not a `success`: the decision went through, but throwing work away is
            // not the note to end on.
            Haptics.tap(.medium)
            localError = nil
        } catch {
            // It is still a candidate, so put the banner back rather than stranding a decision the
            // user can no longer reach.
            rejectedRevisionIDs.remove(revision.id)
            localError = error.localizedDescription
            Haptics.failure()
        }
    }

    private func confirmPlan(_ record: PlanRecord) async {
        isConfirmingPlan = true
        defer { isConfirmingPlan = false }
        do {
            try await store.confirmPlan(stickerID: stickerID, planID: record.id)
            localError = nil
        } catch {
            localError = error.localizedDescription
            Haptics.failure()
        }
    }

    private func rejectPlan(_ record: PlanRecord, reason: String?) async {
        do {
            try await store.cancelPlan(stickerID: stickerID, planID: record.id, reason: reason)
            localError = nil
        } catch {
            localError = error.localizedDescription
            Haptics.failure()
        }
    }

    private func retryFailedTurn() async {
        guard !isRetrying else { return }
        isRetrying = true
        defer { isRetrying = false }
        do {
            try await store.retryFailedMessage(stickerID: stickerID)
            localError = nil
        } catch {
            localError = error.localizedDescription
            Haptics.failure()
        }
    }

    private func stop() async {
        do {
            try await store.stopGeneration(stickerID: stickerID)
            localError = nil
        } catch {
            // The turn is still running, so the beat that ends it is still worth feeling.
            stoppedByUser = false
            localError = error.localizedDescription
            Haptics.failure()
        }
    }
}

private struct ChatBubble: View {
    let message: ChatMessage
    let sticker: AnimatedDocument?
    let assets: [String: UIImage]
    let onOpenSticker: (AnimatedDocument) -> Void

    @ViewBuilder
    var body: some View {
        if message.role == .system && message.kind == .status {
            ToolCallRow(message: message)
        } else if message.role == .user {
            HStack {
                Spacer(minLength: 44)
                messageContent
                    .padding(12)
                    .background(AppColors.accentSoft.opacity(0.65), in: .rect(cornerRadius: 18))
            }
            .accessibilityLabel("user: \(message.content)")
        } else {
            HStack {
                messageContent
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                Spacer(minLength: 44)
            }
            .accessibilityLabel("assistant: \(message.content)")
        }
    }

    private var messageContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !message.content.isEmpty {
                // Assistant prose is written as Markdown; what the user typed is taken literally,
                // so an underscore in their own words never turns into italics behind their back.
                if message.role == .user {
                    Text(message.content)
                } else {
                    MarkdownText(markdown: message.content)
                }
            }

            if !message.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(message.attachments) { attachment in
                            ChatAttachmentThumbnail(attachment: attachment, image: assets[attachment.assetId])
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.never)
            }

            if let sticker {
                Button { onOpenSticker(sticker) } label: {
                    StickerAttachment(document: sticker, assets: assets)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("show-sticker-attachment")
            }
        }
    }
}

/// Placeholder bubbles for a transcript that has not arrived yet.
///
/// Laid out like the real thing — alternating sides, uneven widths, one tall row where a sticker
/// will land — so the transcript settles into place instead of appearing out of a blank screen.
/// The pulse is staggered per row, which reads as loading rather than as a control.
private struct TranscriptSkeleton: View {
    @State private var animate = false

    private struct Row: Identifiable {
        let id: Int
        let isUser: Bool
        let widthFraction: CGFloat
        let height: CGFloat
    }

    private static let rows: [Row] = [
        .init(id: 0, isUser: true, widthFraction: 0.52, height: 40),
        .init(id: 1, isUser: false, widthFraction: 0.78, height: 58),
        .init(id: 2, isUser: false, widthFraction: 0.62, height: 190),
        .init(id: 3, isUser: true, widthFraction: 0.40, height: 40),
        .init(id: 4, isUser: false, widthFraction: 0.72, height: 58),
    ]

    var body: some View {
        VStack(spacing: 12) {
            ForEach(Self.rows) { row in
                HStack(spacing: 0) {
                    if row.isUser { Spacer(minLength: 44) }
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.secondary.opacity(animate ? 0.22 : 0.07))
                        .frame(height: row.height)
                        .containerRelativeFrame(.horizontal) { width, _ in width * row.widthFraction }
                        .animation(
                            .easeInOut(duration: 0.9)
                                .repeatForever(autoreverses: true)
                                .delay(Double(row.id) * 0.12),
                            value: animate
                        )
                    if !row.isUser { Spacer(minLength: 44) }
                }
            }
        }
        .padding(.horizontal, 16)
        .onAppear { animate = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading conversation")
        .accessibilityIdentifier("transcript-loading")
    }
}

/// A break in the transcript for something that happened to the sticker rather than something
/// anyone said — an edit saved in the editor. Centred and ruled on both sides so it reads as a
/// timeline marker at a glance, and never as a bubble waiting for a reply.
private struct TranscriptDivider: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            rule
            Label(text, systemImage: "pencil.and.outline")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
            rule
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
        .accessibilityIdentifier("transcript-divider")
    }

    private var rule: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(height: 1)
    }
}

private struct ToolCallRow: View {
    let message: ChatMessage

    private var color: Color {
        switch message.status {
        case .streaming: .secondary
        case .complete: .green
        case .failed: .red
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 3)
                .padding(.vertical, 6)

            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(color.opacity(0.12)).frame(width: 26, height: 26)
                    switch message.status {
                    case .streaming:
                        ProgressView().controlSize(.small).scaleEffect(0.75)
                    case .complete:
                        Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(color)
                    case .failed:
                        Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(color)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(message.content)
                        .font(.caption.weight(.semibold).monospaced())
                    if message.status == .streaming {
                        Text("Running…").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
        }
        .frame(maxWidth: 460, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.25), lineWidth: 0.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Tool \(message.content), \(message.status.rawValue)")
    }
}

private struct AssistantTypingIndicator: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: 7, height: 7)
                    .scaleEffect(animate ? 1 : 0.5)
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animate
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 16))
        .onAppear { animate = true }
        .accessibilityLabel("Sticker Factory is responding")
    }
}

private struct ChatAttachmentThumbnail: View {
    let attachment: ChatAttachment
    let image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: attachment.kind == .mask ? "circle.lefthalf.filled" : "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 82, height: 82)
        .background(.black.opacity(0.05))
        .clipShape(.rect(cornerRadius: 14))
        .accessibilityLabel(attachment.kind == .mask ? "Mask attachment" : "Reference image attachment")
    }
}

private struct StickerAttachment: View {
    let document: AnimatedDocument
    let assets: [String: UIImage]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.04))
            Canvas { context, size in
                let cell = size.width / 12
                for row in 0..<12 {
                    for column in 0..<12 where (row + column).isMultiple(of: 2) {
                        context.fill(
                            Path(CGRect(x: Double(column) * cell, y: Double(row) * cell, width: cell, height: cell)),
                            with: .color(.secondary.opacity(0.055))
                        )
                    }
                }
            }
            .clipShape(.rect(cornerRadius: 16))

            StickerPlayer(document: document, assets: assets, repeats: true)
                .padding(10)
        }
        .frame(maxWidth: 240)
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel(document.kind == .animated ? "Animated sticker attachment" : "Sticker attachment")
    }
}

private struct ComposerMediaChip: View {
    let media: PendingMediaAttachment
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            if let image = UIImage(data: media.data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 34, height: 34)
                    .clipShape(.rect(cornerRadius: 8))
            }
            Text(media.filename)
                .font(.caption)
                .lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
            }
            .accessibilityLabel("Remove \(media.filename)")
        }
        .padding(6)
        .glassEffect(.regular, in: .capsule)
    }
}
