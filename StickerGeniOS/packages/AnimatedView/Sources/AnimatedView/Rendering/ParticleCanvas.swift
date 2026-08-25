import SwiftUI

/// Deterministic particle field.
///
/// Every particle's position, size, and opacity comes from a splitmix-style hash of the layer seed
/// and the particle index, never from a random number generator. That is a hard requirement rather
/// than a stylistic choice: an exported GIF is rendered frame by frame in a separate pass from the
/// on-screen preview, and the two must agree exactly. The hash below is bit-for-bit the one the v1
/// renderer used, so documents authored before this package still look the same.
struct ParticleCanvas: View {
    let layer: AnimatedParticleLayer
    /// Already mapped into the document's timeline by the caller.
    let time: Double
    let duration: Double

    var body: some View {
        Canvas { context, size in
            for index in 0..<layer.count {
                let seed = UInt64(bitPattern: Int64(layer.seed)) &+ UInt64(bitPattern: Int64(index &* 1_103_515_245))
                let x = unit(seed ^ 0x9E37_79B9_7F4A_7C15)
                let baseY = unit(seed ^ 0xD1B5_4A32_D192_ED03)
                // Snow and bubbles drift; the others hold station and only twinkle.
                let phase = (baseY + time / duration).truncatingRemainder(dividingBy: 1)
                let y = layer.preset == .snow || layer.preset == .bubbles ? phase : baseY
                let radius = size.width * (0.009 + unit(seed ^ 0x94D0_49BB_1331_11EB) * 0.016)
                let rect = CGRect(
                    x: x * size.width - radius,
                    y: y * size.height - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                let alpha = 0.45 + unit(seed ^ 0xBF58_476D_1CE4_E5B9) * 0.55
                context.opacity = alpha
                context.fill(particlePath(in: rect), with: .style(layer.paint.shapeStyle))
            }
        }
    }

    private func particlePath(in rect: CGRect) -> Path {
        switch layer.preset {
        case .sparkles:
            AnimatedShape.radial(in: rect, points: 5, innerRatio: 0.42)
        case .confetti:
            Path(roundedRect: rect, cornerRadius: rect.width * 0.2)
        case .hearts:
            AnimatedShape.heart(in: rect)
        case .bubbles, .snow:
            Path(ellipseIn: rect)
        }
    }

    private func unit(_ value: UInt64) -> Double {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z & 0xFF_FFFF) / Double(0x100_0000)
    }
}
