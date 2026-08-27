import SwiftUI

struct PackDetailView: View {
    @Bindable var store: MarketplaceStore
    let packID: String
    @State private var isWorking = false
    @State private var previewedSticker: Sticker?

    private var detail: StickerPackDetail? { store.details[packID] }

    var body: some View {
        StickerBackground {
            ScrollView {
                if let detail {
                    VStack(alignment: .leading, spacing: 20) {
                        header(detail)
                        installControl(detail)
                        members(detail)
                    }
                    .padding()
                } else {
                    ProgressView("Loading pack…").padding(.top, 64)
                }
            }
        }
        .navigationTitle(detail?.title ?? "Pack")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $previewedSticker) { sticker in
            NavigationStack {
                StickerBackground {
                    StickerThumbnail(sticker: sticker, api: store.api)
                        .aspectRatio(1, contentMode: .fit)
                        .padding()
                }
                .navigationTitle(sticker.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { previewedSticker = nil }
                    }
                }
            }
        }
        .task(id: packID) { await store.loadDetail(packID: packID) }
    }

    @ViewBuilder
    private func header(_ detail: StickerPackDetail) -> some View {
        PackCover(stickers: detail.coverStickers, api: store.api)
            .frame(maxWidth: 240)
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)

        VStack(alignment: .leading, spacing: 8) {
            Text(detail.title).font(.title2.weight(.bold))
            if let summary = detail.summary, !summary.isEmpty {
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
            }
            NavigationLink(value: CreatorRoute(handle: detail.creator.handle)) {
                Label("by \(detail.creator.byline)", systemImage: "person.crop.circle")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.accent)
            }
            // `.plain`, or the byline picks up the default button chrome and sits on a filled
            // capsule instead of reading as a line of text you can tap.
            .buttonStyle(.plain)
            .accessibilityIdentifier("pack-creator-button")

            // The count of people who added this pack — the marketplace's only social signal.
            Label(detail.installCountLabel, systemImage: "square.and.arrow.down")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("pack-install-count")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func installControl(_ detail: StickerPackDetail) -> some View {
        if detail.isMine {
            // Self-install is refused server-side: the creator's stickers are already in their own
            // section, so adding the pack would duplicate every one of them.
            Label("You created this pack", systemImage: "checkmark.seal")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Button {
                Haptics.tap(.light)
                Task {
                    isWorking = true
                    defer { isWorking = false }
                    await store.setInstalled(!detail.installed, packID: detail.id)
                    // `setInstalled` rolls its optimistic change back and parks the reason in
                    // `errorMessage` rather than throwing, so that is what says how it went.
                    if store.errorMessage == nil { Haptics.success() } else { Haptics.failure() }
                }
            } label: {
                Label(
                    detail.installed ? "Remove from library" : "Add to library",
                    systemImage: detail.installed ? "trash" : "plus"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(detail.installed ? Color.secondary : AppColors.accent)
            .disabled(isWorking)
            .accessibilityIdentifier("pack-install-button")
        }
    }

    @ViewBuilder
    private func members(_ detail: StickerPackDetail) -> some View {
        if detail.stickers.isEmpty {
            EmptyStateView(
                symbol: "square.stack.3d.up",
                title: "Nothing published right now",
                message: "The creator is still working on it. Anything they publish shows up here automatically."
            )
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 12) {
                ForEach(detail.stickers) { sticker in
                    Button { previewedSticker = sticker } label: {
                        StickerThumbnail(sticker: sticker, api: store.api)
                            .aspectRatio(1, contentMode: .fit)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("pack-sticker-\(sticker.id)")
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        PackDetailView(store: MarketplaceStore(api: MockStickerAPIClient()), packID: PreviewFixtures.pack.id)
    }
}
