import AVFoundation
import CoreGraphics
import Foundation

/// Samples evenly spaced frames out of a Live Photo's paired video.
nonisolated enum LivePhotoFrameExtractor {
    /// The frames to lift a subject out of, in playback order.
    ///
    /// Sampling is centred on `centreSeconds` — the instant the still corresponds to — and clamped
    /// into the video. That matters because the user picked their subject on the still, so the
    /// frames nearest it are the ones where that choice is most certainly right, and tracking walks
    /// outward from there.
    static func frames(
        of url: URL,
        centredOn centreSeconds: Double?,
        settings: SubjectLiftSettings
    ) async throws -> [CGImage] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw LivePhotoImportError.unreadableVideo }

        let window = min(settings.windowSeconds, duration)
        let centre = centreSeconds.map { min(max($0, 0), duration) } ?? duration / 2
        let start = min(max(centre - window / 2, 0), max(duration - window, 0))
        let times = (0..<settings.frameCount).map { index in
            CMTime(seconds: min(start + Double(index) / settings.frameRate, duration), preferredTimescale: 600)
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // The segmenter runs once per frame, so capping here is the single biggest cost lever —
        // and 1280 is already twice the tile the frames end up in.
        if let longEdge = settings.quality.segmentationLongEdge {
            generator.maximumSize = CGSize(width: longEdge, height: longEdge)
        }
        // Well under half the sampling interval, so two requests can never collapse onto the same
        // decoded frame — which would produce a sequence that stutters rather than moves — while
        // staying far cheaper than demanding exact times.
        let tolerance = CMTime(seconds: 1.0 / 120, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        // `images(for:)` makes no ordering promise, so results are keyed by the time that was asked
        // for and re-sorted. Frames that fail to decode are dropped rather than left as gaps: an
        // empty tile mid-sequence reads as a rendering fault, a slightly shorter sequence does not.
        var decoded: [Double: CGImage] = [:]
        for await result in generator.images(for: times) {
            guard let image = try? result.image else { continue }
            decoded[result.requestedTime.seconds] = image
        }
        let ordered = times.compactMap { decoded[$0.seconds] }
        guard !ordered.isEmpty else { throw LivePhotoImportError.unreadableVideo }
        return ordered
    }

    /// The first decodable frame, used as a stand-in still when the picker gave us only a movie.
    static func firstFrame(of url: URL) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let duration = try await asset.load(.duration).seconds
        let midpoint = CMTime(seconds: duration.isFinite ? duration / 2 : 0, preferredTimescale: 600)
        return try await generator.image(at: midpoint).image
    }
}
