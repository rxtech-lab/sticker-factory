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
                    .aspectRatio(1, contentMode: .fit)

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
            }
        }
    }
}

/// A mosaic of a pack's first few members.
///
/// Like `StickerThumbnail`, the artwork is transparent and draws with no plate behind it; only the
/// empty-pack glyph gets a filled tile.
struct PackCover: View {
    let stickers: [Sticker]
    let api: StickerAPIClientProtocol

    var body: some View {
        if stickers.isEmpty {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(AppColors.accentSoft.opacity(0.55).gradient)
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(AppColors.accent)
            }
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 2), spacing: 4) {
                ForEach(stickers.prefix(4)) { sticker in
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
            .padding(10)
        }
    }
}
