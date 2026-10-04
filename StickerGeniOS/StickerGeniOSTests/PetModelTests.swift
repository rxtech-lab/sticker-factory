import AnimatedView
import Foundation
import UIKit
import XCTest
@testable import StickerGeniOS

@MainActor
final class PetModelTests: XCTestCase {
    func testOffersOnlyControllableStickersFromInstalledPacks() async throws {
        let api = MockStickerAPIClient()
        let model = PetModel(api: api)

        await model.loadCandidates(query: "", debounce: .zero)
        XCTAssertTrue(model.candidateSections.isEmpty, "Nothing the mock owns is controllable")

        _ = try await api.installPack(id: PreviewFixtures.pack.id, idempotencyKey: "install-pet-pack")
        await model.loadCandidates(query: "", debounce: .zero)
        XCTAssertEqual(model.candidateSections.flatMap(\.stickers).map(\.id), [PreviewFixtures.borrowedSticker.id])
        XCTAssertEqual(model.candidateSections.first?.kind, .pack)
    }

    func testDecodesThePetStatusTheServerReadFromSends() throws {
        var pet = Pet(sticker: PreviewFixtures.borrowedSticker, selectedAt: Date(timeIntervalSince1970: 0))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder.api.encode(pet)) as! [String: Any]
        var json = encoded
        json["status"] = [
            "values": ["mood": "happy", "speed": 1.5, "hat": true],
            "caption": "Party time!",
            "updatedAt": "2026-10-04T12:00:00.000Z",
        ]
        json["actions"] = [[
            "id": "11111111-1111-4111-8111-111111111111",
            "title": "Wave to Loaf",
            "description": "Wave at Loaf's ears.",
            "effects": ["happiness": 3, "hp": 0, "energy": -1],
        ]]
        let decoded = try JSONDecoder.api.decode(Pet.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.status?.values, ["mood": .string("happy"), "speed": .number(1.5), "hat": .bool(true)])
        XCTAssertEqual(decoded.status?.caption, "Party time!")
        XCTAssertEqual(decoded.actions?.first?.title, "Wave to Loaf")
        XCTAssertEqual(decoded.actions?.first?.effects.energy, -1)

        // A pet whose sends have not been read yet arrives with a null status.
        json["status"] = NSNull()
        pet.status = try JSONDecoder.api.decode(Pet.self, from: JSONSerialization.data(withJSONObject: json)).status
        XCTAssertNil(pet.status)
    }

    func testAdoptsAndReleasesAPet() async throws {
        let api = MockStickerAPIClient()
        _ = try await api.installPack(id: PreviewFixtures.pack.id, idempotencyKey: "install-pet-pack")
        let model = PetModel(api: api)

        await model.loadPet()
        XCTAssertTrue(model.hasLoadedPet)
        XCTAssertNil(model.pet)

        let adopted = await model.adopt(PreviewFixtures.borrowedSticker)
        XCTAssertTrue(adopted)
        XCTAssertEqual(model.pet?.sticker.id, PreviewFixtures.borrowedSticker.id)
        XCTAssertNil(model.activity)
        let stored = try await api.pet()
        XCTAssertEqual(stored?.sticker.id, PreviewFixtures.borrowedSticker.id)

        await model.release()
        XCTAssertNil(model.pet)
        let cleared = try await api.pet()
        XCTAssertNil(cleared)
    }

    func testDecodesGoldAndTreatsItsAbsenceAsNone() throws {
        let effects = try JSONDecoder.api.decode(PetActionEffects.self, from: Data(#"{"happiness":1,"hp":0,"energy":-2,"gold":-15}"#.utf8))
        XCTAssertEqual(effects.gold, -15)
        XCTAssertEqual(effects.price, 15)
        let older = try JSONDecoder.api.decode(PetActionEffects.self, from: Data(#"{"happiness":1,"hp":0,"energy":-2}"#.utf8))
        XCTAssertEqual(older.gold, 0)
        XCTAssertEqual(older.price, 0)
        let stats = try JSONDecoder.api.decode(PetStats.self, from: Data(#"{"happiness":80,"hp":100,"energy":80}"#.utf8))
        XCTAssertEqual(stats.gold, 0)
    }

    func testShowsAPhotoAndRefusesWhatThePetCannotAfford() async throws {
        let api = MockStickerAPIClient()
        _ = try await api.installPack(id: PreviewFixtures.pack.id, idempotencyKey: "install-pet-pack")
        let model = PetModel(api: api)
        _ = await model.adopt(PreviewFixtures.borrowedSticker)
        let cake = try XCTUnwrap(model.pet?.actions?.first { $0.effects.price > (model.pet?.stats.gold ?? 0) })
        XCTAssertFalse(model.canAfford(cake))
        XCTAssertFalse(model.interact(cake))

        let image = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 1500)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3000, height: 1500))
        }
        let jpeg = try XCTUnwrap(PetModel.photoJPEG(image))
        XCTAssertEqual(UIImage(data: jpeg)?.size, CGSize(width: 1024, height: 512))

        XCTAssertTrue(model.showPhoto(image))
        XCTAssertNotNil(model.shownPhoto)
        XCTAssertTrue(model.isAnswering)
        XCTAssertFalse(model.showPhoto(image), "One answer at a time")
        while model.isAnswering { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.pet?.status?.caption, "What a lovely picture!")
    }

    func testRefusedAdoptionKeepsThePreviousPetAndSaysWhy() async throws {
        let api = MockStickerAPIClient()
        let model = PetModel(api: api)

        let adopted = await model.adopt(PreviewFixtures.sticker)
        XCTAssertFalse(adopted)
        XCTAssertNil(model.pet)
        XCTAssertEqual(model.errorMessage, "Only a published controllable sticker you made or installed can be your pet.")
    }
}
