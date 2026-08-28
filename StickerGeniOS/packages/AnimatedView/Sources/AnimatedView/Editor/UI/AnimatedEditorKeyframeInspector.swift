#if os(iOS)
import SwiftUI

/// The selected keyframe: when it happens, what it holds, and how it eases in.
struct AnimatedEditorKeyframeInspector: View {
    @Bindable var editor: AnimatedDocumentEditor

    private var selection: AnimatedKeyframeSelection? { editor.selectedKeyframe }

    var body: some View {
        Form {
            if let selection,
               let layer = editor.document.layer(id: selection.layerID),
               selection.index < layer.animation.count(of: selection.channel) {
                content(selection, layer)
            } else {
                ContentUnavailableView(
                    "No Keyframe Selected",
                    systemImage: "diamond",
                    description: Text("Tap a keyframe in the timeline to edit it.")
                )
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func content(_ selection: AnimatedKeyframeSelection, _ layer: AnimatedLayer) -> some View {
        let times = layer.animation.times(on: selection.channel)
        let time = times[selection.index]

        Section {
            LabeledContent("Channel") {
                Label(selection.channel.label, systemImage: selection.channel.symbolName)
                    .foregroundStyle(.secondary)
            }
            AnimatedNumberField(
                title: "Time",
                value: Binding(
                    get: { time },
                    set: {
                        editor.moveKeyframe(
                            on: selection.channel, forLayer: selection.layerID, index: selection.index, toTime: $0
                        )
                    }
                ),
                range: 0...editor.document.durationSeconds
            )
        } header: {
            Text("Keyframe \(selection.index + 1) of \(times.count)")
        }

        Section {
            AnimatedEasingPicker(
                easing: Binding(
                    get: { layer.animation.easing(on: selection.channel, index: selection.index) ?? .linear },
                    set: {
                        editor.setKeyframeEasing(
                            $0, on: selection.channel, forLayer: selection.layerID, index: selection.index
                        )
                    }
                ),
                isEnabled: selection.index > 0
            )
        } header: {
            Text("Easing")
        } footer: {
            // Not a quirk worth hiding: the interpolator reads easing from the *upper* keyframe of
            // the pair it is blending, so the first keyframe of a channel has no incoming segment
            // and its easing can never be observed.
            Text(selection.index == 0
                ? "Easing applies to the segment ending at a keyframe, so it has no effect on the first one."
                : "Applies to the segment ending at this keyframe.")
        }

        valueSection(selection, layer)

        Section {
            Button("Delete Keyframe", systemImage: "trash", role: .destructive) {
                editor.removeKeyframe(on: selection.channel, forLayer: selection.layerID, index: selection.index)
            }
        }
    }

    @ViewBuilder
    private func valueSection(_ selection: AnimatedKeyframeSelection, _ layer: AnimatedLayer) -> some View {
        let animation = layer.animation
        let index = selection.index

        Section("Value") {
            switch selection.channel {
            case .position:
                AnimatedPointSlider(
                    title: "Position",
                    point: Binding(
                        get: { AnimatedPoint(x: animation.position[index].x, y: animation.position[index].y) },
                        set: { value in edit(selection) { try $0.settingPosition(value, index: index) } }
                    ),
                    range: -1...2,
                    onEditingChanged: gesture(selection)
                )

            case .scale:
                AnimatedPointSlider(
                    title: "Scale",
                    point: Binding(
                        get: { AnimatedPoint(x: animation.scale[index].x, y: animation.scale[index].y) },
                        set: { value in edit(selection) { try $0.settingScale(value, index: index) } }
                    ),
                    range: 0.05...8,
                    uniform: layer.isText,
                    onEditingChanged: gesture(selection)
                )

            case .rotation:
                AnimatedValueSlider(
                    title: "Rotation",
                    value: Binding(
                        get: { animation.rotation[index].degrees },
                        set: { value in edit(selection) { try $0.settingRotation(value, index: index) } }
                    ),
                    range: AnimatedCanvasGeometry.keyframeRotationRange,
                    step: 1,
                    format: "%.0f\u{00B0}",
                    onEditingChanged: gesture(selection)
                )

            case .opacity:
                AnimatedValueSlider(
                    title: "Opacity",
                    value: Binding(
                        get: { animation.opacity[index].value },
                        set: { value in edit(selection) { try $0.settingOpacity(value, index: index) } }
                    ),
                    range: 0...1,
                    step: nil,
                    onEditingChanged: gesture(selection)
                )

            case .effects:
                let effect = animation.effects[index]
                AnimatedValueSlider(
                    title: "Blur",
                    value: Binding(
                        get: { effect.blurRadius },
                        set: { value in
                            edit(selection) {
                                try $0.settingEffects(effect.value.with(blurRadius: value), index: index)
                            }
                        }
                    ),
                    range: 0...20,
                    step: nil,
                    onEditingChanged: gesture(selection)
                )
                AnimatedValueSlider(
                    title: "Hue",
                    value: Binding(
                        get: { effect.hueDegrees },
                        set: { value in
                            edit(selection) {
                                try $0.settingEffects(effect.value.with(hueDegrees: value), index: index)
                            }
                        }
                    ),
                    range: -180...180,
                    step: 1,
                    format: "%.0f\u{00B0}",
                    onEditingChanged: gesture(selection)
                )
                AnimatedValueSlider(
                    title: "Saturation",
                    value: Binding(
                        get: { effect.saturation },
                        set: { value in
                            edit(selection) {
                                try $0.settingEffects(effect.value.with(saturation: value), index: index)
                            }
                        }
                    ),
                    range: 0...2,
                    step: nil,
                    onEditingChanged: gesture(selection)
                )

            case .trim:
                let trim = animation.trim[index]
                AnimatedValueSlider(
                    title: "Start",
                    value: Binding(
                        get: { trim.start },
                        set: { value in
                            edit(selection) { try $0.settingTrim(.init(start: value, end: trim.end), index: index) }
                        }
                    ),
                    range: 0...1,
                    step: nil,
                    onEditingChanged: gesture(selection)
                )
                AnimatedValueSlider(
                    title: "End",
                    value: Binding(
                        get: { trim.end },
                        set: { value in
                            edit(selection) { try $0.settingTrim(.init(start: trim.start, end: value), index: index) }
                        }
                    ),
                    range: 0...1,
                    step: nil,
                    onEditingChanged: gesture(selection)
                )

            case .wipe:
                let wipe = animation.wipe[index]
                AnimatedValueSlider(
                    title: "Start",
                    value: Binding(
                        get: { wipe.start },
                        set: { value in
                            edit(selection) { try $0.settingWipe(wipe.value.with(start: value), index: index) }
                        }
                    ),
                    range: 0...1,
                    step: nil,
                    onEditingChanged: gesture(selection)
                )
                AnimatedValueSlider(
                    title: "End",
                    value: Binding(
                        get: { wipe.end },
                        set: { value in
                            edit(selection) { try $0.settingWipe(wipe.value.with(end: value), index: index) }
                        }
                    ),
                    range: 0...1,
                    step: nil,
                    onEditingChanged: gesture(selection)
                )
                AnimatedValueSlider(
                    title: "Angle",
                    value: Binding(
                        get: { wipe.angleDegrees },
                        set: { value in
                            edit(selection) { try $0.settingWipe(wipe.value.with(angleDegrees: value), index: index) }
                        }
                    ),
                    range: -360...360,
                    step: 1,
                    format: "%.0f\u{00B0}",
                    onEditingChanged: gesture(selection)
                )
                AnimatedValueSlider(
                    title: "Softness",
                    value: Binding(
                        get: { wipe.softness },
                        set: { value in
                            edit(selection) { try $0.settingWipe(wipe.value.with(softness: value), index: index) }
                        }
                    ),
                    range: 0...0.5,
                    step: nil,
                    onEditingChanged: gesture(selection)
                )

            case .sheen:
                let sheen = animation.sheen[index]
                AnimatedValueSlider(
                    title: "Position",
                    value: Binding(
                        get: { sheen.position },
                        set: { value in
                            edit(selection) { try $0.settingSheen(sheen.value.with(position: value), index: index) }
                        }
                    ),
                    // Wider than the layer on purpose: the band has to be parkable off both edges.
                    range: -1...2,
                    step: nil,
                    onEditingChanged: gesture(selection)
                )
                AnimatedValueSlider(
                    title: "Width",
                    value: Binding(
                        get: { sheen.width },
                        set: { value in
                            edit(selection) { try $0.settingSheen(sheen.value.with(width: value), index: index) }
                        }
                    ),
                    range: 0.02...1,
                    step: nil,
                    onEditingChanged: gesture(selection)
                )
                AnimatedValueSlider(
                    title: "Angle",
                    value: Binding(
                        get: { sheen.angleDegrees },
                        set: { value in
                            edit(selection) { try $0.settingSheen(sheen.value.with(angleDegrees: value), index: index) }
                        }
                    ),
                    range: -360...360,
                    step: 1,
                    format: "%.0f\u{00B0}",
                    onEditingChanged: gesture(selection)
                )
                AnimatedValueSlider(
                    title: "Intensity",
                    value: Binding(
                        get: { sheen.intensity },
                        set: { value in
                            edit(selection) { try $0.settingSheen(sheen.value.with(intensity: value), index: index) }
                        }
                    ),
                    range: 0...1,
                    step: nil,
                    onEditingChanged: gesture(selection)
                )

            case .glow:
                let glow = animation.glow[index]
                AnimatedValueSlider(
                    title: "Amount",
                    value: Binding(
                        get: { glow.amount },
                        set: { value in
                            edit(selection) { try $0.settingGlow(.init(amount: value, radius: glow.radius), index: index) }
                        }
                    ),
                    range: 0...1,
                    step: nil,
                    onEditingChanged: gesture(selection)
                )
                AnimatedValueSlider(
                    title: "Radius",
                    value: Binding(
                        get: { glow.radius },
                        set: { value in
                            edit(selection) { try $0.settingGlow(.init(amount: glow.amount, radius: value), index: index) }
                        }
                    ),
                    range: 0.01...0.5,
                    step: nil,
                    onEditingChanged: gesture(selection)
                )
            }
        }
    }

    /// Routes a channel edit through the editor so it lands in the undo history like any other.
    private func edit(
        _ selection: AnimatedKeyframeSelection,
        _ body: @escaping (AnimatedLayerAnimation) throws -> AnimatedLayerAnimation
    ) {
        editor.applyKeyframeEdit(forLayer: selection.layerID, coalescingKey: coalescingKey(selection), body)
    }

    private func gesture(_ selection: AnimatedKeyframeSelection) -> (Bool) -> Void {
        { editing in
            if editing { editor.beginGesture(coalescingKey(selection)) } else { editor.endGesture() }
        }
    }

    private func coalescingKey(_ selection: AnimatedKeyframeSelection) -> String {
        "kf-\(selection.layerID)-\(selection.channel.rawValue)-\(selection.index)"
    }
}
#endif
