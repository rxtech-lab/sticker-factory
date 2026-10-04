import Observation
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
    }

    private(set) var pet: Pet?
    private(set) var hasLoadedPet = false
    private(set) var sections: [LibrarySection] = []
    private(set) var isLoadingCandidates = false
    private(set) var activity: Activity?
    /// The action the pet is answering. Unlike `activity` it does not block the screen: the pet's
    /// dialogue box shows a thinking line until the reply lands.
    private(set) var pendingAction: PetAction?
    /// The picture the pet was last shown, held up beside it until the next interaction or until
    /// `photoLifetime` after the pet has reacted to it.
    private(set) var shownPhoto: UIImage?
    /// True while the pet is looking at `shownPhoto`. Like `pendingAction`, it does not block the screen.
    private(set) var isLookingAtPhoto = false
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
    var errorMessage: String?

    let api: any StickerAPIClientProtocol
    /// Steps and location, for the pet's birth world and its "World" row. Shared across the app.
    let context: PetContextProvider

    /// Invalidates a candidate response still in flight when the query changes.
    @ObservationIgnored private var generation = 0
    /// The pet `pose` was drawn for.
    @ObservationIgnored private var poseStickerID: String?
    /// Puts the shown picture away once it has been up for `photoLifetime`.
    @ObservationIgnored private var photoExpiry: Task<Void, Never>?
    /// How long the picture stays up after the pet's reaction lands.
    static let photoLifetime: Duration = .seconds(20)
    /// Edge of the pose drawing, in pixels: the tab shows the pet at 176 points, so about 3x.
    static let poseSize = 512
    /// Edge of the weather drawing, in pixels: the tab shows it at about 120 points.
    static let weatherArtSize = 384

    init(api: any StickerAPIClientProtocol, context: PetContextProvider = .shared) {
        self.api = api
        self.context = context
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
            // The pet is here and current, so whatever failed before no longer describes it.
            errorMessage = nil
            publishToCompanions()
            Task { await refreshPose() }
            Task { await refreshWeatherArt() }
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
            dismissPhoto()
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
    /// overlay, no haptics, and nothing at all within half an hour of the last upload.
    func syncWorldInBackground() {
        let api = api, context = context
        Task {
            await context.refreshPermissions()
            await context.syncIfNeeded(api: api)
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
        } else {
            Haptics.failure()
        }
        return stored
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
            weatherProblem = String(localized: "Your phone couldn't find where you are. Check that Location Services is on, then try again.")
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

    /// Fetches the drawing of the pet's weather when it changed. No weather, or none drawn yet,
    /// clears it so a stale sky never stands behind the pet; a failed fetch keeps what is up.
    private func refreshWeatherArt() async {
        guard let art = pet?.weatherArt else {
            weatherArt = nil
            weatherArtKey = nil
            return
        }
        guard art.key != weatherArtKey || weatherArt == nil else { return }
        do {
            let data = try await api.petWeatherArt(size: Self.weatherArtSize)
            // The weather turned while this one was fetched; that one's fetch will land it.
            guard self.pet?.weatherArt?.key == art.key, let image = UIImage(data: data) else { return }
            weatherArt = image
            weatherArtKey = art.key
        } catch {
            guard !StickerStore.isCancellation(error) else { return }
        }
    }

    /// Whether the pet has weather the server is still drawing, so the tab looks again shortly.
    var isWeatherArtPending: Bool { pet?.signals?.weather != nil && pet?.weatherArt == nil }

    func release() async {
        guard activity == nil else { return }
        activity = .releasing
        defer { activity = nil }
        do {
            try await api.clearPet()
            pet = nil
            await refreshPose()
            await refreshWeatherArt()
            dismissPhoto()
            errorMessage = nil
            publishToCompanions()
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.failure()
        }
    }

    /// Whether the pet is busy answering an action or a picture; only one at a time.
    var isAnswering: Bool { pendingAction != nil || isLookingAtPhoto }

    /// Whether the pet has the gold `action` costs.
    func canAfford(_ action: PetAction) -> Bool { action.effects.price <= (pet?.stats.gold ?? 0) }

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
        shownPhoto = image
        isLookingAtPhoto = true
        Task {
            defer {
                isLookingAtPhoto = false
                expirePhoto(image)
            }
            do {
                pet = try await api.sendPetPhoto(jpeg: jpeg)
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
    func interact(_ action: PetAction) -> Bool {
        guard activity == nil, !isAnswering, pet != nil, canAfford(action) else { return false }
        pendingAction = action
        // A new interaction moves on from the picture.
        dismissPhoto()
        Task {
            defer { pendingAction = nil }
            do {
                pet = try await api.interactWithPet(action)
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
}
