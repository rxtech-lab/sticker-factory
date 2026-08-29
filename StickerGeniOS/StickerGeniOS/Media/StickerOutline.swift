import CoreGraphics
import CoreImage
import Foundation

/// The white die-cut rim that makes a cut-out read as a sticker rather than as a photo with its
/// background deleted.
///
/// Produces only the rim, never the composite. The subject's pixels never enter Core Image: the
/// encoder draws this underneath them with an ordinary `UIImage.draw`, so no photographic colour
/// ever makes the round trip through a context whose working colour space is deliberately null.
nonisolated enum StickerOutline {
    /// Colour management off, matching `SubjectSegmenter`. This graph moves alpha and writes pure
    /// white; there is no colour here for a working space to manage.
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    /// Below this the rim is thinner than the antialiasing that would draw it, and asking for it
    /// costs a full Core Image pass to produce something indistinguishable from nothing.
    private static let minimumWidth: Double = 1

    /// The white rim for one tile, as a `CGImage` of exactly that tile's dimensions.
    ///
    /// **Takes one tile, never the sheet, and that is the entire no-bleed guarantee.** Morphology
    /// reads outside its input's extent and finds transparency there, so a subject sitting flush
    /// against a cell border grows into nothing. Dilating the assembled atlas instead would grow
    /// every subject across its border into the next frame, and the artefact would surface as a
    /// smear on one frame of playback that nothing upstream could explain.
    ///
    /// `widthPixels` is the disc radius, and dilating by a disc of radius r grows the silhouette by
    /// exactly r in every direction — so it is also the rim's visible thickness, with no factor of
    /// two to remember at the call site.
    static func rim(for tile: CGImage, widthPixels: Double) -> CGImage? {
        guard widthPixels >= minimumWidth else { return nil }
        let source = CIImage(cgImage: tile)
        let extent = source.extent
        guard extent.width >= 1, extent.height >= 1 else { return nil }

        // Colour first, dilate second. Morphology takes a per-channel maximum, so dilating the
        // cut-out itself would draw each channel from a different neighbouring pixel and fringe the
        // rim with colour; on a silhouette every channel is already equal and stays that way.
        //
        // `CISourceInCompositing` against an opaque white generator rather than a `CIColorMatrix`
        // that rewrites RGB. Source-in is defined on premultiplied values, so it yields (a,a,a,a)
        // outright. The colour-category filters — the matrix among them — operate on
        // *unpremultiplied* values and re-premultiply on output, which turns the same intent into
        // (a², a², a², a): a white rim ringed by a gamma-squared grey fringe that reads as a dark
        // halo against a light Messages bubble, and as "the export looks a bit soft" in a bug report.
        let silhouette = CIImage(color: .white)
            .cropped(to: extent)
            .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: source])

        // Circular, not square: `CIMorphologyMaximum` takes a disc, and the boxy-cornered variants
        // are separately named `CIMorphology*Rectangle*`. A disc is what gives the rim the rounded
        // corners a die cut has.
        //
        // Left at full resolution deliberately. If this ever needs to be cheaper, a disc composes
        // exactly — dilate(r₁) then dilate(r₂) equals dilate(r₁+r₂) — so two half-radius passes, or
        // a quarter-scale silhouette dilated at a quarter of the radius, are both exact enough. Do
        // not reach for either before measuring; both trade a real artefact risk for a saving that
        // may not exist.
        let grown = silhouette.applyingFilter(
            "CIMorphologyMaximum",
            parameters: ["inputRadius": Float(widthPixels)]
        )

        // Cropped back to the tile it came from. The dilation genuinely does grow past the extent,
        // which is why the encoder's crop window carries margin for the rim rather than letting it
        // be cut off here.
        //
        // Never `.clampedToExtent()` anywhere in this graph: it replicates edge pixels, which would
        // smear the subject's alpha out to the tile border and hand back a rim that fills the cell.
        return context.createCGImage(grown.cropped(to: extent), from: extent)
    }
}
