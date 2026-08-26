#if os(iOS)
import SwiftUI

/// The layer stack, top-most first.
///
/// `AnimatedIconFrame` draws `ForEach(document.layers)` in array order, so **index 0 is the
/// bottom-most layer**. Every layers panel anyone has used shows the top-most first, so this list
/// renders the array reversed and translates indices at the boundary. `.onMove`'s destination
/// semantics under a reversed array are the classic place that goes wrong, which is why the mapping
/// is a named function with its own unit test rather than arithmetic inlined into the closure.
struct AnimatedEditorLayerList: View {
    @Bindable var editor: AnimatedDocumentEditor
    /// Image layers are only offerable when the host can resolve an asset for one.
    var canAddImageLayers: Bool
    var allowedLayerTypes: Set<AnimatedLayerType>
    var onRequestImageAsset: (() -> Void)?

    /// The layer a swipe has proposed deleting, held until the confirmation resolves.
    ///
    /// Stored as an id rather than the layer itself so it cannot go stale: the document can change
    /// while the dialog is up, and acting on a captured copy would delete by a name and index that
    /// no longer describe anything.
    @State private var pendingDeletion: String?

    /// Display order is the model array reversed.
    private var displayLayers: [AnimatedLayer] { editor.document.layers.reversed() }

    private func modelIndex(displayIndex: Int) -> Int {
        AnimatedLayerListOrder.modelIndex(displayIndex: displayIndex, count: editor.document.layers.count)
    }

    var body: some View {
        List(selection: $editor.selectedLayerID) {
            Section {
                ForEach(displayLayers) { layer in
                    row(layer)
                        .tag(layer.id)
                }
                // Deliberately no `.onDelete`. Its red minus badge only appears in edit mode, and
                // edit mode is mutually exclusive with `.swipeActions` — a row cannot offer both.
                // Swiping is the gesture people reach for, and it is the only one that can also
                // offer Duplicate.
                .onMove(perform: move)
            } header: {
                HStack {
                    Text("Layers")
                    Spacer()
                    Text("\(editor.document.layers.count)/\(AnimatedDocument.maximumLayerCount)")
                        .monospacedDigit()
                        .foregroundStyle(editor.document.layers.count >= AnimatedDocument.maximumLayerCount ? .orange : .secondary)
                }
            } footer: {
                if editor.document.layers.isEmpty {
                    Text("Add a layer to start building this sticker.")
                } else {
                    // Both gestures are now the only way to reorder and to delete, and neither has
                    // a visible control, so the footer has to say so.
                    Text("The top of this list draws in front. Press and hold to reorder, swipe left to duplicate or delete.")
                }
            }

            // An empty document needs an obvious way forward that does not depend on finding the
            // toolbar; the same menu also stays available once there are layers.
            Section {
                AnimatedAddLayerMenu(
                    editor: editor,
                    allowedLayerTypes: allowedLayerTypes,
                    canAddImageLayers: canAddImageLayers,
                    onRequestImageAsset: onRequestImageAsset
                )
            }
        }
        .listStyle(.insetGrouped)
        .confirmationDialog(
            deletionTitle,
            isPresented: confirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Layer", role: .destructive) {
                if let pendingDeletion { editor.removeLayer(id: pendingDeletion) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("This removes the layer and every keyframe on it. Undo can bring it back until you save.")
        }
    }

    private var deletionTitle: String {
        guard let pendingDeletion, let layer = editor.document.layer(id: pendingDeletion) else {
            return "Delete this layer?"
        }
        return "Delete \(layer.name)?"
    }

    /// Derived from the pending id rather than kept as a second `@State` flag, so the dialog and the
    /// thing it acts on cannot disagree about whether there is one.
    private var confirmingDeletion: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private func row(_ layer: AnimatedLayer) -> some View {
        HStack(spacing: 10) {
            Image(systemName: layer.type.editorSymbol)
                .frame(width: 22)
                .foregroundStyle(layer.hidden ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))

            VStack(alignment: .leading, spacing: 1) {
                Text(layer.name)
                    .lineLimit(1)
                    .foregroundStyle(layer.hidden ? .secondary : .primary)
                HStack(spacing: 6) {
                    Text(layer.type.editorLabel)
                    if !layer.animations.isEmpty {
                        // Worth surfacing in the list, not just the timeline: it changes what the
                        // timeline will let you do to this layer.
                        Label("Preset", systemImage: "wand.and.stars")
                    } else if !layer.animation.isEmpty {
                        Label("\(layer.animation.keyframeCount)", systemImage: "diamond.fill")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                editor.setHidden(!layer.hidden, forLayer: layer.id)
            } label: {
                Image(systemName: layer.hidden ? "eye.slash" : "eye")
                    .foregroundStyle(layer.hidden ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(layer.hidden ? "Show \(layer.name)" : "Hide \(layer.name)")
        }
        .contentShape(Rectangle())
        // `List(selection:)` alone used to be enough because the list was permanently in edit mode,
        // where a tap means "select". Outside edit mode a tap on a plain row is inert, so selecting
        // a layer is now explicit. Assigning the id the binding already holds is a no-op, so the two
        // paths cannot fight.
        .onTapGesture { editor.selectedLayerID = layer.id }
        .swipeActions(edge: .trailing) {
            // Asks rather than deleting outright. Undo would cover it, but the swipe is a single
            // gesture with no visible control, so it is easy to reach by accident — and a layer can
            // carry motion that took a while to build.
            Button("Delete", systemImage: "trash", role: .destructive) { pendingDeletion = layer.id }
            Button("Duplicate", systemImage: "plus.square.on.square") { editor.duplicateLayer(id: layer.id) }
                .tint(.indigo)
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        guard let displayIndex = source.first else { return }
        editor.moveLayer(
            id: displayLayers[displayIndex].id,
            toIndex: AnimatedLayerListOrder.modelDestination(
                displayDestination: destination,
                movingFrom: displayIndex,
                count: editor.document.layers.count
            )
        )
    }
}

/// The add-layer menu, shared by the toolbar and the empty state.
struct AnimatedAddLayerMenu: View {
    @Bindable var editor: AnimatedDocumentEditor
    var allowedLayerTypes: Set<AnimatedLayerType>
    var canAddImageLayers: Bool
    var onRequestImageAsset: (() -> Void)?

    private var availableTypes: [AnimatedLayerType] {
        AnimatedLayerType.allCases.filter { type in
            guard allowedLayerTypes.contains(type) else { return false }
            // A document carries no pixels, so an image layer is meaningless unless the host can
            // resolve an asset for it.
            return type != .image || canAddImageLayers
        }
    }

    var body: some View {
        Menu {
            ForEach(availableTypes, id: \.self) { type in
                Button {
                    if type == .image {
                        onRequestImageAsset?()
                    } else {
                        editor.addLayer(type)
                    }
                } label: {
                    Label(type.editorLabel, systemImage: type.editorSymbol)
                }
            }
        } label: {
            Label("Add Layer", systemImage: "plus")
        }
        .disabled(editor.document.layers.count >= AnimatedDocument.maximumLayerCount)
    }
}
#endif
