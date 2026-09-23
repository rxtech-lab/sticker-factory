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
    /// Work still running on this sticker. Nil for pack members and anything idle.
    var progress: StickerLibraryProgress?

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
                    // On the artwork rather than in the meta row below it: a tile in a wall of
                    // stickers is scanned as pictures, and the one thing that distinguishes a
                    // sticker with controls is what it *does* when opened, not what it is called.
                    .overlay(alignment: .topTrailing) {
                        if sticker.isControllable { StickerControlsBadge() }
                    }

                Text(sticker.title)
                    .font(.posterDisplay(16, weight: .bold))
                    .foregroundStyle(AppColors.ink)
                    .lineLimit(1)
                if let progress {
                    StickerLibraryProgressView(progress: progress)
                } else {
                    statusRow
                }
            }
        }
        // The animated thumbnail is a transparent UIKit-backed view. Without an explicit shape,
        // a plain navigation link can derive its tappable area from the text below and leave the
        // artwork out. Make the entire visible card one interaction surface.
        .contentShape(.rect(cornerRadius: Poster.cardRadius))
    }

    private var statusRow: some View {
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

/// What a library tile shows about work still running on its sticker.
///
/// Built from the live job when this app is streaming it, and from the listing's snapshot
/// otherwise — the listing is what knows about a job after a relaunch, before the stream attaches.
struct StickerLibraryProgress: Equatable {
    var fraction: Double?
    var status: String

    init?(job: StickerJobState?, generation: StickerGenerationSummary?) {
        if let job, !job.isTerminal {
            // Counted units are the one measure that moves steadily; the overall figure sits at
            // zero through most of a turn, so zero is drawn as indeterminate rather than empty.
            fraction = job.unitProgress ?? (job.progress > 0 ? min(job.progress, 1) : nil)
            status = job.note ?? job.statusDetail ?? job.message
        } else if job == nil, let generation {
            fraction = nil
            status = switch generation.state {
            case "queued": String(localized: "Waiting to start…")
            case "waiting": String(localized: "Waiting for your input")
            default: generation.kind == "export"
                ? String(localized: "Publishing…")
                : String(localized: "Creating your sticker…")
            }
        } else {
            return nil
        }
    }
}

private struct StickerLibraryProgressView: View {
    let progress: StickerLibraryProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView(value: nil as Double?)
                }
            }
            .progressViewStyle(.linear)
            .tint(AppColors.ink)
            Text(progress.status)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(AppColors.muted)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("library-sticker-progress")
    }
}

/// Marks a sticker that is posed before it is used.
///
/// The same generated configuration icon on the same cream disc the Messages grid draws, because it means the same thing
/// in both places and a reader who has learned it in the drawer should not have to learn it twice.
private struct StickerControlsBadge: View {
    var body: some View {
        Image("ControllableSticker")
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .padding(2)
            .frame(width: 22, height: 22)
            .posterSurface(
                cornerRadius: 11,
                fill: AppColors.card,
                lineWidth: Poster.hairline,
                offset: Poster.noShadow
            )
            .padding(4)
            .accessibilityLabel("Has controls")
            .accessibilityIdentifier("sticker-controllable-badge")
    }
}

/// A sticker's artwork, its draft plan's concept sketch, or its kind glyph when there is neither.
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
    /// Draws the sticker as unavailable — drained of colour and faded back.
    ///
    /// Only the messenger export sheet passes this, and only for a member it cannot send. It is a
    /// property of *that list*, not of the sticker: the same sticker is perfectly usable in the
    /// library and in Messages, and dimming it there would say something untrue.
    var isUnavailable = false

    var body: some View {
        // `Color.clear` takes exactly the size it is offered and the artwork is laid over it, so a
        // tile occupies the same space whether it is still loading, holds a tall sticker, or holds
        // a wide one. Letting the image size the tile made a grid row's height depend on which of
        // its images had arrived — cards visibly grew once the artwork was cached.
        Color.clear
            .overlay { artwork }
            .grayscale(isUnavailable ? 1 : 0)
            .opacity(isUnavailable ? 0.45 : 1)
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
        } else if let concept = sticker.planConceptAsset {
            // A draft that has not built anything yet. The plan's concept render is the picture the
            // user already approved, and it tells the projects in a grid apart — which a wall of
            // identical kind glyphs never did. Clipped, because a concept is an opaque sketch on a
            // backdrop rather than a cut-out sticker, and a bare square inside the rounded plate
            // reads as a mistake.
            VerifiedAssetImage(
                assetID: concept.id,
                expectedSHA256: concept.sha256,
                api: api,
                detail: detail
            )
            .clipShape(.rect(cornerRadius: Poster.tileRadius - 4))
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
