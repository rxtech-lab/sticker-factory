import SwiftUI
import UIKit

private enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case `static` = "Static"
    case animated = "Animated"
    var id: Self { self }

    func matches(_ sticker: Sticker) -> Bool {
        switch self {
        case .all: true
        case .static: sticker.kind == .static
        case .animated: sticker.kind == .animated
        }
    }
}

private let libraryColumns = [GridItem(.adaptive(minimum: 156), spacing: 16)]

struct LibraryView: View {
    @Bindable var store: StickerStore
    /// Only needed so a pack section header can push that pack's detail without leaving the tab.
    @Bindable var marketplace: MarketplaceStore
    @State private var filter: LibraryFilter = .all
    @State private var showingCreation = false
    /// Set after creation so a brand-new project lands straight in its chat.
    @State private var openedStickerID: String?
    /// A pack sticker the viewer tapped. They do not own it, so it opens read-only.
    @State private var previewedSticker: Sticker?

    private var filtered: [Sticker] { store.stickers.filter(filter.matches) }

    private var packSections: [LibrarySection] {
        store.sections
            .filter { $0.kind == .pack }
            .map { section in
                var copy = section
                copy.stickers = section.stickers.filter(filter.matches)
                return copy
            }
    }

    private var hasAnything: Bool {
        !filtered.isEmpty || !packSections.isEmpty
    }

    var body: some View {
        StickerBackground {
            Group {
                if store.isLoading && store.stickers.isEmpty && store.sections.isEmpty {
                    ProgressView("Loading your library…")
                } else if !hasAnything {
                    EmptyStateView(
                        symbol: "face.smiling.inverse",
                        title: "No stickers yet",
                        message: filter == .all ? "Create a static or animated sticker to get started." : "No \(filter.rawValue.lowercased()) stickers match this filter."
                    )
                } else {
                    ScrollView {
                        // Headers scroll with their section rather than pinning. A pinned header
                        // needs an opaque backing to stay readable over the content sliding under
                        // it, and that backing is a light bar across the app's own background.
                        LazyVStack(alignment: .leading, spacing: 24) {
                            Section {
                                if filtered.isEmpty {
                                    SectionPlaceholder(message: "Nothing of yours matches this filter.")
                                } else {
                                    LazyVGrid(columns: libraryColumns, spacing: 16) {
                                        ForEach(filtered) { sticker in
                                            NavigationLink(value: sticker.id) {
                                                StickerLibraryCard(sticker: sticker, api: store.api)
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityIdentifier("library-sticker-\(sticker.id)")
                                        }
                                    }
                                    .padding(.horizontal)
                                }
                            } header: {
                                LibrarySectionHeader(title: "My Stickers", subtitle: nil, packID: nil)
                            }

                            ForEach(packSections) { section in
                                Section {
                                    if section.stickers.isEmpty {
                                        SectionPlaceholder(message: "Nothing published in this pack right now.")
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
                                        subtitle: section.creator.map { "by \($0.byline)" },
                                        packID: section.packId
                                    )
                                }
                            }
                        }
                        .padding(.vertical)
                    }
                    .refreshable { await store.refresh() }
                }
            }
        }
        .navigationTitle("Library")
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
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Create", systemImage: "wand.and.stars") {
                    Haptics.tap(.light)
                    showingCreation = true
                }
                .accessibilityIdentifier("create-sticker-button")

                Menu("Filter", systemImage: "line.3.horizontal.decrease.circle") {
                    Picker("Filter", selection: $filter) {
                        ForEach(LibraryFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
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
        .safeAreaInset(edge: .top) {
            if let error = store.errorMessage { ErrorBanner(message: error).padding(.horizontal) }
        }
        .task {
            if store.stickers.isEmpty { await store.refresh() } else { await store.refreshSections() }
        }
    }
}

/// A navigation value distinct from `String`, which the library already uses for sticker ids.
struct PackRoute: Hashable {
    let packID: String
}

private struct LibrarySectionHeader: View {
    let title: String
    let subtitle: String?
    let packID: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let packID {
                NavigationLink(value: PackRoute(packID: packID)) {
                    Label("Pack details", systemImage: "chevron.right")
                        .labelStyle(.iconOnly)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                // `.plain`, or the link picks up the default button chrome and the chevron sits
                // on a filled capsule.
                .buttonStyle(.plain)
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
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
    }
}

/// Read-only artwork for a pack member. There is no editor here by design — the sticker belongs
/// to its creator, and the viewer only has permission to look at it.
private struct PackStickerPreview: View {
    let sticker: Sticker
    let api: StickerAPIClientProtocol

    var body: some View {
        StickerBackground {
            VStack(spacing: 16) {
                StickerThumbnail(sticker: sticker, api: api)
                    .aspectRatio(1, contentMode: .fit)
                    .padding()
                Label(sticker.kind.label, systemImage: sticker.kind.symbol)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}
