import SwiftUI

/// A sticker design the assistant drafted, shown in the transcript for the user to confirm.
///
/// Actionability comes from the server's `actionable` flag rather than from `state` alone: the
/// agent revises a draft in place, so a scrolled-up card can be showing an older revision of a plan
/// that is otherwise still live. Such a card is a record of what was proposed, not a button.
struct PlanCard: View {
    let record: PlanRecord
    let isBusy: Bool
    let onConfirm: () -> Void
    let onReject: (String?) -> Void

    @State private var confirming = false
    @State private var rejecting = false
    @State private var rejectionReason = ""

    private var plan: Plan { record.plan }
    private var generationCount: Int { record.generationCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                header
                PlanLayoutPreview(layers: plan.layers)
                layerList
                if plan.kind == .animated { timingNote }
                if !record.actionable {
                    Text(statusNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)

            if record.actionable { actions }
        }
        .frame(maxWidth: 460, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(AppColors.accent.opacity(0.2), lineWidth: 0.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("composition-plan-card")
        .confirmationDialog("Build this plan?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Build") {
                // Heavier than an ordinary tap: this commits to generating images.
                Haptics.tap(.medium)
                onConfirm()
            }
            Button("Cancel", role: .cancel) {}
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
            Button("Keep it", role: .cancel) { rejectionReason = "" }
        } message: {
            Text("Say what is wrong and the assistant will draft a new plan right away. Leave it blank to just dismiss this one.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("PLAN")
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(AppColors.accent)
                if record.revision > 1 {
                    Text("v\(record.revision)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(plan.title)
                .font(.headline)
            Text(plan.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var layerList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(layerHeading)
                .font(.caption2.weight(.semibold))
                .tracking(0.7)
                .foregroundStyle(.secondary)
            ForEach(Array(plan.layers.enumerated()), id: \.element.id) { index, layer in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(layer.name)
                                .font(.subheadline.weight(.medium))
                            if !layer.source.isGenerated {
                                Text(layer.source.label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 4))
                            }
                        }
                        if case .generate(let prompt) = layer.source, !prompt.isEmpty {
                            Text(prompt)
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AppColors.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(AppColors.accentSoft.opacity(0.55), in: .capsule)
            }
        }
    }

    private var timingNote: some View {
        Label(
            "\(formatted(plan.timing.durationSeconds))s · \(plan.timing.fps) fps · \(plan.timing.loop.rawValue)",
            systemImage: "waveform.path"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var actions: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.secondary.opacity(0.2))
            HStack(spacing: 0) {
                Button {
                    confirming = true
                } label: {
                    HStack(spacing: 6) {
                        if isBusy { ProgressView().controlSize(.small) }
                        Text(confirmLabel)
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppColors.accent)
                .disabled(isBusy)
                .accessibilityIdentifier("composition-plan-generate")

                Divider().frame(height: 24).overlay(Color.secondary.opacity(0.2))

                Button { rejecting = true } label: {
                    Text("Reject")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(isBusy)
                .accessibilityIdentifier("composition-plan-dismiss")
            }
        }
    }

    private var layerHeading: String {
        let layers = plan.layers.count == 1 ? "1 LAYER" : "\(plan.layers.count) LAYERS"
        guard generationCount < plan.layers.count else { return layers }
        return "\(layers) · \(generationCount) GENERATED"
    }

    private var confirmLabel: String {
        generationCount == 0
            ? "Build sticker"
            : generationCount == 1 ? "Generate 1 image" : "Generate \(generationCount) images"
    }

    private var confirmationMessage: String {
        generationCount == 0
            ? "This assembles \(plan.layers.count) layers. No images need to be generated."
            : "This generates \(generationCount) separate \(generationCount == 1 ? "image" : "images") and assembles them. It takes longer than a single sticker."
    }

    private var statusNote: String {
        switch record.state {
        case .draft: "Still being drafted."
        case .finalized: "Superseded by a newer revision of this plan."
        case .confirmed: "Building."
        case .superseded: "Superseded by a newer plan."
        case .cancelled: record.decisionReason.map { "Dismissed — \($0)" } ?? "Dismissed."
        }
    }

    private func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
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
private struct PlanLayoutPreview: View {
    let layers: [PlanLayer]

    private static let boardSide: CGFloat = 150

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
            let board = CGRect(origin: origin, size: CGSize(width: side, height: side))
            context.fill(Path(roundedRect: board, cornerRadius: 10), with: .color(.secondary.opacity(0.08)))

            // The renderer fits each layer into a box of 86% of the canvas before scaling, so the
            // schematic applies the same factor to stay faithful to the real composition.
            let fit = 0.86
            for (index, layer) in layers.enumerated() {
                let width = side * fit * layer.scaleX
                let height = side * fit * layer.scaleY
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
                context.fill(shape, with: .color(AppColors.accent.opacity(filled ? 0.16 : 0.06)))
                context.stroke(
                    shape,
                    with: .color(AppColors.accent.opacity(filled ? 0.5 : 0.35)),
                    style: StrokeStyle(lineWidth: 1, dash: filled ? [] : [3, 2])
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
                context.fill(chip, with: .color(.white.opacity(0.85)))
                context.stroke(chip, with: .color(AppColors.accent.opacity(0.45)), lineWidth: 1)
                context.draw(
                    Text("\(index + 1)")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(AppColors.accent),
                    at: corner
                )
            }

            context.stroke(
                Path(roundedRect: board, cornerRadius: 10),
                with: .color(.secondary.opacity(0.25)),
                lineWidth: 1
            )
        }
        .frame(height: Self.boardSide)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Layout preview with \(layers.count) layers")
    }
}
