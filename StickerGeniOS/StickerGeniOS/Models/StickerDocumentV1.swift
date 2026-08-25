import Foundation

/// Canonical, data-only animation contract shared with the backend.
/// Coordinates are normalized and keyframe times are absolute seconds.
nonisolated struct StickerDocumentV1: Codable, Hashable, Sendable {
    static let currentVersion = 1
    static let maximumLayerCount = 8
    static let maximumKeyframeCount = 128

    var version: Int
    var canvas: StickerCanvasV1
    var kind: StickerKind
    var durationSeconds: Double
    var fps: Int
    var loop: StickerLoopBehavior
    var mp4Background: StickerMP4BackgroundV1
    var layers: [StickerLayerV1]

    init(
        version: Int = Self.currentVersion,
        canvas: StickerCanvasV1 = .init(),
        kind: StickerKind,
        durationSeconds: Double? = nil,
        fps: Int? = nil,
        loop: StickerLoopBehavior? = nil,
        mp4Background: StickerMP4BackgroundV1 = .solid("#FFFFFF"),
        layers: [StickerLayerV1]
    ) {
        self.version = version
        self.canvas = canvas
        self.kind = kind
        self.durationSeconds = durationSeconds ?? (kind == .animated ? 2 : 0)
        self.fps = fps ?? (kind == .animated ? 30 : 0)
        self.loop = loop ?? (kind == .animated ? .loop : .once)
        self.mp4Background = mp4Background
        self.layers = layers
    }

    func validated() throws -> Self {
        guard version == Self.currentVersion else {
            throw StickerDocumentValidationError.unsupportedVersion(version)
        }
        guard canvas == StickerCanvasV1() else { throw StickerDocumentValidationError.invalidCanvas }
        switch kind {
        case .static:
            guard durationSeconds == 0, fps == 0, loop == .once else {
                throw StickerDocumentValidationError.invalidStaticTiming
            }
        case .animated:
            guard (0.5...4).contains(durationSeconds), (1...30).contains(fps) else {
                throw StickerDocumentValidationError.invalidAnimatedTiming
            }
        }
        guard layers.count <= Self.maximumLayerCount else { throw StickerDocumentValidationError.tooManyLayers }
        guard Set(layers.map(\.id)).count == layers.count else { throw StickerDocumentValidationError.duplicateLayerID }
        guard mp4Background.isValid else { throw StickerDocumentValidationError.invalidBackground }
        guard layers.allSatisfy(\.isStructurallyValid) else { throw StickerDocumentValidationError.invalidLayer }
        let keyframes = layers.flatMap(\.allKeyframes)
        guard keyframes.count <= Self.maximumKeyframeCount else { throw StickerDocumentValidationError.tooManyKeyframes }
        guard keyframes.allSatisfy({ frame in
            frame.timeSeconds >= 0 && frame.timeSeconds <= durationSeconds && (kind != .static || frame.timeSeconds == 0)
        }) else { throw StickerDocumentValidationError.keyframeOutsideDuration }
        return self
    }
}

nonisolated struct StickerCanvasV1: Codable, Hashable, Sendable {
    var width: Int = 1024
    var height: Int = 1024
    var coordinateSpace: String = "normalized"
    var transparent: Bool = true
}

nonisolated enum StickerKind: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case `static`
    case animated
    var id: Self { self }
    var label: String { self == .static ? "Static" : "Animated" }
    var symbol: String { self == .static ? "photo" : "sparkles.rectangle.stack" }
}

nonisolated enum StickerLoopBehavior: String, Codable, CaseIterable, Hashable, Sendable { case once, loop, pingPong }

nonisolated enum StickerMP4BackgroundV1: Codable, Hashable, Sendable {
    case solid(String)
    case linearGradient(colors: [String], angleDegrees: Double)

    private enum CodingKeys: String, CodingKey { case type, color, colors, angleDegrees }
    private enum Kind: String, Codable { case solid, linearGradient }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .solid:
            self = .solid(try container.decode(String.self, forKey: .color))
        case .linearGradient:
            let colors = try container.decode([String].self, forKey: .colors)
            guard colors.count == 2 else {
                throw DecodingError.dataCorruptedError(forKey: .colors, in: container, debugDescription: "A linear gradient requires two colors")
            }
            self = .linearGradient(colors: colors, angleDegrees: try container.decode(Double.self, forKey: .angleDegrees))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .solid(let color):
            try container.encode(Kind.solid, forKey: .type)
            try container.encode(color, forKey: .color)
        case .linearGradient(let colors, let angleDegrees):
            try container.encode(Kind.linearGradient, forKey: .type)
            try container.encode(colors, forKey: .colors)
            try container.encode(angleDegrees, forKey: .angleDegrees)
        }
    }

    var isValid: Bool {
        switch self {
        case .solid(let color): color.isHexColor
        case .linearGradient(let colors, let angle):
            colors.count == 2 && colors.allSatisfy(\.isHexColor) && (0...360).contains(angle)
        }
    }
}

nonisolated enum StickerLayerType: String, Codable, Hashable, Sendable { case image, text, shape, particle }

nonisolated struct StickerImageLayerV1: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var hidden: Bool = false
    var animation: StickerLayerAnimationV1 = .init()
    var type: StickerLayerType = .image
    var assetId: String
    var maskAssetId: String?
    var contentMode: StickerImageContentMode = .fit
}

nonisolated enum StickerImageContentMode: String, Codable, Hashable, Sendable { case fit, fill }

nonisolated struct StickerTextLayerV1: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var hidden: Bool = false
    var animation: StickerLayerAnimationV1 = .init()
    var type: StickerLayerType = .text
    var text: String
    var font: StickerFontFamily
    var weight: StickerFontWeight
    var color: String
    var alignment: StickerTextAlignment = .center
}

nonisolated enum StickerFontFamily: String, Codable, Hashable, Sendable { case rounded, serif, monospaced, system }
nonisolated enum StickerFontWeight: String, Codable, Hashable, Sendable { case regular, medium, semibold, bold }
nonisolated enum StickerTextAlignment: String, Codable, Hashable, Sendable { case leading, center, trailing }

nonisolated struct StickerShapeLayerV1: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var hidden: Bool = false
    var animation: StickerLayerAnimationV1 = .init()
    var type: StickerLayerType = .shape
    var shape: StickerShapeKind
    var fill: String
    var stroke: String?
    var strokeWidth: Double = 0
    var cornerRadius: Double = 0.12
}

nonisolated enum StickerShapeKind: String, Codable, Hashable, Sendable { case circle, roundedRectangle, star, heart, burst }

nonisolated struct StickerParticleLayerV1: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var hidden: Bool = false
    var animation: StickerLayerAnimationV1 = .init()
    var type: StickerLayerType = .particle
    var preset: StickerParticlePreset
    var count: Int
    var color: String
    var seed: Int
}

nonisolated enum StickerParticlePreset: String, Codable, Hashable, Sendable { case sparkles, confetti, hearts, bubbles, snow }

nonisolated enum StickerLayerV1: Codable, Identifiable, Hashable, Sendable {
    case image(StickerImageLayerV1)
    case text(StickerTextLayerV1)
    case shape(StickerShapeLayerV1)
    case particle(StickerParticleLayerV1)

    private enum CodingKeys: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(StickerLayerType.self, forKey: .type) {
        case .image: self = .image(try StickerImageLayerV1(from: decoder))
        case .text: self = .text(try StickerTextLayerV1(from: decoder))
        case .shape: self = .shape(try StickerShapeLayerV1(from: decoder))
        case .particle: self = .particle(try StickerParticleLayerV1(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .image(let value): try value.encode(to: encoder)
        case .text(let value): try value.encode(to: encoder)
        case .shape(let value): try value.encode(to: encoder)
        case .particle(let value): try value.encode(to: encoder)
        }
    }

    var id: String {
        switch self { case .image(let v): v.id; case .text(let v): v.id; case .shape(let v): v.id; case .particle(let v): v.id }
    }
    var name: String {
        switch self { case .image(let v): v.name; case .text(let v): v.name; case .shape(let v): v.name; case .particle(let v): v.name }
    }
    var hidden: Bool {
        switch self { case .image(let v): v.hidden; case .text(let v): v.hidden; case .shape(let v): v.hidden; case .particle(let v): v.hidden }
    }
    var animation: StickerLayerAnimationV1 {
        switch self { case .image(let v): v.animation; case .text(let v): v.animation; case .shape(let v): v.animation; case .particle(let v): v.animation }
    }
    /// Text is the one layer kind that must never be scaled non-uniformly; stretched glyphs read
    /// as a rendering fault rather than as a deliberate effect.
    var isText: Bool { if case .text = self { true } else { false } }
    var isStructurallyValid: Bool {
        guard id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 80,
              animation.isValid
        else { return false }
        switch self {
        case .image(let value): return UUID(uuidString: value.assetId) != nil && (value.maskAssetId.map { UUID(uuidString: $0) != nil } ?? true)
        case .text(let value): return !value.text.isEmpty && value.text.count <= 160 && value.color.isHexColor
        case .shape(let value): return value.fill.isHexColor && (value.stroke?.isHexColor ?? true) && (0...0.08).contains(value.strokeWidth) && (0...0.5).contains(value.cornerRadius)
        case .particle(let value): return (1...64).contains(value.count) && (0...Int(Int32.max)).contains(value.seed) && value.color.isHexColor
        }
    }
    var allKeyframes: [any StickerTimedKeyframe] { animation.allKeyframes }
}

nonisolated protocol StickerTimedKeyframe: Sendable {
    var timeSeconds: Double { get }
    var easing: StickerEasing { get }
}

nonisolated struct PositionKeyframeV1: Codable, Hashable, Sendable, StickerTimedKeyframe {
    var timeSeconds: Double
    var x: Double
    var y: Double
    var easing: StickerEasing = .linear
}

nonisolated struct ScaleKeyframeV1: Codable, Hashable, Sendable, StickerTimedKeyframe {
    var timeSeconds: Double
    var x: Double
    var y: Double
    var easing: StickerEasing = .linear
}

nonisolated struct RotationKeyframeV1: Codable, Hashable, Sendable, StickerTimedKeyframe {
    var timeSeconds: Double
    var degrees: Double
    var easing: StickerEasing = .linear
}

nonisolated struct OpacityKeyframeV1: Codable, Hashable, Sendable, StickerTimedKeyframe {
    var timeSeconds: Double
    var value: Double
    var easing: StickerEasing = .linear
}

nonisolated struct EffectKeyframeV1: Codable, Hashable, Sendable, StickerTimedKeyframe {
    var timeSeconds: Double
    var blurRadius: Double = 0
    var hueDegrees: Double = 0
    var saturation: Double = 1
    var easing: StickerEasing = .linear
}

nonisolated struct StickerLayerAnimationV1: Codable, Hashable, Sendable {
    var position: [PositionKeyframeV1] = []
    var scale: [ScaleKeyframeV1] = []
    var rotation: [RotationKeyframeV1] = []
    var opacity: [OpacityKeyframeV1] = []
    var effects: [EffectKeyframeV1] = []

    var allKeyframes: [any StickerTimedKeyframe] {
        position.map { $0 as any StickerTimedKeyframe } +
            scale.map { $0 as any StickerTimedKeyframe } +
            rotation.map { $0 as any StickerTimedKeyframe } +
            opacity.map { $0 as any StickerTimedKeyframe } +
            effects.map { $0 as any StickerTimedKeyframe }
    }

    var isValid: Bool {
        guard position.count <= 32, scale.count <= 32, rotation.count <= 32,
              opacity.count <= 32, effects.count <= 32
        else { return false }
        return position.allSatisfy { (-1...2).contains($0.x) && (-1...2).contains($0.y) && (0...4).contains($0.timeSeconds) }
            && scale.allSatisfy { (0.05...8).contains($0.x) && (0.05...8).contains($0.y) && (0...4).contains($0.timeSeconds) }
            && rotation.allSatisfy { (-1080...1080).contains($0.degrees) && (0...4).contains($0.timeSeconds) }
            && opacity.allSatisfy { (0...1).contains($0.value) && (0...4).contains($0.timeSeconds) }
            && effects.allSatisfy {
                (0...20).contains($0.blurRadius) && (-180...180).contains($0.hueDegrees)
                    && (0...2).contains($0.saturation) && (0...4).contains($0.timeSeconds)
            }
    }
}

nonisolated enum StickerEasing: String, Codable, CaseIterable, Hashable, Sendable {
    case linear, easeIn, easeOut, easeInOut, springSoft, springBouncy
}

nonisolated enum StickerOperationV1: Codable, Hashable, Sendable {
    case addLayer(layer: StickerLayerV1, index: Int?)
    case removeLayer(layerId: String)
    case reorderLayer(layerId: String, index: Int)
    case renameLayer(layerId: String, name: String)
    case replaceAsset(layerId: String, assetId: String, maskAssetId: String?)
    case setPositionKeyframes(layerId: String, keyframes: [PositionKeyframeV1])
    case setScaleKeyframes(layerId: String, keyframes: [ScaleKeyframeV1])
    case setRotationKeyframes(layerId: String, keyframes: [RotationKeyframeV1])
    case setOpacityKeyframes(layerId: String, keyframes: [OpacityKeyframeV1])
    case setEffectKeyframes(layerId: String, keyframes: [EffectKeyframeV1])
    case setTiming(durationSeconds: Double, fps: Int, loop: StickerLoopBehavior)
    case setMp4Background(background: StickerMP4BackgroundV1)

    private enum CodingKeys: String, CodingKey { case op, layer, index, layerId, name, assetId, maskAssetId, keyframes, durationSeconds, fps, loop, background }
    private enum Operation: String, Codable {
        case addLayer, removeLayer, reorderLayer, renameLayer, replaceAsset
        case setPositionKeyframes, setScaleKeyframes, setRotationKeyframes, setOpacityKeyframes, setEffectKeyframes
        case setTiming, setMp4Background
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Operation.self, forKey: .op) {
        case .addLayer: self = .addLayer(layer: try c.decode(StickerLayerV1.self, forKey: .layer), index: try c.decodeIfPresent(Int.self, forKey: .index))
        case .removeLayer: self = .removeLayer(layerId: try c.decode(String.self, forKey: .layerId))
        case .reorderLayer: self = .reorderLayer(layerId: try c.decode(String.self, forKey: .layerId), index: try c.decode(Int.self, forKey: .index))
        case .renameLayer: self = .renameLayer(layerId: try c.decode(String.self, forKey: .layerId), name: try c.decode(String.self, forKey: .name))
        case .replaceAsset: self = .replaceAsset(layerId: try c.decode(String.self, forKey: .layerId), assetId: try c.decode(String.self, forKey: .assetId), maskAssetId: try c.decodeIfPresent(String.self, forKey: .maskAssetId))
        case .setPositionKeyframes: self = .setPositionKeyframes(layerId: try c.decode(String.self, forKey: .layerId), keyframes: try c.decode([PositionKeyframeV1].self, forKey: .keyframes))
        case .setScaleKeyframes: self = .setScaleKeyframes(layerId: try c.decode(String.self, forKey: .layerId), keyframes: try c.decode([ScaleKeyframeV1].self, forKey: .keyframes))
        case .setRotationKeyframes: self = .setRotationKeyframes(layerId: try c.decode(String.self, forKey: .layerId), keyframes: try c.decode([RotationKeyframeV1].self, forKey: .keyframes))
        case .setOpacityKeyframes: self = .setOpacityKeyframes(layerId: try c.decode(String.self, forKey: .layerId), keyframes: try c.decode([OpacityKeyframeV1].self, forKey: .keyframes))
        case .setEffectKeyframes: self = .setEffectKeyframes(layerId: try c.decode(String.self, forKey: .layerId), keyframes: try c.decode([EffectKeyframeV1].self, forKey: .keyframes))
        case .setTiming: self = .setTiming(durationSeconds: try c.decode(Double.self, forKey: .durationSeconds), fps: try c.decode(Int.self, forKey: .fps), loop: try c.decode(StickerLoopBehavior.self, forKey: .loop))
        case .setMp4Background: self = .setMp4Background(background: try c.decode(StickerMP4BackgroundV1.self, forKey: .background))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .addLayer(let layer, let index): try c.encode(Operation.addLayer, forKey: .op); try c.encode(layer, forKey: .layer); try c.encodeIfPresent(index, forKey: .index)
        case .removeLayer(let id): try c.encode(Operation.removeLayer, forKey: .op); try c.encode(id, forKey: .layerId)
        case .reorderLayer(let id, let index): try c.encode(Operation.reorderLayer, forKey: .op); try c.encode(id, forKey: .layerId); try c.encode(index, forKey: .index)
        case .renameLayer(let id, let name): try c.encode(Operation.renameLayer, forKey: .op); try c.encode(id, forKey: .layerId); try c.encode(name, forKey: .name)
        case .replaceAsset(let id, let assetId, let mask): try c.encode(Operation.replaceAsset, forKey: .op); try c.encode(id, forKey: .layerId); try c.encode(assetId, forKey: .assetId); try c.encodeIfPresent(mask, forKey: .maskAssetId)
        case .setPositionKeyframes(let id, let frames): try c.encode(Operation.setPositionKeyframes, forKey: .op); try c.encode(id, forKey: .layerId); try c.encode(frames, forKey: .keyframes)
        case .setScaleKeyframes(let id, let frames): try c.encode(Operation.setScaleKeyframes, forKey: .op); try c.encode(id, forKey: .layerId); try c.encode(frames, forKey: .keyframes)
        case .setRotationKeyframes(let id, let frames): try c.encode(Operation.setRotationKeyframes, forKey: .op); try c.encode(id, forKey: .layerId); try c.encode(frames, forKey: .keyframes)
        case .setOpacityKeyframes(let id, let frames): try c.encode(Operation.setOpacityKeyframes, forKey: .op); try c.encode(id, forKey: .layerId); try c.encode(frames, forKey: .keyframes)
        case .setEffectKeyframes(let id, let frames): try c.encode(Operation.setEffectKeyframes, forKey: .op); try c.encode(id, forKey: .layerId); try c.encode(frames, forKey: .keyframes)
        case .setTiming(let duration, let fps, let loop): try c.encode(Operation.setTiming, forKey: .op); try c.encode(duration, forKey: .durationSeconds); try c.encode(fps, forKey: .fps); try c.encode(loop, forKey: .loop)
        case .setMp4Background(let background): try c.encode(Operation.setMp4Background, forKey: .op); try c.encode(background, forKey: .background)
        }
    }
}

nonisolated enum StickerDocumentValidationError: Error, Equatable {
    case unsupportedVersion(Int), invalidCanvas, invalidStaticTiming, invalidAnimatedTiming
    case tooManyLayers, tooManyKeyframes, duplicateLayerID, invalidLayer, invalidBackground, keyframeOutsideDuration
}

private extension String {
    nonisolated var isHexColor: Bool { range(of: "^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$", options: .regularExpression) != nil }
}
