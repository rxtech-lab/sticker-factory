import CoreGraphics
import SwiftUI
import os

/// What the user lifted out of the photo, and where it sits on screen.
nonisolated struct LiftedSubject {
    /// Full-frame: the same dimensions as the photo, transparent outside the subject. Drawn over
    /// the photo at the same rect, which is why nothing here has to map mask geometry by hand.
    var cutout: CGImage
    var anchor: SubjectAnchorDescriptor
    /// The subject's rect in the lift view's own coordinates, so a callout can point at it.
    var bounds: CGRect
    /// The white die-cut rim the atlas will bake, at the width the atlas will bake it, full-frame
    /// like the cut-out and drawn underneath it.
    ///
    /// Filled in after the selection lands rather than as part of it, so a dilation never runs
    /// inside a drag gesture. Nil means "not computed yet" and reads as the bare cut-out, which is
    /// what the sheet showed before the rim existed.
    var rim: CGImage?
}

/// How far along the search for subjects is.
///
/// A count alone cannot say this: zero means both "none in this photo" and "not asked yet", and
/// showing "no subject found" during the second is how a working photo came to look broken.
nonisolated enum SubjectDetection: Equatable {
    case detecting
    case found(Int)
    case failed(String)
}

/// The photo, with its subjects selectable by touch.
///
/// **This is Vision, not VisionKit, and that is the whole point.** It was
/// `ImageAnalysisInteraction` — the API behind touch-and-hold in Photos — and that returned an
/// empty subject set on photos the Photos app lifts without hesitating. Its subjects resolve
/// against a hosted view's live geometry and analysis state, none of which an app can inspect when
/// the answer comes back empty, so there was no fix to make, only guesses to try.
///
/// `GenerateForegroundInstanceMaskRequest` takes pixels and returns instances. It is the same
/// segmentation, minus the view plumbing, and it can be reasoned about, logged, and tested.
///
/// Everything published is in normalized image coordinates, apart from `LiftedSubject.bounds`,
/// which exists only to place a callout and never leaves the sheet.
struct SubjectLiftView: View {
    let image: CGImage
    /// Carried whole rather than as a loose flag because the rim's preview width has to be derived
    /// the same way the encoder derives it, and that derivation takes the settings.
    var settings: SubjectLiftSettings = .default
    @Binding var selection: LiftedSubject?
    @Binding var detection: SubjectDetection
    /// True while a finger is still down, so the callout waits for the release rather than
    /// appearing under the thumb that summoned it.
    @Binding var isPressing: Bool

    @State private var subjects: [SubjectSegmenter.Detection] = []

    private var imageSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }

    var body: some View {
        GeometryReader { proxy in
            let box = Self.fittedSize(imageSize: imageSize, proposal: ProposedViewSize(proxy.size))
            // The photo is centred, so the subject's rect has to be reported with that offset baked
            // in — the callout is placed in this view's full coordinate space, not the photo's.
            let origin = CGPoint(
                x: (proxy.size.width - box.width) / 2,
                y: (proxy.size.height - box.height) / 2
            )
            stage(box: box)
                .frame(width: box.width, height: box.height)
                .contentShape(.rect)
                .gesture(press(in: box, origin: origin))
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .task(id: imageSize) { await detectSubjects() }
        .onChange(of: settings.outlineFraction) { _, _ in
            // Switching the rim on for a subject that was picked while it was off. Turning it back
            // off needs nothing: the rim is kept, just not drawn, so flipping back costs nothing.
            guard let selection, selection.rim == nil else { return }
            previewRim(for: selection.cutout, anchor: selection.anchor)
        }
    }

    private func stage(box: CGSize) -> some View {
        ZStack {
            Image(decorative: image, scale: 1, orientation: .up)
                .resizable()
                .frame(width: box.width, height: box.height)
                // Dimming the photo behind the cut-out is the *selection* highlight, and it is
                // unambiguous in a way a marching-ants outline is not: what stays bright is exactly
                // what will be uploaded, so a mask that clipped an ear or swallowed the sofa is
                // visible before the user commits. Not to be confused with the white rim below,
                // which is not a highlight at all — it is part of the sticker.
                .opacity(selection == nil ? 1 : 0.28)

            if let selection {
                // The rim goes under the cut-out at the same rect — both are full-frame, so they
                // register with each other and with the photo for free. Drawn only when the rim is
                // switched on and has arrived; until then the bare cut-out stands in, which is what
                // keeps the toggle instant in one direction and merely quick in the other.
                if settings.outlineFraction > 0, let rim = selection.rim {
                    Image(decorative: rim, scale: 1, orientation: .up)
                        .resizable()
                        .frame(width: box.width, height: box.height)
                }
                Image(decorative: selection.cutout, scale: 1, orientation: .up)
                    .resizable()
                    .frame(width: box.width, height: box.height)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: selection?.bounds)
        .clipShape(.rect(cornerRadius: 12))
    }

    /// Touch down selects, lift confirms.
    ///
    /// A `DragGesture` with no minimum distance rather than a `LongPressGesture`, because the long
    /// press reports only that it happened and never says where — and where is the entire question.
    /// Selection is immediate on contact because the segmentation already ran when the sheet
    /// opened, so there is nothing to wait for and a delay would only feel like lag.
    private func press(in box: CGSize, origin: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isPressing { isPressing = true }
                select(at: value.location, in: box, origin: origin)
            }
            .onEnded { _ in isPressing = false }
    }

    private func detectSubjects() async {
        detection = .detecting
        selection = nil
        subjects = []
        do {
            let found = try await SubjectSegmenter(settings: settings).detect(in: image)
            subjects = found
            let visible = found.filter(\.isInstance).count
            detection = .found(visible)
            SubjectLiftLog.logger.info("stage: offering \(visible, privacy: .public) subject(s) to choose from")
        } catch {
            SubjectLiftLog.logger.error("stage: detection failed — \(error.localizedDescription, privacy: .public)")
            detection = .failed(error.localizedDescription)
        }
    }

    private func select(at point: CGPoint, in box: CGSize, origin: CGPoint) {
        guard box.width > 0, box.height > 0 else { return }
        let normalized = CGPoint(x: point.x / box.width, y: point.y / box.height)
        guard let hit = SubjectSegmenter.subject(at: normalized, among: subjects) else {
            // Pressing the background clears, which is how the user changes their mind without
            // leaving the sheet.
            if selection != nil {
                SubjectLiftLog.logger.info("stage: press missed every subject, cleared")
                selection = nil
            }
            return
        }
        // Re-selecting what is already selected must not restart the animation on every touch
        // event a drag delivers.
        guard selection?.anchor != hit.descriptor else { return }

        let bounds = hit.descriptor.bounds
        SubjectLiftLog.logger.info(
            """
            stage: press at (\(normalized.x, privacy: .public), \(normalized.y, privacy: .public)) \
            selected area=\(hit.descriptor.areaFraction, privacy: .public)
            """
        )
        Haptics.tap(.medium)
        selection = LiftedSubject(
            cutout: hit.cutout,
            anchor: hit.descriptor,
            bounds: CGRect(
                x: origin.x + bounds.minX * box.width,
                y: origin.y + bounds.minY * box.height,
                width: bounds.width * box.width,
                height: bounds.height * box.height
            )
        )
        previewRim(for: hit.cutout, anchor: hit.descriptor)
    }

    /// Builds the rim the encoder would bake, off the gesture, and drops it into the selection.
    ///
    /// The width has to come from `FrameAtlasEncoder.window` rather than from anything this view
    /// can see. The rim is a fraction of the *tile*, and the tile is the subject's padded, squared
    /// crop scaled to a fixed side — so the equivalent width in source pixels depends on how big
    /// that crop is, which is the one number the encoder and the preview must not compute two
    /// different ways. A still lift crops to exactly this window, so the preview is not an
    /// approximation of the result; it is the result.
    private func previewRim(for cutout: CGImage, anchor: SubjectAnchorDescriptor) {
        guard settings.outlineFraction > 0 else { return }
        let size = CGSize(width: cutout.width, height: cutout.height)
        let subject = CGRect(
            x: anchor.bounds.minX * size.width,
            y: anchor.bounds.minY * size.height,
            width: anchor.bounds.width * size.width,
            height: anchor.bounds.height * size.height
        )
        let window = FrameAtlasEncoder.window(around: subject, in: size, settings: settings)
        let width = Double(window.width) * FrameAtlasEncoder.outlineMargin(settings)
        Task {
            let rim = await Task.detached(priority: .userInitiated) {
                StickerOutline.rim(for: cutout, widthPixels: width)
            }.value
            // The finger may have moved on to another subject while this ran. Assigning anyway
            // would hang the previous subject's rim off the current one's cut-out.
            guard selection?.anchor == anchor else { return }
            selection?.rim = rim
        }
    }

    /// The largest aspect-correct box that fits inside `proposal`.
    ///
    /// Static and pure so the one property that matters can actually be tested: the result never
    /// exceeds a finite proposal on either axis. That is the whole bug it was written for — a view
    /// that answers with something bigger than it was offered does not overflow visibly at the
    /// point of failure, it silently widens its container and clips its *siblings*.
    static func fittedSize(
        imageSize: CGSize,
        proposal: ProposedViewSize,
        fallback: CGFloat = 320
    ) -> CGSize {
        let usable: (CGFloat?) -> CGFloat? = { value in
            guard let value, value.isFinite, value > 0 else { return nil }
            return value
        }
        let width = usable(proposal.width)
        let height = usable(proposal.height)
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGSize(width: width ?? fallback, height: height ?? fallback)
        }
        let aspect = imageSize.width / imageSize.height

        switch (width, height) {
        case let (.some(w), .some(h)):
            // Whichever axis binds first decides, so the box fits inside both.
            return h * aspect <= w
                ? CGSize(width: h * aspect, height: h)
                : CGSize(width: w, height: w / aspect)
        case let (.some(w), .none):
            return CGSize(width: w, height: w / aspect)
        case let (.none, .some(h)):
            return CGSize(width: h * aspect, height: h)
        case (.none, .none):
            return CGSize(width: fallback, height: fallback / aspect)
        }
    }
}
