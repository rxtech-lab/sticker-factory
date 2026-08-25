import SwiftUI

/// The built-in vector primitives.
///
/// `path(in:)` is `nonisolated`, so it cannot reach `SVGCache` to resolve an `AnimatedShapeKind.path`
/// itself. The caller resolves that once and hands the geometry in through `customPath`, which also
/// keeps a `d` string from being re-parsed on every frame.
public struct AnimatedShape: Shape {
    public var kind: AnimatedShapeKind
    public var cornerRadius: Double
    public var customPath: Path?

    public init(kind: AnimatedShapeKind, cornerRadius: Double = 0.12, customPath: Path? = nil) {
        self.kind = kind
        self.cornerRadius = cornerRadius
        self.customPath = customPath
    }

    public func path(in rect: CGRect) -> Path {
        switch kind {
        case .circle:
            return Path(ellipseIn: rect)
        case .roundedRectangle:
            return Path(roundedRect: rect, cornerRadius: rect.width * cornerRadius, style: .continuous)
        case .capsule:
            return Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) / 2, style: .continuous)
        case .triangle:
            return Self.regularPolygon(in: rect, sides: 3)
        case .star(let points, let innerRatio):
            return Self.radial(in: rect, points: points, innerRatio: innerRatio)
        case .heart:
            return Self.heart(in: rect)
        case .burst:
            return Self.radial(in: rect, points: 12, innerRatio: 0.7)
        case .polygon(let sides):
            return Self.regularPolygon(in: rect, sides: sides)
        case .path:
            return Self.fitted(customPath ?? Path(), in: rect)
        }
    }

    /// Scales an arbitrary path into `rect`, preserving aspect ratio and centering it.
    ///
    /// This is what makes "here is a path, draw it" behave like every other layer kind: whatever
    /// coordinate space the author wrote the path in, it lands in the same fit box a shape or an
    /// image would.
    static func fitted(_ path: Path, in rect: CGRect) -> Path {
        let bounds = path.boundingRect
        guard !bounds.isNull, !bounds.isEmpty, bounds.width > 0, bounds.height > 0 else { return path }
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        let width = bounds.width * scale
        let height = bounds.height * scale
        let transform = CGAffineTransform.identity
            .translatedBy(x: rect.midX - width / 2, y: rect.midY - height / 2)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -bounds.minX, y: -bounds.minY)
        return path.applying(transform)
    }

    /// A star or a burst: alternating outer and inner vertices around a circle.
    static func radial(in rect: CGRect, points: Int, innerRatio: Double) -> Path {
        guard points >= 2 else { return Path(ellipseIn: rect) }
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        for index in 0..<(points * 2) {
            let radius = index.isMultiple(of: 2) ? outer : outer * innerRatio
            let angle = -CGFloat.pi / 2 + CGFloat(index) * .pi / CGFloat(points)
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    static func regularPolygon(in rect: CGRect, sides: Int) -> Path {
        guard sides >= 3 else { return Path(ellipseIn: rect) }
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        for index in 0..<sides {
            let angle = -CGFloat.pi / 2 + CGFloat(index) * 2 * .pi / CGFloat(sides)
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    static func heart(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.32),
            control1: CGPoint(x: rect.minX + rect.width * 0.16, y: rect.minY + rect.height * 0.78),
            control2: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.55)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.22),
            control1: CGPoint(x: rect.minX, y: rect.minY),
            control2: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.minY)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.32),
            control1: CGPoint(x: rect.minX + rect.width * 0.64, y: rect.minY),
            control2: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.55),
            control2: CGPoint(x: rect.minX + rect.width * 0.84, y: rect.minY + rect.height * 0.78)
        )
        return path
    }
}
