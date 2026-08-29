import SwiftUI

/// A pack tile: a mosaic of its first members, then name, creator, and install count.
///
/// The cover is a mosaic rather than one image because a pack is a set — a single thumbnail reads
/// as a sticker rather than a collection.
struct PackCard: View {
    let pack: StickerPack
    let api: StickerAPIClientProtocol

    var body: some View {
        GlassCard(padding: 10) {
            VStack(alignment: .leading, spacing: 10) {
                PackCover(stickers: pack.coverStickers, api: api)

                Text(pack.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("by \(pack.creator.byline)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(pack.installCountLabel)
                    if pack.installed {
                        Text("Added")
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppColors.accentSoft.opacity(0.65), in: Capsule())
                    }
                    if pack.state != .published {
                        Text(pack.state.label)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.18), in: Capsule())
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                // Grid rows are as tall as their tallest card. Without this the shorter card's
                // content floats in the middle of its tile instead of sitting under its cover.
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A mosaic of a pack's first few members, at a height that does not depend on them.
///
/// The fixed height is the whole point. A cover that sizes itself from its artwork is one height on
/// a cold start, when its cells still hold spinners, and a taller one once the images are cached —
/// so the same card grew after a trip through search and back, and a grid row grew with it. Every
/// cell is a `Color.clear` of a known size with the artwork laid over it, which leaves the image
/// nothing to say about the layout.
///
/// Like `StickerThumbnail`, the artwork is transparent and draws with no plate behind it; only the
/// empty-pack glyph gets a filled tile.
struct PackCover: View {
    let stickers: [Sticker]
    let api: StickerAPIClientProtocol
    /// Tuning knob for how much of a browse tile the artwork takes up.
    var height: CGFloat = 64

    private static let spacing: CGFloat = 4
    private var cell: CGFloat { (height - Self.spacing) / 2 }

    var body: some View {
        content
            .frame(height: height, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        if stickers.isEmpty {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppColors.accentSoft.opacity(0.55).gradient)
                .frame(width: height, height: height)
                .overlay {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: height * 0.4, weight: .medium))
                        .foregroundStyle(AppColors.accent)
                }
        } else {
            let members = Array(stickers.prefix(4))
            VStack(alignment: .leading, spacing: Self.spacing) {
                ForEach(Array(stride(from: 0, to: members.count, by: 2)), id: \.self) { row in
                    HStack(spacing: Self.spacing) {
                        ForEach(members[row..<min(row + 2, members.count)]) { sticker in
                            Color.clear
                                .frame(width: cell, height: cell)
                                .overlay { artwork(sticker) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func artwork(_ sticker: Sticker) -> some View {
        if let assetID = sticker.systemSticker?.assetId ?? sticker.previewAsset?.id {
            VerifiedAssetImage(
                assetID: assetID,
                expectedSHA256: sticker.systemSticker?.sha256 ?? sticker.previewAsset?.sha256,
                api: api
            )
        } else {
            Image(systemName: sticker.kind.symbol).foregroundStyle(AppColors.accent)
        }
    }
}
