import AnimatedView
import SwiftUI

/// Edits authored definitions. Playback selections are a separate, cancelable sheet.
///
/// Dressed in the poster system rather than in stock form controls: this section sits directly
/// under the plan editor's own sections, so a tinted system `Picker` label and a grey
/// `DisclosureGroup` chevron were the only things on that screen still reading as iOS.
struct StickerConfigurationEditor: View {
    /// The poses and moods a sprite character already has. A mood or pose control on such a layer
    /// selects between them at no cost; only a *new* pose or mood needs artwork, and therefore a plan.
    nonisolated struct Sprite: Hashable, Sendable {
        nonisolated struct Option: Identifiable, Hashable, Sendable { var id: String; var label: String }
        var clips: [Option]
        var expressions: [Option]
    }
    struct Layer: Identifiable { var id: String; var name: String; var sprite: Sprite? }
    @Binding var configuration: AnimatedControlConfiguration?
    let layers: [Layer]
    var planned = false
    /// What the server says a configuration may spend. Nil until the app has heard, and nil greys
    /// out nothing: an editor that does not know the budget lets the server refuse the plan.
    var limits: ConfigurationLimits?
    var onRequestArtwork: ((String) -> Void)?
    @State private var selectedLayer = ""

    private var layerID: String { layers.contains { $0.id == selectedLayer } ? selectedLayer : layers.first?.id ?? "" }
    private var controls: [AnimatedControl] { configuration?.controls ?? [] }
    private var layerName: String { layers.first { $0.id == layerID }?.name ?? String(localized: "No layers") }
    private var canHideLayer: Bool { controls.contains { $0.type == .toggle && $0.layerIds?.contains(layerID) == true } }
    private var sprite: Sprite? { layers.first { $0.id == layerID }?.sprite }
    /// Whether some control already selects this sprite layer's clip or expression.
    private func spriteBound(_ keyPath: KeyPath<AnimatedVariantLayer, String?>) -> Bool {
        configuration?.variants.contains { variant in
            variant.layers.contains { $0.layerId == layerID && $0[keyPath: keyPath] != nil }
        } == true
    }

    /// The parts of a document's sprite layer, for a caller that edits a built sticker.
    static func sprite(of layer: AnimatedLayer) -> Sprite? {
        guard case .sprite(let sprite) = layer else { return nil }
        return Sprite(
            clips: sprite.clips.map { .init(id: $0.id, label: $0.id.capitalized) },
            expressions: sprite.expressions.tiles.map { .init(id: $0.id, label: $0.id.capitalized) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PosterSectionHeader(
                title: String(localized: "Configurable layers"),
                subtitle: String(localized: "Choose what can change in the preview and before sending."),
                highlight: AppColors.mint
            )
            PosterMenuRow(caption: String(localized: "Layer"), value: layerName) {
                Picker("Layer", selection: Binding(get: { layerID }, set: { selectedLayer = $0 })) {
                    ForEach(layers) { Text($0.name).tag($0.id) }
                }
            }
            .disabled(layers.count <= 1)
            .accessibilityIdentifier("configuration-layer-picker")

            PosterToggleRow(title: String(localized: "Allow showing or hiding this layer"), isOn: Binding(
                get: { canHideLayer },
                set: { visibility($0) }
            ))
            .disabled(atControlCeiling && !canHideLayer)

            ForEach(controls) { control in
                PosterCard(padding: 14) {
                    PosterDisclosure(title: control.label.isEmpty ? String(localized: "Control") : control.label) {
                        controlFields(control)
                    }
                }
            }

            Menu {
                if !controls.contains(where: { $0.type == .number }) {
                    Button("Speed") {
                        append(.init(
                            id: identifier(), label: "Speed", type: .number, defaultValue: .number(1),
                            binding: "speed", minimum: 0.25, maximum: 2, step: 0.05
                        ))
                    }
                }
                Button("Mood") { addChoice("Mood", artwork: true) }
                    .disabled(atCombinationCeiling || (sprite != nil && spriteBound(\.expression)))
                Button("Pose") { addChoice("Pose", artwork: true) }
                    .disabled(atCombinationCeiling || (sprite != nil && spriteBound(\.clip)))
                if sprite == nil {
                    Button("Movement") { addChoice("Movement", artwork: false) }.disabled(atCombinationCeiling)
                }
            } label: {
                PosterMenuLabel("Add control", icon: .add).frame(maxWidth: .infinity)
            }
            .buttonStyle(.posterSecondary)
            .disabled(atControlCeiling || layers.isEmpty)

            if let configuration {
                // With a cast, the product is what the sticker can show but the per-character count
                // is what is actually capped, so the one being spent is the one named.
                Text(configuration.layerCombinationCounts.count > 1
                    ? "\(configuration.combinationCount) combinations, \(selectedLayerCombinations) for \(layerName)"
                    : "\(configuration.combinationCount) combinations")
                    .posterLabelStyle(10, color: AppColors.muted)
                if let validationMessage { NoticeBanner(message: validationMessage) }
            }
        }
        .onChange(of: layers.map(\.id)) { _, ids in configuration = configuration?.keepingLayers(Set(ids)) }
        .accessibilityIdentifier("sticker-configuration-editor")
    }

    private var validationMessage: String? {
        do {
            try configuration?.validated(layerIds: Set(layers.map(\.id)), planned: planned)
        } catch {
            return error.localizedDescription
        }
        // `validated` answers whether the configuration makes sense. Whether it is affordable is
        // a separate question, and only the server knows the answer.
        guard let configuration, let limits else { return nil }
        return limits.issue(for: configuration)
    }

    private func controlFields(_ control: AnimatedControl) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            PosterField(placeholder: String(localized: "Control name"), text: Binding(
                get: { current(control).label },
                set: { label in update(control.id) { $0.label = label } }
            ))
            if control.type == .choice {
                PosterMenuRow(
                    caption: String(localized: "Default"),
                    value: control.options?.first { $0.id == current(control).defaultValue.string }?.label ?? ""
                ) {
                    Picker("Default", selection: Binding(
                        get: { current(control).defaultValue.string ?? "" },
                        set: { value in update(control.id) { $0.defaultValue = .string(value) } }
                    )) {
                        ForEach(control.options ?? []) { Text($0.label).tag($0.id) }
                    }
                }
                ForEach(control.options ?? []) { option in
                    HStack(spacing: 8) {
                        PosterField(placeholder: String(localized: "Option name"), text: Binding(
                            get: { current(control).options?.first { $0.id == option.id }?.label ?? "" },
                            set: { label in
                                update(control.id) {
                                    if let i = $0.options?.firstIndex(where: { $0.id == option.id }) { $0.options?[i].label = label }
                                }
                            }
                        ))
                        let canRemove = (control.options?.count ?? 0) > (limits?.controlOptionsMinimum ?? 1)
                        Button(role: .destructive) { removeOption(option.id, control: control) } label: {
                            PosterSymbol("minus.circle")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundStyle(canRemove ? AppColors.coral : AppColors.faint)
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.posterPlain)
                        .disabled(!canRemove)
                        .accessibilityLabel("Remove \(option.label)")
                    }
                }
                Button { addOption(control) } label: { PosterMenuLabel("Add option", icon: .add) }
                    .buttonStyle(.posterSecondaryCompact)
                    .disabled(wouldExceedCombinations(control))
                ForEach(configuration?.variants.filter { $0.selections[control.id] != nil } ?? []) { variant in
                    variantFields(variant)
                }
            } else if control.type == .toggle {
                PosterToggleRow(title: String(localized: "Visible by default"), isOn: Binding(
                    get: { current(control).defaultValue.bool ?? true },
                    set: { value in update(control.id) { $0.defaultValue = .bool(value) } }
                ))
                ForEach(layers) { layer in
                    PosterToggleRow(title: layer.name, isOn: Binding(
                        get: { current(control).layerIds?.contains(layer.id) == true },
                        set: { value in update(control.id) {
                            var ids = $0.layerIds ?? []
                            ids.removeAll { $0 == layer.id }
                            if value { ids.append(layer.id) }
                            $0.layerIds = ids
                        } }
                    ))
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Default speed").posterLabelStyle(9, color: AppColors.muted)
                        Spacer()
                        Text((control.defaultValue.number ?? 1).formatted(.number.precision(.fractionLength(2))))
                            .font(.posterDisplay(15, weight: .bold))
                            .foregroundStyle(AppColors.ink)
                    }
                    Slider(
                        value: Binding(
                            get: { current(control).defaultValue.number ?? 1 },
                            set: { value in update(control.id) { $0.defaultValue = .number(value) } }
                        ),
                        in: (control.minimum ?? 0.25)...(control.maximum ?? 2),
                        step: control.step ?? 0.05
                    )
                    .tint(AppColors.ink)
                }
            }
            Button("Remove control", role: .destructive) { removeControl(control) }
                .buttonStyle(.posterDanger)
        }
    }

    private func variantFields(_ variant: AnimatedVariant) -> some View {
        PosterDisclosure(title: variantLabel(variant)) {
            ForEach(variant.layers.indices, id: \.self) { index in
                let patch = variant.layers[index]
                VStack(alignment: .leading, spacing: 8) {
                    Text(layers.first { $0.id == patch.layerId }?.name ?? patch.layerId)
                        .posterLabelStyle(9, color: AppColors.muted)
                    if let source = patch.source {
                        PosterMenuRow(caption: String(localized: "Artwork"), value: sourceLabel(source), icon: PosterIcon.staticSticker) {
                            Button("Original artwork") { sourceUpdate(variant.id, index: index, .init(kind: .base)) }
                            ForEach(artworkChoices(layerID: patch.layerId)) { choice in
                                Button(choice.label) { sourceUpdate(variant.id, index: index, choice.source) }
                            }
                            if planned {
                                Button("Generate expression") {
                                    sourceUpdate(variant.id, index: index, .init(
                                        kind: .generate, prompt: "Preserve the approved character; draw this expression."
                                    ))
                                }
                                Button("Generate animated pose") {
                                    sourceUpdate(variant.id, index: index, .init(
                                        kind: .frames,
                                        prompt: "Preserve the approved character; animate this pose in aligned frames.",
                                        columns: 4, rows: 2, frameCount: 8, frameRate: 8, playback: .loop
                                    ))
                                }
                            } else {
                                Button("Plan new artwork…") {
                                    onRequestArtwork?(
                                        "Create a revised plan for new expression or pose artwork on layer \(patch.layerId), "
                                            + "preserving existing control and option ids."
                                    )
                                }
                            }
                        }
                        if planned, source.kind == .generate || source.kind == .frames {
                            PosterField(placeholder: String(localized: "Describe this expression or pose"), text: Binding(get: {
                                configuration?.variants.first { $0.id == variant.id }?.layers[index].source?.prompt ?? ""
                            }, set: { prompt in patchUpdate(variant.id, index: index) { $0.source?.prompt = prompt } }), lineLimit: 2...4)
                        }
                    }
                    if patch.text != nil {
                        PosterField(placeholder: String(localized: "Caption"), text: Binding(
                            get: { configuration?.variants.first { $0.id == variant.id }?.layers[index].text ?? "" },
                            set: { text in patchUpdate(variant.id, index: index) { $0.text = text } }
                        ))
                    }
                    if let hidden = patch.hidden {
                        PosterToggleRow(title: String(localized: "Visible"), isOn: Binding(
                            get: { !(configuration?.variants.first { $0.id == variant.id }?.layers[index].hidden ?? hidden) },
                            set: { visible in patchUpdate(variant.id, index: index) { $0.hidden = !visible } }
                        ))
                    }
                    let spriteInfo = layers.first { $0.id == patch.layerId }?.sprite
                    if let clip = patch.clip, let options = spriteInfo?.clips {
                        let label = options.first { $0.id == clip }?.label ?? clip
                        PosterMenuRow(caption: String(localized: "Pose"), value: label, icon: PosterIcon.animatedSticker) {
                            ForEach(options) { option in
                                Button(option.label) { patchUpdate(variant.id, index: index) { $0.clip = option.id } }
                            }
                        }
                    }
                    if let expression = patch.expression, let options = spriteInfo?.expressions {
                        let label = options.first { $0.id == expression }?.label ?? expression
                        PosterMenuRow(caption: String(localized: "Mood"), value: label, icon: PosterIcon.staticSticker) {
                            ForEach(options) { option in
                                Button(option.label) { patchUpdate(variant.id, index: index) { $0.expression = option.id } }
                            }
                        }
                    }
                    if let animations = patch.animations {
                        PosterMenuRow(
                            caption: String(localized: "Movement"),
                            value: animations.isEmpty ? String(localized: "Still") : String(localized: "Animated"),
                            icon: PosterIcon.animatedSticker
                        ) {
                            Button("Still") { patchUpdate(variant.id, index: index) { $0.animations = [] } }
                            Button("Bounce") { setMotion(variant.id, index: index, .bounce(height: 0.08, bounces: 2)) }
                            Button("Sway") { setMotion(variant.id, index: index, .wiggle(amplitudeDegrees: 8, cycles: 2)) }
                            Button("Float") { setMotion(variant.id, index: index, .float(amplitude: 0.04, cycles: 1)) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(12)
        .posterSurface(cornerRadius: Poster.chipRadius, fill: AppColors.paper, lineWidth: Poster.hairline, offset: .zero)
    }

    private struct ArtworkChoice: Identifiable { var id: String; var label: String; var source: AnimatedVariantSource }
    private func artworkChoices(layerID: String) -> [ArtworkChoice] {
        (configuration?.variants ?? []).compactMap { variant in
            guard let source = variant.layers.first(where: { $0.layerId == layerID })?.source, source.kind != .base else { return nil }
            return .init(id: variant.id, label: variantLabel(variant), source: source)
        }
    }
    private func variantLabel(_ variant: AnimatedVariant) -> String {
        variant.selections.sorted { $0.key < $1.key }.map { key, value in
            controls.first { $0.id == key }?.options?.first { $0.id == value }?.label ?? value
        }.joined(separator: " · ")
    }
    private func sourceLabel(_ source: AnimatedVariantSource) -> String {
        switch source.kind {
        case .base: "Original artwork"
        case .generate: "Generate expression"
        case .frames: "Generate animated pose"
        case .sequence: "Approved animation"
        default: "Approved artwork"
        }
    }
    private func identifier() -> String { "control_" + UUID().uuidString.prefix(8).lowercased() }
    private func motion(_ effect: AnimationEffect) -> AnimationSpec { .init(effect, delay: 0, duration: 0.5) }
    private func current(_ control: AnimatedControl) -> AnimatedControl { controls.first { $0.id == control.id } ?? control }
    /// How many states the layer being edited can already be prepared in. The ceiling is per
    /// character, so adding a control to the dog must not read as spending the cat's budget.
    private var selectedLayerCombinations: Int { configuration?.layerCombinationCounts[layerID] ?? 1 }
    /// Whether the configuration is already at the control ceiling the server set.
    private var atControlCeiling: Bool { limits.map { controls.count >= $0.controls } ?? false }
    /// Whether one more control on the selected character would put it past its ceiling.
    private var atCombinationCeiling: Bool {
        limits?.exceedsLayerCombinations(addingControlTo: selectedLayerCombinations) ?? false
    }
    /// Whether one more option on this control would put its character past its ceiling, or the
    /// control past the options it is allowed to offer.
    private func wouldExceedCombinations(_ control: AnimatedControl) -> Bool {
        guard let limits else { return false }
        let options = control.options?.count ?? 0
        guard let configuration, let layerID = configuration.layerIDs(for: control).first else {
            return options >= limits.controlOptions
        }
        let counts = configuration.layerCombinationCounts
        return limits.exceedsLayerCombinations(addingOptionTo: counts[layerID] ?? 1, options: options)
    }
    private func update(_ id: String, _ body: (inout AnimatedControl) -> Void) {
        guard let i = configuration?.controls.firstIndex(where: { $0.id == id }) else { return }
        body(&configuration!.controls[i])
    }
    private func patchUpdate(_ id: String, index: Int, _ body: (inout AnimatedVariantLayer) -> Void) {
        guard let i = configuration?.variants.firstIndex(where: { $0.id == id }),
              configuration!.variants[i].layers.indices.contains(index) else { return }
        body(&configuration!.variants[i].layers[index])
    }
    private func setMotion(_ id: String, index: Int, _ effect: AnimationEffect) {
        patchUpdate(id, index: index) { $0.animations = [motion(effect)] }
    }
    private func sourceUpdate(_ id: String, index: Int, _ source: AnimatedVariantSource) { patchUpdate(id, index: index) { $0.source = source } }
    private func append(_ control: AnimatedControl) {
        if configuration == nil { configuration = .init(controls: []) }
        configuration?.controls.append(control)
    }
    private func visibility(_ enabled: Bool) {
        let id = layerID
        if enabled {
            let name = layers.first { $0.id == id }?.name ?? String(localized: "layer")
            append(.init(id: identifier(), label: "Show \(name)", type: .toggle, defaultValue: .bool(true), layerIds: [id]))
        } else {
            for control in controls where control.type == .toggle { update(control.id) { $0.layerIds?.removeAll { $0 == id } } }
            configuration?.controls.removeAll { $0.type == .toggle && $0.layerIds?.isEmpty == true }
            if configuration?.controls.isEmpty == true { configuration = nil }
        }
    }
    private func addChoice(_ label: String, artwork: Bool) {
        // A sprite already holds every pose and mood it was built with, so a control that selects
        // between them is authored here for free, whether or not the plan is still being drafted.
        if artwork, let sprite {
            let isPose = label == "Pose"
            let options = isPose ? sprite.clips : sprite.expressions
            guard let first = options.first else { return }
            let id = identifier()
            append(.init(
                id: id, label: label, type: .choice, defaultValue: .string(first.id),
                options: options.map { .init(id: $0.id, label: $0.label) }
            ))
            configuration?.variants += options.map { option in
                .init(id: identifier(), selections: [id: option.id], layers: [
                    isPose ? .init(layerId: layerID, clip: option.id) : .init(layerId: layerID, expression: option.id)
                ])
            }
            return
        }
        if artwork && !planned {
            onRequestArtwork?(
                "Create a revised generation plan adding a configurable \(label.lowercased()) to layer \(layerID). "
                    + "Preserve existing appearance and stable control, option and layer ids. "
                    + "Propose options and count all required artwork combinations."
            )
            return
        }
        let id = identifier(), original = "original", changed = "changed"
        append(.init(id: id, label: label, type: .choice, defaultValue: .string(original), options: [
            .init(id: original, label: "Original"),
            .init(id: changed, label: artwork ? "New \(label.lowercased())" : "Bounce")
        ]))
        // Two controls changing one source need an explicit combined table. Keep the original
        // variant ids for the unchanged option and count each new combination as artwork.
        if let conflict = configuration?.variants.first(where: { variant in
            variant.layers.contains { $0.layerId == layerID && (artwork ? $0.source != nil : $0.animations != nil) }
        }) {
            let axes = Set(conflict.selections.keys)
            let templates = configuration?.variants.filter { Set($0.selections.keys) == axes } ?? []
            configuration?.variants.removeAll { Set($0.selections.keys) == axes }
            for template in templates {
                var kept = template; kept.selections[id] = original
                configuration?.variants.append(kept)
                var combined = template; combined.id = identifier(); combined.selections[id] = changed
                let names = template.selections.sorted { $0.key < $1.key }.map { key, value in
                    let control = controls.first { $0.id == key }
                    return "\(control?.label ?? key): \(control?.options?.first { $0.id == value }?.label ?? value)"
                }.joined(separator: ", ")
                for index in combined.layers.indices where combined.layers[index].layerId == layerID {
                    if artwork, combined.layers[index].source != nil {
                        combined.layers[index].source = .init(
                            kind: .generate,
                            prompt: "Preserve the approved character and \(names). "
                                + "Combine these with the new \(label.lowercased())."
                        )
                    } else if !artwork, combined.layers[index].animations != nil {
                        combined.layers[index].animations = [motion(.bounce(height: 0.08, bounces: 2))]
                    }
                }
                configuration?.variants.append(combined)
            }
            return
        }
        let drawn = AnimatedVariantSource(kind: .generate, prompt: "Preserve the approved character; draw a new \(label.lowercased()).")
        configuration?.variants += [
            .init(id: identifier(), selections: [id: original], layers: [
                .init(layerId: layerID, source: artwork ? .init(kind: .base) : nil, animations: artwork ? nil : [])
            ]),
            .init(id: identifier(), selections: [id: changed], layers: [
                .init(
                    layerId: layerID,
                    source: artwork ? drawn : nil,
                    animations: artwork ? nil : [motion(.bounce(height: 0.08, bounces: 2))]
                )
            ])
        ]
    }
    private func addOption(_ control: AnimatedControl) {
        guard let defaultID = control.defaultValue.string else { return }
        let templates = configuration?.variants.filter { $0.selections[control.id] == defaultID } ?? []
        // In a draft, add an editable option using the default pose or mood as its starting
        // selection. The plan editor has no artwork-request callback, so routing draft options
        // through that callback silently discards the tap. Built stickers still request a plan
        // for new sprite artwork.
        if !planned, let bound = templates.flatMap(\.layers).first(where: { $0.clip != nil || $0.expression != nil }) {
            let what = bound.clip != nil ? "pose" : "expression"
            onRequestArtwork?(
                "Create a revised plan adding a new \(what) to the sprite character on layer \(bound.layerId), "
                    + "and an option for it on control \(control.id) (\(control.label)). "
                    + "Keep every existing layer, control, option, clip, and expression id."
            )
            return
        }
        if !planned && templates.contains(where: { $0.layers.contains { $0.source != nil } }) {
            onRequestArtwork?(
                "Create a revised plan adding an option to control \(control.id) (\(control.label)). "
                    + "Preserve all existing control, option, and layer ids and generate complete combined artwork coverage."
            )
            return
        }
        let optionID = identifier()
        update(control.id) { $0.options?.append(.init(id: optionID, label: "New option")) }
        for var variant in templates {
            variant.id = identifier(); variant.selections[control.id] = optionID
            for i in variant.layers.indices where planned && variant.layers[i].source != nil {
                variant.layers[i].source = .init(
                    kind: .generate,
                    prompt: "Preserve the approved character; draw the new \(control.label.lowercased()) option."
                )
            }
            configuration?.variants.append(variant)
        }
    }
    private func removeOption(_ id: String, control: AnimatedControl) {
        update(control.id) {
            $0.options?.removeAll { $0.id == id }
            if $0.defaultValue.string == id, let first = $0.options?.first { $0.defaultValue = .string(first.id) }
        }
        configuration?.variants.removeAll { $0.selections[control.id] == id }
    }
    private func removeControl(_ control: AnimatedControl) {
        configuration?.controls.removeAll { $0.id == control.id }
        configuration?.variants = configuration?.variants.compactMap { variant in
            guard variant.selections[control.id] != nil else { return variant }
            guard variant.selections[control.id] == control.defaultValue.string else { return nil }
            var next = variant; next.selections.removeValue(forKey: control.id)
            return next.selections.isEmpty ? nil : next
        } ?? []
        if configuration?.controls.isEmpty == true { configuration = nil }
    }
}

// MARK: - Poster controls

/// A row that opens. `DisclosureGroup` draws its title in the accent tint and its chevron in the
/// system's grey; this keeps the ink title, the poster's own chevron, and the card it sits on.
private struct PosterDisclosure<Content: View>: View {
    let title: String
    @State private var isExpanded = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                Haptics.tap(.light)
                withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(AppColors.ink)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    PosterSymbol("chevron.right")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(AppColors.muted)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.posterPlain)
            .accessibilityAddTraits(isExpanded ? .isSelected : [])

            if isExpanded { content }
        }
    }
}

#Preview("Configurable layers") {
    @Previewable @State var configuration = PreviewFixtures.configurableDocument.configuration

    StickerBackground {
        ScrollView {
            StickerConfigurationEditor(
                configuration: $configuration,
                layers: PreviewFixtures.configurableDocument.layers.map { .init(id: $0.id, name: $0.name) },
                planned: true
            )
            .padding(20)
        }
    }
}
