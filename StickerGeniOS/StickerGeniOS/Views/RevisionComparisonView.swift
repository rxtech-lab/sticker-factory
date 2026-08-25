import SwiftUI
import UIKit

struct RevisionComparisonView: View {
    @Bindable var store: StickerStore
    let stickerID: String
    let assets: [String: UIImage]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(store.details[stickerID]?.revisions ?? []) { revision in
                    GlassCard {
                        VStack(spacing: 10) {
                            StickerScene(document: revision.document, time: revision.document.durationSeconds, assets: assets)
                                .frame(width: 260, height: 260)
                            Text(revision.state.rawValue.capitalized).font(.headline)
                            Text(revision.createdAt, format: .dateTime.month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                            if revision.id != store.details[stickerID]?.activeRevisionId && revision.state != .candidate {
                                Button("Revert to this") {
                                    Task { if (try? await store.transition(stickerID: stickerID, revisionID: revision.id, action: .revert)) != nil { dismiss() } }
                                }
                                .buttonStyle(.glassProminent)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Compare revisions")
        .accessibilityIdentifier("revision-comparison")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}
