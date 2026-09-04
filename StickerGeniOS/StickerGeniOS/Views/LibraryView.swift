import SwiftUI
import TipKit
import UIKit

private enum LibraryFilter: String, CaseIterable, Identifiable {
    case all
    case `static`
    case animated
    var id: Self { self }

    var label: String {
        switch self {
        case .all: String(localized: "All")
        case .static: String(localized: "Static")
        case .animated: String(localized: "Animated")
        }
    }

    func matches(_ sticker: Sticker) -> Bool {
        switch self {
        case .all: true
        case .static: sticker.kind == .static
        case .animated: sticker.kind == .animated
        }
    }
}

private let libraryColumns = [GridItem(.adaptive(minimum: 156), spacing: 16)]

/// A library edit that is waiting on the server. Both rewrite the grid underneath, so the list is
/// covered while one runs rather than left tappable against soon-to-be-stale rows.
private enum LibraryPendingEdit {
    case renaming
    case deleting

    var message: String {
        switch self {
        case .renaming: String(localized: "Renaming…")
        case .deleting: String(localized: "Deleting…")
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .renaming: "library-rename-progress"
        case .deleting: "library-delete-progress"
        }
    }
}

struct LibraryView: View {
    @Bindable var store: StickerStore
    /// Only needed so a pack section header can push that pack's detail without leaving the tab.
    @Bindable var marketplace: MarketplaceStore
    /// Defaulted so previews and tests keep working; an unconfigured store shows no chip.
    @Bindable var subscription: SubscriptionStore = .init()
    @State private var filter: LibraryFilter = .all
    @State private var searchText = ""
    @State private var showingCreation = false
    /// Set after creation so a brand-new project lands straight in its chat.
    @State private var openedStickerID: String?
    /// A pack sticker the viewer tapped. They do not own it, so it opens read-only.
    @State private var previewedSticker: Sticker?
    @State private var renamingSticker: Sticker?
    @State private var renameTitle = ""
    @State private var showingRename = false
    @State private var deletionCandidate: Sticker?
    @State private var confirmingDelete = false
    @State private var pendingEdit: LibraryPendingEdit?
    private let generateTip = GenerateStickerTip()

    private var isRenaming: Binding<Bool> {
        Binding(
            get: { pendingEdit == .renaming },
            set: { pendingEdit = $0 ? .renaming : nil }
        )
    }

    private var isShowingError: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )
    }

    private var normalizedSearchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearchActive: Bool { !normalizedSearchQuery.isEmpty }

    private var filtered: [Sticker] {
        let stickers = isSearchActive ? store.librarySearchResults : store.stickers
        return stickers.filter(filter.matches)
    }

    private var packSections: [LibrarySection] {
        let sections = isSearchActive ? store.librarySearchSections : store.sections
        return sections
            .filter { $0.kind == .pack }
            .compactMap { section in
                var copy = section
                copy.stickers = section.stickers.filter(filter.matches)
                return !isSearchActive || !copy.stickers.isEmpty ? copy : nil
            }
    }

    private var nextStickerCursor: String? {
        isSearchActive ? store.nextLibrarySearchCursor : store.nextStickerCursor
    }

    private var paginationTaskID: String? {
        nextStickerCursor.map { "\(isSearchActive ? "search:\(normalizedSearchQuery)" : "library"):\($0)" }
    }

    private var hasAnything: Bool {
        !filtered.isEmpty || !packSections.isEmpty || nextStickerCursor != nil
    }

    var body: some View {
        StickerBackground {
            Group {
                if !isSearchActive && store.isLoading && store.stickers.isEmpty && store.sections.isEmpty {
                    PosterProgress(message: String(localized: "Loading your library…"))
                } else if isSearchActive && store.isSearchingLibrary && !hasAnything {
                    Color.clear
                } else if !hasAnything {
                    EmptyStateView(
                        title: isSearchActive
                            ? String(localized: "No matching stickers")
                            : String(localized: "No stickers yet"),
                        message: isSearchActive
                            ? String(localized: "Try a different search or filter.")
                            : filter == .all
                            ? String(localized: "Create a static or animated sticker to get started.")
                            : String(localized: "No \(filter.label.lowercased()) stickers match this filter.")
                    )
                } else {
                    ScrollView {
                        // Headers scroll with their section rather than pinning. A pinned header
                        // needs an opaque backing to stay readable over the content sliding under
                        // it, and that backing is a light bar across the app's own background.
                        LazyVStack(alignment: .leading, spacing: 24) {
                            if !isSearchActive || !filtered.isEmpty {
                                Section {
                                    if filtered.isEmpty {
                                        SectionPlaceholder(message: String(localized: "Nothing of yours matches this filter."))
                                    } else {
                                        LazyVGrid(columns: libraryColumns, spacing: 16) {
                                            ForEach(filtered) { sticker in
                                                NavigationLink(value: sticker.id) {
                                                    StickerLibraryCard(sticker: sticker, api: store.api)
                                                }
                                                .buttonStyle(.plain)
                                                .accessibilityIdentifier("library-sticker-\(sticker.id)")
                                                .contextMenu {
                                                    Button {
                                                        renamingSticker = sticker
                                                        renameTitle = sticker.title
                                                        showingRename = true
                                                    } label: {
                                                        PosterMenuLabel("Rename", icon: .rename)
                                                    }
                                                    .accessibilityIdentifier("rename-library-sticker-\(sticker.id)")

                                                    Button(role: .destructive) {
                                                        deletionCandidate = sticker
                                                        confirmingDelete = true
                                                    } label: {
                                                        PosterMenuLabel("Delete", icon: .delete)
                                                    }
                                                    .accessibilityIdentifier("delete-library-sticker-\(sticker.id)")
                                                }
                                            }
                                        }
                                        .padding(.horizontal)
                                    }
                                } header: {
                                    LibrarySectionHeader(title: String(localized: "My Stickers"), subtitle: nil, packID: nil)
                                }
                            }

                            if nextStickerCursor != nil {
                                PosterProgress(message: String(localized: "Loading more stickers…"))
                                    .frame(maxWidth: .infinity)
                                    .padding(.bottom, 8)
                                    .accessibilityIdentifier("library-pagination-progress")
                                    .task(id: paginationTaskID) {
                                        if isSearchActive {
                                            await store.loadMoreLibrarySearchResults()
                                        } else {
                                            await store.loadMoreStickers()
                                        }
                                    }
                            }

                            ForEach(packSections) { section in
                                Section {
                                    if section.stickers.isEmpty {
                                        SectionPlaceholder(message: String(localized: "Nothing published in this pack right now."))
                                    } else {
                                        LazyVGrid(columns: libraryColumns, spacing: 16) {
                                            ForEach(section.stickers) { sticker in
                                                // Deliberately not a NavigationLink into the chat:
                                                // the viewer does not own this sticker, so fetching
                                                // its detail would 404. Tapping previews it instead.
                                                Button {
                                                    previewedSticker = sticker
                                                } label: {
                                                    StickerLibraryCard(sticker: sticker, api: store.api, showsStatus: false)
                                                }
                                                .buttonStyle(.plain)
                                                .accessibilityIdentifier("library-pack-sticker-\(sticker.id)")
                                            }
                                        }
                                        .padding(.horizontal)
                                    }
                                } header: {
                                    LibrarySectionHeader(
                                        title: section.title,
                                        subtitle: section.creator.map { String(localized: "by \($0.byline)") },
                                        packID: section.packId
                                    )
                                }
                            }
                        }
                        .padding(.vertical)
                    }
                    .refreshable {
                        if isSearchActive {
                            await store.searchLibrary(query: searchText, debounce: .zero)
                        } else {
                            await store.refresh()
                        }
                    }
                }
            }
        }
        .navigationTitle("Library")
        .searchable(text: $searchText, prompt: "Search stickers")
        .overlay {
            if isSearchActive && store.isSearchingLibrary {
                PosterProgress(message: String(localized: "Searching…"))
                    .accessibilityIdentifier("library-search-progress")
            }
        }
        .overlay {
            if let pendingEdit {
                ZStack {
                    // Also swallows taps: the rows underneath are about to be renamed or removed.
                    AppColors.ink.opacity(0.18).ignoresSafeArea()
                    PosterProgress(message: pendingEdit.message)
                }
                .accessibilityIdentifier(pendingEdit.accessibilityIdentifier)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: pendingEdit)
        .navigationDestination(for: String.self) { id in
            StickerChatView(store: store, stickerID: id)
        }
        .navigationDestination(item: $openedStickerID) { id in
            StickerChatView(store: store, stickerID: id)
        }
        .navigationDestination(for: PackRoute.self) { route in
            PackDetailView(store: marketplace, packID: route.packID)
        }
        .navigationDestination(for: CreatorRoute.self) { route in
            CreatorPacksView(store: marketplace, handle: route.handle)
        }
        .toolbar {
            if subscription.isReady {
                ToolbarItem(placement: .topBarLeading) {
                    CreditsChip(subscription: subscription)
                }
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    generateTip.invalidate(reason: .actionPerformed)
                    Haptics.tap(.light)
                    showingCreation = true
                } label: {
                    PosterToolbarIcon(glyph: .create)
                }
                .accessibilityLabel("Create")
                .popoverTip(generateTip, arrowEdge: .top)
                .accessibilityIdentifier("create-sticker-button")

                Menu {
                    Picker("Filter", selection: $filter) {
                        ForEach(LibraryFilter.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    PosterToolbarIcon(glyph: .filter)
                }
                .accessibilityLabel("Filter")
                .accessibilityIdentifier("library-filter-menu")
            }
        }
        .sheet(isPresented: $showingCreation) {
            NavigationStack {
                CreateStickerView(store: store, onCreated: { sticker in
                    showingCreation = false
                    openedStickerID = sticker.id
                })
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { showingCreation = false }
                            .accessibilityIdentifier("dismiss-create-button")
                    }
                }
            }
            .interactiveDismissDisabled()
        }
        .sheet(item: $previewedSticker) { sticker in
            NavigationStack {
                PackStickerPreview(sticker: sticker, api: store.api)
                    .navigationTitle(sticker.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { previewedSticker = nil }
                        }
                    }
            }
        }
        .stickerRenameAlert(
            store: store,
            stickerID: renamingSticker?.id ?? "",
            currentTitle: renamingSticker?.title ?? "",
            isPresented: $showingRename,
            title: $renameTitle,
            isRenaming: isRenaming
        )
        .confirmationDialog(
            "Delete this sticker project?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible,
            presenting: deletionCandidate
        ) { sticker in
            Button("Delete “\(sticker.title)”", role: .destructive) {
                Haptics.tap(.heavy)
                Task {
                    pendingEdit = .deleting
                    defer { pendingEdit = nil }
                    if await store.delete(stickerID: sticker.id) {
                        Haptics.success()
                    } else {
                        Haptics.failure()
                    }
                    deletionCandidate = nil
                }
            }
            Button("Cancel", role: .cancel) { deletionCandidate = nil }
        } message: { _ in
            Text("Deletion starts a durable purge of the private source images, transcript, revisions, and exports.")
        }
        .alert("Couldn’t Complete Action", isPresented: isShowingError) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .task {
            if store.stickers.isEmpty { await store.refresh() } else { await store.refreshSections() }
        }
        .task(id: searchText) {
            await store.searchLibrary(query: searchText)
        }
    }
}

/// A navigation value distinct from `String`, which the library already uses for sticker ids.
struct PackRoute: Hashable {
    let packID: String
}

/// The credit balance, where a user is about to spend some.
///
/// Sits next to Create on purpose: running out is something to notice before starting a sticker,
/// not after describing one. Tapping it opens the paywall, so topping up never requires hitting a
/// wall first.
private struct CreditsChip: View {
    @Bindable var subscription: SubscriptionStore

    var body: some View {
        Button {
            Haptics.tap(.light)
            subscription.presentPaywall()
        } label: {
            // Deliberately *not* a poster capsule. A toolbar item's content is composited
            // inside the bar's Liquid Glass, which blends whatever colour it is given with the
            // backdrop — a flat lime pill came out olive, and hiding the glass to stop that
            // only moved the problem. The bar's own capsule is the button here, the same as the
            // two controls opposite it, and the chip just fills it.
            HStack(spacing: 4) {
                PosterToolbarIcon(glyph: .credits, size: 17)
                if let credits = subscription.credits {
                    Text(credits, format: .number).monospacedDigit()
                } else {
                    Text("—")
                }
            }
            .font(.posterDisplay(14, weight: .heavy))
        }
        .tint(AppColors.accent)
        .accessibilityLabel(
            subscription.credits.map { String(localized: "\($0) credits. Tap to top up.") }
                ?? String(localized: "Credits. Tap to top up.")
        )
        .accessibilityIdentifier("credits-chip")
    }
}

private struct LibrarySectionHeader: View {
    let title: String
    let subtitle: String?
    let packID: String?

    var body: some View {
        PosterSectionHeader(
            title: title,
            subtitle: subtitle,
            // A pack borrowed from someone else is marked in sky; the user's own work in lime.
            highlight: packID == nil ? AppColors.lime : AppColors.sky
        ) {
            if let packID {
                NavigationLink(value: PackRoute(packID: packID)) {
                    PosterSymbol("chevron.right")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(AppColors.ink)
                        .frame(width: 30, height: 30)
                        .posterSurface(
                            cornerRadius: 15,
                            lineWidth: Poster.hairline,
                            offset: Poster.noShadow
                        )
                }
                // `.plain`, or the link picks up the default button chrome and the chevron sits
                // on a filled capsule.
                .buttonStyle(.plain)
                .accessibilityLabel("Pack details")
                .accessibilityIdentifier("library-pack-header-\(packID)")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

private struct SectionPlaceholder: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(AppColors.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
    }
}

/// Read-only artwork for a pack member. There is no editor here by design — the sticker belongs
/// to its creator, and the viewer only has permission to look at it.
///
/// Shared with the marketplace's pack detail, which presents a borrowed sticker on the same terms.
struct PackStickerPreview: View {
    let sticker: Sticker
    let api: StickerAPIClientProtocol

    var body: some View {
        StickerBackground {
            VStack(spacing: 16) {
                // `.preview`: one sticker filling a sheet can afford frames at twice the size a
                // grid tile decodes them at.
                StickerThumbnail(sticker: sticker, api: api, detail: .preview)
                    .aspectRatio(1, contentMode: .fit)
                    .padding(18)
                    .posterSurface(cornerRadius: Poster.cardRadius, fill: AppColors.paper)
                    .padding(20)
                Text(sticker.kind.label)
                    .posterLabelStyle(10, color: AppColors.muted)
                Spacer()
            }
        }
    }
}
