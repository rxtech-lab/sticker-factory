#if os(iOS)
import SwiftUI

/// The property panel for the selected layer.
///
/// Three sections in a fixed order: what every layer has, what this *kind* of layer has, and its
/// motion. Keeping the common section first means the controls a user reaches for most — name,
/// visibility, position, size — never move when they switch between layer kinds.
struct AnimatedEditorInspector: View {
    @Bindable var editor: AnimatedDocumentEditor
    let assets: any AnimatedAssetProvider
    var onRequestImageAsset: ((String) -> Void)?
    var onRequestMaskAsset: ((String) -> Void)?

    var body: some View {
        Form {
            if let layer = editor.selectedLayer {
                commonSection(layer)
                transformSection(layer)
                typeSection(layer)
                motionSection(layer)
            } else {
                ContentUnavailableView {
                    AnimatedCartoonLabel("No Layer Selected", icon: "square.dashed")
                } description: {
                    Text("Tap a layer on the canvas or in the layer list.")
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Common

    @ViewBuilder
    private func commonSection(_ layer: AnimatedLayer) -> some View {
        Section("Layer") {
            TextField("Name", text: Binding(
                get: { layer.name },
                set: { editor.renameLayer(id: layer.id, to: $0) }
            ))

            Toggle("Visible", isOn: Binding(
                get: { !layer.hidden },
                set: { editor.setHidden(!$0, forLayer: layer.id) }
            ))

            Picker("Blend Mode", selection: Binding(
                get: { layer.blendMode },
                set: { editor.setBlendMode($0, forLayer: layer.id) }
            )) {
                ForEach(AnimatedBlendMode.allCases, id: \.self) { Text($0.editorLabel).tag($0) }
            }

            LabeledContent("Kind") {
                AnimatedCartoonLabel(verbatim: layer.type.editorLabel, icon: layer.type.editorSymbol)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Position, size, rotation, opacity, trim — the channels a canvas gesture also drives.
    ///
    /// Every control here writes through the same `applying…` path the gestures use, so a slider
    /// and a drag land on the same target: the anchor when the channel is empty, the keyframe under
    /// the playhead when it is not.
    @ViewBuilder
    private func transformSection(_ layer: AnimatedLayer) -> some View {
        let state = AnimationInterpolator.state(for: layer, atDocumentTime: editor.scrubDocumentTime)

        Section {
            AnimatedPointSlider(
                title: "Position",
                point: Binding(
                    get: { state.position },
                    set: { editor.setPosition($0, forLayer: layer.id) }
                ),
                range: -1...2,
                onEditingChanged: gesture("position-\(layer.id)")
            )

            AnimatedPointSlider(
                title: layer.isText ? "Size" : "Scale",
                point: Binding(
                    get: { AnimatedCanvasGeometry.renderedScale(state.scale, isText: layer.isText) },
                    set: { editor.setScale($0, forLayer: layer.id) }
                ),
                range: 0.05...8,
                // Text renders at `min(x, y)` on both axes, so two sliders would let the panel
                // display numbers the renderer ignores.
                uniform: layer.isText,
                onEditingChanged: gesture("scale-\(layer.id)")
            )

            AnimatedValueSlider(
                title: "Rotation",
                value: Binding(
                    get: { state.rotationDegrees },
                    set: { editor.setRotation($0, forLayer: layer.id) }
                ),
                range: AnimatedCanvasGeometry.anchorRotationRange,
                step: 1,
                format: "%.0f°",
                onEditingChanged: gesture("rotation-\(layer.id)")
            )

            AnimatedValueSlider(
                title: "Opacity",
                value: Binding(
                    get: { state.opacity },
                    set: { editor.setOpacity($0, forLayer: layer.id) }
                ),
                range: 0...1,
                step: nil,
                onEditingChanged: gesture("opacity-\(layer.id)")
            )

            if layer.supportsTrim {
                AnimatedValueSlider(
                    title: "Trim Start",
                    value: Binding(
                        get: { state.trim.start },
                        set: { editor.setTrim(.init(start: $0, end: state.trim.end), forLayer: layer.id) }
                    ),
                    range: 0...1,
                    step: nil,
                    onEditingChanged: gesture("trim-\(layer.id)")
                )
                AnimatedValueSlider(
                    title: "Trim End",
                    value: Binding(
                        get: { state.trim.end },
                        set: { editor.setTrim(.init(start: state.trim.start, end: $0), forLayer: layer.id) }
                    ),
                    range: 0...1,
                    step: nil,
                    onEditingChanged: gesture("trim-\(layer.id)")
                )
            }
        } header: {
            Text("Transform")
        } footer: {
            AnimatedEditTargetCaption(editor: editor)
        }
    }

    // MARK: - Type-specific

    @ViewBuilder
    private func typeSection(_ layer: AnimatedLayer) -> some View {
        switch layer {
        case .image(let value):
            AnimatedImageLayerInspector(
                editor: editor,
                layer: value,
                assets: assets,
                onRequestImageAsset: onRequestImageAsset,
                onRequestMaskAsset: onRequestMaskAsset
            )
        case .text(let value):
            AnimatedTextLayerInspector(editor: editor, layer: value)
        case .shape(let value):
            AnimatedShapeLayerInspector(editor: editor, layer: value)
        case .svg(let value):
            AnimatedSVGLayerInspector(editor: editor, layer: value)
        case .particle(let value):
            AnimatedParticleLayerInspector(editor: editor, layer: value)
        case .sequence(let value):
            AnimatedSequenceLayerInspector(editor: editor, layer: value, assets: assets)
        case .video(let value):
            AnimatedVideoLayerInspector(editor: editor, layer: value, assets: assets)
        case .sprite(let value):
            AnimatedSpriteLayerInspector(editor: editor, layer: value, assets: assets)
        case .unsupported:
            AnimatedUnsupportedLayerInspector()
        }
    }

    // MARK: - Motion

    /// Always present, even for a layer with no motion — this is where you find out *why* the
    /// timeline will not let you edit a layer's keyframes.
    @ViewBuilder
    private func motionSection(_ layer: AnimatedLayer) -> some View {
        if !layer.animations.isEmpty {
            Section {
                ForEach(Array(layer.animations.enumerated()), id: \.offset) { _, spec in
                    LabeledContent(spec.type.editorLabel) {
                        Text(String(format: "%.2fs → %.2fs", spec.delay, spec.endSeconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    editor.detachAnimations(forLayer: layer.id)
                } label: {
                    Label("Convert to Keyframes", systemImage: "diamond")
                }
            } header: {
                AnimatedCartoonLabel("Preset Motion", icon: "wand.and.stars")
            } footer: {
                Text("""
                    These presets generate this layer's \(layer.animation.keyframeCount) keyframes, so the \
                    timeline can't edit them directly. Converting makes them editable, but they will no \
                    longer re-time themselves when the duration changes.
                    """)
            }
        } else if layer.animation.isEmpty {
            Section("Motion") {
                Text("This layer doesn't move. Add a keyframe from the timeline to animate it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Wires a slider's drag to the editor's undo coalescing, so one drag is one undo step.
    private func gesture(_ key: String) -> (Bool) -> Void {
        { editing in
            if editing { editor.beginGesture(key) } else { editor.endGesture() }
        }
    }
}

extension AnimationEffectType {
    var editorLabel: String {
        switch self {
        case .fadeIn: "Fade In"
        case .fadeOut: "Fade Out"
        case .popIn: "Pop In"
        case .popOut: "Pop Out"
        case .slideIn: "Slide In"
        case .slideOut: "Slide Out"
        case .moveTo: "Move To"
        case .arcTo: "Arc To"
        case .scaleTo: "Scale To"
        case .rotateTo: "Rotate To"
        case .spin: "Spin"
        case .wiggle: "Wiggle"
        case .pulse: "Pulse"
        case .bounce: "Bounce"
        case .float: "Float"
        case .blurIn: "Blur In"
        case .blurOut: "Blur Out"
        case .hueShift: "Hue Shift"
        case .drawOn: "Draw On"
        case .drawOff: "Draw Off"
        case .trimTo: "Trim To"
        case .wipeIn: "Wipe In"
        case .wipeOut: "Wipe Out"
        case .wipeTo: "Wipe To"
        case .shine: "Shine"
        case .bloomIn: "Bloom In"
        case .bloomOut: "Bloom Out"
        case .bloomPulse: "Bloom Pulse"
        }
    }
}
#endif
