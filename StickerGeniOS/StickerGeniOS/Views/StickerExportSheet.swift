import AnimatedView
import OSLog
import SwiftUI
import TipKit
import UIKit

struct StickerExportSheet: View {
    @Bindable var store: StickerStore
    @Bindable var model: StickerExportModel
    let stickerID: String
    let revision: StickerRevision
    /// The store rather than a snapshot of its images: the preview is live and editable, so it
    /// needs the same provider the editor saves new layers through.
    let assetStore: StickerAssetStore

    @Environment(\.dismiss) private var dismiss
    @State private var isPresentingFullScreen = false
    @State private var isPresentingShareSheet = false
    @State private var isPresentingProgress = false
    private let publishTip = PublishStickerTip()
    private let useTip = UseStickerTip()

    @State private var controlsApplied = 0
    private var assets: [String: UIImage] { assetStore.images }
    private var renderAssets: StickerRenderAssets { assetStore.renderAssets }
    private var verifiedAssetIDs: Set<String> { assetStore.verifiedAssetIDs }

    private var publishJob: StickerJobState? {
        store.jobs[stickerID].flatMap { $0.jobID == model.publishJobID ? $0 : nil }
    }
    private var publishIsPending: Bool { publishJob.map { !$0.isTerminal } ?? false }
    private var publishSucceeded: Bool { publishJob.map { $0.isTerminal && !$0.isFailed } ?? false }
    private var publishFailed: Bool { publishJob?.isFailed ?? false }
    /// The server refused the publish. `model.errorMessage` cannot carry this: `publish` returned
    /// successfully — it hands off to a job — so the sheet would otherwise drop straight back to
    /// "Ready to publish" with the sticker still a draft and nothing on screen saying why.
    private var publishFailureMessage: String {
        publishJob?.failureMessage
            ?? String(localized: "Publishing failed. This sticker is still a draft — try publishing it again.")
    }
    private var isPublished: Bool { revision.hasPublishedExports || publishSucceeded }
    private var localExportReady: Bool { !revision.canPublishExports && !model.publishedURLs.isEmpty }
    private var actionIsComplete: Bool { isPublished || localExportReady }
    /// Saving an edit replaces the revision underneath a render that is already running, so the
    /// preview opens view-only while an export or publish is in flight.
    private var rememberedSettings: StickerControlSettings? {
        guard revision.document.configuration != nil else { return nil }
        _ = controlsApplied
        let account = (try? SharedKeychainTokenVault().load()?.subject) ?? "local"
        return StickerControlPreferences().load(accountID: account, stickerID: stickerID, document: revision.document)
    }

    private var canEdit: Bool { !model.isPublishing && !publishIsPending }

    /// One flat column on the sheet itself: preview, state, settings, actions.
    ///
    /// The cards this replaces stacked three glass surfaces on top of the sheet's own background,
    /// which put two borders and two paddings between the reader and every control for no
    /// grouping that the section headings and rules do not already state.
    var body: some View {
        StickerBackground {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    TutorialButton(
                        chapter: .finish,
                        step: "export",
                        title: TutorialCopy.text("Learn about exporting"),
                        onAction: { action in
                            if case .sticker(let screen) = action, screen == "export" { return true }
                            return false
                        }
                    )
                    .font(.footnote)
                    preview

                    statusHeader

                    if isPublished {
                        TipView(useTip)
                            .tipViewStyle(.miniTip)
                    }

                    if !revision.canPublishExports {
                        PosterSymbolLabel(
                            "Animated stickers need motion before they can be published. Describe how it should move in chat first.",
                            posterSymbol: "waveform.path"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if revision.canPublishExports {
                        Divider()
                        exportSettings
                    }

                    Divider()

                    VStack(spacing: 12) {
                        actionRow
                        shareRow
                    }

                    if let note = model.qualityNote { NoticeBanner(message: note) }
                    if publishFailed { ErrorBanner(message: publishFailureMessage) }
                    if let error = model.errorMessage { ErrorBanner(message: error) }
                }
                .padding(20)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
        }
        .environment(\.tutorialContext, TutorialContext(stickerID: stickerID))
        .navigationTitle("Export")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("sticker-export-sheet")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        // Keyed on the revision because an edit made from the preview lands a new one under this
        // sheet: the background picker has to pick that document's setting back up, and anything
        // rendered for the version being replaced is stale.
        .task(id: revision.id) { model.seed(from: revision) }
        .sheet(isPresented: $isPresentingShareSheet) {
            ShareSheet(items: model.publishedURLs)
        }
        // The export itself, step by step. Presented over this sheet rather than replacing the
        // inline row so the settings that produced the run stay behind it, and so a publish that is
        // still on the server can be left running from here.
        .sheet(isPresented: $isPresentingProgress) {
            if let progress = model.progress {
                StickerExportProgressSheet(
                    progress: progress,
                    onCancel: { model.cancelExport() },
                    onDismiss: { isPresentingProgress = false }
                )
            }
        }
        .fullScreenCover(isPresented: $isPresentingFullScreen) {
            FullScreenStickerPlayer(
                document: revision.document,
                assets: assets,
                videos: assetStore.videos,
                editing: canEdit
                    ? .init(
                        store: store,
                        stickerID: stickerID,
                        revisionID: revision.id,
                        assetStore: assetStore
                    )
                    : nil,
                controls: .init(store: store, stickerID: stickerID, assetStore: assetStore,
                    onApply: { controlsApplied += 1 })
            )
        }
        .onChange(of: publishSucceeded) { _, succeeded in
            if succeeded { Haptics.success() }
        }
        .onChange(of: publishJob?.isFailed) { _, failed in
            if failed == true { Haptics.failure() }
        }
        // The publish call returns as soon as the job is accepted, so the server's half of the run
        // only reaches the timeline through the job state the store keeps.
        .onChange(of: publishJob, initial: true) { _, job in
            StickerExportModel.log.debug(
                """
                job change job=\(job?.jobID ?? "-", privacy: .public) \
                watching=\(model.publishJobID ?? "-", privacy: .public) \
                terminal=\(job?.isTerminal ?? false) failed=\(job?.isFailed ?? false) \
                message=\(job?.message ?? "-", privacy: .public)
                """
            )
            // Losing sight of the job is not the same as the job not finishing: the store follows
            // one job per sticker, and a turn started from chat replaces this one there. The
            // revision is the other half of the same answer, and it is the half that outlives this.
            if let job { model.progress?.apply(publishJob: job) } else { model.settlePublish(with: revision) }
        }
        .onChange(of: model.background) { oldValue, newValue in
            guard oldValue != newValue, !isPublished, !publishIsPending, !model.isPublishing else { return }
            model.invalidateExports()
        }
        // Unlike the background, this changes nothing about the files — only which of them get
        // shared — so it stays available on a published sticker and drops just the share list.
        .onChange(of: model.selection) { oldValue, newValue in
            guard oldValue != newValue, !publishIsPending, !model.isPublishing else { return }
            model.clearShareFiles()
        }
        // Same reasoning as the selection above: the published files are unchanged, so only the
        // share list is dropped — but a GIF share has to be encoded, so the next share re-renders.
        .onChange(of: model.sharingFormat) { oldValue, newValue in
            guard oldValue != newValue, !publishIsPending, !model.isPublishing else { return }
            model.clearShareFiles()
        }
    }

    /// The sticker being acted on, above the controls that act on it. Publishing is
    /// irreversible enough that the reader should be able to confirm *which* version they
    /// are shipping — and fix it — without backing out of the sheet.
    ///
    /// The one surface left on the sheet, and not a card: a sticker is transparent by definition, so
    /// a white one drawn straight onto the background would be a blank rectangle. The backdrop stays
    /// neutral on purpose — the MP4 background below is one export's setting, and painting it here
    /// would read as the look of every export.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isPresentingFullScreen = true
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.background.opacity(0.7))
                    StickerPlayer(
                        document: revision.document, assets: assets, videos: assetStore.videos,
                        repeats: true, settings: rememberedSettings
                    )
                        .padding(16)
                }
                .frame(height: 190)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topTrailing) {
                    PosterSymbolLabel(
                        revision.document.kind == .animated ? "Animated" : "Static",
                        posterSymbol: revision.document.kind == .animated ? "waveform.path" : "photo"
                    )
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(10)
                }
                .overlay(alignment: .bottomTrailing) {
                    PosterSymbol(canEdit ? "slider.horizontal.3" : "arrow.up.left.and.arrow.down.right")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(7)
                        .background(AppColors.card, in: Circle())
                        .overlay(Circle().strokeBorder(AppColors.ink, lineWidth: 1))
                        .padding(8)
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.posterPlain)
            .accessibilityIdentifier("export-preview")
            .accessibilityLabel(
                revision.document.kind == .animated
                    ? "Current animated sticker"
                    : "Current sticker"
            )
            .accessibilityHint(canEdit ? "Opens full screen, where it can be edited" : "Opens full screen")

            HStack {
                Text(revision.createdAt, format: .relative(presentation: .named))
                Spacer(minLength: 8)
                Text(canEdit ? LocalizedStringKey("Tap to view or edit") : LocalizedStringKey("Tap to view"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var statusHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            PosterSymbol(publishFailed ? "exclamationmark" : "checkmark")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(publishFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.green), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(
                    publishFailed ? "Publish failed"
                        : isPublished ? "Published"
                        : localExportReady ? "Export ready"
                        : revision.canPublishExports ? "Ready to publish"
                        : "Image ready"
                )
                    .font(.title3.bold())
                Text(
                    publishFailed ? "This sticker is still a draft"
                        : isPublished ? "Saved to your Library"
                        : localExportReady ? "Your files are ready to share"
                        : revision.canPublishExports ? "Your accepted revision is ready"
                        : "Export it now or add motion first"
                )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier(publishFailed ? "publish-failed-header" : "export-status-header")
    }

    private var exportSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("EXPORT SETTINGS")
                .font(.caption2.weight(.semibold))
                .tracking(0.7)
                .foregroundStyle(.secondary)

            if revision.document.kind == .animated { selectionPicker }

            if revision.document.kind == .animated, model.selection.includesSticker { sharingFormatPicker }

            if revision.document.kind == .animated { backgroundPicker }
        }
    }

    /// A sticker and a video are two different things to want, and wanting one does not mean
    /// wanting the other: this decides which files the share sheet hands over.
    private var selectionPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Export as")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Export as", selection: $model.selection) {
                ForEach(StickerExportSelection.allCases) { selection in
                    Text(selection.label).tag(selection)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("export-selection-picker")
            .disabled(publishIsPending || model.isPublishing)

            Text(model.selection.detail(
                isAnimated: revision.document.kind == .animated,
                sharing: model.sharingFormat
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Which container the animated sticker is shared in.
    ///
    /// A share-sheet choice only. The APNG is published either way — it is what the library and the
    /// Messages extension read — so this never changes the sticker, only the file handed to whatever
    /// app it is being sent to. It is here because neither answer is right everywhere: APNG is
    /// smaller and keeps soft transparent edges, and the apps most people send to outside Messages
    /// will not animate one.
    private var sharingFormatPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Animation format")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Animation format", selection: $model.sharingFormat) {
                ForEach(StickerSharingFormat.allCases) { format in
                    Text(format.label).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("export-sharing-format-picker")
            .disabled(publishIsPending || model.isPublishing)

            Text(model.sharingFormat.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // There is no size picker here any more. It used to bake one dimension into the published
    // sticker, which meant changing your mind cost a re-publish — and it asked the question at the
    // wrong moment, since how big a sticker should arrive depends on the conversation it is going
    // into. A publish now renders every size, and WinkySticker chooses between them on the way out.

    private var backgroundPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                Picker("MP4 background", selection: $model.background) {
                    ForEach(ExportBackgroundChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    ExportBackgroundSwatch(choice: model.background)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("MP4 background")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(model.background.label)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                    }

                    Spacer()
                    PosterDropdownIcon()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .posterSurface(cornerRadius: 14, fill: AppColors.paper, lineWidth: Poster.hairline, offset: .zero)
            }
            .accessibilityIdentifier("mp4-background-picker")
            .disabled(publishIsPending || model.isPublishing)

            Text("MP4 uses this background. The animated PNG and system sticker exports remain transparent.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Share is offered for anything that has files to hand over — including a revision published
    /// in an earlier session, which this run rendered nothing for. Publishing is the point of the
    /// sheet, so reaching the published state and finding no way to send the sticker anywhere
    /// reads as the publish having gone nowhere.
    @ViewBuilder
    private var shareRow: some View {
        if !model.publishedURLs.isEmpty {
            ShareLink(items: model.publishedURLs) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.posterSecondary)
            .controlSize(.large)
            .accessibilityIdentifier("share-exports")
        } else if isPublished {
            // The files are on the server, not on this device, so the share sheet cannot be handed
            // its items up front the way `ShareLink` needs them.
            Button {
                Task {
                    if await model.prepareShareFiles(
                        store: store,
                        revision: revision,
                        assets: renderAssets,
                        verifiedAssetIDs: verifiedAssetIDs
                    ) {
                        isPresentingShareSheet = true
                    } else {
                        Haptics.failure()
                    }
                }
            } label: {
                Group {
                    if model.isPreparingShare {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Preparing files…")
                        }
                    } else {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.posterSecondary)
            .controlSize(.large)
            .disabled(model.isPreparingShare)
            .accessibilityIdentifier("share-exports")
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        if model.isPublishing || publishIsPending {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(
                    model.isPublishing
                        ? (revision.canPublishExports ? "Preparing exports…" : "Exporting files…")
                        : "Publishing…"
                )
                    .fontWeight(.semibold)
            }
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .background(AppColors.accentSoft.opacity(0.38), in: .rect(cornerRadius: 16))
            .accessibilityIdentifier("export-progress")
        } else if actionIsComplete {
            // Kept on screen with nothing pending and nothing edited. The settings above describe
            // the *next* render, and the ladder can walk a rendition down to fit Apple's 500 KB
            // ceiling without being asked — so "the size I picked" and "the size I got" are not the
            // same claim, and running it again has to be reachable without editing the sticker
            // first. Secondary styling, because Share is the point of this state.
            Button(action: runExport) { actionLabel }
                .buttonStyle(.posterSecondary)
                .controlSize(.large)
                .accessibilityIdentifier("re-export-files")
        } else {
            Button(action: runExport) { actionLabel }
                .buttonStyle(.poster)
                .controlSize(.large)
                .popoverTip(revision.canPublishExports ? publishTip : nil, arrowEdge: .bottom)
                .accessibilityIdentifier(revision.canPublishExports ? "publish-exports" : "export-files")
        }
    }

    /// Renamed once files exist, so the same button reads as "run it again" rather than as an
    /// action already taken.
    private var actionLabel: some View {
        Label {
            Text(
                actionIsComplete
                    ? (revision.canPublishExports ? "Re-export & Publish" : "Re-export")
                    : (revision.canPublishExports ? "Export & Publish" : "Export")
            )
        } icon: {
            Image(
                systemName: actionIsComplete
                    ? "arrow.clockwise"
                    : (revision.canPublishExports ? "shippingbox.fill" : "square.and.arrow.down.fill")
            )
        }
        .fontWeight(.semibold)
        .frame(maxWidth: .infinity)
    }

    private func runExport() {
        publishTip.invalidate(reason: .actionPerformed)
        // The timeline opens in the same frame as the tap, before any work starts: the first step
        // validates a document whose assets may still be arriving, and that is exactly the wait
        // this replaces.
        isPresentingProgress = true
        model.startExportOrPublish(
            store: store,
            stickerID: stickerID,
            revision: revision,
            assets: renderAssets,
            verifiedAssetIDs: verifiedAssetIDs
        ) {
            if model.errorMessage != nil {
                Haptics.failure()
            } else if !revision.canPublishExports, model.progress?.outcome == .succeeded {
                // A local export is finished the moment this returns. A publish is not —
                // it hands off to a job, and `publishSucceeded` is what says it landed.
                Haptics.success()
            }
        }
    }
}

/// The system share sheet for files that only exist once a download finishes — the case
/// `ShareLink`, which takes its items at construction, cannot cover.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
