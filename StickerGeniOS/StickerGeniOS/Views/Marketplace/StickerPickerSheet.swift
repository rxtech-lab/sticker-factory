import Observation
import SwiftUI

/// A paged, searchable feed of the stickers a pack may contain.
///
/// Deliberately its own model rather than a read of `StickerStore`: the Library's snapshot is
/// whatever that tab happens to have scrolled to, and driving its search from a sheet would replace
/// what the Library is showing behind it. Fetching here also keeps the picker to *published*
/// stickers server-side, so paging never stalls on a page that contains only drafts.
@MainActor
@Observable
final class StickerPickerModel {
    private(set) var stickers: [Sticker] = []
    private(set) var nextCursor: String?
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var errorMessage: String?

    let api: any StickerAPIClientProtocol

    /// Invalidates a page response that is still in flight when the query changes.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var activeQuery: String?

    init(api: any StickerAPIClientProtocol) {
        self.api = api
    }

    /// Loads the first page for `rawQuery`, debounced so typing does not fire a request per keystroke.
    func load(query rawQuery: String, debounce: Duration = .milliseconds(300)) async {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        generation &+= 1
        let generation = self.generation
        activeQuery = query.isEmpty ? nil : query
        isLoading = true
        defer { if generation == self.generation { isLoading = false } }
        do {
            if debounce > .zero { try await Task.sleep(for: debounce) }
            let page = try await api.publishedStickers(query: activeQuery, cursor: nil)
            guard generation == self.generation else { return }
            var seen = Set<String>()
            stickers = page.items.filter { seen.insert($0.id).inserted }
            nextCursor = Self.usableCursor(page.nextCursor)
            errorMessage = nil
        } catch {
            guard generation == self.generation, !StickerStore.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Appends exactly one continuation page. The cursor survives a failure so the sentinel can
    /// retry, and a server that repeats a cursor ends pagination rather than looping on one page.
    func loadMore() async {
        guard let cursor = nextCursor, !isLoading, !isLoadingMore else { return }
        let generation = self.generation
        isLoadingMore = true
        defer { if generation == self.generation { isLoadingMore = false } }
        do {
            let page = try await api.publishedStickers(query: activeQuery, cursor: cursor)
            guard generation == self.generation else { return }
            var seen = Set(stickers.map(\.id))
            stickers.append(contentsOf: page.items.filter { seen.insert($0.id).inserted })
            let next = Self.usableCursor(page.nextCursor)
            nextCursor = next == cursor ? nil : next
            errorMessage = nil
        } catch {
            guard generation == self.generation, !StickerStore.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private static func usableCursor(_ cursor: String?) -> String? {
        guard let cursor, !cursor.isEmpty else { return nil }
        return cursor
    }
}

/// Picks the stickers that go into a pack.
///
/// The selection is the caller's, and it holds whole stickers rather than ids: the composer shows
/// what was picked even after a search has scrolled those rows out of this feed entirely.
struct StickerPickerSheet: View {
    @Binding var selection: [Sticker]

    @State private var model: StickerPickerModel
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    init(api: any StickerAPIClientProtocol, selection: Binding<[Sticker]>) {
        _selection = selection
        _model = State(initialValue: StickerPickerModel(api: api))
    }

    private var selectedIDs: Set<String> {
        Set(selection.map(\.id))
    }

    /// Re-arms the pagination sentinel for each new cursor — a `.task` keyed on the view's identity
    /// alone would fire once and never ask for a third page.
    private var paginationTaskID: String? {
        model.nextCursor.map { "\(query):\($0)" }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Choose stickers")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, prompt: "Search stickers")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            Haptics.tap(.light)
                            dismiss()
                        }
                            .accessibilityIdentifier("sticker-picker-done-button")
                    }
                }
                .safeAreaInset(edge: .top) {
                    if let errorMessage = model.errorMessage {
                        ErrorBanner(message: errorMessage).padding(.horizontal)
                    }
                }
                // Clearing the field restores the unfiltered feed immediately; typing waits out the
                // debounce inside `load`.
                .task(id: query) {
                    await model.load(query: query, debounce: query.isEmpty ? .zero : .milliseconds(300))
                }
        }
        .accessibilityIdentifier("sticker-picker-sheet")
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.stickers.isEmpty {
            PosterProgress(message: String(localized: "Loading stickers…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.stickers.isEmpty {
            EmptyStateView(
                title: query.isEmpty
                    ? String(localized: "No published stickers")
                    : String(localized: "No matches"),
                message: query.isEmpty
                    ? String(localized: "Publish a sticker first — a pack can only contain published stickers.")
                    : String(localized: "No published sticker matches “\(query)”.")
            )
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 12) {
                    ForEach(model.stickers) { sticker in
                        Button {
                            Haptics.selection()
                            toggle(sticker)
                        } label: {
                            PickableSticker(
                                sticker: sticker,
                                api: model.api,
                                isSelected: selectedIDs.contains(sticker.id)
                            )
                        }
                        // Stays undecorated and silent: a tile that toggles a selection answers
                        // with `Haptics.selection()` above, and an impact on top of that is two
                        // buzzes for one tap.
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("pack-pick-\(sticker.id)")
                    }
                }
                .padding()

                if model.nextCursor != nil {
                    PosterProgress(message: String(localized: "Loading more stickers…"))
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 24)
                        .accessibilityIdentifier("sticker-picker-pagination-progress")
                        .task(id: paginationTaskID) { await model.loadMore() }
                }
            }
            .refreshable { await model.load(query: query, debounce: .zero) }
        }
    }

    private func toggle(_ sticker: Sticker) {
        if let index = selection.firstIndex(where: { $0.id == sticker.id }) {
            selection.remove(at: index)
        } else {
            selection.append(sticker)
        }
    }
}

/// A sticker as it appears in the picker grid, with its selection state.
struct PickableSticker: View {
    let sticker: Sticker
    let api: any StickerAPIClientProtocol
    let isSelected: Bool

    var body: some View {
        StickerThumbnail(sticker: sticker, api: api)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? AppColors.accent : .clear, lineWidth: 3)
            }
            .overlay(alignment: .topTrailing) {
                PosterSymbol(isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AppColors.accent : Color.secondary)
                    .padding(6)
            }
            .accessibilityLabel(sticker.title)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview {
    StickerPickerSheet(api: MockStickerAPIClient(), selection: .constant([]))
}
