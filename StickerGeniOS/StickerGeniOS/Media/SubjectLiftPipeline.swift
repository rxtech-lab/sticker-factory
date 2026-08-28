import CoreGraphics
import Foundation
import os

/// Turns a picked photo into something the composer can attach.
///
/// The one seam both pickers know about. Everything upstream of it — the picker ladder, the frame
/// extractor, the segmenter, the atlas encoder — stays private to this folder, and everything
/// downstream sees an ordinary `PendingMediaAttachment` that happens to carry sequence metadata.
/// That is what keeps `CreateStickerView` and `StickerChatView` from growing two copies of this.
@MainActor
enum SubjectLiftPipeline {
    /// Lifts `anchor`'s subject out of `capture` and packs the result for upload.
    ///
    /// Falls back to a single frame whenever motion is unavailable or unwanted — no paired video,
    /// the user turned it off, or every frame past the first failed to segment. A one-frame atlas is
    /// structurally identical to a multi-frame one, so nothing downstream needs to know which
    /// happened; the sticker is simply still.
    static func attachment(
        from capture: LivePhotoCapture,
        anchor: SubjectAnchorDescriptor?,
        includeMotion: Bool,
        settings: SubjectLiftSettings = .default,
        basename: String = "capture"
    ) async throws -> PendingMediaAttachment {
        let segmenter = SubjectSegmenter(settings: settings)

        var lifted: [CGImage?]
        var effective = settings
        if includeMotion, let videoURL = capture.videoURL {
            let frames = try await LivePhotoFrameExtractor.frames(
                of: videoURL,
                centredOn: capture.stillTimeSeconds,
                settings: settings
            )
            // The anchor was taken on the still, which sits at the middle of the sampled window, so
            // that is where tracking starts and walks outward.
            lifted = try await segmenter.lift(frames: frames, anchor: anchor, anchorIndex: frames.count / 2)
            effective.frameCount = frames.count
            SubjectLiftLog.logger.info(
                "pipeline: extracted \(frames.count, privacy: .public) frame(s), lifted \(lifted.compactMap { $0 }.count, privacy: .public)"
            )
        } else {
            lifted = [try await segmenter.lift(from: capture.still, near: anchor)?.image]
            effective = .still
            SubjectLiftLog.logger.info(
                "pipeline: still-only lift, subject=\(lifted.compactMap { $0 }.count == 1, privacy: .public)"
            )
        }

        if lifted.compactMap({ $0 }).isEmpty {
            SubjectLiftLog.logger.error("pipeline: nothing was lifted from any frame")
            throw MediaNormalizationError.liftProducedNoSubject
        }
        let encoded = try FrameAtlasEncoder.encode(frames: lifted, settings: effective)
        SubjectLiftLog.logger.info(
            "pipeline: atlas \(encoded.metadata.columns, privacy: .public)x\(encoded.metadata.rows, privacy: .public) frames=\(encoded.metadata.frameCount, privacy: .public) bytes=\(encoded.data.count, privacy: .public)"
        )
        return .init(
            data: encoded.data,
            filename: "\(basename)-\(encoded.metadata.frameCount)f.png",
            mimeType: "image/png",
            sequence: encoded.metadata
        )
    }
}
