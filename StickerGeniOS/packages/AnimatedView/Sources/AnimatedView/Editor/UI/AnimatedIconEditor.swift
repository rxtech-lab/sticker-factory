#if os(iOS)
import SwiftUI

/// How a host restricts what the editor may do.
///
/// This exists because a document the editor can express is not necessarily one the server will
/// accept: the v1 sticker contract pins the canvas to 1024×1024, caps layers at 8, and has no
/// notion of SVG layers or gradients. A host talking to that contract turns the corresponding
/// switches off here rather than letting the user build something that fails on save.
public struct AnimatedEditorConfiguration: Sendable {
    public var allowsCanvasResize: Bool
    public var allowsKindChange: Bool
    public var allowedLayerTypes: Set<AnimatedLayerType>

    public init(
        allowsCanvasResize: Bool = true,
        allowsKindChange: Bool = true,
        allowedLayerTypes: Set<AnimatedLayerType> = Set(AnimatedLayerType.allCases)
    ) {
        self.allowsCanvasResize = allowsCanvasResize
        self.allowsKindChange = allowsKindChange
        self.allowedLayerTypes = allowedLayerTypes
    }
}

/// A full editor for an `AnimatedDocument`.
///
/// The host owns persistence. This type owns the editing session and writes changes back through
/// the binding; when the host is ready to save or export it calls `try document.validated()` and
/// takes it from there.
///
/// Image layers appear in the add menu only when `onPickImageAsset` is supplied: a document carries
/// no pixels, so an image layer needs an asset id that only the host can resolve.
public struct AnimatedIconEditor: View {
    @Binding private var document: AnimatedDocument
    private let assets: any AnimatedAssetProvider
    private let configuration: AnimatedEditorConfiguration
    private let onPickImageAsset: (@MainActor () async -> String?)?

    @State private var editor: AnimatedDocumentEditor
    @State private var pane = Pane.layers
    @State private var backdrop = AnimatedEditorBackdrop.checkerboard
    @State private var showsSettings = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    public init(
        document: Binding<AnimatedDocument>,
        assets: any AnimatedAssetProvider = EmptyAnimatedAssets(),
        configuration: AnimatedEditorConfiguration = .init(),
        onPickImageAsset: (@MainActor () async -> String?)? = nil
    ) {
        self._document = document
        self.assets = assets
        self.configuration = configuration
        self.onPickImageAsset = onPickImageAsset
        self._editor = State(initialValue: AnimatedDocumentEditor(document: document.wrappedValue))
    }

    private enum Pane: String, CaseIterable, Identifiable {
        case layers, style, motion
        var id: Self { self }
        var label: String {
            switch self {
            case .layers: "Layers"
            case .style: "Style"
            case .motion: "Motion"
            }
        }
    }

    public var body: some View {
        Group {
            if sizeClass == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showsSettings) {
            AnimatedDocumentSettingsView(editor: editor, configuration: configuration)
        }
        .safeAreaInset(edge: .top, spacing: 0) { issueBanner }
        // Mirrored both ways behind an equality guard. `AnimatedDocument` is `Hashable`, so the
        // guard is exact and cheap, and it is what stops the two writes from ping-ponging.
        .onChange(of: editor.document) { _, new in
            if new != document { document = new }
        }
        .onChange(of: document) { _, new in
            if new != editor.document { editor.replaceDocument(new) }
        }
    }

    // MARK: - Layouts

    /// iPhone: one column, no sheet over the canvas.
    ///
    /// A bottom sheet would have to be dismissed before the artwork could be dragged, which is
    /// hostile in an editor whose primary interaction *is* dragging the artwork.
    private var compactLayout: some View {
        VStack(spacing: 0) {
            AnimatedEditorStage(editor: editor, assets: assets, backdrop: backdrop)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)

            transport

            if editor.document.kind == .animated, pane == .motion {
                AnimatedEditorTimeline(editor: editor)
                    .frame(height: 150)
            }

            Picker("Pane", selection: $pane) {
                ForEach(Pane.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            paneContent
                .frame(height: 280)
        }
    }

    /// iPad: sidebar for the stack, detail for the canvas, inspector for properties.
    private var regularLayout: some View {
        HStack(spacing: 0) {
            layerList
                .frame(width: 260)

            Divider()

            VStack(spacing: 0) {
                AnimatedEditorStage(editor: editor, assets: assets, backdrop: backdrop)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
                transport
                if editor.document.kind == .animated {
                    AnimatedEditorTimeline(editor: editor).frame(height: AnimatedEditorTimeline.preferredHeight)
                }
            }

            Divider()

            Group {
                if editor.selectedKeyframe != nil {
                    AnimatedEditorKeyframeInspector(editor: editor)
                } else {
                    inspector
                }
            }
            .frame(width: 320)
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch pane {
        case .layers: layerList
        case .style: inspector
        case .motion: AnimatedEditorKeyframeInspector(editor: editor)
        }
    }

    private var layerList: some View {
        AnimatedEditorLayerList(
            editor: editor,
            canAddImageLayers: onPickImageAsset != nil,
            allowedLayerTypes: configuration.allowedLayerTypes,
            onRequestImageAsset: { pickImageAsset() }
        )
    }

    private var inspector: some View {
        AnimatedEditorInspector(
            editor: editor,
            assets: assets,
            onRequestImageAsset: { layerID in replaceImage(forLayer: layerID) },
            onRequestMaskAsset: { layerID in addMask(forLayer: layerID) }
        )
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: 12) {
            Button {
                editor.isPlaying.toggle()
            } label: {
                Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill")
            }
            .disabled(editor.document.kind == .static)
            .accessibilityLabel(editor.isPlaying ? "Pause" : "Play")

            if editor.document.kind == .animated {
                Slider(
                    value: $editor.scrubDocumentTime,
                    in: 0...max(editor.document.durationSeconds, 0.01)
                ) { isEditing in
                    // Scrubbing means looking at one frame, so it takes over from playback.
                    if isEditing { editor.isPlaying = false }
                }
                Text(String(format: "%.2fs", editor.scrubDocumentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            } else {
                Text("Still image").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }

            Picker("Backdrop", selection: $backdrop) {
                ForEach(AnimatedEditorBackdrop.allCases) { Image(systemName: symbol(for: $0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 130)
            .labelsHidden()
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private func symbol(for backdrop: AnimatedEditorBackdrop) -> String {
        switch backdrop {
        case .checkerboard: "square.grid.2x2"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    // MARK: - Toolbar and banner

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button("Undo", systemImage: "arrow.uturn.backward") { editor.undo() }
                .disabled(!editor.canUndo)
            Button("Redo", systemImage: "arrow.uturn.forward") { editor.redo() }
                .disabled(!editor.canRedo)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            AnimatedAddLayerMenu(
                editor: editor,
                allowedLayerTypes: configuration.allowedLayerTypes,
                canAddImageLayers: onPickImageAsset != nil,
                onRequestImageAsset: { pickImageAsset() }
            )
            Button("Sticker Settings", systemImage: "slider.horizontal.3") { showsSettings = true }
        }
    }

    /// Non-blocking by design: the document is allowed to sit invalid while it is being edited, and
    /// only the host's save path calls `validated()`.
    @ViewBuilder
    private var issueBanner: some View {
        if let issue = editor.issues.first {
            Label(issue.message, systemImage: issue.severity == .blocking ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.caption)
                .foregroundStyle(issue.severity == .blocking ? Color.red : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.bar)
                .onTapGesture {
                    if let layerID = issue.layerID { editor.selectedLayerID = layerID }
                }
        } else if let error = editor.lastError {
            Label(error.errorDescription ?? "That edit was not possible.", systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.bar)
                .onTapGesture { editor.lastError = nil }
        }
    }

    // MARK: - Host callbacks

    private func pickImageAsset() {
        guard let onPickImageAsset else { return }
        Task { @MainActor in
            guard let assetID = await onPickImageAsset() else { return }
            editor.addLayer(.image, assetID: assetID)
        }
    }

    private func replaceImage(forLayer layerID: String) {
        guard let onPickImageAsset else { return }
        Task { @MainActor in
            guard let assetID = await onPickImageAsset() else { return }
            editor.updateLayer(id: layerID, name: "Replace Image") {
                guard case .image(var value) = $0 else { return }
                value.assetId = assetID
                $0 = .image(value)
            }
        }
    }

    private func addMask(forLayer layerID: String) {
        guard let onPickImageAsset else { return }
        Task { @MainActor in
            guard let assetID = await onPickImageAsset() else { return }
            editor.updateLayer(id: layerID, name: "Add Mask") {
                guard case .image(var value) = $0 else { return }
                value.maskAssetId = assetID
                $0 = .image(value)
            }
        }
    }
}
#endif
