import SwiftUI

/// What the owner can do with the pet right now: the actions its agent offers for its mood, and the
/// four objects it chose from its world. Picking one closes the sheet; the pet answers on the tab.
/// The Rooms tab is where the owner buys the pet a room to live in, and moves it between them; the
/// Places tab is where the owner takes it to the places its agent discovered, or brings it home.
struct PetActionsSheet: View {
    @Bindable var model: PetModel
    @Environment(\.dismiss) private var dismiss

    private enum Tab: Hashable, CaseIterable {
        case actions
        case items
        case rooms
        case places

        var title: LocalizedStringKey {
            switch self {
            case .actions: "Actions"
            case .items: "Items"
            case .rooms: "Rooms"
            case .places: "Places"
            }
        }
    }
    @State private var selectedTab: Tab = .actions
    @State private var itemImages: [Int: UIImage] = [:]
    @State private var loadedArtKey: String?
    @State private var presentedRoom: PresentedRoom?
    @State private var presentedTheme: PresentedTheme?

    /// A place opened from the Places tab, with the thumbnail it showed there.
    private struct PresentedTheme: Identifiable {
        let theme: PetTheme
        let preview: UIImage?
        var id: String { theme.id }
    }

    /// A room opened from the Rooms tab, with the thumbnail it showed there.
    private struct PresentedRoom: Identifiable {
        let room: PetRoom
        let preview: UIImage?
        var id: String { room.id }
    }

    private var actions: [PetAction] { model.pet?.actions ?? [] }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Spend time", selection: $selectedTab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab.title).tag(tab)
                        .accessibilityIdentifier("pet-sheet-tab-\(tab)")
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 12)
                .onChange(of: selectedTab) { _, _ in Haptics.tap(.light) }
                ScrollView {
                    switch selectedTab {
                    case .actions: actionList
                    case .items: itemList
                    case .rooms:
                        PetRoomsList(model: model) { room, preview in
                            presentedRoom = PresentedRoom(room: room, preview: preview)
                        }
                    case .places:
                        PetThemesList(model: model) { theme, preview in
                            presentedTheme = PresentedTheme(theme: theme, preview: preview)
                        }
                    }
                }
            }
            .task(id: selectedTab) {
                guard selectedTab == .items else { return }
                while !Task.isCancelled {
                    guard !Task.isCancelled else { return }
                    await model.refreshItems()
                    if let items = model.pet?.items {
                        await loadImages(for: items)
                        if itemImages.count == items.actions.count { return }
                    }
                    try? await Task.sleep(for: .seconds(10))
                }
            }
            .navigationTitle("Spend Time Together")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    PetGoldBadge(gold: model.pet?.stats.gold ?? 0)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { Haptics.tap(.light); dismiss() }
                        .disabled(model.activity != nil)
                }
            }
            .safeAreaInset(edge: .top) {
                if let errorMessage = model.errorMessage {
                    ErrorBanner(message: errorMessage).padding(.horizontal)
                }
            }
        }
        .overlay {
            if let activity = model.activity { PetActivityOverlay(activity: activity) }
        }
        .animation(.snappy(duration: 0.2), value: model.activity)
        .interactiveDismissDisabled(model.activity != nil)
        // Presented from here rather than from the Rooms tab: a sheet hosted inside the tab's
        // ScrollView lost its confirmation's action on iOS 27, so buying a room did nothing.
        .sheet(item: $presentedRoom) { presented in
            PetRoomDetailSheet(model: model, roomID: presented.room.id, preview: presented.preview)
        }
        .sheet(item: $presentedTheme) { presented in
            PetThemeDetailSheet(model: model, themeID: presented.theme.id, preview: presented.preview)
        }
    }

    private var actionList: some View {
        VStack(alignment: .leading, spacing: 16) {
                    Text("Your pet picks these for how they feel right now. They change as their mood does.")
                        .foregroundStyle(AppColors.muted)
                    if actions.isEmpty {
                        Text("Your pet is still thinking of something to do. Check back in a moment.")
                            .font(.footnote)
                            .foregroundStyle(AppColors.muted)
                    }
                    ForEach(actions) { action in
                        let affordable = model.canAfford(action)
                        Button {
                            Haptics.tap(.light)
                            // The reply arrives on the tab, in the pet's dialogue box.
                            if model.interact(action) { dismiss() }
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(action.title)
                                    if action.effects.gold != 0 {
                                        PetGoldChip(change: action.effects.gold)
                                    }
                                    if !affordable {
                                        Text("Needs \(action.effects.price) gold")
                                            .font(.caption)
                                            .foregroundStyle(AppColors.muted)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                // The pill has no vertical padding of its own; a second line
                                // would otherwise run into its rounded edges.
                                .padding(.vertical, action.effects.gold != 0 || !affordable ? 12 : 0)
                            } icon: {
                                Image(systemName: "sparkles")
                            }
                        }
                        .buttonStyle(.posterSecondary)
                        .disabled(model.activity != nil || model.isAnswering || !affordable)
                        .accessibilityIdentifier("pet-action-\(action.id)")
                    }
        }
        .padding()
    }

    private var itemList: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Objects your pet chose from its world today.")
                .foregroundStyle(AppColors.muted)
            if let items = model.pet?.items {
                ForEach(Array(items.actions.enumerated()), id: \.element.id) { index, item in
                    let affordable = model.canAfford(item)
                    Button {
                        Haptics.tap(.light)
                        let image = loadedArtKey == items.artKey ? itemImages[index] : nil
                        if model.useItem(at: index, image: image) { dismiss() }
                    } label: {
                        HStack(spacing: 14) {
                            if loadedArtKey == items.artKey, let image = itemImages[index] {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 72, height: 72)
                                    .accessibilityHidden(true)
                            } else {
                                Image(systemName: "shippingbox")
                                    .frame(width: 72, height: 72)
                                    .accessibilityHidden(true)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).font(.headline)
                                Text(item.description).font(.caption).foregroundStyle(AppColors.muted)
                                // The set's pricey tonic: what it costs is only worth it for this.
                                if item.effects.energy > 0 {
                                    Label("Restores \(item.effects.energy) energy", systemImage: "bolt.fill")
                                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.orange)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.orange.opacity(0.14), in: .capsule)
                                }
                                if item.effects.gold != 0 { PetGoldChip(change: item.effects.gold) }
                                if !affordable {
                                    Text("Needs \(item.effects.price) gold")
                                        .font(.caption).foregroundStyle(AppColors.muted)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.posterCard)
                    .disabled(model.activity != nil || model.isAnswering || !affordable)
                    .accessibilityIdentifier("pet-item-\(index)")
                }
            } else {
                VStack(spacing: 16) {
                    Image("PetItemsLoading")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 160, height: 160)
                        .accessibilityHidden(true)
                    ProgressView("Your pet is choosing and drawing some things…")
                }
                .frame(maxWidth: .infinity, minHeight: 240)
            }
        }
        .padding()
    }

    private func loadImages(for items: PetItems) async {
        if loadedArtKey != items.artKey {
            loadedArtKey = items.artKey
            itemImages = [:]
        }
        for index in items.actions.indices where itemImages[index] == nil {
            guard !Task.isCancelled else { return }
            if let image = try? await PetArtworkImageCache.shared.load(
                artKey: items.artKey, index: index, size: 256, api: model.api
            ), !Task.isCancelled, model.pet?.items?.artKey == items.artKey {
                itemImages[index] = image
            }
        }
    }
}
