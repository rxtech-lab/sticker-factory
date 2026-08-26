import SVGView
import SwiftUI

/// A `Shape` that returns an already-positioned path.
///
/// The flattener bakes every ancestor transform into absolute viewBox coordinates, so the path does
/// not depend on the rect it is asked to draw into. Wrapping it as a `Shape` rather than drawing it
/// in a `Canvas` is what makes `.trim(from:to:)` available, and trim is the whole draw-on feature.
struct AbsolutePathShape: Shape {
    let stored: Path
    func path(in rect: CGRect) -> Path { stored }
}

/// Draws a flattened SVG document with a layer's trim, tint, and stroke overrides applied.
struct SVGVectorView: View {
    let drawing: SVGDrawing
    let passthroughNodes: [SVGNodeBox]
    let trim: AnimatedTrim
    let tint: AnimatedPaint?
    let strokeOverride: AnimatedStroke?
    /// Fraction of the total draw window each successive subpath is delayed by.
    let staggerFraction: Double
    /// The scale from viewBox units to the rendered box, used to size an overridden stroke, whose
    /// width is authored in normalized canvas units rather than viewBox units.
    let strokeScale: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(drawing.elements.enumerated()), id: \.offset) { _, element in
                switch element {
                case .subpath(let subpath):
                    subpathView(subpath)
                case .passthrough(let index, let transform, let opacity):
                    passthroughView(index: index, transform: transform, opacity: opacity)
                }
            }
        }
        .frame(width: drawing.viewBox.width, height: drawing.viewBox.height, alignment: .topLeading)
        // The flattener works in viewBox coordinates including a non-zero origin, so shift the
        // origin to (0, 0) before the frame clips it away.
        .offset(x: -drawing.viewBox.minX, y: -drawing.viewBox.minY)
    }

    @ViewBuilder
    private func subpathView(_ subpath: SVGSubpath) -> some View {
        let window = trimWindow(for: subpath.id)
        let coverage = max(0, window.end - window.start)
        let shape = AbsolutePathShape(stored: subpath.path)
        let stroke = resolvedStroke(subpath.stroke)

        ZStack(alignment: .topLeading) {
            if let fill = resolvedFill(subpath.fill) {
                // Trimming a *fill* produces a partially-closed blob rather than a partial drawing,
                // so the fill fades with coverage instead. That is what makes the common draw-on
                // shape read correctly: the outline traces itself, and the color arrives with it.
                shape
                    .fill(fill.shapeStyle, style: FillStyle(eoFill: subpath.fillRule == .evenOdd))
                    .opacity(coverage)
            }
            if let stroke {
                shape
                    .trim(from: window.start, to: window.end)
                    .stroke(stroke.paint.shapeStyle, style: strokeStyle(stroke))
            }
        }
        .opacity(subpath.opacity)
    }

    @ViewBuilder
    private func passthroughView(index: Int, transform: CGAffineTransform, opacity: Double) -> some View {
        if index < passthroughNodes.count {
            // Text and embedded rasters have no path length, so trim cannot apply to them; they are
            // drawn natively so the artwork stays complete rather than losing elements.
            passthroughNodes[index].node.toSwiftUI()
                .transformEffect(transform)
                .opacity(opacity)
        }
    }

    private func strokeStyle(_ stroke: SVGStrokeStyle) -> StrokeStyle {
        StrokeStyle(
            lineWidth: stroke.width,
            lineCap: stroke.cap.cgLineCap,
            lineJoin: stroke.join.cgLineJoin,
            dash: stroke.dash.map { CGFloat($0) },
            dashPhase: stroke.dashPhase
        )
    }

    private func resolvedFill(_ fill: SVGPaintValue?) -> SVGPaintValue? {
        // A tint replaces the artwork's own colors wherever there is one to replace; it never
        // *adds* a fill to a stroke-only path, which would fill open letterforms solid.
        guard let fill else { return nil }
        return tint.map(SVGPaintValue.init) ?? fill
    }

    private func resolvedStroke(_ stroke: SVGStrokeStyle?) -> SVGStrokeStyle? {
        guard let strokeOverride else { return stroke }
        return SVGStrokeStyle(
            paint: SVGPaintValue(strokeOverride.paint),
            width: strokeOverride.width * strokeScale,
            cap: strokeOverride.lineCap,
            join: strokeOverride.lineJoin,
            dash: strokeOverride.dash.map { $0 * strokeScale },
            dashPhase: 0
        )
    }

    /// The trim window for one subpath, shifted by the layer's stagger.
    ///
    /// With no stagger every subpath shares the layer's window. With stagger, subpath *i* is given
    /// the slice of the window that starts `i` steps in, so an icon made of several strokes draws
    /// them in order instead of growing all of them at once.
    private func trimWindow(for index: Int) -> (start: Double, end: Double) {
        guard staggerFraction > 0, drawing.subpathCount > 1 else { return (trim.start, trim.end) }
        let offset = staggerFraction * Double(index)
        let span = max(0.0001, 1 - staggerFraction * Double(drawing.subpathCount - 1))
        let localStart = (trim.start - offset) / span
        let localEnd = (trim.end - offset) / span
        return (min(max(localStart, 0), 1), min(max(localEnd, 0), 1))
    }
}
