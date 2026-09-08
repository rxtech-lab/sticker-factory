import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

public enum VideoFrameDecoderError: Error, Equatable {
    case noVideoTrack
    case unreadable
    case keyingFailed(frame: Int)
    case noFrames
}

/// Reads a video layer's clip off disk and keys every frame.
///
/// The one place in the package that decodes video, and deliberately the only one: the renderer,
/// the exporter, and the editor all consume `KeyedVideoFrames` and never see a pixel buffer. The
/// asset provider owns *when* this runs — the app calls it once per clip as the document loads —
/// so the hot path only ever indexes into an array.
///
/// Frames are scaled on the way out of the decoder when the clip is larger than `maxEdge`, which
/// is what keeps a few seconds of footage inside a sensible memory budget: the clip is generated at
/// 480p and a sticker is exported at 618px or less, so nothing larger is ever drawn.
public enum VideoFrameDecoder {
    public static func decode(
        url: URL,
        keyColor: AnimatedVideoKeyColor,
        maxEdge: Int = 480,
        maxFrameCount: Int = 600,
        keyer: (any ChromaKeyer)? = nil
    ) async throws -> KeyedVideoFrames {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoFrameDecoderError.noVideoTrack
        }
        let (naturalSize, nominalFrameRate) = try await track.load(.naturalSize, .nominalFrameRate)
        let keyer = keyer ?? CPUChromaKeyer.automatic
        return try Self.read(
            asset: asset,
            track: track,
            naturalSize: naturalSize,
            frameRate: Double(nominalFrameRate),
            keyColor: keyColor,
            maxEdge: maxEdge,
            maxFrameCount: maxFrameCount,
            keyer: keyer
        )
    }

    private static func read(
        asset: AVAsset,
        track: AVAssetTrack,
        naturalSize: CGSize,
        frameRate: Double,
        keyColor: AnimatedVideoKeyColor,
        maxEdge: Int,
        maxFrameCount: Int,
        keyer: any ChromaKeyer
    ) throws -> KeyedVideoFrames {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw VideoFrameDecoderError.unreadable
        }

        let width = max(1, Int(naturalSize.width.rounded()))
        let height = max(1, Int(naturalSize.height.rounded()))
        let scale = min(1, Double(maxEdge) / Double(max(width, height)))
        // Even dimensions, because the pixel transfer behind the reader rounds odd ones itself and
        // the frames would otherwise come back a pixel off from the size recorded here.
        let outputWidth = max(2, Int((Double(width) * scale).rounded()) & ~1)
        let outputHeight = max(2, Int((Double(height) * scale).rounded()) & ~1)

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outputWidth,
            kCVPixelBufferHeightKey as String: outputHeight
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoFrameDecoderError.unreadable }
        reader.add(output)
        guard reader.startReading() else { throw VideoFrameDecoderError.unreadable }

        var frames: [CGImage] = []
        var frameSize = CGSize(width: outputWidth, height: outputHeight)
        while frames.count < maxFrameCount, let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            guard let keyed = keyer.key(buffer, keyColor: keyColor) else {
                reader.cancelReading()
                throw VideoFrameDecoderError.keyingFailed(frame: frames.count)
            }
            if frames.isEmpty {
                frameSize = CGSize(width: keyed.width, height: keyed.height)
            }
            frames.append(keyed)
        }
        if reader.status == .failed { throw VideoFrameDecoderError.unreadable }
        reader.cancelReading()
        guard !frames.isEmpty else { throw VideoFrameDecoderError.noFrames }
        return KeyedVideoFrames(frames: frames, frameRate: frameRate, size: frameSize)
    }
}
