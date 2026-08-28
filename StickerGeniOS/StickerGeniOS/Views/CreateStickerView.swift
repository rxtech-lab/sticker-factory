import PhotosUI
import SwiftUI
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

    var body: some View {
        StickerBackground {
            ScrollView {
                VStack(spacing: 18) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("What are we making?").font(.title2.bold())
                            Picker("Sticker type", selection: $kind) {
                                ForEach(StickerKind.allCases) { value in
                                    Label(value.label, systemImage: value.symbol).tag(value)
                                }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("sticker-kind-picker")

                            if kind == .animated {
                                Label(
                                    "You’ll review a static visual reference, confirm it, then we’ll separate the artwork into parts and animate them.",
                                    systemImage: "list.number"
                                )
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Describe your sticker").font(.headline)
                            TextField(
                                "A joyful corgi in a raincoat, thick white sticker outline…",
                                text: $prompt,
                                axis: .vertical
                            )
                            .lineLimit(4...8)
                            .textFieldStyle(.plain)
                            .padding(14)
                            .accessibilityIdentifier("sticker-prompt")
                            Text("\(prompt.count)/4,000")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(prompt.count > 4_000 ? .red : .secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Reference images").font(.headline)
                                    Text("Optional · up to 8")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
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
                                .buttonStyle(.glass)
                                .accessibilityIdentifier("add-reference-images")
                            }

                            Label(
                                "Personal photos are uploaded privately to create or edit this sticker. Sources, chat, and revisions remain until you delete the project.",
                                systemImage: "hand.raised.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            if !references.isEmpty {
                                ScrollView(.horizontal) {
                                    HStack(spacing: 10) {
                                        ForEach(references) { reference in
                                            ReferenceThumbnail(
                                                reference: reference,
                                                lift: AppConfiguration.subjectLiftEnabled ? {
                                                    Haptics.tap(.light)
                                                    Task { pendingLift = await SubjectLiftPresenter.lift(from: reference) }
                                                } : nil,
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
                        HStack {
                            if isGenerating { ProgressView().controlSize(.small) }
                            Label(isGenerating ? "Starting securely…" : "Generate one candidate", systemImage: "wand.and.stars")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(AppColors.accent)
                    .controlSize(.large)
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
                            .clipShape(.rect(cornerRadius: 16))
                    }
                    // Two jobs. A capture is already cut out, so its thumbnail is mostly transparent
                    // and reads as a failed load without a badge saying otherwise. And a plain
                    // reference gives no sign that tapping it does anything at all — which is
                    // precisely why the lift went unnoticed — so it advertises the action instead.
                    if lift != nil {
                        Image(systemName: isCapture ? "livephoto" : "person.and.background.dotted")
                            .font(.caption2.bold())
                            .padding(4)
                            .background(.thinMaterial, in: Circle())
                            .padding(5)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(lift == nil)
            .accessibilityLabel(isCapture ? "Lifted subject. Tap to choose a different one." : "Reference photo. Tap to lift a subject out of it.")

            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.65))
            }
            .accessibilityLabel("Remove reference")
            .offset(x: 5, y: -5)
        }
        .padding(5)
    }
}
