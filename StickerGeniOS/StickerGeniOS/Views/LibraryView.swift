import SwiftUI
import UIKit

private enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case `static` = "Static"
    case animated = "Animated"
    var id: Self { self }
}

struct LibraryView: View {
    @Bindable var store: StickerStore
    @State private var filter: LibraryFilter = .all
    @State private var showingCreation = false
    /// Set after creation so a brand-new project lands straight in its chat.
    @State private var openedStickerID: String?

    private var filtered: [Sticker] {
        switch filter {
        case .all: store.stickers
        case .static: store.stickers.filter { $0.kind == .static }
        case .animated: store.stickers.filter { $0.kind == .animated }
        }
    }

    var body: some View {
        StickerBackground {
            Group {
                if store.isLoading && store.stickers.isEmpty {
                    ProgressView("Loading your library…")
                } else if filtered.isEmpty {
                    EmptyStateView(
                        symbol: "face.smiling.inverse",
                        title: "No stickers yet",
                        message: filter == .all ? "Create a static or animated sticker to get started." : "No \(filter.rawValue.lowercased()) stickers match this filter."
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 156), spacing: 16)], spacing: 16) {
                            ForEach(filtered) { sticker in
                                NavigationLink(value: sticker.id) {
                                    StickerLibraryCard(sticker: sticker, api: store.api)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("library-sticker-\(sticker.id)")
                            }
                        }
                        .padding()
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
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Create", systemImage: "wand.and.stars") {
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
        .safeAreaInset(edge: .top) {
            if let error = store.errorMessage { ErrorBanner(message: error).padding(.horizontal) }
        }
        .task { if store.stickers.isEmpty { await store.refresh() } }
    }
}

private struct StickerLibraryCard: View {
    let sticker: Sticker
    let api: StickerAPIClientProtocol

    var body: some View {
        GlassCard(padding: 10) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.purple.opacity(0.12).gradient)
                    if let assetID = sticker.previewAsset?.id ?? sticker.systemSticker?.assetId {
                        VerifiedAssetImage(assetID: assetID, expectedSHA256: sticker.previewAsset?.sha256 ?? sticker.systemSticker?.sha256, api: api)
                    } else {
                        Image(systemName: sticker.kind.symbol)
                            .font(.system(size: 42, weight: .medium))
                            .foregroundStyle(.purple)
                    }
                }
                .aspectRatio(1, contentMode: .fit)

                Text(sticker.title)
                    .font(.headline)
                    .lineLimit(1)
                HStack {
                    Label(sticker.kind.label, systemImage: sticker.kind.symbol)
                    Spacer()
                    if sticker.status == .draft { Text("Draft") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct VerifiedAssetImage: View {
    let assetID: String
    let expectedSHA256: String?
    let api: StickerAPIClientProtocol
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView()
            }
        }
        .task(id: assetID) {
            guard image == nil else { return }
            image = try? await StickerImageCache.load(
                assetID: assetID,
                expectedSHA256: expectedSHA256,
                api: api
            ).image
        }
    }
}
