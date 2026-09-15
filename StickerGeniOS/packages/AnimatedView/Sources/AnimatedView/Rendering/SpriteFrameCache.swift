import CoreGraphics
import Foundation

/// Composited frames of a sprite layer: one body cell with one expression drawn into its face slot.
///
/// This is the Swift half of the one draw rule the server's `compositeSpriteFrame` also follows: the
/// body cell is cut from its clip sheet with integer cell arithmetic (exactly as `FrameAtlasCache`
/// cuts a capture tile), the expression tile is cut from the expression sheet by its registered
/// bounds, scaled so its width is `faceSize * cellWidth * faceOvercover` with its own aspect kept,
/// and drawn centred on `(faceX, faceY)`. Anything that falls outside the cell is cropped.
///
/// Cached for the same reason `FrameAtlasCache` is: the renderer asks for a frame on every tick and
/// the exporter once per exported frame. Keyed by both sheets and both selections, since the same
/// body can be shown with any face.
@MainActor
public final class SpriteFrameCache {
    public static let shared = SpriteFrameCache()

    /// How much wider than the registered slot a face is drawn. Shared with the server's
    /// `FACE_OVERCOVER` so the two renderers hide the same hairline of body colour round the slot.
    public nonisolated static let faceOvercover = 1.08

    private let capacity: Int
    private var storage: [Key: PlatformImage] = [:]
    private var order: [Key] = []

    public init(capacity: Int = 256) {
        self.capacity = capacity
    }

    private struct Key: Hashable {
        let clipAssetId: String
        let columns: Int
        let rows: Int
        let index: Int
        let sheetAssetId: String
        let tileId: String
        let face: AnimatedSpriteFrame
    }

    /// The composited frame at `index` of the layer's current clip with its current expression, or
    /// `nil` while either sheet has not loaded or the index falls outside the clip.
    public func frame(for layer: AnimatedSpriteLayer, index: Int, assets: any AnimatedAssetProvider) -> PlatformImage? {
        let clip = layer.currentClip
        let tile = layer.currentTile
        guard clip.columns > 0, clip.rows > 0, index >= 0, index < clip.frames.count else { return nil }
        let key = Key(
            clipAssetId: clip.assetId, columns: clip.columns, rows: clip.rows, index: index,
            sheetAssetId: layer.expressions.assetId, tileId: tile.id, face: clip.frames[index]
        )
        if let cached = storage[key] {
            touch(key)
            return cached
        }
        guard let sheet = assets.image(for: clip.assetId)?.animatedCGImage,
              let faces = assets.image(for: layer.expressions.assetId)?.animatedCGImage,
              let composed = Self.composite(sheet: sheet, faces: faces, clip: clip, index: index, tile: tile)
        else { return nil }
        let image = PlatformImage(animatedCGImage: composed)
        storage[key] = image
        order.append(key)
        evictIfNeeded()
        return image
    }

    /// The draw itself, `nonisolated` so the export path and tests can call it without the cache.
    public nonisolated static func composite(
        sheet: CGImage,
        faces: CGImage,
        clip: AnimatedSpriteClip,
        index: Int,
        tile: AnimatedSpriteExpressionTile
    ) -> CGImage? {
        guard index >= 0, index < clip.frames.count else { return nil }
        let frame = clip.frames[index]
        let cellWidth = sheet.width / clip.columns
        let cellHeight = sheet.height / clip.rows
        guard cellWidth > 0, cellHeight > 0 else { return nil }
        let cellRect = CGRect(
            x: (index % clip.columns) * cellWidth,
            y: (index / clip.columns) * cellHeight,
            width: cellWidth,
            height: cellHeight
        )
        guard let cell = sheet.cropping(to: cellRect) else { return nil }

        let sheetBounds = CGRect(x: 0, y: 0, width: faces.width, height: faces.height)
        let tileRect = CGRect(
            x: (tile.x * Double(faces.width)).rounded(),
            y: (tile.y * Double(faces.height)).rounded(),
            width: max(1, (tile.width * Double(faces.width)).rounded()),
            height: max(1, (tile.height * Double(faces.height)).rounded())
        ).intersection(sheetBounds)
        guard !tileRect.isNull, tileRect.width >= 1, tileRect.height >= 1, let face = faces.cropping(to: tileRect) else { return nil }

        guard let context = CGContext(
            data: nil,
            width: cellWidth,
            height: cellHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cell, in: CGRect(x: 0, y: 0, width: cellWidth, height: cellHeight))

        let faceWidth = max(1, (frame.faceSize * Double(cellWidth) * faceOvercover).rounded())
        let faceHeight = max(1, (faceWidth * tileRect.height / tileRect.width).rounded())
        // The slot is registered top-down; CoreGraphics draws bottom-up, so the y flips here and
        // nowhere else.
        let centre = CGPoint(x: frame.faceX * Double(cellWidth), y: Double(cellHeight) - frame.faceY * Double(cellHeight))
        context.draw(face, in: CGRect(x: centre.x - faceWidth / 2, y: centre.y - faceHeight / 2, width: faceWidth, height: faceHeight))
        return context.makeImage()
    }

    private func touch(_ key: Key) {
        guard let index = order.firstIndex(of: key) else { return }
        order.remove(at: index)
        order.append(key)
    }

    private func evictIfNeeded() {
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            storage[oldest] = nil
        }
    }

    public func removeAll() {
        storage.removeAll()
        order.removeAll()
    }
}
