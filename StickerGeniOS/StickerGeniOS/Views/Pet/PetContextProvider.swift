import CoreLocation
import Foundation
import HealthKit
import Observation
import OSLog

/// Gathers the little the pet knows about its owner's world — steps today, roughly where, and which
/// time zone "today" is in — and hands it to the server and to the Messages extension.
///
/// Nothing here ever asks for a permission on its own. Health and location are requested only from
/// `PetWorldSheet`, when the user taps the button for each; until then, and whenever one is
/// refused, its field is simply left out. Location is the coarse, when-in-use kind and is rounded
/// before it leaves this class: the pet needs the weather, not the street.
///
/// Like `PetCompanionSync`, it is a process-wide seam: the Pet tab, adoption and the app coming
/// forward all go through `shared`, so two triggers at once share one collection.
@MainActor
@Observable
final class PetContextProvider {
    static let shared = PetContextProvider()

    /// How often the app comes forward does not change how often the server hears about it.
    static let minimumUploadInterval: TimeInterval = 30 * 60
    /// Where the time of the last accepted upload is kept, in the app's own defaults.
    nonisolated static let lastUploadKey = "PetContextProvider.lastUploadAt"
    private static let healthRequestedKey = "PetContextProvider.healthRequested"
    private static let log = Logger(subsystem: "app.rxlab.sticker-factory", category: "pet")

    /// Whether the user has been asked for each source — what decides if the Pet tab offers to
    /// connect them. Health never says whether reading was allowed, only whether it was asked.
    private(set) var locationStatus: CLAuthorizationStatus
    private(set) var healthRequested: Bool

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cache: PetContextCache
    @ObservationIgnored private let health: HKHealthStore?
    @ObservationIgnored private let location: PetLocationFetcher
    /// The collection in flight, so the tab loading and the app coming forward share one.
    @ObservationIgnored private var collecting: Task<PetContextPayload, Never>?

    init(defaults: UserDefaults = .standard, cache: PetContextCache = PetContextCache()) {
        self.defaults = defaults
        self.cache = cache
        health = HKHealthStore.isHealthDataAvailable() ? HKHealthStore() : nil
        location = PetLocationFetcher()
        locationStatus = location.authorizationStatus
        healthRequested = defaults.bool(forKey: Self.healthRequestedKey)
        location.onAuthorizationChange = { [weak self] status in self?.locationStatus = status }
    }

    var hasLocationAccess: Bool { locationStatus == .authorizedWhenInUse || locationStatus == .authorizedAlways }
    var canAskForLocation: Bool { locationStatus == .notDetermined }
    var isHealthAvailable: Bool { health != nil }
    /// Something the user has not yet been asked about — the Pet tab's cue to offer the sheet.
    var needsPermissions: Bool { canAskForLocation || (isHealthAvailable && !healthRequested) }

    // MARK: Permissions — only ever from a tap in `PetWorldSheet`

    /// Asks to read step count, and nothing else. Returns whether the question was put; HealthKit
    /// never reveals whether reading was then allowed, so a refusal only shows as no steps.
    @discardableResult
    func requestHealthAccess() async -> Bool {
        guard let health else { return false }
        do {
            try await health.requestAuthorization(toShare: [], read: [HKQuantityType(.stepCount)])
            defaults.set(true, forKey: Self.healthRequestedKey)
            healthRequested = true
            Self.log.info("pet context: health access requested")
            return true
        } catch {
            Self.log.error("pet context: health request failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Asks for when-in-use location. Returns whether it is now allowed.
    @discardableResult
    func requestLocationAccess() async -> Bool {
        let status = await location.requestWhenInUseAuthorization()
        locationStatus = status
        Self.log.info("pet context: location authorization \(status.rawValue, privacy: .public)")
        return hasLocationAccess
    }

    /// Re-reads both, for when the user may have changed them in Settings while away.
    func refreshPermissions() async {
        locationStatus = location.authorizationStatus
        guard let health, !healthRequested else { return }
        // Asked on another install of this build, or before the flag existed.
        let status = try? await health.statusForAuthorizationRequest(toShare: [], read: [HKQuantityType(.stepCount)])
        if status == .unnecessary {
            defaults.set(true, forKey: Self.healthRequestedKey)
            healthRequested = true
        }
    }

    // MARK: Collecting

    /// Reads whatever the user allowed and writes it to the app group for the Messages extension.
    /// Never prompts. `locationTimeout` bounds the one slow part: a fix that is not already fresh.
    func collect(locationTimeout: Duration = .seconds(10)) async -> PetContextPayload {
        if let collecting { return await collecting.value }
        let task = Task { await self.gather(locationTimeout: locationTimeout) }
        collecting = task
        defer { collecting = nil }
        let payload = await task.value
        cache.write(payload, previous: cache.read())
        return payload
    }

    /// What adoption sends as the pet's birth world: the cached context when it is recent, or a
    /// quick read that does not keep the user waiting on a location fix.
    func quickContext() async -> PetContextPayload {
        if let cached = cache.read(), Date().timeIntervalSince(cached.capturedAt) < Self.minimumUploadInterval {
            return cached.payload
        }
        return await collect(locationTimeout: .seconds(3))
    }

    /// Collects and uploads, unless the server heard from this phone in the last half hour.
    /// `force` skips that wait — after the user just connected a source, they expect it to count.
    /// Returns whether the server kept something.
    @discardableResult
    func syncIfNeeded(api: any StickerAPIClientProtocol, force: Bool = false) async -> Bool {
        if !force, let last = defaults.object(forKey: Self.lastUploadKey) as? Date,
           Date().timeIntervalSince(last) < Self.minimumUploadInterval {
            return false
        }
        let payload = await collect()
        guard !payload.isEmpty else { return false }
        do {
            let stored = try await api.updatePetContext(payload)
            // Only a kept upload counts: with no pet yet, the next foreground should try again.
            if stored { defaults.set(Date(), forKey: Self.lastUploadKey) }
            Self.log.info(
                "pet context uploaded: stored=\(stored, privacy: .public) location=\(payload.hasLocation, privacy: .public) steps=\(payload.stepsToday ?? -1, privacy: .public)"
            )
            return stored
        } catch {
            guard !StickerStore.isCancellation(error) else { return false }
            Self.log.error("pet context upload failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func gather(locationTimeout: Duration) async -> PetContextPayload {
        var payload = PetContextPayload(timeZone: TimeZone.current.identifier)
        async let steps = stepsToday()
        async let coordinate = coarseCoordinate(timeout: locationTimeout)
        payload.stepsToday = await steps
        if let coordinate = await coordinate {
            payload.latitude = coordinate.latitude
            payload.longitude = coordinate.longitude
        }
        Self.log.info(
            "pet context collected: steps=\(payload.stepsToday ?? -1, privacy: .public) location=\(payload.hasLocation, privacy: .public) lat=\(payload.latitude ?? 0, privacy: .private) lon=\(payload.longitude ?? 0, privacy: .private)"
        )
        return payload
    }

    /// The day's cumulative step count, or nil when Health is unavailable, never asked, refused, or
    /// simply has nothing for today — none of which the pet should read as "zero steps".
    private func stepsToday() async -> Int? {
        guard let health, healthRequested else { return nil }
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(.stepCount), predicate: HKQuery.predicateForSamples(withStart: start, end: now)),
            options: .cumulativeSum
        )
        do {
            guard let sum = try await descriptor.result(for: health)?.sumQuantity() else { return nil }
            return min(200_000, max(0, Int(sum.doubleValue(for: .count()).rounded())))
        } catch {
            Self.log.error("pet context: steps query failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Where the phone is, to about a kilometre: two decimal places, the same coarseness the server
    /// rounds to before storing it. Nil without permission or without a fix in time.
    private func coarseCoordinate(timeout: Duration) async -> CLLocationCoordinate2D? {
        guard hasLocationAccess, let fix = await location.currentLocation(timeout: timeout) else { return nil }
        func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }
        return CLLocationCoordinate2D(latitude: rounded(fix.coordinate.latitude), longitude: rounded(fix.coordinate.longitude))
    }
}

/// One-shot, reduced-accuracy location for `PetContextProvider`.
///
/// `CLLocationManager` answers through its delegate, so each request parks a continuation that the
/// first fix, the first failure, or the timeout resumes — whichever comes first, exactly once.
@MainActor
final class PetLocationFetcher: NSObject {
    private let manager = CLLocationManager()
    private var fixWaiters: [CheckedContinuation<CLLocation?, Never>] = []
    private var authorizationWaiters: [CheckedContinuation<CLAuthorizationStatus, Never>] = []
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        // The weather where you are is the same a kilometre away; never ask for more than that.
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    /// Prompts for when-in-use access if it was never asked, and returns the answer. Never "always".
    func requestWhenInUseAuthorization() async -> CLAuthorizationStatus {
        guard manager.authorizationStatus == .notDetermined else { return manager.authorizationStatus }
        return await withCheckedContinuation { continuation in
            authorizationWaiters.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    /// A recent cached fix when there is one, otherwise a fresh one bounded by `timeout`.
    func currentLocation(timeout: Duration) async -> CLLocation? {
        if let cached = manager.location, Date().timeIntervalSince(cached.timestamp) < 15 * 60 { return cached }
        return await withCheckedContinuation { continuation in
            fixWaiters.append(continuation)
            if fixWaiters.count == 1 { manager.requestLocation() }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resolveFix(nil)
            }
        }
    }

    private func resolveFix(_ location: CLLocation?) {
        let waiters = fixWaiters
        fixWaiters = []
        for waiter in waiters { waiter.resume(returning: location) }
    }

    private func authorizationChanged(_ status: CLAuthorizationStatus) {
        onAuthorizationChange?(status)
        // The first callback arrives on creation with the current status; only a decided one answers.
        guard status != .notDetermined else { return }
        let waiters = authorizationWaiters
        authorizationWaiters = []
        for waiter in waiters { waiter.resume(returning: status) }
    }
}

extension PetLocationFetcher: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in self.resolveFix(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.resolveFix(nil) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorizationChanged(status) }
    }
}

/// The last collected context, shared with the Messages extension through the app group.
///
/// The extension cannot read Health or ask for location itself, so it sends what the app last saw
/// when it records a sticker send. The contract is fixed — the extension decodes it independently:
/// JSON `Data` under `"StickerFactoryPetContext"` in the `group.app.rxlab.stickerfactory` suite,
/// shaped `{"latitude", "longitude", "stepsToday", "timeZone", "capturedAt"}` with nil keys left
/// out and `capturedAt` an ISO-8601 string (`ISO8601DateFormatter`'s default format).
nonisolated struct PetContextCache: Sendable {
    static let key = "StickerFactoryPetContext"

    /// The stored shape. `capturedAt` stays a string so neither side depends on a decoder's date
    /// strategy to agree.
    struct Entry: Codable, Equatable, Sendable {
        var latitude: Double?
        var longitude: Double?
        var stepsToday: Int?
        var timeZone: String?
        var capturedAt: String
    }

    struct Snapshot: Equatable, Sendable {
        var payload: PetContextPayload
        var capturedAt: Date
    }

    private let suiteName: String

    init(suiteName: String = AppConfiguration.appGroupIdentifier) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults? { UserDefaults(suiteName: suiteName) }

    static func encode(_ payload: PetContextPayload, capturedAt: Date) throws -> Data {
        let entry = Entry(
            latitude: payload.latitude,
            longitude: payload.longitude,
            stepsToday: payload.stepsToday,
            timeZone: payload.timeZone,
            capturedAt: ISO8601DateFormatter().string(from: capturedAt)
        )
        return try JSONEncoder().encode(entry)
    }

    static func decode(_ data: Data) -> Snapshot? {
        guard let entry = try? JSONDecoder().decode(Entry.self, from: data),
              let capturedAt = ISO8601DateFormatter().date(from: entry.capturedAt) else { return nil }
        return Snapshot(
            payload: PetContextPayload(latitude: entry.latitude, longitude: entry.longitude, stepsToday: entry.stepsToday, timeZone: entry.timeZone),
            capturedAt: capturedAt
        )
    }

    /// Writes `payload`. A location that timed out this time keeps the last one rather than
    /// erasing it; steps are only carried over within the same day, since they reset at midnight.
    func write(_ payload: PetContextPayload, previous: Snapshot?, capturedAt: Date = Date()) {
        var merged = payload
        if let previous {
            if !merged.hasLocation, previous.payload.hasLocation {
                merged.latitude = previous.payload.latitude
                merged.longitude = previous.payload.longitude
            }
            if merged.stepsToday == nil, Calendar.current.isDate(previous.capturedAt, inSameDayAs: capturedAt) {
                merged.stepsToday = previous.payload.stepsToday
            }
        }
        guard let data = try? Self.encode(merged, capturedAt: capturedAt) else { return }
        defaults?.set(data, forKey: Self.key)
    }

    func read() -> Snapshot? {
        defaults?.data(forKey: Self.key).flatMap(Self.decode)
    }

    /// Signing out: the next account must not inherit where the last one was.
    func clear() {
        defaults?.removeObject(forKey: Self.key)
        UserDefaults.standard.removeObject(forKey: PetContextProvider.lastUploadKey)
    }
}
