import SwiftUI

/// GIFs are exported from real generated controllable documents. Choice changes replace the
/// player's media, and all selected examples share the same local pose/mood selection.
struct CreationSelectedPreview: View {
    let options: [CreationPresetOption]
    let controllable: Bool
    let preset: PosePreset
    @Environment(\.locale) private var locale
    @State private var pose: String?
    @State private var mood: String?
    private var examples: [CreationPresetOption] {
        options.isEmpty ? [CreationDemo.bundledOption].compactMap { $0 } : options
    }
    private var controls: CreationPresetPreview? { examples.compactMap(\.preview).first }
    private var poses: [CreationPresetPreview.Choice] { Array((controls?.poses ?? []).prefix(preset.poseCount)) }
    private var selectedPose: String {
        if let pose, poses.contains(where: { $0.id == pose }) { return pose }
        // Trying a higher level immediately demonstrates one of its newly available actions.
        return poses.last?.id ?? controls?.defaultPose ?? ""
    }
    private var selectedMood: String {
        if let mood, controls?.moods.contains(where: { $0.id == mood }) == true { return mood }
        return controls?.defaultMood ?? ""
    }
    private func url(for option: CreationPresetOption) -> URL {
        guard let preview = option.preview else { return option.cover }
        return controllable
            ? preview.animation(pose: selectedPose, mood: selectedMood) ?? preview.url
            : preview.url
    }
    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(examples.enumerated()), id: \.offset) { _, option in
                    VStack(spacing: 8) {
                        CreationPresetImage(url: url(for: option), size: examples.count > 1 ? 320 : 480)
                            .frame(height: 230).frame(maxWidth: .infinity)
                        Text(option.title.localized(locale))
                            .font(.caption.weight(.semibold)).multilineTextAlignment(.center)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("creation-selection-preview-\(option.id)")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(controllable ? "creation-interactive-preview" : "creation-selected-animation-preview")
            if controllable, let controls {
                HStack {
                    Text("Try a pose").font(.subheadline.weight(.semibold))
                    Spacer()
                    Picker("Try a pose", selection: Binding(get: { selectedPose }, set: { pose = $0; Haptics.selection() })) {
                        ForEach(poses) { Text($0.title.localized(locale)).tag($0.id) }
                    }.pickerStyle(.menu).tint(AppColors.ink).accessibilityIdentifier("creation-demo-pose")
                }
                HStack {
                    Text("Try a mood").font(.subheadline.weight(.semibold))
                    Spacer()
                    Picker("Try a mood", selection: Binding(get: { selectedMood }, set: { mood = $0; Haptics.selection() })) {
                        ForEach(controls.moods) { Text($0.title.localized(locale)).tag($0.id) }
                    }.pickerStyle(.menu).tint(AppColors.ink).accessibilityIdentifier("creation-demo-mood")
                }
            }
        }
        .padding(12)
        .posterSurface(cornerRadius: Poster.tileRadius, fill: AppColors.paper)
        .onChange(of: preset) { _, _ in pose = nil }
    }
}
