import Foundation

/// One frame of a sprite clip: how long it holds, and where the face slot sits in it.
///
/// `faceX`/`faceY` are the slot's centre as fractions of the cell and `faceSize` is its width as a
/// fraction of the cell's width — measured on the server off the placeholder the image model was
/// asked to draw. Every expression tile is drawn into that slot, so the face follows the body from
/// frame to frame without the body ever being redrawn.
public struct AnimatedSpriteFrame: Codable, Hashable, Sendable {
    public var duration: Double
    public var faceX: Double
    public var faceY: Double
    public var faceSize: Double

    public init(duration: Double, faceX: Double, faceY: Double, faceSize: Double) {
        self.duration = duration
        self.faceX = faceX
        self.faceY = faceY
        self.faceSize = faceSize
    }

    public var isValid: Bool {
        (0.05...10).contains(duration) && (0...1).contains(faceX) && (0...1).contains(faceY) && (0.02...1).contains(faceSize)
    }
}

public enum AnimatedFaceCompositing: String, Codable, Hashable, Sendable {
    case overlay, masked
}

/// One motion of a character: a short sheet of body frames with per-frame timing.
///
/// Timing is per frame rather than a rate, which is what makes a loop read as alive: an idle clip
/// holds its resting frame for seconds and blinks for a fifth of one. `AnimationInterpolator
/// .spriteFrameIndex` walks the durations modulo their sum, so a clip loops on its own clock
/// regardless of the document's `durationSeconds`.
public struct AnimatedSpriteClip: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// The clip's sheet: `rows` x `columns` cells, row-major, one frame each.
    public var assetId: String
    public var columns: Int
    public var rows: Int
    public var frames: [AnimatedSpriteFrame]
    public var faceCompositing: AnimatedFaceCompositing
    public var faceMaskAssetId: String?
    public var faceSourceAssetId: String?

    public init(id: String, assetId: String, columns: Int, rows: Int, frames: [AnimatedSpriteFrame], faceCompositing: AnimatedFaceCompositing = .overlay, faceMaskAssetId: String? = nil, faceSourceAssetId: String? = nil) {
        self.id = id
        self.assetId = assetId
        self.columns = columns
        self.rows = rows
        self.frames = frames
        self.faceCompositing = faceCompositing
        self.faceMaskAssetId = faceMaskAssetId
        self.faceSourceAssetId = faceSourceAssetId
    }

    private enum CodingKeys: String, CodingKey {
        case id, assetId, columns, rows, frames, faceCompositing, faceMaskAssetId, faceSourceAssetId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        assetId = try c.decode(String.self, forKey: .assetId)
        columns = try c.decode(Int.self, forKey: .columns)
        rows = try c.decode(Int.self, forKey: .rows)
        frames = try c.decode([AnimatedSpriteFrame].self, forKey: .frames)
        faceCompositing = try c.decodeIfPresent(AnimatedFaceCompositing.self, forKey: .faceCompositing) ?? .overlay
        faceMaskAssetId = try c.decodeIfPresent(String.self, forKey: .faceMaskAssetId)
        faceSourceAssetId = try c.decodeIfPresent(String.self, forKey: .faceSourceAssetId)
    }

    /// One loop of the clip, in document seconds.
    public var totalDuration: Double { frames.reduce(0) { $0 + $1.duration } }

    public var isValid: Bool {
        id.isAnimatedLayerID && assetId.isAnimatedUUID
            && (1...8).contains(columns) && (1...8).contains(rows)
            && (1...8).contains(frames.count) && frames.count <= rows * columns
            && frames.allSatisfy(\.isValid)
            && (faceCompositing == .overlay || faceMaskAssetId?.isAnimatedUUID == true)
            && (faceSourceAssetId?.isAnimatedUUID ?? true)
    }
}

/// One face on the expression sheet, as its opaque bounds normalized to the whole sheet.
public struct AnimatedSpriteExpressionTile: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(id: String, x: Double, y: Double, width: Double, height: Double) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isValid: Bool {
        id.isAnimatedLayerID && (0...1).contains(x) && (0...1).contains(y) && (0.001...1).contains(width) && (0.001...1).contains(height)
    }
}

/// The expression sheet: a grid of face plates, one per mood, on transparent.
public struct AnimatedSpriteExpressions: Codable, Hashable, Sendable {
    public var assetId: String
    public var columns: Int
    public var rows: Int
    public var tiles: [AnimatedSpriteExpressionTile]

    public init(assetId: String, columns: Int, rows: Int, tiles: [AnimatedSpriteExpressionTile]) {
        self.assetId = assetId
        self.columns = columns
        self.rows = rows
        self.tiles = tiles
    }

    public var isValid: Bool {
        assetId.isAnimatedUUID && (1...8).contains(columns) && (1...8).contains(rows)
            && (1...8).contains(tiles.count) && tiles.count <= rows * columns && tiles.allSatisfy(\.isValid)
    }
}

/// A controllable character: body clips and face expressions that compose at draw time.
///
/// This is the RxPet model. `clipId` picks which sheet of body frames plays and `expressionId`
/// picks which face is drawn into every frame's slot, so a mood and a pose are independent choices
/// rather than a table of pre-drawn combinations — a configuration's mood control binds
/// `expression` and its pose control binds `clip`. `SpriteFrameCache` does the compositing; the
/// server's `compositeSpriteFrame` is the other implementation, and the two agree on the anchor,
/// the fit rule, and `SpriteFrameCache.faceOvercover`.
///
/// `posterAssetId` is required: the server always builds a sprite, and the poster is what everything
/// that cannot composite draws in its place.
public struct AnimatedSpriteLayer: Codable, Hashable, Sendable {
    public var base: AnimatedLayerBase
    public var clips: [AnimatedSpriteClip]
    public var expressions: AnimatedSpriteExpressions
    /// The clip playing when no control says otherwise.
    public var clipId: String
    /// The face shown when no control says otherwise.
    public var expressionId: String
    public var contentMode: AnimatedContentMode
    /// The default clip's first frame with the default face composited, fitted to a 1024 square.
    public var posterAssetId: String

    public init(
        base: AnimatedLayerBase,
        clips: [AnimatedSpriteClip],
        expressions: AnimatedSpriteExpressions,
        clipId: String,
        expressionId: String,
        contentMode: AnimatedContentMode = .fit,
        posterAssetId: String
    ) {
        self.base = base
        self.clips = clips
        self.expressions = expressions
        self.clipId = clipId
        self.expressionId = expressionId
        self.contentMode = contentMode
        self.posterAssetId = posterAssetId
    }

    private enum CodingKeys: String, CodingKey {
        case type, clips, expressions, clipId, expressionId, contentMode, posterAssetId
    }

    public init(from decoder: Decoder) throws {
        base = try AnimatedLayerBase(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clips = try c.decode([AnimatedSpriteClip].self, forKey: .clips)
        expressions = try c.decode(AnimatedSpriteExpressions.self, forKey: .expressions)
        clipId = try c.decode(String.self, forKey: .clipId)
        expressionId = try c.decode(String.self, forKey: .expressionId)
        contentMode = try c.value(.contentMode, default: .fit)
        posterAssetId = try c.decode(String.self, forKey: .posterAssetId)
    }

    public func encode(to encoder: Encoder) throws {
        try base.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(AnimatedLayerType.sprite, forKey: .type)
        try c.encode(clips, forKey: .clips)
        try c.encode(expressions, forKey: .expressions)
        try c.encode(clipId, forKey: .clipId)
        try c.encode(expressionId, forKey: .expressionId)
        try c.encode(contentMode, forKey: .contentMode)
        try c.encode(posterAssetId, forKey: .posterAssetId)
    }

    /// The clip currently set to play. `isValid` guarantees it exists; the fallback only guards a draw of an invalid layer.
    public var currentClip: AnimatedSpriteClip {
        clips.first { $0.id == clipId } ?? clips[0]
    }

    /// The expression currently set to show, with the same guarantee as `currentClip`.
    public var currentTile: AnimatedSpriteExpressionTile {
        expressions.tiles.first { $0.id == expressionId } ?? expressions.tiles[0]
    }

    /// Whether any clip actually moves; a sprite of single-frame poses is a still with a face.
    public var hasMotion: Bool { clips.contains { $0.frames.count > 1 } }

    public var isValid: Bool {
        base.isValid
            && posterAssetId.isAnimatedUUID
            && (1...8).contains(clips.count) && clips.allSatisfy(\.isValid)
            && Set(clips.map(\.id)).count == clips.count
            && expressions.isValid
            && Set(expressions.tiles.map(\.id)).count == expressions.tiles.count
            && clips.contains { $0.id == clipId }
            && expressions.tiles.contains { $0.id == expressionId }
    }
}
