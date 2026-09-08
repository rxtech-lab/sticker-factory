import SwiftUI

/// Ready-made documents covering every layer kind and animation capability.
///
/// Not wrapped in `#if DEBUG`: the app's own preview fixtures build on these, and the test target
/// asserts every one of them compiles and validates. That test is what makes the `try!` calls below
/// safe — a fixture that cannot compile is a bug that should fail loudly and immediately, not one
/// that quietly renders a motionless sticker.
public enum AnimatedPreviewDocuments {
    public static let imageAssetID = "11111111-1111-4111-8111-111111111111"

    // MARK: - Helpers

    static func base(
        _ id: String,
        _ name: String,
        at position: AnimatedPoint = .center,
        scale: AnimatedPoint = .unit,
        rotation: Double = 0,
        specs: [AnimationSpec] = []
    ) -> AnimatedLayerBase {
        .init(
            id: id,
            name: name,
            anchor: .init(position: position, scale: scale, rotationDegrees: rotation),
            animations: specs
        )
    }

    static func animated(
        durationSeconds: Double = 2,
        fps: Int = 30,
        loop: AnimatedLoop = .loop,
        speed: Double = 1,
        canvas: AnimatedCanvas = .init(),
        background: AnimatedBackground = .none,
        _ layers: [AnimatedLayer]
    ) -> AnimatedDocument {
        let document = AnimatedDocument(
            canvas: canvas,
            kind: .animated,
            durationSeconds: durationSeconds,
            fps: fps,
            loop: loop,
            speed: speed,
            background: background,
            layers: layers
        )
        return (try? document.compiled()) ?? document
    }

    // MARK: - 1. Shapes and colors

    /// Every built-in shape at once, laid out on a grid, each with a solid fill.
    public static let shapes: AnimatedDocument = {
        let palette = ["#FF6B6B", "#FFB86B", "#FFE66B", "#8BE58B", "#6BC5FF", "#8B7BFF", "#D77BFF", "#FF7BC5"]
        let layers = AnimatedShapeKind.presets.enumerated().map { index, kind -> AnimatedLayer in
            let column = index % 4
            let row = index / 4
            return .shape(.init(
                base: base(
                    "shape\(index)",
                    "Shape \(index)",
                    at: .init(x: 0.16 + Double(column) * 0.23, y: 0.32 + Double(row) * 0.34),
                    scale: .init(x: 0.22, y: 0.22),
                    specs: [.popIn(delay: Double(index) * 0.08, duration: 0.5)]
                ),
                shape: kind,
                fill: .solid(palette[index % palette.count]),
                cornerRadius: 0.18
            ))
        }
        return animated(durationSeconds: 2, layers)
    }()

    // MARK: - 2. Gradients

    /// Linear and radial paint on both fills and strokes.
    public static let gradients = animated(durationSeconds: 3, [
        .shape(.init(
            base: base("backdrop", "Backdrop", scale: .init(x: 0.95, y: 0.95)),
            shape: .roundedRectangle,
            fill: .linearGradient("#2B1B4F", "#12263F", angleDegrees: 60),
            cornerRadius: 0.22
        )),
        .shape(.init(
            base: base(
                "orb", "Orb",
                at: .init(x: 0.36, y: 0.42),
                scale: .init(x: 0.4, y: 0.4),
                specs: [.pulse(minScale: 0.9, maxScale: 1.1, cycles: 2, duration: 3)]
            ),
            shape: .circle,
            fill: .radialGradient("#FFF7D6", "#FF8A3D", radius: 0.6)
        )),
        .shape(.init(
            base: base(
                "ring", "Ring",
                at: .init(x: 0.64, y: 0.6),
                scale: .init(x: 0.44, y: 0.44),
                specs: [.spin(turns: 1, duration: 3, easing: .linear)]
            ),
            shape: .fivePointStar,
            stroke: .init(paint: .linearGradient("#6BC5FF", "#D77BFF", angleDegrees: 90), width: 0.035)
        ))
    ])

    // MARK: - 3. SVG draw-on

    /// A four-stroke SVG traced one stroke at a time, then held.
    public static let svgDrawOn = animated(durationSeconds: 3, loop: .loop, [
        .svg(.init(
            base: base(
                "face", "Stroke face",
                scale: .init(x: 0.8, y: 0.8),
                specs: [.drawOn(duration: 2.4, easing: .easeInOut)]
            ),
            source: .inline(markup: AnimatedPreviewSVG.strokeFace),
            renderMode: .vector,
            staggerSeconds: 0.45
        ))
    ])

    /// The simplest possible draw-on: one continuous stroke, no stagger.
    public static let svgDrawOnSimple = animated(durationSeconds: 2, [
        .svg(.init(
            base: base("check", "Check", scale: .init(x: 0.7, y: 0.7), specs: [.drawOn(duration: 1.2, easing: .easeOut)]),
            source: .inline(markup: AnimatedPreviewSVG.strokeCheck),
            renderMode: .vector
        ))
    ])

    // MARK: - 4. SVG native

    /// A full SVG document with `defs` gradients, a group transform, and a `<text>` node, rendered
    /// both ways so the fidelity difference between the modes is visible side by side.
    public static let svgNative = animated(durationSeconds: 2.5, [
        .svg(.init(
            base: base(
                "badge", "Gradient badge",
                scale: .init(x: 0.86, y: 0.86),
                specs: [.float(amplitude: 0.03, cycles: 1, duration: 2.5)]
            ),
            source: .inline(markup: AnimatedPreviewSVG.gradientBadge),
            renderMode: .native
        ))
    ])

    public static let svgVector = animated(durationSeconds: 2.5, [
        .svg(.init(
            base: base(
                "badge", "Gradient badge",
                scale: .init(x: 0.86, y: 0.86),
                specs: [.float(amplitude: 0.03, cycles: 1, duration: 2.5)]
            ),
            source: .inline(markup: AnimatedPreviewSVG.gradientBadge),
            renderMode: .vector
        ))
    ])

    /// Contains a `<text>` node, which the flattener cannot reduce to a path — it is drawn natively
    /// in paint order and does not participate in trim.
    public static let svgWithText = animated(durationSeconds: 2, [
        .svg(.init(
            base: base("badge", "Text badge", scale: .init(x: 0.9, y: 0.9), specs: [.popIn(duration: 0.6)]),
            source: .inline(markup: AnimatedPreviewSVG.textBadge),
            renderMode: .vector
        ))
    ])

    // MARK: - 5. Custom path

    /// `AnimatedShapeKind.path` — a bare `d` string, stroked as it draws and then filled.
    public static let customPath = animated(durationSeconds: 3, [
        .shape(.init(
            base: base("bolt", "Bolt", scale: .init(x: 0.7, y: 0.7), specs: [.drawOn(duration: 1.6, easing: .easeInOut)]),
            shape: .path(d: AnimatedPreviewSVG.boltPathData),
            fill: .linearGradient("#FFD166", "#FF8A3D", angleDegrees: 90),
            stroke: .init(paint: .solid("#1B1B2F"), width: 0.018)
        ))
    ])

    /// A long curve with no fill at all: pure draw-on.
    public static let signature = animated(durationSeconds: 2.5, [
        .shape(.init(
            base: base("sig", "Signature", scale: .init(x: 0.85, y: 0.85), specs: [.drawOn(duration: 2, easing: .easeInOut)]),
            shape: .path(d: AnimatedPreviewSVG.signaturePathData),
            stroke: .init(paint: .solid("#1B1B2F"), width: 0.02, lineCap: .round)
        ))
    ])

    // MARK: - 5b. Wipe, shine and bloom

    /// The three v3 compositing channels, each on its own layer and then all three at once.
    ///
    /// Worth having as a fixture because these are the only effects that cannot be checked by
    /// reading keyframes: they are compositing, so the only way to know a wipe reaches the corners
    /// or a shine stays inside the artwork is to rasterise it.
    public static let lightAndWipe = animated(durationSeconds: 3, [
        .shape(.init(
            base: base(
                "card", "Card",
                at: .init(x: 0.5, y: 0.28),
                scale: .init(x: 0.8, y: 0.34),
                specs: [
                    .wipeIn(.right, softness: 0.08, duration: 1.1),
                    .shine(angleDegrees: -30, width: 0.28, intensity: 0.85, cycles: 2, delay: 1.1, duration: 1.9)
                ]
            ),
            shape: .roundedRectangle,
            fill: .linearGradient("#3D2E6B", "#7A5CC4", angleDegrees: 60),
            cornerRadius: 0.18
        )),
        .shape(.init(
            base: base(
                "orb", "Glowing orb",
                at: .init(x: 0.28, y: 0.72),
                scale: .init(x: 0.3, y: 0.3),
                specs: [.bloomPulse(radius: 0.12, intensity: 0.9, cycles: 3, duration: 3)]
            ),
            shape: .circle,
            fill: .radialGradient("#FFF3C4", "#FF9F45", radius: 0.6)
        )),
        .shape(.init(
            base: base(
                "star", "Wiping star",
                at: .init(x: 0.72, y: 0.72),
                scale: .init(x: 0.34, y: 0.34),
                // A diagonal wipe, which is the case that catches a sweep axis that stops short of
                // the corners: at the end the star has to be whole, not clipped.
                specs: [
                    .init(.wipeTo(start: 0, end: 1, angleDegrees: 45, softness: 0.15), duration: 1.4),
                    .bloomIn(radius: 0.07, intensity: 0.6, delay: 1.4, duration: 0.8)
                ]
            ),
            shape: .star(points: 5, innerRatio: 0.45),
            fill: .solid("#FFD166")
        ))
    ])

    // MARK: - 6. Text

    /// Staggered per-letter entrance, gradient paint, all four font families.
    public static let text: AnimatedDocument = {
        let letters = Array("HELLO")
        let fonts: [AnimatedFontFamily] = [.rounded, .serif, .monospaced, .system, .rounded]
        let layers = letters.enumerated().map { index, letter -> AnimatedLayer in
            .text(.init(
                base: base(
                    "letter\(index)",
                    "Letter \(letter)",
                    at: .init(x: 0.12 + Double(index) * 0.19, y: 0.5),
                    scale: .init(x: 0.2, y: 0.2),
                    specs: [
                        .slideIn(.up, distance: 0.25, delay: Double(index) * 0.12, duration: 0.5, easing: .springBouncy)
                    ]
                ),
                text: String(letter),
                font: fonts[index],
                weight: .bold,
                paint: .linearGradient("#7C5CFF", "#FF6BA9", angleDegrees: 90)
            ))
        }
        return animated(durationSeconds: 2, layers)
    }()

    // MARK: - 7. Image

    /// Two image layers — one plain, one masked by a second asset. Both render the deterministic
    /// placeholder when the provider has nothing, which is what makes this useful in a preview.
    public static let image = animated(durationSeconds: 2, [
        .image(.init(
            base: base("hero", "Hero", specs: [.bounce(height: 0.1, bounces: 2, duration: 2)]),
            assetId: imageAssetID
        ))
    ])

    // MARK: - 8. Particles

    public static let particles: AnimatedDocument = {
        let presets = AnimatedParticlePreset.allCases
        let colors = ["#FFE66B", "#FF6BA9", "#FF4D6D", "#6BC5FF", "#FFFFFF"]
        let layers = presets.enumerated().map { index, preset -> AnimatedLayer in
            .particle(.init(
                base: base("particles\(index)", preset.rawValue.capitalized),
                preset: preset,
                count: 18,
                paint: .solid(colors[index % colors.count]),
                seed: 1_000 + index
            ))
        }
        return animated(durationSeconds: 3, background: .solid("#12263F"), layers)
    }()

    // MARK: - 9. Multi-layer composite

    /// Six layers of four different kinds, staggered — the closest thing here to a real sticker.
    public static let composite = animated(durationSeconds: 3, [
        .shape(.init(
            base: base("burst", "Burst", scale: .init(x: 0.95, y: 0.95), specs: [.spin(turns: 0.5, duration: 3, easing: .linear)]),
            shape: .burst,
            fill: .radialGradient("#FFE7A3", "#FF8FA3", radius: 0.7)
        )),
        .svg(.init(
            base: base("face", "Face", scale: .init(x: 0.52, y: 0.52), specs: [.drawOn(delay: 0.3, duration: 1.6)]),
            source: .inline(markup: AnimatedPreviewSVG.strokeFace),
            renderMode: .vector,
            staggerSeconds: 0.3
        )),
        .text(.init(
            base: base(
                "caption", "Caption",
                at: .init(x: 0.5, y: 0.84),
                scale: .init(x: 0.5, y: 0.13),
                specs: [.slideIn(.up, distance: 0.2, delay: 1.9, duration: 0.5, easing: .springBouncy)]
            ),
            text: "YES!",
            paint: .solid("#1B1B2F")
        )),
        .shape(.init(
            base: base(
                "dotLeft", "Dot left",
                at: .init(x: 0.14, y: 0.2),
                scale: .init(x: 0.1, y: 0.1),
                specs: [.pulse(minScale: 0.7, maxScale: 1.2, cycles: 3, duration: 3)]
            ),
            shape: .circle,
            fill: .solid("#FF6BA9")
        )),
        .shape(.init(
            base: base(
                "dotRight", "Dot right",
                at: .init(x: 0.86, y: 0.24),
                scale: .init(x: 0.08, y: 0.08),
                specs: [.pulse(minScale: 0.7, maxScale: 1.2, cycles: 3, delay: 0.4, duration: 2.6)]
            ),
            shape: .heart,
            fill: .solid("#FF4D6D")
        )),
        .particle(.init(
            base: base("sparkles", "Sparkles"),
            preset: .sparkles,
            count: 22,
            paint: .solid("#FFFFFF"),
            seed: 42
        ))
    ])

    // MARK: - 10. Backgrounds

    /// The same artwork over each background kind, to show that `background` is part of the
    /// artwork while transparency is the default.
    public static func withBackground(_ background: AnimatedBackground) -> AnimatedDocument {
        var document = composite
        document.background = background
        return document
    }

    public static let transparent = withBackground(.none)
    public static let solidBackground = withBackground(.solid("#12263F"))
    public static let gradientBackground = withBackground(.linearGradient("#7C5CFF", "#FF6BA9", angleDegrees: 45))
    public static let radialBackground = withBackground(
        .radialGradient(stops: [.init(color: "#FFF7D6", location: 0), .init(color: "#FF8A3D", location: 1)], center: .center, radius: 0.75)
    )

    // MARK: - 11. Speed

    public static func atSpeed(_ speed: Double) -> AnimatedDocument {
        var document = svgDrawOn
        document.speed = speed
        return document
    }

    // MARK: - 12. Non-square canvas

    /// A wide canvas, which v1 could not express at all — every document was pinned to 1024².
    public static let wideCanvas = animated(
        durationSeconds: 2,
        canvas: .init(width: 1024, height: 384),
        background: .linearGradient("#1B1B2F", "#2B1B4F", angleDegrees: 0),
        [
            .svg(.init(
                base: base("badge", "Badge", at: .init(x: 0.5, y: 0.5), scale: .init(x: 0.7, y: 0.7), specs: [.popIn(duration: 0.6)]),
                source: .inline(markup: AnimatedPreviewSVG.textBadge),
                renderMode: .vector
            ))
        ]
    )

    // MARK: - 13. Static

    public static let staticDocument = AnimatedDocument(
        kind: .static,
        background: .none,
        layers: [
            .shape(.init(
                base: base("bubble", "Bubble", scale: .init(x: 0.9, y: 0.6)),
                shape: .roundedRectangle,
                fill: .linearGradient("#A88BFF", "#7C5CFF", angleDegrees: 90),
                cornerRadius: 0.2
            )),
            .text(.init(
                base: base("caption", "Caption", scale: .init(x: 0.6, y: 0.3)),
                text: "YES!",
                paint: .solid("#FFFFFF")
            ))
        ]
    )

    // MARK: - Catalog

    /// Every fixture, for the gallery preview and for the test that asserts they all validate.
    public static let all: [(title: String, document: AnimatedDocument)] = [
        ("Shapes", shapes),
        ("Gradients", gradients),
        ("SVG draw-on", svgDrawOn),
        ("SVG draw-on (simple)", svgDrawOnSimple),
        ("SVG native", svgNative),
        ("SVG vector", svgVector),
        ("SVG with text", svgWithText),
        ("Custom path", customPath),
        ("Signature", signature),
        ("Wipe, shine and bloom", lightAndWipe),
        ("Text", text),
        ("Image", image),
        ("Particles", particles),
        ("Composite", composite),
        ("Gradient background", gradientBackground),
        ("Wide canvas", wideCanvas),
        ("Static", staticDocument)
    ]
}
