import AnimatedView
import SwiftUI
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

    private var assets: [String: UIImage] { assetStore.images }
    private var verifiedAssetIDs: Set<String> { assetStore.verifiedAssetIDs }

    private var publishJob: StickerJobState? {
        store.jobs[stickerID].flatMap { $0.jobID == model.publishJobID ? $0 : nil }
    }
    private var publishIsPending: Bool { publishJob.map { !$0.isTerminal } ?? false }
    private var publishSucceeded: Bool { publishJob.map { $0.isTerminal && !$0.isFailed } ?? false }
    private var isPublished: Bool { revision.hasPublishedExports || publishSucceeded }
    private var localExportReady: Bool { !revision.canPublishExports && !model.publishedURLs.isEmpty }
    private var actionIsComplete: Bool { isPublished || localExportReady }
    /// Saving an edit replaces the revision underneath a render that is already running, so the
    /// preview opens view-only while an export or publish is in flight.
    private var canEdit: Bool { !model.isPublishing && !publishIsPending }

    var body: some View {
        StickerBackground {
            ScrollView {
                VStack(spacing: 18) {
                    previewCard

                    GlassCard(padding: 20) {
                        VStack(alignment: .leading, spacing: 18) {
                            statusHeader
                            if revision.canPublishExports { exportSettings }
                            actionRow
                            if !model.publishedURLs.isEmpty {
                                ShareLink(items: model.publishedURLs) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glass)
                                .controlSize(.large)
                            }
                        }
                    }

                    if !revision.canPublishExports {
                        GlassCard {
                            Label(
                                "Animated stickers need motion before they can be published. Describe how it should move in chat first.",
                                systemImage: "waveform.path"
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if let error = model.errorMessage { ErrorBanner(message: error) }
                }
                .padding()
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Export")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("sticker-export-sheet")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        // Keyed on the revision because an edit made from the preview lands a new one under this
        // sheet: the background picker has to pick that document's setting back up, and anything
        // rendered for the version being replaced is stale.
        .task(id: revision.id) { model.seed(from: revision) }
        .fullScreenCover(isPresented: $isPresentingFullScreen) {
            FullScreenStickerPlayer(
                document: revision.document,
                assets: assets,
                editing: canEdit
                    ? .init(
                        store: store,
                        stickerID: stickerID,
                        revisionID: revision.id,
                        assetStore: assetStore
                    )
                    : nil
            )
        }
        .onChange(of: publishSucceeded) { _, succeeded in
            if succeeded { Haptics.success() }
        }
        .onChange(of: publishJob?.isFailed) { _, failed in
            if failed == true { Haptics.failure() }
        }
        .onChange(of: model.background) { oldValue, newValue in
            guard oldValue != newValue, !isPublished, !publishIsPending, !model.isPublishing else { return }
            model.invalidateExports()
        }
        .onChange(of: model.stickerSize) { oldValue, newValue in
            guard oldValue != newValue, !isPublished, !publishIsPending, !model.isPublishing else { return }
            model.invalidateExports()
        }
    }

    /// The sticker being acted on, above the card that acts on it. Publishing is
    /// irreversible enough that the reader should be able to confirm *which* version they
    /// are shipping — and fix it — without backing out of the sheet.
    ///
    /// The backdrop stays neutral on purpose: the MP4 background below is one export's
    /// setting, and painting it here would read as the look of every export.
    private var previewCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("CURRENT VERSION")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.7)
                    Spacer(minLength: 8)
                    Label(
                        revision.document.kind == .animated ? "Animated" : "Static",
                        systemImage: revision.document.kind == .animated ? "waveform.path" : "photo"
                    )
                    .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.secondary)

                Button { isPresentingFullScreen = true } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(.background)
                        StickerPlayer(document: revision.document, assets: assets, repeats: true)
                            .padding(16)
                    }
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: canEdit ? "slider.horizontal.3" : "arrow.up.left.and.arrow.down.right")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                            .padding(7)
                            .background(.thinMaterial, in: Circle())
                            .padding(8)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .buttonStyle(.plain)
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
                    Text(canEdit ? "Tap to view or edit" : "Tap to view")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var statusHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.green, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(
                    isPublished ? "Published"
                        : localExportReady ? "Export ready"
                        : revision.canPublishExports ? "Ready to publish"
                        : "Image ready"
                )
                    .font(.title3.bold())
                Text(
                    isPublished ? "Saved to your Library"
                        : localExportReady ? "Your files are ready to share"
                        : revision.canPublishExports ? "Your accepted revision is ready"
                        : "Export it now or add motion first"
                )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var exportSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("EXPORT SETTINGS")
                .font(.caption2.weight(.semibold))
                .tracking(0.7)
                .foregroundStyle(.secondary)

            sizePicker

            if revision.document.kind == .animated { backgroundPicker }
        }
    }

    /// The one control that changes how big the sticker arrives: Messages draws a sticker at its
    /// pixel size over three, and nothing in the document can move that number.
    private var sizePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The segmented style drops the picker's own label, and "Large/Medium/Small" on its own
            // reads as a quality setting.
            Text("Sticker size")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Sticker size", selection: $model.stickerSize) {
                ForEach(SystemStickerSize.allCases) { size in
                    Text(size.label).tag(size)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("sticker-size-picker")
            .disabled(isPublished || publishIsPending || model.isPublishing)

            Text("\(model.stickerSize.detail). Detailed artwork can still be exported one size down to stay under Apple's 500 KB limit.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

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
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(.primary.opacity(0.045), in: .rect(cornerRadius: 14))
            }
            .accessibilityIdentifier("mp4-background-picker")
            .disabled(isPublished || publishIsPending || model.isPublishing)

            Text("MP4 uses this background. GIF and system sticker exports remain transparent.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        } else if !actionIsComplete {
            Button {
                Haptics.tap(.medium)
                Task {
                    await model.exportOrPublish(
                        store: store,
                        stickerID: stickerID,
                        revision: revision,
                        assets: assets,
                        verifiedAssetIDs: verifiedAssetIDs
                    )
                    if model.errorMessage != nil {
                        Haptics.failure()
                    } else if !revision.canPublishExports {
                        // A local export is finished the moment this returns. A publish is not —
                        // it hands off to a job, and `publishSucceeded` is what says it landed.
                        Haptics.success()
                    }
                }
            } label: {
                Label(
                    revision.canPublishExports ? "Export & Publish" : "Export",
                    systemImage: revision.canPublishExports ? "shippingbox.fill" : "square.and.arrow.down.fill"
                )
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(AppColors.accent)
            .controlSize(.large)
            .accessibilityIdentifier(revision.canPublishExports ? "publish-exports" : "export-files")
        }
    }
}
