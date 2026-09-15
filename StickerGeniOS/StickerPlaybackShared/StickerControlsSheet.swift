import AnimatedView
import SwiftUI

/// Posing a configurable sticker before it is applied — the pickers, the speed, and the motion
/// switch — shared by the app's full-screen player and by the Messages extension.
///
/// It wears the poster design system rather than the stock form it grew out of. This is the one
/// surface the two hosts share, so a plain grey sheet here read as somebody else's app inside both
/// of them: cream paper under the rows, each control standing on its own outlined chip, and an ink
/// track instead of the system's tint.
struct StickerControlsSheet: View {
    /// Two-step sending, for a host that can hand the reader the prepared artwork itself.
    ///
    /// In Messages the point of preparing rather than sending outright is that the result can then
    /// be peeled off the sheet and dropped on a particular bubble. That gesture belongs to
    /// `MSStickerView` and only works where the transcript is on screen, so the host supplies both
    /// the view and the send, and gives the drawer back when the artwork is ready.
    ///
    /// Left `nil` by the app, where there is nothing to drag onto and applying is the whole errand.
    struct PreparedSending {
        /// The host's view of what was prepared. Peelable where the host can make it so.
        var preview: @MainActor () -> AnyView
        var send: @MainActor () async throws -> Void
    }

    /// What the sheet is waiting on, and the word for it. Rendering a pose and handing it to the
    /// conversation are both slow enough to need saying, and they are not the same wait.
    private enum Phase {
        case preparing, sending
        var message: String {
            switch self {
            case .preparing: String(localized: "Preparing…")
            case .sending: String(localized: "Sending…")
            }
        }
    }

    let document: AnimatedDocument
    let stickerID: String
    let accountID: String
    var actionTitle = String(localized: "Apply")
    var loadAssets: @MainActor (AnimatedDocument) async throws -> StickerRenderAssets
    var onApply: @MainActor (StickerControlSettings, AnimatedDocument, StickerRenderAssets) async throws -> Void
    var onClose: () -> Void
    var onExpand: ((StickerControlSettings) -> Void)?
    var onEdit: (() -> Void)?
    var showsPreview: Bool
    var onPreviewChange: ((StickerControlSettings, StickerRenderAssets) -> Void)?
    var preparedSending: PreparedSending?

    @State private var settings: StickerControlSettings
    @State private var assets = StickerRenderAssets()
    @State private var loadedDocument: AnimatedDocument?
    @State private var errorMessage: String?
    @State private var phase: Phase?
    @State private var workTask: Task<Void, Never>?
    @State private var selectedDetent: PresentationDetent = .medium
    /// The settings the host's artwork was prepared from.
    ///
    /// Keeping the whole value rather than a flag is what makes the cache free: posing away from a
    /// prepared sticker and back again lands on the same settings, so it is still prepared and the
    /// send costs nothing. Anything else puts the sheet back into posing, where the host renders
    /// again — from *its* cache when that pose has been rendered before.
    @State private var preparedSettings: StickerControlSettings?

    init(document: AnimatedDocument, stickerID: String, accountID: String, actionTitle: String = String(localized: "Apply"),
         loadAssets: @escaping @MainActor (AnimatedDocument) async throws -> StickerRenderAssets,
         onApply: @escaping @MainActor (StickerControlSettings, AnimatedDocument, StickerRenderAssets) async throws -> Void,
         onClose: @escaping () -> Void, onExpand: ((StickerControlSettings) -> Void)? = nil, onEdit: (() -> Void)? = nil,
         initialSettings: StickerControlSettings? = nil, showsPreview: Bool = true,
         onPreviewChange: ((StickerControlSettings, StickerRenderAssets) -> Void)? = nil,
         preparedSending: PreparedSending? = nil) {
        self.document = document; self.stickerID = stickerID; self.accountID = accountID; self.actionTitle = actionTitle
        self.loadAssets = loadAssets; self.onApply = onApply; self.onClose = onClose; self.onExpand = onExpand; self.onEdit = onEdit
        self.showsPreview = showsPreview; self.onPreviewChange = onPreviewChange; self.preparedSending = preparedSending
        _settings = State(initialValue: initialSettings ?? StickerControlPreferences().load(accountID: accountID, stickerID: stickerID, document: document))
    }
    private var resolved: AnimatedDocument? { try? settings.resolvedDocument(document) }
    private var artworkIsReady: Bool { resolved != nil && loadedDocument == resolved }
    private var busy: Bool { phase != nil }
    /// The host has artwork for exactly the pose now on screen.
    private var isPrepared: Bool { preparedSending != nil && preparedSettings == settings }

    var body: some View {
        NavigationStack {
            StickerBackground {
                ScrollView {
                    Group {
                        if isPrepared, let preparedSending {
                            prepared(preparedSending)
                        } else {
                            posing
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .disabled(busy)
                }
            }
            // Over the sheet rather than after the last row: the work takes long enough that the
            // reader looks for it, and at the bottom of a scroll view it is as likely to be off
            // screen as on it. The scrim is what makes the wait read as blocking — the rows are
            // already disabled underneath, and a dimmed control with no reason given looks broken.
            .overlay {
                if let phase {
                    ZStack {
                        AppColors.ink.opacity(0.16).ignoresSafeArea()
                        PosterProgress(message: phase.message)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: busy)
            .navigationTitle("Sticker Controls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { Haptics.tap(.light); workTask?.cancel(); onClose() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView().controlSize(.small).tint(AppColors.ink)
                    } else if !isPrepared {
                        // Once it is prepared the action moves next to the artwork it sends, where
                        // it sits beside the drag that is the other half of the same choice.
                        Button(actionTitle) { Haptics.tap(.medium); workTask = Task { await prepare() } }
                            .disabled(!artworkIsReady)
                            .accessibilityIdentifier("sticker-controls-apply")
                    }
                }
            }
        }
        // The extension hosts this without `ContentView`'s root modifiers, so the two are set here
        // rather than being inherited: without them the same sheet is rounded ink in the app and
        // system grey-on-blue in Messages.
        .fontDesign(.rounded)
        .tint(AppColors.accent)
        .accessibilityIdentifier("sticker-controls-sheet")
        .presentationDetents([.medium, .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
        // Paper all the way to the sheet's own edges: the system's translucent grey otherwise shows
        // through at the corners and while the detent is being dragged.
        .presentationBackground(AppColors.paper)
        .interactiveDismissDisabled(busy)
        .task(id: resolved) { await refreshAssets() }
        .onChange(of: settings) { _, updated in
            if artworkIsReady { onPreviewChange?(updated, assets) }
        }
        .onDisappear { workTask?.cancel() }
    }

    // MARK: - Posing

    @ViewBuilder private var posing: some View {
        VStack(alignment: .leading, spacing: 18) {
            if showsPreview {
                preview
            } else if !artworkIsReady {
                PosterProgress(message: String(localized: "Loading artwork…"))
            }

            StickerControlRows(document: document, settings: $settings)

            Divider()

            actions

            if let errorMessage {
                ErrorBanner(message: errorMessage)
                Button("Retry loading") { loadedDocument = nil; Task { await refreshAssets() } }
                    .buttonStyle(.posterSecondaryCompact)
            }
        }
    }

    /// The sticker itself, on a card. A sticker is transparent by definition, so it needs a surface
    /// of its own to read as artwork rather than as a hole in the page.
    @ViewBuilder private var preview: some View {
        if let resolved, loadedDocument == resolved {
            Group {
                if settings.animate {
                    AnimatedIconView(document: resolved, assets: assets.dictionary, repeats: true)
                } else {
                    AnimatedIconFrame(document: resolved, time: settings.stillTime(in: resolved), assets: assets.dictionary)
                }
            }
            .frame(height: 155)
            .frame(maxWidth: .infinity)
            .padding(12)
            .posterSurface(cornerRadius: Poster.cardRadius, offset: Poster.smallShadow)
            .padding(.trailing, Poster.smallShadow.width)
            .padding(.bottom, Poster.smallShadow.height)
            .accessibilityIdentifier("sticker-controls-preview")
        } else {
            PosterProgress(message: String(localized: "Loading artwork…"))
                .frame(height: 155)
                .frame(maxWidth: .infinity)
        }
    }

    /// Reset undoes the posing; the other two leave for somewhere that can do more with it. They
    /// wrap onto a second line rather than truncate, which is where larger text sends them.
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                resetButton
                Spacer(minLength: 8)
                expandButton
                editButton
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    expandButton
                    editButton
                    Spacer(minLength: 0)
                }
                resetButton
            }
        }
    }

    private var resetButton: some View {
        Button("Reset") { settings = .defaults(for: document) }
            .buttonStyle(.posterSecondaryCompact)
            .accessibilityIdentifier("sticker-controls-reset")
    }

    @ViewBuilder private var expandButton: some View {
        if let onExpand {
            Button { onExpand(settings) } label: {
                PosterSymbolLabel("Full Screen", posterSymbol: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.posterSecondaryCompact)
            .disabled(!artworkIsReady)
        }
    }

    @ViewBuilder private var editButton: some View {
        if let onEdit {
            Button(action: onEdit) {
                PosterSymbolLabel("Edit", posterSymbol: "slider.horizontal.3")
            }
            .buttonStyle(.posterSecondaryCompact)
        }
    }

    // MARK: - Prepared

    /// The pose is rendered and the sheet gets out of the way of the two things left to do with it.
    ///
    /// Deliberately not the posing screen with a send button added: this is shown in the collapsed
    /// drawer, where there is room for the sticker and one decision and nothing else. Adjust is the
    /// way back, and it is free — the render for these settings is already on disk.
    private func prepared(_ sending: StickerControlsSheet.PreparedSending) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                sending.preview()
                    .frame(width: Self.preparedStickerSide, height: Self.preparedStickerSide)
                    .padding(8)
                    .posterSurface(cornerRadius: Poster.tileRadius, offset: Poster.smallShadow)
                    .padding(.trailing, Poster.smallShadow.width)
                    .padding(.bottom, Poster.smallShadow.height)
                    .accessibilityIdentifier("sticker-controls-prepared")

                VStack(alignment: .leading, spacing: 10) {
                    Text("Press and hold to drag it onto a message, or send it.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(AppColors.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Button("Adjust") { preparedSettings = nil }
                            .buttonStyle(.posterSecondaryCompact)
                            .accessibilityIdentifier("sticker-controls-adjust")
                        Spacer(minLength: 8)
                        Button { workTask = Task { await send(sending) } } label: {
                            PosterSymbolLabel("Send", posterSymbol: "paperplane.fill")
                        }
                        .buttonStyle(.posterCompact)
                        .accessibilityIdentifier("sticker-controls-send")
                    }
                }
            }

            if let errorMessage { ErrorBanner(message: errorMessage) }
        }
    }

    /// Small on purpose. This is shown in the collapsed drawer, which is about a keyboard tall and
    /// has to hold the artwork, the sentence explaining it, and two buttons without the send
    /// falling below the fold — and the sticker is being identified here, not admired.
    private static let preparedStickerSide: CGFloat = 76

    // MARK: - Work

    private func refreshAssets() async {
        guard let target = resolved else { errorMessage = String(localized: "This sticker's controls are invalid."); return }
        do {
            let loaded = try await loadAssets(target)
            try Task.checkCancellation()
            guard target == resolved else { return }
            assets = loaded; loadedDocument = target; errorMessage = nil
            onPreviewChange?(settings, loaded)
        } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
    }

    /// Renders the pose. Where the host sends in one step this is the whole errand and the sheet
    /// closes; where it sends in two, the sheet stays open holding what was made.
    private func prepare() async {
        guard !busy, let resolved, loadedDocument == resolved else { return }
        guard StickerControlPreferences().defaults != nil else { errorMessage = String(localized: "Shared sticker settings are unavailable."); return }
        let posed = settings
        phase = .preparing; errorMessage = nil
        defer { phase = nil }
        do {
            try await onApply(posed, resolved, assets)
            try Task.checkCancellation()
            try StickerControlPreferences().save(posed, accountID: accountID, stickerID: stickerID, document: document)
            // Against the settings the render was made from, not against whatever is on screen now:
            // a slider nudged while it rendered must leave the result stale rather than claim it.
            if preparedSending != nil { preparedSettings = posed } else { onClose() }
        } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
    }

    private func send(_ sending: StickerControlsSheet.PreparedSending) async {
        guard !busy else { return }
        phase = .sending; errorMessage = nil
        defer { phase = nil }
        do {
            try await sending.send()
            try Task.checkCancellation()
            onClose()
        } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
    }
}
