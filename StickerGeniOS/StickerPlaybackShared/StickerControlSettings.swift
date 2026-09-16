import AnimatedView
import CryptoKit
import Foundation

nonisolated struct StickerControlSettings: Codable, Hashable, Sendable {
    enum Mode: String, Codable, Sendable { case single, multiple }
    struct Entry: Codable, Hashable, Identifiable, Sendable {
        var id = UUID()
        var values: [String: AnimatedControlValue]
        var speed: Double
        var signatures: [String: String]

        init(settings: StickerControlSettings) {
            values = settings.values; speed = settings.speed; signatures = settings.signatures
        }
        var settings: StickerControlSettings {
            var result = StickerControlSettings()
            result.values = values; result.speed = speed; result.signatures = signatures
            return result
        }
    }

    var values: [String: AnimatedControlValue] = [:]
    var animate = true
    var speed: Double = 1
    /// A fraction of one rendered cycle. Survives changing the pose's timing.
    var stillPosition: Double = 0
    var signatures: [String: String] = [:]
    var mode: Mode = .single
    var entries: [Entry] = []
    var hasSeededSequence = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case values, animate, speed, stillPosition, signatures, mode, entries, hasSeededSequence
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        values = try c.decodeIfPresent([String: AnimatedControlValue].self, forKey: .values) ?? [:]
        animate = try c.decodeIfPresent(Bool.self, forKey: .animate) ?? true
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        stillPosition = try c.decodeIfPresent(Double.self, forKey: .stillPosition) ?? 0
        signatures = try c.decodeIfPresent([String: String].self, forKey: .signatures) ?? [:]
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .single
        entries = try c.decodeIfPresent([Entry].self, forKey: .entries) ?? []
        hasSeededSequence = try c.decodeIfPresent(Bool.self, forKey: .hasSeededSequence) ?? !entries.isEmpty
    }

    var canPlay: Bool { mode == .single || !entries.isEmpty }

    mutating func selectMode(_ mode: Mode) {
        if mode == .multiple, !hasSeededSequence {
            entries = [.init(settings: self)]
            hasSeededSequence = true
        }
        self.mode = mode
    }

    func reconciled(with document: AnimatedDocument) -> Self {
        var result = self
        guard let configuration = document.configuration else { return .init() }
        let signatures = Self.signatures(configuration)
        let compatible = values.filter { self.signatures[$0.key] == nil || self.signatures[$0.key] == signatures[$0.key] }
        result.values = configuration.normalizedValues(compatible)
        result.signatures = signatures
        result.speed = speed.isFinite ? min(2, max(0.25, speed)) : 1
        result.stillPosition = stillPosition.isFinite ? min(1, max(0, stillPosition)) : 0
        result.entries = entries.map { entry in
            var reconciled = Entry(settings: entry.settings.reconciled(with: document))
            reconciled.id = entry.id
            return reconciled
        }
        return result
    }

    static func defaults(for document: AnimatedDocument) -> Self { Self().reconciled(with: document) }

    func resolvedDocument(_ document: AnimatedDocument) throws -> AnimatedDocument {
        let settings = reconciled(with: document)
        var result = try document.resolvingConfiguration(settings.values)
        if document.configuration?.controls.contains(where: { $0.type == .number && $0.binding == "speed" }) != true {
            result.speed = settings.speed
        }
        return try result.validated()
    }

    func stillTime(in resolved: AnimatedDocument) -> Double {
        let frames = max(1, Int(ceil(resolved.renderedCycleDuration * Double(max(1, resolved.fps)))))
        return Double(Int((Double(frames - 1) * stillPosition).rounded())) / Double(max(1, resolved.fps))
    }

    private static func signatures(_ configuration: AnimatedControlConfiguration) -> [String: String] {
        Dictionary(configuration.controls.map { control in
            let targets = configuration.variants.flatMap { variant in
                variant.selections[control.id] == nil ? [] : variant.layers.map { "\($0.layerId):\($0.source != nil):\($0.animations != nil):\($0.clip != nil):\($0.expression != nil)" }
            }
            return (control.id, "\(control.type.rawValue):\(control.binding ?? ""):\(control.minimum ?? 0):\(control.maximum ?? 0):\((control.layerIds ?? []).sorted()):\(Set(targets).sorted())")
        }, uniquingKeysWith: { _, new in new })
    }
}

/// App and extension use separate process-local defaults objects backed by the same App Group.
nonisolated struct StickerControlPreferences {
    var defaults: UserDefaults?
    init(defaults: UserDefaults? = UserDefaults(suiteName: "group.app.rxlab.stickerfactory")) { self.defaults = defaults }
    func load(accountID: String, stickerID: String, document: AnimatedDocument, explicitValues: [String: AnimatedControlValue] = [:]) -> StickerControlSettings {
        let data = defaults?.data(forKey: key(accountID, stickerID))
        var settings = data.flatMap { try? JSONDecoder().decode(StickerControlSettings.self, from: $0) }?.reconciled(with: document) ?? .defaults(for: document)
        settings.values.merge(explicitValues, uniquingKeysWith: { _, explicit in explicit })
        return settings.reconciled(with: document)
    }
    func save(_ settings: StickerControlSettings, accountID: String, stickerID: String, document: AnimatedDocument) throws {
        let data = try JSONEncoder().encode(settings.reconciled(with: document))
        defaults?.set(data, forKey: key(accountID, stickerID))
    }
    private func key(_ accountID: String, _ stickerID: String) -> String {
        "StickerFactoryControls." + Self.digest("\(accountID):\(stickerID)")
    }
    static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    /// Two renders of the same pose at different rungs are different files, so the rung belongs in
    /// the key. Without it, changing the size a sticker is sent at would go on serving whatever was
    /// already on disk at the old one.
    static func renderKey(accountID: String, stickerID: String, revisionID: String, settings: StickerControlSettings,
                          image: Bool, size: SystemStickerSize = .default) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(settings)
        return digest("sequence-v1:\(accountID):\(stickerID):\(revisionID):\(image):\(size.rawValue):\(data.base64EncodedString())")
    }
}

/// A token belongs to one presentation; cancelling invalidates completions that arrive later.
@MainActor
final class StickerSendSession {
    private(set) var generation = UUID()
    private(set) var isSending = false
    func begin() -> UUID? {
        guard !isSending else { return nil }
        isSending = true
        return generation
    }
    func isCurrent(_ token: UUID) -> Bool { token == generation && isSending }
    func finish(_ token: UUID) { if token == generation { isSending = false } }
    func cancel() { generation = UUID(); isSending = false }

    /// All asynchronous work and the final insertion share one cancellation token.
    func perform<Value>(prepare: () async throws -> Value, validate: () async throws -> Void,
                        insert: (Value) async throws -> Void) async throws {
        guard let token = begin() else { throw CancellationError() }
        defer { finish(token) }
        let value = try await prepare()
        try Task.checkCancellation()
        guard isCurrent(token) else { throw CancellationError() }
        try await validate()
        try Task.checkCancellation()
        guard isCurrent(token) else { throw CancellationError() }
        try await insert(value)
        try Task.checkCancellation()
        guard isCurrent(token) else { throw CancellationError() }
        try await validate()
        try Task.checkCancellation()
        guard isCurrent(token) else { throw CancellationError() }
    }
}
