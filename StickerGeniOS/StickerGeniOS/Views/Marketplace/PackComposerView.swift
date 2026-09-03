import SwiftUI

/// Create a pack, pick its stickers, and publish it.
///
/// Only *published* stickers are offered: an unpublished one has no system rendition, so it would
/// be invisible in every surface a pack feeds — the server refuses it for the same reason.
struct PackComposerView: View {
    @Bindable var store: MarketplaceStore
    var onCreated: () -> Void

    @State private var title = ""
    @State private var summary = ""
    /// Whole stickers, in the order they were picked: the composer shows only the selection, so it
    /// cannot look them up in a library feed it no longer holds.
    @State private var selected: [Sticker] = []
    @State private var showingPicker = false
    @State private var isSubmitting = false
    /// Which round trip of the submission is running, or `nil` when nothing is in flight.
    @State private var submissionStatus: String?
    @State private var errorMessage: String?

    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !selected.isEmpty && !isSubmitting
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $title)
                    .accessibilityIdentifier("pack-title-field")
                TextField("Description", text: $summary, axis: .vertical)
                    .lineLimit(1...3)
                    .accessibilityIdentifier("pack-summary-field")
            } header: {
                PosterListHeader("Pack")
            }

            Section {
                if selected.isEmpty {
                    Text("Nothing chosen yet — add the stickers this pack should contain.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 12)], spacing: 12) {
                        ForEach(selected) { sticker in
                            Button {
                                Haptics.selection()
                                selected.removeAll { $0.id == sticker.id }
                            } label: {
                                StickerThumbnail(sticker: sticker, api: store.api)
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay(alignment: .topTrailing) {
                                        PosterSymbol("minus.circle.fill")
                                            .foregroundStyle(.white, .red)
                                            .padding(6)
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(localized: "Remove \(sticker.title)"))
                            .accessibilityIdentifier("pack-remove-\(sticker.id)")
                        }
                    }
                }

                Button {
                    showingPicker = true
                } label: {
                    Label("Choose stickers", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("pack-choose-stickers-button")
            } header: {
                Text("Stickers (\(selected.count) selected)")
            }

            if let errorMessage {
                Section { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
            }

            Section {
                // Creating a pack is three round trips, and the sheet stays open for all of them.
                // Showing which one is running is the difference between "working" and "stuck".
                if let submissionStatus {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(submissionStatus).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("pack-submission-progress")
                } else {
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
        }
        // The fields and the picker are the submission's input; editing them mid-flight would
        // describe a pack the server is no longer being asked for.
        .disabled(isSubmitting)
        .scrollContentBackground(.hidden)
        .background { PosterPaper() }
        .listRowBackground(AppColors.card)
        .navigationTitle("New pack")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPicker) {
            StickerPickerSheet(api: store.api, selection: $selected)
        }
    }

    private func submit(publish: Bool) async {
        isSubmitting = true
        errorMessage = nil
        submissionStatus = String(localized: "Creating pack…")
        defer {
            isSubmitting = false
            submissionStatus = nil
        }
        do {
            // Pick order is the pack's order: the picker pages and searches, so there is no single
            // library ordering left to fall back on — and what the composer showed is what ships.
            let detail = try await store.createPack(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                summary: summary.isEmpty ? nil : summary,
                stickerIDs: selected.map(\.id)
            )
            if publish {
                submissionStatus = String(localized: "Publishing pack…")
                try await store.publish(packID: detail.id)
            }
            submissionStatus = String(localized: "Updating your packs…")
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
            onCreated: {}
        )
    }
}
