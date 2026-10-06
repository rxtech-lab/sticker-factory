import SwiftUI

/// What the owner has bought to use later: medicine, given from here when the pet is ill, and food,
/// toys and tickets, used from here for free until they expire. Using an item calls `onUse`, which
/// closes the sheets; the pet answers on the tab.
struct PetBagSheet: View {
    @Bindable var model: PetModel
    let onUse: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var isEmpty: Bool { (model.pet?.medicine ?? 0) == 0 && (model.pet?.bag.isEmpty ?? true) }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let pet = model.pet, !isEmpty {
                    VStack(spacing: 12) {
                        if pet.medicine > 0 { medicineRow(pet) }
                        ForEach(pet.bag) { entry in
                            Button {
                                Haptics.tap(.light)
                                if model.useItem(entry.item, fromBag: true) { onUse() }
                            } label: {
                                PetBagRow(title: entry.item.title, count: entry.count, detail: Self.detail(entry)) {
                                    PetItemImage(itemID: entry.id, api: model.api)
                                }
                            }
                            .buttonStyle(.posterCard)
                            .disabled(model.activity != nil || model.isAnswering)
                            .accessibilityIdentifier("pet-bag-item-\(entry.id)")
                        }
                    }
                    .padding()
                } else {
                    ContentUnavailableView(
                        "Your Bag Is Empty",
                        systemImage: "bag",
                        description: Text("Things you keep from the store wait here until you use them.")
                    )
                    .padding(.top, 60)
                }
            }
            .navigationTitle("Bag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
    }

    private func medicineRow(_ pet: Pet) -> some View {
        Button {
            Haptics.tap(.light)
            Task { await model.giveMedicine() }
        } label: {
            PetBagRow(title: String(localized: "Medicine"), count: pet.medicine,
                      detail: pet.illness == nil ? Text("For when your pet is ill.") : Text("Tap to give it.")) {
                Image(systemName: "cross.vial.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.red)
            }
        }
        .buttonStyle(.posterCard)
        .disabled(model.activity != nil || model.isAnswering || pet.illness == nil)
        .accessibilityIdentifier("pet-bag-medicine")
    }

    /// When the first of `entry` expires.
    private static func detail(_ entry: PetBagEntry) -> Text {
        guard let expiresAt = entry.expiresAt else { return Text("Never expires.") }
        return Text("Expires in \(Text(expiresAt, style: .relative))")
    }
}

/// One thing in the bag: its picture, name, how many are left, and a short line about it.
struct PetBagRow<Icon: View>: View {
    let title: String
    let count: Int
    let detail: Text
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        HStack(spacing: 14) {
            icon()
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).lineLimit(2)
                detail.font(.caption).foregroundStyle(AppColors.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: "×\(count)")
                .font(.system(.headline, design: .monospaced))
                .accessibilityLabel(Text("\(count) left"))
        }
    }
}

/// The picture of an item on the shelf or in the bag, fetched once and cached by its id.
struct PetItemImage: View {
    let itemID: String
    let api: any StickerAPIClientProtocol
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "shippingbox")
            }
        }
        .task(id: itemID) {
            image = try? await PetArtworkImageCache.shared.loadItem(itemID: itemID, size: 256, api: api)
        }
    }
}
