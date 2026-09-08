import PhotosUI
import SwiftUI
import TipKit
import UIKit

struct CreateStickerView: View {
    @Bindable var store: StickerStore
    /// Generation always continues in the project's chat; the caller owns that navigation.
    var onCreated: (Sticker) -> Void
    @State private var kind: StickerKind = .static
    @State private var prompt = ""
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var references: [PendingMediaAttachment] = []
    @State private var isGenerating = false
    @State private var localError: String?
    /// The photo waiting for the user to choose a subject in it, when the lift flow is on.
    @State private var pendingLift: PendingLift?
    private let liftTip = LiftSubjectTip()

    /// Only one thumbnail may carry the tip: a popover on each of eight references at once would
    /// stack them on the same spot. The first photo that has not been lifted yet is the one the tip
    /// is about, so a row of finished cut-outs asks nothing.
    private var liftTipTarget: UUID? {
        guard AppConfiguration.subjectLiftEnabled else { return nil }
        return references.first { $0.sequence == nil }?.id
    }

    var body: some View {
        StickerBackground {
            ScrollView {
                VStack(spacing: 18) {
                    PosterCard {
                        VStack(alignment: .leading, spacing: 14) {
                            PosterEyebrow(text: String(localized: "New sticker"))
                            Text("What are we making?")
                                .font(.posterDisplay(24, weight: .heavy))
                                .foregroundStyle(AppColors.ink)
                            Picker("Sticker type", selection: $kind) {
                                ForEach(StickerKind.allCases) { value in
                                    Label(value.label, systemImage: value.symbol).tag(value)
                                }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("sticker-kind-picker")

                            if kind == .animated {
                                PosterSymbolLabel(
                                    """
                                        You’ll review a static visual reference, confirm it, then we’ll \
                                        separate the artwork into parts and animate them.
                                        """,
                                    posterSymbol: "list.number"
                                )
                                .font(.system(size: 14, design: .rounded))
                                .foregroundStyle(AppColors.muted)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    PosterCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Describe your sticker")
                                .font(.posterDisplay(18, weight: .bold))
                                .foregroundStyle(AppColors.ink)
                            TextField(
                                "A joyful corgi in a raincoat, thick white sticker outline…",
                                text: $prompt,
                                axis: .vertical
                            )
                            .lineLimit(4...8)
                            .textFieldStyle(.plain)
                            .font(.system(size: 15, design: .rounded))
                            .padding(14)
                            // The field is a surface of its own inside the card — paper rather
                            // than cream, so it reads as somewhere to write.
                            .posterSurface(
                                cornerRadius: Poster.tileRadius,
                                fill: AppColors.paper,
                                lineWidth: Poster.hairline,
                                offset: .zero
                            )
                            .accessibilityIdentifier("sticker-prompt")
                            Text("\(prompt.count)/4,000")
                                .font(.posterLabel(10))
                                .foregroundStyle(prompt.count > 4_000 ? AppColors.coral : AppColors.faint)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }

                    PosterCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Reference images")
                                        .font(.posterDisplay(18, weight: .bold))
                                        .foregroundStyle(AppColors.ink)
                                    Text("Optional · up to 8")
                                        .posterLabelStyle(9, color: AppColors.faint)
                                }
                                Spacer()
                                PhotosPicker(
                                    selection: $pickerItems,
                                    maxSelectionCount: 8,
                                    // Live Photos are offered only when the lift flow is on: without
                                    // it there is nothing that could use the motion, and picking one
                                    // would silently behave exactly like picking a still.
                                    matching: AppConfiguration.subjectLiftEnabled
                                        ? .any(of: [.images, .livePhotos])
                                        : .images,
                                    preferredItemEncoding: .compatible
                                ) {
                                    Label("Add", systemImage: "photo.badge.plus")
                                }
                                .buttonStyle(.posterSecondaryCompact)
                                .accessibilityIdentifier("add-reference-images")
                            }

                            PosterSymbolLabel(
                                """
                                    Personal photos are uploaded privately to create or edit this sticker. \
                                    Sources, chat, and revisions remain until you delete the project.
                                    """,
                                posterSymbol: "hand.raised.fill"
                            )
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(AppColors.muted)

                            if !references.isEmpty {
                                ScrollView(.horizontal) {
                                    HStack(spacing: 10) {
                                        ForEach(references) { reference in
                                            ReferenceThumbnail(
                                                reference: reference,
                                                lift: AppConfiguration.subjectLiftEnabled ? {
                                                    // Invalidated here rather than in the thumbnail
                                                    // so opening a lift from any photo retires the
                                                    // tip, not only from the one showing it.
                                                    liftTip.invalidate(reason: .actionPerformed)
                                                    Haptics.tap(.light)
                                                    Task { pendingLift = await SubjectLiftPresenter.lift(from: reference) }
                                                } : nil,
                                                tip: reference.id == liftTipTarget ? liftTip : nil,
                                                remove: {
                                                    Haptics.selection()
                                                    references.removeAll { $0.id == reference.id }
                                                }
                                            )
                                        }
                                    }
                                }
                                .scrollIndicators(.hidden)
                                .scrollDismissesKeyboard(.never)
                            }
                        }
                    }

                    if let error = localError ?? store.errorMessage { ErrorBanner(message: error) }

                    Button {
                        Haptics.tap(.medium)
                        Task { await generate() }
                    } label: {
                        HStack(spacing: 8) {
                            if isGenerating { ProgressView().controlSize(.small).tint(AppColors.card) }
                            Label {
                                Text(
                                    isGenerating
                                        ? String(localized: "Starting securely…")
                                        : String(localized: "Generate one candidate")
                                )
                            } icon: {
                                Image(systemName: "wand.and.stars")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.poster)
                    .disabled(isGenerating || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.count > 4_000)
                    .accessibilityIdentifier("generate-sticker-button")
                }
                .padding()
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Create")
        .onChange(of: pickerItems) { _, newItems in Task { await loadReferences(newItems) } }
        .subjectLiftSheet(pending: $pendingLift, references: $references, basename: "capture")
        .telemetryScreen("create_sticker")
    }

    /// Picking a photo attaches it. Nothing else.
    ///
    /// Lifting a subject used to happen here, which meant choosing one photo opened a second sheet
    /// before the user had asked for anything — and if no subject was found, the photo they picked
    /// was unusable. Attaching first makes the lift an optional refinement of something that
    /// already works, reached by tapping the thumbnail.
    private func loadReferences(_ items: [PhotosPickerItem]) async {
        // Emptied immediately, and never read as the source of truth again. A picker's `selection`
        // binding remembers everything ever chosen, so leaving items in it means a photo the user
        // later removed is still "selected" — and the next pick re-delivers it and it reappears,
        // which is exactly what made deletions look like they had not taken. Clearing it re-enters
        // this method with an empty array, which the guard drops.
        guard !items.isEmpty else { return }
        pickerItems = []

        var loaded: [PendingMediaAttachment] = []
        for (index, item) in items.prefix(max(0, 8 - references.count)).enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            do {
                var attachment = try MediaNormalizer.reference(
                    data: data,
                    basename: "reference-\(references.count + index + 1)"
                )
                attachment.source = item
                loaded.append(attachment)
            } catch {
                localError = error.localizedDescription
            }
        }
        // Appended rather than assigned, now that the picker no longer holds the whole set.
        references.append(contentsOf: loaded)
        if !loaded.isEmpty { Haptics.selection() }
    }

    private func generate() async {
        isGenerating = true
        defer { isGenerating = false }
        do {
            let sticker = try await store.create(kind: kind, prompt: prompt, references: references)
            Haptics.success()
            onCreated(sticker)
            localError = nil
        } catch {
            localError = error.localizedDescription
            Haptics.failure()
        }
    }
}

private struct ReferenceThumbnail: View {
    let reference: PendingMediaAttachment
    /// Tapping the photo reopens the lift flow on it. Nil hides the affordance entirely.
    var lift: (() -> Void)?
    /// Set on the one thumbnail that should explain the tap. Nil on every other.
    var tip: LiftSubjectTip?
    let remove: () -> Void

    private var isCapture: Bool { reference.sequence != nil }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                lift?()
            } label: {
                ZStack(alignment: .bottomLeading) {
                    if let image = UIImage(data: reference.data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 84, height: 84)
                            .clipShape(.rect(cornerRadius: 16, style: .continuous))
                            .posterSurface(
                                cornerRadius: 16,
                                fill: AppColors.paper,
                                lineWidth: Poster.hairline,
                                offset: CGSize(width: 2, height: 2)
                            )
                    }
                    // Two jobs. A capture is already cut out, so its thumbnail is mostly transparent
                    // and reads as a failed load without a badge saying otherwise. And a plain
                    // reference gives no sign that tapping it does anything at all — which is
                    // precisely why the lift went unnoticed — so it advertises the action instead.
                    if lift != nil {
                        PosterSymbol(isCapture ? "livephoto" : "person.and.background.dotted")
                            .font(.caption2.bold())
                            .foregroundStyle(AppColors.ink)
                            .padding(4)
                            .background(AppColors.lime, in: Circle())
                            .overlay(Circle().strokeBorder(AppColors.ink, lineWidth: 1))
                            .padding(5)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(lift == nil)
            .popoverTip(tip, arrowEdge: .top)
            .accessibilityLabel(
                isCapture
                    ? "Lifted subject. Tap to choose a different one."
                    : "Reference photo. Tap to lift a subject out of it."
            )

            Button(action: remove) {
                PosterSymbol("xmark.circle.fill")
                    .foregroundStyle(AppColors.card, AppColors.ink)
            }
            .accessibilityLabel("Remove reference")
            .offset(x: 5, y: -5)
        }
        .padding(5)
    }
}
