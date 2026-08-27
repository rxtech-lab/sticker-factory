import SwiftUI

private enum MarketplaceTab: String, CaseIterable, Identifiable {
    case browse = "Browse"
    case mine = "My packs"
    var id: Self { self }
}

struct MarketplaceView: View {
    @Bindable var store: MarketplaceStore
    /// The library store, so the composer can offer this user's published stickers.
    @Bindable var library: StickerStore
    @State private var tab: MarketplaceTab = .browse
    @State private var showingComposer = false

    private var visible: [StickerPack] {
        tab == .mine ? store.myPacks : store.packs
    }

    var body: some View {
        StickerBackground {
            Group {
                if store.isLoading && visible.isEmpty {
                    ProgressView("Loading packs…")
                } else if visible.isEmpty {
                    EmptyStateView(
                        symbol: "square.stack.3d.up",
                        title: tab == .mine ? "No packs yet" : "Nothing here yet",
                        message: tab == .mine
                            ? "Bundle stickers you have published and share them with everyone."
                            : store.searchQuery.isEmpty
                                ? "Be the first to publish a sticker pack."
                                : "No packs match “\(store.searchQuery)”."
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 156), spacing: 16)], spacing: 16) {
                            ForEach(visible) { pack in
                                NavigationLink(value: PackRoute(packID: pack.id)) {
                                    PackCard(pack: pack, api: store.api)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("marketplace-pack-\(pack.id)")
                            }
                        }
                        .padding()

                        if tab == .browse && store.nextCursor != nil {
                            ProgressView()
                                .padding(.bottom, 24)
                                .task { await store.loadMore() }
                        }
                    }
                    .refreshable { await store.refresh() }
                }
            }
        }
        .navigationTitle("Marketplace")
        .navigationDestination(for: PackRoute.self) { route in
            PackDetailView(store: store, packID: route.packID)
        }
        .navigationDestination(for: CreatorRoute.self) { route in
            CreatorPacksView(store: store, handle: route.handle)
        }
        .searchable(text: $store.searchQuery, prompt: "Search packs")
        .onSubmit(of: .search) { Task { await store.refresh() } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New pack", systemImage: "plus") { showingComposer = true }
                    .accessibilityIdentifier("create-pack-button")
            }
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: $tab) {
                    ForEach(MarketplaceTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("marketplace-tab-picker")
            }
        }
        .toolbar {
            if tab == .browse {
                ToolbarItem(placement: .topBarLeading) {
                    Menu("Sort", systemImage: "arrow.up.arrow.down") {
                        Picker("Sort", selection: $store.sort) {
                            Text("Newest").tag(PackSort.recent)
                            Text("Popular").tag(PackSort.popular)
                        }
                    }
                    .accessibilityIdentifier("marketplace-sort-menu")
                }
            }
        }
        .onChange(of: store.sort) { Task { await store.refresh() } }
        .sheet(isPresented: $showingComposer) {
            NavigationStack {
                PackComposerView(store: store, library: library, onCreated: { showingComposer = false })
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showingComposer = false }
                        }
                    }
            }
        }
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
        MarketplaceView(
            store: MarketplaceStore(api: MockStickerAPIClient()),
            library: StickerStore(api: MockStickerAPIClient())
        )
    }
}
