#if os(iOS)
import SwiftUI

// The per-kind halves of the inspector. Each writes through `editor.updateLayer`, which does not
// recompile — none of these fields is compiler input, unlike the anchor.

/// Image: the asset, how it fits, and an optional mask.
struct AnimatedImageLayerInspector: View {
    @Bindable var editor: AnimatedDocumentEditor
    let layer: AnimatedImageLayer
    let assets: any AnimatedAssetProvider
    var onRequestImageAsset: ((String) -> Void)?
    var onRequestMaskAsset: ((String) -> Void)?

    var body: some View {
        Section("Image") {
            HStack {
                Spacer()
                thumbnail
                Spacer()
            }

            if let onRequestImageAsset {
                Button("Replace Image", systemImage: "photo") { onRequestImageAsset(layer.base.id) }
            }

            Picker("Fit", selection: binding(\.contentMode)) {
                ForEach(AnimatedContentMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
        }

        Section {
            if layer.maskAssetId != nil {
                Button("Remove Mask", systemImage: "minus.circle", role: .destructive) {
                    editor.updateLayer(id: layer.base.id, name: "Remove Mask") {
                        guard case .image(var value) = $0 else { return }
                        value.maskAssetId = nil
                        $0 = .image(value)
                    }
                }
            } else if let onRequestMaskAsset {
                Button("Add Mask", systemImage: "theatermasks") { onRequestMaskAsset(layer.base.id) }
            }
        } header: {
            Text("Mask")
        } footer: {
            Text("A mask hides everything outside its opaque areas. It must match this image's size.")
        }
    }

    /// Falls back to the same placeholder the renderer draws, so an asset that has not loaded looks
    /// the same in the inspector as it does on the canvas.
    @ViewBuilder
    private var thumbnail: some View {
        if let image = assets.image(for: layer.assetId) {
            Image(platformImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.purple.gradient)
                .frame(width: 88, height: 88)
                .overlay {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AnimatedImageLayer, Value>) -> Binding<Value> {
        Binding(
            get: { layer[keyPath: keyPath] },
            set: { newValue in
                editor.updateLayer(id: layer.base.id, name: "Edit Image") {
                    guard case .image(var value) = $0 else { return }
                    value[keyPath: keyPath] = newValue
                    $0 = .image(value)
                }
            }
        )
    }
}

/// Text: the string, its typeface, and its paint.
struct AnimatedTextLayerInspector: View {
    @Bindable var editor: AnimatedDocumentEditor
    let layer: AnimatedTextLayer

    var body: some View {
        Section {
            TextField("Text", text: binding(\.text), axis: .vertical)
                .lineLimit(1...4)
        } header: {
            Text("Text")
        } footer: {
            // The cap is `AnimatedTextLayer.isValid`'s, shown before it can be exceeded rather than
            // reported afterwards.
            Text("\(layer.text.count)/160 characters. Text always scales uniformly, so it is never stretched.")
                .foregroundStyle(layer.text.count > 160 ? .red : .secondary)
        }

        Section("Typeface") {
            Picker("Font", selection: binding(\.font)) {
                ForEach(AnimatedFontFamily.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            Picker("Weight", selection: binding(\.weight)) {
                ForEach(AnimatedFontWeight.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            Picker("Alignment", selection: binding(\.alignment)) {
                ForEach(AnimatedTextAlignment.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
        }

        AnimatedPaintEditor(title: "Colour", paint: binding(\.paint), onEditingChanged: gesture)
    }

    private var gesture: (Bool) -> Void {
        { editing in
            if editing { editor.beginGesture("text-paint-\(layer.base.id)") } else { editor.endGesture() }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AnimatedTextLayer, Value>) -> Binding<Value> {
        Binding(
            get: { layer[keyPath: keyPath] },
            set: { newValue in
                editor.updateLayer(id: layer.base.id, name: "Edit Text", coalescingKey: "text-\(layer.base.id)") {
                    guard case .text(var value) = $0 else { return }
                    value[keyPath: keyPath] = newValue
                    $0 = .text(value)
                }
            }
        )
    }
}

/// Shape: which primitive, and how it is painted.
struct AnimatedShapeLayerInspector: View {
    @Bindable var editor: AnimatedDocumentEditor
    let layer: AnimatedShapeLayer

    var body: some View {
        Section("Shape") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(AnimatedShapeKind.presets.enumerated()), id: \.offset) { _, kind in
                        shapeButton(kind)
                    }
                }
                .padding(.vertical, 4)
            }

            // Parameterised primitives get their parameters only when selected, so the panel does
            // not carry controls that apply to nothing.
            switch layer.shape {
            case .star(let points, let innerRatio):
                Stepper("Points: \(points)", value: Binding(
                    get: { points },
                    set: { write(\.shape, .star(points: $0, innerRatio: innerRatio)) }
                ), in: 3...24)
                AnimatedValueSlider(
                    title: "Inner Radius",
                    value: Binding(
                        get: { innerRatio },
                        set: { write(\.shape, .star(points: points, innerRatio: $0)) }
                    ),
                    range: 0.05...1,
                    step: nil,
                    onEditingChanged: gesture
                )
            case .polygon(let sides):
                Stepper("Sides: \(sides)", value: Binding(
                    get: { sides },
                    set: { write(\.shape, .polygon(sides: $0)) }
                ), in: 3...24)
            case .roundedRectangle:
                AnimatedValueSlider(
                    title: "Corner Radius",
                    value: Binding(get: { layer.cornerRadius }, set: { write(\.cornerRadius, $0) }),
                    range: 0...0.5,
                    step: nil,
                    onEditingChanged: gesture
                )
            default:
                EmptyView()
            }
        }

        // `AnimatedShapeLayer.isValid` rejects a shape with neither fill nor stroke — it would draw
        // nothing — so whichever is the last one standing cannot be switched off.
        AnimatedOptionalPaintEditor(
            title: "Fill",
            paint: Binding(get: { layer.fill }, set: { write(\.fill, $0) }),
            canDisable: layer.stroke != nil,
            defaultPaint: .solid("#7C5CFF"),
            onEditingChanged: gesture
        )

        AnimatedStrokeEditor(
            title: "Stroke",
            stroke: Binding(get: { layer.stroke }, set: { write(\.stroke, $0) }),
            canDisable: layer.fill != nil,
            onEditingChanged: gesture
        )
    }

    private func shapeButton(_ kind: AnimatedShapeKind) -> some View {
        let isSelected = sameFamily(kind, layer.shape)
        return Button {
            write(\.shape, kind)
        } label: {
            AnimatedShape(kind: kind, cornerRadius: 0.2, customPath: nil)
                .fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 34, height: 34)
                .padding(5)
                .background(isSelected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    /// Compares the *case* rather than the whole value, so changing a star's point count does not
    /// deselect the star in the picker.
    private func sameFamily(_ a: AnimatedShapeKind, _ b: AnimatedShapeKind) -> Bool {
        switch (a, b) {
        case (.circle, .circle), (.roundedRectangle, .roundedRectangle), (.capsule, .capsule),
             (.triangle, .triangle), (.heart, .heart), (.burst, .burst),
             (.star, .star), (.polygon, .polygon), (.path, .path):
            true
        default:
            false
        }
    }

    private var gesture: (Bool) -> Void {
        { editing in
            if editing { editor.beginGesture("shape-\(layer.base.id)") } else { editor.endGesture() }
        }
    }

    private func write<Value>(_ keyPath: WritableKeyPath<AnimatedShapeLayer, Value>, _ newValue: Value) {
        editor.updateLayer(id: layer.base.id, name: "Edit Shape", coalescingKey: "shape-\(layer.base.id)") {
            guard case .shape(var value) = $0 else { return }
            value[keyPath: keyPath] = newValue
            $0 = .shape(value)
        }
    }
}

/// SVG: the markup, how it is drawn, and the overrides that make draw-on possible.
struct AnimatedSVGLayerInspector: View {
    @Bindable var editor: AnimatedDocumentEditor
    let layer: AnimatedSVGLayer

    @State private var markupDraft = ""
    @State private var markupError: String?
    @FocusState private var isEditingMarkup: Bool

    private var inlineMarkup: String? {
        if case .inline(let markup) = layer.source { return markup }
        return nil
    }

    var body: some View {
        Section {
            if inlineMarkup != nil {
                TextEditor(text: $markupDraft)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 120)
                    .focused($isEditingMarkup)
                    .onChange(of: isEditingMarkup) { _, focused in if !focused { commitMarkup() } }
                    .onAppear { markupDraft = inlineMarkup ?? "" }

                HStack {
                    Button("Paste", systemImage: "doc.on.clipboard") {
                        markupDraft = UIPasteboard.general.string ?? markupDraft
                        commitMarkup()
                    }
                    Spacer()
                    Button("Apply") { commitMarkup() }
                        .disabled(markupDraft == inlineMarkup)
                }
                .font(.caption)
            } else {
                LabeledContent("Source", value: "Linked asset")
            }
        } header: {
            Text("Artwork")
        } footer: {
            if let markupError {
                Text(markupError).foregroundStyle(.red)
            } else {
                // Committing on blur rather than per keystroke is deliberate: `SVGCache` is keyed by
                // the markup string, so live typing would parse a new document and evict the cache
                // on every character.
                Text("Applied when you finish editing. Scripts and remote references are not allowed.")
            }
        }

        Section {
            Picker("Render Mode", selection: Binding(
                get: { layer.renderMode },
                set: { write(\.renderMode, $0) }
            )) {
                ForEach(AnimatedSVGRenderMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)

            AnimatedValueSlider(
                title: "Stagger",
                value: Binding(get: { layer.staggerSeconds }, set: { write(\.staggerSeconds, $0) }),
                range: 0...4,
                step: nil,
                format: "%.2f s",
                onEditingChanged: gesture
            )
        } header: {
            Text("Drawing")
        } footer: {
            Text(layer.renderMode == .native
                ? "Native has the highest fidelity but ignores trim and tint."
                : "Vector enables draw-on, tinting, and stroke overrides. Stagger offsets each subpath in turn.")
        }

        AnimatedOptionalPaintEditor(
            title: "Tint",
            paint: Binding(get: { layer.tint }, set: { write(\.tint, $0) }),
            onEditingChanged: gesture
        )

        AnimatedStrokeEditor(
            title: "Stroke Override",
            stroke: Binding(get: { layer.strokeOverride }, set: { write(\.strokeOverride, $0) }),
            onEditingChanged: gesture
        )
    }

    private func commitMarkup() {
        let candidate = AnimatedSVGSource.inline(markup: markupDraft)
        guard candidate.isValid else {
            markupError = "That SVG is empty, too large, or references a script or a remote URL."
            return
        }
        markupError = nil
        write(\.source, candidate)
    }

    private var gesture: (Bool) -> Void {
        { editing in
            if editing { editor.beginGesture("svg-\(layer.base.id)") } else { editor.endGesture() }
        }
    }

    private func write<Value>(_ keyPath: WritableKeyPath<AnimatedSVGLayer, Value>, _ newValue: Value) {
        editor.updateLayer(id: layer.base.id, name: "Edit Artwork", coalescingKey: "svg-\(layer.base.id)") {
            guard case .svg(var value) = $0 else { return }
            value[keyPath: keyPath] = newValue
            $0 = .svg(value)
        }
    }
}

/// Particles: a preset, a count, a colour, and the seed that makes it reproducible.
struct AnimatedParticleLayerInspector: View {
    @Bindable var editor: AnimatedDocumentEditor
    let layer: AnimatedParticleLayer

    var body: some View {
        Section("Particles") {
            Picker("Preset", selection: Binding(
                get: { layer.preset },
                set: { write(\.preset, $0) }
            )) {
                ForEach(AnimatedParticlePreset.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }

            Stepper("Count: \(layer.count)", value: Binding(
                get: { layer.count },
                set: { write(\.count, $0) }
            ), in: 1...64)
        }

        Section {
            // The seed is what makes a particle field identical on screen and in every exported
            // frame, so it is offered as a shuffle rather than a number to reason about.
            LabeledContent("Seed", value: "\(layer.seed)")
            Button("Shuffle", systemImage: "shuffle") {
                write(\.seed, Int.random(in: 0...Int(Int32.max)))
            }
        } footer: {
            Text("The seed keeps this particle field identical every time it renders, including in exports.")
        }

        AnimatedPaintEditor(
            title: "Colour",
            paint: Binding(get: { layer.paint }, set: { write(\.paint, $0) }),
            onEditingChanged: { editing in
                if editing { editor.beginGesture("particle-\(layer.base.id)") } else { editor.endGesture() }
            }
        )
        // Particles draw one glyph per particle and cannot carry a gradient across them.
        if case .solid = layer.paint {} else {
            Text("Particles use the gradient's first colour.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func write<Value>(_ keyPath: WritableKeyPath<AnimatedParticleLayer, Value>, _ newValue: Value) {
        editor.updateLayer(id: layer.base.id, name: "Edit Particles", coalescingKey: "particle-\(layer.base.id)") {
            guard case .particle(var value) = $0 else { return }
            value[keyPath: keyPath] = newValue
            $0 = .particle(value)
        }
    }
}
#endif
