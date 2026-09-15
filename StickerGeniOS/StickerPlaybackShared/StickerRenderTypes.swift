import AnimatedView
import Foundation
import UIKit

nonisolated enum StickerExportFormat: String, Codable, CaseIterable, Hashable, Sendable { case png, gif, apng, mp4, webp }

nonisolated struct LocalExportMetadata: Codable, Hashable, Sendable {
    var format: StickerExportFormat
    var width: Int
    var height: Int
    var byteCount: Int
    var durationSeconds: Double?
    var fps: Int?
    var hasAlpha: Bool
}

nonisolated struct StickerRenderAssets: Sendable {
    var images: [String: UIImage]
    var videos: [String: KeyedVideoFrames]

    init(images: [String: UIImage] = [:], videos: [String: KeyedVideoFrames] = [:]) {
        self.images = images
        self.videos = videos
    }

    @MainActor
    var dictionary: AnimatedAssetDictionary {
        AnimatedAssetDictionary(images: images, videos: videos)
    }
}


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
                throw DecodingError.dataCorruptedError(
                    forKey: .colors, in: container, debugDescription: "A linear gradient requires two colors"
                )
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
        case .solid(let color): color.isAnimatedHexColor
        case .linearGradient(let colors, let angle):
            colors.count == 2 && colors.allSatisfy(\.isAnimatedHexColor) && (0...360).contains(angle)
        }
    }

    /// The document-level equivalent, for rendering a frame against this background.
    var animatedBackground: AnimatedBackground {
        switch self {
        case .solid(let color):
            .solid(color)
        case .linearGradient(let colors, let angleDegrees):
            .linearGradient(colors[0], colors[1], angleDegrees: angleDegrees)
        }
    }

    /// The export request's spelling of a document's MP4 background.
    ///
    /// Returns `nil` for the shapes the request cannot express — a radial gradient, an image, or
    /// `none` — so a caller has to decide what to send rather than silently shipping the wrong fill.
    init?(_ background: AnimatedBackground) {
        switch background {
        case .solid(let color):
            self = .solid(color)
        case .linearGradient(let stops, let angleDegrees) where stops.count >= 2:
            self = .linearGradient(
                colors: [stops.first!.color, stops.last!.color],
                angleDegrees: min(max(angleDegrees, 0), 360)
            )
        default:
            return nil
        }
    }
}

nonisolated enum StickerDocumentValidationError: Error, Equatable, LocalizedError {
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            String(localized: "This sticker was made with a newer version of the app (document version \(version)).")
        }
    }
}
