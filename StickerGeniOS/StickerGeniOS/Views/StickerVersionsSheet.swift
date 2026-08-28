import SwiftUI
import UIKit

struct StickerVersionsSheet: View {
    @Bindable var store: StickerStore
    let stickerID: String
    let assets: [String: UIImage]

    @Environment(\.dismiss) private var dismiss
    @State private var showingComparison = false
    @State private var localError: String?

    private var detail: StickerDetail? { store.details[stickerID] }
    private var candidate: StickerRevision? { detail?.revisions.first { $0.state == .candidate } }
    private var historicalRevisions: [StickerRevision] {
        (detail?.revisions ?? []).filter { $0.id != candidate?.id }
    }

    var body: some View {
        StickerBackground {
            ScrollView {
                VStack(spacing: 16) {
                    if historicalRevisions.isEmpty {
                        EmptyStateView(
                            symbol: "clock.arrow.circlepath",
                            title: "No earlier versions",
                            message: "Accepted revisions appear here so you can revert to any of them."
                        )
                    } else {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(historicalRevisions) { revision in
                                    HStack {
                                        Image(systemName: icon(for: revision))
                                        VStack(alignment: .leading) {
                                            Text(revision.state.label)
                                            Text(revision.createdAt, format: .relative(presentation: .named))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if revision.id == detail?.activeRevisionId {
                                            Text("Current")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                        } else if revision.state != .candidate {
                                            Button("Revert") { Task { await revert(to: revision) } }
                                                .buttonStyle(.glass)
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Button {
                            showingComparison = true
                        } label: {
                            Label("Compare side by side", systemImage: "rectangle.on.rectangle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .accessibilityIdentifier("compare-revisions")
                    }

                    if let error = localError { ErrorBanner(message: error) }
                }
                .padding()
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Version history")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("sticker-versions-sheet")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .sheet(isPresented: $showingComparison) {
            NavigationStack {
                RevisionComparisonView(store: store, stickerID: stickerID, assets: assets)
            }
        }
    }

    private func icon(for revision: StickerRevision) -> String {
        switch revision.state {
        case .accepted: "checkmark.circle.fill"
        case .candidate: "sparkles"
        default: "clock.arrow.circlepath"
        }
    }

    private func revert(to revision: StickerRevision) async {
        do {
            try await store.transition(stickerID: stickerID, revisionID: revision.id, action: .revert)
            localError = nil
            dismiss()
        } catch { localError = error.localizedDescription }
    }
}
