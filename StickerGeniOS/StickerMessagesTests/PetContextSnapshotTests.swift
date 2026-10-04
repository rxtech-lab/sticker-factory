import Foundation
import Testing
@testable import StickerMessages

@Suite("Pet context snapshot")
struct PetContextSnapshotTests {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private let newYork = TimeZone(identifier: "America/New_York")!

    /// 2026-10-04 12:00 in Tokyo.
    private var now: Date { date("2026-10-04T03:00:00Z") }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func stored(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    @Test("A fresh snapshot from today passes through whole")
    func freshSnapshot() throws {
        let data = try stored([
            "latitude": 35.68, "longitude": 139.69, "stepsToday": 4210,
            "timeZone": "Asia/Tokyo", "capturedAt": "2026-10-04T01:00:00Z"
        ])
        let snapshot = PetContextSnapshot.resolve(data: data, now: now, currentTimeZone: newYork)
        #expect(snapshot == PetContextSnapshot(latitude: 35.68, longitude: 139.69, stepsToday: 4210, timeZone: "Asia/Tokyo"))
    }

    @Test("Fractional-second timestamps are accepted")
    func fractionalSeconds() throws {
        let data = try stored(["stepsToday": 12, "timeZone": "Asia/Tokyo", "capturedAt": "2026-10-04T01:00:00.123Z"])
        #expect(PetContextSnapshot.resolve(data: data, now: now).stepsToday == 12)
    }

    @Test("Older than a day is ignored entirely, leaving the device's time zone")
    func staleSnapshot() throws {
        let data = try stored([
            "latitude": 35.68, "longitude": 139.69, "stepsToday": 4210,
            "timeZone": "Asia/Tokyo", "capturedAt": "2026-10-03T02:59:00Z"
        ])
        let snapshot = PetContextSnapshot.resolve(data: data, now: now, currentTimeZone: newYork)
        #expect(snapshot == PetContextSnapshot(timeZone: "America/New_York"))
    }

    @Test("Steps from yesterday are dropped, even when the rest is fresh")
    func yesterdaySteps() throws {
        // 23:30 on the 3rd in Tokyo, read at noon on the 4th: under 24 hours, but another day.
        let data = try stored([
            "latitude": 35.68, "longitude": 139.69, "stepsToday": 9000,
            "timeZone": "Asia/Tokyo", "capturedAt": "2026-10-03T14:30:00Z"
        ])
        let snapshot = PetContextSnapshot.resolve(data: data, now: now, currentTimeZone: newYork)
        #expect(snapshot.stepsToday == nil)
        #expect(snapshot.latitude == 35.68)
        #expect(snapshot.timeZone == "Asia/Tokyo")
    }

    @Test("The calendar day is judged in the snapshot's own time zone")
    func dayInSnapshotZone() throws {
        // 03:00Z is 23:00 on the 3rd in New York but noon on the 4th in Tokyo; read two hours later,
        // it is the next day in New York and still the same one in Tokyo.
        let captured = "2026-10-04T03:00:00Z"
        let readAt = date("2026-10-04T05:00:00Z")
        let inNewYork = try stored(["stepsToday": 50, "timeZone": "America/New_York", "capturedAt": captured])
        let inTokyo = try stored(["stepsToday": 50, "timeZone": "Asia/Tokyo", "capturedAt": captured])
        #expect(PetContextSnapshot.resolve(data: inNewYork, now: readAt, currentTimeZone: tokyo).stepsToday == nil)
        #expect(PetContextSnapshot.resolve(data: inTokyo, now: readAt, currentTimeZone: newYork).stepsToday == 50)
    }

    @Test("Without a stored time zone, the device's is used for the day and supplied")
    func missingTimeZone() throws {
        let data = try stored(["stepsToday": 300, "capturedAt": "2026-10-04T01:00:00Z"])
        let snapshot = PetContextSnapshot.resolve(data: data, now: now, currentTimeZone: tokyo)
        #expect(snapshot == PetContextSnapshot(stepsToday: 300, timeZone: "Asia/Tokyo"))
    }

    @Test("A half coordinate is dropped, since the server takes them as a pair")
    func halfCoordinate() throws {
        let data = try stored(["latitude": 35.68, "timeZone": "Asia/Tokyo", "capturedAt": "2026-10-04T01:00:00Z"])
        let snapshot = PetContextSnapshot.resolve(data: data, now: now)
        #expect(snapshot.latitude == nil)
        #expect(snapshot.longitude == nil)
    }

    @Test("Missing, unreadable or future-dated snapshots fall back to the time zone alone")
    func unusable() throws {
        let fallback = PetContextSnapshot(timeZone: "Asia/Tokyo")
        #expect(PetContextSnapshot.resolve(data: nil, now: now, currentTimeZone: tokyo) == fallback)
        #expect(PetContextSnapshot.resolve(data: Data("nope".utf8), now: now, currentTimeZone: tokyo) == fallback)
        let noDate = try stored(["stepsToday": 1])
        #expect(PetContextSnapshot.resolve(data: noDate, now: now, currentTimeZone: tokyo) == fallback)
        let future = try stored(["stepsToday": 1, "capturedAt": "2026-10-04T05:00:00Z"])
        #expect(PetContextSnapshot.resolve(data: future, now: now, currentTimeZone: tokyo) == fallback)
    }

    @Test("Encoding omits absent fields rather than sending null")
    func encodingOmitsNil() throws {
        let data = try JSONEncoder().encode(PetContextSnapshot(timeZone: "Asia/Tokyo"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object.keys.sorted() == ["timeZone"])
    }

    @Test("Reads the app group's key from defaults")
    func readsDefaults() throws {
        let suite = "PetContextSnapshotTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            try stored(["stepsToday": 7, "timeZone": "Asia/Tokyo", "capturedAt": "2026-10-04T01:00:00Z"]),
            forKey: PetContextSnapshot.defaultsKey
        )
        #expect(PetContextSnapshot.current(defaults: defaults, now: now).stepsToday == 7)
    }

    @Test("A pet send carries the context, and leaves it out when there is none")
    func recordPetSendBody() async throws {
        let transport = PetSendBodyTransport()
        let client = StickerLibraryClient(baseURL: URL(string: "https://api.example/")!, transport: transport)
        try await client.recordPetSend(
            stickerID: "s1",
            context: PetContextSnapshot(latitude: 1.5, longitude: 2.5, stepsToday: 10, timeZone: "Asia/Tokyo"),
            accessToken: "token"
        )
        try await client.recordPetSend(stickerID: "s2", context: PetContextSnapshot(), accessToken: "token")
        let bodies = await transport.bodies()
        #expect(bodies.count == 2)
        let first = try #require(try JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any])
        let context = try #require(first["context"] as? [String: Any])
        #expect(first["stickerId"] as? String == "s1")
        #expect(context["latitude"] as? Double == 1.5)
        #expect(context["stepsToday"] as? Int == 10)
        #expect(context["timeZone"] as? String == "Asia/Tokyo")
        let second = try #require(try JSONSerialization.jsonObject(with: bodies[1]) as? [String: Any])
        #expect(second.keys.sorted() == ["stickerId"])
    }
}

private actor PetSendBodyTransport: StickerHTTPTransport {
    private var captured: [Data] = []

    func data(for request: URLRequest) async throws -> StickerHTTPResult {
        captured.append(request.httpBody ?? Data())
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
        return .init(data: Data(#"{"accepted":true}"#.utf8), response: response)
    }

    func bodies() -> [Data] { captured }
}
