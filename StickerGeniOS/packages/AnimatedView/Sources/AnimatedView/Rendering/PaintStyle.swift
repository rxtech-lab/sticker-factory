import SwiftUI

extension Color {
    /// `#RRGGBB` or `#RRGGBBAA`. Unparseable input yields opaque black rather than throwing, because
    /// a malformed color must never take a whole sticker down mid-render.
    public init(animatedHex: String) {
        let clean = animatedHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&value)
        let hasAlpha = clean.count == 8
        let red = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let green = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlpha ? Double(value & 0xFF) / 255 : 1
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

extension AnimatedGradientStop {
    var swiftUI: Gradient.Stop {
        .init(color: Color(animatedHex: color), location: location)
    }
}

extension AnimatedPaint {
    /// The `ShapeStyle` this paint fills with.
    ///
    /// Type-erased because a fill can be any of three concrete styles and the call sites are inside
    /// `@ViewBuilder` bodies where a generic return would fight `some View`.
    public var shapeStyle: AnyShapeStyle {
        switch self {
        case .solid(let hex):
            AnyShapeStyle(Color(animatedHex: hex))
        case .linearGradient(let stops, let angleDegrees):
            AnyShapeStyle(LinearGradient(
                gradient: Gradient(stops: stops.map(\.swiftUI)),
                startPoint: Self.unitPoint(forAngle: angleDegrees, start: true),
                endPoint: Self.unitPoint(forAngle: angleDegrees, start: false)
            ))
        case .radialGradient(let stops, let center, let radius):
            AnyShapeStyle(RadialGradient(
                gradient: Gradient(stops: stops.map(\.swiftUI)),
                center: UnitPoint(x: center.x, y: center.y),
                startRadius: 0,
                endRadius: radius
            ))
        }
    }

    /// Maps a gradient angle onto the unit square.
    ///
    /// 0° runs left-to-right and angles increase clockwise, matching how the same `angleDegrees`
    /// value is interpreted by the exporter's `CGGradient` and by the web preview's CSS. All three
    /// have to agree or a gradient rotates depending on where it is rendered.
    static func unitPoint(forAngle degrees: Double, start: Bool) -> UnitPoint {
        let radians = degrees * .pi / 180
        let dx = cos(radians) / 2
        let dy = sin(radians) / 2
        return start ? UnitPoint(x: 0.5 - dx, y: 0.5 - dy) : UnitPoint(x: 0.5 + dx, y: 0.5 + dy)
    }
}

extension SVGPaintValue {
    public var shapeStyle: AnyShapeStyle {
        switch self {
        case .color(let hex):
            AnyShapeStyle(Color(animatedHex: hex))
        case .linearGradient(let stops, let start, let end):
            AnyShapeStyle(LinearGradient(
                gradient: Gradient(stops: stops.map(\.swiftUI)),
                startPoint: start,
                endPoint: end
            ))
        case .radialGradient(let stops, let center, let radius):
            AnyShapeStyle(RadialGradient(
                gradient: Gradient(stops: stops.map(\.swiftUI)),
                center: center,
                startRadius: 0,
                endRadius: radius
            ))
        }
    }

    /// The value an `AnimatedPaint` override becomes, so a tint can replace SVG artwork's own paint.
    init(_ paint: AnimatedPaint) {
        switch paint {
        case .solid(let hex):
            self = .color(hex)
        case .linearGradient(let stops, let angleDegrees):
            self = .linearGradient(
                stops: stops,
                start: AnimatedPaint.unitPoint(forAngle: angleDegrees, start: true),
                end: AnimatedPaint.unitPoint(forAngle: angleDegrees, start: false)
            )
        case .radialGradient(let stops, let center, let radius):
            self = .radialGradient(stops: stops, center: UnitPoint(x: center.x, y: center.y), radius: radius)
        }
    }
}

extension AnimatedLineCap {
    var cgLineCap: CGLineCap {
        switch self {
        case .butt: .butt
        case .round: .round
        case .square: .square
        }
    }
}

extension AnimatedLineJoin {
    var cgLineJoin: CGLineJoin {
        switch self {
        case .miter: .miter
        case .round: .round
        case .bevel: .bevel
        }
    }
}

extension AnimatedBlendMode {
    var swiftUI: BlendMode {
        switch self {
        case .normal: .normal
        case .multiply: .multiply
        case .screen: .screen
        case .overlay: .overlay
        case .softLight: .softLight
        case .hardLight: .hardLight
        case .difference: .difference
        case .plusLighter: .plusLighter
        }
    }
}
