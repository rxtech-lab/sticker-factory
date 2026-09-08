import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// The dominance band shared with `chromaKeyBackground` in `server/lib/ai/chroma-key.ts`.
///
/// A pixel whose key channel runs ahead of the brightest rival by less than `opaque` is subject
/// and left alone; by `keyed` or more it is backdrop and cleared; in between it is an edge and gets
/// a partial alpha. The two implementations must agree, or a sticker keyed here would have a
/// different rim from the still the server keyed for the same plan.
public enum ChromaKeyDominance {
    public static let opaque: Double = 40
    public static let keyed: Double = 110
}

/// Turns one opaque BGRA frame shot against a chroma backdrop into a `CGImage` with real alpha.
///
/// Two implementations, chosen at decode time: Core Image on the GPU when its kernel compiles, and
/// a plain per-pixel loop otherwise. Both implement the same arithmetic as the server, including
/// the despill — clamping the key channel down to the brightest rival — without which every edge
/// pixel keeps a rim of green that shows the moment the sticker lands on a dark bubble.
public protocol ChromaKeyer: Sendable {
    /// - Parameter pixelBuffer: a `kCVPixelFormatType_32BGRA` buffer, as `VideoFrameDecoder` reads.
    func key(_ pixelBuffer: CVPixelBuffer, keyColor: AnimatedVideoKeyColor) -> CGImage?
}

extension ChromaKeyer where Self == CPUChromaKeyer {
    /// Core Image when it is available, the CPU loop otherwise.
    public static var automatic: any ChromaKeyer {
        CoreImageChromaKeyer() ?? CPUChromaKeyer()
    }
}

/// The reference implementation: a per-pixel loop over the BGRA bytes.
///
/// Deterministic and dependency-free, which is what makes it the one the tests pin the Core Image
/// kernel against. Fast enough on its own for a few seconds of 480p — tens of millions of pixels
/// through a tight unsafe-pointer loop is a fraction of a second.
public struct CPUChromaKeyer: ChromaKeyer {
    public init() {}

    public func key(_ pixelBuffer: CVPixelBuffer, keyColor: AnimatedVideoKeyColor) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let sourceStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let outputStride = width * 4
        var output = [UInt8](repeating: 0, count: outputStride * height)

        // BGRA in memory: the key channel's byte offset within a pixel, and its rivals'.
        let keyOffset = keyColor == .green ? 1 : 0
        let otherOffset = keyColor == .green ? 0 : 1
        let redOffset = 2
        let opaque = ChromaKeyDominance.opaque
        let keyed = ChromaKeyDominance.keyed

        output.withUnsafeMutableBufferPointer { out in
            let source = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let row = source + y * sourceStride
                let outRow = out.baseAddress! + y * outputStride
                for x in 0..<width {
                    let p = row + x * 4
                    let o = outRow + x * 4
                    let key = Double(p[keyOffset])
                    let rival = max(Double(p[redOffset]), Double(p[otherOffset]))
                    let dominance = key - rival
                    if dominance > opaque {
                        if dominance >= keyed {
                            // Cleared, not merely hidden: a transparent pixel that keeps its
                            // colour is still green to anything that ignores alpha.
                            continue
                        }
                        let keyness = (dominance - opaque) / (keyed - opaque)
                        let alpha = (Double(p[3]) * (1 - keyness)).rounded()
                        let factor = alpha / 255
                        var b = Double(p[0])
                        var g = Double(p[1])
                        let r = Double(p[2])
                        if keyColor == .green { g = rival } else { b = rival }
                        // Premultiplied on the way out, which is what `CGImage` expects and what
                        // lets the frame composite without a second pass.
                        o[0] = UInt8((b * factor).rounded())
                        o[1] = UInt8((g * factor).rounded())
                        o[2] = UInt8((r * factor).rounded())
                        o[3] = UInt8(alpha)
                    } else {
                        let factor = Double(p[3]) / 255
                        o[0] = UInt8((Double(p[0]) * factor).rounded())
                        o[1] = UInt8((Double(p[1]) * factor).rounded())
                        o[2] = UInt8((Double(p[2]) * factor).rounded())
                        o[3] = p[3]
                    }
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(output) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: outputStride,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

/// The same key as a Core Image colour kernel, for the GPU.
///
/// `nil` when the kernel does not compile on this system — the string-kernel API is old and Apple
/// has been retiring it — in which case the decoder falls back to `CPUChromaKeyer`. Colour
/// management is switched off on the context so the kernel sees the same bytes the CPU loop does.
public final class CoreImageChromaKeyer: ChromaKeyer, @unchecked Sendable {
    private let kernel: CIColorKernel
    private let context: CIContext

    private static let source = """
    kernel vec4 chromaKey(__sample s, float channel, float opaqueDominance, float keyedDominance) {
        vec3 c = s.rgb * 255.0;
        float key = channel < 1.5 ? c.g : c.b;
        float other = channel < 1.5 ? c.b : c.g;
        float rival = max(c.r, other);
        float dominance = key - rival;
        if (dominance <= opaqueDominance) { return s; }
        if (dominance >= keyedDominance) { return vec4(0.0); }
        float keyness = (dominance - opaqueDominance) / (keyedDominance - opaqueDominance);
        vec3 despilled = c;
        if (channel < 1.5) { despilled.g = rival; } else { despilled.b = rival; }
        float alpha = s.a * (1.0 - keyness);
        return vec4(despilled / 255.0 * (1.0 - keyness), alpha);
    }
    """

    public init?() {
        guard let kernel = CIColorKernel(source: Self.source) else { return nil }
        self.kernel = kernel
        self.context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    }

    public func key(_ pixelBuffer: CVPixelBuffer, keyColor: AnimatedVideoKeyColor) -> CGImage? {
        let input = CIImage(cvPixelBuffer: pixelBuffer)
        guard let keyed = kernel.apply(
            extent: input.extent,
            arguments: [
                input,
                Float(keyColor.channel),
                Float(ChromaKeyDominance.opaque),
                Float(ChromaKeyDominance.keyed)
            ]
        ) else { return nil }
        return context.createCGImage(keyed, from: input.extent)
    }
}
