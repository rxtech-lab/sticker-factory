import Foundation
import UIKit

extension MockStickerAPIClient {
    /// Scheduling and cancelling move the same in-memory state a real account would, so a UI test
    /// can walk the whole round trip — request, see the pending row, keep the account.
    func accountDeletionState() async throws -> AccountDeletionState {
        accountDeletion
    }

    func requestAccountDeletion() async throws -> AccountDeletionState {
        if !accountDeletion.pendingDeletion {
            let now = Date()
            accountDeletion = AccountDeletionState(
                pendingDeletion: true,
                deletionScheduledAt: now.addingTimeInterval(7 * 24 * 60 * 60),
                deletionRequestedAt: now
            )
        }
        return accountDeletion
    }

    func cancelAccountDeletion() async throws -> AccountDeletionState {
        accountDeletion = .none
        return accountDeletion
    }

    func pet() async throws -> Pet? { adoptedPet }

    func interactWithPet(_ action: PetAction) async throws -> Pet? {
        guard var current = adoptedPet else { return nil }
        guard let selected = current.actions?.first(where: { $0.id == action.id }) else { throw StickerAPIError.invalidResponse }
        guard selected.effects.price <= current.stats.gold else {
            throw APIErrorEnvelope(error: .init(
                code: "PET_NOT_ENOUGH_GOLD", message: "Not enough gold.", requestId: "mock-pet", details: nil
            ))
        }
        current.stats.gold = max(0, current.stats.gold + selected.effects.gold)
        current.stats.happiness = min(100, max(0, current.stats.happiness + selected.effects.happiness))
        current.stats.hp = min(current.maxHp, max(0, current.stats.hp + selected.effects.hp))
        current.stats.energy = min(100, max(0, current.stats.energy + selected.effects.energy))
        current.status = PetStatus(values: current.status?.values ?? [:], caption: selected.description, updatedAt: Date())
        adoptedPet = current
        return current
    }

    /// Stands in for the pet's look at a picture: always a little cheered by it.
    func sendPetPhoto(jpeg: Data) async throws -> Pet? {
        guard var current = adoptedPet else {
            throw APIErrorEnvelope(error: .init(code: "PET_NOT_FOUND", message: "Choose a pet first.", requestId: "mock-pet", details: nil))
        }
        current.stats.happiness = min(100, current.stats.happiness + 5)
        current.status = PetStatus(values: current.status?.values ?? [:], caption: "What a lovely picture!", updatedAt: Date())
        adoptedPet = current
        return current
    }

    /// Held to the server's rule — only something in the candidate sections can be adopted — so a
    /// UI test that offers the wrong sticker fails the way the real API would.
    func setPet(stickerID: String, context: PetContextPayload?) async throws -> Pet? {
        let candidates = try await petCandidates(query: nil).sections.flatMap(\.stickers)
        guard let sticker = candidates.first(where: { $0.id == stickerID }) else {
            throw APIErrorEnvelope(error: .init(
                code: "PET_NOT_AVAILABLE",
                message: "Only a published controllable sticker you made or installed can be your pet.",
                requestId: "mock-pet",
                details: nil
            ))
        }
        let actions = [
            PetAction(
                id: "11111111-1111-4111-8111-111111111111",
                title: "Greet \(sticker.title)",
                description: "Say hello to \(sticker.title).",
                effects: .init(happiness: 8, hp: 0, energy: 0)
            ),
            PetAction(
                id: "22222222-2222-4222-8222-222222222222",
                title: "Dance with \(sticker.title)",
                description: "Move together with \(sticker.title).",
                effects: .init(happiness: 14, hp: 0, energy: -12, gold: -5)
            ),
            PetAction(
                id: "44444444-4444-4444-8444-444444444444",
                title: "Buy \(sticker.title) a cake",
                description: "Share a fancy cake with \(sticker.title).",
                effects: .init(happiness: 12, hp: 4, energy: 0, gold: -40)
            ),
            PetAction(
                id: "33333333-3333-4333-8333-333333333333",
                title: "Rest with \(sticker.title)",
                description: "Take a break beside \(sticker.title).",
                effects: .init(happiness: 2, hp: 8, energy: 20)
            )
        ]
        adoptedPet = Pet(
            sticker: sticker,
            selectedAt: Date(),
            stats: PetStats(happiness: 80, hp: Self.sampleIdentity.maxHp, energy: 80, gold: 20),
            actions: actions,
            identity: Self.sampleIdentity,
            signals: Self.sampleSignals,
            nextEventAt: Date().addingTimeInterval(3 * 60 * 60),
            weatherArt: PetWeatherArt(kind: .rainy, isDay: true, key: "mock-rainy-day")
        )
        return adoptedPet
    }

    /// Kept only when there is a pet, like the server.
    func updatePetContext(_ context: PetContextPayload) async throws -> PetContextStoredResponse {
        PetContextStoredResponse(stored: adoptedPet != nil)
    }

    /// A fixed diary in two pages, so the sheet's list, its paging and the debug view all have
    /// something to show in previews and UI tests.
    func petEvents(cursor: String?) async throws -> PetEventsResponse {
        guard adoptedPet != nil else { return PetEventsResponse(events: [], nextCursor: nil) }
        let events = Self.sampleEvents(now: Date())
        if cursor == "mock-page-2" { return PetEventsResponse(events: Array(events.dropFirst(3)), nextCursor: nil) }
        return PetEventsResponse(events: Array(events.prefix(3)), nextCursor: "mock-page-2")
    }

    static let sampleSignals = PetSignals(
        weather: PetWeather(kind: .rainy, temperatureC: 14.5, isDay: true),
        stepsToday: 4_321,
        headlines: ["City opens a new riverside park", "Local bakery wins national award"]
    )

    static let sampleIdentity = PetIdentity(
        petClass: .explorer,
        personality: "Curious and a little dramatic about puddles",
        likes: ["Long walks", "Bubbles", "Rainy days"],
        dislikes: ["Vacuum cleaners", "Mondays"],
        favoriteWeather: .rainy,
        maxHp: 120,
        energyMultiplier: 1.4,
        birth: PetBirth(
            weather: PetWeather(kind: .sunny, temperatureC: 21, isDay: true),
            stepsToday: 1_200,
            headlines: [],
            at: Date(timeIntervalSince1970: 1_790_000_000)
        )
    )

    static func sampleEvents(now: Date) -> [PetEvent] {
        let base = PetStats(happiness: 80, hp: 120, energy: 80)
        func stats(_ happiness: Int, _ hp: Int, _ energy: Int) -> PetStats { PetStats(happiness: happiness, hp: hp, energy: energy) }
        return [
            PetEvent(
                id: "aaaaaaaa-0000-4000-8000-000000000005", kind: .special, title: "Puddle parade",
                detail: "It rained where you are, and your pet splashed through every puddle it could find.",
                effects: .init(happiness: 6, hp: 0, energy: -4), statsBefore: stats(74, 118, 64), statsAfter: stats(80, 118, 60),
                signals: sampleSignals,
                debug: ["workflow": .string("pet-life"), "reason": .string("weather matches favorite"),
                        "model": .object(["name": .string("mock"), "latencyMs": .number(412)]),
                        "rolls": .array([.number(0.12), .number(0.87)]), "special": .bool(true)],
                createdAt: now.addingTimeInterval(-20 * 60)
            ),
            PetEvent(
                id: "aaaaaaaa-0000-4000-8000-000000000004", kind: .interaction, title: "Danced together",
                detail: "Moved together to a song only the two of you could hear.",
                effects: .init(happiness: 14, hp: 0, energy: -17), statsBefore: stats(60, 118, 81), statsAfter: stats(74, 118, 64),
                debug: ["actionId": .string("22222222-2222-4222-8222-222222222222"), "energyMultiplier": .number(1.4)],
                createdAt: now.addingTimeInterval(-2 * 60 * 60)
            ),
            PetEvent(
                id: "aaaaaaaa-0000-4000-8000-000000000003", kind: .send, title: "Saw a sticker go by",
                detail: "You sent a sleepy sticker, and your pet yawned along.",
                effects: .init(happiness: 2, hp: 0, energy: -3), statsBefore: stats(58, 118, 84), statsAfter: stats(60, 118, 81),
                debug: ["stickerTitle": .string("Sleepy Loaf"), "mood": .string("sleepy")],
                createdAt: now.addingTimeInterval(-5 * 60 * 60)
            ),
            PetEvent(
                id: "aaaaaaaa-0000-4000-8000-000000000002", kind: .random, title: "Lost a sock",
                detail: "Searched everywhere for a sock that was never there.",
                effects: .init(happiness: -22, hp: -2, energy: 4), statsBefore: stats(80, 120, 80), statsAfter: stats(58, 118, 84),
                debug: ["roll": .number(0.03), "note": .null],
                createdAt: now.addingTimeInterval(-26 * 60 * 60)
            ),
            PetEvent(
                id: "aaaaaaaa-0000-4000-8000-000000000001", kind: .adopted, title: "Came home",
                detail: "Arrived on a sunny afternoon, ready to explore.",
                effects: .init(happiness: 0, hp: 0, energy: 0), statsBefore: base, statsAfter: base,
                signals: sampleIdentity.birth.signals,
                debug: ["class": .string("explorer"), "maxHp": .number(120)],
                createdAt: now.addingTimeInterval(-3 * 24 * 60 * 60)
            )
        ]
    }

    func clearPet() async throws { adoptedPet = nil }

    /// The weather's symbol in colour, standing in for the server's drawing of it in the pet's style.
    func petWeatherArt(size: Int) async throws -> Data {
        guard let weather = adoptedPet?.signals?.weather, adoptedPet?.weatherArt != nil else {
            throw APIErrorEnvelope(error: .init(
                code: "PET_WEATHER_ART_NOT_READY",
                message: "Your pet's weather has not been drawn yet.",
                requestId: "mock-pet",
                details: nil
            ))
        }
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let configuration = UIImage.SymbolConfiguration(paletteColors: [.white, .systemBlue])
        let symbol = UIImage(systemName: weather.kind.symbol(isDay: weather.isDay), withConfiguration: configuration)
        return UIGraphicsImageRenderer(bounds: bounds, format: format).pngData { _ in
            symbol?.draw(in: bounds.insetBy(dx: bounds.width * 0.08, dy: bounds.height * 0.08))
        }
    }

    func petItemArt(index: Int, size: Int) async throws -> Data {
        guard adoptedPet?.items?.actions.indices.contains(index) == true else {
            throw StickerAPIError.invalidResponse
        }
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        return UIGraphicsImageRenderer(bounds: bounds).pngData { _ in
            UIImage(systemName: "shippingbox.fill")?.draw(in: bounds.insetBy(dx: 12, dy: 12))
        }
    }

    /// A paw on a warm disc, standing in for the server's drawing of the pet.
    func petPose(size: Int) async throws -> Data {
        guard adoptedPet != nil else {
            throw APIErrorEnvelope(error: .init(
                code: "PET_NOT_FOUND", message: "You have not chosen a pet.", requestId: "mock-pet", details: nil
            ))
        }
        petPoseRequests += 1
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: bounds, format: format).pngData { _ in
            UIColor.systemYellow.setFill()
            UIBezierPath(ovalIn: bounds.insetBy(dx: bounds.width * 0.05, dy: bounds.height * 0.05)).fill()
            let paw = UIImage(systemName: "pawprint.fill")?.withTintColor(.black, renderingMode: .alwaysOriginal)
            paw?.draw(in: bounds.insetBy(dx: bounds.width * 0.25, dy: bounds.height * 0.25))
        }
    }

    func petCandidates(query: String?) async throws -> LibrarySectionsResponse {
        let response = if let query, !query.isEmpty {
            try await searchLibrarySections(query: query, status: .published)
        } else {
            try await librarySections(status: .published)
        }
        let sections = response.sections.compactMap { section -> LibrarySection? in
            var copy = section
            copy.stickers = section.stickers.filter(\.isControllable)
            return copy.kind == .mine || !copy.stickers.isEmpty ? copy : nil
        }
        return .init(sections: sections, generatedAt: response.generatedAt)
    }
}
