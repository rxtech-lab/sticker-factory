import Foundation
import XCTest
@testable import StickerGeniOS

/// The pet's places as the server sends them, and the Location Tracking switch as the phone sends it.
@MainActor
final class PetThemeContractsTests: XCTestCase {
    func testDecodesThePlacesAndThePlaceThePetIsAt() throws {
        let json = """
        {"themes":{"activeThemeId":"7f6d1d55-0000-4000-8000-000000000001","discovering":false,"traveling":true,"hasLocation":true,
          "themes":[
            {"id":"7f6d1d55-0000-4000-8000-000000000001","title":"Faraway Streets","description":"The trip","category":"travel",
             "limited":true,"effects":{"happiness":4,"hp":0,"energy":-2},
             "rules":{"dailyMinutes":null,"hours":null,"weather":null,
                      "place":{"label":"Kyoto","latitude":35.01,"longitude":135.77,"radiusKm":60}},
             "artKey":"7f6d1d55-0000-4000-8000-0000000000aa","expiresAt":"2026-10-09T12:00:00.000Z","expired":false,
             "available":true,"unavailableReason":null,"minutesLeftToday":null,"discoveredAt":"2026-10-06T12:00:00.000Z"},
            {"id":"7f6d1d55-0000-4000-8000-000000000002","title":"Night Market","description":"Lanterns","category":"floating-island",
             "limited":false,"effects":{"happiness":3,"hp":0,"energy":-1},
             "rules":{"dailyMinutes":60,"hours":{"from":18,"to":24},"weather":["sunny","cloudy"],"place":null},
             "artKey":"7f6d1d55-0000-4000-8000-0000000000bb","expiresAt":null,"expired":false,
             "available":false,"unavailableReason":"Open 18:00–00:00 your time.","minutesLeftToday":60,
             "discoveredAt":"2026-10-05T12:00:00.000Z"}
          ]}}
        """
        let themes = try JSONDecoder.api.decode(PetThemesResponse.self, from: Data(json.utf8)).themes
        XCTAssertTrue(themes.traveling)
        let trip = try XCTUnwrap(themes.themes.first)
        XCTAssertEqual(trip.category, .travel)
        XCTAssertTrue(trip.limited)
        XCTAssertEqual(trip.rules.place?.label, "Kyoto")
        XCTAssertEqual(trip.rules.place?.coordinate?.latitude, 35.01)
        XCTAssertNotNil(trip.expiresAt)
        let market = themes.themes[1]
        // A kind of place this build does not know yet still decodes.
        XCTAssertEqual(market.category.rawValue, "floating-island")
        XCTAssertEqual(market.rules.hours?.from, 18)
        XCTAssertEqual(market.unavailableReason, "Open 18:00–00:00 your time.")
        XCTAssertFalse(market.rules.isEmpty)

        var petJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.api.encode(
            Pet(sticker: PreviewFixtures.borrowedSticker, selectedAt: Date(timeIntervalSince1970: 0))
        )) as? [String: Any])
        XCTAssertNil(try JSONDecoder.api.decode(Pet.self, from: JSONSerialization.data(withJSONObject: petJSON)).theme)
        petJSON["theme"] = ["id": trip.id, "title": trip.title, "artKey": trip.artKey, "category": "travel"]
        let pet = try JSONDecoder.api.decode(Pet.self, from: JSONSerialization.data(withJSONObject: petJSON))
        XCTAssertEqual(pet.theme, trip.ref)
    }

    func testGoingHomeSendsNullRatherThanNothing() throws {
        let encoded = try JSONEncoder.api.encode(SetPetThemeRequest(themeId: nil))
        let home = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(home.keys), ["themeId"])
        XCTAssertTrue(home["themeId"] is NSNull)
    }

    func testTrackingOffSendsNoLocationAndTheCacheForgetsIt() throws {
        let off = PetContextPayload(timeZone: "UTC", trackLocation: false)
        XCTAssertFalse(off.isEmpty)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.api.encode(off)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["timeZone", "trackLocation"])
        XCTAssertEqual(object["trackLocation"] as? Bool, false)

        let suite = "pet-theme-tests-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let cache = PetContextCache(suiteName: suite)
        let capturedAt = Date(timeIntervalSince1970: 1_790_000_000)
        cache.write(PetContextPayload(latitude: 48.86, longitude: 2.35, timeZone: "UTC"), previous: nil, capturedAt: capturedAt)
        // A fix that timed out keeps the last location; tracking turned off does not.
        cache.write(off, previous: cache.read(), capturedAt: capturedAt.addingTimeInterval(60))
        XCTAssertNil(cache.read()?.payload.latitude)

        let walked = PetContextPayload(latitude: 48.86, longitude: 2.35, stepsToday: 10, timeZone: "UTC")
        cache.write(walked, previous: nil, capturedAt: capturedAt)
        cache.forgetLocation()
        XCTAssertNil(cache.read()?.payload.latitude)
        XCTAssertEqual(cache.read()?.payload.stepsToday, 10)
    }

    func testTheMockTakesThePetOnlyWhereItsRulesAllow() async throws {
        let api = MockStickerAPIClient()
        _ = try await api.installPack(id: PreviewFixtures.pack.id, idempotencyKey: "install-theme-pack")
        _ = try await api.setPet(stickerID: PreviewFixtures.borrowedSticker.id, context: nil)
        let change = try await api.setPetTheme(themeID: "mock-theme-cafe")
        XCTAssertEqual(change.pet?.theme?.id, "mock-theme-cafe")
        XCTAssertEqual(change.themes.activeThemeId, "mock-theme-cafe")

        do {
            _ = try await api.setPetTheme(themeID: "mock-theme-kyoto")
            XCTFail("An expired place cannot be gone back to")
        } catch let error as APIErrorEnvelope {
            XCTAssertEqual(error.error.code, "PET_THEME_EXPIRED")
        }
        let home = try await api.setPetTheme(themeID: nil)
        XCTAssertNil(home.pet?.theme)
    }
}
