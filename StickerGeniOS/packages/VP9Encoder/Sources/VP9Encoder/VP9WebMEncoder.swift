import Foundation

/// One RGBA frame handed to the encoder. Rows are `bytesPerRow` apart; pixels are R, G, B, A.
public struct RGBAFrame: Sendable {
    public var width: Int
    public var height: Int
    public var bytesPerRow: Int
    public var pixels: [UInt8]
    /// Whether colour is premultiplied by alpha — what Core Graphics produces for
    /// `premultipliedLast`. Un-premultiplied before encoding so soft edges keep their colour.
    public var isPremultiplied: Bool

    public init(width: Int, height: Int, bytesPerRow: Int, pixels: [UInt8], isPremultiplied: Bool = true) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixels = pixels
        self.isPremultiplied = isPremultiplied
    }
}

/// Encodes RGBA frames into a transparent VP9 WebM.
///
/// Two VP9 streams are run in step: one for colour (BT.601, limited range, 4:2:0) and one for
/// alpha, carried as the luma of a grey stream and muxed as each block's `BlockAdditional`. That is
/// the layout FFmpeg produces for `-pix_fmt yuva420p -c:v libvpx-vp9`, which is what Telegram's
/// import documentation points at and what its clients decode.
///
/// Not thread-safe; use one instance per encode, from one task.
public final class VP9WebMEncoder {
    public struct Settings: Sendable {
        /// The byte budget the whole file should land under. Rate control targets a bitrate
        /// derived from it and the expected duration; callers check the result and retry lower.
        public var colorBitrateKilobits: Int
        public var alphaBitrateKilobits: Int
        public var speed: Int
        public var threads: Int

        public init(colorBitrateKilobits: Int, alphaBitrateKilobits: Int, speed: Int = 5, threads: Int = 4) {
            self.colorBitrateKilobits = colorBitrateKilobits
            self.alphaBitrateKilobits = alphaBitrateKilobits
            self.speed = speed
            self.threads = threads
        }

        /// Splits a byte budget over a duration into the two streams' targets.
        ///
        /// The alpha of a cutout is mostly flat 0 or 255 and compresses to a fraction of the
        /// colour, so it is given a fifth of the rate. The headroom factor leaves room for the
        /// container and for VBR overshoot; the caller still measures and retries.
        public static func fitting(byteBudget: Int, durationMilliseconds: Int, headroom: Double = 0.85, speed: Int = 5) -> Settings {
            let seconds = max(0.05, Double(durationMilliseconds) / 1_000)
            let kilobits = Double(byteBudget) * 8 / 1_000 / seconds * headroom
            return Settings(
                colorBitrateKilobits: max(20, Int(kilobits * 0.8)),
                alphaBitrateKilobits: max(8, Int(kilobits * 0.2)),
                speed: speed
            )
        }
    }

    public enum Failure: Error, Sendable, Equatable {
        case frameSizeMismatch
        case packetCountMismatch
        case noFrames
    }

    public let width: Int
    public let height: Int
    private let color: VP9StreamEncoder
    private let alpha: VP9StreamEncoder
    private var frames: [WebMFrame] = []
    private var timestamp = 0
    private var yPlane: [UInt8]
    private var uPlane: [UInt8]
    private var vPlane: [UInt8]
    private var aPlane: [UInt8]
    private var isFinished = false

    public init(width: Int, height: Int, settings: Settings) throws {
        self.width = width
        self.height = height
        color = try VP9StreamEncoder(
            width: width, height: height,
            targetBitrateKilobits: settings.colorBitrateKilobits,
            speed: settings.speed, threads: settings.threads
        )
        // Full range: the alpha plane is copied straight into luma and back out again, so 0 must
        // stay 0 and 255 must stay 255 rather than being squeezed into 16…235.
        alpha = try VP9StreamEncoder(
            width: width, height: height,
            targetBitrateKilobits: settings.alphaBitrateKilobits,
            speed: settings.speed, threads: settings.threads,
            fullRange: true
        )
        let chromaWidth = (width + 1) / 2
        let chromaHeight = (height + 1) / 2
        yPlane = [UInt8](repeating: 0, count: width * height)
        uPlane = [UInt8](repeating: 128, count: chromaWidth * chromaHeight)
        vPlane = [UInt8](repeating: 128, count: chromaWidth * chromaHeight)
        aPlane = [UInt8](repeating: 0, count: width * height)
    }

    /// Encodes one frame shown for `durationMilliseconds`.
    public func append(_ frame: RGBAFrame, durationMilliseconds: Int) throws {
        guard !isFinished else { return }
        guard frame.width == width, frame.height == height, frame.pixels.count >= frame.bytesPerRow * frame.height else {
            throw Failure.frameSizeMismatch
        }
        PixelConversion.convert(frame, y: &yPlane, u: &uPlane, v: &vPlane, alpha: &aPlane)
        let duration = max(1, durationMilliseconds)
        let pts = Int64(timestamp)
        let chromaWidth = (width + 1) / 2
        let chromaHeight = (height + 1) / 2

        let colorPackets = try color.encode(pts: pts, durationMilliseconds: duration) { planes, strides in
            Self.copy(yPlane, width: width, height: height, into: planes[0], stride: strides[0])
            Self.copy(uPlane, width: chromaWidth, height: chromaHeight, into: planes[1], stride: strides[1])
            Self.copy(vPlane, width: chromaWidth, height: chromaHeight, into: planes[2], stride: strides[2])
        }
        let alphaPackets = try alpha.encode(pts: pts, durationMilliseconds: duration) { planes, strides in
            Self.copy(aPlane, width: width, height: height, into: planes[0], stride: strides[0])
            Self.fill(128, width: chromaWidth, height: chromaHeight, into: planes[1], stride: strides[1])
            Self.fill(128, width: chromaWidth, height: chromaHeight, into: planes[2], stride: strides[2])
        }
        try pair(colorPackets, alphaPackets, duration: duration)
        timestamp += duration
    }

    /// The finished WebM file. Consumes the encoders; a second call returns the same bytes.
    public func finish() throws -> Data {
        if !isFinished {
            isFinished = true
            let colorPackets = try color.finish()
            let alphaPackets = try alpha.finish()
            // Nothing is expected here without lookahead; anything that does arrive has no
            // duration of its own and is paired at the last known cadence.
            try pair(colorPackets, alphaPackets, duration: frames.last?.durationMilliseconds ?? 33)
        }
        guard !frames.isEmpty else { throw Failure.noFrames }
        return try WebMWriter.write(frames: frames, width: width, height: height, hasAlpha: true)
    }

    private func pair(_ colorPackets: [VP9StreamEncoder.Packet], _ alphaPackets: [VP9StreamEncoder.Packet], duration: Int) throws {
        guard colorPackets.count == alphaPackets.count else { throw Failure.packetCountMismatch }
        for (colorPacket, alphaPacket) in zip(colorPackets, alphaPackets) {
            frames.append(WebMFrame(
                color: colorPacket.data,
                alpha: alphaPacket.data,
                isKeyframe: colorPacket.isKeyframe,
                timestampMilliseconds: Int(colorPacket.pts),
                durationMilliseconds: duration
            ))
        }
    }

    private static func copy(_ plane: [UInt8], width: Int, height: Int, into destination: UnsafeMutablePointer<UInt8>, stride: Int) {
        plane.withUnsafeBufferPointer { source in
            for row in 0..<height {
                (destination + row * stride).update(from: source.baseAddress! + row * width, count: width)
            }
        }
    }

    private static func fill(_ value: UInt8, width: Int, height: Int, into destination: UnsafeMutablePointer<UInt8>, stride: Int) {
        for row in 0..<height {
            (destination + row * stride).update(repeating: value, count: width)
        }
    }
}

/// RGBA → planar YUV 4:2:0 plus a separate alpha plane.
enum PixelConversion {
    /// BT.601 limited range, the default a decoder assumes for an untagged VP9 stream.
    ///
    /// Transparent pixels get the frame's average opaque colour rather than the black that
    /// un-premultiplying leaves behind: chroma is shared between neighbouring pixels, so a black
    /// halo around every cutout would otherwise bleed into its edge once the alpha is reapplied.
    static func convert(_ frame: RGBAFrame, y: inout [UInt8], u: inout [UInt8], v: inout [UInt8], alpha: inout [UInt8]) {
        let width = frame.width
        let height = frame.height
        let chromaWidth = (width + 1) / 2

        // Straight (un-premultiplied) RGB for the frame, and the fill colour for cleared pixels.
        var straight = [UInt8](repeating: 0, count: width * height * 3)
        var sumR = 0, sumG = 0, sumB = 0, opaqueCount = 0
        frame.pixels.withUnsafeBufferPointer { pixels in
            for row in 0..<height {
                let rowBase = row * frame.bytesPerRow
                for column in 0..<width {
                    let offset = rowBase + column * 4
                    let a = Int(pixels[offset + 3])
                    var r = Int(pixels[offset])
                    var g = Int(pixels[offset + 1])
                    var b = Int(pixels[offset + 2])
                    if frame.isPremultiplied, a > 0, a < 255 {
                        r = min(255, (r * 255 + a / 2) / a)
                        g = min(255, (g * 255 + a / 2) / a)
                        b = min(255, (b * 255 + a / 2) / a)
                    }
                    let index = (row * width + column) * 3
                    straight[index] = UInt8(r)
                    straight[index + 1] = UInt8(g)
                    straight[index + 2] = UInt8(b)
                    alpha[row * width + column] = UInt8(a)
                    if a > 0 {
                        sumR += r; sumG += g; sumB += b; opaqueCount += 1
                    }
                }
            }
        }
        let fillR = opaqueCount > 0 ? sumR / opaqueCount : 128
        let fillG = opaqueCount > 0 ? sumG / opaqueCount : 128
        let fillB = opaqueCount > 0 ? sumB / opaqueCount : 128
        for index in 0..<(width * height) where alpha[index] == 0 {
            straight[index * 3] = UInt8(fillR)
            straight[index * 3 + 1] = UInt8(fillG)
            straight[index * 3 + 2] = UInt8(fillB)
        }

        // Luma per pixel; chroma averaged over each 2×2 block.
        for row in 0..<height {
            for column in 0..<width {
                let index = (row * width + column) * 3
                let r = Int(straight[index]), g = Int(straight[index + 1]), b = Int(straight[index + 2])
                y[row * width + column] = UInt8(clamping: 16 + ((66 * r + 129 * g + 25 * b + 128) >> 8))
            }
        }
        for chromaRow in 0..<((height + 1) / 2) {
            for chromaColumn in 0..<chromaWidth {
                var r = 0, g = 0, b = 0, count = 0
                for dy in 0..<2 {
                    let row = chromaRow * 2 + dy
                    guard row < height else { continue }
                    for dx in 0..<2 {
                        let column = chromaColumn * 2 + dx
                        guard column < width else { continue }
                        let index = (row * width + column) * 3
                        r += Int(straight[index]); g += Int(straight[index + 1]); b += Int(straight[index + 2])
                        count += 1
                    }
                }
                guard count > 0 else { continue }
                r /= count; g /= count; b /= count
                let chromaIndex = chromaRow * chromaWidth + chromaColumn
                u[chromaIndex] = UInt8(clamping: 128 + ((-38 * r - 74 * g + 112 * b + 128) >> 8))
                v[chromaIndex] = UInt8(clamping: 128 + ((112 * r - 94 * g - 18 * b + 128) >> 8))
            }
        }
    }
}
