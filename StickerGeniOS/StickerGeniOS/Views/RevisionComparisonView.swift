import AnimatedView
import SwiftUI
import UIKit

struct RevisionComparisonView: View {
    @Bindable var store: StickerStore
    let stickerID: String
    let assets: [String: UIImage]
    @Environment(\.dismiss) private var dismiss
    /// Every revision points at its own master asset, and the chat screen only ever loaded the
    /// working one. Comparing revisions is the one place that needs all of them at once, so it
    /// loads the rest itself instead of showing older cards as empty.
    @State private var history = StickerAssetStore()

    private var revisions: [StickerRevision] { store.details[stickerID]?.revisions ?? [] }
    private var mergedAssets: [String: UIImage] { assets.merging(history.images) { _, loaded in loaded } }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(revisions) { revision in
                    PosterCard {
                        VStack(spacing: 10) {
                            // Played, not sampled at `durationSeconds`: an animation that ends on a
                            // fade- or scale-out has nothing left in its final frame, which read as
                            // a blank card next to the revision it was supposed to be compared with.
                            StickerPlayer(document: revision.document, assets: mergedAssets, repeats: true)
                                .frame(width: 260, height: 260)
                            Text(revision.state.rawValue.capitalized).font(.headline)
                            Text(revision.createdAt, format: .dateTime.month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                            if revision.id != store.details[stickerID]?.activeRevisionId && revision.state != .candidate {
                                Button("Revert to this") {
                                    Task {
                                        let reverted = (try? await store.transition(
                                            stickerID: stickerID,
                                            revisionID: revision.id,
                                            action: .revert
                                        )) != nil
                                        if reverted { dismiss() }
                                    }
                                }
                                .buttonStyle(.poster)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .task(id: revisions.map(\.id).joined(separator: ":")) {
            for revision in revisions {
                await history.preload(document: revision.document, api: store.api)
            }
        }
        .navigationTitle("Compare revisions")
        .accessibilityIdentifier("revision-comparison")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}
