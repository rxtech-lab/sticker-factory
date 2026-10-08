import AnimatedView
import Foundation

extension StickerAPIClient {
    func animationEngine() async throws -> ControllableEngineID {
        let response: AnimationTestingSettings = try await send(path: "api/v1/account/animation-settings")
        return response.engine
    }
    func setAnimationEngine(_ engine: ControllableEngineID) async throws {
        let _: AnimationTestingSettings = try await send(path: "api/v1/account/animation-settings", method: "PATCH",
            body: AnimationTestingSettings(engine: engine))
    }
    func petScene(id: String, isTheme: Bool) async throws -> SVGSceneDocument? {
        let path = isTheme ? "api/v1/pet/themes/scene" : "api/v1/pet/rooms/scene"
        let response: PetSceneResponse = try await send(path: path, query: [URLQueryItem(name: "id", value: id)])
        guard response.scene?.isValid != false else { throw StickerAPIError.invalidResponse }
        return response.scene
    }

    func pet() async throws -> Pet? {
        let response: PetResponse = try await send(path: "api/v1/pet")
        return response.pet
    }

    func interactWithPet(_ action: PetAction) async throws -> Pet? {
        let response: PetResponse = try await send(
            path: "api/v1/pet/interactions",
            method: "POST",
            body: PetInteractionRequest(actionId: action.id)
        )
        return response.pet
    }

    func resolvePetEncounter(encounterID: String, choiceID: String) async throws -> ResolvePetEncounterResponse {
        try await send(
            path: "api/v1/pet/encounter", method: "POST",
            body: ResolvePetEncounterRequest(encounterId: encounterID, choiceId: choiceID)
        )
    }

    func markPetFriendSeen(friendID: String) async throws -> Pet? {
        let response: PetResponse = try await send(
            path: "api/v1/pet/friends/seen", method: "POST", body: MarkPetFriendSeenRequest(friendId: friendID)
        )
        return response.pet
    }

    func givePetMedicine() async throws -> Pet? {
        let response: PetResponse = try await send(path: "api/v1/pet/medicine", method: "POST")
        return response.pet
    }

    func purchasePetMedicine() async throws -> Pet? {
        let response: PetResponse = try await send(path: "api/v1/pet/medicine/purchase", method: "POST")
        return response.pet
    }

    func purchasePetItem(itemID: String) async throws -> Pet? {
        let response: PetResponse = try await send(
            path: "api/v1/pet/items/purchase", method: "POST", body: PurchasePetItemRequest(itemId: itemID)
        )
        return response.pet
    }

    func useBagItem(_ item: PetAction) async throws -> Pet? {
        let response: PetResponse = try await send(
            path: "api/v1/pet/interactions",
            method: "POST",
            body: PetInteractionRequest(actionId: item.id, fromBag: true)
        )
        return response.pet
    }

    func petRooms() async throws -> PetRooms {
        let response: PetRoomsResponse = try await send(path: "api/v1/pet/rooms")
        return response.rooms
    }

    func purchasePetRoom(roomID: String) async throws -> PetRoomChangeResponse {
        try await send(path: "api/v1/pet/rooms/purchase", method: "POST", body: PurchasePetRoomRequest(roomId: roomID))
    }

    func setPetRoom(roomID: String?) async throws -> PetRoomChangeResponse {
        try await send(path: "api/v1/pet/rooms/active", method: "PUT", body: SetPetRoomRequest(roomId: roomID))
    }

    func petRoomArt(roomID: String) async throws -> Data {
        var request = try await authorizedRequest(path: "api/v1/pet/rooms/art", query: [URLQueryItem(name: "id", value: roomID)])
        request.setValue("image/webp", forHTTPHeaderField: "Accept")
        var (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            request.setValue("Bearer \(try await tokenBroker.validAccessToken(forceRefresh: true))", forHTTPHeaderField: "Authorization")
            (data, response) = try await session.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw StickerAPIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let _: PetResponse = try decode(data, response: response, context: "GET api/v1/pet/rooms/art")
            throw StickerAPIError.invalidResponse
        }
        return data
    }

    func petThemes() async throws -> PetThemes {
        let response: PetThemesResponse = try await send(path: "api/v1/pet/themes")
        return response.themes
    }

    func setPetTheme(themeID: String?) async throws -> PetThemeChangeResponse {
        try await send(path: "api/v1/pet/themes/active", method: "PUT", body: SetPetThemeRequest(themeId: themeID))
    }

    func petThemeArt(themeID: String) async throws -> Data {
        var request = try await authorizedRequest(path: "api/v1/pet/themes/art", query: [URLQueryItem(name: "id", value: themeID)])
        request.setValue("image/webp", forHTTPHeaderField: "Accept")
        var (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            request.setValue("Bearer \(try await tokenBroker.validAccessToken(forceRefresh: true))", forHTTPHeaderField: "Authorization")
            (data, response) = try await session.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw StickerAPIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let _: PetResponse = try decode(data, response: response, context: "GET api/v1/pet/themes/art")
            throw StickerAPIError.invalidResponse
        }
        return data
    }

    func sendPetPhoto(jpeg: Data) async throws -> Pet? {
        // Unbound to any sticker, so the server's sweep of stale uploads clears it within a day.
        let assetID = try await upload(
            data: jpeg, stickerID: nil, kind: .reference, filename: "pet-photo.jpg", mimeType: "image/jpeg",
            sequence: nil, idempotencyKey: UUID().uuidString
        )
        let response: PetResponse = try await send(path: "api/v1/pet/photos", method: "POST", body: SendPetPhotoRequest(assetId: assetID))
        return response.pet
    }

    func setPet(stickerID: String, context: PetContextPayload?) async throws -> Pet? {
        let response: PetResponse = try await send(
            path: "api/v1/pet", method: "PUT",
            // The server refuses an empty context object no more than a missing one, but there is
            // nothing to record in one, so it is left out.
            body: SetPetRequest(stickerId: stickerID, context: context?.isEmpty == false ? context : nil)
        )
        return response.pet
    }

    func updatePetContext(_ context: PetContextPayload) async throws -> PetContextStoredResponse {
        try await send(path: "api/v1/pet/context", method: "PUT", body: context)
    }

    func petEvents(cursor: String?) async throws -> PetEventsResponse {
        var items = [URLQueryItem(name: "limit", value: "30")]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await send(path: "api/v1/pet/events", query: items)
    }

    func petMemories(about query: String?) async throws -> [PetMemory] {
        var items = [URLQueryItem(name: "limit", value: "5")]
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        let response: PetMemoriesResponse = try await send(path: "api/v1/pet/memories", query: items)
        return response.memories
    }

    @discardableResult
    func rememberPetTalk(words: String, reply: String?) async throws -> Pet? {
        let response: RememberPetTalkResponse = try await send(
            path: "api/v1/pet/talks", method: "POST", body: RememberPetTalkRequest(words: words, reply: reply)
        )
        return response.pet
    }

    func petTouchPose(_ touch: PetTouch, shown: [String: AnimatedControlValue]) async throws -> [String: AnimatedControlValue] {
        let response: PetTouchResponse = try await send(
            path: "api/v1/pet/touch", method: "POST", body: PetTouchRequest(touch: touch.wireName, pose: shown.isEmpty ? nil : shown)
        )
        return response.values
    }

    func clearPet() async throws {
        let _: PetResponse = try await send(path: "api/v1/pet", method: "DELETE")
    }

    func petCandidates(query: String?) async throws -> LibrarySectionsResponse {
        var items = [URLQueryItem(name: "status", value: "published"), URLQueryItem(name: "controllable", value: "1")]
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        return try await send(path: "api/v1/library/sections", query: items)
    }

    func petPose(size: Int) async throws -> Data {
        try await petImage(path: "api/v1/pet/pose", size: size)
    }

    func petWeatherArt(size: Int) async throws -> Data {
        try await petImage(path: "api/v1/pet/weather-art", size: size)
    }

    func petWeatherArt(size: Int, artKey: String) async throws -> Data {
        try await petImage(path: "api/v1/pet/weather-art", size: size, artKey: artKey)
    }

    func petWindowWeatherArt(size: Int, artKey: String) async throws -> Data {
        try await petImage(path: "api/v1/pet/weather-art", size: size, artKey: artKey, layer: "window")
    }

    func petItemArt(index: Int, size: Int) async throws -> Data {
        try await petImage(path: "api/v1/pet/items/art", size: size, index: index, mimeType: "image/webp")
    }

    func petItemArt(index: Int, size: Int, artKey: String) async throws -> Data {
        try await petImage(path: "api/v1/pet/items/art", size: size, index: index, artKey: artKey, mimeType: "image/webp")
    }

    func petItemArt(itemID: String, size: Int) async throws -> Data {
        try await petImage(path: "api/v1/pet/items/art", size: size, item: itemID, mimeType: "image/webp")
    }

    /// Artwork the server draws for the pet, `size` pixels square.
    private func petImage(
        path: String, size: Int, index: Int? = nil, artKey: String? = nil, layer: String? = nil, item: String? = nil,
        mimeType: String = "image/png"
    ) async throws -> Data {
        var query = [URLQueryItem(name: "size", value: String(size))]
        if let item { query.append(URLQueryItem(name: "item", value: item)) }
        if let layer { query.append(URLQueryItem(name: "layer", value: layer)) }
        if let index { query.append(URLQueryItem(name: "index", value: String(index))) }
        if let artKey { query.append(URLQueryItem(name: "artKey", value: artKey)) }
        var request = try await authorizedRequest(path: path, query: query)
        request.setValue(mimeType, forHTTPHeaderField: "Accept")
        var (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            request.setValue("Bearer \(try await tokenBroker.validAccessToken(forceRefresh: true))", forHTTPHeaderField: "Authorization")
            (data, response) = try await session.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw StickerAPIError.invalidResponse }
        // A refusal is the usual JSON envelope; let `decode` turn it into the server's own words.
        guard (200...299).contains(http.statusCode) else {
            let _: PetResponse = try decode(data, response: response, context: "GET \(path)")
            throw StickerAPIError.invalidResponse
        }
        return data
    }
}
