import AnimatedView
import PhotosUI
import SwiftUI
import UIKit

/// A document presented full screen.
///
/// `AnimatedDocument` is a value type with no identity of its own, so this wrapper gives
/// `.fullScreenCover(item:)` something to key on. It also carries the revision the document came
/// from, which is what a save from the editor parents itself onto — without it an edit would have
/// to guess at the sticker's active revision and could silently re-parent onto a generation that
/// landed while the editor was open.
///
/// The id is *derived* rather than a fresh `UUID`, and that is not a detail. A random id makes the
/// type unsafe to construct anywhere a view body can re-run: `item:` keys the presentation on it,
/// so a re-derived value reads as a different thing and SwiftUI dismisses and re-presents the
/// cover — losing whatever state the presented view was holding. Deriving it from the content means
/// the same document is always the same presentation, however many times the value gets rebuilt.
nonisolated struct PresentedStickerDocument: Identifiable, Sendable {
    let document: AnimatedDocument
    var revisionID: String?

    var id: String { revisionID ?? "document-\(document.hashValue)" }
}

/// The sticker at full size, with a way into the editor.
struct FullScreenStickerPlayer: View {
    let document: AnimatedDocument
    let assets: [String: UIImage]
    var videos: [String: KeyedVideoFrames] = [:]
    /// Everything a save needs. `nil` for a document with no revision behind it — a preview, or a
    /// candidate that has not been accepted — in which case editing is view-only.
    var editing: EditingContext?

    struct EditingContext {
        let store: StickerStore
        let stickerID: String
        let revisionID: String
        let assetStore: StickerAssetStore
    }

    @Environment(\.dismiss) private var dismiss
    /// Presented by a plain flag, never by an `item:` binding.
    ///
    /// `PresentedStickerDocument` mints a fresh `UUID` on init, so building one inside a computed
    /// binding's getter gave the cover a new identity on every parent re-evaluation — SwiftUI tore
    /// the editor down and re-presented it from the original document, silently discarding whatever
    /// had been edited. Identity has to be stable for as long as the thing is on screen.
    @State private var isEditing = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                StickerPlayer(document: document, assets: assets, videos: videos, repeats: true)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("full-screen-sticker-player")
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        Haptics.tap(.light)
                        dismiss()
                    } label: {
                        Label("Close", systemImage: "xmark")
                    }
                        .accessibilityIdentifier("dismiss-full-screen-player")
                }
                if editing != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Haptics.tap(.light)
                            isEditing = true
                        } label: {
                            Label("Edit", systemImage: "slider.horizontal.3")
                        }
                            .accessibilityIdentifier("edit-sticker-button")
                    }
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .fullScreenCover(isPresented: $isEditing) {
            if let editing {
                StickerEditorSheet(
                    document: document,
                    context: editing,
                    onFinished: { saved in
                        isEditing = false
                        // A saved edit becomes the sticker's active revision, so this view is now
                        // showing something out of date; step back to the chat rather than leaving
                        // a stale document on screen.
                        if saved { dismiss() }
                    }
                )
            }
        }
    }
}

/// Hosts `AnimatedIconEditor` and owns the save.
///
/// The editor itself is deliberately ignorant of the network: it edits a document and hands it
/// back. Persistence, asset picking, and the "this will unpublish your sticker" warning all live
/// here, where the app's store and API client are in scope.
struct StickerEditorSheet: View {
    @State var document: AnimatedDocument
    let context: FullScreenStickerPlayer.EditingContext
    let onFinished: (Bool) -> Void

    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmingUnpublish = false
    @State private var photoItem: PhotosPickerItem?
    @State private var pickerContinuation: CheckedContinuation<String?, Never>?

    private var isPublished: Bool {
        context.store.stickers.first { $0.id == context.stickerID }?.status == .published
    }

    var body: some View {
        NavigationStack {
            AnimatedIconEditor(
                document: $document,
                assets: context.assetStore,
                // Canvas resize is off because it cannot keep its promise here: positions are
                // normalized, so a same-aspect resize moves nothing, and every sticker export
                // renders a square frame that letterboxes anything else. Size that does reach the
                // sticker is chosen at send time in WinkySticker, from the three renditions a
                // publish uploads — see `StickerExportMetadataPolicy.attachmentDimensions`.
                configuration: .init(allowsCanvasResize: false),
                onPickImageAsset: { await pickImageAsset() }
            )
            .navigationTitle("Edit Sticker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        Haptics.tap(.light)
                        onFinished(false)
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Haptics.tap(.light)
                            if isPublished { confirmingUnpublish = true } else { Task { await save() } }
                        }
                        .accessibilityIdentifier("save-edited-sticker-button")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let errorMessage {
                    ErrorBanner(message: errorMessage).padding()
                }
            }
            .confirmationDialog(
                "This sticker is published",
                isPresented: $confirmingUnpublish,
                titleVisibility: .visible
            ) {
                Button("Save Anyway") {
                    Haptics.tap(.medium)
                    Task { await save() }
                }
                Button("Cancel", role: .cancel) { Haptics.tap(.light) }
            } message: {
                // Saving creates a revision with no renditions, so the server derives the sticker
                // back to draft. Better said here than discovered when it vanishes from Messages.
                Text("Saving replaces it with an unpublished draft. Export again to put it back in Messages.")
            }
            .photosPicker(isPresented: Binding(
                get: { pickerContinuation != nil },
                set: { if !$0 { resumePicker(with: nil) } }
            ), selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await uploadPickedImage(item) }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            // The editor's issue banner is advisory and never blocks typing, so this is the first
            // point anything insists the document is whole.
            let validated = try document.validated()
            try await context.store.saveEditedDocument(
                stickerID: context.stickerID,
                parentRevisionID: context.revisionID,
                document: validated
            )
            Haptics.success()
            onFinished(true)
        } catch {
            // Deliberately does not dismiss: an edit lost to a flaky connection is unrecoverable.
            errorMessage = error.localizedDescription
            Haptics.failure()
        }
    }

    /// Bridges the editor's `async` asset request to the photo picker's callback shape.
    private func pickImageAsset() async -> String? {
        await withCheckedContinuation { continuation in
            pickerContinuation = continuation
        }
    }

    private func resumePicker(with assetID: String?) {
        guard let continuation = pickerContinuation else { return }
        pickerContinuation = nil
        photoItem = nil
        continuation.resume(returning: assetID)
    }

    private func uploadPickedImage(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                resumePicker(with: nil)
                return
            }
            // The same normalisation the composer's attachments go through, so an image added in
            // the editor is subject to the identical size and format rules.
            let normalized = try MediaNormalizer.reference(data: data, basename: "edited-layer")
            let assetID = try await context.store.api.upload(
                data: normalized.data,
                stickerID: context.stickerID,
                kind: .reference,
                filename: normalized.filename,
                mimeType: normalized.mimeType,
                sequence: nil,
                idempotencyKey: UUID().uuidString
            )
            await context.assetStore.load(assetID: assetID, api: context.store.api)
            // The layer appears in the canvas at this point, which is a change to the document
            // rather than a finished task — a selection tick, not a success.
            Haptics.selection()
            resumePicker(with: assetID)
        } catch {
            errorMessage = error.localizedDescription
            Haptics.failure()
            resumePicker(with: nil)
        }
    }
}
