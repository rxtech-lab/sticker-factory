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
    public var controlLimits: AnimatedEditorControlLimits?

    public init(
        allowsCanvasResize: Bool = true,
        allowsKindChange: Bool = true,
        allowedLayerTypes: Set<AnimatedLayerType> = Set(AnimatedLayerType.allCases),
        controlLimits: AnimatedEditorControlLimits? = nil
    ) {
        self.allowsCanvasResize = allowsCanvasResize
        self.allowsKindChange = allowsKindChange
        self.allowedLayerTypes = allowedLayerTypes
        self.controlLimits = controlLimits
    }
}

public struct AnimatedEditorControlLimits: Sendable {
    public var controls: Int
    public var controlOptions: Int
    public var variants: Int
    public var layerCombinations: Int
    public var preparedStates: Int

    public init(controls: Int, controlOptions: Int, variants: Int, layerCombinations: Int, preparedStates: Int) {
        self.controls = controls
        self.controlOptions = controlOptions
        self.variants = variants
        self.layerCombinations = layerCombinations
        self.preparedStates = preparedStates
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
    private let onRequestAIArtwork: ((String) -> Void)?

    @State private var editor: AnimatedDocumentEditor
    @State private var pane = Pane.layers
    @State private var backdrop = AnimatedEditorBackdrop.checkerboard
    @State private var showsSettings = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    public init(
        document: Binding<AnimatedDocument>,
        assets: any AnimatedAssetProvider = EmptyAnimatedAssets(),
        configuration: AnimatedEditorConfiguration = .init(),
        onPickImageAsset: (@MainActor () async -> String?)? = nil,
        onRequestAIArtwork: ((String) -> Void)? = nil
    ) {
        self._document = document
        self.assets = assets
        self.configuration = configuration
        self.onPickImageAsset = onPickImageAsset
        self.onRequestAIArtwork = onRequestAIArtwork
        self._editor = State(initialValue: AnimatedDocumentEditor(document: document.wrappedValue))
    }

    private enum Pane: String, CaseIterable, Identifiable {
        case layers, style, motion, controls
        var id: Self { self }
        var label: String {
            switch self {
            case .layers: "Layers"
            case .style: "Style"
            case .motion: "Motion"
            case .controls: "Controls"
            }
        }
    }

    public var body: some View {
        Group {
            if sizeClass == .regular {
                regularLayout
            } else if verticalSizeClass == .compact {
                landscapeLayout
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
                    .frame(height: AnimatedEditorTimeline.compactHeight)
            }

            panePicker

            paneContent
                .frame(height: 280)
        }
    }

    /// iPhone in landscape: two columns.
    ///
    /// Stacking works on a tall screen and nowhere else — in landscape the canvas, the timeline, and
    /// a 280pt pane add up to more than the screen is tall, so the canvas takes the left half and
    /// everything that edits it moves to a column on the right.
    private var landscapeLayout: some View {
        HStack(spacing: 0) {
            AnimatedEditorStage(editor: editor, assets: assets, backdrop: backdrop)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)

            Divider()

            VStack(spacing: 0) {
                transport

                if editor.document.kind == .animated, pane == .motion {
                    AnimatedEditorTimeline(editor: editor)
                        .frame(maxHeight: AnimatedEditorTimeline.compactHeight)
                }

                panePicker

                paneContent
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 380)
        }
    }

    private var panePicker: some View {
        Picker("Pane", selection: $pane) {
            ForEach(Pane.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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

            VStack(spacing: 0) {
                panePicker
                paneContent
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
        case .controls:
            AnimatedEditorControlsPane(
                editor: editor,
                assets: assets,
                limits: configuration.controlLimits,
                onRequestImageAsset: { replaceOptionArtwork() },
                onRequestAIArtwork: onRequestAIArtwork
            )
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
                AnimatedCartoonSymbol(editor.isPlaying ? "pause.fill" : "play.fill")
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
                ForEach(AnimatedEditorBackdrop.allCases) {
                    AnimatedCartoonSymbol(symbol(for: $0)).tag($0)
                }
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
            Button {
                editor.undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
                .disabled(!editor.canUndo)
            Button {
                editor.redo()
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
                .disabled(!editor.canRedo)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            AnimatedAddLayerMenu(
                editor: editor,
                allowedLayerTypes: configuration.allowedLayerTypes,
                canAddImageLayers: onPickImageAsset != nil,
                onRequestImageAsset: { pickImageAsset() }
            )
            Button {
                showsSettings = true
            } label: {
                Label("Sticker Settings", systemImage: "slider.horizontal.3")
            }
        }
    }

    /// Non-blocking by design: the document is allowed to sit invalid while it is being edited, and
    /// only the host's save path calls `validated()`.
    @ViewBuilder
    private var issueBanner: some View {
        if let issue = editor.issues.first {
            AnimatedCartoonLabel(
                verbatim: issue.message,
                icon: issue.severity == .blocking ? "exclamationmark.triangle.fill" : "info.circle"
            )
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
            AnimatedCartoonLabel(
                verbatim: error.errorDescription ?? "That edit was not possible.",
                icon: "exclamationmark.circle"
            )
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

    private func replaceOptionArtwork() {
        guard let onPickImageAsset, let layerID = editor.selectedLayerID else { return }
        Task { @MainActor in
            guard let assetID = await onPickImageAsset() else { return }
            editor.setOptionArtwork(.init(kind: .image, assetId: assetID), forLayer: layerID)
        }
    }
}
#endif
