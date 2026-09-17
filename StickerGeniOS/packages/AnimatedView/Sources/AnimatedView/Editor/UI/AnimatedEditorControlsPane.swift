#if os(iOS)
import SwiftUI

/// Authors the controls that resolve a sticker into an option-specific document. The selected
/// option is also installed on `AnimatedDocumentEditor`, so the shared canvas is the preview and
/// its drag, pinch, rotate, visibility, motion, and stack edits write variant bindings.
struct AnimatedEditorControlsPane: View {
    @Bindable var editor: AnimatedDocumentEditor
    let assets: any AnimatedAssetProvider
    let limits: AnimatedEditorControlLimits?
    let onRequestImageAsset: (() -> Void)?
    let onRequestAIArtwork: ((String) -> Void)?
    @State private var editingControlID: String?
    @State private var showingAddControl = false
    @State private var showingCustomControl = false
    @State private var customKind = CustomControlKind.choice
    @State private var customTarget = CustomChoiceTarget.movement
    @State private var customName = "Custom"
    @State private var customFirstOption = "Option 1"
    @State private var customSecondOption = "Option 2"
    @State private var customDefaultVisible = true
    @State private var customDefaultSpeed = 1.0

    private enum CustomControlKind: String, CaseIterable, Identifiable {
        case choice = "Choice"
        case visibility = "Visibility"
        case speed = "Speed"
        var id: Self { self }
    }

    private enum CustomChoiceTarget: String, CaseIterable, Identifiable {
        case artwork = "Artwork"
        case movement = "Movement"
        case placement = "Placement"
        case visibility = "Visibility"
        case pose = "Pose"
        case mood = "Mood"
        var id: Self { self }
    }

    private var configuration: AnimatedControlConfiguration? { editor.document.configuration }
    private var controls: [AnimatedControl] { configuration?.controls ?? [] }
    private var selectedLayer: AnimatedLayer? { editor.selectedLayer }

    var body: some View {
        Form {
            Section {
                Text(editor.activeVariantID == nil ? "Editing base sticker" : "Editing this option")
                    .font(.headline)
                if editor.activeVariantID != nil {
                    Button("Return to base sticker") { editor.selectVariant(nil) }
                }
                if case .sprite(let sprite)? = selectedLayer,
                   sprite.clips.contains(where: { $0.faceCompositing == .overlay }),
                   let onRequestAIArtwork {
                    Button("Repair face overlap") {
                        onRequestAIArtwork("""
                        Repair face overlap on sprite layer \(sprite.base.id) with repair_sprite_faces. \
                        Preserve the current body artwork, controls, poses, expressions, placement, animation, and stacking.
                        """)
                    }
                }
            }

            ForEach(controls) { control in
                Section(control.label.isEmpty ? "Control" : control.label) {
                    TextField("Control name", text: Binding(
                        get: { current(control.id)?.label ?? control.label },
                        set: { value in updateControl(control.id) { $0.label = value } }
                    ))
                    switch control.type {
                    case .choice: choiceFields(control)
                    case .toggle: toggleFields(control)
                    case .number: speedFields(control)
                    }
                    Button("Remove control", role: .destructive) { removeControl(control) }
                }
            }

            Section {
                Button {
                    prepareCustomControl()
                    showingAddControl = true
                } label: {
                    Label("Add Control", systemImage: "plus.circle.fill")
                }
                .disabled(!canAddAnotherControl)
                .accessibilityIdentifier("add-control-button")
            }
        }
        .accessibilityIdentifier("animated-editor-controls-pane")
        .sheet(isPresented: $showingAddControl) { addControlSheet }
    }

    private var canAddAnotherControl: Bool {
        limits.map { controls.count < $0.controls } ?? true
    }

    private var customKinds: [CustomControlKind] {
        selectedLayer == nil ? [.speed] : CustomControlKind.allCases
    }

    private var availableCustomTargets: [CustomChoiceTarget] {
        guard let layer = selectedLayer else { return [] }
        let candidates: [CustomChoiceTarget] = switch layer {
        case .sprite: [.pose, .mood, .movement, .placement, .visibility]
        case .image, .sequence: [.artwork, .movement, .placement, .visibility]
        default: [.movement, .placement, .visibility]
        }
        return candidates.filter { targetIsAvailable($0, for: layer.id) }
    }

    private var addControlSheet: some View {
        NavigationStack {
            List {
                if let layer = selectedLayer {
                    Section("For \(layer.name)") {
                        switch layer {
                        case .sprite(let sprite):
                            controlTemplateButton("Pose", icon: "figure.stand", enabled: canAddChoice(
                                optionCount: sprite.clips.count, layerID: layer.id, target: .pose
                            )) {
                                addSpriteChoice(label: "Pose", values: sprite.clips.map { ($0.id, $0.id.capitalized) }, pose: true)
                            }
                            controlTemplateButton("Mood", icon: "face.smiling", enabled: canAddChoice(
                                optionCount: sprite.expressions.tiles.count, layerID: layer.id, target: .mood
                            )) {
                                addSpriteChoice(
                                    label: "Mood",
                                    values: sprite.expressions.tiles.map { ($0.id, $0.id.capitalized) },
                                    pose: false
                                )
                            }
                        case .image, .sequence:
                            controlTemplateButton("Artwork", icon: "photo.on.rectangle", enabled: canAddChoice(
                                optionCount: 2, layerID: layer.id, target: .artwork
                            )) { addChoice(label: "Artwork", artwork: true) }
                            controlTemplateButton("Movement", icon: "figure.walk.motion", enabled: canAddChoice(
                                optionCount: 2, layerID: layer.id, target: .movement
                            )) { addChoice(label: "Movement", artwork: false) }
                        default:
                            controlTemplateButton("Movement", icon: "figure.walk.motion", enabled: canAddChoice(
                                optionCount: 2, layerID: layer.id, target: .movement
                            )) { addChoice(label: "Movement", artwork: false) }
                        }
                        controlTemplateButton("Visibility", icon: "eye", enabled: canAddToggle(for: layer.id)) { addVisibility() }
                    }
                }

                Section("Sticker") {
                    controlTemplateButton("Speed", icon: "speedometer", enabled: canAddSpeed) { addSpeed() }
                }

                Section {
                    Button {
                        prepareCustomControl()
                        showingCustomControl = true
                    } label: {
                        Label("Custom Control", systemImage: "slider.horizontal.3")
                    }
                    .disabled(customKinds.isEmpty)
                } footer: {
                    Text("Create a named choice, visibility, or speed control with your own option labels.")
                }
            }
            .navigationTitle("Add Control")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("add-control-sheet")
            .navigationDestination(isPresented: $showingCustomControl) { customControlForm }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingAddControl = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var customControlForm: some View {
        Form {
            Section("Control") {
                TextField("Name", text: $customName)
                Picker("Type", selection: $customKind) {
                    ForEach(customKinds) { Text($0.rawValue).tag($0) }
                }
            }

            switch customKind {
            case .choice:
                Section("Options") {
                    TextField("First option", text: $customFirstOption)
                    TextField("Second option", text: $customSecondOption)
                    if !availableCustomTargets.isEmpty {
                        Picker("Changes", selection: $customTarget) {
                            ForEach(availableCustomTargets) { Text($0.rawValue).tag($0) }
                        }
                    } else {
                        Text("Every supported property on this layer already has a control.")
                            .foregroundStyle(.secondary)
                    }
                }
            case .visibility:
                Section("Default") { Toggle("Visible", isOn: $customDefaultVisible) }
            case .speed:
                Section("Default") {
                    Slider(value: $customDefaultSpeed, in: 0.25...2, step: 0.05)
                    Text("\(customDefaultSpeed, format: .number.precision(.fractionLength(2)))×")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Custom Control")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("custom-control-form")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") { createCustomControl() }
                    .disabled(!canCreateCustomControl)
            }
        }
        .onChange(of: customKind) { _, _ in selectAvailableCustomTarget() }
    }

    @ViewBuilder
    private func controlTemplateButton(
        _ title: String,
        icon: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            showingAddControl = false
        } label: {
            Label(title, systemImage: icon)
        }
        .disabled(!enabled)
    }

    private var canCreateCustomControl: Bool {
        let name = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAddAnotherControl, !name.isEmpty, name.count <= 80 else { return false }
        switch customKind {
        case .choice:
            let first = customFirstOption.trimmingCharacters(in: .whitespacesAndNewlines)
            let second = customSecondOption.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let layer = selectedLayer, availableCustomTargets.contains(customTarget),
                  !first.isEmpty, !second.isEmpty, first != second,
                  first.count <= 80, second.count <= 80 else { return false }
            return canAddChoice(optionCount: 2, layerID: layer.id, target: customTarget)
        case .visibility:
            return selectedLayer.map { canAddToggle(for: $0.id) } ?? false
        case .speed:
            return canAddSpeed
        }
    }

    private func prepareCustomControl() {
        customName = "Custom"
        customFirstOption = "Option 1"
        customSecondOption = "Option 2"
        customDefaultVisible = !(selectedLayer?.base.hidden ?? false)
        customDefaultSpeed = editor.document.speed
        customKind = selectedLayer == nil ? .speed : .choice
        selectAvailableCustomTarget()
    }

    private func selectAvailableCustomTarget() {
        if !availableCustomTargets.contains(customTarget), let first = availableCustomTargets.first {
            customTarget = first
        }
    }

    private func createCustomControl() {
        guard canCreateCustomControl else { return }
        let name = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch customKind {
        case .choice:
            addCustomChoice(
                label: name,
                firstLabel: customFirstOption.trimmingCharacters(in: .whitespacesAndNewlines),
                secondLabel: customSecondOption.trimmingCharacters(in: .whitespacesAndNewlines),
                target: customTarget
            )
        case .visibility:
            addVisibility(label: name, defaultVisible: customDefaultVisible)
        case .speed:
            addSpeed(label: name, defaultValue: customDefaultSpeed)
        }
        showingAddControl = false
    }

    @ViewBuilder
    private func choiceFields(_ control: AnimatedControl) -> some View {
        Picker("Option", selection: Binding(
            get: { selectedOption(control) },
            set: { select($0, control: control) }
        )) {
            ForEach(control.options ?? []) { Text($0.label).tag($0.id) }
        }
        ForEach(control.options ?? []) { option in
            HStack {
                TextField("Option name", text: Binding(
                    get: { current(control.id)?.options?.first(where: { $0.id == option.id })?.label ?? option.label },
                    set: { value in updateControl(control.id) { valueControl in
                        if let index = valueControl.options?.firstIndex(where: { $0.id == option.id }) {
                            valueControl.options?[index].label = value
                        }
                    } }
                ))
                Button(role: .destructive) { removeOption(option.id, control: control) } label: {
                    Image(systemName: "minus.circle")
                }
                .disabled((control.options?.count ?? 0) <= 2)
            }
        }
        Button("Add option") { addOption(control) }
            .disabled(!canAddOption(to: control))

        if editingControlID == control.id,
           let variant = activeVariant(for: control), editor.activeVariantID == variant.id {
            optionEditor(variant)
        }
    }

    @ViewBuilder
    private func optionEditor(_ variant: AnimatedVariant) -> some View {
        let layerIDs = Set(variant.layers.map(\.layerId))
        if !layerIDs.isEmpty {
            Text("Affected layers").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack {
                    ForEach(editor.displayDocument.layers.filter { layerIDs.contains($0.id) }) { layer in
                        VStack(spacing: 4) {
                            AnimatedIconFrame(document: isolated(layer), documentTime: editor.scrubDocumentTime, assets: assets)
                                .frame(width: 56, height: 56)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                            Text(layer.name).font(.caption2).lineLimit(1).frame(width: 64)
                        }
                    }
                }
            }
        }
        if let layer = selectedLayer {
            Toggle("Visible", isOn: Binding(
                get: { !layer.base.hidden },
                set: { editor.setOptionHidden(!$0, forLayer: layer.id) }
            ))
            optionArtwork(layer)
            optionMotion(layer)
            VStack(alignment: .leading) {
                Text("Position").font(.caption).foregroundStyle(.secondary)
                Slider(value: anchorValue(layer, \.position.x) { $0.position.x = $1 }, in: 0...1)
                Slider(value: anchorValue(layer, \.position.y) { $0.position.y = $1 }, in: 0...1)
                Text("Size").font(.caption).foregroundStyle(.secondary)
                Slider(value: anchorValue(layer, \.scale.x) { anchor, value in anchor.scale = .init(x: value, y: value) }, in: 0.05...2)
                Text("Rotation").font(.caption).foregroundStyle(.secondary)
                Slider(value: anchorValue(layer, \.rotationDegrees) { $0.rotationDegrees = $1 }, in: -180...180)
            }
            HStack {
                Button("Send backward") { moveSelectedLayer(-1) }
                Spacer()
                Button("Bring forward") { moveSelectedLayer(1) }
            }
        }
    }

    @ViewBuilder
    private func optionArtwork(_ layer: AnimatedLayer) -> some View {
        switch layer {
        case .image, .sequence:
            if onRequestImageAsset != nil { Button("Choose artwork from Photos") { onRequestImageAsset?() } }
            if let onRequestAIArtwork {
                Button("Request AI artwork") {
                    onRequestAIArtwork("""
                    Create a revised generation plan for new artwork on option \(editor.activeVariantID ?? "") \
                    and layer \(layer.id). Preserve every existing control, option, and layer id.
                    """)
                }
            }
        case .sprite(let sprite):
            Picker("Pose", selection: Binding(
                get: { sprite.clipId }, set: { editor.setOptionSpriteState(clip: $0, forLayer: layer.id) }
            )) { ForEach(sprite.clips) { Text($0.id.capitalized).tag($0.id) } }
            Picker("Mood", selection: Binding(
                get: { sprite.expressionId }, set: { editor.setOptionSpriteState(expression: $0, forLayer: layer.id) }
            )) { ForEach(sprite.expressions.tiles) { Text($0.id.capitalized).tag($0.id) } }
        default: EmptyView()
        }
    }

    private func optionMotion(_ layer: AnimatedLayer) -> some View {
        Picker("Movement", selection: Binding(
            get: { layer.base.animations.first?.type.rawValue ?? "still" },
            set: { value in
                let effect: AnimationEffect? = switch value {
                case "bounce": .bounce(height: 0.08, bounces: 2)
                case "wiggle": .wiggle(amplitudeDegrees: 8, cycles: 2)
                case "float": .float(amplitude: 0.04, cycles: 1)
                default: nil
                }
                editor.setOptionAnimations(effect.map { [AnimationSpec($0)] } ?? [], forLayer: layer.id)
            }
        )) {
            Text("Still").tag("still")
            Text("Bounce").tag("bounce")
            Text("Sway").tag("wiggle")
            Text("Float").tag("float")
        }
    }

    private func toggleFields(_ control: AnimatedControl) -> some View {
        Toggle("Visible by default", isOn: Binding(
            get: { current(control.id)?.defaultValue.bool ?? true },
            set: { value in updateControl(control.id) { $0.defaultValue = .bool(value) } }
        ))
    }

    private func speedFields(_ control: AnimatedControl) -> some View {
        Slider(value: Binding(
            get: { current(control.id)?.defaultValue.number ?? 1 },
            set: { value in updateControl(control.id) { $0.defaultValue = .number(value) } }
        ), in: (control.minimum ?? 0.25)...(control.maximum ?? 2), step: control.step ?? 0.05)
    }

    private func anchorValue(
        _ layer: AnimatedLayer,
        _ path: KeyPath<AnimatedAnchor, Double>,
        _ set: @escaping (inout AnimatedAnchor, Double) -> Void
    ) -> Binding<Double> {
        Binding(get: { layer.anchor[keyPath: path] }, set: { value in
            editor.setOptionAnchor(forLayer: layer.id) { set(&$0, value) }
        })
    }

    private func current(_ id: String) -> AnimatedControl? { editor.document.configuration?.controls.first { $0.id == id } }
    private func identifier() -> String { "control_" + UUID().uuidString.prefix(8).lowercased() }
    private func updateControl(_ id: String, _ body: @escaping (inout AnimatedControl) -> Void) {
        editor.updateConfiguration { configuration in
            guard let index = configuration?.controls.firstIndex(where: { $0.id == id }) else { return }
            body(&configuration!.controls[index])
        }
    }
    private func selectedOption(_ control: AnimatedControl) -> String {
        editor.previewControlValues[control.id]?.string ?? control.defaultValue.string ?? ""
    }
    private func activeVariant(for control: AnimatedControl) -> AnimatedVariant? {
        let option = selectedOption(control)
        if let activeVariantID = editor.activeVariantID,
           let active = configuration?.variants.first(where: { $0.id == activeVariantID }),
           active.selections[control.id] == option {
            return active
        }
        return configuration?.variants.first { variant in
            variant.selections[control.id] == option
                && variant.selections.allSatisfy { editor.previewControlValues[$0.key]?.string == $0.value }
        }
    }
    private func select(_ option: String, control: AnimatedControl) {
        var values = editor.previewControlValues
        values[control.id] = .string(option)
        let candidate = configuration?.variants.first { variant in
            variant.selections.allSatisfy { values[$0.key]?.string == $0.value }
                && variant.selections[control.id] == option
        } ?? configuration?.variants.first { $0.selections[control.id] == option }
        editor.previewControlValues = values
        editingControlID = control.id
        editor.selectVariant(candidate?.id)
    }

    private func targetIsAvailable(_ target: CustomChoiceTarget, for layerID: String) -> Bool {
        let alreadyBound = configuration?.variants.contains { variant in
            variant.layers.contains { patch in
                guard patch.layerId == layerID else { return false }
                return switch target {
                case .artwork: patch.source != nil
                case .movement: patch.animations != nil
                case .placement: patch.anchor != nil
                case .visibility: patch.hidden != nil
                case .pose: patch.clip != nil
                case .mood: patch.expression != nil
                }
            }
        } ?? false
        if alreadyBound { return false }
        if target == .visibility {
            return !controls.contains { $0.type == .toggle && ($0.layerIds ?? []).contains(layerID) }
        }
        return true
    }

    private func canAddChoice(optionCount: Int, layerID: String, target: CustomChoiceTarget) -> Bool {
        guard canAddAnotherControl, optionCount >= 2, targetIsAvailable(target, for: layerID) else { return false }
        guard let limits else { return true }
        guard optionCount <= limits.controlOptions,
              (configuration?.variants.count ?? 0) + optionCount <= limits.variants else { return false }
        let counts = configuration?.layerCombinationCounts ?? [:]
        let current = counts[layerID]
        let projectedLayerCount = (current ?? 1) * optionCount
        let projectedPrepared = (configuration?.preparedStateCount ?? 0) - (current ?? 0) + projectedLayerCount
        return projectedLayerCount <= limits.layerCombinations && projectedPrepared <= limits.preparedStates
    }

    private func canAddToggle(for layerID: String) -> Bool {
        canAddAnotherControl && targetIsAvailable(.visibility, for: layerID)
    }

    private var canAddSpeed: Bool {
        canAddAnotherControl && !controls.contains { $0.type == .number }
    }

    private func addCustomChoice(
        label: String,
        firstLabel: String,
        secondLabel: String,
        target: CustomChoiceTarget
    ) {
        guard let layer = selectedLayer else { return }
        let id = identifier()
        let firstID = "option_1"
        let secondID = "option_2"

        func patch(alternate: Bool) -> AnimatedVariantLayer {
            switch target {
            case .artwork:
                return .init(layerId: layer.id, source: .init(kind: .base))
            case .movement:
                return .init(layerId: layer.id, animations: alternate
                    ? [AnimationSpec(.bounce(height: 0.08, bounces: 2))] : [])
            case .placement:
                return .init(layerId: layer.id, anchor: layer.anchor)
            case .visibility:
                return .init(layerId: layer.id, hidden: alternate ? !layer.base.hidden : layer.base.hidden)
            case .pose:
                guard case .sprite(let sprite) = layer else { return .init(layerId: layer.id, anchor: layer.anchor) }
                let alternateClip = sprite.clips.dropFirst().first?.id ?? sprite.clipId
                return .init(layerId: layer.id, clip: alternate ? alternateClip : sprite.clipId)
            case .mood:
                guard case .sprite(let sprite) = layer else { return .init(layerId: layer.id, anchor: layer.anchor) }
                let alternateExpression = sprite.expressions.tiles.dropFirst().first?.id ?? sprite.expressionId
                return .init(layerId: layer.id, expression: alternate ? alternateExpression : sprite.expressionId)
            }
        }

        editor.updateConfiguration("Add Custom Control") { configuration in
            if configuration == nil { configuration = .init(controls: []) }
            configuration?.controls.append(.init(
                id: id,
                label: label,
                type: .choice,
                defaultValue: .string(firstID),
                options: [.init(id: firstID, label: firstLabel), .init(id: secondID, label: secondLabel)]
            ))
            configuration?.variants.append(contentsOf: [
                .init(id: identifier(), selections: [id: firstID], layers: [patch(alternate: false)]),
                .init(id: identifier(), selections: [id: secondID], layers: [patch(alternate: true)])
            ])
        }
        editingControlID = id
    }

    private func addChoice(label: String, artwork: Bool) {
        guard let layer = selectedLayer else { return }
        let id = identifier(), original = "original", changed = "changed"
        editor.updateConfiguration("Add \(label) Control") { configuration in
            if configuration == nil { configuration = .init(controls: []) }
            configuration?.controls.append(.init(id: id, label: label, type: .choice, defaultValue: .string(original), options: [
                .init(id: original, label: "Original"), .init(id: changed, label: artwork ? "Alternate" : "Bounce")
            ]))
            configuration?.variants.append(contentsOf: [
                .init(id: identifier(), selections: [id: original], layers: [artwork
                    ? .init(layerId: layer.id, source: .init(kind: .base))
                    : .init(layerId: layer.id, animations: [])]),
                .init(id: identifier(), selections: [id: changed], layers: [artwork
                    ? .init(layerId: layer.id, source: .init(kind: .base))
                    : .init(layerId: layer.id, animations: [AnimationSpec(.bounce(height: 0.08, bounces: 2))])])
            ])
        }
        editingControlID = id
    }

    private func addSpriteChoice(label: String, values: [(String, String)], pose: Bool) {
        guard let layer = selectedLayer, let first = values.first else { return }
        let id = identifier()
        editor.updateConfiguration("Add \(label) Control") { configuration in
            if configuration == nil { configuration = .init(controls: []) }
            configuration?.controls.append(.init(id: id, label: label, type: .choice, defaultValue: .string(first.0),
                                                  options: values.map { .init(id: $0.0, label: $0.1) }))
            configuration?.variants.append(contentsOf: values.map { value in
                .init(id: identifier(), selections: [id: value.0], layers: [pose
                    ? .init(layerId: layer.id, clip: value.0)
                    : .init(layerId: layer.id, expression: value.0)])
            })
        }
        editingControlID = id
    }

    private func addVisibility(label: String? = nil, defaultVisible: Bool? = nil) {
        guard let layer = selectedLayer else { return }
        let id = identifier()
        editor.updateConfiguration("Add Visibility Control") { configuration in
            if configuration == nil { configuration = .init(controls: []) }
            configuration?.controls.append(.init(
                id: id,
                label: label ?? "Show \(layer.name)",
                type: .toggle,
                defaultValue: .bool(defaultVisible ?? !layer.base.hidden),
                layerIds: [layer.id]
            ))
        }
    }

    private func addSpeed(label: String = "Speed", defaultValue: Double = 1) {
        let id = identifier()
        editor.updateConfiguration("Add Speed Control") { configuration in
            if configuration == nil { configuration = .init(controls: []) }
            configuration?.controls.append(.init(
                id: id,
                label: label,
                type: .number,
                defaultValue: .number(defaultValue),
                binding: "speed",
                minimum: 0.25,
                maximum: 2,
                step: 0.05
            ))
        }
    }

    private func addOption(_ control: AnimatedControl) {
        guard canAddOption(to: control) else { return }
        guard let defaultID = control.defaultValue.string else { return }
        let optionID = identifier()
        editor.updateConfiguration("Add Option") { configuration in
            guard let index = configuration?.controls.firstIndex(where: { $0.id == control.id }) else { return }
            configuration?.controls[index].options?.append(.init(id: optionID, label: "New option"))
            let templates = configuration?.variants.filter { $0.selections[control.id] == defaultID } ?? []
            for var variant in templates {
                variant.id = identifier()
                variant.selections[control.id] = optionID
                configuration?.variants.append(variant)
            }
        }
    }

    private func canAddOption(to control: AnimatedControl) -> Bool {
        guard let limits else { return true }
        guard (control.options?.count ?? 0) < limits.controlOptions else { return false }
        let templates = configuration?.variants.filter { $0.selections[control.id] == control.defaultValue.string }.count ?? 0
        guard (configuration?.variants.count ?? 0) + templates <= limits.variants else { return false }
        var copy = configuration
        if let index = copy?.controls.firstIndex(where: { $0.id == control.id }) {
            copy?.controls[index].options?.append(.init(id: "limit_probe", label: "Probe"))
        }
        guard let copy else { return true }
        return copy.layerCombinationCounts.values.allSatisfy { $0 <= limits.layerCombinations }
            && copy.preparedStateCount <= limits.preparedStates
    }

    private func removeOption(_ id: String, control: AnimatedControl) {
        editor.updateConfiguration("Remove Option") { configuration in
            guard let index = configuration?.controls.firstIndex(where: { $0.id == control.id }) else { return }
            configuration?.controls[index].options?.removeAll { $0.id == id }
            if configuration?.controls[index].defaultValue.string == id,
               let first = configuration?.controls[index].options?.first {
                configuration?.controls[index].defaultValue = .string(first.id)
            }
            configuration?.variants.removeAll { $0.selections[control.id] == id }
        }
        editor.selectVariant(nil)
        editingControlID = nil
    }

    private func removeControl(_ control: AnimatedControl) {
        editor.updateConfiguration("Remove Control") { configuration in
            configuration?.controls.removeAll { $0.id == control.id }
            let variants = configuration?.variants ?? []
            configuration?.variants = variants.compactMap { variant in
                guard let selection = variant.selections[control.id] else { return variant }
                guard selection == control.defaultValue.string else { return nil }
                var next = variant
                next.selections.removeValue(forKey: control.id)
                return next.selections.isEmpty ? nil : next
            }
            if configuration?.controls.isEmpty == true { configuration = nil }
        }
        editor.selectVariant(nil)
        editingControlID = nil
    }

    private func moveSelectedLayer(_ delta: Int) {
        guard let id = selectedLayer?.id,
              let index = editor.displayDocument.layers.firstIndex(where: { $0.id == id }) else { return }
        editor.moveLayer(id: id, toIndex: index + delta)
    }

    private func isolated(_ layer: AnimatedLayer) -> AnimatedDocument {
        var document = editor.displayDocument
        document.configuration = nil
        document.layers = [layer]
        return document
    }
}
#endif
