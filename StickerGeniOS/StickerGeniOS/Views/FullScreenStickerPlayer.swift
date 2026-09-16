import AnimatedView
import PhotosUI
import SwiftUI
import TipKit
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
    var startsEditing = false
    var settings: StickerControlSettings?

    var id: String { revisionID ?? "document-\(document.hashValue)" }
}

/// The sticker at full size, with a way into the editor.
struct FullScreenStickerPlayer: View {
    let document: AnimatedDocument
    var startsEditing = false
    var settings: StickerControlSettings?
    let assets: [String: UIImage]
    var videos: [String: KeyedVideoFrames] = [:]
    /// Everything a save needs. `nil` for a document with no revision behind it — a preview, or a
    /// candidate that has not been accepted — in which case editing is view-only.
    var editing: EditingContext?
    var controls: ControlsContext?

    struct EditingContext {
        let store: StickerStore
        let stickerID: String
        let revisionID: String
        let assetStore: StickerAssetStore
    }

    struct ControlsContext {
        let store: StickerStore
        let stickerID: String
        let assetStore: StickerAssetStore
        var onApply: () -> Void = {}

        var accountID: String { (try? SharedKeychainTokenVault().load()?.subject) ?? "local" }
    }

    @Environment(\.dismiss) private var dismiss
    /// Presented by a plain flag, never by an `item:` binding.
    ///
    /// `PresentedStickerDocument` used to mint a fresh `UUID` on init, so building one inside a computed
    /// binding's getter gave the cover a new identity on every parent re-evaluation — SwiftUI tore
    /// the editor down and re-presented it from the original document, silently discarding whatever
    /// had been edited. Identity has to be stable for as long as the thing is on screen.
    @State private var isEditing = false
    @State private var didPresentInitially = false
    @State private var isPresentingControls = false
    @State private var controlsHeight: CGFloat = 0
    @State private var previewSettings: StickerControlSettings?
    @State private var previewAssets: StickerRenderAssets?
    @State private var afterControlsAction: ControlsAction?
    @State private var playbackOrigin = Date()
    @State private var exportRequest: StickerViewerExportRequest?
    @State private var isExporting = false
    @State private var controlsOutputReady = false

    private enum ControlsAction: Equatable { case edit, close, export }
    private var hasControls: Bool { document.configuration != nil && controls != nil }
    private var exportSettings: StickerControlSettings { previewSettings ?? settings ?? .defaults(for: document) }
    private var exportAssets: StickerRenderAssets { previewAssets ?? .init(images: assets, videos: videos) }
    private var canExport: Bool {
        guard exportSettings.canPlay, !isExporting,
              let documents = try? exportSettings.playbackDocuments(document),
              documents.allSatisfy({ exportAssets.containsArtwork(for: $0) }) else { return false }
        return !isPresentingControls || controlsOutputReady
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                GeometryReader { geometry in
                    let coveredHeight = isPresentingControls
                        ? (controlsHeight > 0 ? max(0, controlsHeight - geometry.safeAreaInsets.bottom) : geometry.size.height / 2)
                        : 0
                    StickerPlayer(document: document,
                        assets: previewAssets?.images ?? assets,
                        videos: previewAssets?.videos ?? videos,
                        repeats: true, settings: previewSettings ?? settings, playbackOrigin: playbackOrigin)
                        .padding()
                        .frame(width: geometry.size.width, height: max(1, geometry.size.height - coveredHeight))
                        .clipped()
                        .accessibilityIdentifier("full-screen-sticker-player")
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        Haptics.tap(.light)
                        performAfterControls(.close)
                    } label: {
                        Label("Close", systemImage: "xmark")
                    }
                        .accessibilityIdentifier("dismiss-full-screen-player")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if hasControls && !isPresentingControls {
                        Button("Controls", systemImage: "switch.2") {
                            Haptics.tap(.light)
                            controlsHeight = 0
                            controlsOutputReady = false
                            isPresentingControls = true
                        }
                        .accessibilityIdentifier("show-sticker-controls")
                    }
                    if hasControls {
                        Button {
                            exportRequest = .init(document: document, settings: exportSettings, assets: exportAssets)
                            performAfterControls(.export)
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        .disabled(!canExport)
                        .accessibilityIdentifier("sticker-viewer-export")
                    }
                    if editing != nil {
                        Button {
                            Haptics.tap(.light)
                            performAfterControls(.edit)
                        } label: {
                            Label("Edit", systemImage: "slider.horizontal.3")
                        }
                            .accessibilityIdentifier("edit-sticker-button")
                    }
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .onAppear {
            guard !didPresentInitially else { return }
            didPresentInitially = true
            restoreAppliedSettings()
            if let settings { previewSettings = settings }
            if startsEditing {
                isEditing = true
            } else if hasControls {
                isPresentingControls = true
            }
        }
        .sheet(isPresented: $isPresentingControls, onDismiss: controlsDismissed) {
            if let controls {
                StickerControlsSheet(
                    document: document, stickerID: controls.stickerID, accountID: controls.accountID,
                    loadAssets: { documents in
                        for target in documents {
                            try Task.checkCancellation()
                            await controls.assetStore.preload(document: target, api: controls.store.api)
                        }
                        return controls.assetStore.renderAssets
                    },
                    onApply: { _, _, _ in controls.onApply() },
                    onClose: { isPresentingControls = false },
                    initialSettings: previewSettings, showsPreview: false,
                    editsAnimationsInPlace: true,
                    onPreviewChange: { selected, loaded, origin in
                        guard isPresentingControls else { return }
                        previewSettings = selected
                        previewAssets = loaded
                        playbackOrigin = origin
                    },
                    onOutputReadinessChange: { controlsOutputReady = $0 },
                    education: { AnyView(ControllableTutorialHelp(kind: .controls)) },
                    onControlsUsed: { StickerControlsTutorialTip().invalidate(reason: .actionPerformed) }
                )
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
                } action: { controlsHeight = $0 }
            }
        }
        .sheet(isPresented: $isExporting) {
            if let exportRequest { StickerViewerExportSheet(request: exportRequest) }
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

    private func restoreAppliedSettings() {
        guard hasControls, let controls else { return }
        previewSettings = StickerControlPreferences().load(
            accountID: controls.accountID, stickerID: controls.stickerID, document: document)
        previewAssets = controls.assetStore.renderAssets
    }

    private func performAfterControls(_ action: ControlsAction) {
        if isPresentingControls {
            afterControlsAction = action
            isPresentingControls = false
        } else {
            switch action {
            case .edit: isEditing = true
            case .close: dismiss()
            case .export: isExporting = true
            }
        }
    }

    private func controlsDismissed() {
        let action = afterControlsAction
        afterControlsAction = nil
        controlsHeight = 0
        // Export uses the draft; Cancel and swipe dismissal restore saved values.
        if action != .export { restoreAppliedSettings() }
        if let action { performAfterControls(action) }
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
