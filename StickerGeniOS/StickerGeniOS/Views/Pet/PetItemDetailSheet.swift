import SwiftUI

/// Inspecting an item is separate from buying or using it. Shelf availability and the lifetime
/// after purchase are different clocks; an owned copy also has its own actual expiry date.
struct PetItemDetailSheet: View {
    @Bindable var model: PetModel
    let item: PetAction
    @Environment(\.dismiss) private var dismiss

    private var bagEntry: PetBagEntry? { model.pet?.bag.first { $0.id == item.id } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .top, spacing: 14) {
                        PetItemImage(itemID: item.id, api: model.api)
                            .frame(width: 64, height: 64)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.title).font(.headline)
                            Text(item.description)
                                .font(.subheadline)
                                .accessibilityIdentifier("pet-item-detail-description")
                        }
                    }
                    .padding(.vertical, 8)
                    LabeledContent("Type") { Text(kindTitle) }
                    LabeledContent("Price") { Text("\(item.effects.price) gold") }
                }

                Section("Availability & Expiry") {
                    if let leavesAt = item.leavesAt {
                        dateRow("Leaves the Shop", date: leavesAt,
                                pastStatus: "No longer in the shop.", identifier: "pet-item-detail-leaves")
                    } else {
                        LabeledContent("Leaves the Shop", value: String(localized: "No departure time listed."))
                    }
                    LabeledContent("After Purchase") {
                        if let hours = item.keepsHours {
                            let span = Duration.seconds(Double(hours) * 3600)
                                .formatted(.units(allowed: [.days, .hours], width: .wide, maximumUnitCount: 2))
                            Text("Expires \(span) after purchase.")
                        } else {
                            Text("Never expires once bought.")
                        }
                    }
                    .accessibilityIdentifier("pet-item-detail-lifetime")
                }

                if let bagEntry {
                    Section("In Your Bag") {
                        LabeledContent("Quantity") { Text(bagEntry.count.formatted()) }
                        if let expiresAt = bagEntry.expiresAt {
                            dateRow("Expires At", date: expiresAt, pastStatus: "Expired", identifier: "pet-item-detail-expires")
                            if bagEntry.count > 1 {
                                Text("This is the earliest expiry. The copy expiring soonest is used first.")
                                    .font(.footnote)
                                    .foregroundStyle(AppColors.muted)
                            }
                        } else {
                            LabeledContent("Expires At", value: String(localized: "Never expires."))
                        }
                    }
                }
            }
            .navigationTitle("Item Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // The presenting sheet supplies feedback for both Done and swipe dismissal.
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("pet-item-detail-done")
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var kindTitle: LocalizedStringKey {
        switch item.kind {
        case .food?: "Food"
        case .ticket?: "Ticket"
        case .toy?: "Toy"
        default: "Item"
        }
    }

    private func dateRow(_ title: LocalizedStringKey, date: Date, pastStatus: LocalizedStringKey, identifier: String) -> some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 4) {
                Text(date, format: .dateTime.year().month().day().hour().minute())
                if date > Date() {
                    Text("In \(Text(date, style: .relative))")
                        .font(.caption)
                        .foregroundStyle(AppColors.muted)
                } else {
                    Text(pastStatus)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .multilineTextAlignment(.trailing)
        }
        .accessibilityIdentifier(identifier)
    }
}
