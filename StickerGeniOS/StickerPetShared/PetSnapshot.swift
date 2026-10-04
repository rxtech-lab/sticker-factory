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

    func envelope() -> PetSnapshotEnvelope? {
        guard let data = try? Data(contentsOf: envelopeURL) else { return nil }
        return try? PetSnapshotEnvelope.decode(data)
    }

    /// The pet and its picture, or nil when there is no pet or the picture went missing.
    func load() -> (snapshot: PetSnapshot, pose: Data)? {
        guard let snapshot = envelope()?.pet, let pose = try? Data(contentsOf: poseURL) else { return nil }
        return (snapshot, pose)
    }

    /// Writes `envelope`. `pose` replaces the picture when given; a nil pet removes it.
    func save(_ envelope: PetSnapshotEnvelope, pose: Data?) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let pose { try pose.write(to: poseURL, options: .atomic) }
        if envelope.pet == nil { try? FileManager.default.removeItem(at: poseURL) }
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
}
