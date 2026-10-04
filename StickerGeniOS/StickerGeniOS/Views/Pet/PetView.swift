import PhotosUI
import SwiftUI

/// The Pet tab: the controllable sticker this account has adopted, and the ways to change it.
///
/// Choosing happens in `PetPickerSheet`, and progress is reported through an overlay, so a change
/// in flight is never just a frozen screen.
struct PetView: View {
    @State private var model: PetModel
    @State private var showingPicker = false
    @State private var showingActions = false
    @State private var showingDiary = false
    @State private var showingIdentity = false
    @State private var showingPetOptions = false
    @State private var photoItem: PhotosPickerItem?

    init(api: any StickerAPIClientProtocol) {
        _model = State(initialValue: PetModel(api: api))
    }

    var body: some View {
        content
            .navigationTitle("Pet")
            .background { PosterPaper() }
            .safeAreaInset(edge: .top) {
                // The picker shows its own errors while it is up; this is for the tab's.
                if let errorMessage = model.errorMessage, !isPresentingSheet {
                    ErrorBanner(message: errorMessage).padding(.horizontal)
                }
            }
            .toolbar {
                if model.pet != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            Haptics.tap(.light)
                            showingDiary = true
                        } label: {
                            Label("Diary", systemImage: "book.closed")
                        }
                        .accessibilityIdentifier("pet-diary-button")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Change") {
                            Haptics.tap(.light)
                            showingPetOptions = true
                        }
                        .accessibilityIdentifier("change-pet-button")
                    }
                }
            }
            .task {
                await model.loadPet()
                model.syncWorldInBackground()
            }
            .refreshable { await model.loadPet() }
            .overlay {
                if let activity = model.activity, !isPresentingSheet { PetActivityOverlay(activity: activity) }
            }
            .animation(.snappy(duration: 0.2), value: model.activity)
            .confirmationDialog("Your Pet", isPresented: $showingPetOptions, titleVisibility: .hidden) {
                Button("Change Pet") {
                    Haptics.tap(.light)
                    showingPicker = true
                }
                .accessibilityIdentifier("pet-option-change")
                Button("Release Pet", role: .destructive) {
                    Haptics.tap(.medium)
                    Task { await model.release() }
                }
                .accessibilityIdentifier("pet-option-release")
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                photoItem = nil
                Task { await show(item) }
            }
            .sheet(isPresented: $showingPicker) {
                PetPickerSheet(model: model)
            }
            .sheet(isPresented: $showingActions) {
                PetActionsSheet(model: model)
            }
            .sheet(isPresented: $showingDiary) {
                PetDiarySheet(api: model.api, maxHp: model.pet?.maxHp ?? 100)
            }
            .sheet(isPresented: $showingIdentity) {
                PetIdentitySheet(model: model)
            }
            .telemetryScreen("pet")
    }

    /// Loads the picked picture and shows it to the pet. A picture that cannot be read says so.
    private func show(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
            model.errorMessage = String(localized: "This picture could not be read.")
            Haptics.failure()
            return
        }
        model.showPhoto(image)
    }

    /// A sheet shows its own errors and progress; the tab's would sit behind it, unseen.
    private var isPresentingSheet: Bool { showingPicker || showingActions || showingDiary || showingIdentity }

    @ViewBuilder
    private var content: some View {
        if !model.hasLoadedPet {
            PosterProgress(message: String(localized: "Finding your pet…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let pet = model.pet {
            ScrollView {
                VStack(spacing: 20) {
                    HStack(spacing: 12) {
                        Button {
                            Haptics.tap(.light)
                            showingIdentity = true
                        } label: {
                            Label {
                                Text(pet.identity?.petClass.displayName ?? String(localized: "About"))
                            } icon: {
                                Image(systemName: pet.identity?.petClass.symbol ?? "info.circle")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.posterSecondaryCompact)
                        .accessibilityHint(Text("Shows who your pet is and what it knows of the world"))
                        .accessibilityIdentifier("pet-identity-button")

                        PetGoldBadge(gold: pet.stats.gold)
                    }

                    // The pet stands on the page itself; only its stats sit in a card.
                    VStack(spacing: 6) {
                        Group {
                            if model.isAnswering {
                                PetThinkingBubble()
                            } else {
                                PetSpeechBubble(text: pet.status?.caption ?? String(localized: "I'm here with you. What shall we do?"))
                            }
                        }
                        .accessibilityIdentifier("pet-dialogue")
                        StickerThumbnail(sticker: pet.sticker, api: model.api, detail: .preview)
                            .aspectRatio(1, contentMode: .fit)
                            .frame(maxWidth: 176)
                            // The picture the pet was just shown, held up beside it.
                            .overlay(alignment: .topTrailing) {
                                if let photo = model.shownPhoto {
                                    PetPhotoBubble(image: photo)
                                        .offset(x: 64, y: -4)
                                        .transition(.scale(scale: 0.6, anchor: .bottomLeading).combined(with: .opacity))
                                }
                            }
                            .animation(.snappy(duration: 0.3), value: model.shownPhoto)
                        // The title is no longer drawn, but VoiceOver still names the pet.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(pet.sticker.title))
                        .accessibilityIdentifier("current-pet")
                    }
                    .frame(maxWidth: .infinity)

                    PosterCard(padding: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("How I'm doing")
                                .font(.system(size: 16, weight: .heavy, design: .monospaced))
                                .foregroundStyle(AppColors.ink)
                            PetStatRow(title: "Happiness", value: pet.stats.happiness, symbol: "heart.fill", color: .pink)
                            PetStatRow(title: "HP", value: pet.stats.hp, maximum: pet.maxHp, symbol: "cross.vial.fill", color: .red)
                            PetStatRow(title: "Energy", value: pet.stats.energy, symbol: "bolt.fill", color: .orange)
                        }
                        // An action's effects land as the gauges sliding to their new values.
                        .animation(.snappy(duration: 0.45), value: pet.stats)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("pet-stats")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack(spacing: 12) {
                        Button {
                            Haptics.tap(.light)
                            showingActions = true
                        } label: {
                            Label("Spend Time Together", systemImage: "pawprint.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.poster)
                        .disabled(model.isAnswering)
                        .accessibilityIdentifier("pet-actions-button")

                        // Icon only, so it fits beside the main action without truncating either.
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Image(systemName: "photo.on.rectangle")
                        }
                        .buttonStyle(.posterSecondary)
                        .simultaneousGesture(TapGesture().onEnded { Haptics.tap(.light) })
                        .disabled(model.isAnswering || model.activity != nil)
                        .accessibilityLabel(Text("Show a Picture"))
                        .accessibilityIdentifier("pet-photo-button")
                    }
                }
                .padding()
                .padding(.bottom, 96)
            }
        } else {
            EmptyStateView(
                title: String(localized: "No pet yet"),
                message: String(localized: "Adopt any controllable sticker you made or installed as your pet.")
            ) {
                Button("Choose a Pet") { showingPicker = true }
                    .buttonStyle(.poster)
                    .accessibilityIdentifier("choose-pet-button")
            }
        }
    }
}

/// The pet's latest line, framed like an RPG dialogue box with a tail pointing down at the sticker.
private struct PetSpeechBubble: View {
    let text: String

    var body: some View {
        VStack(spacing: -2) {
            Text(text)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(AppColors.ink)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(AppColors.card, in: .rect(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(AppColors.ink, lineWidth: 3)
                }
                .overlay(alignment: .bottomTrailing) {
                    // The "more to read" cursor of a game text box.
                    Image(systemName: "arrowtriangle.down.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(AppColors.ink)
                        .padding(8)
                        .accessibilityHidden(true)
                }
            BubbleTail()
                .fill(AppColors.card)
                .overlay { BubbleTail().stroke(AppColors.ink, style: StrokeStyle(lineWidth: 3, lineJoin: .round)) }
                .frame(width: 18, height: 12)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Stands in for the pet's reply while it is on its way: a predefined line and a typing cursor.
private struct PetThinkingBubble: View {
    private static let lines: [LocalizedStringResource] = [
        "Hmm, let me think…",
        "Ooh, give me a second…",
        "Thinking about it…",
    ]

    @State private var line = PetThinkingBubble.lines.randomElement()!

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { context in
            let dots = Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 3 + 1
            PetSpeechBubble(text: String(localized: line) + String(repeating: "·", count: dots))
        }
        .accessibilityLabel(Text(line))
    }
}

/// A downward triangle open at the top, so it merges into the bubble's bottom border.
private struct BubbleTail: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

/// One stat drawn like an RPG status window: a monospaced label and a framed, segmented gauge.
struct PetStatRow: View {
    let title: LocalizedStringKey
    let value: Int
    /// The gauge's ceiling: 100 for happiness and energy, the class's own for HP.
    var maximum: Int = 100
    let symbol: String
    let color: Color

    private static let segments = 20

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Label(title, systemImage: symbol)
                    .labelStyle(PetStatLabelStyle(color: color))
                Spacer()
                Text(verbatim: "\(value)/\(maximum)")
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(value)))
            }
            .font(.system(size: 14, weight: .bold, design: .monospaced))
            .foregroundStyle(AppColors.ink)
            gauge
        }
        .accessibilityElement(children: .combine)
    }

    private var gauge: some View {
        let ceiling = max(maximum, 1)
        let filled = Int((Double(min(max(value, 0), ceiling)) / Double(ceiling) * Double(Self.segments)).rounded())
        return HStack(spacing: 2) {
            ForEach(0..<Self.segments, id: \.self) { index in
                Rectangle()
                    .fill(index < filled ? color : AppColors.ink.opacity(0.08))
                    // A lighter top edge gives each block the bevel of a pixel-art gauge.
                    .overlay(alignment: .top) {
                        if index < filled { Rectangle().fill(.white.opacity(0.35)).frame(height: 3) }
                    }
            }
        }
        .frame(height: 12)
        .padding(3)
        .background(AppColors.card)
        .overlay { Rectangle().strokeBorder(AppColors.ink, lineWidth: 2.5) }
        .accessibilityHidden(true)
    }
}

/// Puts the stat's icon in its colour, so each row reads at a glance like a game HUD.
struct PetStatLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(color)
            configuration.title
        }
    }
}

private struct PetActionsSheet: View {
    @Bindable var model: PetModel
    @Environment(\.dismiss) private var dismiss

    private var actions: [PetAction] { model.pet?.actions ?? [] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Your pet picks these for how they feel right now. They change as their mood does.")
                        .foregroundStyle(AppColors.muted)
                    if actions.isEmpty {
                        Text("Your pet is still thinking of something to do. Check back in a moment.")
                            .font(.footnote)
                            .foregroundStyle(AppColors.muted)
                    }
                    ForEach(actions) { action in
                        let affordable = model.canAfford(action)
                        Button {
                            Haptics.tap(.light)
                            // The reply arrives on the tab, in the pet's dialogue box.
                            if model.interact(action) { dismiss() }
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(action.title)
                                    if action.effects.gold != 0 {
                                        PetGoldChip(change: action.effects.gold)
                                    }
                                    if !affordable {
                                        Text("Needs \(action.effects.price) gold")
                                            .font(.caption)
                                            .foregroundStyle(AppColors.muted)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                // The pill has no vertical padding of its own; a second line
                                // would otherwise run into its rounded edges.
                                .padding(.vertical, action.effects.gold != 0 || !affordable ? 12 : 0)
                            } icon: {
                                Image(systemName: "sparkles")
                            }
                        }
                        .buttonStyle(.posterSecondary)
                        .disabled(model.activity != nil || model.isAnswering || !affordable)
                        .accessibilityIdentifier("pet-action-\(action.id)")
                    }
                }
                .padding()
            }
            .navigationTitle("Spend Time Together")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    PetGoldBadge(gold: model.pet?.stats.gold ?? 0)
                }
                // A balance, not a button: without this the toolbar wraps it in glass.
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { Haptics.tap(.light); dismiss() }
                        .disabled(model.activity != nil)
                }
            }
            .safeAreaInset(edge: .top) {
                if let errorMessage = model.errorMessage {
                    ErrorBanner(message: errorMessage).padding(.horizontal)
                }
            }
        }
        .overlay {
            if let activity = model.activity { PetActivityOverlay(activity: activity) }
        }
        .animation(.snappy(duration: 0.2), value: model.activity)
        .interactiveDismissDisabled(model.activity != nil)
    }
}

/// How much gold the pet has, as a coin and a number. Sits beside the pet and atop its actions.
struct PetGoldBadge: View {
    let gold: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "dollarsign.circle.fill").foregroundStyle(.yellow)
            Text(verbatim: "\(gold)")
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(gold)))
        }
        .font(.system(size: 15, weight: .heavy, design: .monospaced))
        .foregroundStyle(AppColors.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.18), in: .capsule)
        .overlay { Capsule().strokeBorder(AppColors.ink, lineWidth: 2) }
        .animation(.snappy(duration: 0.45), value: gold)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(gold) gold"))
        .accessibilityIdentifier("pet-gold")
    }
}

/// What an action costs or earns in gold, as a small signed chip.
struct PetGoldChip: View {
    let change: Int

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "dollarsign.circle.fill").foregroundStyle(.yellow)
            Text(verbatim: change > 0 ? "+\(change)" : "\(change)")
        }
        .font(.system(size: 12, weight: .bold, design: .monospaced))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.yellow.opacity(0.18), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(change > 0 ? Text("Earns \(change) gold") : Text("Costs \(-change) gold"))
    }
}

/// How one change moves each stat, as small signed chips. Unchanged stats are left out. The diary
/// shows every number; the actions sheet shows only gold.
struct PetEffectsRow: View {
    let effects: PetActionEffects

    var body: some View {
        HStack(spacing: 6) {
            chip(effects.happiness, symbol: "heart.fill", color: .pink, name: "Happiness")
            chip(effects.hp, symbol: "cross.vial.fill", color: .red, name: "HP")
            chip(effects.energy, symbol: "bolt.fill", color: .orange, name: "Energy")
            if effects.gold != 0 { PetGoldChip(change: effects.gold) }
        }
        .font(.system(size: 12, weight: .bold, design: .monospaced))
    }

    @ViewBuilder
    private func chip(_ value: Int, symbol: String, color: Color, name: LocalizedStringKey) -> some View {
        if value != 0 {
            HStack(spacing: 2) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(value > 0 ? "+\(value)" : "\(value)")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: .capsule)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(name) + Text(verbatim: " \(value > 0 ? "+" : "")\(value)"))
        }
    }
}

/// The picture the pet was just shown, in a framed bubble with a tail pointing down at the pet.
private struct PetPhotoBubble: View {
    let image: UIImage

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 72, height: 72)
            .clipShape(.rect(cornerRadius: 6))
            .padding(4)
            .background(AppColors.card, in: .rect(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(AppColors.ink, lineWidth: 3) }
            .overlay(alignment: .bottomLeading) {
                BubbleTail()
                    .fill(AppColors.card)
                    .overlay { BubbleTail().stroke(AppColors.ink, style: StrokeStyle(lineWidth: 3, lineJoin: .round)) }
                    .frame(width: 14, height: 10)
                    .rotationEffect(.degrees(20))
                    .offset(x: 10, y: 8)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("The picture you showed your pet"))
            .accessibilityIdentifier("pet-photo-bubble")
    }
}

/// Chooses the pet from every controllable sticker the account can pose.
///
/// The server filters the candidates and groups them the way the library does, so a member of an
/// installed pack sits under its pack's name. Tapping one adopts it and closes the sheet.
struct PetPickerSheet: View {
    @Bindable var model: PetModel

    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Choose a Pet")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, prompt: "Search controllable stickers")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            Haptics.tap(.light)
                            dismiss()
                        }
                        .accessibilityIdentifier("pet-picker-cancel-button")
                    }
                }
                .safeAreaInset(edge: .top) {
                    if let errorMessage = model.errorMessage {
                        ErrorBanner(message: errorMessage).padding(.horizontal)
                    }
                }
                .task(id: query) {
                    await model.loadCandidates(query: query, debounce: query.isEmpty ? .zero : .milliseconds(300))
                }
                .overlay {
                    if let activity = model.activity { PetActivityOverlay(activity: activity) }
                }
                .animation(.snappy(duration: 0.2), value: model.activity)
        }
        .interactiveDismissDisabled(model.activity != nil)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoadingCandidates && model.sections.isEmpty {
            PosterProgress(message: String(localized: "Loading stickers…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.candidateSections.isEmpty {
            EmptyStateView(
                title: query.isEmpty
                    ? String(localized: "No controllable stickers")
                    : String(localized: "No matches"),
                message: query.isEmpty
                    ? String(localized: "Create an animated sticker with controls, or install a pack that has one.")
                    : String(localized: "No controllable sticker matches “\(query)”.")
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(model.candidateSections) { section in
                        candidates(in: section)
                    }
                }
                .padding()
            }
            .refreshable { await model.loadCandidates(query: query, debounce: .zero) }
        }
    }

    private func candidates(in section: LibrarySection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.kind == .mine ? String(localized: "My Stickers") : section.title)
                .font(.posterDisplay(15, weight: .bold))
                .foregroundStyle(AppColors.ink)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 12) {
                ForEach(section.stickers) { sticker in
                    Button {
                        Haptics.selection()
                        Task {
                            if await model.adopt(sticker) { dismiss() }
                        }
                    } label: {
                        PickableSticker(sticker: sticker, api: model.api, isSelected: sticker.id == model.pet?.sticker.id)
                    }
                    // Undecorated, like the pack picker: the selection haptic answers the tap, and
                    // the overlay answers the request.
                    .buttonStyle(.plain)
                    .disabled(model.activity != nil)
                    .accessibilityIdentifier("pet-candidate-\(sticker.id)")
                }
            }
        }
    }
}

/// Covers the screen while a change is in flight, so a second tap cannot race the first.
struct PetActivityOverlay: View {
    let activity: PetModel.Activity

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 10) {
                ProgressView().controlSize(.large).tint(.white)
                Group {
                    switch activity {
                    case .adopting(let title): Text("Adopting \(title)…")
                    case .releasing: Text("Releasing your pet…")
                    case .connectingWorld: Text("Telling your pet about your world…")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.9))
            }
            .padding(24)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
        }
        .transition(.opacity)
        .accessibilityIdentifier("pet-activity-overlay")
    }
}

#Preview {
    NavigationStack { PetView(api: MockStickerAPIClient()) }
}
