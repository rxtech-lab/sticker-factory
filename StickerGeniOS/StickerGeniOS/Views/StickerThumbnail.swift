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
    /// Passed through to the thumbnail; a card is a grid tile everywhere it is used.
    var detail: StickerAnimationDetail = .thumbnail

    var body: some View {
        GlassCard(padding: 10) {
            VStack(alignment: .leading, spacing: 10) {
                StickerThumbnail(sticker: sticker, api: api, detail: detail)
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
        // The animated thumbnail is a transparent UIKit-backed view. Without an explicit shape,
        // a plain navigation link can derive its tappable area from the text below and leave the
        // artwork out. Make the entire visible card one interaction surface.
        .contentShape(.rect(cornerRadius: 24))
    }
}

/// A sticker's artwork, or its kind glyph when there is nothing to show.
///
/// Stickers are transparent PNGs and APNG/GIFs. Filling a plate behind one puts a light rectangle
/// where the transparency should be, so artwork sits directly on whatever the surrounding view
/// provides. The plate is only drawn for the glyph placeholder, which needs contrast to read.
///
/// An animated sticker plays here rather than sitting on its poster frame — a library of stickers
/// that all advertise themselves as animated and none of which move reads as broken artwork.
struct StickerThumbnail: View {
    let sticker: Sticker
    let api: StickerAPIClientProtocol
    /// How large the frames are decoded. The default suits a grid tile; a sheet showing one sticker
    /// large passes `.preview`.
    var detail: StickerAnimationDetail = .thumbnail

    var body: some View {
        // `Color.clear` takes exactly the size it is offered and the artwork is laid over it, so a
        // tile occupies the same space whether it is still loading, holds a tall sticker, or holds
        // a wide one. Letting the image size the tile made a grid row's height depend on which of
        // its images had arrived — cards visibly grew once the artwork was cached.
        Color.clear
            .overlay { artwork }
    }

    @ViewBuilder
    private var artwork: some View {
        // The system rendition first, not the preview: both show the same artwork, but the
        // preview for an animated sticker is the 1024² sharing APNG — megabytes to fill a
        // thumbnail the system sticker covers in under 500 KB.
        if let assetID = sticker.systemSticker?.assetId ?? sticker.previewAsset?.id {
            VerifiedAssetImage(
                assetID: assetID,
                expectedSHA256: sticker.systemSticker?.sha256 ?? sticker.previewAsset?.sha256,
                api: api,
                animates: sticker.kind == .animated,
                detail: detail
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
    /// Play the artwork rather than draw one frame of it.
    ///
    /// Off by default, and the caller decides: a browse-list cover mosaic is four stickers deep in a
    /// scrolling list of cards, and playing all of them buys nothing a poster frame does not already
    /// say. Asking for it is not a promise — an asset that turns out to hold a single frame falls
    /// back to the still, which is what an animated sticker whose Messages rendition lost its motion
    /// to the 500 KB ceiling has.
    var animates = false
    var detail: StickerAnimationDetail = .thumbnail

    @State private var image: UIImage?
    @State private var animation: StickerAnimation?

    var body: some View {
        Group {
            if let animation {
                AnimatedStickerImage(animation: animation)
                    // Playback is visual content. Its SwiftUI bridge must not compete with a card
                    // or attachment button that owns the tap.
                    .allowsHitTesting(false)
            } else if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView()
            }
        }
        .task(id: assetID) {
            // One download, not two: the animated path decodes its own still out of the same bytes,
            // so a moving sticker never pays for the poster it would have shown instead.
            if animates, animation == nil, image == nil {
                if let artwork = await StickerArtworkLoader.shared.artwork(
                    assetID: assetID,
                    expectedSHA256: expectedSHA256,
                    detail: detail,
                    api: api
                ) {
                    animation = artwork.animation
                    if artwork.animation == nil { image = artwork.still }
                    return
                }
                // Fell through on a failed download or undecodable bytes — the still path gets its
                // own attempt rather than leaving the tile spinning.
            }
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
