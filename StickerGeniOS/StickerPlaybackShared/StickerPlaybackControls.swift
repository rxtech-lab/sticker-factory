import AnimatedView
import SwiftUI

struct StickerPlaybackControls: View {
    let document: AnimatedDocument
    @Binding var settings: StickerControlSettings
    var origin: Date
    @State private var selectedID: UUID?
    @State private var editingEntry: EditingEntry?
    private struct EditingEntry: Identifiable { let id: UUID }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var shouldReduceMotion: Bool {
        reduceMotion || ProcessInfo.processInfo.arguments.contains("--reduce-motion")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Playback", selection: Binding(get: { settings.mode }, set: { settings.selectMode($0) })) {
                Text("Single").tag(StickerControlSettings.Mode.single)
                Text("Multiple").tag(StickerControlSettings.Mode.multiple)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("sticker-playback-mode")

            if settings.mode == .single {
                StickerControlRows(document: document, settings: $settings)
            } else {
                let timeline = try? StickerPlaybackTimeline(document: document, settings: settings)
                TimelineView(.animation(minimumInterval: 0.1, paused: shouldReduceMotion)) { context in
                    let playing = timeline?.sample(at: shouldReduceMotion ? 0 : context.date.timeIntervalSince(origin)).index
                    List {
                        ForEach(Array(settings.entries.enumerated()), id: \.element.id) { index, entry in
                            Button {
                                selectedID = entry.id
                                editingEntry = .init(id: entry.id)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: playing == index ? "play.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(playing == index ? AppColors.ink : AppColors.muted)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Animation \(index + 1)").font(.subheadline.bold())
                                        Text(summary(entry)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "slider.horizontal.3")
                                }
                                .foregroundStyle(AppColors.ink)
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            .accessibilityIdentifier("sticker-sequence-entry-\(index)")
                            .accessibilityValue(playing == index ? "Playing" : "")
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 14, trailing: 12))
                            .listRowBackground(
                                Color.clear
                                    .posterSurface(
                                        cornerRadius: Poster.tileRadius,
                                        fill: playing == index ? AppColors.lime : AppColors.paper,
                                        offset: Poster.smallShadow
                                    )
                                    .padding(.leading, 2)
                                    .padding(.trailing, 6)
                                    .padding(.top, 4)
                                    .padding(.bottom, 10)
                            )
                        }
                        .onMove { settings.entries.move(fromOffsets: $0, toOffset: $1) }
                        .onDelete { settings.entries.remove(atOffsets: $0) }
                    }
                    .listStyle(.plain)
                    .environment(\.editMode, .constant(.active))
                    .scrollContentBackground(.hidden)
                    .frame(height: min(384, CGFloat(settings.entries.count) * 96))
                    .accessibilityIdentifier("sticker-sequence-list")
                }
                Button {
                    let source = settings.entries.first { $0.id == selectedID } ?? settings.entries.last
                    let entry = StickerControlSettings.Entry(settings: source?.settings ?? settings)
                    settings.entries.append(entry)
                    selectedID = entry.id
                    editingEntry = .init(id: entry.id)
                } label: {
                    Label("Add animation", systemImage: "plus")
                }
                .buttonStyle(.posterSecondaryCompact)
                .accessibilityIdentifier("sticker-sequence-add")
            }
        }
        .sheet(item: $editingEntry) { selection in
            if let index = settings.entries.firstIndex(where: { $0.id == selection.id }) {
                let original = settings.entries[index]
                StickerSequenceEntrySheet(document: document, number: index + 1, entry: Binding(
                    get: { settings.entries.first { $0.id == selection.id } ?? original },
                    set: { updated in
                        guard let current = settings.entries.firstIndex(where: { $0.id == selection.id }) else { return }
                        settings.entries[current] = updated
                    }
                ))
            }
        }
    }

    private func summary(_ entry: StickerControlSettings.Entry) -> String {
        let controls = document.configuration?.controls ?? []
        let choices = controls.filter { $0.type == .choice }.compactMap { control in
            let value = entry.values[control.id]?.string ?? control.defaultValue.string
            return control.options?.first { $0.id == value }?.label
        }
        let speedControl = controls.first { $0.type == .number && $0.binding == "speed" }
        let speed = speedControl.flatMap { entry.values[$0.id]?.number ?? $0.defaultValue.number } ?? entry.speed
        return (choices + [speed.formatted(.number.precision(.fractionLength(0...2))) + "×"]).joined(separator: " · ")
    }
}

/// Owns the editing state so a parent preview refresh cannot replace an open picker.
private struct StickerSequenceEntrySheet: View {
    let document: AnimatedDocument
    let number: Int
    @Binding var entry: StickerControlSettings.Entry
    @State private var draft: StickerControlSettings
    @Environment(\.dismiss) private var dismiss

    init(document: AnimatedDocument, number: Int, entry: Binding<StickerControlSettings.Entry>) {
        self.document = document
        self.number = number
        _entry = entry
        _draft = State(initialValue: entry.wrappedValue.settings)
    }

    var body: some View {
        NavigationStack {
            StickerBackground {
                ScrollView {
                    StickerControlRows(document: document, settings: $draft, sequenceEntry: true)
                        .padding(20)
                }
            }
            .navigationTitle("Animation \(number)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .fontDesign(.rounded)
        .tint(AppColors.accent)
        .presentationDetents([.large])
        .presentationBackgroundInteraction(.disabled)
        .onChange(of: draft) { _, updated in
            var value = StickerControlSettings.Entry(settings: updated)
            value.id = entry.id
            entry = value
        }
    }
}
