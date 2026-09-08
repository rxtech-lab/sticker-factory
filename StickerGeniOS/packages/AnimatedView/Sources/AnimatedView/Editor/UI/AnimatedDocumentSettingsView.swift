#if os(iOS)
import SwiftUI

/// Everything that belongs to the sticker rather than to one of its layers: canvas size, whether it
/// animates at all, its timing, and its backgrounds.
struct AnimatedDocumentSettingsView: View {
    @Bindable var editor: AnimatedDocumentEditor
    var configuration: AnimatedEditorConfiguration

    @Environment(\.dismiss) private var dismiss
    @State private var lockAspectRatio = true
    @State private var confirmingStatic = false
    @State private var rescaleOnDurationChange = true

    private var document: AnimatedDocument { editor.document }

    var body: some View {
        NavigationStack {
            Form {
                if configuration.allowsCanvasResize { canvasSection }
                if configuration.allowsKindChange { kindSection }
                if document.kind == .animated { timingSection }
                backgroundSections
            }
            .formStyle(.grouped)
            .navigationTitle("Sticker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog(
                "Convert to a still image?",
                isPresented: $confirmingStatic,
                titleVisibility: .visible
            ) {
                Button("Convert", role: .destructive) { editor.setKind(.static) }
                Button("Cancel", role: .cancel) {}
            } message: {
                // `AnimatedAnchor` has no effects field, so this loss is structural rather than an
                // implementation shortcut — worth saying plainly before it happens.
                Text("""
                    Every layer is frozen at \(String(format: "%.2f", editor.scrubDocumentTime))s and its keyframes are \
                    removed. Blur, hue, and saturation are not preserved.
                    """)
            }
        }
    }

    // MARK: - Canvas

    @ViewBuilder
    private var canvasSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AnimatedCanvasPreset.all) { preset in
                        Button(preset.label) {
                            editor.setCanvas(.init(
                                width: preset.width,
                                height: preset.height,
                                transparent: document.canvas.transparent
                            ))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(preset.matches(document.canvas) ? .accentColor : .secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            AnimatedIntegerField(
                title: "Width",
                value: Binding(
                    get: { document.canvas.width },
                    set: { width in
                        let height = lockAspectRatio
                            ? Int((Double(width) / document.canvas.aspectRatio).rounded())
                            : document.canvas.height
                        editor.setCanvas(.init(width: width, height: height, transparent: document.canvas.transparent))
                    }
                ),
                range: AnimatedCanvas.minimumDimension...AnimatedCanvas.maximumDimension
            )
            AnimatedIntegerField(
                title: "Height",
                value: Binding(
                    get: { document.canvas.height },
                    set: { height in
                        let width = lockAspectRatio
                            ? Int((Double(height) * document.canvas.aspectRatio).rounded())
                            : document.canvas.width
                        editor.setCanvas(.init(width: width, height: height, transparent: document.canvas.transparent))
                    }
                ),
                range: AnimatedCanvas.minimumDimension...AnimatedCanvas.maximumDimension
            )
            Toggle("Lock Aspect Ratio", isOn: $lockAspectRatio)
            Toggle("Transparent", isOn: Binding(
                get: { document.canvas.transparent },
                set: { editor.setCanvas(.init(width: document.canvas.width, height: document.canvas.height, transparent: $0)) }
            ))
        } header: {
            Text("Canvas")
        } footer: {
            // Half of "nothing changes" is wrong, and the half that is wrong is the surprising half.
            Text("""
                Aspect ratio \(String(format: "%.2f", document.canvas.aspectRatio)) : 1. \
                Positions are relative, so no layer moves — but shapes stretch to a non-square canvas \
                and strokes get thicker as it widens. Text and images keep their proportions.
                """)
        }
    }

    // MARK: - Kind

    @ViewBuilder
    private var kindSection: some View {
        Section("Type") {
            Picker("Type", selection: Binding(
                get: { document.kind },
                set: { kind in
                    // Going static destroys every keyframe, so it asks first. Going animated only
                    // adds a timeline and needs no confirmation.
                    if kind == .static { confirmingStatic = true } else { editor.setKind(kind) }
                }
            )) {
                ForEach(AnimatedKind.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Timing

    @ViewBuilder
    private var timingSection: some View {
        let floor = document.minimumDurationForAnimations

        Section {
            AnimatedValueSlider(
                title: "Duration",
                value: Binding(
                    get: { document.durationSeconds },
                    set: { editor.setTiming(durationSeconds: $0, rescalingDetachedKeyframes: rescaleOnDurationChange) }
                ),
                // The lower bound *is* the floor the compiler would reject below, so the error is
                // designed out rather than caught: the slider simply cannot reach an invalid value.
                range: max(AnimatedDocument.durationRange.lowerBound, floor)...AnimatedDocument.durationRange.upperBound,
                step: nil,
                format: "%.2f s"
            )

            Stepper(
                "Frame Rate: \(document.fps) fps",
                value: Binding(get: { document.fps }, set: { editor.setTiming(fps: $0) }),
                in: AnimatedDocument.fpsRange
            )

            Picker("Loop", selection: Binding(
                get: { document.loop },
                set: { editor.setTiming(loop: $0) }
            )) {
                ForEach(AnimatedLoop.allCases, id: \.self) { Text($0.editorLabel).tag($0) }
            }

            Toggle("Rescale Keyframes With Duration", isOn: $rescaleOnDurationChange)
        } header: {
            Text("Timing")
        } footer: {
            if floor > AnimatedDocument.durationRange.lowerBound {
                Text("At least \(String(format: "%.2f", floor))s to fit this sticker's preset motion.")
            } else {
                Text("Rescaling keeps hand-authored motion in proportion. Turning it off clamps keyframes instead, which can merge them.")
            }
        }

        Section {
            AnimatedValueSlider(
                title: "Speed",
                value: Binding(get: { document.speed }, set: { editor.setSpeed($0) }),
                range: AnimatedDocument.speedRange,
                step: nil,
                format: "%.2f\u{00D7}"
            )
            HStack {
                ForEach([0.5, 1.0, 2.0], id: \.self) { value in
                    Button(String(format: "%.1f\u{00D7}", value)) { editor.setSpeed(value) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        } header: {
            Text("Playback")
        } footer: {
            Text("""
                Speed changes playback only; it never rewrites keyframes. \
                One cycle currently takes \(String(format: "%.2f", document.renderedCycleDuration))s on screen.
                """)
        }
    }

    // MARK: - Backgrounds

    @ViewBuilder
    private var backgroundSections: some View {
        AnimatedBackgroundEditor(
            title: "Background",
            footer: "Part of the artwork. It renders into every export, including the transparent ones.",
            background: Binding(
                get: { document.background },
                set: { editor.setBackground($0) }
            )
        )

        AnimatedBackgroundEditor(
            title: "Video Background",
            footer: "Only fills the transparency in formats that cannot carry it, such as MP4.",
            background: Binding(
                get: { document.mp4Background },
                set: { editor.setBackground(document.background, mp4: $0) }
            )
        )
    }
}

/// The canvas sizes offered as one-tap presets.
struct AnimatedCanvasPreset: Identifiable {
    let label: String
    let width: Int
    let height: Int
    var id: String { label }

    func matches(_ canvas: AnimatedCanvas) -> Bool {
        canvas.width == width && canvas.height == height
    }

    static let all: [AnimatedCanvasPreset] = [
        .init(label: "1024²", width: 1024, height: 1024),
        .init(label: "512²", width: 512, height: 512),
        .init(label: "2048²", width: 2048, height: 2048),
        .init(label: "Wide", width: 1024, height: 384),
        .init(label: "Tall", width: 384, height: 1024)
    ]
}
#endif
