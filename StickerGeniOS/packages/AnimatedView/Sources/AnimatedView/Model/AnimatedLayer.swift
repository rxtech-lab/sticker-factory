import Foundation

public enum AnimatedLayerType: String, Codable, CaseIterable, Hashable, Sendable {
    case image, text, shape, svg, particle, sequence, video, sprite
    /// Not a wire type. Stands for a layer a newer build wrote and this one cannot draw; the layer
    /// re-encodes its own original `type` string, so this raw value never reaches JSON.
    case unsupported

    /// Whether the editor may offer this as a layer the user can add.
    ///
    /// `sequence` is authorable only in the sense that a document can contain one — the footage
    /// comes from lifting a subject out of a Live Photo in the picker, and there is nothing
    /// meaningful to create from an empty editor menu. `video` is the same: the clip is generated
    /// on the server from a confirmed plan, so there is nothing to author locally, and a `sprite`'s
    /// sheets and face slots are registered by the server build. `unsupported` is never authorable.
    public var isAuthorable: Bool {
        switch self {
        case .image, .text, .shape, .svg, .particle: true
        case .sequence, .video, .sprite, .unsupported: false
        }
    }
}

/// The backdrop a generated clip was shot against, and which the renderer keys out.
///
/// Named rather than spelled as a colour because the key is a *channel*, not an exact value: the
/// clip's background is never precisely `#00FF00` after a video encoder has been at it, so keying
/// works on how far the key channel runs ahead of the other two. Mirrors `ChromaKeyColor` in
/// `server/lib/ai/chroma-key.ts`, which is what chose the backdrop in the first place.
public enum AnimatedVideoKeyColor: String, Codable, CaseIterable, Hashable, Sendable {
    case green, blue

    /// Index of the key channel in RGB order. Green is 1, blue is 2; red is always a rival.
    public var channel: Int {
        switch self {
        case .green: 1
        case .blue: 2
        }
    }

    /// The colour the model was told to flood the background with.
    public var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .green: (0, 1, 0)
        case .blue: (0, 0, 1)
        }
    }
}

/// How captured footage repeats inside its own layer, independent of the document's `loop`.
public enum AnimatedSequencePlayback: String, Codable, CaseIterable, Hashable, Sendable {
    case loop, once, pingPong
}

public enum AnimatedFontFamily: String, Codable, CaseIterable, Hashable, Sendable {
    case rounded, serif, monospaced, system
}

public enum AnimatedFontWeight: String, Codable, CaseIterable, Hashable, Sendable {
    case regular, medium, semibold, bold
}

public enum AnimatedTextAlignment: String, Codable, CaseIterable, Hashable, Sendable {
    case leading, center, trailing
}

public enum AnimatedParticlePreset: String, Codable, CaseIterable, Hashable, Sendable {
    case sparkles, confetti, hearts, bubbles, snow
}

/// Fields every layer carries regardless of what it draws.
///
/// Swift has no schema inheritance for `Codable`, so this is composed into each layer struct and
/// flattened on the wire — the JSON is one flat object per layer, exactly as the zod contract emits
/// it. Keeping it as a real type instead of repeating five fields five times is what lets
/// `AnimatedLayer`'s accessors stay one line each.
public struct AnimatedLayerBase: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var hidden: Bool
    public var anchor: AnimatedAnchor
    /// Declarative motion. When non-empty this is the source of truth and `animation` is its
    /// compiled output; the server rejects a document where the two disagree. When empty,
    /// `animation` may hold hand-authored keyframes and is left alone.
    public var animations: [AnimationSpec]
    /// Compiled keyframes. This is the only thing the renderer and the exporter read.
    public var animation: AnimatedLayerAnimation
    public var blendMode: AnimatedBlendMode

    public init(
        id: String,
        name: String,
        hidden: Bool = false,
        anchor: AnimatedAnchor = .default,
        animations: [AnimationSpec] = [],
        animation: AnimatedLayerAnimation = .empty,
        blendMode: AnimatedBlendMode = .normal
    ) {
        self.id = id
        self.name = name
        self.hidden = hidden
        self.anchor = anchor
        self.animations = animations
        self.animation = animation
        self.blendMode = blendMode
    }

    private enum CodingKeys: String, CodingKey { case id, name, hidden, anchor, animations, animation, blendMode }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        hidden = try c.value(.hidden, default: false)
        anchor = try c.value(.anchor, default: .default)
        animations = try c.value(.animations, default: [])
        animation = try c.value(.animation, default: .empty)
        blendMode = try c.value(.blendMode, default: .normal)
    }

    public var isValid: Bool {
        id.isAnimatedLayerID
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name.count <= 80
            && animations.count <= 12
            && anchor.isValid
            && animation.isValid
    }
}

public struct AnimatedImageLayer: Codable, Hashable, Sendable {
    public var base: AnimatedLayerBase
    public var assetId: String
    public var maskAssetId: String?
    public var contentMode: AnimatedContentMode

    public init(
        base: AnimatedLayerBase,
        assetId: String,
        maskAssetId: String? = nil,
        contentMode: AnimatedContentMode = .fit
    ) {
        self.base = base
        self.assetId = assetId
        self.maskAssetId = maskAssetId
        self.contentMode = contentMode
    }

    private enum CodingKeys: String, CodingKey { case type, assetId, maskAssetId, contentMode }

    public init(from decoder: Decoder) throws {
        base = try AnimatedLayerBase(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assetId = try c.decode(String.self, forKey: .assetId)
        maskAssetId = try c.decodeIfPresent(String.self, forKey: .maskAssetId)
        contentMode = try c.value(.contentMode, default: .fit)
    }

    public func encode(to encoder: Encoder) throws {
        try base.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(AnimatedLayerType.image, forKey: .type)
        try c.encode(assetId, forKey: .assetId)
        try c.encodeIfPresent(maskAssetId, forKey: .maskAssetId)
        try c.encode(contentMode, forKey: .contentMode)
    }

    public var isValid: Bool {
        base.isValid && assetId.isAnimatedUUID && (maskAssetId.map(\.isAnimatedUUID) ?? true)
    }
}

public struct AnimatedTextLayer: Codable, Hashable, Sendable {
    public var base: AnimatedLayerBase
    public var text: String
    public var font: AnimatedFontFamily
    public var weight: AnimatedFontWeight
    public var paint: AnimatedPaint
    public var alignment: AnimatedTextAlignment

    public init(
        base: AnimatedLayerBase,
        text: String,
        font: AnimatedFontFamily = .rounded,
        weight: AnimatedFontWeight = .bold,
        paint: AnimatedPaint = .solid("#FFFFFF"),
        alignment: AnimatedTextAlignment = .center
    ) {
        self.base = base
        self.text = text
        self.font = font
        self.weight = weight
        self.paint = paint
        self.alignment = alignment
    }

    private enum CodingKeys: String, CodingKey { case type, text, font, weight, paint, alignment }

    public init(from decoder: Decoder) throws {
        base = try AnimatedLayerBase(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        font = try c.value(.font, default: .rounded)
        weight = try c.value(.weight, default: .bold)
        paint = try c.value(.paint, default: .solid("#FFFFFF"))
        alignment = try c.value(.alignment, default: .center)
    }

    public func encode(to encoder: Encoder) throws {
        try base.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(AnimatedLayerType.text, forKey: .type)
        try c.encode(text, forKey: .text)
        try c.encode(font, forKey: .font)
        try c.encode(weight, forKey: .weight)
        try c.encode(paint, forKey: .paint)
        try c.encode(alignment, forKey: .alignment)
    }

    public var isValid: Bool {
        base.isValid && !text.isEmpty && text.count <= 160 && paint.isValid
    }
}

public struct AnimatedShapeLayer: Codable, Hashable, Sendable {
    public var base: AnimatedLayerBase
    public var shape: AnimatedShapeKind
    public var fill: AnimatedPaint?
    public var stroke: AnimatedStroke?
    /// Corner radius as a fraction of the layer box width, used by `roundedRectangle`.
    public var cornerRadius: Double

    public init(
        base: AnimatedLayerBase,
        shape: AnimatedShapeKind,
        fill: AnimatedPaint? = nil,
        stroke: AnimatedStroke? = nil,
        cornerRadius: Double = 0.12
    ) {
        self.base = base
        self.shape = shape
        self.fill = fill
        self.stroke = stroke
        self.cornerRadius = cornerRadius
    }

    private enum CodingKeys: String, CodingKey { case type, shape, fill, stroke, cornerRadius }

    public init(from decoder: Decoder) throws {
        base = try AnimatedLayerBase(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shape = try c.decode(AnimatedShapeKind.self, forKey: .shape)
        fill = try c.decodeIfPresent(AnimatedPaint.self, forKey: .fill)
        stroke = try c.decodeIfPresent(AnimatedStroke.self, forKey: .stroke)
        cornerRadius = try c.value(.cornerRadius, default: 0.12)
    }

    public func encode(to encoder: Encoder) throws {
        try base.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(AnimatedLayerType.shape, forKey: .type)
        try c.encode(shape, forKey: .shape)
        try c.encodeIfPresent(fill, forKey: .fill)
        try c.encodeIfPresent(stroke, forKey: .stroke)
        try c.encode(cornerRadius, forKey: .cornerRadius)
    }

    public var isValid: Bool {
        base.isValid && shape.isValid && (0...0.5).contains(cornerRadius)
            && (fill?.isValid ?? true) && (stroke?.isValid ?? true)
            // A shape with neither fill nor stroke draws nothing, which is always an authoring bug.
            && (fill != nil || stroke != nil)
    }
}

public struct AnimatedSVGLayer: Codable, Hashable, Sendable {
    public var base: AnimatedLayerBase
    public var source: AnimatedSVGSource
    public var renderMode: AnimatedSVGRenderMode
    /// Replaces every subpath's fill. `nil` keeps the artwork's own colors.
    public var tint: AnimatedPaint?
    /// Replaces every subpath's stroke. Set this together with a `drawOn` animation to make an
    /// otherwise fill-only icon draw itself as an outline.
    public var strokeOverride: AnimatedStroke?
    public var contentMode: AnimatedContentMode
    /// Seconds each successive subpath's trim window is offset by, so a multi-stroke glyph draws
    /// one stroke after another instead of all at once. Zero draws them together.
    public var staggerSeconds: Double

    public init(
        base: AnimatedLayerBase,
        source: AnimatedSVGSource,
        renderMode: AnimatedSVGRenderMode = .vector,
        tint: AnimatedPaint? = nil,
        strokeOverride: AnimatedStroke? = nil,
        contentMode: AnimatedContentMode = .fit,
        staggerSeconds: Double = 0
    ) {
        self.base = base
        self.source = source
        self.renderMode = renderMode
        self.tint = tint
        self.strokeOverride = strokeOverride
        self.contentMode = contentMode
        self.staggerSeconds = staggerSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case type, source, renderMode, tint, strokeOverride, contentMode, staggerSeconds
    }

    public init(from decoder: Decoder) throws {
        base = try AnimatedLayerBase(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(AnimatedSVGSource.self, forKey: .source)
        renderMode = try c.value(.renderMode, default: .vector)
        tint = try c.decodeIfPresent(AnimatedPaint.self, forKey: .tint)
        strokeOverride = try c.decodeIfPresent(AnimatedStroke.self, forKey: .strokeOverride)
        contentMode = try c.value(.contentMode, default: .fit)
        staggerSeconds = try c.value(.staggerSeconds, default: 0)
    }

    public func encode(to encoder: Encoder) throws {
        try base.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(AnimatedLayerType.svg, forKey: .type)
        try c.encode(source, forKey: .source)
        try c.encode(renderMode, forKey: .renderMode)
        try c.encodeIfPresent(tint, forKey: .tint)
        try c.encodeIfPresent(strokeOverride, forKey: .strokeOverride)
        try c.encode(contentMode, forKey: .contentMode)
        try c.encode(staggerSeconds, forKey: .staggerSeconds)
    }

    public var isValid: Bool {
        base.isValid && source.isValid && (0...4).contains(staggerSeconds)
            && (tint?.isValid ?? true) && (strokeOverride?.isValid ?? true)
    }
}

public struct AnimatedParticleLayer: Codable, Hashable, Sendable {
    public var base: AnimatedLayerBase
    public var preset: AnimatedParticlePreset
    public var count: Int
    public var paint: AnimatedPaint
    /// Seeds a deterministic hash so the same document produces the same particles on screen and
    /// in every exported frame.
    public var seed: Int

    public init(
        base: AnimatedLayerBase,
        preset: AnimatedParticlePreset,
        count: Int = 24,
        paint: AnimatedPaint = .solid("#FFFFFF"),
        seed: Int = 42
    ) {
        self.base = base
        self.preset = preset
        self.count = count
        self.paint = paint
        self.seed = seed
    }

    private enum CodingKeys: String, CodingKey { case type, preset, count, paint, seed }

    public init(from decoder: Decoder) throws {
        base = try AnimatedLayerBase(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preset = try c.decode(AnimatedParticlePreset.self, forKey: .preset)
        count = try c.value(.count, default: 24)
        paint = try c.value(.paint, default: .solid("#FFFFFF"))
        seed = try c.value(.seed, default: 42)
    }

    public func encode(to encoder: Encoder) throws {
        try base.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(AnimatedLayerType.particle, forKey: .type)
        try c.encode(preset, forKey: .preset)
        try c.encode(count, forKey: .count)
        try c.encode(paint, forKey: .paint)
        try c.encode(seed, forKey: .seed)
    }

    public var isValid: Bool {
        base.isValid && (1...64).contains(count) && (0...Int(Int32.max)).contains(seed) && paint.isValid
    }
}

/// Real frames the user captured, packed into one image and played back on the timeline.
///
/// The frames arrive as a single transparent PNG holding a `rows` x `columns` grid of equally sized
/// tiles. Slicing one out costs nothing — `CGImage.cropping(to:)` shares the backing store — which
/// is what lets the renderer resolve a tile per frame without a second decode. `FrameAtlasCache`
/// does that; nothing here holds pixels.
///
/// `frameRate` is the footage's own rate and has nothing to do with the document's `fps`, which
/// only governs how densely the exporter samples the timeline. `AnimationInterpolator
/// .sequenceFrameIndex` is where the two meet.
public struct AnimatedSequenceLayer: Codable, Hashable, Sendable {
    public var base: AnimatedLayerBase
    /// The frame-atlas image. One asset, whatever the frame count.
    public var assetId: String
    public var columns: Int
    public var rows: Int
    /// Tiles actually used, read row-major from the top-left. Trailing cells of the grid may be empty.
    public var frameCount: Int
    public var frameRate: Double
    public var playback: AnimatedSequencePlayback
    /// When on the document timeline the first tile appears. Before it, the first tile is held.
    public var startSeconds: Double
    public var contentMode: AnimatedContentMode
    /// Tile 0 as its own asset, present on documents the server has processed. The renderer never
    /// needs it — it exists so a client that predates this layer type can be served a still.
    public var posterAssetId: String?

    public init(
        base: AnimatedLayerBase,
        assetId: String,
        columns: Int,
        rows: Int,
        frameCount: Int,
        frameRate: Double,
        playback: AnimatedSequencePlayback = .loop,
        startSeconds: Double = 0,
        contentMode: AnimatedContentMode = .fit,
        posterAssetId: String? = nil
    ) {
        self.base = base
        self.assetId = assetId
        self.columns = columns
        self.rows = rows
        self.frameCount = frameCount
        self.frameRate = frameRate
        self.playback = playback
        self.startSeconds = startSeconds
        self.contentMode = contentMode
        self.posterAssetId = posterAssetId
    }

    private enum CodingKeys: String, CodingKey {
        case type, assetId, columns, rows, frameCount, frameRate, playback, startSeconds, contentMode, posterAssetId
    }

    public init(from decoder: Decoder) throws {
        base = try AnimatedLayerBase(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assetId = try c.decode(String.self, forKey: .assetId)
        columns = try c.decode(Int.self, forKey: .columns)
        rows = try c.decode(Int.self, forKey: .rows)
        frameCount = try c.decode(Int.self, forKey: .frameCount)
        frameRate = try c.decode(Double.self, forKey: .frameRate)
        playback = try c.value(.playback, default: .loop)
        startSeconds = try c.value(.startSeconds, default: 0)
        contentMode = try c.value(.contentMode, default: .fit)
        posterAssetId = try c.decodeIfPresent(String.self, forKey: .posterAssetId)
    }

    public func encode(to encoder: Encoder) throws {
        try base.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(AnimatedLayerType.sequence, forKey: .type)
        try c.encode(assetId, forKey: .assetId)
        try c.encode(columns, forKey: .columns)
        try c.encode(rows, forKey: .rows)
        try c.encode(frameCount, forKey: .frameCount)
        try c.encode(frameRate, forKey: .frameRate)
        try c.encode(playback, forKey: .playback)
        try c.encode(startSeconds, forKey: .startSeconds)
        try c.encode(contentMode, forKey: .contentMode)
        try c.encodeIfPresent(posterAssetId, forKey: .posterAssetId)
    }

    public var isValid: Bool {
        base.isValid
            && assetId.isAnimatedUUID
            && (posterAssetId.map(\.isAnimatedUUID) ?? true)
            && (1...8).contains(columns)
            && (1...8).contains(rows)
            && (1...64).contains(frameCount)
            && frameCount <= rows * columns
            && (1...60).contains(frameRate)
            && (0...30).contains(startSeconds)
    }
}

/// A short generated clip of the whole subject, played back on the timeline.
///
/// This is the one layer whose pixels the server never draws: the clip is an opaque 1:1 MP4 shot
/// against a solid chroma backdrop, and it is keyed to alpha *here*, on device, by
/// `VideoFrameDecoder`. Everything that has to draw the layer without decoding video — the server
/// renderer, the layout review, quick publish, and clients older than v4 — draws `posterAssetId`
/// instead, which is why the poster is required rather than optional as it is on a sequence.
///
/// `frameRate` is the clip's own rate and is independent of the document's `fps`, exactly as for a
/// sequence layer. `AnimationInterpolator.videoFrameIndex` is where the two meet.
public struct AnimatedVideoLayer: Codable, Hashable, Sendable {
    public var base: AnimatedLayerBase
    /// The MP4 asset. Opaque, square, on a `keyColor` backdrop.
    public var assetId: String
    public var keyColor: AnimatedVideoKeyColor
    public var frameCount: Int
    public var frameRate: Double
    public var playback: AnimatedSequencePlayback
    /// When on the document timeline the first frame appears. Before it, the first frame is held.
    public var startSeconds: Double
    public var contentMode: AnimatedContentMode
    /// The keyed transparent still the clip was animated from. Drawn while the clip is still
    /// downloading or decoding, and by everything that cannot decode video at all.
    public var posterAssetId: String

    public init(
        base: AnimatedLayerBase,
        assetId: String,
        keyColor: AnimatedVideoKeyColor,
        frameCount: Int,
        frameRate: Double,
        playback: AnimatedSequencePlayback = .loop,
        startSeconds: Double = 0,
        contentMode: AnimatedContentMode = .fit,
        posterAssetId: String
    ) {
        self.base = base
        self.assetId = assetId
        self.keyColor = keyColor
        self.frameCount = frameCount
        self.frameRate = frameRate
        self.playback = playback
        self.startSeconds = startSeconds
        self.contentMode = contentMode
        self.posterAssetId = posterAssetId
    }

    private enum CodingKeys: String, CodingKey {
        case type, assetId, keyColor, frameCount, frameRate, playback, startSeconds, contentMode, posterAssetId
    }

    public init(from decoder: Decoder) throws {
        base = try AnimatedLayerBase(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assetId = try c.decode(String.self, forKey: .assetId)
        keyColor = try c.decode(AnimatedVideoKeyColor.self, forKey: .keyColor)
        frameCount = try c.decode(Int.self, forKey: .frameCount)
        frameRate = try c.decode(Double.self, forKey: .frameRate)
        playback = try c.value(.playback, default: .loop)
        startSeconds = try c.value(.startSeconds, default: 0)
        contentMode = try c.value(.contentMode, default: .fit)
        posterAssetId = try c.decode(String.self, forKey: .posterAssetId)
    }

    public func encode(to encoder: Encoder) throws {
        try base.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(AnimatedLayerType.video, forKey: .type)
        try c.encode(assetId, forKey: .assetId)
        try c.encode(keyColor, forKey: .keyColor)
        try c.encode(frameCount, forKey: .frameCount)
        try c.encode(frameRate, forKey: .frameRate)
        try c.encode(playback, forKey: .playback)
        try c.encode(startSeconds, forKey: .startSeconds)
        try c.encode(contentMode, forKey: .contentMode)
        try c.encode(posterAssetId, forKey: .posterAssetId)
    }

    public var isValid: Bool {
        base.isValid
            && assetId.isAnimatedUUID
            && posterAssetId.isAnimatedUUID
            && (1...600).contains(frameCount)
            && (1...60).contains(frameRate)
            && (0...30).contains(startSeconds)
    }
}

/// A layer written by a newer build, carried through untouched.
///
/// Without this, an unknown `type` throws out of `AnimatedLayer.init(from:)`, which fails the whole
/// document decode, which fails the whole sticker decode — and the user is left with a project they
/// cannot open at all. Rendering nothing is a far better failure than that, and re-encoding the raw
/// object means saving an edit does not silently delete the layer either.
///
/// `isValid` is false on purpose: the editor should surface a blocking issue rather than let someone
/// publish a sticker with a layer this build could not draw.
public struct AnimatedUnsupportedLayer: Codable, Hashable, Sendable {
    public var base: AnimatedLayerBase
    /// The layer's original JSON, including its own `type`. Re-encoded verbatim.
    public var raw: [String: AnimatedRawJSON]

    public init(base: AnimatedLayerBase, raw: [String: AnimatedRawJSON]) {
        self.base = base
        self.raw = raw
    }

    public init(from decoder: Decoder) throws {
        raw = try [String: AnimatedRawJSON](from: decoder)
        // A future layer kind will still carry the shared base, but this type's whole purpose is
        // surviving what we did not anticipate, so a base that fails to decode falls back to a
        // placeholder rather than throwing and taking the document with it.
        if let decoded = try? AnimatedLayerBase(from: decoder) {
            base = decoded
        } else {
            let id = if case .string(let value) = raw["id"] ?? .null { value } else { "unsupported" }
            base = AnimatedLayerBase(id: id, name: "Unsupported layer")
        }
    }

    public func encode(to encoder: Encoder) throws {
        try raw.encode(to: encoder)
    }

    public var isValid: Bool { false }
}

/// The type-discriminated layer union, encoded as one flat object with a `type` key.
public enum AnimatedLayer: Codable, Identifiable, Hashable, Sendable {
    case image(AnimatedImageLayer)
    case text(AnimatedTextLayer)
    case shape(AnimatedShapeLayer)
    case svg(AnimatedSVGLayer)
    case particle(AnimatedParticleLayer)
    case sequence(AnimatedSequenceLayer)
    case video(AnimatedVideoLayer)
    case sprite(AnimatedSpriteLayer)
    /// A layer this build does not understand. See `AnimatedUnsupportedLayer`.
    case unsupported(AnimatedUnsupportedLayer)

    private enum CodingKeys: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Decoded as a raw string rather than straight into the enum: an unknown `type` must land on
        // `.unsupported`, not throw. Throwing here fails the document, then the sticker, and the
        // user cannot open the project at all — which is precisely what a version bump would
        // otherwise do to every build already in the field.
        let raw = try container.decode(String.self, forKey: .type)
        switch AnimatedLayerType(rawValue: raw) {
        case .image: self = .image(try AnimatedImageLayer(from: decoder))
        case .text: self = .text(try AnimatedTextLayer(from: decoder))
        case .shape: self = .shape(try AnimatedShapeLayer(from: decoder))
        case .svg: self = .svg(try AnimatedSVGLayer(from: decoder))
        case .particle: self = .particle(try AnimatedParticleLayer(from: decoder))
        case .sequence: self = .sequence(try AnimatedSequenceLayer(from: decoder))
        case .video: self = .video(try AnimatedVideoLayer(from: decoder))
        case .sprite: self = .sprite(try AnimatedSpriteLayer(from: decoder))
        // `unsupported` is not a wire type, so a document that literally spells it is as unknown as
        // anything else — and falls into the same bucket rather than round-tripping as a real case.
        case .unsupported, nil: self = .unsupported(try AnimatedUnsupportedLayer(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .image(let value): try value.encode(to: encoder)
        case .text(let value): try value.encode(to: encoder)
        case .shape(let value): try value.encode(to: encoder)
        case .svg(let value): try value.encode(to: encoder)
        case .particle(let value): try value.encode(to: encoder)
        case .sequence(let value): try value.encode(to: encoder)
        case .video(let value): try value.encode(to: encoder)
        case .sprite(let value): try value.encode(to: encoder)
        case .unsupported(let value): try value.encode(to: encoder)
        }
    }

    public var base: AnimatedLayerBase {
        get {
            switch self {
            case .image(let v): v.base
            case .text(let v): v.base
            case .shape(let v): v.base
            case .svg(let v): v.base
            case .particle(let v): v.base
            case .sequence(let v): v.base
            case .video(let v): v.base
            case .sprite(let v): v.base
            case .unsupported(let v): v.base
            }
        }
        set {
            switch self {
            case .image(var v): v.base = newValue; self = .image(v)
            case .text(var v): v.base = newValue; self = .text(v)
            case .shape(var v): v.base = newValue; self = .shape(v)
            case .svg(var v): v.base = newValue; self = .svg(v)
            case .particle(var v): v.base = newValue; self = .particle(v)
            case .sequence(var v): v.base = newValue; self = .sequence(v)
            case .video(var v): v.base = newValue; self = .video(v)
            case .sprite(var v): v.base = newValue; self = .sprite(v)
            // Deliberately a no-op. `raw` is what gets encoded, so writing the base here would
            // change what the editor shows without changing what is saved.
            case .unsupported: break
            }
        }
    }

    public var id: String { base.id }
    public var name: String { base.name }
    public var hidden: Bool { base.hidden }
    public var anchor: AnimatedAnchor { base.anchor }
    public var animations: [AnimationSpec] { base.animations }
    public var animation: AnimatedLayerAnimation { base.animation }
    public var blendMode: AnimatedBlendMode { base.blendMode }

    public var type: AnimatedLayerType {
        switch self {
        case .image: .image
        case .text: .text
        case .shape: .shape
        case .svg: .svg
        case .particle: .particle
        case .sequence: .sequence
        case .video: .video
        case .sprite: .sprite
        case .unsupported: .unsupported
        }
    }

    /// Text is the one layer kind that must never be scaled non-uniformly; stretched glyphs read as
    /// a rendering fault rather than a deliberate effect.
    public var isText: Bool { type == .text }

    /// Whether trim keyframes do anything to this layer. Images and particles have no path to trim.
    ///
    /// A sequence layer joins them rather than reusing `trim` to mean "which slice of the footage
    /// plays". Overloading it that way would make this property lie, collide with the server's rule
    /// that a declaratively animated layer's keyframes may not be hand-edited, and break compiler
    /// parity. `startSeconds` and `playback` express the same intent without touching a channel.
    public var supportsTrim: Bool {
        switch self {
        case .shape, .svg: true
        case .image, .text, .particle, .sequence, .video, .sprite, .unsupported: false
        }
    }

    public var isValid: Bool {
        switch self {
        case .image(let v): v.isValid
        case .text(let v): v.isValid
        case .shape(let v): v.isValid
        case .svg(let v): v.isValid
        case .particle(let v): v.isValid
        case .sequence(let v): v.isValid
        case .video(let v): v.isValid
        case .sprite(let v): v.isValid
        case .unsupported(let v): v.isValid
        }
    }

    /// Every bitmap this layer needs before it can draw.
    ///
    /// Exists so the two places that gather a document's assets — the app's preloader and the
    /// publisher's pre-flight check — cannot disagree, and cannot quietly miss a layer kind. Both
    /// used to pattern-match `.image` inline, which compiled perfectly well after `sequence` was
    /// added and would have shipped a sticker of placeholders. The exhaustive switch here turns that
    /// class of mistake into a build error at one site instead of a silent failure at two.
    ///
    /// `posterAssetId` is deliberately absent: nothing on this client renders it, and fetching it
    /// would cost a download per sequence layer to hold an image only older clients are served.
    /// SVG asset sources are absent for the same reason — they resolve through `svgMarkup(for:)`,
    /// not through the image store.
    ///
    /// A video layer's poster *is* listed, unlike a sequence's: the renderer draws it while the
    /// clip decodes, and the exporter falls back to it when the clip is missing. The clip itself is
    /// not a bitmap and resolves through `referencedVideoAssetIDs` instead.
    public var referencedImageAssetIDs: [String] {
        switch self {
        case .image(let v): [v.assetId, v.maskAssetId].compactMap { $0 }
        case .sequence(let v): [v.assetId]
        case .video(let v): [v.posterAssetId]
        // Every clip sheet and the expression sheet, whatever is selected: a control can switch to
        // any of them without another download. The poster is for consumers that cannot composite.
        case .sprite(let v): v.clips.flatMap { [$0.assetId, $0.faceMaskAssetId].compactMap { $0 } } + [v.expressions.assetId]
        case .text, .shape, .svg, .particle, .unsupported: []
        }
    }

    /// Every clip this layer needs before it can play, resolved through `videoFrames(for:)`.
    public var referencedVideoAssetIDs: [String] {
        switch self {
        case .video(let v): [v.assetId]
        case .image, .sequence, .sprite, .text, .shape, .svg, .particle, .unsupported: []
        }
    }
}
