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
    }

    private(set) var pet: Pet?
    private(set) var hasLoadedPet = false
    private(set) var sections: [LibrarySection] = []
    private(set) var isLoadingCandidates = false
    private(set) var activity: Activity?
    /// The action the pet is answering. Unlike `activity` it does not block the screen: the pet's
    /// dialogue box shows a thinking line until the reply lands.
    private(set) var pendingAction: PetAction?
    /// The picture the pet was last shown, drawn in a bubble above it until another one is sent.
    private(set) var shownPhoto: UIImage?
    /// True while the pet is looking at `shownPhoto`. Like `pendingAction`, it does not block the screen.
    private(set) var isLookingAtPhoto = false
    var errorMessage: String?

    let api: any StickerAPIClientProtocol
    /// Steps and location, for the pet's birth world and its "World" row. Shared across the app.
    let context: PetContextProvider

    /// Invalidates a candidate response still in flight when the query changes.
    @ObservationIgnored private var generation = 0

    init(api: any StickerAPIClientProtocol, context: PetContextProvider = .shared) {
        self.api = api
        self.context = context
    }

    /// Every candidate, in section order, without the empty "My Stickers" a pack-only user gets.
    var candidateSections: [LibrarySection] { sections.filter { !$0.stickers.isEmpty } }

    func loadPet() async {
        do {
            pet = try await api.pet()
            hasLoadedPet = true
            publishToCompanions()
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
        }
        if stored {
            errorMessage = nil
            Haptics.success()
        } else {
            Haptics.failure()
        }
        return stored
    }

    /// Hands the pet to the widget and the watch. Not awaited: drawing the pose is their business,
    /// and the tab has already shown the user what changed.
    private func publishToCompanions() {
        let pet = pet
        Task { await PetCompanionSync.shared.publish(pet) }
    }

    func release() async {
        guard activity == nil else { return }
        activity = .releasing
        defer { activity = nil }
        do {
            try await api.clearPet()
            pet = nil
            shownPhoto = nil
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
        shownPhoto = image
        isLookingAtPhoto = true
        Task {
            defer { isLookingAtPhoto = false }
            do {
                pet = try await api.sendPetPhoto(jpeg: jpeg)
                errorMessage = nil
                publishToCompanions()
                Haptics.success()
            } catch {
                errorMessage = error.localizedDescription
                Haptics.failure()
            }
        }
        return true
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
        Task {
            defer { pendingAction = nil }
            do {
                pet = try await api.interactWithPet(action)
                errorMessage = nil
                publishToCompanions()
                Haptics.success()
            } catch {
                errorMessage = error.localizedDescription
                Haptics.failure()
            }
        }
        return true
    }
}
