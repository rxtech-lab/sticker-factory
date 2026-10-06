import Foundation

/// The pet as the widget and the watch show it: a drawn pose and a few words, nothing to fetch.
///
/// Neither surface can run the animation engine or hold the account's credentials, so the phone
/// writes one of these whenever the pet changes and both read it as it is. The pose itself travels
/// beside it as a PNG the server drew.
nonisolated struct PetSnapshot: Codable, Equatable, Sendable {
    var stickerID: String
    var title: String
    /// The pet's own words about its mood. Nil until it has read a sent sticker.
    var caption: String?
    var statusUpdatedAt: Date?
    var selectedAt: Date
    /// Names the drawn pose: same key, same picture. A new one means the PNG has to be fetched again.
    var poseKey: String
    /// The weather where the owner is, as the pet last read it. Nil without location, and in
    /// snapshots written before the widget showed weather.
    var weather: PetSnapshotWeather? = nil
    /// What the pet says next on its own, counted from `statusUpdatedAt`. Nil in older snapshots.
    var musings: [PetMusing]? = nil

    /// What the pet is saying at `date`: its caption, or the last of its musings due by then.
    func caption(at date: Date) -> String? {
        guard let caption, let statusUpdatedAt else { return caption }
        return PetMusing.line(caption: caption, musings: musings ?? [], since: statusUpdatedAt, at: date)
    }

    /// When each musing takes over from the line before it.
    var musingDates: [Date] {
        guard caption != nil, let statusUpdatedAt else { return [] }
        return PetMusing.dates(of: musings ?? [], since: statusUpdatedAt)
    }

    /// This snapshot as it reads at `date`, for a surface that only shows `caption`.
    func speaking(at date: Date) -> PetSnapshot {
        var snapshot = self
        snapshot.caption = caption(at: date)
        return snapshot
    }

    /// What the server draws the pose from: the revision it plays, and the reading that posed it.
    /// The app and the widget both name a pose this way, so either can tell the other's is current.
    static func poseKey(stickerID: String, revisionID: String?, statusUpdatedAt: Date?) -> String {
        [stickerID, revisionID ?? "", statusUpdatedAt.map { String($0.timeIntervalSince1970) } ?? "default"]
            .joined(separator: "|")
    }
}

/// A line the pet's agent queued to say on its own after its caption, `afterMinutes` after the line
/// before it. The agent picks the pauses (5 to 30 minutes), so every surface can keep the pet talking
/// on schedule without asking the server.
nonisolated struct PetMusing: Codable, Equatable, Sendable {
    var text: String
    var afterMinutes: Int

    /// When each of `musings` takes over, counting from `start`, the moment the caption was said.
    static func dates(of musings: [PetMusing], since start: Date) -> [Date] {
        var date = start
        return musings.map { musing in
            date = date.addingTimeInterval(Double(max(musing.afterMinutes, 1)) * 60)
            return date
        }
    }

    /// The line due at `date`: `caption` until the first musing, then each in turn; the last one stays.
    static func line(caption: String, musings: [PetMusing], since start: Date, at date: Date) -> String {
        Array(zip(musings, dates(of: musings, since: start))).last { $0.1 <= date }?.0.text ?? caption
    }
}

/// The weather beside the pet on the widget: what it is, and the server's drawing of it, if any.
nonisolated struct PetSnapshotWeather: Codable, Equatable, Sendable {
    /// `PetWeatherKind.rawValue`, which the widget does not link; it only shows `symbol`.
    var kind: String
    /// The SF Symbol drawn while there is no drawing, and on surfaces that cannot show one.
    var symbol: String
    var temperatureC: Double
    var isDay: Bool
    /// Names the drawing in the pet's style written beside the pose. Nil until the server drew it.
    var artKey: String?

    /// The symbol for weather of `kind`; a clear night draws the moon rather than the sun.
    static func symbol(kind: String, isDay: Bool) -> String {
        switch kind {
        case "sunny": isDay ? "sun.max.fill" : "moon.stars.fill"
        case "cloudy": "cloud.fill"
        case "rainy": "cloud.rain.fill"
        case "snowy": "cloud.snow.fill"
        case "stormy": "cloud.bolt.rain.fill"
        case "foggy": "cloud.fog.fill"
        case "windy": "wind"
        default: "cloud.sun.fill"
        }
    }
}

/// What the phone last said about the pet, including that there is none.
///
/// "No pet" is written down rather than left as a missing file, so the watch can tell a release
/// from a message that has not arrived yet — and can drop a late one that `writtenAt` has overtaken.
nonisolated struct PetSnapshotEnvelope: Codable, Equatable, Sendable {
    var pet: PetSnapshot?
    var writtenAt: Date

    // Dates keep Foundation's default encoding on purpose: ISO 8601 drops the fraction of a second,
    // and a snapshot that no longer equals itself after a round trip is rewritten on every publish.
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()

    func encoded() throws -> Data { try Self.encoder.encode(self) }

    static func decode(_ data: Data) throws -> PetSnapshotEnvelope { try decoder.decode(Self.self, from: data) }
}

/// The snapshot on disk, in the app group, where a widget extension can read what its app wrote.
///
/// The phone's app and widget share one container; the watch app and its complications share
/// another under the same group name. The pose is written before the envelope that points at it,
/// so a reader never sees a snapshot whose picture is not there yet.
nonisolated struct PetSnapshotStore: Sendable {
    static let appGroupIdentifier = "group.app.rxlab.stickerfactory"

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// The app group's copy, or nil when the process has no app group entitlement.
    init?(fileManager: FileManager = .default) {
        guard let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier) else {
            return nil
        }
        directory = container.appending(path: "Pet", directoryHint: .isDirectory)
    }

    private var envelopeURL: URL { directory.appending(path: "snapshot.json") }
    var poseURL: URL { directory.appending(path: "pose.png") }
    var weatherArtURL: URL { directory.appending(path: "weather.png") }

    func envelope() -> PetSnapshotEnvelope? {
        guard let data = try? Data(contentsOf: envelopeURL) else { return nil }
        return try? PetSnapshotEnvelope.decode(data)
    }

    /// The pet and its picture, or nil when there is no pet or the picture went missing.
    func load() -> (snapshot: PetSnapshot, pose: Data)? {
        guard let snapshot = envelope()?.pet, let pose = try? Data(contentsOf: poseURL) else { return nil }
        return (snapshot, pose)
    }

    /// The drawing of the pet's weather, or nil when there is none on disk.
    func weatherArt() -> Data? {
        guard envelope()?.pet?.weather?.artKey != nil else { return nil }
        return try? Data(contentsOf: weatherArtURL)
    }

    /// Writes `envelope`. `pose` and `weatherArt` replace their pictures when given; a nil pet removes
    /// both, and a snapshot whose weather names no drawing removes the weather's.
    func save(_ envelope: PetSnapshotEnvelope, pose: Data?, weatherArt: Data? = nil) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let pose { try pose.write(to: poseURL, options: .atomic) }
        if let weatherArt { try weatherArt.write(to: weatherArtURL, options: .atomic) }
        if envelope.pet == nil { try? FileManager.default.removeItem(at: poseURL) }
        if envelope.pet?.weather?.artKey == nil { try? FileManager.default.removeItem(at: weatherArtURL) }
        try envelope.encoded().write(to: envelopeURL, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Names shared by the phone and the watch, so the two ends of each channel cannot drift apart.
nonisolated enum PetCompanion {
    /// The phone's home-screen and lock-screen widget.
    static let phoneWidgetKind = "PetWidget"
    /// The watch's complications and Smart Stack widget.
    static let watchWidgetKind = "PetComplication"
    /// WatchConnectivity key carrying an encoded `PetSnapshotEnvelope`.
    static let envelopeKey = "petEnvelope"
    /// WatchConnectivity message the watch sends to ask the phone for the current pet.
    static let requestKey = "requestPet"
    /// The edge the server draws the pose at: sharp on a large widget, small enough to cross to the watch.
    static let poseSize = 320
    /// The edge the server draws the weather at: it sits in a corner of the widget.
    static let weatherArtSize = 192
}
