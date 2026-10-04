import Foundation
import Testing
@testable import StickerMessages

@Suite("Pet card payload")
struct PetCardPayloadTests {
    private let sample = PetCardPayload(
        name: "Pip & Co + friends",
        petClass: "explorer",
        personality: "Curious, a little dramatic",
        caption: "It's raining?! 100% cozy = yes",
        happiness: 80,
        hp: 120,
        maxHp: 140,
        energy: 60,
        stickerID: "4d3c5b0e-6a4f-4f0d-9a8e-5b9f2c1d7e11"
    )

    @Test("A card survives a round trip through its URL")
    func roundTrip() throws {
        let url = sample.url
        #expect(url.scheme == "https")
        #expect(url.host() == PetCardPayload.host)
        #expect(url.path() == PetCardPayload.path)
        let decoded = try #require(PetCardPayload(url: url))
        #expect(decoded == sample)
    }

    @Test("A plus sign stays a plus sign")
    func plusIsEncoded() throws {
        let query = try #require(URLComponents(url: sample.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        #expect(!query.contains("+"))
        #expect(PetCardPayload(url: sample.url)?.name == "Pip & Co + friends")
    }

    @Test("Optional fields are left out and come back as nil")
    func optionalFields() throws {
        let bare = PetCardPayload(name: "Pip", happiness: 1, hp: 2, maxHp: 100, energy: 3)
        let items = URLComponents(url: bare.url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? []
        #expect(!items.contains("class"))
        #expect(!items.contains("caption"))
        #expect(!items.contains("stickerId"))
        let decoded = try #require(PetCardPayload(url: bare.url))
        #expect(decoded.petClass == nil)
        #expect(decoded.caption == nil)
        #expect(decoded == bare)
    }

    @Test(
        "Anything that is not a version-1 pet card is rejected",
        arguments: [
            "https://example.com/pet-card?v=1&name=Pip&happiness=1&hp=1&energy=1",
            "http://sticker.rxlab.app/pet-card?v=1&name=Pip&happiness=1&hp=1&energy=1",
            "https://sticker.rxlab.app/pet?v=1&name=Pip&happiness=1&hp=1&energy=1",
            "https://sticker.rxlab.app/pet-card?v=2&name=Pip&happiness=1&hp=1&energy=1",
            "https://sticker.rxlab.app/pet-card?name=Pip&happiness=1&hp=1&energy=1",
            "https://sticker.rxlab.app/pet-card?v=1&happiness=1&hp=1&energy=1",
            "https://sticker.rxlab.app/pet-card?v=1&name=%20%20&happiness=1&hp=1&energy=1",
            "https://sticker.rxlab.app/pet-card?v=1&name=Pip&happiness=lots&hp=1&energy=1",
            "https://sticker.rxlab.app/pet-card?v=1&name=Pip&happiness=1&energy=1",
            "https://sticker.rxlab.app/pet-card",
            "stickerfactory://open"
        ]
    )
    func rejectsMalformed(_ string: String) {
        #expect(PetCardPayload(url: URL(string: string)) == nil)
    }

    @Test("A nil URL is not a card")
    func nilURL() {
        #expect(PetCardPayload(url: nil) == nil)
    }

    @Test("Numbers are clamped and strings truncated, whatever the sender wrote")
    func clampsHostileValues() throws {
        let longName = String(repeating: "N", count: 500)
        var components = URLComponents(string: "https://sticker.rxlab.app/pet-card")!
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "name", value: longName),
            URLQueryItem(name: "name", value: "Override"),
            URLQueryItem(name: "caption", value: "line\u{0007}break"),
            URLQueryItem(name: "happiness", value: "999"),
            URLQueryItem(name: "hp", value: "500"),
            URLQueryItem(name: "maxHp", value: "-4"),
            URLQueryItem(name: "energy", value: "-20")
        ]
        let payload = try #require(PetCardPayload(url: components.url))
        #expect(payload.name.count == PetCardPayload.maximumNameLength)
        #expect(payload.name.allSatisfy { $0 == "N" })
        #expect(payload.caption == "linebreak")
        #expect(payload.happiness == 100)
        #expect(payload.maxHp == 1)
        #expect(payload.hp == 1)
        #expect(payload.energy == 0)
    }

    @Test("A card without a ceiling draws against the default one")
    func missingMaxHp() throws {
        let url = try #require(URL(string: "https://sticker.rxlab.app/pet-card?v=1&name=Pip&happiness=5&hp=80&energy=5"))
        let payload = try #require(PetCardPayload(url: url))
        #expect(payload.maxHp == 100)
        #expect(payload.hp == 80)
    }

    @Test("The stat line shows the ceiling")
    func statLine() {
        #expect(sample.statLine == "♥ 80 · HP 120/140 · ⚡ 60")
    }

    @Test("A card is built from the server's pet, with HP against the class ceiling")
    func fromServerPet() throws {
        let json = Data("""
        {"pet":{"sticker":{"id":"4d3c5b0e-6a4f-4f0d-9a8e-5b9f2c1d7e11","title":"Pip","kind":"animated"},
          "selectedAt":"2026-10-01T00:00:00Z",
          "status":{"values":{},"caption":"Sunny day!","updatedAt":"2026-10-04T00:00:00Z"},
          "stats":{"happiness":80,"hp":120,"energy":60},"actions":[],
          "identity":{"class":"explorer","personality":"Curious","likes":[],"dislikes":[],
            "favoriteWeather":"sunny","maxHp":140,"energyMultiplier":1,\
        "birth":{"weather":null,"stepsToday":null,"headlines":[],"at":"2026-10-01T00:00:00Z"}},
          "signals":{"weather":{"kind":"rainy","temperatureC":18.4,"isDay":true},"stepsToday":4210,"headlines":[]},
          "nextEventAt":null}}
        """.utf8)
        let pet = try #require(try JSONDecoder().decode(MessagesPetEnvelope.self, from: json).pet)
        #expect(pet.signals?.weather?.kind == "rainy")
        let payload = PetCardPayload(pet: pet)
        #expect(payload == sample.with(name: "Pip", personality: "Curious", caption: "Sunny day!"))
    }

    @Test("An older pet with no identity or status still decodes")
    func sparseServerPet() throws {
        let json = Data("""
        {"pet":{"sticker":{"id":"s1","title":""},"status":null,"stats":{"happiness":5,"hp":90,"energy":7},
          "identity":null,"signals":null}}
        """.utf8)
        let pet = try #require(try JSONDecoder().decode(MessagesPetEnvelope.self, from: json).pet)
        #expect(pet.maxHp == 100)
        #expect(pet.caption == nil)
        #expect(PetCardPayload(pet: pet).classLine == nil)
        #expect(try JSONDecoder().decode(MessagesPetEnvelope.self, from: Data(#"{"pet":null}"#.utf8)).pet == nil)
    }
}

private extension PetCardPayload {
    func with(name: String, personality: String, caption: String) -> PetCardPayload {
        PetCardPayload(
            name: name, petClass: petClass, personality: personality, caption: caption,
            happiness: happiness, hp: hp, maxHp: maxHp, energy: energy, stickerID: stickerID
        )
    }
}
