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
        PosterCard(padding: 10) {
            VStack(alignment: .leading, spacing: 10) {
                // The artwork gets a plate of its own — outlined, and a shade off the card — so a
                // transparent sticker reads as a thing pasted onto the tile rather than as a hole
                // in it.
                StickerThumbnail(sticker: sticker, api: api, detail: detail)
                    .aspectRatio(1, contentMode: .fit)
                    .padding(6)
                    .posterSurface(
                        cornerRadius: Poster.tileRadius,
                        fill: AppColors.paper,
                        lineWidth: Poster.hairline,
                        offset: Poster.noShadow
                    )

                Text(sticker.title)
                    .font(.posterDisplay(16, weight: .bold))
                    .foregroundStyle(AppColors.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(sticker.kind.label)
                        .posterLabelStyle(9, color: AppColors.muted)
                    Spacer(minLength: 0)
                    if showsStatus && sticker.status == .draft {
                        Text("Draft")
                            .posterLabelStyle(9)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .posterCapsule(fill: AppColors.peach, lineWidth: 1, offset: Poster.noShadow)
                    }
                }
            }
        }
        // The animated thumbnail is a transparent UIKit-backed view. Without an explicit shape,
        // a plain navigation link can derive its tappable area from the text below and leave the
        // artwork out. Make the entire visible card one interaction surface.
        .contentShape(.rect(cornerRadius: Poster.cardRadius))
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
            // Nothing to show yet. A blob rather than a grey box: an empty tile in a wall of
            // stickers should still look like it belongs to the same craft project.
            StickerBlobIcon(icon: sticker.kind.icon, fill: AppColors.sky, tilt: -4)
                .padding(10)
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
                ProgressView().tint(AppColors.coral)
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
