import SwiftUI

/// A pack tile: a mosaic of its first members, then name, creator, and install count.
///
/// The cover is a mosaic rather than one image because a pack is a set — a single thumbnail reads
/// as a sticker rather than a collection.
struct PackCard: View {
    let pack: StickerPack
    let api: StickerAPIClientProtocol

    var body: some View {
        PosterCard(padding: 10) {
            VStack(alignment: .leading, spacing: 10) {
                PackCover(stickers: pack.coverStickers, api: api)

                Text(pack.title)
                    .font(.posterDisplay(16, weight: .bold))
                    .foregroundStyle(AppColors.ink)
                    .lineLimit(1)
                Text("by \(pack.creator.byline)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(AppColors.muted)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(pack.installCountLabel)
                        .posterLabelStyle(9, color: AppColors.faint)
                    if pack.installed {
                        Text("Added")
                            .posterLabelStyle(9)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .posterCapsule(fill: AppColors.mint, lineWidth: 1, offset: .zero)
                    }
                    if pack.state != .published {
                        Text(pack.state.label)
                            .posterLabelStyle(9)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .posterCapsule(fill: AppColors.peach, lineWidth: 1, offset: .zero)
                    }
                }

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
            StickerBlobIcon(icon: PosterIcon.mark, fill: AppColors.peach, tilt: -5)
                .frame(width: height, height: height)
        } else {
            let members = Array(stickers.prefix(4))
            VStack(alignment: .leading, spacing: Self.spacing) {
                ForEach(Array(stride(from: 0, to: members.count, by: 2)), id: \.self) { row in
                    HStack(spacing: Self.spacing) {
                        ForEach(members[row..<min(row + 2, members.count)]) { sticker in
                            Color.clear
                                .frame(width: cell, height: cell)
                                .overlay { artwork(sticker).padding(3) }
                                // Each member sits on its own outlined tile, so a mosaic of one
                                // or two still reads as a stack of stickers rather than as a
                                // stray glyph floating above the title.
                                .posterSurface(
                                    cornerRadius: 10,
                                    fill: AppColors.paper,
                                    lineWidth: 1,
                                    offset: .zero
                                )
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
            PosterSymbol(sticker.kind.symbol)
                .font(.system(size: cell * 0.34, weight: .semibold))
                .foregroundStyle(AppColors.faint)
        }
    }
}
