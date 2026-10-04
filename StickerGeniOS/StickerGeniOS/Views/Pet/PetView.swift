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
    @State private var photoItem: PhotosPickerItem?
    @Environment(\.scenePhase) private var scenePhase

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
                if let pet = model.pet {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        Button {
                            Haptics.tap(.light)
                            showingDiary = true
                        } label: {
                            Label("Diary", systemImage: "book.closed")
                        }
                        .accessibilityIdentifier("pet-diary-button")
                        Button {
                            Haptics.tap(.light)
                            showingIdentity = true
                        } label: {
                            Label {
                                Text(pet.identity?.petClass.displayName ?? String(localized: "About"))
                            } icon: {
                                Image(systemName: pet.identity?.petClass.symbol ?? "info.circle")
                            }
                        }
                        .accessibilityHint(Text("Shows who your pet is and what it knows of the world"))
                        .accessibilityIdentifier("pet-identity-button")
                    }
                    // The balance and the pet's options share one glass pill.
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 6) {
                            PetGoldBadge(gold: pet.stats.gold)
                            Menu {
                                Button {
                                    Haptics.tap(.light)
                                    showingPicker = true
                                } label: {
                                    Label("Change Pet", systemImage: "arrow.triangle.2.circlepath")
                                }
                                .accessibilityIdentifier("pet-option-change")
                                Button(role: .destructive) {
                                    Haptics.tap(.medium)
                                    Task { await model.release() }
                                } label: {
                                    Label("Release Pet", systemImage: "door.left.hand.open")
                                }
                                .accessibilityIdentifier("pet-option-release")
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.body.weight(.semibold))
                                    .frame(width: 28, height: 28)
                                    .contentShape(.rect)
                            }
                            .accessibilityLabel(Text("Pet Options"))
                            .accessibilityIdentifier("change-pet-button")
                            .simultaneousGesture(TapGesture().onEnded { Haptics.tap(.light) })
                        }
                        .padding(.leading, 4)
                    }
                }
            }
            .task {
                await model.loadPet()
                model.syncWorldInBackground()
            }
            .refreshable { await model.loadPet() }
            // Back from a "your pet grew" banner, or anything else that changed it while away.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, model.hasLoadedPet { Task { await model.loadPet() } }
            }
            // Growing finishes in the background; its banner is swallowed while the app is open, so
            // the tab looks again now and then until the new look is in.
            .task(id: model.pet?.evolution?.isGrowing == true) {
                guard model.pet?.evolution?.isGrowing == true else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { return }
                    await model.loadPet()
                }
            }
            // The weather is drawn in the pet's style after the pet is read; look again until it lands.
            .task(id: model.isWeatherArtPending) {
                guard model.isWeatherArtPending else { return }
                for _ in 0..<4 {
                    try? await Task.sleep(for: .seconds(25))
                    guard !Task.isCancelled else { return }
                    await model.loadPet()
                    guard model.isWeatherArtPending else { return }
                }
            }
            .overlay {
                if let activity = model.activity, !isPresentingSheet { PetActivityOverlay(activity: activity) }
            }
            .animation(.snappy(duration: 0.2), value: model.activity)
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
            let motion = PetMotionProfile(pet: pet)
            ScrollView {
                VStack(spacing: 20) {
                    // The pet stands on the page itself; only its stats sit in a card.
                    // Negative spacing: sticker art carries a transparent margin, so the bubble's
                    // tail reaches down into it to sit right over the pet.
                    VStack(spacing: -18) {
                        Group {
                            if model.isAnswering {
                                PetThinkingBubble()
                            } else {
                                // The pet growing something new in the background is said in the
                                // dialogue box, under its line.
                                PetSpeechBubble(
                                    text: pet.status?.caption ?? String(localized: "I'm here with you. What shall we do?"),
                                    isGrowing: pet.evolution?.isGrowing == true
                                )
                            }
                        }
                        .animation(.snappy(duration: 0.3), value: pet.evolution?.isGrowing)
                        .accessibilityIdentifier("pet-dialogue")
                        // Drawn over the sticker's margin rather than under it.
                        .zIndex(1)
                        // The pose the pet struck for its last interaction, or its sticker until
                        // it has struck one. A new pose fades in over the old one.
                        ZStack {
                            if let pose = model.pose {
                                Image(uiImage: pose)
                                    .resizable()
                                    .interpolation(.high)
                                    .scaledToFit()
                                    .id(model.poseKey)
                                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)))
                            } else {
                                StickerThumbnail(sticker: pet.sticker, api: model.api, detail: .preview)
                                    .transition(.opacity)
                            }
                        }
                            .animation(.snappy(duration: 0.35), value: model.poseKey)
                            .aspectRatio(1, contentMode: .fit)
                            // As big as the page allows, but narrow enough that a picture held up
                            // at its side still fits on screen.
                            .frame(maxWidth: 260)
                            // Breathes and sways while nothing else is going on, so a still pose
                            // still reads as alive: bouncy when happy, slow and slumped when tired.
                            .modifier(PetIdleMotion(profile: motion))
                            // The picture the pet was just shown, held up at its side, clear of the
                            // dialogue box above. It starts a gap past the sticker's trailing edge,
                            // since some art fills its frame and would be covered otherwise.
                            .overlay(alignment: .trailing) {
                                if let photo = model.shownPhoto {
                                    PetPhotoBubble(image: photo)
                                        // Pushed wholly past the trailing edge, then a wide gap on top.
                                        .offset(x: PetPhotoBubble.width + PetPhotoBubble.gap)
                                        .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
                                }
                            }
                            // The pet steps aside to make room, so pet and picture sit side by side,
                            // centred together, instead of the picture running off the edge.
                            .offset(x: model.shownPhoto == nil ? 0 : -(PetPhotoBubble.width + PetPhotoBubble.gap) / 2)
                            .animation(.snappy(duration: 0.3), value: model.shownPhoto)
                        // The title is no longer drawn, but VoiceOver still names the pet.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(pet.sticker.title))
                        .accessibilityIdentifier("current-pet")
                        // Taps, holds, swipes and too many taps each get their own reaction, shaped
                        // by the pet's mood and nature; nothing is sent. Striking a new pose replays
                        // a hop, so the change reads as the pet moving.
                        .modifier(PetTouchReactions(profile: motion, replayKey: model.poseKey) {
                            // Touching the pet is a new interaction, so the picture is put away.
                            if !model.isAnswering { model.dismissPhoto() }
                        })
                        // Takes whatever height the stats card leaves over.
                        .frame(maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The weather where you are, drawn in the pet's style, standing behind the pet's
                    // shoulder on the side the picture it is shown never goes. Pinned to the stage,
                    // not the pet, so it keeps its own motion while the pet breathes and hops.
                    .background(alignment: .leading) {
                        if let weather = pet.signals?.weather {
                            PetWeatherSticker(weather: weather, art: model.weatherArt)
                                .frame(width: 116, height: 116)
                                .offset(y: -60)
                                .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .bottom)))
                        }
                    }
                    // The temperature sits in front, under the drawing, so the pet never covers it.
                    .overlay(alignment: .leading) {
                        if let weather = pet.signals?.weather {
                            PetWeatherChip(weather: weather)
                                .offset(y: 12)
                                .transition(.opacity)
                        }
                    }
                    .animation(.snappy(duration: 0.4), value: pet.signals?.weather)

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
                }
                .padding()
                // Exactly one screen tall, so the pet grows into the room left over; the scroll
                // view stays for pull to refresh.
                .containerRelativeFrame(.vertical)
            }
            // The actions stay put at the bottom, above the tab bar.
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button {
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
                    .disabled(model.isAnswering || model.activity != nil)
                    .accessibilityLabel(Text("Show a Picture"))
                    .accessibilityIdentifier("pet-photo-button")
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
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
    /// Adds a "growing something new" line under the text while the pet evolves.
    var isGrowing = false

    var body: some View {
        VStack(spacing: -2) {
            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppColors.ink)
                    .multilineTextAlignment(.leading)
                    // Hugs the line rather than spanning the screen; long lines still wrap.
                    .fixedSize(horizontal: false, vertical: true)
                if isGrowing {
                    PetGrowingLine()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
                .padding(.leading, 14)
                // Room for the cursor, so a short line does not run into it.
                .padding(.trailing, 26)
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
        "Thinking about it…"
    ]

    @State private var line = PetThinkingBubble.lines.randomElement()!

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { context in
            let dots = Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 3 + 1
            PetSpeechBubble(text: String(localized: line) + String(repeating: "·", count: dots))
        }
        .accessibilityLabel(Text(line))
        // A slow pulse while the pet thinks, so the wait is felt and not just watched. Spaced well
        // apart so a long reply reads as patience, not a buzz; it stops when the bubble goes.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                Haptics.tap(.soft, intensity: 0.45)
            }
        }
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
    /// How long a change stays marked after it lands.
    private static let highlightDuration: Duration = .seconds(3)

    /// The net change still on show, or nil once it has faded. Changes that land while one is
    /// still showing add up, so two quick actions read as their total.
    @State private var delta: Int?
    /// Bumped by every change, restarting the fade-out timer.
    @State private var changeCount = 0

    private var deltaTint: Color { (delta ?? 0) > 0 ? AppColors.mint : AppColors.coral }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Label(title, systemImage: symbol)
                    .labelStyle(PetStatLabelStyle(color: color))
                Spacer()
                if let delta {
                    PetStatDeltaChip(delta: delta, tint: deltaTint)
                        .transition(.scale(scale: 0.5, anchor: .trailing).combined(with: .opacity))
                }
                Text(verbatim: "\(value)/\(maximum)")
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(value)))
            }
            .font(.system(size: 14, weight: .bold, design: .monospaced))
            .foregroundStyle(AppColors.ink)
            gauge
        }
        // A wash behind the whole row, drawn past its edges so marking it never shifts the layout.
        .background {
            if delta != nil {
                RoundedRectangle(cornerRadius: 8)
                    .fill(deltaTint.opacity(0.22))
                    .padding(-6)
                    .transition(.opacity)
            }
        }
        .onChange(of: value) { old, new in
            guard new != old else { return }
            withAnimation(.snappy(duration: 0.3)) { delta = (delta ?? 0) + (new - old) }
            if delta == 0 { withAnimation(.easeOut(duration: 0.3)) { delta = nil } }
            changeCount += 1
        }
        .task(id: changeCount) {
            guard delta != nil else { return }
            try? await Task.sleep(for: Self.highlightDuration)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.5)) { delta = nil }
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

/// How much a stat just moved: a filled, outlined chip with an arrow, mint for a gain, coral for a loss.
private struct PetStatDeltaChip: View {
    let delta: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: delta > 0 ? "arrow.up" : "arrow.down")
            Text(verbatim: delta > 0 ? "+\(delta)" : "\(delta)")
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(delta)))
        }
        .font(.system(size: 12, weight: .heavy, design: .monospaced))
        .foregroundStyle(AppColors.ink)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint, in: .capsule)
        .overlay { Capsule().strokeBorder(AppColors.ink, lineWidth: 2) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(delta > 0 ? Text("Up \(delta)") : Text("Down \(-delta)"))
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

/// The picture the pet was just shown, in a framed bubble with a tail pointing left at the pet.
private struct PetPhotoBubble: View {
    /// The framed picture's width: the photo plus its padding.
    static let width: CGFloat = 80
    /// The space between the pet's frame and the picture.
    static let gap: CGFloat = 44

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
            .overlay(alignment: .leading) {
                // Turned to point left; its open side sits on the frame's border to merge into it.
                BubbleTail()
                    .fill(AppColors.card)
                    .overlay { BubbleTail().stroke(AppColors.ink, style: StrokeStyle(lineWidth: 3, lineJoin: .round)) }
                    .frame(width: 14, height: 10)
                    .rotationEffect(.degrees(90))
                    .offset(x: -10)
                    .accessibilityHidden(true)
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
                    case .findingWeather: Text("Finding the weather where you are…")
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

/// A line in the dialogue box while the pet grows a new mood or look in the background.
private struct PetGrowingLine: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text("Growing something new…")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(AppColors.ink.opacity(0.6))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pet-growing-badge")
    }
}
