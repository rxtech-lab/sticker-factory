#if os(iOS)
import SwiftUI

/// Edits an `AnimatedPaint` — solid, linear gradient, or radial gradient.
///
/// One editor for every fillable thing in the document: text colour, shape fill, stroke paint, SVG
/// tint, and both document backgrounds. That is the same reason `AnimatedPaint` is a paint type
/// rather than a layer kind — the alternative is a special case per combination.
struct AnimatedPaintEditor: View {
    let title: String
    @Binding var paint: AnimatedPaint
    var onEditingChanged: (Bool) -> Void = { _ in }

    private enum Style: String, CaseIterable, Identifiable {
        case solid, linear, radial
        var id: Self { self }
        var label: String {
            switch self {
            case .solid: "Solid"
            case .linear: "Linear"
            case .radial: "Radial"
            }
        }
    }

    private var style: Style {
        switch paint {
        case .solid: .solid
        case .linearGradient: .linear
        case .radialGradient: .radial
        }
    }

    var body: some View {
        Section(title) {
            // The setter is an explicit closure rather than a bare `set: convert` method reference:
            // Swift 6.3.2 crashes in IRGen emitting the reabstraction thunk for one over a private
            // nested enum. Same behaviour, no thunk.
            Picker("Style", selection: Binding(get: { style }, set: { convert(to: $0) })) {
                ForEach(Style.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            swatch

            switch paint {
            case .solid(let hex):
                AnimatedHexColorField(title: "Colour", hex: Binding(
                    get: { hex },
                    set: { paint = .solid($0) }
                ))

            case .linearGradient(let stops, let angle):
                stopList(stops) { paint = .linearGradient(stops: $0, angleDegrees: angle) }
                AnimatedValueSlider(
                    title: "Angle",
                    value: Binding(
                        get: { angle },
                        set: { paint = .linearGradient(stops: stops, angleDegrees: $0) }
                    ),
                    range: -360...360,
                    step: 1,
                    format: "%.0f°",
                    onEditingChanged: onEditingChanged
                )

            case .radialGradient(let stops, let centre, let radius):
                stopList(stops) { paint = .radialGradient(stops: $0, center: centre, radius: radius) }
                AnimatedValueSlider(
                    title: "Radius",
                    value: Binding(
                        get: { radius },
                        set: { paint = .radialGradient(stops: stops, center: centre, radius: $0) }
                    ),
                    range: 0.01...4,
                    step: nil,
                    onEditingChanged: onEditingChanged
                )
                AnimatedPointSlider(
                    title: "Centre",
                    point: Binding(
                        get: { centre },
                        set: { paint = .radialGradient(stops: stops, center: $0, radius: radius) }
                    ),
                    range: -1...2,
                    onEditingChanged: onEditingChanged
                )
            }
        }
    }

    private var swatch: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(paint.shapeStyle)
            .frame(height: 32)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.quaternary, lineWidth: 1)
            }
            .accessibilityLabel("\(title) preview")
    }

    @ViewBuilder
    private func stopList(_ stops: [AnimatedGradientStop], _ write: @escaping ([AnimatedGradientStop]) -> Void) -> some View {
        ForEach(Array(stops.enumerated()), id: \.offset) { index, stop in
            VStack(alignment: .leading, spacing: 6) {
                AnimatedHexColorField(title: "Stop \(index + 1)", hex: Binding(
                    get: { stop.color },
                    set: { colour in
                        var next = stops
                        next[index] = .init(color: colour, location: stop.location)
                        write(next)
                    }
                ))
                AnimatedValueSlider(
                    title: "Position",
                    value: Binding(
                        get: { stop.location },
                        set: { location in
                            var next = stops
                            next[index] = .init(color: stop.color, location: location)
                            write(next)
                        }
                    ),
                    range: 0...1,
                    step: nil,
                    onEditingChanged: onEditingChanged
                )
            }
            .swipeActions {
                // A gradient needs at least two stops to be valid, so the last pair is not
                // removable — offering a delete that always fails would be worse than hiding it.
                if stops.count > 2 {
                    Button("Delete", role: .destructive) {
                        var next = stops
                        next.remove(at: index)
                        write(next)
                    }
                }
            }
        }

        Button {
            var next = stops
            let location = min(1, (stops.last?.location ?? 0.5) + 0.25)
            next.append(.init(color: stops.last?.color ?? "#FFFFFF", location: location))
            write(next.sorted { $0.location < $1.location })
        } label: {
            Label("Add Stop", systemImage: "plus")
        }
        .disabled(stops.count >= 8)
    }

    /// Switching style preserves the colours rather than resetting them.
    ///
    /// Going gradient → solid uses `primaryColor`, which already exists on `AnimatedPaint` for the
    /// same reason: particles and the MP4 background fallback also need a single representative
    /// colour where a gradient cannot be expressed.
    private func convert(to newStyle: Style) {
        guard newStyle != style else { return }
        switch newStyle {
        case .solid:
            paint = .solid(paint.primaryColor)
        case .linear:
            paint = .linearGradient(stops: gradientStops(), angleDegrees: 0)
        case .radial:
            paint = .radialGradient(stops: gradientStops(), center: .center, radius: 0.5)
        }
    }

    private func gradientStops() -> [AnimatedGradientStop] {
        switch paint {
        case .solid(let hex):
            // Two stops of the same colour: a valid gradient that looks identical to what was
            // there, so the switch itself never changes the artwork.
            [.init(color: hex, location: 0), .init(color: hex, location: 1)]
        case .linearGradient(let stops, _), .radialGradient(let stops, _, _):
            stops
        }
    }
}

/// Edits an optional paint, with a toggle to turn it off.
///
/// `canDisable` exists for shape layers: `AnimatedShapeLayer.isValid` rejects a shape with neither
/// fill nor stroke, because it draws nothing. The last one standing has its toggle disabled rather
/// than being allowed to produce an invalid document.
struct AnimatedOptionalPaintEditor: View {
    let title: String
    @Binding var paint: AnimatedPaint?
    var canDisable: Bool = true
    var defaultPaint: AnimatedPaint = .solid("#FFFFFF")
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        Section {
            Toggle(title, isOn: Binding(
                get: { paint != nil },
                set: { paint = $0 ? defaultPaint : nil }
            ))
            .disabled(paint != nil && !canDisable)
        } footer: {
            if paint != nil && !canDisable {
                Text("A shape needs a fill or a stroke to be visible.")
            }
        }

        if paint != nil {
            AnimatedPaintEditor(
                title: title,
                paint: Binding(get: { paint ?? defaultPaint }, set: { paint = $0 }),
                onEditingChanged: onEditingChanged
            )
        }
    }
}

/// Edits an optional `AnimatedStroke`.
struct AnimatedStrokeEditor: View {
    let title: String
    @Binding var stroke: AnimatedStroke?
    var canDisable: Bool = true
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        Section {
            Toggle(title, isOn: Binding(
                get: { stroke != nil },
                set: { stroke = $0 ? AnimatedStroke(paint: .solid("#FFFFFF")) : nil }
            ))
            .disabled(stroke != nil && !canDisable)
        }

        if let current = stroke {
            AnimatedPaintEditor(
                title: "\(title) Colour",
                paint: Binding(
                    get: { current.paint },
                    set: { var next = current; next.paint = $0; stroke = next }
                ),
                onEditingChanged: onEditingChanged
            )

            Section("\(title) Shape") {
                // Width is a fraction of the layer's fit box, not points — that is what keeps a
                // stroke's visual weight the same at 64pt and at 2048px.
                AnimatedValueSlider(
                    title: "Width",
                    value: Binding(
                        get: { current.width },
                        set: { var next = current; next.width = $0; stroke = next }
                    ),
                    range: 0...0.5,
                    step: nil,
                    format: "%.3f",
                    onEditingChanged: onEditingChanged
                )
                Picker("Cap", selection: Binding(
                    get: { current.lineCap },
                    set: { var next = current; next.lineCap = $0; stroke = next }
                )) {
                    ForEach(AnimatedLineCap.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Picker("Join", selection: Binding(
                    get: { current.lineJoin },
                    set: { var next = current; next.lineJoin = $0; stroke = next }
                )) {
                    ForEach(AnimatedLineJoin.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
            }
        }
    }
}

/// Edits an `AnimatedBackground`, which is a paint plus `none` and `image`.
struct AnimatedBackgroundEditor: View {
    let title: String
    let footer: String
    @Binding var background: AnimatedBackground
    var onEditingChanged: (Bool) -> Void = { _ in }

    private enum Kind: String, CaseIterable, Identifiable {
        case none, solid, gradient
        var id: Self { self }
        var label: String {
            switch self {
            case .none: "None"
            case .solid: "Solid"
            case .gradient: "Gradient"
            }
        }
    }

    private var kind: Kind {
        switch background {
        case .none: .none
        case .solid: .solid
        case .linearGradient, .radialGradient: .gradient
        // An image background is authored by the generator, not here — there is no picker for it in
        // the editor, so it is shown as-is and editing the kind replaces it.
        case .image: .none
        }
    }

    var body: some View {
        Section {
            Picker(title, selection: Binding(get: { kind }, set: { convert(to: $0) })) {
                ForEach(Kind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        } footer: {
            Text(footer)
        }

        if let paint = background.paint {
            AnimatedPaintEditor(
                title: title,
                paint: Binding(
                    get: { paint },
                    set: { background = $0.asBackground }
                ),
                onEditingChanged: onEditingChanged
            )
        }
    }

    private func convert(to newKind: Kind) {
        guard newKind != kind else { return }
        switch newKind {
        case .none:
            background = .none
        case .solid:
            background = .solid(background.paint?.primaryColor ?? "#FFFFFF")
        case .gradient:
            let base = background.paint?.primaryColor ?? "#FFFFFF"
            background = .linearGradient(base, "#000000", angleDegrees: 90)
        }
    }
}

extension AnimatedPaint {
    /// The background equivalent of a paint. Every paint case has one; only `none` and `image` go
    /// the other way without a match.
    var asBackground: AnimatedBackground {
        switch self {
        case .solid(let hex): .solid(hex)
        case .linearGradient(let stops, let angle): .linearGradient(stops: stops, angleDegrees: angle)
        case .radialGradient(let stops, let centre, let radius):
            .radialGradient(stops: stops, center: centre, radius: radius)
        }
    }
}
#endif
