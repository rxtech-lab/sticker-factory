import CoreGraphics
import SwiftUI

/// A paint resolved from SVG markup.
///
/// Richer than `AnimatedPaint` on purpose: SVG gradients carry explicit start and end points, and
/// collapsing those to a single angle the way `AnimatedPaint` does would visibly move a gradient
/// whose axis is not centered. `AnimatedPaint` converts *into* this, never the other way.
public enum SVGPaintValue: Sendable, Equatable {
    case color(String)
    case linearGradient(stops: [AnimatedGradientStop], start: UnitPoint, end: UnitPoint)
    case radialGradient(stops: [AnimatedGradientStop], center: UnitPoint, radius: Double)

    public static let black = SVGPaintValue.color("#000000FF")
}

public enum SVGFillRule: String, Sendable, Equatable {
    case nonZero, evenOdd
}

public struct SVGStrokeStyle: Sendable, Equatable {
    public var paint: SVGPaintValue
    /// In viewBox units. Scaling the whole drawing to fit a layer scales this with it, which is what
    /// SVG itself does.
    public var width: Double
    public var cap: AnimatedLineCap
    public var join: AnimatedLineJoin
    public var dash: [Double]
    public var dashPhase: Double

    public init(
        paint: SVGPaintValue,
        width: Double = 1,
        cap: AnimatedLineCap = .butt,
        join: AnimatedLineJoin = .miter,
        dash: [Double] = [],
        dashPhase: Double = 0
    ) {
        self.paint = paint
        self.width = width
        self.cap = cap
        self.join = join
        self.dash = dash
        self.dashPhase = dashPhase
    }
}

/// One flattened vector element, in viewBox coordinates with every ancestor transform baked in.
public struct SVGSubpath: Sendable, Equatable, Identifiable {
    /// Draw order. Also the index the layer's `staggerSeconds` offsets by, so subpath 0 draws first.
    public var id: Int
    public var path: Path
    public var fill: SVGPaintValue?
    public var stroke: SVGStrokeStyle?
    public var fillRule: SVGFillRule
    public var opacity: Double

    public init(
        id: Int,
        path: Path,
        fill: SVGPaintValue? = nil,
        stroke: SVGStrokeStyle? = nil,
        fillRule: SVGFillRule = .nonZero,
        opacity: Double = 1
    ) {
        self.id = id
        self.path = path
        self.fill = fill
        self.stroke = stroke
        self.fillRule = fillRule
        self.opacity = opacity
    }
}

/// One item in a drawing's paint order.
public enum SVGElement: Sendable, Equatable {
    case subpath(SVGSubpath)
    /// A node the flattener could not reduce to a path — SVG `<text>` or an embedded raster.
    ///
    /// It is drawn natively at this position in the paint order so the artwork stays complete, but
    /// it has no path length, so trim and draw-on animation do not apply to it. `index` addresses
    /// the node in the parsed document's `passthroughNodes`, which is main-actor-only because
    /// SVGView's node classes are not `Sendable`.
    case passthrough(index: Int, transform: CGAffineTransform, opacity: Double)
}

/// A whole SVG document reduced to values.
///
/// This is the boundary that keeps SVGView's non-`Sendable` `ObservableObject` node tree from
/// leaking into the rest of the package: everything past the flattener is a plain value, which is
/// also what makes deterministic `ImageRenderer` export possible.
public struct SVGDrawing: Sendable, Equatable {
    public var viewBox: CGRect
    public var elements: [SVGElement]

    public init(viewBox: CGRect, elements: [SVGElement]) {
        self.viewBox = viewBox
        self.elements = elements
    }

    public static let empty = SVGDrawing(viewBox: CGRect(x: 0, y: 0, width: 1, height: 1), elements: [])

    public var subpaths: [SVGSubpath] {
        elements.compactMap { if case .subpath(let value) = $0 { value } else { nil } }
    }

    public var subpathCount: Int { subpaths.count }

    public var passthroughCount: Int {
        elements.count { if case .passthrough = $0 { true } else { false } }
    }

    public var isEmpty: Bool { elements.isEmpty }
}

/// A parsed SVG document: the value model plus the main-actor-only pieces it could not absorb.
@MainActor
public struct SVGParsedDocument {
    public var drawing: SVGDrawing
    /// The original tree, kept for `AnimatedSVGRenderMode.native`.
    public var root: SVGNodeBox
    /// Nodes referenced by `SVGElement.passthrough`, in the order they were encountered.
    public var passthroughNodes: [SVGNodeBox]
}
