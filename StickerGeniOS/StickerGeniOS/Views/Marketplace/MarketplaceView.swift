import SwiftUI

private enum MarketplaceTab: String, CaseIterable, Identifiable {
    case browse
    case mine
    var id: Self { self }

    var label: String {
        switch self {
        case .browse: String(localized: "Browse")
        case .mine: String(localized: "My packs")
        }
    }
}

/// The Sticker Packs tab: packs to browse, the user's own, and the way into any one of them.
///
/// Every pack here is also the unit a messenger receives — `PackDetailView` sends one to WhatsApp
/// or Telegram — which is why a freshly created pack is pushed straight onto the stack: the next
/// thing to do with it is on that screen.
struct MarketplaceView: View {
    @Bindable var store: MarketplaceStore
    @State private var tab: MarketplaceTab = .browse
    @State private var showingComposer = false
    @State private var path = NavigationPath()
    /// The pack the composer just made, pushed once its sheet has gone: pushing while a sheet is
    /// still dismissing drops one of the two animations.
    @State private var createdPackID: String?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var visible: [StickerPack] {
        tab == .mine ? store.myPacks : store.packs
    }

    /// Fixed columns rather than adaptive ones: adaptive sizing leaves the row's leftover width as a
    /// gap, which is what made the tiles look mismatched and stranded short of the screen edge.
    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 16),
            count: horizontalSizeClass == .regular ? 3 : 2
        )
    }

    private var nextCursor: String? {
        tab == .mine ? store.nextMyPacksCursor : store.nextCursor
    }

    /// Re-arms the sentinel for every cursor: keyed on the view alone it would fire once and the
    /// feed would stop after two pages.
    private var paginationTaskID: String? {
        nextCursor.map { "\(tab.rawValue):\($0)" }
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
        }
        .telemetryScreen("marketplace")
    }

    private var content: some View {
        StickerBackground {
            Group {
                if store.isLoading && visible.isEmpty {
                    PosterProgress(message: String(localized: "Loading packs…"))
                } else if visible.isEmpty {
                    // Keyed on `appliedQuery`, never the live search text: the two disagree while a
                    // search is being typed or has just been dismissed, and the results on screen
                    // belong to the applied one.
                    EmptyStateView(
                        title: store.appliedQuery.isEmpty
                            ? (tab == .mine
                                ? String(localized: "No packs yet")
                                : String(localized: "Nothing here yet"))
                            : String(localized: "No matching packs"),
                        message: store.appliedQuery.isEmpty
                            ? (tab == .mine
                                ? String(localized: "Bundle stickers you have published and share them with everyone.")
                                : String(localized: "Be the first to publish a sticker pack."))
                            : String(localized: "No packs match “\(store.appliedQuery)”.")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(visible) { pack in
                                NavigationLink(value: PackRoute(packID: pack.id)) {
                                    PackCard(pack: pack, api: store.api)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                                .buttonStyle(.posterPlain)
                                .accessibilityIdentifier("marketplace-pack-\(pack.id)")
                            }
                        }
                        .padding()

                        if nextCursor != nil {
                            PosterProgress(message: String(localized: "Loading more packs…"))
                                .frame(maxWidth: .infinity)
                                .padding(.bottom, 24)
                                .accessibilityIdentifier("marketplace-pagination-progress")
                                .task(id: paginationTaskID) {
                                    if tab == .mine {
                                        await store.loadMoreMyPacks()
                                    } else {
                                        await store.loadMore()
                                    }
                                }
                        }
                    }
                    .refreshable { await store.refresh() }
                }
            }
        }
        .navigationTitle("Sticker Packs")
        .navigationDestination(for: PackRoute.self) { route in
            PackDetailView(store: store, packID: route.packID)
        }
        .navigationDestination(for: CreatorRoute.self) { route in
            CreatorPacksView(store: store, handle: route.handle)
        }
        .searchable(text: $store.searchQuery, prompt: "Search packs")
        // Both tabs search: the query goes to browse and to the authoring list in the same reload,
        // so switching tabs mid-search shows that tab's matches rather than its whole contents.
        .onChange(of: store.searchQuery) { store.searchQueryChanged() }
        .onSubmit(of: .search) { Task { await store.refresh() } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.tap(.light)
                    showingComposer = true
                } label: {
                    PosterToolbarIcon(glyph: .add)
                }
                    .accessibilityLabel("New pack")
                    .accessibilityIdentifier("create-pack-button")
            }
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: $tab) {
                    ForEach(MarketplaceTab.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("marketplace-tab-picker")
            }
        }
        .toolbar {
            if tab == .browse {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Sort", selection: $store.sort) {
                            Text("Newest").tag(PackSort.recent)
                            Text("Popular").tag(PackSort.popular)
                        }
                    } label: {
                        PosterToolbarIcon(glyph: .sort)
                    }
                    .accessibilityLabel("Sort")
                    .accessibilityIdentifier("marketplace-sort-menu")
                }
            }
        }
        // Both live in UIKit menus and segmented controls, which the app's button styles never
        // reach. Watching the values catches them wherever they are changed from.
        .onChange(of: tab) { Haptics.selection() }
        .onChange(of: store.sort) {
            Haptics.selection()
            Task { await store.refresh() }
        }
        .sheet(isPresented: $showingComposer, onDismiss: {
            guard let createdPackID else { return }
            self.createdPackID = nil
            path.append(PackRoute(packID: createdPackID))
        }, content: {
            NavigationStack {
                PackComposerView(store: store, onCreated: { detail in
                    createdPackID = detail.id
                    showingComposer = false
                })
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") {
                                Haptics.tap(.light)
                                showingComposer = false
                            }
                        }
                    }
            }
        })
        .safeAreaInset(edge: .top) {
            if let error = store.errorMessage { ErrorBanner(message: error).padding(.horizontal) }
        }
        .task { if store.packs.isEmpty { await store.refresh() } }
    }
}

struct CreatorRoute: Hashable {
    let handle: String
}

#Preview {
    NavigationStack {
        MarketplaceView(store: MarketplaceStore(api: MockStickerAPIClient()))
    }
}
