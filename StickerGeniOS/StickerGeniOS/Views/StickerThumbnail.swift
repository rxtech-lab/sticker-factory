import SwiftUI
import UIKit

/// The library/marketplace tile for one sticker.
///
/// Extracted from `LibraryView` so the marketplace grids reuse the same verified image loader
/// rather than growing a second one.
struct StickerLibraryCard: View {
    let sticker: Sticker
    let api: StickerAPIClientProtocol
    /// Pack members are not editable by the viewer, so their card omits the draft/status line.
    var showsStatus = true

    var body: some View {
        GlassCard(padding: 10) {
            VStack(alignment: .leading, spacing: 10) {
                StickerThumbnail(sticker: sticker, api: api)
                    .aspectRatio(1, contentMode: .fit)

                Text(sticker.title)
                    .font(.headline)
                    .lineLimit(1)
                HStack {
                    Label(sticker.kind.label, systemImage: sticker.kind.symbol)
                    Spacer()
                    if showsStatus && sticker.status == .draft { Text("Draft") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// A sticker's artwork, or its kind glyph when there is nothing to show.
///
/// Stickers are transparent PNGs and APNG/GIFs. Filling a plate behind one puts a light rectangle
/// where the transparency should be, so artwork sits directly on whatever the surrounding view
/// provides. The plate is only drawn for the glyph placeholder, which needs contrast to read.
struct StickerThumbnail: View {
    let sticker: Sticker
    let api: StickerAPIClientProtocol

    var body: some View {
        // The system rendition first, not the preview: both show the same artwork, but the
        // preview for an animated sticker is the 1024² sharing GIF — tens of megabytes to fill a
        // thumbnail the system sticker covers in under 500 KB.
        if let assetID = sticker.systemSticker?.assetId ?? sticker.previewAsset?.id {
            VerifiedAssetImage(
                assetID: assetID,
                expectedSHA256: sticker.systemSticker?.sha256 ?? sticker.previewAsset?.sha256,
                api: api
            )
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(AppColors.accentSoft.opacity(0.55).gradient)
                Image(systemName: sticker.kind.symbol)
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(AppColors.accent)
            }
        }
    }
}

/// Loads an asset through the SHA-256-verifying cache.
///
/// Works for borrowed marketplace artwork as well as the user's own: the server authorizes a
/// published pack member's system rendition to any signed-in viewer, so the same call succeeds
/// for a sticker this user does not own.
struct VerifiedAssetImage: View {
    let assetID: String
    let expectedSHA256: String?
    let api: StickerAPIClientProtocol
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView()
            }
        }
        .task(id: assetID) {
            guard image == nil else { return }
            image = try? await StickerImageCache.load(
                assetID: assetID,
                expectedSHA256: expectedSHA256,
                posterFrame: true,
                api: api
            ).image
        }
    }
}
