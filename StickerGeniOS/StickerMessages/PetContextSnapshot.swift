import Foundation

/// The phone's last-known context — where, how far walked today, which time zone — as the main app
/// left it in the app group for this extension to attach to pet sends.
///
/// The extension cannot ask for location or HealthKit itself: an appex gets no permission prompts
/// of its own and Messages can tear it down between sends. So the app writes a snapshot whenever it
/// runs and this reads it back, applying the staleness rules here rather than trusting the writer —
/// a snapshot is only as current as the last time someone opened the app, which can be days.
///
/// Encoded as `PetContextV1` on the wire: every field optional, latitude and longitude together or
/// not at all, and nil keys omitted rather than sent as null (the server's schema is `.strict()`
/// and `.optional()`, which rejects an explicit null).
struct PetContextSnapshot: Codable, Equatable, Sendable {
    var latitude: Double?
    var longitude: Double?
    var stepsToday: Int?
    var timeZone: String?

    /// The app-group key the main app writes, as JSON `Data`.
    static let defaultsKey = "StickerFactoryPetContext"

    /// Past this, a location says where someone *was*, not where they are — and the server would
    /// file the pet's reaction under weather from somewhere else. Dropped wholesale rather than in
    /// part, because nothing in it is still trustworthy.
    static let maximumAge: TimeInterval = 24 * 60 * 60

    var isEmpty: Bool {
        latitude == nil && longitude == nil && stepsToday == nil && timeZone == nil
    }

    /// What the app wrote, stamped with when it captured it.
    private struct Stored: Decodable {
        var latitude: Double?
        var longitude: Double?
        var stepsToday: Int?
        var timeZone: String?
        var capturedAt: String
    }

    /// Reads the app group's snapshot and applies the staleness rules.
    ///
    /// Never nil: with no snapshot at all, the time zone this device is in is still worth sending,
    /// because it is what decides which calendar day the server counts the send toward.
    static func current(
        defaults: UserDefaults? = UserDefaults(suiteName: SharedAuthConfiguration.appGroupIdentifier),
        now: Date = Date()
    ) -> PetContextSnapshot {
        resolve(data: defaults?.data(forKey: defaultsKey), now: now)
    }

    /// The rules, apart from the defaults, so they can be tested with fixed clocks.
    ///
    /// - Older than `maximumAge` (or unreadable, or captured in the future beyond a little clock
    ///   skew): ignored entirely, leaving only the device's time zone.
    /// - `stepsToday` is a count *for a day*; read on a later day it is yesterday's total
    ///   masquerading as today's, so it is dropped unless the capture and now fall on the same
    ///   calendar day in the snapshot's time zone (or this device's when it named none).
    /// - Latitude and longitude survive only as a pair, matching the server's refinement.
    /// - `timeZone` falls back to `TimeZone.current` so it is always present.
    static func resolve(data: Data?, now: Date, currentTimeZone: TimeZone = .current) -> PetContextSnapshot {
        let fallback = PetContextSnapshot(timeZone: currentTimeZone.identifier)
        guard let data,
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let capturedAt = parseDate(stored.capturedAt)
        else { return fallback }

        let age = now.timeIntervalSince(capturedAt)
        // A few minutes of future is clock skew between two processes; more is a bad write.
        guard age <= maximumAge, age >= -5 * 60 else { return fallback }

        let zoneIdentifier = stored.timeZone.flatMap { TimeZone(identifier: $0) != nil ? $0 : nil }
        let zone = zoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? currentTimeZone

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let sameDay = calendar.isDate(capturedAt, inSameDayAs: now)

        var snapshot = PetContextSnapshot(timeZone: zoneIdentifier ?? currentTimeZone.identifier)
        if let latitude = stored.latitude, let longitude = stored.longitude,
           (-90...90).contains(latitude), (-180...180).contains(longitude) {
            snapshot.latitude = latitude
            snapshot.longitude = longitude
        }
        if sameDay, let steps = stored.stepsToday, (0...200_000).contains(steps) {
            snapshot.stepsToday = steps
        }
        return snapshot
    }

    private static func parseDate(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}
