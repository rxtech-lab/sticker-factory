#if os(iOS)
import SwiftUI

/// A numeric field that lets you type a partial number.
///
/// Clamping on every keystroke is the obvious implementation and the wrong one: typing "1" on the
/// way to "1024" would snap the canvas to the 16pt minimum, and the next keystroke appends to *that*.
/// So the draft string is held as-is while the field has focus and only committed — parsed, clamped,
/// and written back — when focus leaves or the user hits return.
struct AnimatedNumberField: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var format: String = "%.2f"
    var keyboard: UIKeyboardType = .decimalPad

    @State private var draft: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $draft)
                .keyboardType(keyboard)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .focused($isFocused)
                .submitLabel(.done)
                .onSubmit(commit)
                .onChange(of: isFocused) { _, focused in
                    if focused { draft = String(format: format, value) } else { commit() }
                }
                .onChange(of: value) { _, new in
                    // Follow the model when something else changes it — a canvas drag, an undo —
                    // but never while the user is mid-edit.
                    if !isFocused { draft = String(format: format, new) }
                }
                .onAppear { draft = String(format: format, value) }
        }
    }

    private func commit() {
        guard let parsed = Double(draft.replacingOccurrences(of: ",", with: ".")) else {
            draft = String(format: format, value)
            return
        }
        value = min(max(parsed, range.lowerBound), range.upperBound)
        draft = String(format: format, value)
    }
}

/// The integer twin of `AnimatedNumberField`, for pixel dimensions and counts.
struct AnimatedIntegerField: View {
    let title: String
    @Binding var value: Int
    var range: ClosedRange<Int>

    var body: some View {
        AnimatedNumberField(
            title: title,
            value: Binding(
                get: { Double(value) },
                set: { value = Int($0.rounded()) }
            ),
            range: Double(range.lowerBound)...Double(range.upperBound),
            format: "%.0f",
            keyboard: .numberPad
        )
    }
}

/// A labelled slider with a live monospaced readout.
///
/// `onEditingChanged` is wired to the editor's gesture coalescing, so dragging a slider is one undo
/// step rather than one per pixel.
struct AnimatedValueSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double?
    var format: String = "%.2f"
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let step {
                Slider(value: $value, in: range, step: step, onEditingChanged: onEditingChanged)
            } else {
                Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
            }
        }
    }
}

/// A pair of sliders for a normalized point, with an option to lock them together.
struct AnimatedPointSlider: View {
    let title: String
    @Binding var point: AnimatedPoint
    var range: ClosedRange<Double>
    /// Text layers render at `min(x, y)` on both axes, so showing two independent sliders for one
    /// would let the inspector display numbers the renderer ignores.
    var uniform: Bool = false
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        if uniform {
            AnimatedValueSlider(
                title: title,
                value: Binding(
                    get: { min(point.x, point.y) },
                    set: { point = AnimatedPoint(x: $0, y: $0) }
                ),
                range: range,
                step: nil,
                onEditingChanged: onEditingChanged
            )
        } else {
            AnimatedValueSlider(
                title: "\(title) X",
                value: Binding(get: { point.x }, set: { point.x = $0 }),
                range: range,
                step: nil,
                onEditingChanged: onEditingChanged
            )
            AnimatedValueSlider(
                title: "\(title) Y",
                value: Binding(get: { point.y }, set: { point.y = $0 }),
                range: range,
                step: nil,
                onEditingChanged: onEditingChanged
            )
        }
    }
}

struct AnimatedEasingPicker: View {
    @Binding var easing: AnimatedEasing
    var isEnabled: Bool = true

    var body: some View {
        Picker("Easing", selection: $easing) {
            ForEach(AnimatedEasing.allCases, id: \.self) { value in
                Text(value.editorLabel).tag(value)
            }
        }
        .disabled(!isEnabled)
    }
}

/// A hex colour field paired with the system colour picker.
///
/// The two directions are not symmetric. `Color(animatedHex:)` already exists for text → colour;
/// the reverse has to go through `Color.Resolved`, and its components can fall outside `0...1`
/// because the system picker works in extended-range sRGB. Clamping before formatting is what stops
/// a wide-gamut pick from producing a hex string the document schema rejects.
struct AnimatedHexColorField: View {
    let title: String
    @Binding var hex: String

    @Environment(\.self) private var environment
    @State private var draft: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            ColorPicker(
                title,
                selection: Binding(
                    get: { Color(animatedHex: hex) },
                    set: { hex = Self.hexString(from: $0, in: environment, preservingAlphaOf: hex) }
                ),
                supportsOpacity: true
            )
            TextField("#RRGGBB", text: $draft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .monospaced()
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 110)
                .focused($isFocused)
                .submitLabel(.done)
                .onSubmit(commit)
                .onChange(of: isFocused) { _, focused in if !focused { commit() } }
                .onChange(of: hex) { _, new in if !isFocused { draft = new } }
                .onAppear { draft = hex }
        }
    }

    private func commit() {
        var candidate = draft.trimmingCharacters(in: .whitespaces).uppercased()
        if !candidate.hasPrefix("#") { candidate = "#" + candidate }
        if candidate.isAnimatedHexColor {
            hex = candidate
        }
        // Snap back rather than leaving unusable text sitting in the field.
        draft = hex
    }

    static func hexString(from color: Color, in environment: EnvironmentValues, preservingAlphaOf existing: String) -> String {
        let resolved = color.resolve(in: environment)
        let clamp = { (value: Float) in Int((min(max(value, 0), 1) * 255).rounded()) }
        let base = String(format: "#%02X%02X%02X", clamp(resolved.red), clamp(resolved.green), clamp(resolved.blue))
        let alpha = clamp(resolved.opacity)
        // Only carry an alpha channel when it is actually doing something, so a fully opaque colour
        // round-trips as the familiar six-digit form.
        guard alpha < 255 else { return base }
        return base + String(format: "%02X", alpha)
    }
}

extension AnimatedEasing {
    var editorLabel: String {
        switch self {
        case .linear: "Linear"
        case .easeIn: "Ease In"
        case .easeOut: "Ease Out"
        case .easeInOut: "Ease In Out"
        case .springSoft: "Spring (Soft)"
        case .springBouncy: "Spring (Bouncy)"
        }
    }
}

extension AnimatedBlendMode {
    var editorLabel: String {
        switch self {
        case .normal: "Normal"
        case .multiply: "Multiply"
        case .screen: "Screen"
        case .overlay: "Overlay"
        case .softLight: "Soft Light"
        case .hardLight: "Hard Light"
        case .difference: "Difference"
        case .plusLighter: "Plus Lighter"
        }
    }
}

extension AnimatedLoop {
    var editorLabel: String {
        switch self {
        case .once: "Once"
        case .loop: "Loop"
        case .pingPong: "Ping-Pong"
        }
    }
}

extension AnimatedLayerType {
    var editorLabel: String { AnimatedEditorDefaults.defaultName(for: self) }
    var editorSymbol: String { AnimatedEditorDefaults.symbolName(for: self) }
}
#endif
