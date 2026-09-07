import Foundation
import Testing
@testable import VP9Encoder

/// The encoder is checked against a reader and a decoder that share no code with the muxer or the
/// encoding path: `WebMReader` walks the EBML structure on its own, and `VP9Decoder` is libvpx's
/// decoder, which is what every player uses.
@Suite("VP9 WebM encoder")
struct VP9WebMEncoderTests {
    /// A soft-edged coloured disc moving across a transparent canvas, so both the colour and the
    /// alpha stream have something to encode and the alpha has every value between 0 and 255.
    private func frame(index: Int, count: Int, side: Int) -> RGBAFrame {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let radius = Double(side) * 0.3
        let centreX = Double(side) * (0.3 + 0.4 * Double(index) / Double(max(1, count - 1)))
        let centreY = Double(side) / 2
        for y in 0..<side {
            for x in 0..<side {
                let distance = ((Double(x) - centreX) * (Double(x) - centreX) + (Double(y) - centreY) * (Double(y) - centreY)).squareRoot()
                let coverage = max(0, min(1, (radius - distance) / 8 + 0.5))
                let alpha = UInt8(coverage * 255)
                let offset = (y * side + x) * 4
                // Premultiplied, the way Core Graphics hands frames over.
                pixels[offset] = UInt8(Double(230) * coverage)
                pixels[offset + 1] = UInt8(Double(90) * coverage)
                pixels[offset + 2] = UInt8(Double(60) * coverage)
                pixels[offset + 3] = alpha
            }
        }
        return RGBAFrame(width: side, height: side, bytesPerRow: side * 4, pixels: pixels, isPremultiplied: true)
    }

    @Test("A transparent animation round-trips through an independent reader and libvpx's decoder")
    func roundTrip() throws {
        let side = 128
        let count = 12
        let encoder = try VP9WebMEncoder(
            width: side, height: side,
            settings: .fitting(byteBudget: 256 * 1024, durationMilliseconds: count * 40)
        )
        for index in 0..<count {
            try encoder.append(frame(index: index, count: count, side: side), durationMilliseconds: 40)
        }
        let data = try encoder.finish()

        let document = try WebMReader.read(data)
        #expect(document.docType == "webm")
        #expect(document.timecodeScaleNanoseconds == 1_000_000)
        #expect(document.track?.codecID == "V_VP9")
        #expect(document.track?.pixelWidth == side)
        #expect(document.track?.pixelHeight == side)
        #expect(document.track?.alphaMode == 1)
        #expect(document.blocks.count == count)
        #expect(document.blocks.first?.isKeyframe == true)
        #expect(document.blocks.map(\.timestampMilliseconds) == (0..<count).map { $0 * 40 })
        #expect(document.durationMilliseconds == Double(count * 40))
        #expect(document.blocks.allSatisfy { $0.alpha != nil })

        let color = try VP9Decoder()
        let alpha = try VP9Decoder()
        for block in document.blocks {
            let decodedColor = try color.decode(block.color)
            #expect(decodedColor.width == side && decodedColor.height == side)
            let decodedAlpha = try alpha.decode(try #require(block.alpha))
            #expect(decodedAlpha.width == side && decodedAlpha.height == side)
            // A corner is transparent, the centre of the disc is opaque.
            #expect(decodedAlpha.luma[0] < 8)
            #expect(decodedAlpha.luma[(side / 2) * side + side / 2] > 247)
        }
    }

    @Test("Frames of the wrong size are refused")
    func mismatchedFrames() throws {
        let encoder = try VP9WebMEncoder(width: 64, height: 64, settings: .fitting(byteBudget: 100_000, durationMilliseconds: 100))
        #expect(throws: VP9WebMEncoder.Failure.frameSizeMismatch) {
            try encoder.append(frame(index: 0, count: 1, side: 32), durationMilliseconds: 40)
        }
    }

    @Test("An empty animation is refused")
    func empty() throws {
        let encoder = try VP9WebMEncoder(width: 64, height: 64, settings: .fitting(byteBudget: 100_000, durationMilliseconds: 100))
        #expect(throws: VP9WebMEncoder.Failure.noFrames) { try encoder.finish() }
    }

    @Test("EBML sizes are written at their minimal width")
    func vintWidths() {
        #expect(EBML.vint(0) == [0x80])
        #expect(EBML.vint(126) == [0xFE])
        #expect(EBML.vint(127) == [0x40, 0x7F])
        #expect(EBML.vint(16_382) == [0x7F, 0xFE])
        #expect(EBML.vint(16_383) == [0x20, 0x3F, 0xFF])
    }
}
