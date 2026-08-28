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
    }

    private func stage(box: CGSize) -> some View {
        ZStack {
            Image(decorative: image, scale: 1, orientation: .up)
                .resizable()
                .frame(width: box.width, height: box.height)
                // Dimming the photo behind the cut-out is the highlight. It is unambiguous in a way
                // an outline is not: what stays bright is exactly what will be uploaded, so a mask
                // that clipped an ear or swallowed the sofa is visible before the user commits.
                .opacity(selection == nil ? 1 : 0.28)

            if let selection {
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
            let found = try await SubjectSegmenter(settings: .default).detect(in: image)
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
            "stage: press at (\(normalized.x, privacy: .public), \(normalized.y, privacy: .public)) selected area=\(hit.descriptor.areaFraction, privacy: .public)"
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
