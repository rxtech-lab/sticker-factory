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
    @State var text = ""
    @State var referenceItems: [PhotosPickerItem] = []
    @State var references: [PendingMediaAttachment] = []
    @FocusState var composerFocused: Bool
    /// Identity of the composer's text field. Bumped whenever the draft is written from code, which
    /// rebuilds the field — see `takeComposerDraft`.
    @State var composerFieldGeneration = 0
    @State private var privacyAccepted = false
    @State private var showingPrivacy = false
    /// The photo waiting for the user to choose a subject in it, when the lift flow is on.
    @State private var pendingLift: PendingLift?
    private let liftTip = LiftSubjectTip()
    @State var localError: String?
    /// What the sticker-pack publish has to say, floated over the transcript.
    ///
    /// The publish has no card of its own to report into — it makes a *different* sticker, so
    /// nothing in this conversation is about it. It gets a pill over the message list rather than a
    /// line under the composer: the composer belongs to the draft being written, while failures are
    /// presented separately in an alert.
    @State var packNotice: StickerPackNotice?
    @State var assetStore = StickerAssetStore()
    @State var exportModel = StickerExportModel()
    @State private var showingVersions = false
    @State private var showingExport = false
    @State private var showingComparison = false
    @State private var confirmingDelete = false
    @State private var showingRename = false
    @State private var renameTitle = ""
    @State var showingCandidate = false
    @State var isDeciding = false
    @State var isConfirmingPlan = false
    /// A retry is in flight. Held here rather than read off the job, because the job only stops
    /// looking failed once the replacement stream opens — well after the tap.
    @State var isRetrying = false
    @State private var presentedDocument: PresentedStickerDocument?
    /// Measured, not fixed: the bar grows with reference chips, a multi-line draft and the
    /// candidate banner, and the transcript has to keep exactly that much room free under it.
    @State private var bottomBarHeight: CGFloat = 0
    @State private var streamHaptics = StreamHaptics()
    /// Set when the user stops the turn themselves. Stopping already answers the tap with its own
    /// beat, and the turn ending is that same action arriving — not news.
    @State var stoppedByUser = false
    /// Whether a turn has streamed while this screen has been open. Gates the candidate haptic:
    /// opening a chat that already had a candidate waiting is not an arrival, and announcing it
    /// with the same buzz as one that just landed would make the buzz mean nothing.
    @State private var hasStreamedTurn = false
    /// Candidates the user has already turned down, hidden from the moment they tap rather than
    /// when the round trip lands. The banner and the sheet are a decision waiting to be made;
    /// leaving either up after it has been made reads as the tap not registering.
    @State var rejectedRevisionIDs: Set<String> = []

    var detail: StickerDetail? { store.details[stickerID] }
    /// Derived from the notice rather than tracked beside it, so the pill and the disabled menu item
    /// can never disagree about whether a publish is still running.
    var isAddingToStickerPack: Bool { packNotice?.isWorking == true }
    var stickerTitle: String {
        detail?.title
            ?? store.stickers.first(where: { $0.id == stickerID })?.title
            ?? String(localized: "Sticker")
    }
    var candidate: StickerRevision? {
        detail?.revisions.first { $0.state == .candidate && !rejectedRevisionIDs.contains($0.id) }
    }
    private var activeRevision: StickerRevision? { detail?.activeRevision }
    var messages: [ChatMessage] { store.messages[stickerID] ?? [] }
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
            Text("""
                Reference images are uploaded privately and \
                become part of this sticker’s persistent chat and revision history until project deletion.
                """)
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

    var composer: some View {
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
}
