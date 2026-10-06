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

    func pet() async throws -> Pet? {
        if adoptedPet == nil, !hasSeededFriendPet, ProcessInfo.processInfo.arguments.contains("--ui-pet-friend") {
            hasSeededFriendPet = true
            _ = try await setPet(stickerID: "sticker-borrowed", context: nil)
        }
        return adoptedPet
    }

    func markPetFriendSeen(friendID: String) async throws -> Pet? {
        guard var current = adoptedPet else { return nil }
        if current.friend?.id == friendID { current.friend = nil }
        adoptedPet = current
        return current
    }

    func interactWithPet(_ action: PetAction) async throws -> Pet? {
        guard var current = adoptedPet else { return nil }
        let offered = (current.actions ?? []) + (current.items?.actions ?? [])
        guard let selected = offered.first(where: { $0.id == action.id }) else { throw StickerAPIError.invalidResponse }
        guard selected.effects.price <= current.stats.gold else { throw Self.notEnoughGold }
        current.stats.gold = max(0, current.stats.gold + selected.effects.gold)
        Self.apply(selected, to: &current)
        adoptedPet = current
        return current
    }

    /// Like the server: a dose of medicine goes in the bag, and so does anything bought from the shop,
    /// keeping as long as the item does.
    func purchasePetMedicine() async throws -> Pet? {
        guard var current = adoptedPet else { return nil }
        let price = current.medicinePrice ?? 0
        guard price <= current.stats.gold else { throw Self.notEnoughGold }
        current.stats.gold -= price
        current.medicine += 1
        adoptedPet = current
        return current
    }

    func purchasePetItem(itemID: String) async throws -> Pet? {
        guard var current = adoptedPet else { return nil }
        guard var item = current.items?.actions.first(where: { $0.id == itemID }) else {
            throw APIErrorEnvelope(error: .init(
                code: "PET_ITEM_NOT_AVAILABLE", message: "This item is no longer in the shop.", requestId: "mock-pet", details: nil
            ))
        }
        guard item.effects.price <= current.stats.gold else { throw Self.notEnoughGold }
        current.stats.gold -= item.effects.price
        item.leavesAt = nil
        let expiresAt = item.keepsHours.map { Date().addingTimeInterval(Double($0) * 3600) }
        if let index = current.bag.firstIndex(where: { $0.id == itemID }) {
            current.bag[index].count += 1
            if let expiresAt, current.bag[index].expiresAt == nil || expiresAt < current.bag[index].expiresAt! {
                current.bag[index].expiresAt = expiresAt
            }
        } else {
            current.bag.append(PetBagEntry(item: item, count: 1, expiresAt: expiresAt))
        }
        adoptedPet = current
        return current
    }

    func useBagItem(_ item: PetAction) async throws -> Pet? {
        guard var current = adoptedPet, let index = current.bag.firstIndex(where: { $0.id == item.id }) else {
            throw StickerAPIError.invalidResponse
        }
        Self.apply(current.bag[index].item, to: &current)
        current.bag[index].count -= 1
        if current.bag[index].count == 0 { current.bag.remove(at: index) }
        adoptedPet = current
        return current
    }

    func petItemArt(itemID: String, size: Int) async throws -> Data {
        let known = adoptedPet?.bag.contains(where: { $0.id == itemID }) == true
            || adoptedPet?.items?.actions.contains(where: { $0.id == itemID }) == true
        guard known else { throw StickerAPIError.invalidResponse }
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        return UIGraphicsImageRenderer(bounds: bounds).pngData { _ in
            UIImage(systemName: "takeoutbag.and.cup.and.straw.fill")?.draw(in: bounds.insetBy(dx: 12, dy: 12))
        }
    }

    private static let notEnoughGold = APIErrorEnvelope(error: .init(
        code: "PET_NOT_ENOUGH_GOLD", message: "Not enough gold.", requestId: "mock-pet", details: nil
    ))

    /// What an action or item does to the pet's stats and line, gold aside.
    private static func apply(_ selected: PetAction, to current: inout Pet) {
        current.stats.happiness = min(100, max(0, current.stats.happiness + selected.effects.happiness))
        current.stats.hp = min(current.maxHp, max(0, current.stats.hp + selected.effects.hp))
        current.stats.energy = min(100, max(0, current.stats.energy + selected.effects.energy))
        current.status = PetStatus(values: current.status?.values ?? [:], caption: selected.description, updatedAt: Date())
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
            weatherArt: PetWeatherArt(kind: .rainy, isDay: true, key: "mock-rainy-day"),
            medicinePrice: 10,
            windowWeatherArt: PetWeatherArt(kind: .rainy, isDay: true, key: "mock-rainy-day-window")
        )
        if ProcessInfo.processInfo.arguments.contains("--ui-pet-friend") {
            // The pet comes home having made a friend, for the welcome to greet.
            adoptedPet?.friend = PetFriend(
                id: "99999999-9999-4999-8999-999999999999", name: "Puddle",
                story: "We met splashing by the window when the rain started.",
                greeting: "This is Puddle! We splashed together all afternoon.",
                sticker: sticker, metAt: Date()
            )
        }
        adoptedPet?.items = PetItems(actions: [
            PetAction(
                id: "55555555-5555-4555-8555-555555555555", title: "Puddle boots",
                description: "Stomp through puddles with \(sticker.title).",
                effects: .init(happiness: 6, hp: 0, energy: -4), kind: .toy,
                leavesAt: Date().addingTimeInterval(30 * 3600), keepsHours: nil
            ),
            PetAction(
                id: "66666666-6666-4666-8666-666666666666", title: "Berry pie",
                description: "Share a warm berry pie with \(sticker.title).",
                effects: .init(happiness: 5, hp: 4, energy: -3, gold: -8), kind: .food,
                leavesAt: Date().addingTimeInterval(14 * 3600), keepsHours: 10
            ),
            PetAction(
                id: "77777777-7777-4777-8777-777777777777", title: "Aquarium ticket",
                description: "A day among the fish with \(sticker.title).",
                effects: .init(happiness: 10, hp: 0, energy: -8, gold: -12), kind: .ticket,
                leavesAt: Date().addingTimeInterval(72 * 3600), keepsHours: 120
            ),
            PetAction(
                id: "88888888-8888-4888-8888-888888888888", title: "Star tonic",
                description: "A sparkling tonic that wakes \(sticker.title) right up.",
                effects: .init(happiness: 2, hp: 0, energy: 40, gold: -35), kind: .food,
                leavesAt: Date().addingTimeInterval(100 * 3600), keepsHours: 240
            )
        ], artKey: "99999999-9999-4999-8999-999999999999")
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
        headlines: ["City opens a new riverside park", "Local bakery wins national award"],
        tomorrow: PetForecast(kind: .rainy, minC: 6, maxC: 11, precipitationChance: 80)
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

    static let sampleRooms: [PetRoom] = [
        PetRoom(id: "mock-room-burrow", title: "Moss Burrow", description: "A soft, quiet den for long naps.",
                effects: .init(happiness: 1, hp: 0, energy: 5), price: 15, artKey: "mock-room-burrow", owned: false,
                fixtures: mockRoomFixtures(hue: 0.3)),
        PetRoom(id: "mock-room-garden", title: "Rooftop Garden", description: "Sun, flowers and a breeze.",
                effects: .init(happiness: 6, hp: 0, energy: -2), price: 90, artKey: "mock-room-garden", owned: false,
                fixtures: mockRoomFixtures(hue: 0.12)),
        PetRoom(id: "mock-room-spring", title: "Crystal Spring", description: "Healing water to soak in.",
                effects: .init(happiness: 0, hp: 6, energy: 1), price: 120, artKey: "mock-room-spring", owned: false,
                fixtures: mockRoomFixtures(hue: 0.55))
    ]

    private var mockRooms: PetRooms {
        PetRooms(
            activeRoomId: adoptedPet?.room?.id,
            owned: petRoomList.filter(\.owned), offers: petRoomList.filter { !$0.owned },
            offersRefreshAt: Date().addingTimeInterval(20 * 60 * 60), drawing: false
        )
    }

    func petRooms() async throws -> PetRooms { mockRooms }

    func purchasePetRoom(roomID: String) async throws -> PetRoomChangeResponse {
        guard var pet = adoptedPet else {
            throw APIErrorEnvelope(error: .init(code: "PET_NOT_FOUND", message: "Choose a pet first.", requestId: "mock-pet", details: nil))
        }
        guard let index = petRoomList.firstIndex(where: { $0.id == roomID && !$0.owned }) else {
            throw APIErrorEnvelope(error: .init(
                code: "PET_ROOM_OWNED", message: "You already have this room.", requestId: "mock-pet", details: nil
            ))
        }
        let room = petRoomList[index]
        guard room.price <= pet.stats.gold else {
            throw APIErrorEnvelope(error: .init(
                code: "PET_NOT_ENOUGH_GOLD", message: "Not enough gold.", requestId: "mock-pet", details: nil
            ))
        }
        petRoomList[index].owned = true
        pet.stats.gold -= room.price
        pet.room = room.ref
        adoptedPet = pet
        return PetRoomChangeResponse(pet: pet, rooms: mockRooms)
    }

    func setPetRoom(roomID: String?) async throws -> PetRoomChangeResponse {
        guard var pet = adoptedPet else {
            throw APIErrorEnvelope(error: .init(code: "PET_NOT_FOUND", message: "Choose a pet first.", requestId: "mock-pet", details: nil))
        }
        if let roomID {
            guard let room = petRoomList.first(where: { $0.id == roomID && $0.owned }) else {
                throw APIErrorEnvelope(error: .init(
                    code: "PET_ROOM_NOT_FOUND", message: "Buy this room before moving your pet in.", requestId: "mock-pet", details: nil
                ))
            }
            pet.room = room.ref
        } else {
            pet.room = nil
        }
        adoptedPet = pet
        return PetRoomChangeResponse(pet: pet, rooms: mockRooms)
    }

    /// A sky and a floor in a colour of the room's own, portrait like the server's drawings.
    func petRoomArt(roomID: String) async throws -> Data {
        guard let index = petRoomList.firstIndex(where: { $0.id == roomID }) else { throw StickerAPIError.invalidResponse }
        let hues: [CGFloat] = [0.3, 0.12, 0.55]
        let hue = hues[index % hues.count]
        let bounds = CGRect(x: 0, y: 0, width: 384, height: 576)
        return UIGraphicsImageRenderer(bounds: bounds).pngData { context in
            UIColor(hue: hue, saturation: 0.25, brightness: 0.95, alpha: 1).setFill()
            context.fill(bounds)
            UIColor(hue: hue, saturation: 0.4, brightness: 0.7, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: bounds.height * 0.66, width: bounds.width, height: bounds.height * 0.34))
            // A clock and a weather board, blank as the server leaves them, where `mockRoomFixtures` says.
            let rim = UIColor(hue: hue, saturation: 0.5, brightness: 0.35, alpha: 1)
            let face = UIColor(red: 0.95, green: 0.92, blue: 0.86, alpha: 1)
            rim.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 53, y: 95, width: 53, height: 55))
            context.fill(CGRect(x: 291, y: 190, width: 76, height: 59))
            context.fill(CGRect(x: 82, y: 339, width: 220, height: 104))
            face.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 59, y: 101, width: 41, height: 43))
            context.fill(CGRect(x: 297, y: 196, width: 64, height: 47))
            context.fill(CGRect(x: 88, y: 345, width: 208, height: 92))
        }
    }

    /// Where `petRoomArt` and `petThemeArt` draw each mock room's and place's clock face, weather
    /// board and status board.
    static func mockRoomFixtures(hue: CGFloat) -> PetRoomFixtures {
        let ink = UIColor(hue: hue, saturation: 0.5, brightness: 0.35, alpha: 1)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        ink.getRed(&red, green: &green, blue: &blue, alpha: nil)
        let inkHex = String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
        return PetRoomFixtures(
            clock: PetRoomFixture(x: 59 / 384, y: 101 / 576, width: 41 / 384, height: 43 / 576,
                                  shape: .round, face: "#F2EBDB", ink: inkHex),
            weather: PetRoomFixture(x: 297 / 384, y: 196 / 576, width: 64 / 384, height: 47 / 576,
                                    shape: .rect, face: "#F2EBDB", ink: inkHex),
            status: PetRoomFixture(x: 88 / 384, y: 345 / 576, width: 208 / 384, height: 92 / 576,
                                   shape: .rect, face: "#F2EBDB", ink: inkHex)
        )
    }

    /// Four symbols in a 2×2 grid, standing in for the server's sheet of sky pieces in the pet's style.
    func petWindowWeatherArt(size: Int, artKey: String) async throws -> Data {
        guard let weather = adoptedPet?.signals?.weather, adoptedPet?.windowWeatherArt?.key == artKey else {
            throw APIErrorEnvelope(error: .init(
                code: "PET_WEATHER_ART_NOT_READY",
                message: "Your pet's weather has not been drawn yet.",
                requestId: "mock-pet",
                details: nil
            ))
        }
        let particle = switch weather.kind {
        case .snowy: "snowflake"
        case .windy: "leaf.fill"
        case .rainy, .stormy: "drop.fill"
        case .sunny: weather.isDay ? "bird.fill" : "sparkle"
        default: "circle.fill"
        }
        let names = [weather.kind.symbol(isDay: weather.isDay), "cloud.fill", "cloud.fill", particle]
        let cell = CGFloat(size) / 2
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let configuration = UIImage.SymbolConfiguration(paletteColors: [.white, .systemBlue])
        return UIGraphicsImageRenderer(bounds: CGRect(x: 0, y: 0, width: size, height: size), format: format).pngData { _ in
            for (index, name) in names.enumerated() {
                let frame = CGRect(x: CGFloat(index % 2) * cell, y: CGFloat(index / 2) * cell, width: cell, height: cell)
                UIImage(systemName: name, withConfiguration: configuration)?.draw(in: frame.insetBy(dx: cell * 0.1, dy: cell * 0.1))
            }
        }
    }

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
