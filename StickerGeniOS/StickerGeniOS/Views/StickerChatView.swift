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
    @State private var presentedDocument: PresentedStickerDocument?
    /// Measured, not fixed: the bar grows with reference chips, a multi-line draft and the
    /// candidate banner, and the transcript has to keep exactly that much room free under it.
    @State private var bottomBarHeight: CGFloat = 0

    private var detail: StickerDetail? { store.details[stickerID] }
    private var candidate: StickerRevision? { detail?.revisions.first { $0.state == .candidate } }
    private var activeRevision: StickerRevision? { detail?.activeRevision }
    private var messages: [ChatMessage] { store.messages[stickerID] ?? [] }
    private var isComputing: Bool { store.computingStickerIDs.contains(stickerID) }
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
                transcript
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
        .onChange(of: candidate?.id) { _, newValue in
            if newValue == nil { showingCandidate = false }
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
                Task { if await store.delete(stickerID: stickerID) { dismiss() } }
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
            if store.nextMessageBeforeSequence[stickerID] != nil {
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
                Button("Retry") { Task { await retryFailedTurn() } }
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("retry-failed-generation")
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func transcriptRow(_ message: ChatMessage) -> some View {
        if let record = message.plan {
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
                onOpenSticker: { presentedDocument = .init(document: $0, revisionID: message.revisionId) }
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
                CandidateReadyBanner(isBusy: isDeciding) { showingCandidate = true }
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
                .foregroundStyle(.purple)
                .accessibilityLabel("Add photos")
                .accessibilityIdentifier("add-chat-attachment")

                TextField("Message Sticker Factory", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("chat-composer")

                Button {
                    Task {
                        if isComputing { await stop() }
                        else { await send() }
                    }
                } label: {
                    Image(systemName: isComputing ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(isComputing ? .red : .purple)
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

    private func revisionDocument(for message: ChatMessage) -> AnimatedDocument? {
        guard message.role == .assistant, let revisionID = message.revisionId else { return nil }
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
    }

    private func send() async {
        let submittedText = text
        let submittedReferenceItems = referenceItems
        let submittedReferences = references
        let value = submittedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = value.isEmpty ? "Use these reference images for the sticker." : value
        let baseRevisionID = detail?.revisions.first(where: { $0.state == .candidate })?.id ?? detail?.activeRevisionId

        text = ""
        referenceItems = []
        references = []
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
        }
    }

    private func acceptCandidate(_ revision: StickerRevision) async {
        isDeciding = true
        defer { isDeciding = false }
        do {
            try await store.transition(stickerID: stickerID, revisionID: revision.id, action: .accept)
            exportModel.invalidateExports()
            localError = nil
            localHint = detail?.kind == .animated && !revision.containsMotion
                // Nothing to navigate to any more — say what to do next, right where they type it.
                ? "Accepted. Describe how it should move to add motion before exporting."
                : nil
        } catch { localError = error.localizedDescription }
    }

    private func rejectCandidate(_ revision: StickerRevision) async {
        isDeciding = true
        defer { isDeciding = false }
        do {
            try await store.transition(stickerID: stickerID, revisionID: revision.id, action: .reject)
            localError = nil
        } catch { localError = error.localizedDescription }
    }

    private func confirmPlan(_ record: PlanRecord) async {
        isConfirmingPlan = true
        defer { isConfirmingPlan = false }
        do {
            try await store.confirmPlan(stickerID: stickerID, planID: record.id)
            localError = nil
        } catch { localError = error.localizedDescription }
    }

    private func rejectPlan(_ record: PlanRecord, reason: String?) async {
        do {
            try await store.cancelPlan(stickerID: stickerID, planID: record.id, reason: reason)
            localError = nil
        } catch { localError = error.localizedDescription }
    }

    private func retryFailedTurn() async {
        do {
            try await store.retryFailedMessage(stickerID: stickerID)
            localError = nil
        } catch { localError = error.localizedDescription }
    }

    private func stop() async {
        do {
            try await store.stopGeneration(stickerID: stickerID)
            localError = nil
        } catch { localError = error.localizedDescription }
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
                    .background(Color.purple.opacity(0.18), in: .rect(cornerRadius: 18))
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
            if !message.content.isEmpty { Text(message.content) }

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
