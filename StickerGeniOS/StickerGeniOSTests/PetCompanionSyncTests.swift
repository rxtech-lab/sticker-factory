import AnimatedView
import Foundation
import XCTest
@testable import StickerGeniOS

@MainActor
final class PetCompanionSyncTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "pet-companion-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testStoreKeepsThePoseBesideTheSnapshotAndDropsItWithThePet() throws {
        let store = PetSnapshotStore(directory: directory)
        XCTAssertNil(store.envelope())

        let snapshot = PetSnapshot(stickerID: "s", title: "Loaf", caption: "Hi", statusUpdatedAt: nil,
                                   selectedAt: Date(timeIntervalSince1970: 0), poseKey: "k")
        try store.save(PetSnapshotEnvelope(pet: snapshot, writtenAt: Date(timeIntervalSince1970: 1)), pose: Data([1, 2, 3]))
        XCTAssertEqual(store.load()?.snapshot, snapshot)
        XCTAssertEqual(store.load()?.pose, Data([1, 2, 3]))

        // "No pet" is written down, so the watch can tell a release from a message still in flight.
        try store.save(PetSnapshotEnvelope(pet: nil, writtenAt: Date(timeIntervalSince1970: 2)), pose: nil)
        XCTAssertNil(store.load())
        XCTAssertEqual(store.envelope(), PetSnapshotEnvelope(pet: nil, writtenAt: Date(timeIntervalSince1970: 2)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.poseURL.path()))
    }

    func testEnvelopeSurvivesTheTripToTheWatch() throws {
        let envelope = PetSnapshotEnvelope(
            pet: PetSnapshot(stickerID: "s", title: "Loaf", caption: nil, statusUpdatedAt: Date(timeIntervalSince1970: 60),
                             selectedAt: Date(timeIntervalSince1970: 0), poseKey: "k"),
            writtenAt: Date(timeIntervalSince1970: 120)
        )
        XCTAssertEqual(try PetSnapshotEnvelope.decode(envelope.encoded()), envelope)
    }

    func testPublishesThePetAndFetchesThePoseOnlyWhenItChanges() async throws {
        let api = MockStickerAPIClient()
        _ = try await api.installPack(id: PreviewFixtures.pack.id, idempotencyKey: "install-pet-pack")
        let adopted = try await api.setPet(stickerID: PreviewFixtures.borrowedSticker.id)
        var pet = try XCTUnwrap(adopted)
        let store = PetSnapshotStore(directory: directory)
        var reloads = 0
        let sync = PetCompanionSync(api: api, store: store, reloadWidgets: { reloads += 1 })

        let published = await sync.publish(pet)
        XCTAssertTrue(published)
        XCTAssertEqual(store.load()?.snapshot.title, PreviewFixtures.borrowedSticker.title)
        XCTAssertNotNil(store.load()?.pose)
        XCTAssertEqual(reloads, 1)
        var poseRequests = await api.petPoseRequests
        XCTAssertEqual(poseRequests, 1)

        // Nothing moved: no drawing, no widget reload.
        await sync.publish(pet)
        poseRequests = await api.petPoseRequests
        XCTAssertEqual(poseRequests, 1)
        XCTAssertEqual(reloads, 1)

        // The pet read a send: a new pose to draw, and its words for the widget.
        pet.status = PetStatus(values: ["mood": .string("happy")], caption: "Party time!", updatedAt: Date(timeIntervalSince1970: 500))
        await sync.publish(pet)
        poseRequests = await api.petPoseRequests
        XCTAssertEqual(poseRequests, 2)
        XCTAssertEqual(store.load()?.snapshot.caption, "Party time!")
        XCTAssertEqual(reloads, 2)

        await sync.publish(nil)
        XCTAssertNil(store.load())
        XCTAssertNotNil(store.envelope(), "A release is recorded, not just forgotten")
        XCTAssertEqual(reloads, 3)
    }

    func testPublishesTheWeatherDrawingBesideThePetAndDropsItWhenTheSkyHasNone() async throws {
        let api = MockStickerAPIClient()
        _ = try await api.installPack(id: PreviewFixtures.pack.id, idempotencyKey: "install-pet-pack")
        let adopted = try await api.setPet(stickerID: PreviewFixtures.borrowedSticker.id)
        var pet = try XCTUnwrap(adopted)
        let store = PetSnapshotStore(directory: directory)
        let sync = PetCompanionSync(api: api, store: store, reloadWidgets: {})

        await sync.publish(pet)
        let weather = try XCTUnwrap(store.envelope()?.pet?.weather)
        XCTAssertEqual(weather.kind, "rainy")
        XCTAssertEqual(weather.artKey, "mock-rainy-day")
        XCTAssertNotNil(store.weatherArt())

        // The weather turned and its new look is still being drawn: the widget falls back to the symbol.
        pet.signals?.weather = PetWeather(kind: .sunny, temperatureC: 22, isDay: true)
        await sync.publish(pet)
        XCTAssertEqual(store.envelope()?.pet?.weather?.symbol, "sun.max.fill")
        XCTAssertNil(store.envelope()?.pet?.weather?.artKey)
        XCTAssertNil(store.weatherArt())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.weatherArtURL.path()))
    }

    func testKeepsTheLastPoseWhenTheDrawingFails() async throws {
        let api = MockStickerAPIClient()
        let store = PetSnapshotStore(directory: directory)
        let sync = PetCompanionSync(api: api, store: store, reloadWidgets: {})
        // The mock has no adopted pet, so drawing one fails the way a released pet would on the server.
        let pet = Pet(sticker: PreviewFixtures.borrowedSticker, selectedAt: Date())
        let published = await sync.publish(pet)
        XCTAssertFalse(published)
        XCTAssertNil(store.envelope())
    }

    func testSigningOutClearsWhatTheWidgetShows() async throws {
        let store = PetSnapshotStore(directory: directory)
        let snapshot = PetSnapshot(stickerID: "s", title: "Loaf", caption: nil, statusUpdatedAt: nil, selectedAt: Date(), poseKey: "k")
        try store.save(PetSnapshotEnvelope(pet: snapshot, writtenAt: Date()), pose: Data([1]))
        var reloads = 0
        let sync = PetCompanionSync(store: store, reloadWidgets: { reloads += 1 })

        await sync.signedOut()
        XCTAssertNil(store.envelope())
        XCTAssertEqual(reloads, 1)
    }
}
