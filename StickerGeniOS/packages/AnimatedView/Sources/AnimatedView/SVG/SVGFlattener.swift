import CoreGraphics
import SVGView
import SwiftUI

/// A main-actor handle on an SVGView node.
///
/// SVGView's model is a tree of `ObservableObject` classes, which are not `Sendable`. Wrapping them
/// keeps that fact explicit and localized instead of forcing `@unchecked Sendable` onto anything
/// that wants to hold one.
@MainActor
public struct SVGNodeBox {
    public let node: SVGNode
    public init(_ node: SVGNode) { self.node = node }
}

/// Turns an SVGView node tree into `SVGDrawing` values.
///
/// Runs on the main actor because every node it touches is a non-`Sendable` `ObservableObject`.
/// Everything it returns is a value, so the result can cross actors freely — that separation is
/// what lets the renderer stay deterministic and lets `ImageRenderer` produce export frames that
/// match the screen exactly.
///
/// Two nodes cannot be reduced to a path: `<text>`, whose glyphs would need font outlines, and
/// embedded rasters. Those are recorded as `SVGElement.passthrough` and drawn natively in place, so
/// the artwork stays complete; they simply have no length for trim to act on.
@MainActor
public enum SVGFlattener {
    public static func parse(markup: String) -> SVGParsedDocument? {
        guard let root = SVGParser.parse(string: markup) else { return nil }
        return flatten(root: root)
    }

    public static func parse(data: Data) -> SVGParsedDocument? {
        guard let root = SVGParser.parse(data: data) else { return nil }
        return flatten(root: root)
    }

    public static func parse(contentsOf url: URL) -> SVGParsedDocument? {
        guard let root = SVGParser.parse(contentsOf: url) else { return nil }
        return flatten(root: root)
    }

    /// Parses a bare SVG `d` attribute into a single path.
    ///
    /// Routed through the full parser rather than a private path tokenizer so that
    /// `AnimatedShapeKind.path` and an SVG layer's `<path>` are guaranteed to interpret the same
    /// `d` string identically — SVGView's `PathReader` is not public, and a second implementation
    /// would be a second set of arc-flag and implicit-lineto bugs.
    public static func path(fromPathData data: String) -> Path? {
        let escaped = data
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let markup = "<svg xmlns=\"http://www.w3.org/2000/svg\"><path d=\"\(escaped)\"/></svg>"
        guard let root = SVGParser.parse(string: markup) else { return nil }
        let subpaths = flatten(root: root).drawing.subpaths
        guard !subpaths.isEmpty else { return nil }
        var combined = Path()
        for subpath in subpaths { combined.addPath(subpath.path) }
        return combined.isEmpty ? nil : combined
    }

    public static func flatten(root: SVGNode) -> SVGParsedDocument {
        var context = FlattenContext()
        context.walk(root, transform: .identity, opacity: 1)
        let viewBox = context.viewBox ?? fallbackViewBox(for: context.elements)
        return SVGParsedDocument(
            drawing: SVGDrawing(viewBox: viewBox, elements: context.elements),
            root: SVGNodeBox(root),
            passthroughNodes: context.passthrough.map(SVGNodeBox.init)
        )
    }

    /// A viewBox derived from the artwork when the document declares none.
    ///
    /// Falls back to a unit square rather than `.zero` so the renderer never divides by zero on a
    /// document that parsed to nothing.
    private static func fallbackViewBox(for elements: [SVGElement]) -> CGRect {
        var union: CGRect?
        for case .subpath(let subpath) in elements {
            let bounds = subpath.path.boundingRect
            guard !bounds.isNull, !bounds.isInfinite else { continue }
            union = union.map { $0.union(bounds) } ?? bounds
        }
        guard let union, union.width > 0, union.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        return union
    }
}

@MainActor
private struct FlattenContext {
    var elements: [SVGElement] = []
    var passthrough: [SVGNode] = []
    var viewBox: CGRect?
    private var nextSubpathID = 0

    mutating func walk(_ node: SVGNode, transform inherited: CGAffineTransform, opacity inheritedOpacity: Double) {
        // A node's own transform applies before its ancestors', which is what `concatenating`
        // expresses: `a.concatenating(b)` is "a, then b".
        let transform = node.transform.concatenating(inherited)
        let opacity = inheritedOpacity * node.opacity

        switch node {
        case let viewport as SVGViewport:
            if viewBox == nil { viewBox = resolvedViewBox(of: viewport) }
            for child in viewport.contents { walk(child, transform: transform, opacity: opacity) }
        case let group as SVGGroup:
            for child in group.contents { walk(child, transform: transform, opacity: opacity) }
        case let userSpace as SVGUserSpaceNode:
            walk(userSpace.node, transform: transform, opacity: opacity)
        case let shape as SVGShape:
            appendShape(shape, transform: transform, opacity: opacity)
        default:
            appendPassthrough(node, transform: transform, opacity: opacity)
        }
    }

    private mutating func appendShape(_ shape: SVGShape, transform: CGAffineTransform, opacity: Double) {
        guard var path = SVGGeometry.path(for: shape) else {
            appendPassthrough(shape, transform: transform, opacity: opacity)
            return
        }
        path = path.applying(transform)

        // Stroke width lives in the pre-transform coordinate system, so a scaled group scales its
        // strokes. Using the transform's average scale keeps a non-uniformly scaled group's stroke
        // from having two different widths, which a single `lineWidth` cannot express anyway.
        let scale = ((transform.a * transform.a + transform.b * transform.b).squareRoot()
            + (transform.c * transform.c + transform.d * transform.d).squareRoot()) / 2

        elements.append(.subpath(SVGSubpath(
            id: nextSubpathID,
            path: path,
            fill: SVGGeometry.paint(shape.fill),
            stroke: SVGGeometry.stroke(shape.stroke, scale: scale),
            fillRule: (shape as? SVGPath)?.fillRule == .evenOdd ? .evenOdd : .nonZero,
            opacity: opacity
        )))
        nextSubpathID += 1
    }

    private mutating func appendPassthrough(_ node: SVGNode, transform: CGAffineTransform, opacity: Double) {
        elements.append(.passthrough(index: passthrough.count, transform: transform, opacity: opacity))
        passthrough.append(node)
    }

    /// `viewBox` when the document declares one, otherwise its pixel width/height.
    ///
    /// A percentage width resolves to zero here because there is no parent to be a percentage of;
    /// that case falls through to bounds-derived sizing.
    private func resolvedViewBox(of viewport: SVGViewport) -> CGRect? {
        if let declared = viewport.viewBox, declared.width > 0, declared.height > 0 { return declared }
        let width = viewport.width.toPixels(total: 0)
        let height = viewport.height.toPixels(total: 0)
        guard width > 0, height > 0 else { return nil }
        return CGRect(x: 0, y: 0, width: width, height: height)
    }
}

/// Geometry and paint conversion for the SVGView node types.
///
/// SVGView only exposes `toBezierPath()` on `SVGPath`; every other shape has to be rebuilt from its
/// published geometry, which is what the bulk of this does.
@MainActor
enum SVGGeometry {
    static func path(for shape: SVGShape) -> Path? {
        switch shape {
        case let value as SVGPath:
            return Path(cgPath(from: value.toBezierPath()))
        case let value as SVGRect:
            let rect = CGRect(x: value.x, y: value.y, width: value.width, height: value.height)
            // SVG allows independent rx/ry; SwiftUI's rounded rect takes a CGSize, so both survive.
            if value.rx > 0 || value.ry > 0 {
                let rx = value.rx > 0 ? value.rx : value.ry
                let ry = value.ry > 0 ? value.ry : value.rx
                return Path(roundedRect: rect, cornerSize: CGSize(width: rx, height: ry), style: .continuous)
            }
            return Path(rect)
        case let value as SVGCircle:
            return Path(ellipseIn: CGRect(x: value.cx - value.r, y: value.cy - value.r, width: value.r * 2, height: value.r * 2))
        case let value as SVGEllipse:
            return Path(ellipseIn: CGRect(x: value.cx - value.rx, y: value.cy - value.ry, width: value.rx * 2, height: value.ry * 2))
        case let value as SVGLine:
            var path = Path()
            path.move(to: CGPoint(x: value.x1, y: value.y1))
            path.addLine(to: CGPoint(x: value.x2, y: value.y2))
            return path
        case let value as SVGPolyline:
            return polyline(value.points, closed: false)
        case let value as SVGPolygon:
            return polyline(value.points, closed: true)
        default:
            return nil
        }
    }

    /// `NSBezierPath.cgPath` is ambiguous on macOS — AppKit gained it in macOS 14 and SVGView
    /// still ships its own extension of the same name — so the macOS path is rebuilt by hand.
    private static func cgPath(from bezier: MBezierPath) -> CGPath {
        #if canImport(UIKit)
        return bezier.cgPath
        #else
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for index in 0..<bezier.elementCount {
            switch bezier.element(at: index, associatedPoints: &points) {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo, .cubicCurveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo:
                path.addQuadCurve(to: points[1], control: points[0])
            case .closePath:
                path.closeSubpath()
            @unknown default:
                continue
            }
        }
        return path
        #endif
    }

    private static func polyline(_ points: [CGPoint], closed: Bool) -> Path? {
        guard let first = points.first else { return nil }
        var path = Path()
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        if closed { path.closeSubpath() }
        return path
    }

    static func paint(_ paint: SVGPaint?) -> SVGPaintValue? {
        switch paint {
        case let color as SVGColor:
            return .color(hex(color))
        case let gradient as SVGLinearGradient:
            return .linearGradient(
                stops: stops(gradient.stops),
                start: UnitPoint(x: gradient.x1, y: gradient.y1),
                end: UnitPoint(x: gradient.x2, y: gradient.y2)
            )
        case let gradient as SVGRadialGradient:
            return .radialGradient(
                stops: stops(gradient.stops),
                center: UnitPoint(x: gradient.cx, y: gradient.cy),
                radius: gradient.r
            )
        default:
            return nil
        }
    }

    static func stroke(_ stroke: SVGStroke?, scale: Double) -> SVGStrokeStyle? {
        guard let stroke, stroke.width > 0, let paint = paint(stroke.fill) else { return nil }
        let cap: AnimatedLineCap = switch stroke.cap {
        case .round: .round
        case .square: .square
        default: .butt
        }
        let join: AnimatedLineJoin = switch stroke.join {
        case .round: .round
        case .bevel: .bevel
        default: .miter
        }
        return SVGStrokeStyle(
            paint: paint,
            width: stroke.width * scale,
            cap: cap,
            join: join,
            dash: stroke.dashes.map { $0 * scale },
            dashPhase: stroke.offset * scale
        )
    }

    private static func stops(_ stops: [SVGStop]) -> [AnimatedGradientStop] {
        // A gradient with fewer than two stops renders as nothing in SwiftUI, so a single-stop
        // gradient — legal SVG — is widened into a flat one rather than dropped.
        let converted = stops.map { AnimatedGradientStop(color: hex($0.color), location: $0.offset) }
        guard converted.count == 1, let only = converted.first else { return converted }
        return [AnimatedGradientStop(color: only.color, location: 0), AnimatedGradientStop(color: only.color, location: 1)]
    }

    private static func hex(_ color: SVGColor) -> String {
        let alpha = Int((min(max(color.opacity, 0), 1) * 255).rounded())
        return String(format: "#%02X%02X%02X%02X", color.r & 0xFF, color.g & 0xFF, color.b & 0xFF, alpha)
    }
}
