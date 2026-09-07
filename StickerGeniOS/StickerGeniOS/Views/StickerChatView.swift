import AnimatedView
import os
import Photos
import PhotosUI
import SwiftUI
import TipKit
import UIKit

struct StickerChatView: View {
    @Bindable var store: StickerStore
    let stickerID: String

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var referenceItems: [PhotosPickerItem] = []
    @State private var references: [PendingMediaAttachment] = []
    @FocusState private var composerFocused: Bool
    /// Identity of the composer's text field. Bumped whenever the draft is written from code, which
    /// rebuilds the field — see `takeComposerDraft`.
    @State private var composerFieldGeneration = 0
    @State private var privacyAccepted = false
    @State private var showingPrivacy = false
    /// The photo waiting for the user to choose a subject in it, when the lift flow is on.
    @State private var pendingLift: PendingLift?
    private let liftTip = LiftSubjectTip()
    @State private var localError: String?
    /// What the sticker-pack publish has to say, floated over the transcript.
    ///
    /// The publish has no card of its own to report into — it makes a *different* sticker, so
    /// nothing in this conversation is about it. It gets a pill over the message list rather than a
    /// line under the composer: the composer belongs to the draft being written, while failures are
    /// presented separately in an alert.
    @State private var packNotice: StickerPackNotice?
    @State private var assetStore = StickerAssetStore()
    @State private var exportModel = StickerExportModel()
    @State private var showingVersions = false
    @State private var showingExport = false
    @State private var showingComparison = false
    @State private var confirmingDelete = false
    @State private var showingRename = false
    @State private var renameTitle = ""
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
    /// Derived from the notice rather than tracked beside it, so the pill and the disabled menu item
    /// can never disagree about whether a publish is still running.
    private var isAddingToStickerPack: Bool { packNotice?.isWorking == true }
    private var stickerTitle: String {
        detail?.title
            ?? store.stickers.first(where: { $0.id == stickerID })?.title
            ?? String(localized: "Sticker")
    }
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
    private var presentedErrorMessage: String? { localError ?? store.errorMessage }
    /// Whether a plan card is live is the server's call: only it knows whether the card is still
    /// showing the current revision of a draft the agent may have rewritten since. Taking the
    /// newest on top of that keeps scrolled-up history inert even if two cards ever both qualify.
    private var actionablePlanID: String? {
        messages.compactMap(\.plan).last(where: \.actionable)?.id
    }
    private var mediaPreloadToken: String {
        let revisionIDs = messages.compactMap(\.revisionId)
        let attachmentIDs = messages.flatMap(\.attachments).map(\.assetId)
        let planReferenceIDs = messages.compactMap(\.plan?.conceptAssetId)
        return (revisionIDs + attachmentIDs + planReferenceIDs).joined(separator: ":")
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

    /// The transcript, minus the phase rows that the navigation bar's title chip now carries.
    ///
    /// Only the phases are taken out. The individual tool calls stay as rows: they are a record of
    /// work the user can scroll back through, and a turn makes several of them, so they were never
    /// something one line of chrome could stand in for.
    ///
    /// Filtered here rather than upstream because everything else — plan lookups, the haptic
    /// signature, the job's own bookkeeping — still wants the whole list.
    private var conversation: [ChatMessage] {
        messages.filter { !($0.role == .system && $0.kind == .status && StickerToolLabel.isPhase($0.content)) }
    }

    /// What the title chip's second line says the app is doing, if anything.
    ///
    /// The newest *streaming* phase row is the live one; a finished row is history and belongs to no
    /// status. Falling back to a generic label while `isComputing` matters because a turn spends its
    /// first moments queued, before any phase has opened a row, and a bar that says nothing for two
    /// seconds after sending reads as the tap having missed.
    private var activeStatus: String? {
        guard isComputing else { return nil }
        let phase = messages.last {
            $0.kind == .status && $0.status == .streaming && StickerToolLabel.isPhase($0.content)
        }
        return phase.map { StickerToolLabel.text(for: $0.content) } ?? String(localized: "Working…")
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
                .overlay(alignment: .top) { stickerPackNotice }
                .animation(.easeInOut(duration: 0.25), value: packNotice)
                bottomBar
            }
        }
        // Still set even though `.principal` draws the bar: this is what names the back button on
        // the screen that pushed us, and what VoiceOver reads for the screen itself.
        .navigationTitle(stickerTitle)
        .navigationBarTitleDisplayMode(.inline)
        // Chat is the whole detail screen; the tab bar would sit under the composer.
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ChatTitleChip(title: stickerTitle, status: activeStatus)
            }
            ToolbarItem(placement: .topBarTrailing) {
                StickerChatActionsMenu(
                    candidate: candidate,
                    activeRevision: activeRevision,
                    isBusy: isDeciding,
                    onAcceptCandidate: { if let candidate { Task { await acceptCandidate(candidate) } } },
                    onRejectCandidate: { if let candidate { Task { await rejectCandidate(candidate) } } },
                    onCompare: { showingComparison = true },
                    onExport: { showingExport = true },
                    onRename: {
                        renameTitle = stickerTitle
                        showingRename = true
                    },
                    onViewVersions: { showingVersions = true },
                    onDelete: { confirmingDelete = true }
                )
            }
        }
        .task {
            await store.loadDetail(stickerID: stickerID)
            await store.loadMessages(stickerID: stickerID)
            if activeRevision != nil {
                StickerOnboardingTips.acceptedRevisionBecameAvailable()
            }
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
        .modifier(ChatErrorAlert(message: presentedErrorMessage) {
            // Leaving either source set would immediately present the same alert again on the next
            // render, so dismissing it consumes both the local and shared error.
            localError = nil
            store.errorMessage = nil
        })
        .subjectLiftSheet(pending: $pendingLift, references: $references, basename: "chat-capture")
        .sheet(isPresented: $showingCandidate) {
            if let candidate {
                CandidateReadySheet(
                    revision: candidate,
                    assets: assetStore.images,
                    videos: assetStore.videos,
                    // `isBusy` covers a decision started from the toolbar menu; the sheet spins its
                    // own buttons for the ones started inside it.
                    isBusy: isDeciding,
                    onAccept: { await acceptCandidate(candidate) },
                    // Comparison is a second sheet: let this one finish leaving before it
                    // arrives, or the presentation lands on a view that is on its way out.
                    onCompare: {
                        Task {
                            try? await Task.sleep(for: .milliseconds(350))
                            showingComparison = true
                        }
                    },
                    onReject: { await rejectCandidate(candidate) }
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
                        title: String(localized: "Nothing to export yet"),
                        message: String(localized: "Accept a candidate first, then export and publish it."),
                        icon: PosterIcon.publish
                    )
                }
            }
        }
        .fullScreenCover(item: $presentedDocument) { presented in
            FullScreenStickerPlayer(
                document: presented.document,
                assets: assetStore.images,
                videos: assetStore.videos,
                // Editing needs a revision to parent the save onto. A bubble whose document came
                // from a live generation stream has none yet, so that one opens view-only.
                editing: presented.revisionID.map {
                    .init(store: store, stickerID: stickerID, revisionID: $0, assetStore: assetStore)
                }
            )
        }
        .stickerRenameAlert(
            store: store,
            stickerID: stickerID,
            currentTitle: stickerTitle,
            isPresented: $showingRename,
            title: $renameTitle
        )
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
        .telemetryScreen("sticker_chat")
    }

    // MARK: - Transcript

    /// The transcript pins the newest user message to the top of the viewport when it is
    /// sent, so the turn being worked on is the thing on screen. The space under the turn
    /// is computed from the live viewport height rather than being a fixed padding, and
    /// the list never scrolls itself afterwards — a reply that outgrows the viewport waits
    /// below the fold until the reader goes there. See `MessageList`.
    private var transcript: some View {
        MessageList(
            messages: conversation,
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
                    ProgressView().controlSize(.small).tint(AppColors.coral)
                    Text("Loading earlier messages…")
                        .posterLabelStyle(10, color: AppColors.muted)
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("loading-older-chat-messages")
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            } else if store.nextMessageBeforeSequence[stickerID] != nil {
                Button {
                    Task { await store.loadOlderMessages(stickerID: stickerID) }
                } label: {
                    Label("Load earlier messages", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.posterSecondaryCompact)
                .frame(maxWidth: .infinity)
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
                PosterSymbol("exclamationmark.triangle.fill")
                    .foregroundStyle(AppColors.coral)
                Text(job.message)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(AppColors.ink)
                Spacer()
                // The retry request itself takes a moment, and until the new job's stream opens
                // nothing else on screen moves — so the button becomes the progress it started.
                if isRetrying {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).tint(AppColors.coral)
                        Text("Retrying…")
                            .posterLabelStyle(10, color: AppColors.muted)
                    }
                    .accessibilityIdentifier("retrying-failed-generation")
                    .transition(.opacity)
                } else {
                    Button("Retry") {
                        Haptics.tap(.light)
                        Task { await retryFailedTurn() }
                    }
                        .buttonStyle(.posterCompact)
                        .accessibilityIdentifier("retry-failed-generation")
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isRetrying)
            .padding(12)
            .posterSurface(cornerRadius: Poster.tileRadius, offset: Poster.smallShadow)
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
                            StickerAttachment(document: document, assets: assetStore.images, videos: assetStore.videos)
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
                referenceImage: record.conceptAssetId.flatMap { assetStore.images[$0] },
                isBusy: isConfirmingPlan || isComputing,
                onConfirm: { Task { await confirmPlan(record) } },
                onReject: { reason in Task { await rejectPlan(record, reason: reason) } },
                isAddingImageToStickerPack: isAddingToStickerPack,
                onAddImageToStickerPack: { image in
                    Task { await addPlanImageToStickerPack(image) }
                },
                onSaveImageToPhotoLibrary: { image in
                    Task { await savePlanImageToPhotoLibrary(image) }
                }
            )
        } else {
            ChatBubble(
                message: message,
                sticker: revisionDocument(for: message),
                assets: assetStore.images,
                videos: assetStore.videos,
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
                PosterSymbol("antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(AppColors.coral)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lost the live connection")
                        .font(.posterDisplay(14, weight: .bold))
                        .foregroundStyle(AppColors.ink)
                    Text(message)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(AppColors.muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button("Reconnect") { store.reattach(stickerID: stickerID) }
                    .buttonStyle(.posterCompact)
                    .accessibilityIdentifier("reconnect-stream")
                Button {
                    store.dismissStreamError(stickerID: stickerID)
                } label: {
                    PosterSymbol("xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppColors.muted)
                .accessibilityLabel("Dismiss connection warning")
            }
            .padding(12)
            .posterSurface(cornerRadius: Poster.tileRadius, offset: Poster.smallShadow)
            .accessibilityIdentifier("stream-error-banner")
        }
    }

    /// Only one chip may carry the tip: a popover on each of eight references at once would stack
    /// them on the same spot. The first photo that has not been lifted yet is the one the tip is
    /// about, so a row of finished cut-outs asks nothing.
    private var liftTipTarget: UUID? {
        guard AppConfiguration.subjectLiftEnabled else { return nil }
        return references.first { $0.sequence == nil }?.id
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !references.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(references) { reference in
                            ComposerMediaChip(
                                media: reference,
                                lift: AppConfiguration.subjectLiftEnabled ? {
                                    // Invalidated here rather than in the chip so opening a lift
                                    // from any photo retires the tip, not only from the one
                                    // showing it.
                                    liftTip.invalidate(reason: .actionPerformed)
                                    Haptics.tap(.light)
                                    Task { pendingLift = await SubjectLiftPresenter.lift(from: reference) }
                                } : nil,
                                tip: reference.id == liftTipTarget ? liftTip : nil,
                                remove: {
                                    Haptics.selection()
                                    references.removeAll { $0.id == reference.id }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.never)
            }

            HStack(alignment: .center, spacing: 10) {
                Menu {
                    if privacyAccepted {
                        PhotosPicker(
                            selection: $referenceItems,
                            maxSelectionCount: 8,
                            // Live Photos only when the lift flow is on; otherwise nothing could
                            // use the motion and picking one would behave exactly like a still.
                            matching: AppConfiguration.subjectLiftEnabled
                                ? .any(of: [.images, .livePhotos])
                                : .images,
                            preferredItemEncoding: .compatible
                        ) {
                            PosterMenuLabel("Photo Library", icon: .photo)
                        }
                    } else {
                        Button("Add photos") { showingPrivacy = true }
                    }
                } label: {
                    PosterSymbol("plus")
                        .font(.system(size: 17, weight: .black))
                        .frame(width: 32, height: 32)
                        .posterSurface(
                            cornerRadius: 16,
                            fill: AppColors.lime,
                            lineWidth: Poster.hairline,
                            offset: .zero
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppColors.ink)
                .accessibilityLabel("Add photos")
                .accessibilityIdentifier("add-chat-attachment")

                TextField(
                    String(localized: "Message \(AppConfiguration.defaultAppName)"),
                    text: $text,
                    axis: .vertical
                )
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .focused($composerFocused)
                    .id(composerFieldGeneration)
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
                    // Stop is drawn larger than send. It is the only control here with a clock on
                    // it — the turn is already spending — and at send's size it was a small target
                    // to find in a hurry, next to a text field that wants the same thumb.
                    PosterSymbol(isComputing ? "stop.fill" : "arrow.up")
                        .font(.system(size: isComputing ? 15 : 17, weight: .black))
                        .foregroundStyle(canSend || isComputing ? AppColors.card : AppColors.faint)
                        .frame(width: 34, height: 34)
                        .posterSurface(
                            cornerRadius: 17,
                            fill: isComputing
                                ? AppColors.coral
                                : (canSend ? AppColors.ink : AppColors.paper),
                            stroke: canSend || isComputing ? AppColors.ink : AppColors.faint,
                            lineWidth: Poster.hairline,
                            offset: .zero
                        )
                        // Fixed so the composer does not resize as the glyph swaps, and so the
                        // smaller send state still gets a target the size of the larger one.
                        .frame(width: 34, height: 34)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(isComputing ? store.stoppingStickerIDs.contains(stickerID) : !canSend)
                .accessibilityLabel(isComputing ? "Stop" : "Send")
                .accessibilityIdentifier(isComputing ? "stop-streaming" : "send-chat-message")
            }
            .padding(12)
            .posterSurface(cornerRadius: Poster.cardRadius, offset: CGSize(width: 4, height: 4))
        }
        // The composer floats over the transcript, so it keeps its shadow clear of the screen edge.
        .padding(.trailing, 4)
    }

    /// The sticker-pack publish, reported over the top of the transcript.
    ///
    /// It floats rather than taking layout: the transcript is what the user is reading, and pushing
    /// it down to make room would move the message they are looking at. The pill is the same glass
    /// the composer wears, so it reads as chrome over the conversation rather than as part of it.
    @ViewBuilder
    private var stickerPackNotice: some View {
        if let notice = packNotice {
            HStack(spacing: 10) {
                if notice.isWorking {
                    ProgressView().controlSize(.small).tint(AppColors.ink)
                } else {
                    PosterSymbol("checkmark.circle.fill")
                        .foregroundStyle(AppColors.ink)
                }
                Text(notice.message)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppColors.ink)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .posterCapsule(fill: notice.isWorking ? AppColors.card : AppColors.mint)
            .padding(.top, 8)
            .padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityIdentifier("sticker-pack-notice")
            // A finished notice is news for a moment and clutter after it, over a transcript it is
            // covering. The working one stays: it is the only sign the work is still going.
            .task(id: notice) {
                guard !notice.isWorking else { return }
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                packNotice = nil
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
            if let plan = message.plan, plan.plan.kind == .animated, plan.actionable {
                // A plan card's confirm button waits on this image, so a card that never becomes
                // tappable is either a plan with no concept to load — capture-led plans have none —
                // or an asset fetch that failed, and the two look identical on screen.
                StickerAssetStore.log.debug(
                    """
                    plan-reference: plan=\(plan.id, privacy: .public) \
                    concept=\(plan.conceptAssetId ?? "none", privacy: .public) \
                    generated=\(plan.generationCount) \
                    loaded=\(plan.conceptAssetId.map { assetStore.images[$0] != nil } ?? false)
                    """
                )
            }
            if let referenceID = message.plan?.conceptAssetId {
                await assetStore.load(assetID: referenceID, api: store.api)
            }
            for attachment in message.attachments {
                await assetStore.load(assetID: attachment.assetId, api: store.api)
            }
            if let document = revisionDocument(for: message) {
                await assetStore.preload(document: document, api: store.api)
            }
        }
    }

    /// Picking a photo attaches it, exactly as in `CreateStickerView.loadReferences`.
    ///
    /// Kept as two small copies rather than one shared helper because the two composers hold their
    /// drafts differently, and the only part genuinely worth sharing — the pipeline — already is.
    private func loadReferences(_ items: [PhotosPickerItem]) async {
        // Emptied immediately, and never read as the source of truth again. A picker's `selection`
        // binding remembers everything ever chosen, so leaving items in it means a photo the user
        // later removed is still "selected" — and the next pick re-delivers it and it reappears,
        // which is exactly what made deletions look like they had not taken. Clearing it re-enters
        // this method with an empty array, which the guard drops.
        guard !items.isEmpty else { return }
        referenceItems = []

        var loaded: [PendingMediaAttachment] = []
        for (index, item) in items.prefix(max(0, 8 - references.count)).enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            do {
                var attachment = try MediaNormalizer.reference(
                    data: data,
                    basename: "chat-reference-\(references.count + index)"
                )
                attachment.source = item
                loaded.append(attachment)
            } catch {
                localError = error.localizedDescription
            }
        }
        references.append(contentsOf: loaded)
        if !loaded.isEmpty { Haptics.selection() }
    }

    /// Publishes a plan's visual into the sticker pack, so it can be sent from Messages.
    ///
    /// This is the whole point of the action and not a shortcut to it: Messages reads the published
    /// library, so the image becomes its own static sticker project and is exported the same way any
    /// finished sticker is. Nothing is generated, so it costs the user no model time — but it does
    /// cost a render and two uploads, which is why the menu item reports that it is working rather
    /// than looking like it did nothing.
    private func addPlanImageToStickerPack(_ image: UIImage) async {
        guard !isAddingToStickerPack else { return }
        localError = nil
        packNotice = .init(message: String(localized: "Adding to your stickers…"), isWorking: true)
        do {
            try await store.addImageToStickerPack(image, title: stickerTitle)
            packNotice = .init(
                message: String(localized: "Added to your stickers. It's ready in Messages."),
                isWorking: false
            )
            Haptics.success()
        } catch {
            // The pill only ever says the work is going or went well; a failure belongs in the error
            // line, which is where every other thing that can go wrong on this screen reports.
            packNotice = nil
            guard !StickerStore.isCancellation(error) else { return }
            localError = error.localizedDescription
            Haptics.failure()
        }
    }

    /// Saves only the image the user long-pressed. Add-only authorization avoids asking to browse
    /// the rest of the library for an operation that never reads it.
    private func savePlanImageToPhotoLibrary(_ image: UIImage) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            localError = String(localized: "Allow photo-library access in Settings to save this image.")
            Haptics.failure()
            return
        }
        do {
            try await Self.addToPhotoLibrary(image)
            localError = nil
            Haptics.success()
        } catch {
            localError = error.localizedDescription
            Haptics.failure()
        }
    }

    /// Photos runs the change block on a thread of its own choosing. This file is main-actor by
    /// default, so a block written inline above would be inferred `@MainActor` and trap the moment
    /// Photos called it off the main thread; `nonisolated` leaves it with no actor to check.
    private nonisolated static func addToPhotoLibrary(_ image: UIImage) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }

    /// One line about the sticker-pack publish, and whether it is still going.
    ///
    /// `isWorking` is carried rather than inferred from the wording: it decides the spinner, whether
    /// the notice dismisses itself, and whether the menu item is still disabled — three things that
    /// must not be re-derived from a localized string.
    private struct StickerPackNotice: Equatable {
        var message: String
        var isWorking: Bool
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
        rebuildComposerField()
        return draft
    }

    /// Replaces the text field with a fresh one carrying the current `text`.
    ///
    /// A `.vertical` axis text field keeps drawing what the user typed when its binding is written
    /// from code while it holds the keyboard — the field owns the editing session, and it does not
    /// re-read the binding on the way through. So emptying `text` is not enough to empty the
    /// composer: the field it is showing has to be a new one. Focus is handed back afterwards,
    /// because the field taking the keyboard with it is the whole reason this is not free.
    private func rebuildComposerField() {
        guard composerFocused else {
            composerFieldGeneration &+= 1
            return
        }
        composerFieldGeneration &+= 1
        // The replacement does not exist until this update has been applied, so it can only be
        // focused on the next one — soon enough that the keyboard never leaves.
        Task { @MainActor in composerFocused = true }
    }

    private func send(_ draft: ComposerDraft) async {
        let submittedText = draft.text
        let submittedReferenceItems = draft.referenceItems
        let submittedReferences = draft.references
        let value = submittedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = value.isEmpty ? String(localized: "Use these reference images for the sticker.") : value
        let baseRevisionID = detail?.revisions.first(where: { $0.state == .candidate })?.id ?? detail?.activeRevisionId

        localError = nil
        // A settled pack notice is older news than the turn about to start; one still working keeps
        // its pill, because the work is still going whatever this screen does next.
        if packNotice?.isWorking == false { packNotice = nil }

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
                // Same reason as the send: a field holding the keyboard shows what it was given
                // last, not what the binding says, so putting the draft back needs a new field.
                rebuildComposerField()
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

    /// Returns whether the decision landed, so the sheet knows whether to keep its spinner up or
    /// step aside for the error alert.
    @discardableResult
    private func acceptCandidate(_ revision: StickerRevision) async -> Bool {
        Haptics.tap(.light)
        isDeciding = true
        defer { isDeciding = false }
        do {
            try await store.transition(stickerID: stickerID, revisionID: revision.id, action: .accept)
            StickerOnboardingTips.acceptedRevisionBecameAvailable()
            exportModel.invalidateExports()
            Haptics.success()
            localError = nil
            return true
        } catch {
            localError = error.localizedDescription
            Haptics.failure()
            return false
        }
    }

    @discardableResult
    private func rejectCandidate(_ revision: StickerRevision) async -> Bool {
        Haptics.tap(.light)
        isDeciding = true
        defer { isDeciding = false }
        do {
            try await store.transition(stickerID: stickerID, revisionID: revision.id, action: .reject)
            // The banner and the sheet only leave once the decision has landed; until then the
            // spinner on the tapped button is what says the tap registered. Hidden from here
            // rather than a reload later, when the refreshed detail happens to drop the candidate.
            rejectedRevisionIDs.insert(revision.id)
            showingCandidate = false
            // Deliberately not a `success`: the decision went through, but throwing work away is
            // not the note to end on.
            Haptics.tap(.medium)
            localError = nil
            return true
        } catch {
            localError = error.localizedDescription
            Haptics.failure()
            return false
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

private struct ChatErrorAlert: ViewModifier {
    let message: String?
    let onDismiss: () -> Void

    private var isPresented: Binding<Bool> {
        Binding(
            get: { message != nil },
            set: { if !$0 { onDismiss() } }
        )
    }

    func body(content: Content) -> some View {
        content.alert("Couldn’t Complete Action", isPresented: isPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }
}

private struct ChatBubble: View {
    let message: ChatMessage
    let sticker: AnimatedDocument?
    let assets: [String: UIImage]
    var videos: [String: KeyedVideoFrames] = [:]
    let onOpenSticker: (AnimatedDocument) -> Void

    @ViewBuilder
    var body: some View {
        if message.role == .system && message.kind == .status {
            // Phase rows never reach here — `conversation` filters those out and the title chip
            // shows the live one. What is left is the model's own tool calls.
            ToolCallRow(message: message)
        } else if message.role == .user {
            HStack {
                Spacer(minLength: 44)
                messageContent
                    .foregroundStyle(AppColors.ink)
                    .padding(12)
                    .posterSurface(
                        cornerRadius: Poster.tileRadius,
                        fill: AppColors.accentSoft,
                        lineWidth: Poster.hairline,
                        offset: Poster.smallShadow
                    )
                    // Room for the bubble's own shadow, which is drawn outside its box.
                    .padding(.trailing, Poster.smallShadow.width)
                    .padding(.bottom, Poster.smallShadow.height)
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
                    StickerAttachment(document: sticker, assets: assets, videos: videos)
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
                    RoundedRectangle(cornerRadius: Poster.tileRadius, style: .continuous)
                        .fill(AppColors.ink.opacity(animate ? 0.14 : 0.05))
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
            PosterSymbolLabel(verbatim: text, posterSymbol: "pencil.and.outline")
                .posterLabelStyle(9, color: AppColors.ink)
                .lineLimit(1)
                .layoutPriority(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .posterCapsule(fill: AppColors.highlight, lineWidth: 1, offset: .zero)
            rule
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
        .accessibilityIdentifier("transcript-divider")
    }

    private var rule: some View {
        Rectangle()
            .fill(AppColors.line)
            .frame(height: 1.5)
    }
}

private struct ToolCallRow: View {
    let message: ChatMessage
    @State private var showingDetails = false

    private var color: Color {
        switch message.status {
        case .streaming: AppColors.sky
        case .complete: AppColors.mint
        case .failed: AppColors.coral
        }
    }

    var body: some View {
        Button {
            Haptics.tap(.light)
            showingDetails = true
        } label: {
            chip
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Tool \(message.content), \(message.status.label)")
        .accessibilityHint("Shows the tool result or error")
        .sheet(isPresented: $showingDetails) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(message.content).font(.headline)
                        Label(message.status.label, systemImage: message.status == .failed ? "exclamationmark.circle" : "info.circle")
                            .foregroundStyle(AppColors.muted)
                        Text(message.toolDetails ?? fallbackDetails)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding()
                }
                .background(AppColors.paper)
                .navigationTitle(message.status == .failed ? "Tool Error" : "Tool Result")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingDetails = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var fallbackDetails: String {
        switch message.status {
        case .streaming: String(localized: "This tool is still running. Its result will appear here when available.")
        case .complete: String(localized: "This tool completed. No result details were recorded.")
        case .failed: String(localized: "This tool failed. No error details were recorded.")
        }
    }

    private var chip: some View {
        HStack(spacing: 0) {
            UnevenRoundedRectangle(
                topLeadingRadius: Poster.chipRadius - 2,
                bottomLeadingRadius: Poster.chipRadius - 2,
                style: .continuous
            )
            .fill(color)
            .frame(width: 8)

            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(color)
                        .overlay(Circle().strokeBorder(AppColors.ink, lineWidth: 1.5))
                        .frame(width: 26, height: 26)
                    switch message.status {
                    case .streaming:
                        ProgressView().controlSize(.small).scaleEffect(0.7).tint(AppColors.ink)
                    case .complete:
                        PosterSymbol("checkmark").font(.caption.weight(.black)).foregroundStyle(AppColors.ink)
                    case .failed:
                        PosterSymbol("xmark").font(.caption.weight(.black)).foregroundStyle(AppColors.card)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(message.content)
                        .font(.caption.weight(.bold).monospaced())
                        .foregroundStyle(AppColors.ink)
                    if message.status == .streaming {
                        Text("Running…").posterLabelStyle(9, color: AppColors.muted)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
        }
        .frame(maxWidth: 460, alignment: .leading)
        .posterSurface(cornerRadius: Poster.chipRadius, lineWidth: Poster.hairline, offset: CGSize(width: 2, height: 2))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Tool \(message.content), \(message.status.label)")
    }
}

private struct AssistantTypingIndicator: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(AppColors.coral)
                    .frame(width: 8, height: 8)
                    .scaleEffect(animate ? 1 : 0.5)
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animate
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .posterCapsule(offset: Poster.smallShadow)
        .onAppear { animate = true }
        .accessibilityLabel(
            String(localized: "\(AppConfiguration.defaultAppName) is responding")
        )
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
                PosterSymbol(attachment.kind == .mask ? "circle.lefthalf.filled" : "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 82, height: 82)
        .clipShape(.rect(cornerRadius: 14, style: .continuous))
        .posterSurface(
            cornerRadius: 14,
            fill: AppColors.paper,
            lineWidth: Poster.hairline,
            offset: CGSize(width: 2, height: 2)
        )
        .accessibilityLabel(attachment.kind == .mask ? "Mask attachment" : "Reference image attachment")
    }
}

private struct StickerAttachment: View {
    let document: AnimatedDocument
    let assets: [String: UIImage]
    var videos: [String: KeyedVideoFrames] = [:]

    var body: some View {
        ZStack {
            // A checkerboard says "this artwork is transparent". Drawn in paper and ink so it
            // belongs to the same printed surface as everything around it.
            Canvas { context, size in
                let cell = size.width / 12
                for row in 0..<12 {
                    for column in 0..<12 where (row + column).isMultiple(of: 2) {
                        context.fill(
                            Path(CGRect(x: Double(column) * cell, y: Double(row) * cell, width: cell, height: cell)),
                            with: .color(AppColors.ink.opacity(0.05))
                        )
                    }
                }
            }
            .clipShape(.rect(cornerRadius: Poster.tileRadius, style: .continuous))

            StickerPlayer(document: document, assets: assets, videos: videos, repeats: true)
                .padding(10)
        }
        // Square first, then capped: a list row proposes no height, and `aspectRatio` fills a
        // missing dimension from the other one. Capping the width before the ratio is applied
        // keeps the tile at most 240 tall; capping it after let the ratio see the row's full
        // width first, which on iPad reserved a screen-tall column for a 240pt sticker.
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 240)
        .posterSurface(cornerRadius: Poster.tileRadius, fill: AppColors.paper, offset: Poster.smallShadow)
        .padding(.trailing, Poster.smallShadow.width)
        .padding(.bottom, Poster.smallShadow.height)
        .accessibilityLabel(document.kind == .animated ? "Animated sticker attachment" : "Sticker attachment")
    }
}

private struct ComposerMediaChip: View {
    let media: PendingMediaAttachment
    /// Tapping the thumbnail reopens the lift flow on it. Nil hides the affordance entirely.
    var lift: (() -> Void)?
    /// Set on the one chip that should explain the tap. Nil on every other.
    var tip: LiftSubjectTip?
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Button {
                lift?()
            } label: {
                if let image = UIImage(data: media.data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 34, height: 34)
                        .clipShape(.rect(cornerRadius: 8))
                        .overlay(alignment: .bottomTrailing) {
                            // A capture is already cut out, so its thumbnail is mostly transparent
                            // and reads as a failed load without a badge. A plain reference gets one
                            // too, because nothing else says that tapping it lifts a subject.
                            if lift != nil {
                                PosterSymbol(media.sequence != nil ? "livephoto" : "person.and.background.dotted")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(2)
                                    .background(AppColors.card, in: Circle())
                                    .overlay(Circle().strokeBorder(AppColors.ink, lineWidth: 1))
                            }
                        }
                }
            }
            .buttonStyle(.plain)
            .disabled(lift == nil)
            // The chips sit directly above the keyboard, so the popover has to open upward.
            .popoverTip(tip, arrowEdge: .bottom)
            .accessibilityLabel(media.sequence != nil
                ? "Lifted subject. Tap to choose a different one."
                : "Reference photo. Tap to lift a subject out of it.")

            Text(media.filename)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(AppColors.ink)
                .lineLimit(1)
            Button(action: remove) {
                PosterSymbol("xmark.circle.fill")
                    .foregroundStyle(AppColors.ink)
            }
            .accessibilityLabel("Remove \(media.filename)")
        }
        .padding(6)
        .padding(.trailing, 4)
        .posterCapsule(offset: CGSize(width: 2, height: 2))
    }
}
