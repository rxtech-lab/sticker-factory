import AnimatedView
import UIKit

@MainActor
enum StickerPlaybackPreparer {
    /// Keyed frames use the same decoder as preview. Original videos never enter a playback bundle.
    static func prepare(document: AnimatedDocument, stickerID: String, api: any StickerAPIClientProtocol) async throws -> AnimatedDocument? {
        let carriesClip = document.layers.contains { if case .video = $0 { true } else { false } }
        guard document.configuration != nil, carriesClip else { return nil }
        var result = document
        for index in result.layers.indices {
            guard case .video(let video) = result.layers[index] else { continue }
            try Task.checkCancellation()
            let decoded = try await StickerVideoFrameLoader.shared.frames(
                assetID: video.assetId, keyColor: video.keyColor, maxEdge: 640, api: api
            )
            guard decoded.isVerified, decoded.frames.frameCount > 0 else {
                throw StickerPublishError.missingVerifiedAssets([video.assetId])
            }
            let count = min(64, video.frameCount)
            let frames = (0..<count).compactMap { decoded.frames.frame(at: Int(Double($0) * Double(video.frameCount) / Double(count))) }
            let rate = Double(count) / (Double(video.frameCount) / video.frameRate)
            let atlas = try FrameAtlasEncoder.encodePlayback(frames: frames, frameRate: rate)
            let assetID = try await api.upload(
                data: atlas.data, stickerID: stickerID, kind: .sequence, filename: "playback-frames.png",
                mimeType: "image/png", sequence: atlas.metadata, idempotencyKey: UUID().uuidString
            )
            result.layers[index] = .sequence(.init(
                base: video.base, assetId: assetID,
                columns: atlas.metadata.columns, rows: atlas.metadata.rows,
                frameCount: count, frameRate: rate, playback: video.playback,
                startSeconds: video.startSeconds, contentMode: video.contentMode, posterAssetId: video.posterAssetId
            ))
        }
        return try result.validated()
    }
}
