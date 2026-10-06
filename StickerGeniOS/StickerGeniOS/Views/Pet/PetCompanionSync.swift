import Foundation
import OSLog
import UIKit
import WidgetKit

/// Keeps the widget and the watch showing the pet the account has now.
///
/// The watch cannot ask the server itself — it has no account — and the widget only does between
/// the app's visits (`PetWidgetRefresh`), so the phone does it for them: fetch the pet, fetch the
/// server's drawing of its pose when that changed, write both to the app group for the widget, and
/// hand them to the watch.
///
/// It runs whenever the app learns something new about the pet: the Pet tab loading or changing
/// it, the app coming forward, the server's silent "your pet moved" push, and the watch asking.
/// Like `PushDeviceRegistry`, it is a process-wide seam: an API client is attached once the app has
/// one, and until then every call is a no-op.
@MainActor
final class PetCompanionSync {
    static let shared = PetCompanionSync()

    private static let log = Logger(subsystem: "app.rxlab.sticker-factory", category: "pet-companion")

    private var api: (any StickerAPIClientProtocol)?
    private let store: PetSnapshotStore?
    private let watch: PetWatchBridge
    private let reloadWidgets: @MainActor () -> Void
    /// The publish in flight. Each one waits for the last, so two answers cannot land out of order.
    private var work: Task<Void, Never>?

    /// `api` is for tests; the app attaches one with `attach(api:)`, which also wakes the watch link.
    init(
        api: (any StickerAPIClientProtocol)? = nil,
        store: PetSnapshotStore? = PetSnapshotStore(),
        watch: PetWatchBridge = PetWatchBridge(),
        reloadWidgets: @escaping @MainActor () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: PetCompanion.phoneWidgetKind) }
    ) {
        self.api = api
        self.store = store
        self.watch = watch
        self.reloadWidgets = reloadWidgets
    }

    func attach(api: any StickerAPIClientProtocol) {
        self.api = api
        watch.activate(
            onRequest: { [weak self] in await self?.refresh(resendToWatch: true) },
            onReachable: { [weak self] force in self?.resendToWatch(force: force) }
        )
    }

    /// Asks the server for the pet and publishes it. Returns whether that worked, for the push handler.
    @discardableResult
    func refresh(resendToWatch: Bool = false) async -> Bool {
        guard let api else { return false }
        do {
            return await publish(try await api.pet(), resendToWatch: resendToWatch)
        } catch {
            Self.log.error("pet refresh failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Publishes a pet the app already holds — the Pet tab's, after loading or changing it.
    @discardableResult
    func publish(_ pet: Pet?, resendToWatch: Bool = false) async -> Bool {
        guard let api, let store else { return false }
        return await serially { [watch, reloadWidgets] in
            let weatherScopeChanged = await PetArtworkImageCache.shared.prepareWeather(for: pet)
            var snapshot = pet.map(PetSnapshot.init(pet:))
            let current = store.envelope()
            do {
                // The picture is the expensive part — a server render — so it is fetched only when
                // the pose it names changed, or the copy on disk went missing.
                let needsPose = snapshot != nil && (current?.pet?.poseKey != snapshot?.poseKey || store.load() == nil)
                let pose = needsPose ? try await api.petPose(size: PetCompanion.poseSize) : nil
                // The weather's drawing likewise. One that will not come is left out rather than
                // failing the pet: the widget shows the weather's symbol, and the next publish retries.
                var weatherArt: Data?
                if let pet, let artKey = snapshot?.weather?.artKey,
                   weatherScopeChanged || current?.pet?.weather?.artKey != artKey || store.weatherArt() == nil {
                    let image = try? await PetArtworkImageCache.shared.loadWeather(
                        pet: pet, artKey: artKey, size: PetCompanion.weatherArtSize, api: api
                    )
                    weatherArt = image?.pngData()
                    if weatherArt == nil { snapshot?.weather?.artKey = nil }
                }
                if let current, current.pet == snapshot, pose == nil, weatherArt == nil {
                    // The widget may have written this one itself while the app was away, and the
                    // watch has not been sent it yet.
                    watch.send(current, poseURL: current.pet == nil ? nil : store.poseURL, onlyIfNew: !resendToWatch)
                    return true
                }
                let envelope = PetSnapshotEnvelope(pet: snapshot, writtenAt: .now)
                try store.save(envelope, pose: pose, weatherArt: weatherArt)
                reloadWidgets()
                watch.send(envelope, poseURL: snapshot == nil ? nil : store.poseURL)
                return true
            } catch {
                // The last pose stays up. A pet that missed one mood still looks like itself.
                Self.log.error("pet publish failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
    }

    /// Signing out: the next person to hold this phone, or glance at this watch, must not see the pet.
    func signedOut() async {
        await serially { [store, watch, reloadWidgets] in
            await PetArtworkImageCache.shared.prepareWeather(for: nil)
            store?.clear()
            reloadWidgets()
            watch.send(PetSnapshotEnvelope(pet: nil, writtenAt: .now), poseURL: nil)
        }
    }

    /// The watch link came up, or the watch app was just installed (`force`): give the watch what
    /// the phone already has, unless it was already sent.
    private func resendToWatch(force: Bool) {
        guard api != nil, let store, let envelope = store.envelope() else { return }
        watch.send(envelope, poseURL: envelope.pet == nil ? nil : store.poseURL, onlyIfNew: !force)
    }

    @discardableResult
    private func serially<Result: Sendable>(_ operation: @escaping @MainActor () async -> Result) async -> Result {
        let previous = work
        let task = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        work = Task { _ = await task.value }
        return await task.value
    }
}

extension PetSnapshot {
    init(pet: Pet) {
        let sticker = pet.sticker
        self.init(
            stickerID: sticker.id,
            title: sticker.title,
            caption: pet.status?.caption,
            statusUpdatedAt: pet.status?.updatedAt,
            selectedAt: pet.selectedAt,
            poseKey: PetSnapshot.poseKey(
                stickerID: sticker.id,
                revisionID: sticker.playbackRevisionId ?? sticker.activeRevisionId,
                statusUpdatedAt: pet.status?.updatedAt
            ),
            weather: pet.signals?.weather.map { weather in
                PetSnapshotWeather(
                    kind: weather.kind.rawValue,
                    symbol: weather.kind.symbol(isDay: weather.isDay),
                    temperatureC: weather.temperatureC,
                    isDay: weather.isDay,
                    // Only a drawing of the weather it is in now; a stale one would show the wrong sky.
                    artKey: pet.weatherArt.flatMap { $0.kind == weather.kind && $0.isDay == weather.isDay ? $0.key : nil }
                )
            },
            musings: pet.status?.musings
        )
    }
}
