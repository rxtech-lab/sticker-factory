import AnimatedView
import Observation
import os
import SwiftUI
import UIKit

/// The account's pet, and the controllable stickers it can be swapped for.
///
/// One model is shared by the Pet tab and the picker sheet it opens, so adopting a pet in the sheet
/// updates the tab behind it without a second fetch.
@MainActor
@Observable
final class PetModel {
    /// What the overlay says while a change is on its way to the server.
    enum Activity: Equatable {
        case adopting(String)
        case releasing
        /// Reading steps and location after the user connected them, and telling the server.
        case connectingWorld
        /// Looking for the phone's location again, and the weather there.
        case findingWeather
        /// Telling the server which way the owner decided the pet's encounter.
        case deciding
        /// Giving the ill pet its medicine.
        case givingMedicine
        /// Buying a dose of medicine from the item shop.
        case buyingMedicine
        /// Buying food or a ticket from the item shop into the bag.
        case buyingItem(String)
        /// Buying a room from the shop and moving the pet in.
        case buyingRoom(String)
        /// Moving the pet into another room it has, or back onto the plain page.
        case movingRoom
        /// Taking the pet to one of its places.
        case goingTo(String)
        /// Bringing the pet home from a place.
        case comingHome
        /// Turning Location Tracking on or off, and telling the server.
        case settingTracking(Bool)
    }

    private(set) var pet: Pet?
    private(set) var hasLoadedPet = false
    private(set) var sections: [LibrarySection] = []
    private(set) var isLoadingCandidates = false
    private(set) var activity: Activity?
    /// The action the pet is answering. Unlike `activity` it does not block the screen: the pet's
    /// dialogue box shows a thinking line until the reply lands.
    private(set) var pendingAction: PetAction?
    /// The item being used, kept on the pet view through its reply and briefly afterward.
    struct UsedItem: Identifiable {
        let id = UUID()
        let title: String
        var image: UIImage?
    }
    private(set) var usedItem: UsedItem?
    /// The picture the pet was last shown, held up beside it until the next interaction or until
    /// `photoLifetime` after the pet has reacted to it.
    private(set) var shownPhoto: UIImage?
    /// True while the pet is looking at `shownPhoto`. Like `pendingAction`, it does not block the screen.
    private(set) var isLookingAtPhoto = false
    /// True while the pet thinks of what to say back to its owner's words. Like `pendingAction`, it
    /// does not block the screen.
    private(set) var isHearingOwner = false
    /// The server's drawing of the pet in the pose it holds now, so an interaction shows on its body
    /// and not only in its words. Nil until the pet has been posed; the sticker stands in until then.
    private(set) var pose: UIImage?
    /// Names exactly what `pose` shows. Changes when the pet strikes a new pose, to replay its hop.
    private(set) var poseKey: String?
    /// The server's drawing of the weather the pet is in, in the pet's own style. Nil while there is
    /// no weather or it is still being drawn; the weather's symbol stands in until then.
    private(set) var weatherArt: UIImage?
    /// Names exactly what `weatherArt` shows: `PetWeatherArt.key`.
    private(set) var weatherArtKey: String?
    /// The pet's sticker in the pose it holds now, ready to play through. Nil until it has loaded,
    /// and for a sticker with nothing that moves; the still pose stands in between plays either way.
    private(set) var animation: PetAnimation?
    /// The owner's rooms and the room shop. Nil until the Rooms tab has loaded them.
    private(set) var rooms: PetRooms?
    /// The drawing of the room the pet lives in, filling the tab behind it. Nil on the plain page,
    /// and until it has loaded.
    private(set) var roomArt: UIImage?
    /// Names exactly what `roomArt` shows: `PetRoomRef.artKey`.
    private(set) var roomArtKey: String?
    /// The places the pet knows. Nil until the Places tab has loaded them.
    private(set) var themes: PetThemes?
    /// The drawing of the place the pet has gone, filling the tab behind it in place of its room.
    /// Nil while it is at home, and until it has loaded.
    private(set) var themeArt: UIImage?
    /// Names exactly what `themeArt` shows: `PetThemeRef.artKey`.
    private(set) var themeArtKey: String?
    /// The sky outside the room's window, drawn in the pet's style as pieces the tab animates. Nil on
    /// the plain page and until it is drawn; the painted sky stands in until then.
    private(set) var windowSky: PetWindowSprites?
    /// Names exactly what `windowSky` shows: `Pet.windowWeatherArt.key`.
    private(set) var windowSkyKey: String?
    /// Where the room or place on screen shows the time, weather and stats. Nil on the plain page,
    /// while its drawing loads, and in drawings made without them, so the tab keeps them in its own
    /// chips and card then.
    var roomFixtures: PetRoomFixtures? {
        if themeArt != nil {
            guard let theme = pet?.theme, theme.artKey == themeArtKey else { return nil }
            return theme.fixtures
        }
        guard roomArt != nil, let room = pet?.room, room.artKey == roomArtKey else { return nil }
        return room.fixtures
    }
    var errorMessage: String?

    let api: any StickerAPIClientProtocol
    /// Steps and location, for the pet's birth world and its "World" row. Shared across the app.
    let context: PetContextProvider

    /// Invalidates a candidate response still in flight when the query changes.
    @ObservationIgnored private var generation = 0
    /// The pet `pose` was drawn for.
    @ObservationIgnored private var poseStickerID: String?
    private static let log = Logger(subsystem: "app.rxlab.sticker-factory", category: "pet")
    /// The pet's playback document, kept across poses: a new pose resolves the same document again.
    @ObservationIgnored private var playback: (key: String, document: AnimatedDocument)?
    /// The pose `animation` is being loaded for, so a second refresh for it does not load it twice.
    @ObservationIgnored private var loadingAnimationKey: String?
    /// The artwork every pose of the pet draws from. Shared, so a new pose only fetches what is new.
    @ObservationIgnored private let animationAssets = StickerAssetStore()
    /// Puts the shown picture away once it has been up for `photoLifetime`.
    @ObservationIgnored private var photoExpiry: Task<Void, Never>?
    @ObservationIgnored private var itemExpiry: Task<Void, Never>?
    /// How long the picture stays up after the pet's reaction lands.
    static let photoLifetime: Duration = .seconds(20)
    /// Edge of the pose drawing, in pixels: the tab shows the pet at 176 points, so about 3x.
    static let poseSize = 512
    /// Edge of the weather drawing, in pixels: the tab shows it at about 120 points.
    static let weatherArtSize = 384
    /// Edge of the window sky's sheet, in pixels: four pieces, each shown at up to about 160 points.
    static let windowSkySize = 1024

    /// Decides what the pet says and does: its agent on the server, and the on-device model.
    let brain: PetBrain

    /// How long the pet holds still between plays of its animation, as its agent chose with the pose.
    var animationInterval: Duration { brain.animationInterval(for: pet) }

    init(api: any StickerAPIClientProtocol, context: PetContextProvider = .shared) {
        self.api = api
        self.context = context
        brain = PetBrain(api: api)
    }

    /// Lets the pet answer a touch with a few words of its own, thought of on the phone.
    func touched(_ touch: PetTouch) {
        guard let pet, activity == nil, !isAnswering else { return }
        brain.react(to: touch, pet: pet)
    }

    /// Counts the times the pet greeted its owner; the pet hops hello each time it changes.
    private(set) var greetCount = 0
    /// When the owner last had the pet in front of them, kept across launches.
    static let lastSeenKey = "pet.lastSeenAt"

    /// Remembers that the owner is leaving, so the next greeting knows how long they were away.
    func ownerLeft() {
        UserDefaults.standard.set(Date.now, forKey: Self.lastSeenKey)
    }

    /// Has the pet react to its owner opening the app: a hop hello, and a few words when it needs
    /// something or they were gone a while.
    func greetOwner() {
        guard let pet, activity == nil, !isAnswering else { return }
        let lastSeen = UserDefaults.standard.object(forKey: Self.lastSeenKey) as? Date
        // Stamped now too, so an app killed without going to the background still counts as a visit.
        ownerLeft()
        // Back from a walk, the pet's thanks for it is the hello.
        if context.pendingWalk != nil {
            Task { await reactToWalk() }
            return
        }
        greetCount &+= 1
        brain.greet(pet, awayFor: lastSeen.map { Date.now.timeIntervalSince($0) })
    }

    /// Has the pet thank its owner for the walk the last context upload paid out, once: reloads it
    /// so the energy it got back shows, then hops and says so — on the phone, without waiting on its
    /// agent. Waits while the pet is busy; the next chance picks the walk up.
    func reactToWalk() async {
        guard pet != nil, activity == nil, !isAnswering, let walk = context.takePendingWalk() else { return }
        await loadPet()
        guard let pet else { return }
        greetCount &+= 1
        Haptics.success()
        brain.thank(forWalk: walk, pet: pet)
    }

    /// Every candidate, in section order, without the empty "My Stickers" a pack-only user gets.
    var candidateSections: [LibrarySection] { sections.filter { !$0.stickers.isEmpty } }

    func loadPet() async {
        do {
            let wasGrowing = pet?.evolution?.isGrowing == true
            pet = try await api.pet()
            // The new look arrived while the tab was open: the banner is swallowed, so feel it.
            if wasGrowing, pet?.evolution?.state == .ready { Haptics.success() }
            hasLoadedPet = true
            if pet != nil { brain.prepare() }
            // The pet is here and current, so whatever failed before no longer describes it.
            errorMessage = nil
            publishToCompanions()
            Task { await refreshPose() }
            Task { await refreshWeatherArt() }
            Task { await refreshRoomArt() }
            Task { await refreshThemeArt() }
            Task { await refreshWindowSky() }
        } catch {
            guard !StickerStore.isCancellation(error) else { return }
            hasLoadedPet = true
            errorMessage = error.localizedDescription
        }
    }

    /// Loads the candidates for `rawQuery`, debounced so typing does not fire a request per keystroke.
    func loadCandidates(query rawQuery: String, debounce: Duration = .milliseconds(300)) async {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        generation &+= 1
        let generation = self.generation
        isLoadingCandidates = true
        defer { if generation == self.generation { isLoadingCandidates = false } }
        do {
            if debounce > .zero { try await Task.sleep(for: debounce) }
            let response = try await api.petCandidates(query: query.isEmpty ? nil : query)
            guard generation == self.generation else { return }
            sections = response.sections
            errorMessage = nil
        } catch {
            guard generation == self.generation, !StickerStore.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Adopts `sticker`. Returns whether it worked, so the sheet knows whether to close.
    func adopt(_ sticker: Sticker) async -> Bool {
        guard activity == nil else { return false }
        guard sticker.id != pet?.sticker.id else { return true }
        activity = .adopting(sticker.title)
        defer { activity = nil }
        do {
            // The world the pet is born into. What is cached when it is fresh; otherwise a quick
            // read that gives up on a slow location fix rather than holding the overlay up.
            let birthWorld = await context.quickContext()
            pet = try await api.setPet(stickerID: sticker.id, context: birthWorld)
            brain.forgetLocalLine()
            dismissPhoto()
            dismissItem()
            errorMessage = nil
            publishToCompanions()
            await refreshPose()
            await refreshWeatherArt()
            Haptics.success()
            return true
        } catch {
            errorMessage = error.localizedDescription
            Haptics.failure()
            return false
        }
    }

    /// Tells the server about the owner's world in the background after the tab loads. Silent: no
    /// overlay, and nothing at all within half an hour of the last upload unless the owner has
    /// walked since — then the walk gives the pet energy back and it thanks them for it.
    func syncWorldInBackground() {
        let api = api, context = context
        Task {
            await context.refreshPermissions()
            await context.syncIfNeeded(api: api)
            await reactToWalk()
        }
    }

    /// Which source `PetWorldSheet` is connecting.
    enum WorldSource { case health, location }

    /// Asks for `source` — the only place either permission is requested — then reads everything
    /// allowed, uploads it at once and reloads the pet. Returns whether the upload was kept.
    @discardableResult
    func connect(_ source: WorldSource) async -> Bool {
        guard activity == nil else { return false }
        switch source {
        case .health: await context.requestHealthAccess()
        case .location: await context.requestLocationAccess()
        }
        activity = .connectingWorld
        defer { activity = nil }
        let stored = await context.syncIfNeeded(api: api, force: true)
        if let refreshed = try? await api.pet() {
            pet = refreshed
            await refreshPose()
            await refreshWeatherArt()
        }
        if stored {
            errorMessage = nil
            Haptics.success()
            // Steps already walked today give the pet energy back as soon as Health is connected;
            // its thanks waits until the overlay is down.
            Task { await reactToWalk() }
        } else {
            Haptics.failure()
        }
        return stored
    }

    /// Turns Location Tracking on or off, covering the screen while the server hears. Off has the
    /// server forget where the owner was; on offers "Always" so trips are noticed in the background.
    func setLocationTracking(_ enabled: Bool) async {
        guard activity == nil else { return }
        activity = .settingTracking(enabled)
        defer { activity = nil }
        let stored = await context.setLocationTracking(enabled, api: api)
        if let refreshed = try? await api.pet() { pet = refreshed }
        if stored || pet == nil {
            errorMessage = nil
            Haptics.success()
        } else {
            Haptics.failure()
        }
    }

    /// Whether location is allowed but the pet still has no weather: the phone could not find where
    /// it is in time, or the server has not looked the weather up yet.
    var isWeatherMissing: Bool { context.hasLocationAccess && pet != nil && pet?.signals?.weather == nil }

    /// Why the last weather retry found nothing, for the sheet's alert. Nil when it worked.
    var weatherProblem: String?

    /// Looks for the phone's location again and hands it over, then waits for the server to look up
    /// the weather there. Covers the screen while it works and says what went wrong if it could not.
    func retryWeather() async {
        guard activity == nil else { return }
        activity = .findingWeather
        defer { activity = nil }
        let result = await context.upload(api: api)
        guard result.hasLocation else {
            weatherProblem = String(
                localized: "Your phone couldn't find where you are. Check that Location Services is on, then try again."
            )
            Haptics.failure()
            return
        }
        guard result.stored else {
            weatherProblem = String(localized: "Your pet couldn't be reached. Check your connection, then try again.")
            Haptics.failure()
            return
        }
        // The server looks the weather up just after it answers; give it a few moments.
        for _ in 0..<5 {
            try? await Task.sleep(for: .seconds(2))
            guard let refreshed = try? await api.pet() else { continue }
            pet = refreshed
            if refreshed.signals?.weather != nil { break }
        }
        await refreshWeatherArt()
        publishToCompanions()
        if pet?.signals?.weather != nil {
            weatherProblem = nil
            Haptics.success()
        } else {
            weatherProblem = String(localized: "The weather where you are couldn't be looked up just now. Try again in a little while.")
            Haptics.failure()
        }
    }

    /// Hands the pet to the widget and the watch. Not awaited: drawing the pose is their business,
    /// and the tab has already shown the user what changed.
    private func publishToCompanions() {
        let pet = pet
        Task { await PetCompanionSync.shared.publish(pet) }
    }

    /// Fetches the drawing of the pet's current pose when it changed. A pet never posed keeps its
    /// sticker; a failed fetch keeps the last pose, since a pet that missed one still looks like itself.
    private func refreshPose() async {
        // The moving pose loads alongside; the still one is what the tab waits on.
        Task { await refreshAnimation() }
        guard let pet, pet.status != nil else {
            pose = nil
            poseKey = nil
            return
        }
        let key = PetSnapshot(pet: pet).poseKey
        guard key != poseKey || pose == nil else { return }
        do {
            let data = try await api.petPose(size: Self.poseSize)
            // Another pose replaced this one while it was drawn; that one's fetch will land it.
            guard let current = self.pet, PetSnapshot(pet: current).poseKey == key,
                  let image = UIImage(data: data) else { return }
            pose = image
            poseKey = key
            poseStickerID = current.sticker.id
        } catch {
            guard !StickerStore.isCancellation(error) else { return }
            // Another pet's pose must not stand in for this one.
            if self.pet?.sticker.id != poseStickerID {
                pose = nil
                poseKey = nil
            }
        }
    }

    /// Loads the pet's sticker in its current pose when the pose changed, with every bitmap it draws.
    /// A failed load keeps the last one when it is still this pet's: it moves in an older pose rather
    /// than not at all. Another pet's never stands in.
    private func refreshAnimation() async {
        guard let pet, let revisionID = pet.sticker.playbackRevisionId else {
            animation = nil
            return
        }
        let key = PetSnapshot(pet: pet).poseKey
        guard key != animation?.key, key != loadingAnimationKey else { return }
        if animation?.stickerID != pet.sticker.id { animation = nil }
        loadingAnimationKey = key
        defer { if loadingAnimationKey == key { loadingAnimationKey = nil } }
        do {
            let playbackKey = "\(pet.sticker.id)|\(revisionID)"
            let document: AnimatedDocument
            if let playback, playback.key == playbackKey {
                document = playback.document
            } else {
                document = try await api.stickerPlayback(stickerID: pet.sticker.id, revisionID: revisionID).document
                playback = (playbackKey, document)
            }
            var settings = StickerControlSettings.defaults(for: document)
            if let values = pet.status?.values { settings.values.merge(values) { _, posed in posed } }
            let resolved = try settings.resolvedDocument(document)
            await animationAssets.preload(document: resolved, api: api)
            // Another pose replaced this one while it loaded; that one's refresh will land it.
            guard let current = self.pet, PetSnapshot(pet: current).poseKey == key else { return }
            // Drawn even with a frame missing, as the viewer does: a gap beats a pet that never moves.
            if !animationAssets.renderAssets.containsArtwork(for: resolved) {
                Self.log.error("pet animation is missing artwork for \(key, privacy: .public)")
            }
            animation = PetAnimation(key: key, stickerID: current.sticker.id, document: resolved, assets: animationAssets.renderAssets)
            Self.log.info("pet animation ready: \(resolved.renderedCycleDuration)s cycle, every \(self.animationInterval)")
        } catch {
            guard !StickerStore.isCancellation(error) else { return }
            Self.log.error("pet animation failed to load: \(error.localizedDescription, privacy: .public)")
            if self.pet?.sticker.id != animation?.stickerID { animation = nil }
        }
    }

    /// Fetches the drawing of the pet's weather when it changed. No weather, or none drawn yet,
    /// clears it so a stale sky never stands behind the pet; a failed fetch keeps what is up.
    private func refreshWeatherArt() async {
        if await PetArtworkImageCache.shared.prepareWeather(for: pet) {
            weatherArt = nil
            weatherArtKey = nil
        }
        guard let pet, let art = pet.weatherArt else {
            weatherArt = nil
            weatherArtKey = nil
            return
        }
        guard art.key != weatherArtKey || weatherArt == nil else { return }
        do {
            let image = try await PetArtworkImageCache.shared.loadWeather(
                pet: pet, artKey: art.key, size: Self.weatherArtSize, api: api
            )
            // The weather turned while this one was fetched; that one's fetch will land it.
            guard self.pet?.weatherArt?.key == art.key else { return }
            weatherArt = image
            weatherArtKey = art.key
        } catch {
            guard !StickerStore.isCancellation(error) else { return }
        }
    }

    /// Fetches the sky outside the room's window, drawn in the pet's style, when it changed. Off the
    /// plain page, or with no drawing for this weather yet, it clears so the painted sky shows instead
    /// of a stale one; a failed fetch keeps what is up.
    private func refreshWindowSky() async {
        guard let pet, pet.room != nil, let art = pet.windowWeatherArt else {
            windowSky = nil
            windowSkyKey = nil
            return
        }
        guard art.key != windowSkyKey || windowSky == nil else { return }
        do {
            let image = try await PetArtworkImageCache.shared.loadWindowWeather(
                pet: pet, artKey: art.key, size: Self.windowSkySize, api: api
            )
            // The weather turned while this one was fetched; that one's fetch will land it.
            guard self.pet?.windowWeatherArt?.key == art.key else { return }
            windowSky = PetWindowSprites(sheet: image, kind: art.kind, isDay: art.isDay)
            windowSkyKey = art.key
        } catch {
            guard !StickerStore.isCancellation(error) else { return }
            Self.log.error("pet window sky failed to load: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Whether the pet has weather the server is still drawing — the sticker beside it, or the sky
    /// outside its room's window — so the tab looks again shortly.
    var isWeatherArtPending: Bool {
        guard pet?.signals?.weather != nil else { return false }
        return pet?.weatherArt == nil || (pet?.room != nil && pet?.windowWeatherArt == nil)
    }

    func release() async {
        guard activity == nil else { return }
        activity = .releasing
        defer { activity = nil }
        do {
            try await api.clearPet()
            pet = nil
            brain.forgetLocalLine()
            await refreshPose()
            await refreshWeatherArt()
            await refreshRoomArt()
            await refreshThemeArt()
            await refreshWindowSky()
            dismissPhoto()
            dismissItem()
            errorMessage = nil
            publishToCompanions()
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.failure()
        }
    }

    /// Whether the pet is busy answering an action, a picture or its owner's words; only one at a time.
    var isAnswering: Bool { pendingAction != nil || isLookingAtPhoto || isHearingOwner }

    /// Has the pet answer `words` its owner said aloud, without waiting for the reply, so the talk
    /// sheet can close at once. The answer is thought of on the phone, reminded of what the pet
    /// remembers that bears on the words; the server hears of the talk only for the pet to remember
    /// it. Returns whether the pet is answering.
    @discardableResult
    func talk(_ words: String) -> Bool {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, let pet, activity == nil, !isAnswering else { return false }
        isHearingOwner = true
        // A new interaction moves on from the picture.
        dismissPhoto()
        dismissItem()
        Task {
            defer { isHearingOwner = false }
            let memories = await recall(about: words)
            let reply = await brain.hear(words, pet: pet, memories: memories)
            Haptics.success()
            // Remembering is the server's business, and so is the pose the pet's decision model picks
            // to go with its answer; a talk it never hears of is only forgotten, and the pet keeps its pose.
            Task { await strikePose(forTalk: words, reply: reply) }
        }
        return true
    }

    /// Tells the server of a talk and takes on the pose it answers with. Its on-device line stays up.
    /// Skipped when something else started changing the pet meanwhile, since that poses it anyway.
    private func strikePose(forTalk words: String, reply: String) async {
        do {
            guard let posed = try await api.rememberPetTalk(words: words, reply: reply),
                  activity == nil, !isAnswering, posed.status?.values != pet?.status?.values else { return }
            pet = posed
            publishToCompanions()
            Haptics.tap(.soft)
            await refreshPose()
        } catch {
            Self.log.error("Could not tell the pet's memory about a talk: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// What the pet remembers that bears on `words`, or nothing when the server is slow or away:
    /// the pet would rather answer at once than remember.
    private func recall(about words: String) async -> [PetMemory] {
        let api = api
        return await withTaskGroup(of: [PetMemory]?.self) { group in
            group.addTask { try? await api.petMemories(about: words) }
            group.addTask {
                try? await Task.sleep(for: .seconds(2.5))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }

    /// Picks `choice` for the pet's open encounter, covering the screen while the server decides what
    /// it led to. Returns the outcome for the sheet to reveal, or nil when it could not be picked.
    func decide(_ choice: PetEncounter.Choice, in encounter: PetEncounter) async -> PetEncounterOutcome? {
        guard activity == nil, !isAnswering else { return nil }
        activity = .deciding
        defer { activity = nil }
        do {
            let response = try await api.resolvePetEncounter(encounterID: encounter.id, choiceID: choice.id)
            pet = response.pet
            brain.forgetLocalLine()
            errorMessage = nil
            publishToCompanions()
            Task { await refreshPose() }
            // A right call feels like a win; a wrong one is felt as a warning, not an error.
            if response.outcome.correct { Haptics.success() } else { Haptics.warning() }
            return response.outcome
        } catch {
            errorMessage = error.localizedDescription
            Haptics.failure()
            // The moment may have passed or been decided elsewhere; the pet shows where it stands.
            if let refreshed = try? await api.pet() { pet = refreshed }
            return nil
        }
    }

    /// The owner has met the pet's new friend, so it is not welcomed again. Cleared on the tab at
    /// once — the welcome is already closing — and a call that fails only means the friend says
    /// hello once more next time.
    func finishWelcoming(_ friend: PetFriend) async {
        if pet?.friend?.id == friend.id { pet?.friend = nil }
        do {
            if let updated = try await api.markPetFriendSeen(friendID: friend.id) { pet = updated }
        } catch {
            Self.log.error("Could not mark friend \(friend.id, privacy: .public) seen: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Gives the ill pet a dose of medicine, covering the screen while it lands.
    func giveMedicine() async {
        guard activity == nil, !isAnswering, pet?.illness != nil, (pet?.medicine ?? 0) > 0 else { return }
        activity = .givingMedicine
        defer { activity = nil }
        do {
            pet = try await api.givePetMedicine()
            errorMessage = nil
            publishToCompanions()
            greetCount &+= 1
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.failure()
        }
    }

    /// Whether the owner has the gold a dose of medicine costs. False when the server does not sell it.
    var canAffordMedicine: Bool {
        guard let price = pet?.medicinePrice else { return false }
        return price <= (pet?.stats.gold ?? 0)
    }

    /// Buys a dose of medicine from the item shop, covering the screen while it lands. It is kept
    /// whether or not the pet is ill. Returns whether it was bought.
    @discardableResult
    func buyMedicine() async -> Bool {
        guard activity == nil, !isAnswering, canAffordMedicine else { return false }
        activity = .buyingMedicine
        defer { activity = nil }
        do {
            pet = try await api.purchasePetMedicine()
            errorMessage = nil
            publishToCompanions()
            Haptics.success()
            return true
        } catch {
            errorMessage = error.localizedDescription
            Haptics.failure()
            return false
        }
    }

    /// Buys `item` from the shop into the bag to use later, covering the screen while it lands.
    /// Returns whether it was bought.
    @discardableResult
    func buyItem(_ item: PetAction) async -> Bool {
        guard activity == nil, !isAnswering, canAfford(item) else { return false }
        activity = .buyingItem(item.title)
        defer { activity = nil }
        do {
            pet = try await api.purchasePetItem(itemID: item.id)
            errorMessage = nil
            publishToCompanions()
            Haptics.success()
            return true
        } catch {
            errorMessage = error.localizedDescription
            Haptics.failure()
            return false
        }
    }

    /// How many of `item` the bag holds.
    func bagCount(of item: PetAction) -> Int {
        pet?.bag.first { $0.id == item.id }?.count ?? 0
    }

    /// Reads the owner's rooms and the shop; the shop may still be drawing its next rooms, which a
    /// later call picks up. A failure keeps what was shown.
    func refreshRooms() async {
        do {
            rooms = try await api.petRooms()
        } catch {
            guard !StickerStore.isCancellation(error) else { return }
            if rooms == nil { errorMessage = error.localizedDescription }
        }
    }

    /// Whether the owner has the gold `room` costs.
    func canAfford(_ room: PetRoom) -> Bool { room.price <= (pet?.stats.gold ?? 0) }

    /// Buys `room` and moves the pet in, covering the screen while it lands. Returns whether it did.
    func purchaseRoom(_ room: PetRoom) async -> Bool {
        guard activity == nil, !room.owned, canAfford(room) else { return false }
        activity = .buyingRoom(room.title)
        defer { activity = nil }
        do {
            apply(try await api.purchasePetRoom(roomID: room.id))
            Haptics.success()
            return true
        } catch {
            errorMessage = error.localizedDescription
            Haptics.failure()
            await refreshRooms()
            return false
        }
    }

    /// Moves the pet into `room`, one the owner has, or back onto the plain page with nil.
    func moveIntoRoom(_ room: PetRoom?) async -> Bool {
        guard activity == nil else { return false }
        activity = .movingRoom
        defer { activity = nil }
        do {
            apply(try await api.setPetRoom(roomID: room?.id))
            Haptics.success()
            return true
        } catch {
            errorMessage = error.localizedDescription
            Haptics.failure()
            return false
        }
    }

    private func apply(_ change: PetRoomChangeResponse) {
        pet = change.pet
        rooms = change.rooms
        errorMessage = nil
        publishToCompanions()
        // The pet notices its new home.
        greetCount &+= 1
        Task { await refreshRoomArt() }
        Task { await refreshWindowSky() }
    }

    /// Fetches the drawing of the pet's room when it changed. Off the plain page it clears at once;
    /// a failed fetch keeps whatever room is up rather than flashing back to paper.
    private func refreshRoomArt() async {
        guard let room = pet?.room else {
            roomArt = nil
            roomArtKey = nil
            return
        }
        guard room.artKey != roomArtKey || roomArt == nil else { return }
        do {
            let image = try await PetArtworkImageCache.shared.loadRoom(roomID: room.id, artKey: room.artKey, api: api)
            // The pet moved again while this one loaded; that move's fetch will land it.
            guard pet?.room?.artKey == room.artKey else { return }
            roomArt = image
            roomArtKey = room.artKey
        } catch {
            guard !StickerStore.isCancellation(error) else { return }
            Self.log.error("pet room art failed to load: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reads the places the pet knows; its agent may still be discovering new ones, which a later
    /// call picks up. A failure keeps what was shown.
    func refreshThemes() async {
        do {
            themes = try await api.petThemes()
        } catch {
            guard !StickerStore.isCancellation(error) else { return }
            if themes == nil { errorMessage = error.localizedDescription }
        }
    }

    /// Takes the pet to `theme`, or home with nil, covering the screen while it goes. Returns
    /// whether it went; a place its rules close says why in the error banner.
    func goTo(_ theme: PetTheme?) async -> Bool {
        guard activity == nil else { return false }
        activity = theme.map { .goingTo($0.title) } ?? .comingHome
        defer { activity = nil }
        do {
            let change = try await api.setPetTheme(themeID: theme?.id)
            pet = change.pet
            themes = change.themes
            errorMessage = nil
            publishToCompanions()
            // The pet notices where it is.
            greetCount &+= 1
            Haptics.success()
            await refreshThemeArt()
            return true
        } catch {
            errorMessage = error.localizedDescription
            Haptics.failure()
            await refreshThemes()
            return false
        }
    }

    /// Fetches the drawing of the place the pet has gone when it changed. Back home it clears at
    /// once, and the room shows again; a failed fetch leaves the room up rather than a blank. The
    /// tab calls it whenever the pet's place changes, since its agent moves it on its own.
    func refreshThemeArt() async {
        guard let theme = pet?.theme else {
            themeArt = nil
            themeArtKey = nil
            return
        }
        guard theme.artKey != themeArtKey || themeArt == nil else { return }
        do {
            let image = try await PetArtworkImageCache.shared.loadTheme(themeID: theme.id, artKey: theme.artKey, api: api)
            // The pet went somewhere else while this one loaded; that trip's fetch will land it.
            guard pet?.theme?.artKey == theme.artKey else { return }
            themeArt = image
            themeArtKey = theme.artKey
        } catch {
            guard !StickerStore.isCancellation(error) else { return }
            Self.log.error("pet theme art failed to load: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Whether the pet has the gold `action` costs.
    func canAfford(_ action: PetAction) -> Bool { action.effects.price <= (pet?.stats.gold ?? 0) }

    /// Checks whether the server's background item drawing has arrived while the sheet is open.
    func refreshItems() async {
        guard let latest = try? await api.pet(), latest.sticker.id == pet?.sticker.id else { return }
        pet = latest
    }

    /// Uses `item` — bought from the shop and used at once, or one from the bag, already paid for —
    /// holding its picture up on the tab while the pet answers. The picture is fetched by the item's
    /// id, so it survives the shelf changing under the reply. Returns whether it was sent.
    @discardableResult
    func useItem(_ item: PetAction, fromBag: Bool = false) -> Bool {
        let used = UsedItem(title: item.title, image: nil)
        guard interact(item, item: used, fromBag: fromBag) else { return false }
        Task {
            guard let image = try? await PetArtworkImageCache.shared.loadItem(itemID: item.id, size: 256, api: api),
                  usedItem?.id == used.id else { return }
            usedItem?.image = image
        }
        return true
    }

    private func dismissItem() {
        itemExpiry?.cancel()
        itemExpiry = nil
        usedItem = nil
    }

    private func expireItem(_ item: UsedItem?) {
        guard let item, usedItem?.id == item.id else { return }
        itemExpiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, self.usedItem?.id == item.id else { return }
            self.dismissItem()
        }
    }

    /// Shows the pet `image` without blocking the screen: the picture appears above the pet at once,
    /// and its reaction lands in the dialogue box. Returns whether the picture was sent.
    @discardableResult
    func showPhoto(_ image: UIImage) -> Bool {
        guard activity == nil, !isAnswering, pet != nil else { return false }
        guard let jpeg = Self.photoJPEG(image) else {
            errorMessage = String(localized: "This picture could not be read.")
            Haptics.failure()
            return false
        }
        photoExpiry?.cancel()
        dismissItem()
        shownPhoto = image
        isLookingAtPhoto = true
        if let pet { brain.anticipatePhoto(pet: pet) }
        Task {
            defer {
                isLookingAtPhoto = false
                expirePhoto(image)
            }
            do {
                pet = try await brain.look(atPhoto: jpeg)
                errorMessage = nil
                publishToCompanions()
                // The thinking bubble stays up until the new pose is in, so line and pose land together.
                await refreshPose()
                Haptics.success()
            } catch {
                errorMessage = error.localizedDescription
                Haptics.failure()
            }
        }
        return true
    }

    /// Puts the shown picture away now.
    func dismissPhoto() {
        photoExpiry?.cancel()
        photoExpiry = nil
        shownPhoto = nil
    }

    /// Puts `image` away after `photoLifetime`, unless another picture has replaced it by then.
    private func expirePhoto(_ image: UIImage) {
        photoExpiry?.cancel()
        photoExpiry = Task { [weak self] in
            try? await Task.sleep(for: Self.photoLifetime)
            guard !Task.isCancelled, let self, self.shownPhoto === image else { return }
            self.shownPhoto = nil
        }
    }

    /// The picture as the pet is shown it: at most 1024 points on its long edge, as a JPEG, which is
    /// all the model looks at and keeps the upload small.
    nonisolated static func photoJPEG(_ image: UIImage, maxEdge: CGFloat = 1024) -> Data? {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxEdge / longest)
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.8) { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Sends `action` without waiting for the reply, so the actions sheet can close at once.
    /// Returns whether the action was started.
    @discardableResult
    func interact(_ action: PetAction, item: UsedItem? = nil, fromBag: Bool = false) -> Bool {
        // Something from the bag is already paid for.
        guard activity == nil, !isAnswering, pet != nil, fromBag || canAfford(action) else { return false }
        pendingAction = action
        dismissItem()
        usedItem = item
        // A new interaction moves on from the picture.
        dismissPhoto()
        // The pet's first reaction comes from the phone, so it answers at once; its agent's lands after.
        if let pet { brain.anticipate(action, pet: pet) }
        Task {
            defer {
                pendingAction = nil
                expireItem(item)
            }
            do {
                pet = try await brain.answer(action, fromBag: fromBag)
                errorMessage = nil
                publishToCompanions()
                // The thinking bubble stays up until the new pose is in, so line and pose land together.
                await refreshPose()
                Haptics.success()
            } catch {
                dismissItem()
                errorMessage = error.localizedDescription
                Haptics.failure()
            }
        }
        return true
    }
}
