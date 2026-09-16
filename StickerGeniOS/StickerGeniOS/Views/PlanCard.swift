import AnimatedView
import SwiftUI
import TipKit
import UIKit

/// A sticker design the assistant drafted, shown in the transcript for the user to confirm.
///
/// Actionability comes from the server's `actionable` flag rather than from `state` alone: the
/// agent revises a draft in place, so a scrolled-up card can be showing an older revision of a plan
/// that is otherwise still live. Such a card is a record of what was proposed, not a button.
struct PlanCard: View {
    let record: PlanRecord
    /// All saved plans in chronological order. Draft edits within one plan share its version.
    var versions: [PlanRecord] = []
    var currentVersionID: String?
    var onShowVersions: () -> Void = {}
    /// Opens the plan editor, scrolled to whichever part of the card was tapped.
    var onEdit: (PlanEditorFocus) -> Void = { _ in }
    let referenceImage: UIImage?
    var animationPreviewImage: UIImage?
    let isBusy: Bool
    let onConfirm: () -> Void
    let onReject: (String?) -> Void
    /// A pack publish started from this card is still running. The menu item is the only affordance
    /// for it, so it is also the only place that can say so.
    var isAddingImageToStickerPack = false
    let onAddImageToStickerPack: (UIImage) -> Void
    let onSaveImageToPhotoLibrary: (UIImage) -> Void

    @State private var confirming = false
    @State private var rejecting = false
    @State private var rejectionReason = ""
    private let confirmTip = ConfirmPlanTip()
    private let editTip = EditPlanTip()

    private var plan: Plan { record.plan }
    private var generationCount: Int { record.generationCount }
    /// Whether the footage the user captured is this plan's own reference.
    ///
    /// The server's `planRequiresConcept` draws the same line: a capture with nothing generated
    /// around it needs no concept render, so its preview is a frame of the capture rather than
    /// artwork the model drew. Adding a generated layer moves the plan back onto the concept path.
    private var isCaptureLed: Bool {
        generationCount == 0 && plan.layers.contains { layer in
            if case .sequence = layer.source { true } else { false }
        }
    }

    /// Only a plan that actually *has* a concept asset is waiting on one.
    ///
    /// A capture-led animated plan — a lifted subject plus text, shapes or particles, nothing
    /// generated — renders no static reference at all: the frames the user captured *are* the
    /// reference, so the server never attaches a `conceptAssetId` and `confirmPlan` never asks for
    /// one. Gating on `kind == .animated` alone therefore left exactly those plans stuck behind a
    /// disabled "Loading reference…" button, waiting for an image that was never coming.
    private var isWaitingForReference: Bool {
        plan.kind == .animated && record.conceptAssetId != nil && referenceImage == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                header
                TutorialButton(chapter: .finish, title: TutorialCopy.text("How plans and confirmation work"), onAction: { action in
                    if case .sticker(let screen) = action, screen == "plan" { return true }
                    return false
                }).font(.footnote)
                if plan.kind == .animated, record.conceptAssetId != nil {
                    PlanReferencePreview(
                        image: referenceImage,
                        isCapture: isCaptureLed,
                        isAddingToStickerPack: isAddingImageToStickerPack,
                        onAddToStickerPack: onAddImageToStickerPack,
                        onSaveToPhotoLibrary: onSaveImageToPhotoLibrary
                    )
                }
                if record.animationPreviewAssetId != nil {
                    PlanReferencePreview(
                        image: animationPreviewImage,
                        isCapture: false,
                        isAnimationSummary: true,
                        isAddingToStickerPack: isAddingImageToStickerPack,
                        onAddToStickerPack: onAddImageToStickerPack,
                        onSaveToPhotoLibrary: onSaveImageToPhotoLibrary
                    )
                }
                PlanLayoutPreview(layers: plan.layers)
                layerList
                if plan.kind == .animated { timingNote }
                if plan.kind == .animated, plan.layers.contains(where: { $0.source.sprite != nil }) {
                    poseVariety
                }
                if !record.actionable {
                    Text(statusNote)
                        .posterLabelStyle(9, color: AppColors.muted)
                }
                versionPicker
            }
            .padding(14)

            if record.actionable { actions }
        }
        .frame(maxWidth: 460, alignment: .leading)
        // The plan is the one thing in the transcript the user has to answer, so it gets the
        // sky band rather than plain cream — the same colour the web gives its "what happens
        // next" section.
        .posterSurface(cornerRadius: Poster.cardRadius, fill: AppColors.secondaryAccentSoft)
        .padding(.trailing, Poster.mediumShadow.width)
        .padding(.bottom, Poster.mediumShadow.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composition-plan-card")
        .confirmationDialog("Build this plan?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Build") {
                confirmTip.invalidate(reason: .actionPerformed)
                // Heavier than an ordinary tap: this commits to generating images.
                Haptics.tap(.medium)
                onConfirm()
            }
            Button("Cancel", role: .cancel) { Haptics.tap(.light) }
        } message: {
            Text(confirmationMessage)
        }
        // The reason is optional but asked for every time: given one, the assistant drafts again
        // straight away with it in hand. Without one the rejection is the end of the thread.
        .alert("Reject this plan?", isPresented: $rejecting) {
            TextField("What is wrong with it?", text: $rejectionReason, axis: .vertical)
            Button("Reject", role: .destructive) {
                Haptics.tap(.medium)
                let reason = rejectionReason.trimmingCharacters(in: .whitespacesAndNewlines)
                onReject(reason.isEmpty ? nil : reason)
                rejectionReason = ""
            }
            Button("Keep it", role: .cancel) {
                Haptics.tap(.light)
                rejectionReason = ""
            }
        } message: {
            Text("Say what is wrong and the assistant will draft a new plan right away. Leave it blank to just dismiss this one.")
        }
    }

    private var poseVariety: some View {
        Group {
            if let preset = plan.posePreset {
                Text("Pose variety: \(preset.label)")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(AppColors.muted)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("PLAN")
                    .posterLabelStyle(9)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .posterCapsule(fill: AppColors.lime, lineWidth: 1, offset: .zero)
                if !record.actionable {
                    Text("Preview only")
                        .posterLabelStyle(9, color: AppColors.muted)
                        .accessibilityIdentifier("plan-preview-only")
                }
            }
            Text(plan.title)
                .font(.posterDisplay(19, weight: .bold))
                .foregroundStyle(AppColors.ink)
            Text(plan.summary)
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(AppColors.ink.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var versionNumber: Int {
        (versions.firstIndex(where: { $0.versionID == record.versionID }) ?? 0) + 1
    }

    private var versionPicker: some View {
        Button {
            Haptics.tap(.light)
            onShowVersions()
        } label: {
            HStack(spacing: 4) {
                Text("Version \(versionNumber)")
                if record.versionID == currentVersionID {
                    Text("Current")
                }
                if versions.count > 1 {
                    // Sideways rather than down: this opens a screen of versions, it does not drop
                    // a menu, and the chevron is the only thing on the chip saying it is tappable.
                    Image(systemName: "chevron.right")
                }
            }
            .font(.posterLabel(9))
            .foregroundStyle(AppColors.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .posterCapsule(fill: AppColors.card, lineWidth: 1, offset: .zero)
        }
        .disabled(versions.count < 2)
        .accessibilityLabel("Plan version")
        .accessibilityValue("Version \(versionNumber)")
        .accessibilityIdentifier("plan-version-picker")
    }

    private var layerList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if record.actionable {
                TipView(editTip).tipViewStyle(.miniTip)
            }
            layerHeadingRow
            ForEach(Array(plan.layers.enumerated()), id: \.element.id) { index, layer in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1)")
                        .font(.posterLabel(9))
                        .foregroundStyle(AppColors.ink)
                        .frame(width: 18, height: 18)
                        .posterSurface(cornerRadius: 9, lineWidth: 1, offset: .zero)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(layer.name)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(AppColors.ink)
                            if layer.source.isVideo {
                                // The one layer that is a clip rather than a picture. Worth a chip
                                // of its own: it is the part of the plan that costs a video
                                // generation, and the reason the plan takes longer to build.
                                Text(layer.source.label)
                                    .posterLabelStyle(8)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .posterCapsule(fill: AppColors.sky, lineWidth: 1, offset: .zero)
                            } else if !layer.source.isGenerated {
                                Text(layer.source.label)
                                    .posterLabelStyle(8)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .posterCapsule(fill: AppColors.card, lineWidth: 1, offset: .zero)
                            }
                        }
                        if let prompt = layer.source.prompt {
                            Text(prompt)
                                .font(.system(size: 12, design: .rounded))
                                .foregroundStyle(AppColors.ink.opacity(0.7))
                                .lineLimit(2)
                        }
                        if let motion = layer.source.motion {
                            Text(motion)
                                .font(.system(size: 12, design: .rounded).italic())
                                .foregroundStyle(AppColors.muted)
                                .lineLimit(2)
                        }
                        if !layer.animations.isEmpty {
                            animationChips(layer.animations)
                        }
                    }
                }
            }
        }
    }

    /// Delay is the thing worth showing: it is how a staggered reveal is expressed, and seeing
    /// "+0s, +0.2s, +0.4s" down the list is what makes a typewriter plan obviously correct.
    private func animationChips(_ animations: [PlanAnimation]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(animations.enumerated()), id: \.offset) { _, animation in
                Text(animation.label)
                    .posterLabelStyle(8)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .posterCapsule(fill: AppColors.highlight, lineWidth: 1, offset: .zero)
            }
        }
    }

    /// The layer count, and the way into the editor.
    ///
    /// It reads as a subtitle rather than a button, which is the point: the row is already the
    /// sentence describing what will be built, so making it the place to change that costs the card
    /// no extra chrome beyond the chevron.
    @ViewBuilder
    private var layerHeadingRow: some View {
        if record.actionable {
            Button {
                editTip.invalidate(reason: .actionPerformed)
                onEdit(.layers)
            } label: {
                HStack(spacing: 5) {
                    Text(layerHeading)
                    Image(systemName: "chevron.right")
                }
                .posterLabelStyle(9, color: AppColors.ink.opacity(0.65))
            }
            .buttonStyle(.posterPlain)
            .accessibilityLabel(layerHeading)
            .accessibilityHint("Edit the layers of this plan")
            .accessibilityIdentifier("plan-edit-layers")
        } else {
            Text(layerHeading)
                .posterLabelStyle(9, color: AppColors.ink.opacity(0.65))
        }
    }

    private var timingSummary: String {
        "\(formatted(plan.timing.durationSeconds))s · \(plan.timing.fps) fps · \(plan.timing.loop.label)"
    }

    @ViewBuilder
    private var timingNote: some View {
        if record.actionable {
            Button {
                editTip.invalidate(reason: .actionPerformed)
                onEdit(.timing)
            } label: {
                HStack(spacing: 5) {
                    PosterSymbolLabel(verbatim: timingSummary, posterSymbol: "waveform.path")
                    Image(systemName: "chevron.right")
                }
                .posterLabelStyle(9, color: AppColors.ink.opacity(0.65))
            }
            .buttonStyle(.posterPlain)
            .accessibilityLabel("Timing, \(timingSummary)")
            .accessibilityHint("Change how long this animation runs")
            .accessibilityIdentifier("plan-edit-timing")
        } else {
            PosterSymbolLabel(verbatim: timingSummary, posterSymbol: "waveform.path")
                .posterLabelStyle(9, color: AppColors.ink.opacity(0.65))
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                confirming = true
            } label: {
                HStack(spacing: 6) {
                    // The button is disabled while busy, so it is drawn paper-on-paper; the
                    // system indicator tinted cream vanished into it. Ink, and drawn by hand,
                    // for the reasons on `PosterSpinner`.
                    if isBusy || isWaitingForReference {
                        PosterSpinner(color: AppColors.ink, size: 16)
                    }
                    if isWaitingForReference {
                        Text("Loading reference…")
                    } else {
                        Text(confirmLabel)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.poster)
            .disabled(isBusy || isWaitingForReference)
            .popoverTip(confirmTip, arrowEdge: .top)
            .accessibilityIdentifier("composition-plan-generate")

            Button { rejecting = true } label: {
                Text("Reject")
            }
            .buttonStyle(.posterSecondary)
            .disabled(isBusy)
            .accessibilityIdentifier("composition-plan-dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private var videoCount: Int { plan.layers.filter(\.source.isVideo).count }

    private var layerHeading: String {
        let layers = plan.layers.count == 1
            ? String(localized: "1 LAYER")
            : String(localized: "\(plan.layers.count) LAYERS")
        let video = videoCount == 0
            ? ""
            : videoCount == 1 ? String(localized: " · 1 VIDEO") : String(localized: " · \(videoCount) VIDEOS")
        if plan.configuration != nil { return layers + String(localized: " · \(generationCount) IMAGES") + video }
        guard generationCount < plan.layers.count else { return layers + video }
        return String(localized: "\(layers) · \(generationCount) GENERATED") + video
    }

    private var confirmLabel: String {
        if plan.configuration != nil {
            return generationCount == 0
                ? String(localized: "Build configurable sticker")
                : String(localized: "Generate \(generationCount) images")
        }
        if plan.kind == .animated {
            return generationCount == 0
                ? String(localized: "Build animation")
                : generationCount == 1
                    ? String(localized: "Separate 1 part")
                    : String(localized: "Separate \(generationCount) parts")
        }
        return generationCount == 0
            ? String(localized: "Build sticker")
            : generationCount == 1
                ? String(localized: "Generate 1 image")
                : String(localized: "Generate \(generationCount) images")
    }

    private var confirmationMessage: String {
        let video = videoCount == 0
            ? ""
            : " " + String(localized: "One part is then animated as a short video clip, which takes a few extra minutes.")
        return baseConfirmationMessage + video
    }

    private var baseConfirmationMessage: String {
        if let configuration = plan.configuration {
            return String(localized: """
                This prepares \(generationCount) images for \(configuration.combinationCount) combinations \
                using the approved reference. You can choose an expression and motion locally before sending.
                """)
        }
        if plan.kind == .animated {
            return generationCount == 0
                ? String(localized: """
                    This uses the approved static reference to \
                    assemble \(plan.layers.count) existing layers and add motion.
                    """)
                : generationCount == 1
                    ? String(localized: """
                        This uses the approved static reference to \
                        generate 1 matching transparent part, assembles the layers, and adds motion.
                        """)
                    : String(localized: """
                        This uses the approved static reference to \
                        generate \(generationCount) matching transparent parts, assembles the layers, and adds motion.
                        """)
        }
        return generationCount == 0
            ? String(localized: "This assembles \(plan.layers.count) layers. No images need to be generated.")
            : generationCount == 1
                ? String(localized: "This generates 1 separate image and assembles it. It takes longer than a single sticker.")
                : String(localized: """
                    This generates \(generationCount) separate images and \
                    assembles them. It takes longer than a single sticker.
                    """)
    }

    private var statusNote: String {
        switch record.state {
        case .draft: String(localized: "Still being drafted.")
        case .finalized: String(localized: "Use the current plan card to build.")
        case .confirmed: String(localized: "Building.")
        case .superseded: String(localized: "Superseded by a newer plan.")
        case .cancelled:
            record.decisionReason.map { String(localized: "Dismissed — \($0)") }
                ?? String(localized: "Dismissed.")
        }
    }

    private func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// The resting reference, capture poster, or illustrated animation overview shown for approval.
/// The overview explains the planned motion; the resting reference remains the artwork used to build.
private struct PlanReferencePreview: View {
    let image: UIImage?
    let isCapture: Bool
    var isAnimationSummary = false
    @State private var isShowingImage = false
    let isAddingToStickerPack: Bool
    let onAddToStickerPack: (UIImage) -> Void
    let onSaveToPhotoLibrary: (UIImage) -> Void

    /// Tall enough to read as the plate the artwork is coming to, rather than as a caption with a
    /// spinner in it.
    private static let minimumPreviewHeight: CGFloat = 160

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isAnimationSummary ? LocalizedStringKey("ANIMATION SUMMARY")
                : isCapture ? LocalizedStringKey("YOUR CAPTURE") : LocalizedStringKey("STATIC REFERENCE"))
                .font(.caption2.weight(.semibold))
                .tracking(0.7)
                .foregroundStyle(.secondary)

            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .contentShape(Rectangle())
                        .onTapGesture { isShowingImage = true }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel(isAnimationSummary ? "Open animation summary" : "Open plan reference")
                        .accessibilityHint("Opens full screen with zoom controls")
                        .contextMenu {
                            // "Sticker" here is the Messages pack, not this project: the action
                            // publishes the picture as a sticker of its own, ready to send.
                            Button {
                                Haptics.tap(.light)
                                onAddToStickerPack(image)
                            } label: {
                                PosterMenuLabel(
                                    verbatim: isAddingToStickerPack
                                        ? String(localized: "Adding to Stickers…")
                                        : String(localized: "Add to Stickers"),
                                    icon: .add
                                )
                            }
                            .disabled(isAddingToStickerPack)
                            .accessibilityIdentifier("add-plan-image-to-sticker")

                            Button {
                                Haptics.tap(.light)
                                onSaveToPhotoLibrary(image)
                            } label: {
                                PosterMenuLabel("Save to Photo Library", icon: .save)
                            }
                            .accessibilityIdentifier("save-plan-image-to-photo-library")
                        }
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Loading reference…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            // A floor under the square, because the square is only as tall as the content it is
            // measuring: the transcript proposes no height, so a reference that has not arrived
            // yet is measured from a spinner and a line of caption and the plate collapses to
            // nothing. The loaded image overshoots this every time, so the floor costs it nothing.
            .frame(minHeight: Self.minimumPreviewHeight)
            .clipShape(.rect(cornerRadius: 14, style: .continuous))
            .posterSurface(
                cornerRadius: 14,
                fill: AppColors.card,
                lineWidth: Poster.hairline,
                offset: .zero
            )
            .accessibilityIdentifier(isAnimationSummary ? "plan-animation-summary" : "plan-static-reference")

            Text(isAnimationSummary
                ? "A visual guide to the planned motions and expressions. The finished animation is built after you confirm."
                : isCapture
                ? "The first frame of your capture. It animates in place, with the other layers built around it."
                : "Confirm this look, then the artwork is separated into parts for animation.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fullScreenCover(isPresented: $isShowingImage) {
            if let image { PlanImageViewer(image: image) }
        }
    }
}

/// A schematic of where each layer lands on the canvas, so the layout is legible before anything
/// is generated.
///
/// The board is drawn square and centred rather than filling the card. The sticker canvas is
/// 1024x1024 and the coordinates are normalised against it, so stretching them across a wide
/// rectangle would misreport every position and squash the whole layout into a horizontal band.
///
/// Layers are labelled with their index, matching the numbered list below, because full names
/// collide illegibly the moment two boxes are close together — which is the normal case for the
/// per-letter layouts this card exists to show.
struct PlanLayoutPreview: View {
    let layers: [PlanLayer]

    private static let boardSide: CGFloat = 150

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
            let board = CGRect(origin: origin, size: CGSize(width: side, height: side))
            context.fill(Path(roundedRect: board, cornerRadius: 10), with: .color(AppColors.card))

            // The renderer fits each layer into a box of 86% of the canvas before scaling, so the
            // schematic applies the same factor to stay faithful to the real composition.
            let fit = 0.86
            for (index, layer) in layers.enumerated() {
                // Aspect-locked sources are built as the smaller of the pair, so that is the box
                // the sticker will actually have; drawing the wider one would promise a caption
                // the build shrinks to a square.
                let uniform = min(layer.scaleX, layer.scaleY)
                let scaleX = layer.source.isAspectLocked ? uniform : layer.scaleX
                let scaleY = layer.source.isAspectLocked ? uniform : layer.scaleY
                let width = side * fit * scaleX
                let height = side * fit * scaleY
                let rect = CGRect(
                    x: board.minX + side * layer.x - width / 2,
                    y: board.minY + side * layer.y - height / 2,
                    width: width,
                    height: height
                )
                // Artwork reads as solid; app-drawn layers are outlined, so the picture shows what
                // the sticker is actually made of. What it costs is in the heading and the button:
                // artwork the plan keeps from the current sticker is drawn but not paid for.
                let filled = layer.source.isArtwork
                let shape = Path(roundedRect: rect, cornerRadius: 4)
                context.fill(shape, with: .color(filled ? AppColors.peach : AppColors.card))
                context.stroke(
                    shape,
                    with: .color(AppColors.ink),
                    style: StrokeStyle(lineWidth: 1.5, dash: filled ? [] : [3, 2])
                )
                // Anchored to the box's top-left corner, not its centre. An accent layer that spans
                // the elements it decorates shares their centre almost exactly, so centred numerals
                // overprint into an unreadable smear; corners stay distinct because the boxes do.
                // The chip keeps a numeral legible even where two boxes do overlap.
                let corner = CGPoint(
                    x: min(max(rect.minX + 9, board.minX + 9), board.maxX - 9),
                    y: min(max(rect.minY + 9, board.minY + 9), board.maxY - 9)
                )
                let chip = Path(ellipseIn: CGRect(x: corner.x - 8, y: corner.y - 8, width: 16, height: 16))
                context.fill(chip, with: .color(AppColors.lime))
                context.stroke(chip, with: .color(AppColors.ink), lineWidth: 1.5)
                context.draw(
                    Text("\(index + 1)")
                        .font(.posterLabel(10))
                        .foregroundStyle(AppColors.ink),
                    at: corner
                )
            }

            context.stroke(
                Path(roundedRect: board, cornerRadius: 10),
                with: .color(AppColors.ink),
                lineWidth: 2
            )
        }
        .frame(height: Self.boardSide)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Layout preview with \(layers.count) layers")
    }
}
