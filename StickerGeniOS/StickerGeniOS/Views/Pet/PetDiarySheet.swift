import Observation
import OSLog
import SwiftUI
import UIKit

/// The pet's diary, a page at a time: every stat change, what caused it, and what the server knew.
@MainActor
@Observable
final class PetDiaryModel {
    private static let log = Logger(subsystem: "app.rxlab.sticker-factory", category: "pet")

    private(set) var events: [PetEvent] = []
    private(set) var nextCursor: String?
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    var errorMessage: String?

    let api: any StickerAPIClientProtocol

    init(api: any StickerAPIClientProtocol) {
        self.api = api
    }

    /// The first page again, replacing what is listed — the sheet opening, or pull to refresh.
    func reload() async {
        await load(cursor: nil)
    }

    /// The next page, when `event` is the last one listed and there is more.
    func loadMoreIfNeeded(after event: PetEvent) async {
        guard event.id == events.last?.id, let nextCursor, !isLoading else { return }
        await load(cursor: nextCursor)
    }

    private func load(cursor: String?) async {
        guard !isLoading || cursor == nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await api.petEvents(cursor: cursor)
            if cursor == nil {
                events = page.events
            } else {
                // A page boundary that shifted under a new event must not list one twice.
                let known = Set(events.map(\.id))
                events += page.events.filter { !known.contains($0.id) }
            }
            nextCursor = page.nextCursor
            hasLoaded = true
            errorMessage = nil
            Self.log.info("pet diary loaded \(page.events.count, privacy: .public) events, more=\(page.nextCursor != nil, privacy: .public)")
        } catch {
            guard !StickerStore.isCancellation(error) else { return }
            hasLoaded = true
            errorMessage = error.localizedDescription
            Self.log.error("pet diary load failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Lists the diary newest first; tapping a line opens everything recorded about it.
struct PetDiarySheet: View {
    @State private var model: PetDiaryModel
    let maxHp: Int
    @Environment(\.dismiss) private var dismiss

    init(api: any StickerAPIClientProtocol, maxHp: Int) {
        _model = State(initialValue: PetDiaryModel(api: api))
        self.maxHp = maxHp
    }

    var body: some View {
        NavigationStack {
            content
                .background { PosterPaper() }
                .navigationTitle("Diary")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { Haptics.tap(.light); dismiss() }
                            .accessibilityIdentifier("pet-diary-done-button")
                    }
                }
                .safeAreaInset(edge: .top) {
                    if let errorMessage = model.errorMessage {
                        ErrorBanner(message: errorMessage).padding(.horizontal)
                    }
                }
                .task { await model.reload() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasLoaded {
            PosterProgress(message: String(localized: "Opening the diary…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.events.isEmpty {
            EmptyStateView(
                title: String(localized: "Nothing written yet"),
                message: String(localized: "Everything that changes how your pet feels will be written here.")
            ) {
                Button("Refresh") {
                    Haptics.tap(.light)
                    Task { await model.reload() }
                }
                .buttonStyle(.posterSecondary)
            }
        } else {
            List {
                ForEach(model.events) { event in
                    NavigationLink {
                        PetEventDetailView(event: event, maxHp: maxHp)
                    } label: {
                        PetEventRow(event: event)
                    }
                    .listRowBackground(AppColors.card)
                    .accessibilityIdentifier("pet-event-\(event.id)")
                    .task { await model.loadMoreIfNeeded(after: event) }
                }
                if model.nextCursor != nil {
                    HStack {
                        Spacer()
                        PosterSpinner()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .refreshable { await model.reload() }
            .accessibilityIdentifier("pet-diary-list")
        }
    }
}

/// One diary line: what kind of thing happened, its title, when, and how the stats moved.
private struct PetEventRow: View {
    let event: PetEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.kind.symbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(AppColors.indigo)
                .frame(width: 28)
                .accessibilityLabel(Text(event.kind.displayName))
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(AppColors.ink)
                Text(event.createdAt, format: .relative(presentation: .named))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppColors.muted)
                PetEffectsRow(effects: event.effects)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Everything recorded about one diary line, down to the server's debug notes.
struct PetEventDetailView: View {
    let event: PetEvent
    let maxHp: Int
    @State private var copied = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(event.kind.displayName, systemImage: event.kind.symbol)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(AppColors.indigo)
                    if !event.detail.isEmpty {
                        Text(event.detail)
                            .font(.system(size: 15, design: .rounded))
                            .foregroundStyle(AppColors.ink)
                    }
                    Text(event.createdAt, format: .dateTime)
                        .font(.footnote)
                        .foregroundStyle(AppColors.muted)
                }
                .padding(.vertical, 4)
            }

            Section("Stats") {
                statChange("Happiness", symbol: "heart.fill", color: .pink, before: event.statsBefore.happiness, after: event.statsAfter.happiness, maximum: 100)
                statChange("HP", symbol: "cross.vial.fill", color: .red, before: event.statsBefore.hp, after: event.statsAfter.hp, maximum: maxHp)
                statChange("Energy", symbol: "bolt.fill", color: .orange, before: event.statsBefore.energy, after: event.statsAfter.energy, maximum: 100)
                if event.effects != PetActionEffects(happiness: 0, hp: 0, energy: 0) {
                    LabeledContent("Effects") { PetEffectsRow(effects: event.effects) }
                }
            }

            if let signals = event.signals {
                Section("The world at the time") {
                    if let weather = signals.weather {
                        LabeledContent {
                            Text(verbatim: "\(weather.kind.displayName), \(weather.temperatureC.formatted(.number.precision(.fractionLength(0...1))))°C")
                        } label: {
                            Label("Weather", systemImage: weather.kind.symbol(isDay: weather.isDay))
                        }
                    }
                    if let steps = signals.stepsToday {
                        LabeledContent {
                            Text(steps.formatted())
                        } label: {
                            Label("Steps today", systemImage: "figure.walk")
                        }
                    }
                    ForEach(signals.headlines, id: \.self) { headline in
                        Label(headline, systemImage: "newspaper")
                    }
                }
            }

            Section {
                Text(verbatim: JSONValue.object(event.debug).prettyPrinted)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(AppColors.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("pet-event-debug")
                Button {
                    copy()
                } label: {
                    Label("Copy Event as JSON", systemImage: "doc.on.doc")
                }
                .accessibilityIdentifier("pet-event-copy-button")
            } header: {
                Text("Debug")
            } footer: {
                Text("What the server recorded when this happened. Copy it to report something odd.")
            }
        }
        .scrollContentBackground(.hidden)
        .background { PosterPaper() }
        .navigationTitle(event.title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if copied {
                Label("Copied", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(AppColors.ink)
                    .posterChip(fill: AppColors.lime)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityIdentifier("pet-event-copied")
            }
        }
        .animation(.snappy(duration: 0.2), value: copied)
    }

    private func statChange(_ title: LocalizedStringKey, symbol: String, color: Color, before: Int, after: Int, maximum: Int) -> some View {
        LabeledContent {
            Text(verbatim: "\(before) → \(after) / \(maximum)")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(after == before ? AppColors.muted : AppColors.ink)
        } label: {
            Label(title, systemImage: symbol).labelStyle(PetStatLabelStyle(color: color))
        }
    }

    /// The whole event, not only the debug notes, so a report carries its own context.
    private func copy() {
        let encoder = JSONEncoder.api
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(event), let text = String(data: data, encoding: .utf8) else {
            Haptics.failure()
            return
        }
        UIPasteboard.general.string = text
        Haptics.success()
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

#Preview {
    PetDiarySheet(api: MockStickerAPIClient(), maxHp: 120)
}
