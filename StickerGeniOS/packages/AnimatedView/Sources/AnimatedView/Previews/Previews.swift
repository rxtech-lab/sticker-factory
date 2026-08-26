import SwiftUI

// SwiftUI previews for every capability the package renders.
//
// Deliberately one preview per feature rather than one big grid: an Xcode canvas showing sixteen
// animations at once is unreadable, and the point of these is to be able to look at one behaviour —
// draw-on stagger, gradient orientation, speed — in isolation and see whether it is right.

// MARK: - 1. Shapes and colors

#Preview("1 · Shapes & colors") {
    AnimatedIconGallery("Every built-in shape", document: AnimatedPreviewDocuments.shapes)
}

// MARK: - 2. Gradients

#Preview("2 · Gradients") {
    AnimatedIconGallery("Linear & radial paint, fill and stroke", document: AnimatedPreviewDocuments.gradients)
}

// MARK: - 3. SVG draw-on

#Preview("3 · SVG draw-on") {
    AnimatedIconGallery(
        "Four strokes, staggered 0.45 s apart",
        document: AnimatedPreviewDocuments.svgDrawOn
    )
}

#Preview("3b · Draw-on variants") {
    AnimatedIconStrip("Draw-on", items: [
        ("stagger", AnimatedPreviewDocuments.svgDrawOn),
        ("single stroke", AnimatedPreviewDocuments.svgDrawOnSimple),
        ("path d=", AnimatedPreviewDocuments.signature),
    ])
}

// MARK: - 4. SVG native vs vector

#Preview("4 · SVG native vs vector") {
    AnimatedIconStrip("Same markup, both render modes", items: [
        ("native", AnimatedPreviewDocuments.svgNative),
        ("vector", AnimatedPreviewDocuments.svgVector),
        ("vector + text", AnimatedPreviewDocuments.svgWithText),
    ])
}

// MARK: - 5. Custom path

#Preview("5 · Custom path") {
    AnimatedIconGallery(
        "AnimatedShapeKind.path — a bare d string",
        document: AnimatedPreviewDocuments.customPath
    )
}

// MARK: - 6. Text

#Preview("6 · Text") {
    AnimatedIconGallery(
        "Per-letter stagger, four font families, gradient paint",
        document: AnimatedPreviewDocuments.text
    )
}

// MARK: - 7. Image

#Preview("7 · Image") {
    AnimatedIconGallery(
        "Image layer with no provider — deterministic placeholder",
        document: AnimatedPreviewDocuments.image
    )
}

// MARK: - 8. Particles

#Preview("8 · Particles") {
    AnimatedIconGallery("All five presets, deterministic seeds", document: AnimatedPreviewDocuments.particles)
}

// MARK: - 9. Multi-layer composite

#Preview("9 · Composite") {
    AnimatedIconGallery(
        "Six layers, four kinds, staggered",
        document: AnimatedPreviewDocuments.composite
    )
}

// MARK: - 10. Backgrounds

#Preview("10 · Backgrounds") {
    AnimatedIconStrip("Same artwork, four backgrounds", items: [
        ("none", AnimatedPreviewDocuments.transparent),
        ("solid", AnimatedPreviewDocuments.solidBackground),
        ("linear", AnimatedPreviewDocuments.gradientBackground),
        ("radial", AnimatedPreviewDocuments.radialBackground),
    ], size: 120)
}

// MARK: - 11. Speed

#Preview("11 · Speed") {
    AnimatedIconStrip("Identical keyframes, different speed", items: [
        ("0.5×", AnimatedPreviewDocuments.atSpeed(0.5)),
        ("1×", AnimatedPreviewDocuments.atSpeed(1)),
        ("2×", AnimatedPreviewDocuments.atSpeed(2)),
    ])
}

// MARK: - 12. Size

#Preview("12 · Size") {
    VStack(spacing: 20) {
        Text("One document at four sizes").font(.headline)
        HStack(alignment: .center, spacing: 16) {
            ForEach([48.0, 96.0, 160.0, 260.0], id: \.self) { dimension in
                VStack(spacing: 6) {
                    AnimatedIconView(
                        document: AnimatedPreviewDocuments.composite,
                        repeats: true,
                        size: CGSize(width: dimension, height: dimension)
                    )
                    Text("\(Int(dimension)) pt").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
    .padding(24)
}

// MARK: - 13. Canvas shape and static

#Preview("13 · Canvas & static") {
    AnimatedIconStrip("Non-square canvas, and a static document", items: [
        ("1024×384", AnimatedPreviewDocuments.wideCanvas),
        ("static", AnimatedPreviewDocuments.staticDocument),
    ], size: 200)
}

// MARK: - 14. Gallery

#Preview("14 · Everything") {
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
            ForEach(Array(AnimatedPreviewDocuments.all.enumerated()), id: \.offset) { _, item in
                VStack(spacing: 6) {
                    ZStack {
                        AnimatedCheckerboard(squareSize: 9)
                        AnimatedIconView(document: item.document, repeats: true)
                    }
                    .frame(width: 130, height: 130 / max(item.document.canvas.aspectRatio, 0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Text(item.title).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
    }
    .frame(width: 460, height: 620)
}
