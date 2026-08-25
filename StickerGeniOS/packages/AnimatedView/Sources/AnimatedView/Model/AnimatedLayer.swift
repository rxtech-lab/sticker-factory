import Foundation

public enum AnimatedLayerType: String, Codable, CaseIterable, Hashable, Sendable {
    case image, text, shape, svg, particle
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

/// The type-discriminated layer union, encoded as one flat object with a `type` key.
public enum AnimatedLayer: Codable, Identifiable, Hashable, Sendable {
    case image(AnimatedImageLayer)
    case text(AnimatedTextLayer)
    case shape(AnimatedShapeLayer)
    case svg(AnimatedSVGLayer)
    case particle(AnimatedParticleLayer)

    private enum CodingKeys: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(AnimatedLayerType.self, forKey: .type) {
        case .image: self = .image(try AnimatedImageLayer(from: decoder))
        case .text: self = .text(try AnimatedTextLayer(from: decoder))
        case .shape: self = .shape(try AnimatedShapeLayer(from: decoder))
        case .svg: self = .svg(try AnimatedSVGLayer(from: decoder))
        case .particle: self = .particle(try AnimatedParticleLayer(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .image(let value): try value.encode(to: encoder)
        case .text(let value): try value.encode(to: encoder)
        case .shape(let value): try value.encode(to: encoder)
        case .svg(let value): try value.encode(to: encoder)
        case .particle(let value): try value.encode(to: encoder)
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
            }
        }
        set {
            switch self {
            case .image(var v): v.base = newValue; self = .image(v)
            case .text(var v): v.base = newValue; self = .text(v)
            case .shape(var v): v.base = newValue; self = .shape(v)
            case .svg(var v): v.base = newValue; self = .svg(v)
            case .particle(var v): v.base = newValue; self = .particle(v)
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
        }
    }

    /// Text is the one layer kind that must never be scaled non-uniformly; stretched glyphs read as
    /// a rendering fault rather than a deliberate effect.
    public var isText: Bool { type == .text }

    /// Whether trim keyframes do anything to this layer. Images and particles have no path to trim.
    public var supportsTrim: Bool {
        switch self {
        case .shape, .svg: true
        case .image, .text, .particle: false
        }
    }

    public var isValid: Bool {
        switch self {
        case .image(let v): v.isValid
        case .text(let v): v.isValid
        case .shape(let v): v.isValid
        case .svg(let v): v.isValid
        case .particle(let v): v.isValid
        }
    }
}
