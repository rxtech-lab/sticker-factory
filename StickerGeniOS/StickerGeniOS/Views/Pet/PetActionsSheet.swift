import SwiftUI

/// What the owner can do with the pet right now: the actions its agent offers for its mood, and the
/// store — objects it chose from its world, each leaving the shelf in its own time, and medicine.
/// The bag of things bought to use later opens in its own sheet from the toolbar. Using anything
/// closes the sheet; the pet answers on the tab.
/// The Rooms tab is where the owner buys the pet a room to live in, and moves it between them; the
/// Places tab is where the owner takes it to the places its agent discovered, or brings it home.
struct PetActionsSheet: View {
    @Bindable var model: PetModel
    @Environment(\.dismiss) private var dismiss

    private enum Tab: Hashable, CaseIterable {
        case actions
        case store
        case rooms
        case places

        var title: LocalizedStringKey {
            switch self {
            case .actions: "Actions"
            case .store: "Store"
            case .rooms: "Rooms"
            case .places: "Places"
            }
        }
    }
    @State private var selectedTab: Tab = .actions
    @State private var presentedRoom: PresentedRoom?
    @State private var presentedTheme: PresentedTheme?
    /// An item tapped in the shop, waiting on whether to use it now or keep it in the bag.
    @State private var itemChoice: PetAction?
    @State private var itemDetails: PetAction?
    @State private var confirmingMedicine = false
    @State private var showingBag = false

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

    /// Everything in the bag: doses of medicine and each bought item.
    private var bagCount: Int {
        guard let pet = model.pet else { return 0 }
        return pet.medicine + pet.bag.reduce(0) { $0 + $1.count }
    }

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
                    case .store: storeList
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
                guard selectedTab == .store else { return }
                // The first stock may still be drawing; look again until it lands.
                await model.refreshItems()
                while model.pet?.items == nil, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    await model.refreshItems()
                }
            }
            .navigationTitle("Spend Time Together")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // The badge counts what's in the bag.
                    Button {
                        Haptics.tap(.light)
                        showingBag = true
                    } label: {
                        PetBagButtonLabel(count: bagCount)
                    }
                    .accessibilityIdentifier("pet-sheet-bag")
                }
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
        // Using something from the bag closes this sheet too; the pet answers on the tab.
        .sheet(isPresented: $showingBag) {
            PetBagSheet(model: model) { dismiss() }
        }
        .sheet(item: $itemDetails, onDismiss: { Haptics.tap(.light) }, content: { item in
            PetItemDetailSheet(model: model, item: item)
        })
        // Hosted out here for the same reason as the sheets: inside the ScrollView a confirmation
        // can lose its action.
        .confirmationDialog(
            itemChoice?.title ?? "",
            isPresented: Binding(get: { itemChoice != nil }, set: { if !$0 { itemChoice = nil } }),
            titleVisibility: .visible,
            presenting: itemChoice
        ) { item in
            Button("Use Now") {
                Haptics.tap(.light)
                if model.useItem(item) { dismiss() }
            }
            .accessibilityIdentifier("pet-item-use-now")
            Button("Keep in Bag") {
                Haptics.tap(.light)
                Task { await model.buyItem(item) }
            }
            .accessibilityIdentifier("pet-item-keep")
            Button("Cancel", role: .cancel) { Haptics.tap(.light) }
        } message: { item in
            Text("Use it with your pet now, or keep it in your bag for later. \(PetItemFacts.keeps(item.keepsHours))")
        }
        .confirmationDialog(
            "Buy Medicine",
            isPresented: $confirmingMedicine,
            titleVisibility: .visible
        ) {
            Button("Buy for \(model.pet?.medicinePrice ?? 0) Gold") {
                Haptics.tap(.light)
                Task { await model.buyMedicine() }
            }
            .accessibilityIdentifier("pet-medicine-buy")
            Button("Cancel", role: .cancel) { Haptics.tap(.light) }
        } message: {
            Text(model.pet?.illness == nil
                 ? "Your pet is well, so the dose goes in its bag until it's needed."
                 : "The dose goes in your pet's bag. Give it from there to cure your pet.")
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

    private var storeList: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.pet?.medicinePrice != nil { medicineCard }
            if let items = model.pet?.items {
                ForEach(items.actions) { item in
                    PetStoreCard(
                        title: item.title,
                        description: item.description,
                        price: item.effects.price,
                        affordable: model.canAfford(item),
                        enabled: model.activity == nil && !model.isAnswering && model.canAfford(item),
                        identifier: "pet-item-\(item.id)",
                        onSelect: {
                            Haptics.tap(.light)
                            itemChoice = item
                        },
                        onInfo: {
                            Haptics.tap(.light)
                            itemDetails = item
                        },
                        icon: { PetItemImage(itemID: item.id, api: model.api) },
                        facts: { PetItemFacts(item: item, inBag: model.bagCount(of: item)) }
                    )
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

    /// Medicine, always in stock. Bought doses wait in the bag, whether or not the pet is ill.
    private var medicineCard: some View {
        PetStoreCard(
            title: String(localized: "Medicine"),
            description: String(localized: "Cures any illness."),
            price: model.pet?.medicinePrice ?? 0,
            affordable: model.canAffordMedicine,
            enabled: model.activity == nil && !model.isAnswering && model.canAffordMedicine,
            identifier: "pet-shop-medicine",
            onSelect: {
                Haptics.tap(.light)
                confirmingMedicine = true
            },
            icon: {
                Image(systemName: "cross.vial.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.red)
            },
            facts: {
                PetFactChip(symbol: "pills.fill", color: .teal, label: Text("Medicine"))
                PetFactChip(symbol: "infinity", label: Text("Never expires once bought."))
                if let count = model.pet?.medicine, count > 0 {
                    PetFactChip(symbol: "bag.fill", text: "\(count)", label: Text("\(count) in bag"))
                }
            }
        )
    }
}

/// The bag, with a badge counting what's in it. The badge hides while the bag is empty.
private struct PetBagButtonLabel: View {
    let count: Int

    var body: some View {
        Image("PetBag")
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: 28, height: 28)
            .overlay(alignment: .topTrailing) {
                if count > 0 {
                    Text(verbatim: count > 99 ? "99+" : "\(count)")
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(count)))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Color.red, in: .capsule)
                        .offset(x: 7, y: -5)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.3), value: count)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Bag"))
            .accessibilityValue(Text(verbatim: "\(count)"))
    }
}

/// One thing for sale: its picture, name and a line about it, the price, and a row of small chips
/// with the rest. Each chip reads out in full to VoiceOver.
private struct PetStoreCard<Icon: View, Facts: View>: View {
    let title: String
    let description: String
    let price: Int
    let affordable: Bool
    let enabled: Bool
    let identifier: String
    let onSelect: () -> Void
    var onInfo: (() -> Void)?
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let facts: () -> Facts

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 14) {
                    icon()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(title)
                                .font(.headline)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            PetPriceTag(price: price, affordable: affordable)
                        }
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(AppColors.muted)
                            .lineLimit(2)
                    }
                }
                HStack(spacing: 6) { facts() }
                    .frame(maxWidth: .infinity, minHeight: onInfo == nil ? 0 : 44, alignment: .leading)
                    .padding(.trailing, onInfo == nil ? 0 : 44)
            }
        }
        .buttonStyle(.posterCard)
        .disabled(!enabled)
        .accessibilityIdentifier(identifier)
        // A sibling of the purchase button, so inspecting never buys or uses an item, and remains
        // available even when the pet cannot afford it. Its space is reserved in the facts row.
        .overlay(alignment: .bottomTrailing) {
            if let onInfo {
                Button(action: onInfo) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(AppColors.ink)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.posterPlain)
                .accessibilityLabel(Text("Details about \(title)"))
                .accessibilityIdentifier("\(identifier)-info")
                .padding(.trailing, 14)
                .padding(.bottom, 14)
            }
        }
    }
}

/// What a shop item costs, red when the pet can't afford it yet.
private struct PetPriceTag: View {
    let price: Int
    let affordable: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "dollarsign.circle.fill").foregroundStyle(.yellow)
            Text(verbatim: "\(price)")
        }
        .font(.system(size: 14, weight: .heavy, design: .monospaced))
        .foregroundStyle(affordable ? AppColors.ink : .red)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.yellow.opacity(0.18), in: .capsule)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(affordable ? Text("Costs \(price) gold") : Text("Needs \(price) gold"))
    }
}

/// A small icon chip, with an optional short value, that VoiceOver reads as `label`.
struct PetFactChip: View {
    let symbol: String
    var color: Color = AppColors.muted
    var text: String?
    let label: Text

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if let text { Text(verbatim: text).monospacedDigit() }
        }
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: .capsule)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// A shop item's chips: what kind it is, how long it stays on the shelf and keeps once bought, the
/// energy it restores, and how many the bag already holds.
private struct PetItemFacts: View {
    let item: PetAction
    let inBag: Int

    var body: some View {
        PetFactChip(symbol: kindSymbol, color: .teal, label: Text(kindTitle))
        if let leavesAt = item.leavesAt {
            PetFactChip(symbol: "clock", text: Self.short(until: leavesAt),
                        label: Text("Leaves the shop in \(Text(leavesAt, style: .relative))"))
        }
        if let hours = item.keepsHours {
            PetFactChip(symbol: "hourglass", text: Self.short(Duration.seconds(Double(hours) * 3600)),
                        label: Text(Self.keeps(hours)))
        } else {
            PetFactChip(symbol: "infinity", label: Text(Self.keeps(nil)))
        }
        // The shop's pricey tonic: what it costs is only worth it for this.
        if item.effects.energy > 0 {
            PetFactChip(symbol: "bolt.fill", color: .orange, text: "+\(item.effects.energy)",
                        label: Text("Restores \(item.effects.energy) energy"))
        }
        if inBag > 0 {
            PetFactChip(symbol: "bag.fill", text: "\(inBag)", label: Text("\(inBag) in bag"))
        }
    }

    private var kindTitle: LocalizedStringKey {
        switch item.kind {
        case .food?: "Food"
        case .ticket?: "Ticket"
        case .toy?: "Toy"
        default: "Item"
        }
    }

    private var kindSymbol: String {
        switch item.kind {
        case .food?: "fork.knife"
        case .ticket?: "ticket.fill"
        case .toy?: "teddybear.fill"
        default: "shippingbox.fill"
        }
    }

    /// A time left as a short span, like "1d 16h".
    private static func short(until date: Date) -> String {
        short(Duration.seconds(max(date.timeIntervalSinceNow, 60)))
    }

    private static func short(_ duration: Duration) -> String {
        duration.formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 2))
    }

    /// How long one keeps once bought, in a phrase.
    static func keeps(_ hours: Int?) -> String {
        guard let hours else { return String(localized: "Never expires once bought.") }
        let span = Duration.seconds(Double(hours) * 3600)
            .formatted(.units(allowed: [.days, .hours], width: .wide, maximumUnitCount: 1))
        return String(localized: "Keeps for \(span) once bought.")
    }
}
