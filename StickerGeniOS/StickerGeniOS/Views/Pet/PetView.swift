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
    /// The talk popover is up: from the first tap on the mic until the words are sent or dropped.
    @State private var isTalking = false
    /// The encounter on show in its half-height sheet.
    @State private var presentedEncounter: PetEncounter?
    /// The last encounter opened by itself, so one the owner put off is not pushed on them again;
    /// the toolbar's "Needs You" button brings it back.
    @State private var autoPresentedEncounterID: String?
    /// The friend the pet made on its own, welcomed full screen with the rest of the tab put away.
    @State private var welcomedFriend: PetFriend?
    @State private var confirmingMedicine = false
    @State private var confirmingRelease = false
    @State private var healthStatusVisible = false
    @State private var lastHealthStatus: HealthStatus?
    @State private var healthStatusDismissalDate: Date?
    @State private var photoItem: PhotosPickerItem?
    /// The owner opened the app and the pet has not said hello yet.
    @State private var owesGreeting = true
    /// Whether the tab is on screen, so the pet only greets someone who can see it.
    @State private var isShown = false
    /// The bar runs down the side, as on an opened iPhone Duo, which leaves the room wide enough
    /// for the pet and everything else side by side, and the bar too narrow for the balance.
    @State private var hasVerticalToolbar = false
    /// An iPhone Duo opened all the way, the only time the pet and its stats sit in two columns.
    @State private var isFullyOpen = false
    /// Ties the pet, its weather and its stats across layouts, so opening or folding the phone
    /// slides each to its new place rather than redrawing the page.
    @Namespace private var layoutSpace
    /// The room's clock and weather board that show behind the tab, as the backdrop measured them.
    @State private var shownFixtures: PetRoomFixtures?
    /// Where the room's status board shows, in global points, as the backdrop measured it.
    @State private var statusFrame: CGRect?
    /// The one-screen page in portrait, in global points, to fit the pet above the status board.
    @State private var portraitFrame: CGRect?
    @State private var dialogueObstacles: [CGRect] = []
    @State private var dialogueSize = CGSize(width: 260, height: 72)
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    init(api: any StickerAPIClientProtocol) {
        _model = State(initialValue: PetModel(api: api))
    }

    var body: some View {
        content
            .background {
                // A place the pet has gone stands in for its room; it has its own sky.
                PetRoomBackdrop(image: model.pet == nil ? nil : model.themeArt ?? model.roomArt, weather: model.pet?.signals?.weather,
                                fixtures: model.pet == nil ? nil : roomFixtures,
                                stats: model.pet.map { PetRoomStats(happiness: $0.stats.happiness, hp: $0.stats.hp,
                                                                    maxHp: $0.maxHp, energy: $0.stats.energy) },
                                sky: model.themeArt == nil ? model.windowSky : nil, weatherArt: model.weatherArt,
                                onVisibleFixturesChange: { shownFixtures = $0 },
                                onStatusFrameChange: { statusFrame = $0 },
                                onDialogueObstaclesChange: { dialogueObstacles = $0 })
            }
            // The pet's agent takes it places on its own; whichever way the pet arrives, its place follows.
            .task(id: model.pet?.theme?.artKey) { await model.refreshThemeArt() }
            .safeAreaInset(edge: .top) {
                // The picker shows its own errors while it is up; this is for the tab's.
                if let errorMessage = model.errorMessage, !isPresentingSheet {
                    ErrorBanner(message: errorMessage).padding(.horizontal)
                }
            }
            .toolbar {
                if let pet = model.pet {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        if let encounter = pet.encounter {
                            Button {
                                Haptics.tap(.medium)
                                presentedEncounter = encounter
                            } label: {
                                Label("Needs You", systemImage: "exclamationmark.bubble.fill")
                            }
                            .tint(AppColors.coral)
                            .symbolEffect(.pulse, options: .repeating, value: encounter.id)
                            .accessibilityHint(Text("Your pet ran into something and needs you to decide"))
                            .accessibilityIdentifier("pet-encounter-button")
                        }
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
                                Image(systemName: "info.circle")
                            }
                        }
                        .accessibilityHint(Text("Shows who your pet is and what it knows of the world"))
                        .accessibilityIdentifier("pet-identity-button")
                    }
                    if pet.theme != nil {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                Haptics.tap(.medium)
                                Task { await model.goTo(nil) }
                            } label: {
                                Image("PetExitHome")
                                    .resizable()
                                    .renderingMode(.original)
                                    .scaledToFit()
                                    .frame(width: 36, height: 36)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(.rect)
                            }
                            .disabled(model.activity != nil || model.isAnswering)
                            .accessibilityLabel(Text("Bring Home"))
                            .accessibilityHint(Text("Brings your pet back from this place to its home"))
                            .accessibilityIdentifier("pet-bring-home-button")
                        }
                    }
                    // The balance and the pet's options share one glass pill. A vertical bar
                    // clips the balance, so there it sits beside the stats instead.
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 6) {
                            if !hasVerticalToolbar {
                                PetGoldBadge(gold: pet.stats.gold)
                            }
                            Menu {
                                Button {
                                    Haptics.tap(.light)
                                    showingPicker = true
                                } label: {
                                    Label("Change Pet", systemImage: "arrow.triangle.2.circlepath")
                                }
                                .accessibilityIdentifier("pet-option-change")
                                Button(role: .destructive) {
                                    Haptics.warning()
                                    confirmingRelease = true
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
                        .padding(.leading, hasVerticalToolbar ? 0 : 4)
                    }
                }
            }
            .detectsFoldableLayout(verticalToolbar: $hasVerticalToolbar, fullyOpen: $isFullyOpen)
            // The page rearranging as the phone opens or folds is felt as well as seen.
            .onChange(of: isTwoColumn) { _, _ in Haptics.tap(.soft) }
            .task {
                await model.loadPet()
                model.syncWorldInBackground()
                greetIfOwed()
                presentFriendIfOwed()
                presentEncounterIfOwed()
            }
            .onAppear {
                isShown = true
                greetIfOwed()
                presentFriendIfOwed()
                presentEncounterIfOwed()
            }
            // A new friend arrived — from its banner, a refresh, or the tab coming forward.
            .onChange(of: model.pet?.friend?.id) { _, _ in presentFriendIfOwed() }
            // A friend that arrived while a sheet or a change was up is welcomed once it is done.
            .onChange(of: isPresentingSheet || model.activity != nil) { _, busy in
                if !busy { presentFriendIfOwed() }
            }
            // A new encounter arrived — from its banner, a refresh, or the tab coming forward.
            .onChange(of: model.pet?.encounter?.id) { _, _ in presentEncounterIfOwed() }
            .onDisappear {
                isShown = false
                healthStatusVisible = false
            }
            // Health changes get thirty seconds; tab visits and routine refreshes keep the deadline.
            .task(id: healthStatus) { await showHealthStatusIfNeeded() }
            // A walk paid out by an upload the app made coming forward: the pet thanks its owner
            // for it while they are looking. Off screen, the next greeting picks it up.
            .onChange(of: model.context.pendingWalk) { _, walk in
                guard walk != nil, isShown, scenePhase == .active else { return }
                Task { await model.reactToWalk() }
            }
            // Back from a "your pet grew" banner, or anything else that changed it while away.
            // Coming back from the background, the pet says hello once it is current.
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background:
                    model.ownerLeft()
                    owesGreeting = true
                case .active where model.hasLoadedPet:
                    Task {
                        await model.loadPet()
                        greetIfOwed()
                    }
                default:
                    break
                }
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
            // The weather — and the sky outside the room's window — is drawn in the pet's style after the
            // pet is read; look again until it lands. The window's sheet takes the longer of the two.
            .task(id: model.isWeatherArtPending) {
                guard model.isWeatherArtPending else { return }
                for _ in 0..<8 {
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
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingDiary) {
                PetDiarySheet(api: model.api, maxHp: model.pet?.maxHp ?? 100)
            }
            .sheet(isPresented: $showingIdentity) {
                PetIdentitySheet(model: model)
            }
            .fullScreenCover(item: $welcomedFriend) { friend in
                PetFriendWelcomeView(
                    friend: friend,
                    petTitle: model.pet?.sticker.title ?? String(localized: "Your Pet"),
                    onDone: {
                        welcomedFriend = nil
                        Task {
                            await model.finishWelcoming(friend)
                            presentEncounterIfOwed()
                        }
                    },
                    petArt: { welcomePetArt },
                    friendArt: { StickerThumbnail(sticker: friend.sticker, api: model.api, detail: .preview) }
                )
            }
            .sheet(item: $presentedEncounter) { encounter in
                PetEncounterSheet(model: model, encounter: encounter)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .confirmationDialog(
                "Give Medicine?", isPresented: $confirmingMedicine, titleVisibility: .visible,
                presenting: model.pet?.illness
            ) { _ in
                Button("Give Medicine") {
                    Haptics.tap(.medium)
                    Task { await model.giveMedicine() }
                }
                Button("Cancel", role: .cancel) { Haptics.tap(.light) }
            } message: { illness in
                Text("Cures \(illness.name). Your pet has \(model.pet?.medicine ?? 0) medicine.")
            }
            .confirmationDialog(
                "Release \(model.pet?.sticker.title ?? String(localized: "Your Pet"))?",
                isPresented: $confirmingRelease, titleVisibility: .visible
            ) {
                Button("Release Pet", role: .destructive) {
                    Haptics.tap(.heavy)
                    Task { await model.release() }
                }
                .accessibilityIdentifier("pet-release-confirm")
                Button("Cancel", role: .cancel) { Haptics.tap(.light) }
            } message: {
                Text("Its stats, items and medicine are gone for good. Your gold stays with you.")
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

    /// Has the pet greet its owner once per visit, when the tab is up and the pet is loaded. Waits a
    /// beat so the pet is on screen to hop rather than mid-fade.
    private func greetIfOwed() {
        guard owesGreeting, isShown, scenePhase == .active, model.pet != nil else { return }
        owesGreeting = false
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            model.greetOwner()
        }
    }

    /// The pet as the welcome shows it: the pose it holds now, or its sticker until it has one.
    @ViewBuilder
    private var welcomePetArt: some View {
        if let pose = model.pose {
            Image(uiImage: pose).resizable().interpolation(.high).scaledToFit()
        } else if let pet = model.pet {
            StickerThumbnail(sticker: pet.sticker, api: model.api, detail: .preview)
        }
    }

    /// Welcomes the pet's new friend full screen once, when the tab is up and no sheet or change is
    /// in the way. It covers the pet's hello rather than waiting on it, and comes before the day's
    /// encounter, which waits until the welcome is closed.
    private func presentFriendIfOwed() {
        guard let friend = model.pet?.friend, welcomedFriend == nil, isShown, scenePhase == .active else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard model.pet?.friend?.id == friend.id, welcomedFriend == nil, isShown, scenePhase == .active,
                  !isPresentingSheet, model.activity == nil else { return }
            welcomedFriend = friend
        }
    }

    /// Opens today's encounter at half height once per encounter, when the tab is up and nothing
    /// else is in the way. Waits a beat so the pet's hello lands first.
    private func presentEncounterIfOwed() {
        guard let encounter = model.pet?.encounter, encounter.id != autoPresentedEncounterID,
              isShown, scenePhase == .active else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard model.pet?.encounter?.id == encounter.id, encounter.id != autoPresentedEncounterID,
                  isShown, scenePhase == .active, !isPresentingSheet, model.pet?.friend == nil,
                  model.activity == nil, !model.isAnswering else { return }
            autoPresentedEncounterID = encounter.id
            Haptics.warning()
            presentedEncounter = encounter
        }
    }

    /// The pet and its stats sit side by side only on an iPhone Duo opened all the way.
    private var isTwoColumn: Bool { hasVerticalToolbar && isFullyOpen }

    /// A phone on its side: too short to stack the page, so it splits into three columns.
    private var isLandscape: Bool { !isTwoColumn && verticalSizeClass == .compact }

    /// The width of each side column in landscape, beside the centred pet.
    private static let landscapeSideWidth: CGFloat = 240

    /// The parts of the page that slide between layouts as the phone opens and folds.
    private enum LayoutPiece { case pet, weather, stats, actions }

    /// A sheet shows its own errors and progress; the tab's would sit behind it, unseen.
    private var isPresentingSheet: Bool {
        showingPicker || showingActions || showingDiary || showingIdentity || isTalking || presentedEncounter != nil
            || welcomedFriend != nil
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasLoadedPet {
            PosterProgress(message: String(localized: "Finding your pet…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let pet = model.pet {
            let motion = PetMotionProfile(pet: pet)
            ScrollView {
                Group {
                    // An iPhone Duo opened all the way is wide enough for two columns: the pet on
                    // the left with its dialogue box just above it, and its weather, balance and
                    // stats and actions on the right.
                    if isTwoColumn {
                        HStack(alignment: .center, spacing: 24) {
                            petStage(pet, motion: motion)
                                .matchedGeometryEffect(id: LayoutPiece.pet, in: layoutSpace)
                                .frame(maxWidth: .infinity)
                            VStack(spacing: 20) {
                                HStack(alignment: .center) {
                                    weatherRow(pet)
                                        .matchedGeometryEffect(id: LayoutPiece.weather, in: layoutSpace)
                                    Spacer(minLength: 0)
                                    // Leaves the toolbar for here as the phone opens.
                                    PetGoldBadge(gold: pet.stats.gold)
                                        .transition(.scale(scale: 0.6, anchor: .trailing).combined(with: .opacity))
                                }
                                statsCard(pet)
                                    .matchedGeometryEffect(id: LayoutPiece.stats, in: layoutSpace)
                                actionButtons
                                    .matchedGeometryEffect(id: LayoutPiece.actions, in: layoutSpace)
                            }
                            .frame(maxWidth: 420)
                        }
                        .padding()
                        .containerRelativeFrame(.vertical)
                    } else if verticalSizeClass == .compact {
                        // Landscape leaves too little height to stack everything, so the page splits
                        // into three columns that fit on one screen: the weather and actions on the
                        // leading side, the pet centred in the room, and its stats on the trailing
                        // side. Both side columns share one width, so the pet stays in the middle.
                        HStack(alignment: .center, spacing: 20) {
                            VStack(alignment: .leading, spacing: 12) {
                                weatherRow(pet, stacked: true)
                                    .matchedGeometryEffect(id: LayoutPiece.weather, in: layoutSpace)
                                Spacer(minLength: 0)
                                actionButtons
                                    .matchedGeometryEffect(id: LayoutPiece.actions, in: layoutSpace)
                            }
                            .frame(maxWidth: Self.landscapeSideWidth, maxHeight: .infinity, alignment: .topLeading)
                            petStage(pet, motion: motion)
                                .matchedGeometryEffect(id: LayoutPiece.pet, in: layoutSpace)
                                .frame(maxWidth: .infinity)
                            statsCard(pet)
                                .matchedGeometryEffect(id: LayoutPiece.stats, in: layoutSpace)
                                .frame(maxWidth: Self.landscapeSideWidth, maxHeight: .infinity, alignment: .top)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        // Exactly one screen tall, so nothing has to be scrolled into view.
                        .containerRelativeFrame(.vertical)
                    } else {
                        // A room or place with a status board shows the stats on it, so the pet
                        // stands above the board, in the space the card took, rather than on it.
                        let boardSpace = statusBoardSpace
                        VStack(spacing: 20) {
                            weatherRow(pet)
                                .matchedGeometryEffect(id: LayoutPiece.weather, in: layoutSpace)
                            if boardSpace != nil, hasHealthRow(pet) {
                                PosterCard(padding: 16) { healthRow(pet) }
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                            petStage(pet, motion: motion)
                                .matchedGeometryEffect(id: LayoutPiece.pet, in: layoutSpace)
                            if let boardSpace {
                                Color.clear
                                    .frame(height: boardSpace)
                                    .matchedGeometryEffect(id: LayoutPiece.stats, in: layoutSpace)
                            } else {
                                statsCard(pet)
                                    .matchedGeometryEffect(id: LayoutPiece.stats, in: layoutSpace)
                                    .transition(.opacity)
                            }
                        }
                        .padding()
                        .animation(.snappy(duration: 0.35), value: boardSpace == nil)
                        // Exactly one screen tall, so the pet grows into the room left over.
                        .containerRelativeFrame(.vertical)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { portraitFrame = $0 }
                    }
                }
                .animation(.snappy(duration: 0.4), value: pet.signals?.weather)
            }
            .scrollDisabled(true)
            // The actions stay put at the bottom, above the tab bar, unless they sit in a
            // column beside the pet.
            .safeAreaInset(edge: .bottom) {
                if !isTwoColumn && !isLandscape {
                    actionButtons
                        .matchedGeometryEffect(id: LayoutPiece.actions, in: layoutSpace)
                        .padding(.horizontal)
                        .padding(.bottom, 12)
                }
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

    /// In landscape the actions share a narrow column, so the picture and talk buttons drop
    /// below the main action instead of sitting beside it.
    private var actionButtons: some View {
        let layout = isLandscape
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            // Talking takes the whole row: Cancel and a full-width Send.
            if !isTalking {
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
                .transition(.opacity)
            }

            HStack(spacing: 12) {
                // Icon only, so it fits beside the main action without truncating either.
                if !isTalking {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Image(systemName: "photo.on.rectangle")
                            .frame(maxWidth: isLandscape ? .infinity : nil)
                    }
                    .buttonStyle(.posterSecondary)
                    .disabled(model.isAnswering || model.activity != nil)
                    .accessibilityLabel(Text("Show a Picture"))
                    .accessibilityIdentifier("pet-photo-button")
                    .transition(.opacity)
                }

                // Talking out loud: written down on the phone, answered by the pet on the tab. The
                // popover hangs above the mic; the same button stops listening and sends.
                PetTalkButton(model: model, isTalking: $isTalking, fillsWidth: isLandscape)
                    .zIndex(1)
            }
        }
        .animation(.snappy(duration: 0.25), value: isTalking)
    }

    /// The clock, weather board and status board drawn into the room or place on screen.
    private var roomFixtures: PetRoomFixtures? { model.roomFixtures }

    /// How much of the bottom of the portrait page the room's status board takes, from just above
    /// its top edge down; nil when there is no board in view, or it sits where the pet would have
    /// too little room above it or the actions would cover it, so the stats card shows instead.
    private var statusBoardSpace: CGFloat? {
        guard roomFixtures?.status != nil, let board = statusFrame, let page = portraitFrame else { return nil }
        // The page's padding and the stack's spacing above the space, and a gap over the board.
        let inner = page.insetBy(dx: 16, dy: 16)
        let space = inner.maxY - board.minY + 8 - 20
        guard board.minY >= inner.minY + inner.height * 0.4, board.minY < inner.maxY else { return nil }
        return max(0, space)
    }

    /// Those of them that show on screen; the tab keeps whichever is missing or cropped off
    /// in its own chips.
    private var visibleRoomFixtures: PetRoomFixtures? { roomFixtures == nil ? nil : shownFixtures }

    @ViewBuilder
    /// `stacked` puts the chips under the weather sticker, for a narrow column.
    private func weatherRow(_ pet: Pet, stacked: Bool = false) -> some View {
        // The weather where you are, drawn in the pet's style, sits above the dialogue
        // box with its temperature and the time beside it, clear of the pet and the picture
        // it is shown. A room with a clock and weather board drawn in shows them there instead.
        let fixtures = visibleRoomFixtures
        let showsTime = fixtures?.clock == nil
        if let weather = pet.signals?.weather, fixtures?.weather == nil {
            let layout = stacked
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                PetWeatherSticker(weather: weather, art: model.weatherArt)
                    .frame(width: 72, height: 72)
                HStack(spacing: 8) {
                    PetWeatherChip(weather: weather)
                    if showsTime {
                        PetClockChip()
                            .transition(.opacity)
                    }
                }
                .fixedSize()
                if !stacked { Spacer(minLength: 0) }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
        } else if showsTime {
            HStack {
                PetClockChip()
                Spacer(minLength: 0)
            }
            .transition(.opacity)
        }
    }

    /// Choose the clearer side of the pet, leaving the room's window and boards visible.
    private func petStage(_ pet: Pet, motion: PetMotionProfile) -> some View {
        GeometryReader { proxy in
            let placement = PetDialoguePlacement.preferred(
                in: proxy.frame(in: .global),
                bubbleSize: CGSize(width: min(dialogueSize.width, proxy.size.width), height: dialogueSize.height),
                avoiding: dialogueObstacles
            )
            PetDialogueLayout(placement: placement) {
                PetCurrentPose(model: model, pet: pet)
                    .aspectRatio(1, contentMode: .fit)
                    // As big as the page allows, but narrow enough that a picture held up
                    // at its side still fits on screen.
                    .frame(maxWidth: 260)
                    // Breathes and sways while nothing else is going on, so a still pose
                    // still reads as alive: bouncy when happy, slow and slumped when tired.
                    .modifier(PetIdleMotion(profile: motion))
                    // The picture the pet was just shown, held up at its side, clear of the
                    // dialogue box. It starts a gap past the sticker's trailing edge,
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
                // a hop, so the change reads as the pet moving. Shaking the phone rattles it too. With Apple Intelligence the pet
                // also says something back, and may play its animation, thought of on the phone.
                .modifier(PetTouchReactions(
                    profile: motion,
                    replayKey: model.touchPose?.key ?? model.poseKey,
                    greetKey: model.greetCount,
                    onTouch: {
                        // Touching the pet is a new interaction, so the picture is put away.
                        if !model.isAnswering { model.dismissPhoto() }
                    },
                    onReaction: { model.touched($0) },
                    acceptsShakes: isShown && scenePhase == .active && !isPresentingSheet
                        && !confirmingMedicine && model.activity == nil
                ))
                .modifier(PetItemPresentation(
                    item: model.usedItem, isVisible: !showingActions && isShown && scenePhase == .active
                ))
                // The pet growing something new in the background is a badge pinned to it,
                // so the dialogue box keeps to what the pet says.
                .overlay(alignment: .topLeading) {
                    if pet.evolution?.isGrowing == true {
                        PetGrowingBadge()
                            .transition(.scale(scale: 0.6, anchor: .topLeading).combined(with: .opacity))
                    }
                }
                .animation(.snappy(duration: 0.3), value: pet.evolution?.isGrowing)

                Group {
                    if model.isAnswering {
                        // The pet's first reaction, thought of on the phone, stands in
                        // for the thinking line while its agent answers.
                        PetThinkingBubble(reaction: model.brain.localLine?.text, placement: placement)
                    } else {
                        // Between moods it moves on to each
                        // line its agent queued, at the pause the agent chose.
                        // A touch the on-device model answered shows its reply for a while.
                        TimelineView(.explicit(pet.status?.captionDates ?? [.now])) { context in
                            PetSpeechBubble(
                                text: model.brain.localLine?.text
                                    ?? pet.status?.caption(at: context.date)
                                    ?? String(localized: "I'm here with you. What shall we do?"),
                                placement: placement
                            )
                        }
                    }
                }
                .accessibilityIdentifier("pet-dialogue")
                .onGeometryChange(for: CGSize.self) { $0.size } action: { dialogueSize = $0 }
                // Drawn over the sticker's transparent margin on either side.
                .zIndex(1)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .animation(.snappy(duration: 0.3), value: placement)
            .onChange(of: placement) { _, _ in Haptics.tap(.soft) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statsCard(_ pet: Pet) -> some View {
        PosterCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
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
                // Kept apart from the combined stats, so its button stays reachable.
                if hasHealthRow(pet) {
                    healthRow(pet)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.snappy(duration: 0.3), value: pet.illness)
        }
    }

    private struct HealthStatus: Equatable {
        let stickerID: String
        let illness: PetIllness?
        let medicine: Int
    }

    private var healthStatus: HealthStatus? {
        guard let pet = model.pet, pet.illness != nil || pet.medicine > 0 else { return nil }
        // selectedAt is the server row's updatedAt, so context updates must not replay this card.
        return HealthStatus(stickerID: pet.sticker.id, illness: pet.illness, medicine: pet.medicine)
    }

    private func showHealthStatusIfNeeded() async {
        if healthStatus != lastHealthStatus {
            lastHealthStatus = healthStatus
            healthStatusDismissalDate = healthStatus == nil ? nil : Date.now.addingTimeInterval(30)
        }
        let remaining = healthStatusDismissalDate?.timeIntervalSinceNow ?? 0
        setHealthStatusVisible(remaining > 0)
        guard remaining > 0 else { return }
        do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
        withAnimation(.snappy(duration: 0.3)) { setHealthStatusVisible(false) }
    }

    private func setHealthStatusVisible(_ visible: Bool) {
        guard healthStatusVisible != visible else { return }
        healthStatusVisible = visible
        if isShown, !isPresentingSheet { Haptics.tap(.soft) }
    }

    private func hasHealthRow(_ pet: Pet) -> Bool {
        healthStatusVisible && (pet.illness != nil || pet.medicine > 0)
    }

    /// The pet's illness and medicine, with the button to give it a dose.
    private func healthRow(_ pet: Pet) -> some View {
        PetHealthRow(
            illness: pet.illness, medicine: pet.medicine,
            isBusy: model.activity != nil || model.isAnswering
        ) { confirmingMedicine = true }
    }
}

/// The pet's latest line, with its tail pointing toward the sticker.
private struct PetSpeechBubble: View {
    let text: String
    var placement: PetDialoguePlacement = .below

    var body: some View {
        VStack(spacing: -2) {
            if placement == .below { tail.rotationEffect(.degrees(180)) }
            Text(text)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(AppColors.ink)
                .multilineTextAlignment(.leading)
                // Hugs the line rather than spanning the screen; long lines still wrap.
                .fixedSize(horizontal: false, vertical: true)
                // A line the pet moves on to by itself fades in over the last.
                .contentTransition(.opacity)
                .animation(.snappy(duration: 0.4), value: text)
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
            if placement == .above { tail }
        }
        .accessibilityElement(children: .combine)
    }

    private var tail: some View {
        BubbleTail()
            .fill(AppColors.card)
            .overlay { BubbleTail().stroke(AppColors.ink, style: StrokeStyle(lineWidth: 3, lineJoin: .round)) }
            .frame(width: 18, height: 12)
            .accessibilityHidden(true)
    }
}

/// Stands in for the pet's reply while it is on its way: the reaction the on-device model wrote,
/// or a predefined line until it has one or without the model.
private struct PetThinkingBubble: View {
    var reaction: String?
    var placement: PetDialoguePlacement = .below

    private static let lines: [LocalizedStringResource] = [
        "Hmm, let me think…",
        "Ooh, give me a second…",
        "Thinking about it…"
    ]

    @State private var line = PetThinkingBubble.lines.randomElement()!

    var body: some View {
        PetSpeechBubble(text: reaction ?? String(localized: line), placement: placement)
            .accessibilityLabel(Text(reaction ?? String(localized: line)))
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
                    case .deciding: Text("Seeing how it turns out…")
                    case .givingMedicine: Text("Giving your pet its medicine…")
                    case .buyingMedicine: Text("Buying medicine…")
                    case .buyingItem(let title): Text("Buying \(title)…")
                    case .buyingRoom(let title): Text("Moving into \(title)…")
                    case .movingRoom: Text("Moving your pet…")
                    case .goingTo(let title): Text("Heading to \(title)…")
                    case .comingHome: Text("Bringing your pet home…")
                    case .settingTracking(let on): Text(on ? "Turning on Location Tracking…" : "Turning off Location Tracking…")
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

/// Pinned to the pet while it grows a new mood or look in the background, in the same badge as
/// the weather and the time. Tapping it nudges the pet's sparkle, so the wait is felt.
private struct PetGrowingBadge: View {
    @State private var nudges = 0

    var body: some View {
        Button {
            nudges += 1
            Haptics.tap(.light)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.orange)
                    .symbolEffect(.pulse, options: .repeating)
                    .symbolEffect(.bounce, value: nudges)
                Text("Growing…")
            }
            .font(.system(size: 13, weight: .heavy, design: .monospaced))
            .foregroundStyle(AppColors.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(AppColors.card, in: .capsule)
            .overlay { Capsule().strokeBorder(AppColors.ink, lineWidth: 2) }
            .fixedSize()
        }
        .buttonStyle(.plain)
        .onAppear { Haptics.tap(.soft) }
        .accessibilityLabel(Text("Growing something new"))
        .accessibilityIdentifier("pet-growing-badge")
    }
}
