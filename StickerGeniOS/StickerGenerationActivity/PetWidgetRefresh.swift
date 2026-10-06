import Foundation
import OSLog

/// Brings the widget's pet up to date from the server when the app has not done it lately.
///
/// The app writes the snapshot whenever it learns something new (`PetCompanionSync`), but only while
/// it runs: a pet left alone for an afternoon keeps living on the server, and without this the widget
/// would show its morning until the app is opened again. So each time WidgetKit asks for a timeline,
/// a snapshot older than `staleAfter` is fetched again with the credentials the app shares with its
/// extensions, and written back to the app group the same way the app writes it.
///
/// Best effort throughout: signed out, offline or refused, the widget keeps the pet it has.
nonisolated enum PetWidgetRefresh {
    /// A snapshot younger than this is left alone: the app wrote it, and reloaded the widget for it.
    static let staleAfter: TimeInterval = 2 * 60

    private static let log = Logger(subsystem: "app.rxlab.stickerfactory.widget", category: "pet")

    static func refreshIfNeeded() async {
        guard let store = PetSnapshotStore() else { return }
        let current = store.envelope()
        if let current, Date.now.timeIntervalSince(current.writtenAt) < staleAfter { return }
        do {
            let client = try PetWidgetClient()
            guard let pet = try await client.pet() else {
                // Released, or no longer posable. Written down so the widget stops showing it.
                if current?.pet != nil { try save(PetSnapshotEnvelope(pet: nil, writtenAt: .now), over: current, in: store) }
                return
            }
            var snapshot = PetSnapshot(pet)
            // The pose is a server render, so it is fetched only when the pose it names changed.
            let needsPose = current?.pet?.poseKey != snapshot.poseKey || store.load() == nil
            let pose = needsPose ? try await client.image(path: "api/v1/pet/pose", size: PetCompanion.poseSize) : nil
            // The weather's drawing likewise; one that will not come leaves the widget on its symbol.
            var weatherArt: Data?
            if let artKey = snapshot.weather?.artKey,
               current?.pet?.weather?.artKey != artKey || current?.pet?.stickerID != snapshot.stickerID
                || current?.pet?.selectedAt != snapshot.selectedAt || store.weatherArt() == nil {
                weatherArt = try? await client.image(
                    path: "api/v1/pet/weather-art", size: PetCompanion.weatherArtSize, artKey: artKey
                )
                if weatherArt == nil { snapshot.weather?.artKey = nil }
            }
            if current?.pet == snapshot, pose == nil, weatherArt == nil { return }
            try save(PetSnapshotEnvelope(pet: snapshot, writtenAt: .now), pose: pose, weatherArt: weatherArt,
                     over: current, in: store)
        } catch {
            log.error("pet widget refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Writes `envelope` unless the app wrote a newer one while this was fetching; the app's is the
    /// one to keep, and it has already reloaded the widget for it.
    private static func save(
        _ envelope: PetSnapshotEnvelope, pose: Data? = nil, weatherArt: Data? = nil,
        over current: PetSnapshotEnvelope?, in store: PetSnapshotStore
    ) throws {
        guard store.envelope()?.writtenAt == current?.writtenAt else { return }
        try store.save(envelope, pose: pose, weatherArt: weatherArt)
    }
}

/// The two calls the widget makes, authorized like the app's other extensions: the shared token
/// broker, then one forced refresh on a 401 that is abandoned if it lands on a different account.
private nonisolated struct PetWidgetClient: Sendable {
    private let baseURL: URL
    private let broker: SharedTokenBroker
    private let appVersion: String?

    init(bundle: Bundle = .main) throws {
        guard let value = bundle.object(forInfoDictionaryKey: "StickerFactoryAPIBaseURL") as? String,
              let url = URL(string: value), Self.isAllowed(url) else {
            throw PetWidgetClientError.invalidConfiguration
        }
        baseURL = url
        broker = SharedTokenBroker(configuration: try SharedAuthConfiguration(bundle: bundle))
        appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    private static func isAllowed(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
        #if DEBUG
        return url.scheme?.lowercased() == "http" && url.host?.lowercased() == "localhost"
        #else
        return false
        #endif
    }

    /// The account's pet, or nil when it has none.
    func pet() async throws -> PetWidgetPayload.Pet? {
        let data = try await get(path: "api/v1/pet", query: [], accept: "application/json")
        return try PetWidgetPayload.decoder.decode(PetWidgetPayload.self, from: data).pet
    }

    func image(path: String, size: Int, artKey: String? = nil) async throws -> Data {
        var query = [URLQueryItem(name: "size", value: String(size))]
        if let artKey { query.append(URLQueryItem(name: "artKey", value: artKey)) }
        let data = try await get(path: path, query: query, accept: "image/png")
        guard !data.isEmpty else { throw PetWidgetClientError.invalidResponse }
        return data
    }

    private func get(path: String, query: [URLQueryItem], accept: String) async throws -> Data {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw PetWidgetClientError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let appVersion, !appVersion.isEmpty, !appVersion.contains("$(") {
            request.setValue(appVersion, forHTTPHeaderField: "X-iOS-App-Version")
        }
        if let language = Locale.preferredLanguages.first {
            request.setValue(language, forHTTPHeaderField: "Accept-Language")
        }

        let session = try await broker.authenticatedSession()
        var (data, status) = try await send(request, token: session.accessToken)
        if status == 401 || status == 403 {
            let refreshed = try await broker.authenticatedSession(forceRefresh: true)
            guard refreshed.subject == session.subject else { throw PetWidgetClientError.unauthorized }
            (data, status) = try await send(request, token: refreshed.accessToken)
        }
        if status == 401 || status == 403 { throw PetWidgetClientError.unauthorized }
        guard (200..<300).contains(status) else { throw PetWidgetClientError.status(status) }
        return data
    }

    private func send(_ request: URLRequest, token: String) async throws -> (Data, Int) {
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PetWidgetClientError.invalidResponse }
        return (data, http.statusCode)
    }
}

private nonisolated enum PetWidgetClientError: Error {
    case invalidConfiguration
    case invalidResponse
    case unauthorized
    case status(Int)
}

/// Only the parts of `GET /api/v1/pet` the widget draws; the rest of the pet is the app's business.
private nonisolated struct PetWidgetPayload: Decodable, Sendable {
    var pet: Pet?

    struct Pet: Decodable, Sendable {
        var sticker: Sticker
        var selectedAt: Date
        var status: Status?
        var signals: Signals?
        var weatherArt: WeatherArt?
    }

    struct Sticker: Decodable, Sendable {
        var id: String
        var title: String
        var playbackRevisionId: String?
        var activeRevisionId: String?
    }

    struct Status: Decodable, Sendable {
        var caption: String
        var updatedAt: Date
        var musings: [PetMusing]?
    }

    struct Signals: Decodable, Sendable {
        var weather: Weather?
    }

    struct Weather: Decodable, Sendable {
        var kind: String
        var temperatureC: Double
        var isDay: Bool
    }

    struct WeatherArt: Decodable, Sendable {
        var kind: String
        var isDay: Bool
        var key: String
    }

    /// The server's ISO 8601 dates, with or without a fraction of a second.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let whole = ISO8601DateFormatter()
            whole.formatOptions = [.withInternetDateTime]
            if let date = whole.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date")
        }
        return decoder
    }()
}

private extension PetSnapshot {
    /// The snapshot the app would write for this pet; see `PetSnapshot.init(pet:)` in the app.
    nonisolated init(_ pet: PetWidgetPayload.Pet) {
        self.init(
            stickerID: pet.sticker.id,
            title: pet.sticker.title,
            caption: pet.status?.caption,
            statusUpdatedAt: pet.status?.updatedAt,
            selectedAt: pet.selectedAt,
            poseKey: PetSnapshot.poseKey(
                stickerID: pet.sticker.id,
                revisionID: pet.sticker.playbackRevisionId ?? pet.sticker.activeRevisionId,
                statusUpdatedAt: pet.status?.updatedAt
            ),
            weather: pet.signals?.weather.map { weather in
                PetSnapshotWeather(
                    kind: weather.kind,
                    symbol: PetSnapshotWeather.symbol(kind: weather.kind, isDay: weather.isDay),
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
