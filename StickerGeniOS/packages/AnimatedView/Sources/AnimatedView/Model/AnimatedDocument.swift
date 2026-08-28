import Foundation

/// The canonical, data-only animation contract.
///
/// A document is a pure value: given the same document, time, and assets, every renderer in the
/// system — this package, the exporter, and the web preview — must produce the same pixels. That is
/// what lets an animation be authored on a server, previewed in a browser, played on a phone, and
/// exported to a GIF without anyone re-deriving the motion.
///
/// Coordinates are normalized and keyframe times are absolute seconds.
public struct AnimatedDocument: Codable, Hashable, Sendable {
    public static let currentVersion = 3
    /// Versions this build can read. v3 only *added* the `sequence` layer, so a v2 document is
    /// already a valid v3 one and needs no rewriting — accepting it is the whole migration.
    public static let readableVersions: ClosedRange<Int> = 2...3
    public static let maximumLayerCount = 12
    public static let maximumKeyframeCount = 128
    public static let durationRange: ClosedRange<Double> = 0.1...30
    public static let speedRange: ClosedRange<Double> = 0.1...8
    public static let fpsRange: ClosedRange<Int> = 1...60

    public var version: Int
    public var canvas: AnimatedCanvas
    public var kind: AnimatedKind
    /// The authored length of one cycle, before `speed`.
    public var durationSeconds: Double
    public var fps: Int
    public var loop: AnimatedLoop
    /// A playback multiplier. It never touches keyframe times — it divides elapsed time on the way
    /// into the interpolator, so `2` plays the same motion twice as fast. Keeping it out of the
    /// keyframes is what lets speed change without recompiling, and what lets the same compiled
    /// document be exported at two different speeds.
    public var speed: Double
    /// Part of the artwork: renders into every output, including the transparent ones. Defaults to
    /// `.none` because a sticker is transparent unless its author says otherwise.
    public var background: AnimatedBackground
    /// Fills the alpha only for formats that cannot carry it, such as MP4.
    public var mp4Background: AnimatedBackground
    public var layers: [AnimatedLayer]

    public init(
        version: Int = Self.currentVersion,
        canvas: AnimatedCanvas = .init(),
        kind: AnimatedKind,
        durationSeconds: Double? = nil,
        fps: Int? = nil,
        loop: AnimatedLoop? = nil,
        speed: Double = 1,
        background: AnimatedBackground = .none,
        mp4Background: AnimatedBackground = .solid("#FFFFFF"),
        layers: [AnimatedLayer]
    ) {
        self.version = version
        self.canvas = canvas
        self.kind = kind
        self.durationSeconds = durationSeconds ?? (kind == .animated ? 2 : 0)
        self.fps = fps ?? (kind == .animated ? 30 : 0)
        self.loop = loop ?? (kind == .animated ? .loop : .once)
        self.speed = speed
        self.background = background
        self.mp4Background = mp4Background
        self.layers = layers
    }

    private enum CodingKeys: String, CodingKey {
        case version, canvas, kind, durationSeconds, fps, loop, speed, background, mp4Background, layers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.value(.version, default: Self.currentVersion)
        canvas = try c.value(.canvas, default: .init())
        kind = try c.decode(AnimatedKind.self, forKey: .kind)
        durationSeconds = try c.value(.durationSeconds, default: kind == .animated ? 2 : 0)
        fps = try c.value(.fps, default: kind == .animated ? 30 : 0)
        loop = try c.value(.loop, default: kind == .animated ? .loop : .once)
        speed = try c.value(.speed, default: 1)
        background = try c.value(.background, default: .none)
        mp4Background = try c.decodeIfPresent(MP4Background.self, forKey: .mp4Background)?.value ?? .solid("#FFFFFF")
        layers = try c.value(.layers, default: [])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(canvas, forKey: .canvas)
        try c.encode(kind, forKey: .kind)
        try c.encode(durationSeconds, forKey: .durationSeconds)
        try c.encode(fps, forKey: .fps)
        try c.encode(loop, forKey: .loop)
        try c.encode(speed, forKey: .speed)
        try c.encode(background, forKey: .background)
        try c.encode(MP4Background(mp4Background), forKey: .mp4Background)
        try c.encode(layers, forKey: .layers)
    }

    /// The MP4 fill, which travels in a narrower shape than the artwork background.
    ///
    /// The two fields are the same type in this package but not on the wire. `background` is a full
    /// gradient with located stops; `mp4Background` is only ever a flat colour or a two-colour ramp,
    /// so the contract spells it `colors: [from, to]` and rejects anything else. Decoding it as an
    /// artwork background made every document with a gradient MP4 fill fail to decode outright —
    /// not the field, the whole document — and encoding one back made the server reject the save.
    ///
    /// Both shapes are read so a document written by either side still loads.
    private struct MP4Background: Codable {
        var value: AnimatedBackground

        init(_ value: AnimatedBackground) { self.value = value }

        private enum CodingKeys: String, CodingKey { case type, color, colors, stops, angleDegrees }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let colors = try container.decodeIfPresent([String].self, forKey: .colors)
            guard try container.decode(String.self, forKey: .type) == "linearGradient",
                  let colors, colors.count >= 2
            else {
                value = try AnimatedBackground(from: decoder)
                return
            }
            value = .linearGradient(
                stops: colors.enumerated().map {
                    .init(color: $0.element, location: Double($0.offset) / Double(colors.count - 1))
                },
                angleDegrees: try container.decodeIfPresent(Double.self, forKey: .angleDegrees) ?? 0
            )
        }

        func encode(to encoder: Encoder) throws {
            guard case .linearGradient(let stops, let angleDegrees) = value,
                  let first = stops.first, let last = stops.last, stops.count >= 2
            else {
                // `.solid` is the only other shape the contract accepts, and it encodes identically
                // either way. Anything else can only come from a locally built document, and is
                // written in its own shape rather than silently flattened into a colour.
                try value.encode(to: encoder)
                return
            }
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("linearGradient", forKey: .type)
            try container.encode([first.color, last.color], forKey: .colors)
            // The MP4 contract takes a compass bearing, not a signed rotation.
            try container.encode((angleDegrees.truncatingRemainder(dividingBy: 360) + 360)
                .truncatingRemainder(dividingBy: 360), forKey: .angleDegrees)
        }
    }

    // MARK: - Derived timing

    /// The authored duration divided by `speed` — how long one cycle actually takes on screen.
    public var playbackDuration: Double {
        guard kind == .animated, speed > 0 else { return 0 }
        return durationSeconds / speed
    }

    /// The wall-clock length of one full visible cycle, which for ping-pong is there and back.
    ///
    /// This is the number the exporter must use to decide how many frames to write, and the number
    /// the server must expect back when it validates an uploaded rendition.
    public var renderedCycleDuration: Double {
        loop == .pingPong ? playbackDuration * 2 : playbackDuration
    }

    public var totalKeyframeCount: Int {
        layers.reduce(0) { $0 + $1.animation.keyframeCount }
    }

    public var hasMotion: Bool {
        kind == .animated && layers.contains { !$0.animation.isEmpty }
    }

    public func layer(id: String) -> AnimatedLayer? {
        layers.first { $0.id == id }
    }

    // MARK: - Validation

    @discardableResult
    public func validated() throws -> Self {
        guard Self.readableVersions.contains(version) else {
            throw AnimatedDocumentError.unsupportedVersion(version)
        }
        guard canvas.isValid else { throw AnimatedDocumentError.invalidCanvas }
        switch kind {
        case .static:
            guard durationSeconds == 0, fps == 0, loop == .once else {
                throw AnimatedDocumentError.invalidStaticTiming
            }
        case .animated:
            guard Self.durationRange.contains(durationSeconds), Self.fpsRange.contains(fps) else {
                throw AnimatedDocumentError.invalidAnimatedTiming
            }
        }
        guard Self.speedRange.contains(speed) else { throw AnimatedDocumentError.invalidSpeed }
        guard layers.count <= Self.maximumLayerCount else { throw AnimatedDocumentError.tooManyLayers }
        guard Set(layers.map(\.id)).count == layers.count else { throw AnimatedDocumentError.duplicateLayerID }
        guard background.isValid, mp4Background.isValid else { throw AnimatedDocumentError.invalidBackground }
        guard let invalid = layers.first(where: { !$0.isValid }) else {
            return try validatedKeyframes()
        }
        throw AnimatedDocumentError.invalidLayer(invalid.id)
    }

    private func validatedKeyframes() throws -> Self {
        guard totalKeyframeCount <= Self.maximumKeyframeCount else {
            throw AnimatedDocumentError.tooManyKeyframes
        }
        for layer in layers {
            for keyframe in layer.animation.allKeyframes {
                guard keyframe.timeSeconds >= 0, keyframe.timeSeconds <= durationSeconds else {
                    throw AnimatedDocumentError.keyframeOutsideDuration(layer.id)
                }
                guard kind != .static || keyframe.timeSeconds == 0 else {
                    throw AnimatedDocumentError.keyframeOutsideDuration(layer.id)
                }
            }
        }
        return self
    }
}

public enum AnimatedDocumentError: Error, Equatable, LocalizedError {
    case unsupportedVersion(Int)
    case invalidCanvas
    case invalidStaticTiming
    case invalidAnimatedTiming
    case invalidSpeed
    case tooManyLayers
    case tooManyKeyframes
    case duplicateLayerID
    case invalidLayer(String)
    case invalidBackground
    case keyframeOutsideDuration(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "Unsupported animation document version \(version); this build reads version \(AnimatedDocument.currentVersion)."
        case .invalidCanvas:
            "The canvas size is outside the supported range."
        case .invalidStaticTiming:
            "A static document must have duration 0, fps 0, and loop once."
        case .invalidAnimatedTiming:
            "The duration or frame rate is outside the supported range."
        case .invalidSpeed:
            "The playback speed is outside the supported range."
        case .tooManyLayers:
            "A document allows at most \(AnimatedDocument.maximumLayerCount) layers."
        case .tooManyKeyframes:
            "A document allows at most \(AnimatedDocument.maximumKeyframeCount) keyframes."
        case .duplicateLayerID:
            "Two layers share the same id."
        case .invalidLayer(let id):
            "Layer \(id) is not structurally valid."
        case .invalidBackground:
            "A background is not valid."
        case .keyframeOutsideDuration(let id):
            "Layer \(id) has a keyframe outside the document's duration."
        }
    }
}
