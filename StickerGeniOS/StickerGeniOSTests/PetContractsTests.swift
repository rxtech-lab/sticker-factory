import Foundation
import XCTest
@testable import StickerGeniOS

@MainActor
final class PetContractsTests: XCTestCase {
    private func petJSON(extra: [String: Any] = [:]) throws -> [String: Any] {
        let pet = Pet(sticker: PreviewFixtures.borrowedSticker, selectedAt: Date(timeIntervalSince1970: 0))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.api.encode(pet)) as? [String: Any])
        for (key, value) in extra { json[key] = value }
        return json
    }

    func testDecodesAPetWithoutTheNewerParts() throws {
        var json = try petJSON()
        json.removeValue(forKey: "identity")
        json.removeValue(forKey: "signals")
        json.removeValue(forKey: "nextEventAt")
        json.removeValue(forKey: "stats")
        let pet = try JSONDecoder.api.decode(Pet.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(pet.identity)
        XCTAssertNil(pet.signals)
        XCTAssertNil(pet.nextEventAt)
        XCTAssertEqual(pet.stats, .initial)
        XCTAssertEqual(pet.maxHp, 100)

        // The server's explicit nulls read the same as absence.
        let nulls = try petJSON(extra: ["identity": NSNull(), "signals": NSNull(), "nextEventAt": NSNull()])
        let fromNulls = try JSONDecoder.api.decode(Pet.self, from: JSONSerialization.data(withJSONObject: nulls))
        XCTAssertNil(fromNulls.identity)
    }

    func testDecodesAPetWithItsIdentityAndWorld() throws {
        let json = try petJSON(extra: [
            "stats": ["happiness": 70, "hp": 150, "energy": 40],
            "identity": [
                "class": "guardian",
                "personality": "Stoic but secretly soft",
                "likes": ["Naps"],
                "dislikes": ["Thunder"],
                "favoriteWeather": "snowy",
                "maxHp": 180,
                "energyMultiplier": 0.8,
                "birth": [
                    "weather": ["kind": "foggy", "temperatureC": 9.5, "isDay": false],
                    "stepsToday": NSNull(),
                    "headlines": [],
                    "at": "2026-10-01T08:00:00.000Z"
                ]
            ],
            "signals": [
                "weather": ["kind": "hurricane", "temperatureC": 30, "isDay": true],
                "stepsToday": 1234,
                "headlines": ["A headline"]
            ],
            "nextEventAt": "2026-10-04T18:30:00.123Z"
        ])
        let pet = try JSONDecoder.api.decode(Pet.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(pet.identity?.petClass, .guardian)
        XCTAssertEqual(pet.identity?.petClass.symbol, "shield.fill")
        XCTAssertEqual(pet.identity?.favoriteWeather, .snowy)
        XCTAssertEqual(pet.maxHp, 180)
        XCTAssertEqual(pet.stats.hp, 150)
        XCTAssertEqual(pet.identity?.energyMultiplier, 0.8)
        XCTAssertEqual(pet.identity?.birth.weather?.kind, .foggy)
        XCTAssertNil(pet.identity?.birth.stepsToday)
        // A weather kind this build does not know still decodes, as itself.
        XCTAssertEqual(pet.signals?.weather?.kind.rawValue, "hurricane")
        XCTAssertEqual(pet.signals?.stepsToday, 1234)
        XCTAssertEqual(pet.signals?.headlines, ["A headline"])
        XCTAssertNotNil(pet.nextEventAt)

        // And it survives a round trip with `class` spelled as the server spells it.
        let encoded = try JSONEncoder.api.encode(pet)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual((object["identity"] as? [String: Any])?["class"] as? String, "guardian")
        XCTAssertEqual(try JSONDecoder.api.decode(Pet.self, from: encoded).identity, pet.identity)
    }

    func testDecodesADiaryPageWithNestedDebugJSON() throws {
        let json = """
        {
          "events": [{
            "id": "11111111-1111-4111-8111-111111111111",
            "kind": "special",
            "title": "Puddle parade",
            "detail": "Splashed around.",
            "effects": {"happiness": 6, "hp": 0, "energy": -4},
            "statsBefore": {"happiness": 74, "hp": 118, "energy": 64},
            "statsAfter": {"happiness": 80, "hp": 118, "energy": 60},
            "signals": null,
            "debug": {"model": {"name": "m", "latencyMs": 412}, "rolls": [0.5, true, null, "x"], "reason": "rain"},
            "createdAt": "2026-10-04T12:00:00.000Z"
          }, {
            "id": "22222222-2222-4222-8222-222222222222",
            "kind": "teleported",
            "title": "Somewhere else",
            "detail": "",
            "effects": {"happiness": 0, "hp": 0, "energy": 0},
            "statsBefore": {"happiness": 74, "hp": 118, "energy": 64},
            "statsAfter": {"happiness": 74, "hp": 118, "energy": 64},
            "signals": {"weather": null, "stepsToday": null, "headlines": []},
            "debug": {},
            "createdAt": "2026-10-04T11:00:00Z"
          }],
          "nextCursor": "abc"
        }
        """
        let page = try JSONDecoder.api.decode(PetEventsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(page.nextCursor, "abc")
        XCTAssertEqual(page.events.count, 2)
        let event = page.events[0]
        XCTAssertEqual(event.kind, .special)
        XCTAssertEqual(event.effects.energy, -4)
        XCTAssertEqual(event.statsAfter.happiness, 80)
        XCTAssertNil(event.signals)
        XCTAssertEqual(event.debug["model"], .object(["name": .string("m"), "latencyMs": .number(412)]))
        XCTAssertEqual(event.debug["rolls"], .array([.number(0.5), .bool(true), .null, .string("x")]))
        let pretty = JSONValue.object(event.debug).prettyPrinted
        XCTAssertTrue(pretty.contains("\"latencyMs\" : 412"), pretty)
        XCTAssertTrue(pretty.contains("\"reason\" : \"rain\""), pretty)

        XCTAssertEqual(page.events[1].kind.rawValue, "teleported")
        XCTAssertEqual(page.events[1].signals, PetSignals())
    }

    func testContextPayloadLeavesOutWhatWasNotCollected() throws {
        let payload = PetContextPayload(stepsToday: 120, timeZone: "Europe/Paris")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.api.encode(payload)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["stepsToday", "timeZone"])

        let request = SetPetRequest(stickerId: "s")
        let requestObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.api.encode(request)) as? [String: Any])
        XCTAssertEqual(Set(requestObject.keys), ["stickerId"])
    }

    func testContextCacheRoundTripsInTheSharedShape() throws {
        let suite = "pet-context-tests-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let cache = PetContextCache(suiteName: suite)
        XCTAssertNil(cache.read())

        let capturedAt = Date(timeIntervalSince1970: 1_790_000_000)
        let payload = PetContextPayload(latitude: 48.86, longitude: 2.35, stepsToday: 4321, timeZone: "Europe/Paris")
        cache.write(payload, previous: nil, capturedAt: capturedAt)
        XCTAssertEqual(cache.read(), PetContextCache.Snapshot(payload: payload, capturedAt: capturedAt))

        // The exact contract the Messages extension decodes.
        let raw = try XCTUnwrap(UserDefaults(suiteName: suite)?.data(forKey: "StickerFactoryPetContext"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        XCTAssertEqual(object["latitude"] as? Double, 48.86)
        XCTAssertEqual(object["longitude"] as? Double, 2.35)
        XCTAssertEqual(object["stepsToday"] as? Int, 4321)
        XCTAssertEqual(object["timeZone"] as? String, "Europe/Paris")
        XCTAssertEqual(object["capturedAt"] as? String, ISO8601DateFormatter().string(from: capturedAt))

        // A later read without a location fix keeps the last one; nil keys are left out.
        let later = capturedAt.addingTimeInterval(60)
        cache.write(PetContextPayload(timeZone: "Europe/Paris"), previous: cache.read(), capturedAt: later)
        XCTAssertEqual(cache.read()?.payload.latitude, 48.86)
        cache.write(PetContextPayload(timeZone: "UTC"), previous: nil, capturedAt: later)
        let sparseData = try XCTUnwrap(UserDefaults(suiteName: suite)?.data(forKey: PetContextCache.key))
        let sparse = try XCTUnwrap(JSONSerialization.jsonObject(with: sparseData) as? [String: Any])
        XCTAssertEqual(Set(sparse.keys), ["timeZone", "capturedAt"])

        cache.clear()
        XCTAssertNil(cache.read())
    }

    func testDiaryPagesThroughTheMockAndAdoptionGivesThePetAnIdentity() async throws {
        let api = MockStickerAPIClient()
        _ = try await api.installPack(id: PreviewFixtures.pack.id, idempotencyKey: "install-pet-pack")
        let pet = try await api.setPet(stickerID: PreviewFixtures.borrowedSticker.id, context: PetContextPayload(timeZone: "UTC"))
        XCTAssertEqual(pet?.identity?.petClass, .explorer)
        XCTAssertEqual(pet?.stats.hp, pet?.maxHp)

        let diary = PetDiaryModel(api: api)
        await diary.reload()
        XCTAssertEqual(diary.events.count, 3)
        XCTAssertNotNil(diary.nextCursor)
        await diary.loadMoreIfNeeded(after: try XCTUnwrap(diary.events.first))
        XCTAssertEqual(diary.events.count, 3, "Only the last row asks for more")
        await diary.loadMoreIfNeeded(after: try XCTUnwrap(diary.events.last))
        XCTAssertEqual(diary.events.count, 5)
        XCTAssertNil(diary.nextCursor)
        XCTAssertEqual(diary.events.last?.kind, .adopted)
    }

    func testThePetMovesOnToEachQueuedLineAtTheChosenPause() throws {
        let said = Date(timeIntervalSince1970: 1_000)
        let status = PetStatus(values: [:], caption: "Hello!", updatedAt: said, musings: [
            PetMusing(text: "Still here.", afterMinutes: 10),
            PetMusing(text: "Getting sleepy…", afterMinutes: 25)
        ])
        XCTAssertEqual(status.caption(at: said.addingTimeInterval(9 * 60)), "Hello!")
        XCTAssertEqual(status.caption(at: said.addingTimeInterval(10 * 60)), "Still here.")
        XCTAssertEqual(status.caption(at: said.addingTimeInterval(34 * 60)), "Still here.")
        // The last line stays until the next mood.
        XCTAssertEqual(status.caption(at: said.addingTimeInterval(5 * 3_600)), "Getting sleepy…")
        XCTAssertEqual(status.captionDates, [said, said.addingTimeInterval(600), said.addingTimeInterval(2_100)])

        let snapshot = PetSnapshot(pet: Pet(sticker: PreviewFixtures.borrowedSticker, selectedAt: said, status: status))
        XCTAssertEqual(snapshot.speaking(at: said.addingTimeInterval(11 * 60)).caption, "Still here.")
        let decoded = try JSONDecoder.api.decode(PetStatus.self, from: Data(
            #"{"values":{},"caption":"Hi","updatedAt":"2026-10-04T00:00:00Z","musings":[{"text":"Yo","afterMinutes":5}]}"#.utf8))
        XCTAssertEqual(decoded.musings, [PetMusing(text: "Yo", afterMinutes: 5)])
    }

    func testDecodesWhatTheWalkPaidAndAnOlderServerThatSaysNothing() throws {
        let paid = try JSONDecoder.api.decode(PetContextStoredResponse.self, from: Data(
            #"{"stored":true,"walk":{"steps":4400,"energy":44,"gold":17}}"#.utf8))
        XCTAssertEqual(paid.walk, PetWalkReward(steps: 4_400, energy: 44, gold: 17))
        XCTAssertNil(try JSONDecoder.api.decode(PetContextStoredResponse.self, from: Data(#"{"stored":true,"walk":null}"#.utf8)).walk)
        XCTAssertNil(try JSONDecoder.api.decode(PetContextStoredResponse.self, from: Data(#"{"stored":false}"#.utf8)).walk)
    }

    func testThePetThanksItsOwnerForTheEnergyAWalkGaveBack() {
        var pet = Pet(sticker: PreviewFixtures.borrowedSticker, selectedAt: Date(timeIntervalSince1970: 0))
        pet.stats.energy = 64
        let walk = PetWalkReward(steps: 4_400, energy: 44, gold: 17)
        let prompt = PetBrain.walkPrompt(walk, pet: pet)
        XCTAssertTrue(prompt.contains("4400 steps"))
        XCTAssertTrue(prompt.contains("44 energy"))
        XCTAssertTrue(prompt.contains("64/100"))
        XCTAssertTrue(prompt.contains("17 gold"))
        // Already full: no energy to mention, only the fun of it.
        let full = PetWalkReward(steps: 500, energy: 0, gold: 2)
        XCTAssertFalse(PetBrain.walkPrompt(full, pet: pet).contains("energy"))
        XCTAssertNotEqual(PetBrain.walkLine(walk), PetBrain.walkLine(full))
    }
}
