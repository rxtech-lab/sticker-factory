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
                                    "You’ll confirm the base image, describe the motion in chat, preview valid streamed animation snapshots, then export.",
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
                                    matching: .images,
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
                                            ReferenceThumbnail(reference: reference) {
                                                Haptics.selection()
                                                references.removeAll { $0.id == reference.id }
                                            }
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
    }

    private func loadReferences(_ items: [PhotosPickerItem]) async {
        var loaded: [PendingMediaAttachment] = []
        for (index, item) in items.prefix(8).enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            do { loaded.append(try MediaNormalizer.reference(data: data, basename: "reference-\(index + 1)")) }
            catch { localError = error.localizedDescription }
        }
        references = loaded
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
    let remove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let image = UIImage(data: reference.data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 84, height: 84)
                    .clipShape(.rect(cornerRadius: 16))
            }
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
