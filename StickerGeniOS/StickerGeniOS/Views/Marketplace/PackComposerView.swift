import SwiftUI

/// Create a pack, pick its stickers, and publish it.
///
/// Only *published* stickers are offered: an unpublished one has no system rendition, so it would
/// be invisible in every surface a pack feeds — the server refuses it for the same reason.
///
/// Creating the pack is not the end of the sheet. A member without its WhatsApp and Telegram
/// copies has to be encoded before the pack can be sent anywhere, and that happens on this phone
/// — so a save that leaves such members pushes `MessengerPreparationView` and hands the pack over
/// only once that screen is done with it.
struct PackComposerView: View {
    @Bindable var store: MarketplaceStore
    /// Handed the pack that was made, so the caller can land on it — where sending it to
    /// WhatsApp or Telegram lives.
    var onCreated: (StickerPackDetail) -> Void

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
    /// The pack just made, while its members are being prepared on the pushed screen.
    @State private var preparing: PackPreparationRoute?

    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !selected.isEmpty && !isSubmitting
    }

    var body: some View {
        Form {
            Section {
                TutorialButton(chapter: .newPack, title: TutorialCopy.text("How to create a pack"), onAction: { action in
                    if action == .newPack { return true }; return false
                })
            }
            Section {
                TextField("Name", text: $title)
                    .accessibilityIdentifier("pack-title-field")
                TextField("Description", text: $summary, axis: .vertical)
                    .lineLimit(1...3)
                    .accessibilityIdentifier("pack-summary-field")
            } header: {
                PosterListHeader("Pack")
            }

            PackMembersSection(members: $selected, api: store.api, identifierPrefix: "pack") {
                showingPicker = true
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
        .navigationDestination(item: $preparing) { route in
            MessengerPreparationView(
                preparer: store.messengerPreparer,
                api: store.api,
                stickers: route.stickers,
                onFinished: { onCreated(route.detail) }
            )
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
            // The pack exists either way. What differs is whether it can be sent yet: a member
            // short of a rendition keeps the sheet up for the encode, and the hand-off to the
            // caller waits for that screen's Done.
            let pending = MessengerRenditionPreparer.pending(in: detail.stickers)
            if pending.isEmpty {
                onCreated(detail)
            } else {
                preparing = PackPreparationRoute(detail: detail, stickers: pending)
            }
        } catch {
            errorMessage = error.localizedDescription
            Haptics.failure()
        }
    }
}

/// A pack whose members are about to be encoded for the messengers, as a navigation value.
///
/// Hashed by the pack alone: the route exists to push one screen for one save, and two saves of
/// the same pack in a row are the same destination with a fresher member list.
struct PackPreparationRoute: Hashable {
    let detail: StickerPackDetail
    let stickers: [Sticker]

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.detail.id == rhs.detail.id }
    func hash(into hasher: inout Hasher) { hasher.combine(detail.id) }
}

#Preview {
    NavigationStack {
        PackComposerView(
            store: MarketplaceStore(api: MockStickerAPIClient()),
            onCreated: { _ in }
        )
    }
}
