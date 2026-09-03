import SwiftUI

/// Edit a pack you created — before or after it went live.
///
/// A published pack is not frozen: renaming it, rewriting its description, adding a sticker or
/// reordering the grid all apply in place, and everyone who installed it sees the change on their
/// next sync. Only the slug is fixed, so a link somebody shared keeps working through a rename.
///
/// Everything the composer cannot do lives here rather than in `PackDetailView`: publishing,
/// returning a pack to draft, and deleting it are all edits to the same pack, and splitting them
/// across two screens would leave the creator hunting for the half they wanted.
struct PackEditorView: View {
    @Bindable var store: MarketplaceStore
    let packID: String
    /// Called once the pack is gone, so the detail screen behind this sheet can pop rather than sit
    /// on a pack the store no longer holds.
    var onDeleted: () -> Void

    @State private var title: String
    @State private var summary: String
    /// Whole stickers, in pack order. Holding the values rather than ids keeps the rows renderable
    /// after the picker sheet — which pages and searches — has scrolled them out of its own feed.
    @State private var members: [Sticker]
    /// What the server currently holds, so a save sends only what actually changed and a second tap
    /// on Save is a no-op rather than another round trip.
    @State private var saved: Saved

    @State private var showingPicker = false
    @State private var confirmingDelete = false
    @State private var isWorking = false
    /// Which round trip is running, or `nil` when nothing is in flight.
    @State private var workStatus: String?
    @State private var errorMessage: String?

    @Environment(\.dismiss) private var dismiss

    private struct Saved: Equatable {
        var title: String
        var summary: String?
        var memberIDs: [String]
    }

    init(store: MarketplaceStore, detail: StickerPackDetail, onDeleted: @escaping () -> Void) {
        self.store = store
        packID = detail.id
        self.onDeleted = onDeleted
        _title = State(initialValue: detail.title)
        _summary = State(initialValue: detail.summary ?? "")
        _members = State(initialValue: detail.stickers)
        _saved = State(initialValue: Saved(
            title: detail.title,
            summary: detail.summary,
            memberIDs: detail.stickers.map(\.id)
        ))
    }

    /// The pack as the store last saw it. Publishing and unpublishing change nothing this view
    /// edits, so the live row — not the seed it was opened with — says which state it is in.
    private var detail: StickerPackDetail? { store.details[packID] }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var edited: Saved {
        let description = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return Saved(
            title: trimmedTitle,
            summary: description.isEmpty ? nil : description,
            memberIDs: members.map(\.id)
        )
    }

    private var hasChanges: Bool { edited != saved }

    private var canSave: Bool { !trimmedTitle.isEmpty && hasChanges && !isWorking }

    /// Members the server counts but will not hand back.
    ///
    /// Editing a sticker on device returns it to draft, and a draft has no system rendition — so it
    /// drops out of the pack for everyone without ever being removed from it. `itemCount` still
    /// counts it, which is the only way this screen can know it is there.
    private var hiddenCount: Int {
        guard let detail else { return 0 }
        return max(0, detail.itemCount - detail.stickers.count)
    }

    var body: some View {
        Form {
            detailsSection
            membersSection
            if hiddenCount > 0 { hiddenSection }
            visibilitySection
            if let errorMessage {
                Section { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
            }
            deleteSection
        }
        // The fields and the member list are the request's input; editing them mid-flight would
        // describe a pack the server is no longer being asked for.
        .disabled(isWorking)
        .scrollContentBackground(.hidden)
        .background { PosterPaper() }
        .listRowBackground(AppColors.card)
        .navigationTitle("Edit pack")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
                    .accessibilityIdentifier("pack-editor-close-button")
            }
            ToolbarItem(placement: .confirmationAction) {
                if isWorking {
                    ProgressView()
                } else {
                    Button("Save") {
                        Haptics.tap(.medium)
                        Task { await save() }
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("pack-editor-save-button")
                }
            }
        }
        .sheet(isPresented: $showingPicker) {
            StickerPickerSheet(api: store.api, selection: $members)
        }
        .confirmationDialog("Delete this pack?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete pack", role: .destructive) {
                Haptics.tap(.heavy)
                Task { await delete() }
            }
            Button("Keep pack", role: .cancel) {}
        } message: {
            Text("It disappears from the marketplace and from everyone who added it. Your stickers themselves are untouched.")
        }
        // Reopened after an edit elsewhere, the seed this view was built from can be stale.
        .task(id: packID) { await store.loadDetail(packID: packID) }
    }

    // MARK: - Sections

    @ViewBuilder
    private var detailsSection: some View {
        Section {
            TextField("Name", text: $title)
                .accessibilityIdentifier("pack-editor-title-field")
            TextField("Description", text: $summary, axis: .vertical)
                .lineLimit(1...3)
                .accessibilityIdentifier("pack-editor-summary-field")
        } header: {
            Text("Pack")
        } footer: {
            if let slug = detail?.slug {
                Text("The link stays /marketplace/\(slug) even if you rename this pack.")
            }
        }
    }

    @ViewBuilder
    private var membersSection: some View {
        Section {
            if members.isEmpty {
                Text("Nothing in this pack yet — add the stickers it should contain.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(members) { sticker in
                    HStack(spacing: 12) {
                        StickerThumbnail(sticker: sticker, api: store.api)
                            .frame(width: 44, height: 44)
                        Text(sticker.title).lineLimit(1)
                    }
                    .accessibilityIdentifier("pack-editor-member-\(sticker.id)")
                }
                .onMove { members.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { members.remove(atOffsets: $0) }
            }

            Button {
                showingPicker = true
            } label: {
                Label("Choose stickers", systemImage: "plus.circle")
            }
            .accessibilityIdentifier("pack-editor-choose-stickers-button")
        } header: {
            HStack {
                Text("Stickers (\(members.count))")
                Spacer()
                // Reordering is drag-to-move, which needs edit mode. It sits here rather than in the
                // toolbar because it governs this list alone, not the fields above it. `.textCase`
                // undoes the uppercasing a section header would otherwise put on the button.
                if members.count > 1 {
                    EditButton()
                        .textCase(nil)
                        .accessibilityIdentifier("pack-editor-reorder-button")
                }
            }
        } footer: {
            // The server takes the first member as the cover, and the browse tile is built from the
            // first four — so the order here is not only the grid's, it is the pack's shopfront.
            if members.count > 1 { Text("The first sticker is the pack's cover. Drag to reorder.") }
        }
    }

    @ViewBuilder
    private var hiddenSection: some View {
        Section {
            PosterSymbolLabel(
                verbatim: hiddenCount == 1
                    ? String(localized: "1 sticker in this pack is hidden from people who added it.")
                    : String(localized: "\(hiddenCount) stickers in this pack are hidden from people who added it."),
                posterSymbol: "eye.slash"
            )
            .font(.footnote)
            Text("Editing a sticker on device returns it to draft, and a draft cannot appear in a pack. Publish it again to bring it back — but saving the sticker list here drops it from the pack for good.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("pack-editor-hidden-warning")
    }

    @ViewBuilder
    private var visibilitySection: some View {
        if let detail {
            Section {
                LabeledContent("Status", value: detail.state.label)
                if detail.state == .published {
                    Button("Move to draft") {
                        Haptics.tap(.light)
                        Task { await setPublished(false) }
                    }
                    .accessibilityIdentifier("pack-editor-unpublish-button")
                } else {
                    Button("Publish pack") {
                        Haptics.tap(.medium)
                        Task { await setPublished(true) }
                    }
                    .disabled(members.isEmpty)
                    .accessibilityIdentifier("pack-editor-publish-button")
                }

                if let workStatus {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(workStatus).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("pack-editor-progress")
                }
            } header: {
                Text("Visibility")
            } footer: {
                Text(detail.state == .published
                    ? String(localized: "Anyone can find this pack. Edits reach everyone who added it.")
                    : String(localized: "Only you can see this pack until you publish it."))
            }
        }
    }

    @ViewBuilder
    private var deleteSection: some View {
        Section {
            Button("Delete pack", role: .destructive) {
                Haptics.tap(.light)
                confirmingDelete = true
            }
            .disabled(isWorking)
            .accessibilityIdentifier("pack-editor-delete-button")
        }
    }

    // MARK: - Actions

    private func save() async {
        guard await commit() else { return }
        Haptics.success()
        dismiss()
    }

    /// Writes whatever changed, and reports whether everything landed.
    ///
    /// Details and membership are two calls because they are two endpoints; sending the one that
    /// did not change would burn a round trip and bump `updatedAt` for nothing.
    private func commit() async -> Bool {
        let wanted = edited
        guard wanted != saved else { return true }
        isWorking = true
        errorMessage = nil
        defer {
            isWorking = false
            workStatus = nil
        }
        do {
            if wanted.title != saved.title || wanted.summary != saved.summary {
                workStatus = String(localized: "Saving details…")
                try await store.updateDetails(packID: packID, title: wanted.title, summary: wanted.summary)
                saved.title = wanted.title
                saved.summary = wanted.summary
            }
            if wanted.memberIDs != saved.memberIDs {
                workStatus = String(localized: "Saving stickers…")
                try await store.setItems(packID: packID, stickerIDs: wanted.memberIDs)
                saved.memberIDs = wanted.memberIDs
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            Haptics.failure()
            return false
        }
    }

    /// Publishing is "publish what I am looking at", so pending edits go first — a creator who
    /// renamed the pack and then tapped Publish did not ask for the old name to go live.
    private func setPublished(_ published: Bool) async {
        guard await commit() else { return }
        isWorking = true
        errorMessage = nil
        defer {
            isWorking = false
            workStatus = nil
        }
        do {
            workStatus = published
                ? String(localized: "Publishing pack…")
                : String(localized: "Returning to draft…")
            if published {
                try await store.publish(packID: packID)
            } else {
                try await store.unpublish(packID: packID)
            }
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.failure()
        }
    }

    private func delete() async {
        isWorking = true
        errorMessage = nil
        defer {
            isWorking = false
            workStatus = nil
        }
        do {
            workStatus = String(localized: "Deleting pack…")
            try await store.deletePack(packID: packID)
            await store.refresh()
            Haptics.success()
            onDeleted()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.failure()
        }
    }
}

#Preview {
    NavigationStack {
        PackEditorView(
            store: MarketplaceStore(api: MockStickerAPIClient()),
            detail: PreviewFixtures.packDetail,
            onDeleted: {}
        )
    }
}
