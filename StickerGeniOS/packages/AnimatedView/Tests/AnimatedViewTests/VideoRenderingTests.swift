import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import Testing
@testable import AnimatedView

/// The video layer, from a real H.264 clip through the keyer to drawable frames.
///
/// The clip is written by the test itself with `AVAssetWriter`, so the round trip covers the same
/// codec the server accepts (`inspectMp4` requires H.264) and the same chroma-subsampled edges a
/// generated clip has, rather than a synthetic buffer that keys too cleanly to prove anything.
struct VideoRenderingTests {
    private let assetID = "44444444-4444-4444-8444-444444444444"
    private let posterID = "55555555-5555-4555-8555-555555555555"

    // MARK: - Fixtures

    /// One BGRA frame: `background` everywhere, `subject` in the centre square.
    private func pixelBuffer(
        side: Int,
        background: (b: UInt8, g: UInt8, r: UInt8),
        subject: (b: UInt8, g: UInt8, r: UInt8),
        pool: CVPixelBufferPool? = nil
    ) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        } else {
            CVPixelBufferCreate(nil, side, side, kCVPixelFormatType_32BGRA, nil, &buffer)
        }
        let pixelBuffer = buffer!
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let inset = side / 4
        for y in 0..<side {
            for x in 0..<side {
                let p = base + y * stride + x * 4
                let isSubject = (inset..<(side - inset)).contains(x) && (inset..<(side - inset)).contains(y)
                let colour = isSubject ? subject : background
                p[0] = colour.b
                p[1] = colour.g
                p[2] = colour.r
                p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    /// Writes a short H.264 clip: a red square on a green screen, `frameCount` frames at `fps`.
    private func writeClip(side: Int = 64, frameCount: Int = 4, fps: Int = 10) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "video-rendering-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: side,
            AVVideoHeightKey: side
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: side,
                kCVPixelBufferHeightKey as String: side
            ]
        )
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            let frame = pixelBuffer(
                side: side,
                background: (b: 0, g: 255, r: 0),
                subject: (b: 20, g: 20, r: 220),
                pool: adaptor.pixelBufferPool
            )
            #expect(adaptor.append(frame, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed, "\(String(describing: writer.error))")
        return url
    }

    /// The BGRA bytes of a keyed frame, read back through a bitmap context.
    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let width = image.width
        let height = image.height
        let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: width * height * 4)
        defer { buffer.deallocate() }
        buffer.initialize(repeating: 0)
        let context = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let offset = (y * width + x) * 4
        return (Int(buffer[offset]), Int(buffer[offset + 1]), Int(buffer[offset + 2]), Int(buffer[offset + 3]))
    }

    private func videoLayer(frameCount: Int = 4, frameRate: Double = 10, playback: AnimatedSequencePlayback = .loop) -> AnimatedVideoLayer {
        .init(
            base: .init(id: "hero", name: "Video clip"),
            assetId: assetID,
            keyColor: .green,
            frameCount: frameCount,
            frameRate: frameRate,
            playback: playback,
            posterAssetId: posterID
        )
    }

    // MARK: - Keying

    @Test func cpuKeyerMatchesTheServerArithmetic() {
        let keyer = CPUChromaKeyer()
        // Background well past the keyed threshold, subject with no green dominance, and an edge
        // pixel exactly halfway across the band: dominance 75 → keyness 0.5.
        let side = 8
        let buffer = pixelBuffer(side: side, background: (b: 0, g: 255, r: 0), subject: (b: 30, g: 30, r: 200))
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        base[0] = 50; base[1] = 175; base[2] = 100; base[3] = 255 // edge pixel at (0, 0)
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let keyed = keyer.key(buffer, keyColor: .green)!
        let background = pixel(keyed, x: side - 1, y: side - 1)
        #expect(background.a == 0)
        #expect(background.r == 0 && background.g == 0 && background.b == 0)

        let subject = pixel(keyed, x: side / 2, y: side / 2)
        #expect(subject.a == 255)
        #expect(abs(subject.r - 200) <= 1 && abs(subject.g - 30) <= 1 && abs(subject.b - 30) <= 1)

        let edge = pixel(keyed, x: 0, y: 0)
        // Alpha halved, green despilled down to the rival (100), then premultiplied by 128/255.
        #expect(abs(edge.a - 128) <= 1)
        #expect(abs(edge.g - 50) <= 2, "despill should clamp green to the rival channel: \(edge)")
        #expect(abs(edge.r - 50) <= 2)
        #expect(abs(edge.b - 25) <= 2)
    }

    @Test func coreImageKeyerAgreesWithTheCPUKeyer() {
        guard let gpu = CoreImageChromaKeyer() else {
            // The string-kernel API is deprecated; a system without it falls back to the CPU loop,
            // which is exactly the behaviour under test elsewhere.
            return
        }
        let side = 8
        let buffer = pixelBuffer(side: side, background: (b: 0, g: 255, r: 0), subject: (b: 30, g: 30, r: 200))
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        base[0] = 50; base[1] = 175; base[2] = 100; base[3] = 255
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let expected = CPUChromaKeyer().key(buffer, keyColor: .green)!
        let actual = gpu.key(buffer, keyColor: .green)!
        for (x, y) in [(0, 0), (side / 2, side / 2), (side - 1, side - 1)] {
            let a = pixel(actual, x: x, y: y)
            let e = pixel(expected, x: x, y: y)
            #expect(
                abs(a.a - e.a) <= 3 && abs(a.r - e.r) <= 3 && abs(a.g - e.g) <= 3 && abs(a.b - e.b) <= 3,
                "(\(x),\(y)) gpu=\(a) cpu=\(e)"
            )
        }
    }

    @Test func decodesAndKeysAnH264Clip() async throws {
        let url = try await writeClip()
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = try await VideoFrameDecoder.decode(url: url, keyColor: .green)
        #expect(clip.frameCount == 4)
        #expect(clip.size == CGSize(width: 64, height: 64))
        #expect(abs(clip.frameRate - 10) < 0.5)

        for frame in clip.frames {
            let corner = pixel(frame, x: 2, y: 2)
            #expect(corner.a == 0, "green screen should key to transparent: \(corner)")
            let centre = pixel(frame, x: 32, y: 32)
            #expect(centre.a == 255)
            #expect(centre.r > 180 && centre.g < 70 && centre.b < 70, "subject colour should survive keying: \(centre)")
        }
    }

    @Test func decodingScalesDownToTheRequestedEdge() async throws {
        let url = try await writeClip(side: 128, frameCount: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let clip = try await VideoFrameDecoder.decode(url: url, keyColor: .green, maxEdge: 64)
        #expect(clip.size.width <= 64 && clip.size.height <= 64)
        #expect(clip.frameCount == 2)
    }

    // MARK: - Frame index

    @Test func videoFrameIndexMatchesSequenceFrameIndex() {
        let times = stride(from: -0.1, through: 2.5, by: 0.037).map { $0 }
        for playback in AnimatedSequencePlayback.allCases {
            let video = videoLayer(frameCount: 7, frameRate: 12, playback: playback)
            let sequence = AnimatedSequenceLayer(
                base: .init(id: "s", name: "s"), assetId: assetID, columns: 4, rows: 2,
                frameCount: 7, frameRate: 12, playback: playback
            )
            for time in times {
                #expect(
                    AnimationInterpolator.videoFrameIndex(video, atDocumentTime: time)
                        == AnimationInterpolator.sequenceFrameIndex(sequence, atDocumentTime: time)
                )
            }
        }
    }

    // MARK: - Model

    @Test func videoLayerRoundTrips() throws {
        let layer = AnimatedLayer.video(videoLayer(playback: .pingPong))
        let data = try JSONEncoder().encode(layer)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "video")
        #expect(json["keyColor"] as? String == "green")
        #expect(json["posterAssetId"] as? String == posterID)

        let decoded = try JSONDecoder().decode(AnimatedLayer.self, from: data)
        #expect(decoded == layer)
        #expect(decoded.referencedImageAssetIDs == [posterID])
        #expect(decoded.referencedVideoAssetIDs == [assetID])
        #expect(decoded.type == .video)
        #expect(!decoded.type.isAuthorable)
    }

    @Test func versionFourDocumentValidates() throws {
        let document = AnimatedDocument(
            version: 4, kind: .animated, durationSeconds: 3, fps: 24, layers: [.video(videoLayer(frameCount: 72, frameRate: 24))]
        )
        #expect(AnimatedDocument.currentVersion == 7)
        try document.validated()
        var older = document
        older.version = 3
        try older.validated()
        var newer = document
        newer.version = 8
        #expect(throws: AnimatedDocumentError.unsupportedVersion(8)) { try newer.validated() }
    }

    @Test func rejectsAVideoLayerWithoutAPoster() {
        var layer = videoLayer()
        layer.posterAssetId = "not-a-uuid"
        #expect(!AnimatedLayer.video(layer).isValid)
    }

    @Test @MainActor func rendersTheKeyedFrameAndFallsBackToThePoster() async throws {
        let url = try await writeClip()
        defer { try? FileManager.default.removeItem(at: url) }
        let clip = try await VideoFrameDecoder.decode(url: url, keyColor: .green)
        let layer = videoLayer()
        let withClip = AnimatedAssetDictionary(videos: [assetID: clip])
        VideoFrameCache.shared.removeAll()
        let frame = try #require(VideoFrameCache.shared.frame(for: layer, index: 2, assets: withClip))
        #expect(frame.animatedCGImage != nil)
        // Past the end clamps to the last frame rather than vanishing.
        #expect(VideoFrameCache.shared.frame(for: layer, index: 99, assets: withClip) != nil)
        #expect(VideoFrameCache.shared.frame(for: layer, index: 0, assets: AnimatedAssetDictionary()) == nil)
    }
}
