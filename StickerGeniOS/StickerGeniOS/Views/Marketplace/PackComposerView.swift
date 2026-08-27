import SwiftUI

/// Create a pack, pick its stickers, and publish it.
///
/// Only *published* stickers are offered: an unpublished one has no system rendition, so it would
/// be invisible in every surface a pack feeds — the server refuses it for the same reason.
struct PackComposerView: View {
    @Bindable var store: MarketplaceStore
    @Bindable var library: StickerStore
    var onCreated: () -> Void

    @State private var title = ""
    @State private var summary = ""
    @State private var selected: Set<String> = []
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var eligible: [Sticker] {
        library.stickers.filter { $0.status == .published }
    }

    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !selected.isEmpty && !isSubmitting
    }

    var body: some View {
        Form {
            Section("Pack") {
                TextField("Name", text: $title)
                    .accessibilityIdentifier("pack-title-field")
                TextField("Description", text: $summary, axis: .vertical)
                    .lineLimit(1...3)
                    .accessibilityIdentifier("pack-summary-field")
            }

            Section {
                if eligible.isEmpty {
                    Text("Publish a sticker first — a pack can only contain published stickers.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 12)], spacing: 12) {
                        ForEach(eligible) { sticker in
                            Button {
                                Haptics.selection()
                                if selected.contains(sticker.id) {
                                    selected.remove(sticker.id)
                                } else {
                                    selected.insert(sticker.id)
                                }
                            } label: {
                                StickerThumbnail(sticker: sticker, api: store.api)
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay(alignment: .topTrailing) {
                                        Image(systemName: selected.contains(sticker.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(
                                                selected.contains(sticker.id) ? AppColors.accent : Color.secondary
                                            )
                                            .padding(6)
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("pack-pick-\(sticker.id)")
                        }
                    }
                }
            } header: {
                Text("Stickers (\(selected.count) selected)")
            }

            if let errorMessage {
                Section { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
            }

            Section {
                Button("Create and publish") {
                    Haptics.tap(.medium)
                    Task { await submit(publish: true) }
                }
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("pack-create-publish-button")
                Button("Save as draft") {
                    Haptics.tap(.light)
                    Task { await submit(publish: false) }
                }
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("pack-create-draft-button")
            }
        }
        .navigationTitle("New pack")
        .navigationBarTitleDisplayMode(.inline)
        .task { if library.stickers.isEmpty { await library.refresh() } }
    }

    private func submit(publish: Bool) async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            // The order the user tapped is not meaningful; the library order is.
            let ordered = eligible.map(\.id).filter(selected.contains)
            let detail = try await store.createPack(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                summary: summary.isEmpty ? nil : summary,
                stickerIDs: ordered
            )
            if publish { try await store.publish(packID: detail.id) }
            await store.refresh()
            Haptics.success()
            onCreated()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.failure()
        }
    }
}

#Preview {
    NavigationStack {
        PackComposerView(
            store: MarketplaceStore(api: MockStickerAPIClient()),
            library: StickerStore(api: MockStickerAPIClient()),
            onCreated: {}
        )
    }
}
