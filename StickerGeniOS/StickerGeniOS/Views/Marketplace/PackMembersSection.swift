import SwiftUI

/// The stickers a pack is made of, as the composer and the editor both list them.
///
/// Rows rather than a grid, because rows are what a `Form` knows how to edit: drag to reorder,
/// swipe to remove, or Edit for the red minus on every row. The first row is the pack's cover and
/// the browse tile is built from the first four, so the order is not cosmetic — it is the shopfront.
struct PackMembersSection: View {
    @Binding var members: [Sticker]
    let api: StickerAPIClientProtocol
    /// Leads every accessibility identifier, so the composer's rows and the editor's stay distinct.
    let identifierPrefix: String
    var onChoose: () -> Void

    var body: some View {
        Section {
            if members.isEmpty {
                Text("Nothing in this pack yet — add the stickers it should contain.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(members) { sticker in
                    HStack(spacing: 12) {
                        StickerThumbnail(sticker: sticker, api: api)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sticker.title).lineLimit(1)
                            // Saving is what prepares it, and the conversion screen that follows
                            // the save is less of a surprise when the row said it was coming.
                            if MessengerRenditionPreparer.needsPreparation(sticker) {
                                Text("Prepared for WhatsApp and Telegram on save")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("\(identifierPrefix)-member-\(sticker.id)")
                }
                .onMove { members.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { offsets in
                    Haptics.tap(.medium)
                    members.remove(atOffsets: offsets)
                }
            }

            // Form rows are stock SwiftUI controls, so nothing here wears a poster style that
            // could answer the press for it.
            Button {
                Haptics.tap(.light)
                onChoose()
            } label: {
                Label("Choose stickers", systemImage: "plus.circle")
            }
            .accessibilityIdentifier("\(identifierPrefix)-choose-stickers-button")
        } header: {
            HStack {
                Text("Stickers (\(members.count))")
                Spacer()
                // Removing and reordering are edit-mode gestures. The button sits here rather than
                // in the toolbar because it governs this list alone, not the fields above it.
                // `.textCase` undoes the uppercasing a section header would otherwise put on it.
                if !members.isEmpty {
                    EditButton()
                        .textCase(nil)
                        .accessibilityIdentifier("\(identifierPrefix)-reorder-button")
                }
            }
        } footer: {
            if members.count > 1 {
                Text("The first sticker is the pack's cover. Drag to reorder, swipe to remove.")
            } else if members.count == 1 {
                Text("Swipe a sticker to remove it.")
            }
        }
    }
}
