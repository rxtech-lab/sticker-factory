import SwiftUI

/// Every pack by one creator, reached by tapping their byline.
struct CreatorPacksView: View {
    @Bindable var store: MarketplaceStore
    let handle: String

    private var response: CreatorPacksResponse? { store.creators[handle] }

    var body: some View {
        StickerBackground {
            ScrollView {
                if let response {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(response.creator.isSelf ? "Your packs" : response.creator.displayName)
                                .font(.title2.weight(.bold))
                            Text("@\(response.creator.handle)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if let bio = response.creator.bio, !bio.isEmpty {
                                Text(bio).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if response.items.isEmpty {
                            EmptyStateView(
                                title: String(localized: "No packs yet"),
                                message: response.creator.isSelf
                                    ? String(localized: "Publish a pack and it will appear here.")
                                    : String(localized: "This creator has not published anything yet.")
                            )
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 156), spacing: 16)], spacing: 16) {
                                ForEach(response.items) { pack in
                                    NavigationLink(value: PackRoute(packID: pack.id)) {
                                        PackCard(pack: pack, api: store.api)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("creator-pack-\(pack.id)")
                                }
                            }
                        }
                    }
                    .padding()
                } else {
                    PosterProgress(message: String(localized: "Loading creator…")).padding(.top, 64)
                }
            }
        }
        .navigationTitle(response?.creator.displayName ?? String(localized: "Creator"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: handle) { await store.loadCreator(handle: handle) }
    }
}

#Preview {
    NavigationStack {
        CreatorPacksView(store: MarketplaceStore(api: MockStickerAPIClient()), handle: PreviewFixtures.creator.handle)
    }
}
