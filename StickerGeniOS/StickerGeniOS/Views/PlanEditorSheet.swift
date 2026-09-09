import SwiftUI

/// The plan card, opened up.
///
/// Reached from the two lines of the card that describe what will be built — the layer count and
/// the timing — because those are the parts a user disagrees with, and until now disagreeing meant
/// rejecting the whole plan and typing the correction as prose.
///
/// Saving does not overwrite anything: the server keeps the version the edit started from, so the
/// version picker on the card is the undo.
struct PlanEditorSheet: View {
    let record: PlanRecord
    var focus: PlanEditorFocus = .layers
    let onSave: (PlanEdit) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: PlanEditorModel
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(record: PlanRecord, focus: PlanEditorFocus = .layers, onSave: @escaping (PlanEdit) async throws -> Void) {
        self.record = record
        self.focus = focus
        self.onSave = onSave
        _model = State(initialValue: PlanEditorModel(plan: record.plan))
    }

    private var edit: PlanEdit { model.edit() }
    private var canSave: Bool { !isSaving && model.validationMessage == nil && !edit.isEmpty }

    var body: some View {
        StickerBackground {
            ScrollView {
                ScrollViewReader { proxy in
                    VStack(alignment: .leading, spacing: 20) {
                        details
                        if model.isAnimated {
                            Divider()
                            timing.id(PlanEditorFocus.timing)
                        }
                        Divider()
                        layers.id(PlanEditorFocus.layers)
                        if let message = model.validationMessage { NoticeBanner(message: message) }
                        if let errorMessage { ErrorBanner(message: errorMessage) }
                    }
                    .padding(20)
                    .onAppear {
                        // Tapping the duration has to land on the duration, not on the top of a
                        // form that happens to contain it.
                        guard focus == .timing, model.isAnimated else { return }
                        proxy.scrollTo(PlanEditorFocus.timing, anchor: .top)
                    }
                }
            }
        }
        .navigationTitle("Edit plan")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isSaving)
        .accessibilityIdentifier("plan-editor-sheet")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }.disabled(isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    save()
                } label: {
                    if isSaving { ProgressView().controlSize(.small) } else { Text("Save") }
                }
                .disabled(!canSave)
                .accessibilityIdentifier("plan-editor-save")
            }
        }
    }

    private func save() {
        let edit = self.edit
        guard !edit.isEmpty else { return dismiss() }
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                Haptics.tap(.medium)
                try await onSave(edit)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Sections

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            PosterSectionHeader(title: String(localized: "Plan"), subtitle: String(localized: "Title and summary"))
            PosterField(placeholder: String(localized: "Title"), text: $model.title)
                .accessibilityIdentifier("plan-editor-title")
            PosterField(
                placeholder: String(localized: "What this sticker is"),
                text: $model.summary,
                lineLimit: 2...5
            )
            .accessibilityIdentifier("plan-editor-summary")
        }
    }

    private var timing: some View {
        VStack(alignment: .leading, spacing: 12) {
            PosterSectionHeader(
                title: String(localized: "Timing"),
                subtitle: String(localized: "How long the animation runs"),
                highlight: AppColors.sky
            )
            HStack {
                Text("Duration").posterLabelStyle(10, color: AppColors.muted)
                Spacer()
                Text("\(formatted(model.durationSeconds))s").font(.posterDisplay(17, weight: .bold))
            }
            // The plan schema's own window: half a second is the shortest readable beat, four the
            // longest a sticker may run.
            Slider(value: $model.durationSeconds, in: 0.5...4, step: 0.1)
                .tint(AppColors.ink)
                .accessibilityIdentifier("plan-editor-duration")
                .accessibilityValue("\(formatted(model.durationSeconds)) seconds")

            Picker("Frame rate", selection: $model.fps) {
                ForEach([12, 15, 24, 30], id: \.self) { Text("\($0) fps").tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("plan-editor-fps")

            Picker("Loop", selection: $model.loop) {
                ForEach(StickerLoopBehavior.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("plan-editor-loop")
        }
    }

    private var layers: some View {
        VStack(alignment: .leading, spacing: 14) {
            PosterSectionHeader(
                title: String(localized: "Layers"),
                subtitle: String(localized: "\(model.layers.count) of \(PlanEditorModel.layerLimit)"),
                highlight: AppColors.peach
            )
            ForEach($model.layers) { $layer in
                PlanEditorLayerCard(
                    layer: $layer,
                    index: model.layers.firstIndex(where: { $0.id == layer.id }) ?? 0,
                    isAnimated: model.isAnimated,
                    // One clip per plan: the option stays open for the layer that holds it and
                    // closes everywhere else, rather than failing on save.
                    canBecomeVideo: model.videoLayerID == nil || model.videoLayerID == layer.id,
                    canRemove: model.layers.count > 1,
                    onRemove: { remove(layer.id) }
                )
            }
            Button {
                Haptics.tap(.light)
                model.layers.append(PlanEditorModel.newLayer(existingIDs: Set(model.layers.map(\.layerId))))
            } label: {
                PosterMenuLabel("Add layer", icon: .add).frame(maxWidth: .infinity)
            }
            .buttonStyle(.posterSecondary)
            .disabled(model.layers.count >= PlanEditorModel.layerLimit)
            .accessibilityIdentifier("plan-editor-add-layer")
        }
    }

    private func remove(_ id: UUID) {
        Haptics.tap(.light)
        withAnimation { model.layers.removeAll { $0.id == id } }
    }

    private func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// One layer of the plan, opened for editing.
private struct PlanEditorLayerCard: View {
    @Binding var layer: PlanEditorModel.Layer
    let index: Int
    let isAnimated: Bool
    let canBecomeVideo: Bool
    let canRemove: Bool
    let onRemove: () -> Void

    var body: some View {
        PosterCard {
            VStack(alignment: .leading, spacing: 12) {
                header
                sourcePicker
                if layer.source == .keep {
                    Text("Kept as it is — \(layer.keptLabel). Switch it to an image to describe it yourself.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(AppColors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    PosterField(
                        placeholder: String(localized: "What this layer shows"),
                        text: $layer.prompt,
                        lineLimit: 2...5
                    )
                    .accessibilityIdentifier("plan-editor-layer-prompt-\(index)")
                    if layer.source == .video {
                        PosterField(
                            placeholder: String(localized: "How it moves, e.g. a slow turntable spin"),
                            text: $layer.motion,
                            lineLimit: 1...4
                        )
                        .accessibilityIdentifier("plan-editor-layer-motion-\(index)")
                        Stepper(value: $layer.videoSeconds, in: 2...4) {
                            Text("Clip length \(layer.videoSeconds)s")
                                .posterLabelStyle(10, color: AppColors.muted)
                        }
                        .accessibilityIdentifier("plan-editor-layer-clip-\(index)")
                    }
                }
                if isAnimated { effects }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.posterLabel(9))
                .foregroundStyle(AppColors.ink)
                .frame(width: 20, height: 20)
                .posterSurface(cornerRadius: 10, lineWidth: 1, offset: .zero)
            PosterField(placeholder: String(localized: "Layer name"), text: $layer.name)
                .accessibilityIdentifier("plan-editor-layer-name-\(index)")
            Button(role: .destructive) {
                onRemove()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(canRemove ? AppColors.coral : AppColors.faint)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(!canRemove)
            .accessibilityLabel("Remove layer \(index + 1)")
            .accessibilityIdentifier("plan-editor-remove-layer-\(index)")
        }
    }

    private var sourcePicker: some View {
        Picker("Layer type", selection: $layer.source) {
            if layer.canKeep {
                Text(layer.keptLabel).tag(PlanEditorModel.Source.keep)
            }
            Text("Image").tag(PlanEditorModel.Source.image)
            // A clip only means anything in a moving sticker, and only one layer may hold one.
            if isAnimated, canBecomeVideo {
                Text("Video").tag(PlanEditorModel.Source.video)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("plan-editor-layer-type-\(index)")
    }

    private var effects: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("MOTION").posterLabelStyle(9, color: AppColors.muted)
                Spacer()
                addEffectMenu
            }
            if layer.effects.isEmpty {
                Text("No motion yet.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(AppColors.faint)
            }
            ForEach($layer.effects) { $effect in
                effectRow($effect)
            }
        }
    }

    private var addEffectMenu: some View {
        Menu {
            ForEach(PlanAnimationCatalog.effects) { entry in
                if entry.needsDirection {
                    Menu(entry.label) {
                        ForEach(PlanAnimationCatalog.directions) { direction in
                            Button(direction.label) { add(entry, direction: direction.value) }
                        }
                    }
                } else {
                    Button(entry.label) { add(entry, direction: nil) }
                }
            }
        } label: {
            PosterMenuLabel("Add motion", icon: .add).posterLabelStyle(9)
        }
        .disabled(layer.effects.count >= 12)
        .accessibilityIdentifier("plan-editor-add-effect-\(index)")
    }

    private func add(_ entry: PlanAnimationCatalog.Effect, direction: String?) {
        Haptics.tap(.light)
        withAnimation {
            layer.effects.append(PlanEditorModel.Effect(
                origin: nil,
                type: entry.type,
                direction: direction,
                delay: 0,
                duration: 0.5,
                originalDelay: 0,
                originalDuration: 0.5
            ))
        }
    }

    private func effectRow(_ effect: Binding<PlanEditorModel.Effect>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(effect.wrappedValue.label)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppColors.ink)
                if let direction = effect.wrappedValue.direction {
                    Text(direction).posterLabelStyle(8, color: AppColors.muted)
                }
                Spacer()
                Button(role: .destructive) {
                    Haptics.tap(.light)
                    withAnimation { layer.effects.removeAll { $0.id == effect.wrappedValue.id } }
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(AppColors.coral)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(effect.wrappedValue.label)")
            }
            // Delay is what makes a staggered reveal legible, and it is the number the card puts on
            // every chip, so it is the one worth a control rather than a redraft.
            HStack(spacing: 12) {
                Stepper(value: effect.delay, in: 0...4, step: 0.1) {
                    Text("Delay \(formatted(effect.wrappedValue.delay))s").posterLabelStyle(9, color: AppColors.muted)
                }
                Stepper(value: effect.duration, in: 0.1...4, step: 0.1) {
                    Text("For \(formatted(effect.wrappedValue.duration))s").posterLabelStyle(9, color: AppColors.muted)
                }
            }
        }
        .padding(10)
        .posterSurface(cornerRadius: Poster.chipRadius, fill: AppColors.paper, lineWidth: 1, offset: .zero)
    }

    private func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// The poster's text field: paper inside a card, so it reads as somewhere to write.
private struct PosterField: View {
    let placeholder: String
    @Binding var text: String
    var lineLimit: ClosedRange<Int>?

    var body: some View {
        Group {
            if let lineLimit {
                TextField(placeholder, text: $text, axis: .vertical).lineLimit(lineLimit)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 14, design: .rounded))
        .padding(10)
        .posterSurface(
            cornerRadius: Poster.chipRadius,
            fill: AppColors.paper,
            lineWidth: Poster.hairline,
            offset: .zero
        )
    }
}

#Preview("Plan editor") {
    NavigationStack {
        PlanEditorSheet(record: PreviewFixtures.planVersions[1]) { _ in }
    }
}
