#if os(iOS)
import SwiftUI

/// The canvas: the artwork, a selection overlay, and the gestures that move it.
///
/// The stage takes the canvas's aspect ratio as its own and frames `AnimatedIconFrame` to the rect
/// that produces, rather than letting the frame's internal `.aspectRatio(_, contentMode: .fit)` do
/// the fitting. That collapses the inner modifier to a no-op and makes one rect serve as the
/// artwork's bounds, the backdrop's bounds, and the gesture surface — so a gesture's local
/// coordinates *are* canvas coordinates and no call site here does offset arithmetic.
struct AnimatedEditorStage: View {
    @Bindable var editor: AnimatedDocumentEditor
    let assets: any AnimatedAssetProvider
    var backdrop: AnimatedEditorBackdrop = .checkerboard

    /// The value each gesture started from, captured on its first change event.
    ///
    /// SwiftUI reports translation, magnification, and rotation relative to the gesture's start, so
    /// the reducers need the starting value — and reading it back from the document every frame
    /// would compound each delta onto the previous result.
    @State private var activeDrag: StageDrag?
    @State private var scaleOrigin: AnimatedPoint?
    @State private var rotationOrigin: Double?

    /// The text layer a double tap opened for editing, if any.
    @State private var editingTextLayerID: String?
    @FocusState private var textFieldFocused: Bool

    /// What the single drag gesture resolved to when it began.
    ///
    /// One gesture serves both moving and corner-scaling, rather than the handles carrying their own
    /// recognisers. Gestures on child views inside the overlay's `scaleEffect`/`rotationEffect`
    /// would report translation in a rotated space *and* race the stage's own drag for the same
    /// touch — whichever won would depend on recogniser ordering. Deciding once from
    /// `startLocation` is deterministic and unit-testable.
    private enum StageDrag: Equatable {
        case move(layerID: String, start: AnimatedPoint)
        case scale(layerID: String, handle: AnimatedCanvasHandle, start: AnimatedPoint, rotationDegrees: Double, box: CGSize)

        var coalescingKey: String {
            switch self {
            case .move(let id, _): "drag-\(id)"
            case .scale(let id, _, _, _, _): "scale-\(id)"
            }
        }
    }

    /// The canvas's shape, guarded against the degenerate values a malformed document could hold.
    ///
    /// `.aspectRatio` with zero, a negative, or a NaN does not fail loudly — it produces a view with
    /// no valid size, and every coordinate derived from it afterwards is NaN.
    private var canvasAspectRatio: Double {
        let ratio = editor.document.canvas.aspectRatio
        return ratio.isFinite && ratio > 0 ? ratio : 1
    }

    var body: some View {
        GeometryReader { proxy in
            // Still computed rather than assumed to be the full proxy: `.aspectRatio` above already
            // fits the container, so this normally returns the whole of `proxy.size` — but it also
            // absorbs the `.zero` a `GeometryReader` reports on its first layout pass, which would
            // otherwise divide by zero in every gesture reducer.
            let rect = AnimatedCanvasGeometry.contentRect(in: proxy.size, aspectRatio: canvasAspectRatio)
            ZStack {
                backdrop.view

                artwork
            }
            // An overlay rather than a sibling in the stack: the outline carries the selected
            // layer's own transforms, and as a sibling its size fed back into the stack's layout —
            // so selecting a layer could move or drop the artwork it was meant to outline.
            .overlay {
                if let layer = editor.selectedLayer {
                    AnimatedEditorSelectionOverlay(
                        layer: layer,
                        state: AnimationInterpolator.state(for: layer, atDocumentTime: editor.scrubDocumentTime),
                        canvasSize: rect.size
                    )
                }
            }
            .frame(width: rect.width, height: rect.height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary, lineWidth: 1)
            }
            .position(x: rect.midX, y: rect.midY)
            .contentShape(Rectangle())
            // Exclusive, not simultaneous: a double tap must not also register as the single tap
            // that would reselect and dismiss the editor it just opened.
            .gesture(textEditGesture(in: rect).exclusively(before: selectionGesture(in: rect)))
            .simultaneousGesture(dragGesture(in: rect))
            .simultaneousGesture(magnifyGesture())
            .simultaneousGesture(rotateGesture())
        }
        // The stage's own layout carries the canvas's shape, rather than only the letterbox
        // arithmetic inside it.
        //
        // A `GeometryReader` is greedy: on its own it claims every point the container offers, and
        // in the iPad layout the container is a tall, narrow column. The backdrop and border then
        // drew as a tall sliver with a small square of artwork adrift inside it — the checkerboard
        // is meant to show what is transparent about *the sticker*, so it must be the sticker's
        // shape. Constraining it here means the shape is guaranteed by layout instead of computed,
        // and the leftover height goes back to the container as visible empty space rather than
        // being absorbed into something pretending to be the canvas.
        .aspectRatio(canvasAspectRatio, contentMode: .fit)
        .overlay(alignment: .bottom) { textEditingCard }
        .animation(.snappy(duration: 0.2), value: editingTextLayerID)
        .task(id: editor.isPlaying) { await playbackClock() }
    }

    /// Rendered through `AnimatedIconFrame` directly rather than `AnimatedIconView`.
    ///
    /// Two reasons. The editor owns its clock — `scrubDocumentTime` is the single source of truth
    /// for what instant is showing, so the canvas, the timeline playhead, and the readout can never
    /// disagree. And `AnimatedIconView` short-circuits to one settled frame under Reduce Motion,
    /// which would freeze the editor for exactly the people most likely to be stepping frame by
    /// frame.
    ///
    /// Deliberately *not* a `TimelineView`. One here would redraw on its own schedule while the
    /// model stood still, which is the bug this replaced: the artwork was re-rendered 30 times a
    /// second at an unchanging `scrubDocumentTime`, so pressing play swapped the icon and animated
    /// nothing.
    private var artwork: some View {
        AnimatedIconFrame(document: editor.displayDocument, documentTime: editor.scrubDocumentTime, assets: assets)
    }

    /// Advances the playhead while playing.
    ///
    /// Keyed on `isPlaying` so pausing cancels it and playing starts a fresh one. The editor
    /// computes each position from wall clock rather than accumulating per-tick deltas, so a
    /// stalled or coalesced tick shows up as a skipped frame instead of permanent drift.
    private func playbackClock() async {
        guard editor.isPlaying, editor.document.kind == .animated else { return }
        let interval = Duration.seconds(1 / Double(max(editor.document.fps, 1)))
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled, editor.advancePlayback() else { return }
        }
    }

    // MARK: - Gestures

    /// A tap selects the top-most layer under the finger, or clears the selection on empty canvas.
    private func selectionGesture(in rect: CGRect) -> some Gesture {
        SpatialTapGesture(coordinateSpace: .local).onEnded { value in
            // The ZStack is framed to `rect` and centred, so local points need the letterbox origin
            // removed before they mean anything in canvas space.
            let local = CGPoint(x: value.location.x - rect.minX, y: value.location.y - rect.minY)
            editor.selectedLayerID = AnimatedCanvasGeometry.hitTest(
                local,
                document: editor.displayDocument,
                atDocumentTime: editor.scrubDocumentTime,
                in: rect
            )
            editor.selectedKeyframe = nil
            // Selecting anything closes an open text field: leaving it up would let a keystroke land
            // on a layer that is no longer the one outlined on the canvas.
            endTextEditing()
        }
    }

    /// A double tap on a text layer opens its content for editing, in place.
    ///
    /// Only text responds. A double tap that lands on a shape or an image selects it and otherwise
    /// does nothing, which is the same outcome as the single tap it also is.
    private func textEditGesture(in rect: CGRect) -> some Gesture {
        SpatialTapGesture(count: 2, coordinateSpace: .local).onEnded { value in
            let local = CGPoint(x: value.location.x - rect.minX, y: value.location.y - rect.minY)
            let hit = AnimatedCanvasGeometry.hitTest(
                local,
                document: editor.displayDocument,
                atDocumentTime: editor.scrubDocumentTime,
                in: rect
            )
            editor.selectedLayerID = hit
            editor.selectedKeyframe = nil
            guard let hit, editor.displayDocument.layer(id: hit)?.isText == true else {
                endTextEditing()
                return
            }
            // Typing against moving artwork is unusable, and the layer being edited may well be
            // mid-flight across the canvas.
            editor.setPlaying(false)
            editingTextLayerID = hit
        }
    }

    // MARK: - Editing text in place

    /// The field a double tap opens, floating over the bottom of the stage.
    ///
    /// Deliberately not a sheet. A sheet would cover the artwork being retyped, which is the one
    /// thing worth seeing while retyping it, and every dismissal would fight the editor's own
    /// presentation. The inspector's text field remains the way to change font, weight, and colour.
    @ViewBuilder
    private var textEditingCard: some View {
        if let id = editingTextLayerID, case .text(let layer)? = editor.document.layer(id: id) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Text", text: textBinding(forLayer: id), axis: .vertical)
                    .font(.body)
                    .lineLimit(1...3)
                    .focused($textFieldFocused)
                    .submitLabel(.done)
                    .onSubmit { endTextEditing() }
                    .accessibilityIdentifier("canvas-text-editor")

                HStack {
                    // The cap is `AnimatedTextLayer.isValid`'s. Shown here as well as in the
                    // inspector, because this field is where the text is most likely to grow.
                    Text("\(layer.text.count)/160")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(layer.text.count > 160 ? Color.red : .secondary)
                    Spacer()
                    Button("Done") { endTextEditing() }
                        .font(.callout.weight(.semibold))
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onAppear { textFieldFocused = true }
        }
    }

    /// Writes straight through to the layer, so the canvas reflows as the user types.
    ///
    /// Shares its coalescing key with the inspector's field, which makes a typing session one undo
    /// step no matter which of the two the characters were typed into.
    private func textBinding(forLayer id: String) -> Binding<String> {
        Binding(
            get: {
                guard case .text(let layer)? = editor.document.layer(id: id) else { return "" }
                return layer.text
            },
            set: { newValue in
                editor.updateLayer(id: id, name: "Edit Text", coalescingKey: "text-\(id)") {
                    guard case .text(var value) = $0 else { return }
                    value.text = newValue
                    $0 = .text(value)
                }
            }
        )
    }

    private func endTextEditing() {
        guard editingTextLayerID != nil else { return }
        editingTextLayerID = nil
        textFieldFocused = false
        // Closes the undo step, so the next edit is separately undoable rather than merging into
        // the text that was just typed.
        editor.endGesture()
    }

    /// Moves the selected layer, or scales it when the drag started on a corner handle.
    private func dragGesture(in rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard let drag = activeDrag ?? resolveDrag(startingAt: value.startLocation, in: rect) else { return }
                if activeDrag == nil {
                    activeDrag = drag
                    editor.beginGesture(drag.coalescingKey)
                }
                switch drag {
                case .move(let id, let start):
                    editor.setPosition(
                        AnimatedCanvasGeometry.draggedPosition(start: start, translation: value.translation, in: rect),
                        forLayer: id
                    )
                case .scale(let id, let handle, let start, let rotationDegrees, let box):
                    editor.setScale(
                        AnimatedCanvasGeometry.handleScale(
                            start: start,
                            handle: handle,
                            translation: value.translation,
                            rotationDegrees: rotationDegrees,
                            box: box,
                            // Text renders at `min(x, y)` on both axes, so its drag starts from
                            // that collapsed scale rather than the stored pair.
                            uniform: editor.selectedLayer?.isText ?? false
                        ),
                        forLayer: id
                    )
                }
            }
            .onEnded { _ in
                activeDrag = nil
                editor.endGesture()
            }
    }

    /// Decides once, from where the finger went down, whether this drag scales or moves.
    ///
    /// Everything the reducer needs is captured here rather than read back each frame: the playhead
    /// can move under a drag (playback, or a scrub with a second finger), and a gesture that
    /// re-sampled its own starting values would fold the layer's animation into the drag.
    private func resolveDrag(startingAt location: CGPoint, in rect: CGRect) -> StageDrag? {
        guard let id = editor.selectedLayerID, let layer = editor.displayDocument.layer(id: id) else { return nil }
        let state = AnimationInterpolator.state(for: layer, atDocumentTime: editor.scrubDocumentTime)
        let local = CGPoint(x: location.x - rect.minX, y: location.y - rect.minY)
        if let handle = AnimatedCanvasGeometry.handleHitTest(local, layer: layer, state: state, in: rect) {
            return .scale(
                layerID: id,
                handle: handle,
                start: state.scale,
                rotationDegrees: state.rotationDegrees,
                box: AnimatedCanvasGeometry.layoutBox(canvasSize: rect.size, isParticle: layer.type == .particle)
            )
        }
        return .move(layerID: id, start: state.position)
    }

    private func magnifyGesture() -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                guard let id = editor.selectedLayerID else { return }
                let start = scaleOrigin ?? currentState(id)?.scale ?? .unit
                if scaleOrigin == nil {
                    scaleOrigin = start
                    editor.beginGesture("scale-\(id)")
                }
                editor.setScale(
                    AnimatedCanvasGeometry.magnifiedScale(
                        start: start,
                        magnification: value.magnification,
                        // Text is rendered at `min(x, y)` on both axes, so an unequal pair would
                        // make the inspector describe a render that never happens.
                        uniform: editor.selectedLayer?.isText ?? false
                    ),
                    forLayer: id
                )
            }
            .onEnded { _ in
                scaleOrigin = nil
                editor.endGesture()
            }
    }

    private func rotateGesture() -> some Gesture {
        RotateGesture(minimumAngleDelta: .degrees(1))
            .onChanged { value in
                guard let id = editor.selectedLayerID else { return }
                let start = rotationOrigin ?? currentState(id)?.rotationDegrees ?? 0
                if rotationOrigin == nil {
                    rotationOrigin = start
                    editor.beginGesture("rotate-\(id)")
                }
                editor.setRotation(
                    AnimatedCanvasGeometry.rotatedDegrees(start: start, delta: value.rotation.degrees),
                    forLayer: id
                )
            }
            .onEnded { _ in
                rotationOrigin = nil
                editor.endGesture()
            }
    }

    private func currentState(_ id: String) -> AnimatedLayerState? {
        editor.displayDocument.layer(id: id).map {
            AnimationInterpolator.state(for: $0, atDocumentTime: editor.scrubDocumentTime)
        }
    }

    // Note: canvas gestures are deliberately *not* gated on whether a layer's motion is declarative.
    // Drag, pinch, and rotate all write the anchor, and `settingAnchor` recompiles the specs against
    // it, so both representations stay in agreement. Forcing a detach just to move a layer whose
    // motion happens to be a preset would be gratuitous. The detach prompt lives in the timeline,
    // which is where keyframes actually become editable.
}

/// What sits behind the artwork on the stage.
enum AnimatedEditorBackdrop: String, CaseIterable, Identifiable {
    case checkerboard, light, dark
    var id: Self { self }

    var label: String {
        switch self {
        case .checkerboard: "Transparent"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    @ViewBuilder
    var view: some View {
        switch self {
        case .checkerboard: AnimatedCheckerboard()
        case .light: Color(white: 0.97)
        case .dark: Color(white: 0.10)
        }
    }
}
#endif
