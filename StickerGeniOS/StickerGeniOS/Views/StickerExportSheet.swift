import SwiftUI
import UIKit

struct StickerExportSheet: View {
    @Bindable var store: StickerStore
    @Bindable var model: StickerExportModel
    let stickerID: String
    let revision: StickerRevision
    let assets: [String: UIImage]
    let verifiedAssetIDs: Set<String>

    @Environment(\.dismiss) private var dismiss

    private var publishJob: StickerJobState? {
        store.jobs[stickerID].flatMap { $0.jobID == model.publishJobID ? $0 : nil }
    }
    private var publishIsPending: Bool { publishJob.map { !$0.isTerminal } ?? false }
    private var publishSucceeded: Bool { publishJob.map { $0.isTerminal && !$0.isFailed } ?? false }
    private var isPublished: Bool { revision.hasPublishedExports || publishSucceeded }
    private var localExportReady: Bool { !revision.canPublishExports && !model.publishedURLs.isEmpty }
    private var actionIsComplete: Bool { isPublished || localExportReady }

    var body: some View {
        StickerBackground {
            ScrollView {
                VStack(spacing: 18) {
                    GlassCard(padding: 20) {
                        VStack(alignment: .leading, spacing: 18) {
                            statusHeader
                            if revision.document.kind == .animated && revision.canPublishExports { backgroundPicker }
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
        .task { model.seed(from: revision) }
        .onChange(of: model.background) { oldValue, newValue in
            guard oldValue != newValue, !isPublished, !publishIsPending, !model.isPublishing else { return }
            model.invalidateExports()
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

    private var backgroundPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("EXPORT SETTINGS")
                .font(.caption2.weight(.semibold))
                .tracking(0.7)
                .foregroundStyle(.secondary)

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
            .background(.purple.opacity(0.08), in: .rect(cornerRadius: 16))
            .accessibilityIdentifier("export-progress")
        } else if !actionIsComplete {
            Button {
                Task {
                    await model.exportOrPublish(
                        store: store,
                        stickerID: stickerID,
                        revision: revision,
                        assets: assets,
                        verifiedAssetIDs: verifiedAssetIDs
                    )
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
            .tint(.purple)
            .controlSize(.large)
            .accessibilityIdentifier(revision.canPublishExports ? "publish-exports" : "export-files")
        }
    }
}
