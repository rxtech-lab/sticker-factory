import SwiftUI
import UIKit

/// The outside, as seen through the windows of the pet's room. The server cuts each room's window
/// glass out of its drawing, so this fills the whole tab behind the room and shows only where the
/// glass was: the owner's real weather, day or night, moving the way that weather does. With no
/// weather read yet it shows a clear sky for the time of day. Holds still under reduced motion.
///
/// Once the server has drawn this weather in the pet's own style, its pieces — the sun or moon, two
/// clouds and a particle — take the place of the painted ones and move the same way; the colours of the
/// sky and the hills stay painted, so the window is never empty while a new weather is drawn.
struct PetWindowSky: View {
    let weather: PetWeather?
    var sprites: PetWindowSprites?
    var openings: PetWindowOpeningLayout?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var kind: PetWeatherKind { weather?.kind ?? .sunny }

    /// The drawn pieces, only while they are of the weather shown: a turn of the weather paints the
    /// sky until the new look is drawn, rather than raining sunshine.
    private func drawn(isDay: Bool) -> PetWindowSprites? {
        guard let sprites, sprites.kind == kind, sprites.isDay == isDay else { return nil }
        return sprites
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            sky(date: context.date)
        }
    }

    private func sky(date: Date) -> some View {
        let isDay = weather?.isDay ?? PetSkyOrbit.isDay(at: date)
        let palette = SkyPalette(kind: kind, isDay: isDay)
        let drawn = drawn(isDay: isDay)
        return GeometryReader { proxy in
            let preferredSide = isDay ? (drawn == nil ? 84.0 : (kind == .sunny || kind == .windy ? 150.0 : 120.0))
                : (drawn == nil ? 72.0 : 144.0)
            let skyBounds = openings?.bounds ?? CGRect(origin: .zero, size: proxy.size)
            let target = PetSkyOrbit.position(at: date, isDay: isDay, in: skyBounds)
            let celestial: PetSkyPlacement? = if let openings {
                if isDay {
                    openings.placement(near: target, preferredSide: preferredSide)
                } else {
                    openings.fixedPlacement(near: target, side: preferredSide,
                                            footprint: drawn?.bodyFootprint ?? PetSkyFootprint.moon)
                }
            } else {
                PetSkyPlacement(center: target, side: preferredSide)
            }
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                Canvas { canvas, size in
                    let pieces = drawn.map { sprites in
                        SkyPieces(body: canvas.resolve(Image(uiImage: sprites.body)),
                                  wideCloud: canvas.resolve(Image(uiImage: sprites.wideCloud)),
                                  smallCloud: canvas.resolve(Image(uiImage: sprites.smallCloud)),
                                  particle: canvas.resolve(Image(uiImage: sprites.particle)))
                    }
                    SkyPainter(kind: kind, isDay: isDay, palette: palette, time: time, size: size,
                               celestialPlacement: celestial, pieces: pieces).paint(&canvas)
                }
            }
            // The drawn sky fades in over the painted one when it lands.
            .id(drawn?.sheet)
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.8), value: drawn?.sheet)
        .accessibilityIdentifier(drawn == nil ? "pet-window-sky-painted" : "pet-window-sky-drawn")
        .background(LinearGradient(colors: [palette.top, palette.bottom], startPoint: .top, endPoint: .bottom))
        // The glass: a faint sheen so the view reads as through a window, not a hole in the wall.
        .overlay(Color.white.opacity(0.08))
        .animation(.easeInOut(duration: 1.2), value: weather)
        .accessibilityHidden(true)
    }
}

/// The sky outside a room's window drawn in the pet's style: the server's 2×2 sheet cut into its pieces,
/// each fitted to its own square cell.
struct PetWindowSprites: Equatable {
    let sheet: UIImage
    let kind: PetWeatherKind
    let isDay: Bool
    /// The sun or moon; a wide rain or snow cloud for wet weather; a lightning bolt in a storm.
    let body: UIImage
    let bodyFootprint: [CGPoint]
    let wideCloud: UIImage
    let smallCloud: UIImage
    /// Repeated many times: a raindrop, a snowflake, a leaf, a bird, a star or a curl of mist.
    let particle: UIImage

    /// Nil for a sheet with no pixels to cut, which no sky can be made of.
    init?(sheet: UIImage, kind: PetWeatherKind, isDay: Bool) {
        guard let image = sheet.cgImage else { return nil }
        let cellWidth = image.width / 2
        let cellHeight = image.height / 2
        let cells = (0..<4).compactMap { index in
            image.cropping(to: CGRect(x: (index % 2) * cellWidth, y: (index / 2) * cellHeight, width: cellWidth, height: cellHeight))
                .map { UIImage(cgImage: $0, scale: sheet.scale, orientation: .up) }
        }
        guard cells.count == 4 else { return nil }
        self.sheet = sheet
        self.kind = kind
        self.isDay = isDay
        (body, wideCloud, smallCloud, particle) = (cells[0], cells[1], cells[2], cells[3])
        bodyFootprint = PetSkyFootprint.points(in: cells[0])
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sheet === rhs.sheet && lhs.kind == rhs.kind && lhs.isDay == rhs.isDay
    }
}

/// The drawn pieces, resolved once per frame for the canvas.
private struct SkyPieces {
    let body: GraphicsContext.ResolvedImage
    let wideCloud: GraphicsContext.ResolvedImage
    let smallCloud: GraphicsContext.ResolvedImage
    let particle: GraphicsContext.ResolvedImage
}

/// The sky's colours for one weather at one time of day.
private struct SkyPalette {
    var top: Color
    var bottom: Color
    var hills: Color
    var cloud: Color

    init(kind: PetWeatherKind, isDay: Bool) {
        func rgb(_ hex: UInt32) -> Color {
            Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
        }
        switch (kind, isDay) {
        case (.sunny, true): (top, bottom, hills, cloud) = (rgb(0x5BA8F0), rgb(0xCDEBFF), rgb(0x86B98A), rgb(0xFFFFFF))
        case (.windy, true): (top, bottom, hills, cloud) = (rgb(0x79B8E6), rgb(0xD9EEF9), rgb(0x8DB894), rgb(0xFFFFFF))
        case (.cloudy, true): (top, bottom, hills, cloud) = (rgb(0x9DB2C7), rgb(0xDCE4EC), rgb(0x8FA59A), rgb(0xF4F6F8))
        case (.rainy, true): (top, bottom, hills, cloud) = (rgb(0x7A8C9F), rgb(0xB9C5D1), rgb(0x6F8A80), rgb(0xA9B5C2))
        case (.stormy, true): (top, bottom, hills, cloud) = (rgb(0x4A5163), rgb(0x838C9C), rgb(0x4F6158), rgb(0x6C7486))
        case (.snowy, true): (top, bottom, hills, cloud) = (rgb(0xC5D3E1), rgb(0xF1F5F9), rgb(0xE6EDF3), rgb(0xFFFFFF))
        case (.foggy, true): (top, bottom, hills, cloud) = (rgb(0xBFC6CC), rgb(0xE5E8EA), rgb(0xB4BEB9), rgb(0xF2F3F4))
        case (.snowy, false): (top, bottom, hills, cloud) = (rgb(0x334060), rgb(0x6A7896), rgb(0x9AA8BE), rgb(0x8E9AB2))
        case (.rainy, false), (.stormy, false):
            (top, bottom, hills, cloud) = (rgb(0x1F2532), rgb(0x3D4657), rgb(0x232C2A), rgb(0x434C5C))
        case (.cloudy, false), (.foggy, false):
            (top, bottom, hills, cloud) = (rgb(0x2A3142), rgb(0x4B5568), rgb(0x2A3433), rgb(0x5A6476))
        case (_, false): (top, bottom, hills, cloud) = (rgb(0x141B42), rgb(0x3A4A86), rgb(0x1E2C3A), rgb(0x5C6896))
        default: (top, bottom, hills, cloud) = (rgb(0x8EBCE6), rgb(0xD6E8F5), rgb(0x8DB894), rgb(0xFFFFFF))
        }
    }
}

/// Draws one frame of the sky. Every moving part is a function of the clock, so frames need no state.
private struct SkyPainter {
    let kind: PetWeatherKind
    let isDay: Bool
    let palette: SkyPalette
    let time: TimeInterval
    let size: CGSize
    let celestialPlacement: PetSkyPlacement?
    var pieces: SkyPieces?

    private var clear: Bool { kind == .sunny || kind == .windy }
    private var falls: Bool { kind == .rainy || kind == .stormy || kind == .snowy }

    func paint(_ canvas: inout GraphicsContext) {
        if let pieces { return paintDrawn(pieces, &canvas) }
        if !isDay && clear { stars(&canvas) }
        if clear { sunOrMoon(&canvas) }
        clouds(&canvas)
        hills(&canvas)
        if kind == .foggy { fog(&canvas) }
        if falls { precipitation(&canvas) }
        if kind == .stormy { lightning(&canvas) }
    }

    /// A stable pseudo-random number in 0..<1 for particle `index`, so the sky is the same every frame.
    private func seed(_ index: Int, _ salt: Double) -> Double {
        let value = sin(Double(index) * 12.9898 + salt * 78.233) * 43758.5453
        return value - floor(value)
    }

    private func stars(_ canvas: inout GraphicsContext) {
        for index in 0..<48 {
            let point = CGPoint(x: seed(index, 1) * size.width, y: seed(index, 2) * size.height * 0.45)
            let twinkle = 0.55 + 0.45 * sin(time * (1 + seed(index, 3) * 2) + seed(index, 4) * 6)
            let radius = 0.8 + seed(index, 5) * 1.4
            canvas.opacity = twinkle
            canvas.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                        with: .color(.white))
        }
        canvas.opacity = 1
    }

    private func sunOrMoon(_ canvas: inout GraphicsContext) {
        guard let placement = celestialPlacement else { return }
        let center = placement.center
        let radius = placement.side / 2
        if isDay {
            let pulse = 1 + sin(time * 2 * .pi / 4) * 0.04
            let glow = 120 * pulse
            canvas.fill(Path(ellipseIn: CGRect(x: center.x - glow, y: center.y - glow, width: glow * 2, height: glow * 2)),
                        with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.95, blue: 0.7).opacity(0.7), .clear]),
                                              center: center, startRadius: 0, endRadius: glow))
            canvas.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                        with: .color(Color(red: 1, green: 0.9, blue: 0.55)))
        } else {
            canvas.fill(Path(ellipseIn: CGRect(x: center.x - 90, y: center.y - 90, width: 180, height: 180)),
                        with: .radialGradient(Gradient(colors: [Color.white.opacity(0.25), .clear]),
                                              center: center, startRadius: 0, endRadius: 90))
            var moon = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            moon = moon.subtracting(Path(ellipseIn: CGRect(x: center.x - radius * 0.53, y: center.y - radius * 1.33,
                                                         width: radius * 2, height: radius * 2)))
            canvas.fill(moon, with: .color(Color(red: 1, green: 0.96, blue: 0.82)))
        }
    }

    private func clouds(_ canvas: inout GraphicsContext) {
        let count: Int
        let speed: Double
        switch kind {
        case .sunny: (count, speed) = (3, 6)
        case .windy: (count, speed) = (5, 40)
        case .cloudy, .foggy: (count, speed) = (7, 8)
        default: (count, speed) = (9, 14)
        }
        let span = size.width + 360
        for index in 0..<count {
            let width = 160 + seed(index, 6) * 160
            let y = size.height * (0.04 + seed(index, 7) * (falls ? 0.22 : 0.32))
            let x = (seed(index, 8) * span + time * speed * (0.7 + seed(index, 9) * 0.6))
                .truncatingRemainder(dividingBy: span) - 180
            canvas.opacity = falls ? 0.95 : 0.85
            canvas.fill(cloud(at: CGPoint(x: x, y: y), width: width), with: .color(palette.cloud))
        }
        canvas.opacity = 1
    }

    /// A puffy cloud: a flat base with three bumps on top.
    private func cloud(at origin: CGPoint, width: Double) -> Path {
        let height = width * 0.32
        var path = Path(roundedRect: CGRect(x: origin.x, y: origin.y + height * 0.45, width: width, height: height * 0.55),
                        cornerRadius: height * 0.27)
        path.addEllipse(in: CGRect(x: origin.x + width * 0.12, y: origin.y + height * 0.2, width: width * 0.34, height: height * 0.7))
        path.addEllipse(in: CGRect(x: origin.x + width * 0.34, y: origin.y, width: width * 0.4, height: height * 0.85))
        path.addEllipse(in: CGRect(x: origin.x + width * 0.6, y: origin.y + height * 0.25, width: width * 0.28, height: height * 0.6))
        return path
    }

    /// Soft distant hills, so a window low on the wall looks out on land, not more sky.
    private func hills(_ canvas: inout GraphicsContext) {
        for (layer, (height, opacity)) in [(0.46, 0.55), (0.52, 0.85)].enumerated() {
            var path = Path()
            let base = size.height * height
            path.move(to: CGPoint(x: 0, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: base))
            let steps = 6
            for step in 1...steps {
                let x = size.width * Double(step) / Double(steps)
                let previous = size.width * Double(step - 1) / Double(steps)
                let lift = 26 + seed(step + layer * 10, 10) * 34
                path.addQuadCurve(to: CGPoint(x: x, y: base - (step.isMultiple(of: 2) ? 0 : 10)),
                                  control: CGPoint(x: (x + previous) / 2, y: base - lift))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            canvas.opacity = opacity
            canvas.fill(path, with: .color(palette.hills))
        }
        canvas.opacity = 1
    }

    private func fog(_ canvas: inout GraphicsContext) {
        for index in 0..<4 {
            let y = size.height * (0.18 + Double(index) * 0.1)
            let drift = sin(time / (7 + Double(index) * 2) + Double(index)) * 40
            canvas.opacity = 0.35
            canvas.fill(Path(roundedRect: CGRect(x: -60 + drift, y: y, width: size.width + 120, height: 46), cornerRadius: 23),
                        with: .color(.white))
        }
        canvas.opacity = 1
    }

    private func precipitation(_ canvas: inout GraphicsContext) {
        let snowy = kind == .snowy
        let count = snowy ? 70 : (kind == .stormy ? 110 : 80)
        let cycle = snowy ? 7.0 : 0.9
        let color = snowy ? Color.white : Color.white.opacity(isDay ? 0.75 : 0.5)
        for index in 0..<count {
            let progress = ((time / cycle) * (0.8 + seed(index, 11) * 0.4) + seed(index, 12))
                .truncatingRemainder(dividingBy: 1)
            let y = progress * (size.height + 40) - 20
            if snowy {
                let sway = sin(time * 1.3 + seed(index, 13) * 6) * 14
                let x = seed(index, 14) * size.width + sway
                let radius = 1.8 + seed(index, 15) * 2.2
                canvas.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                            with: .color(color))
            } else {
                // Rain leans with the wind, harder in a storm.
                let slant = kind == .stormy ? 7.0 : 3.0
                let x = seed(index, 14) * (size.width + 40) - progress * slant * 4
                var drop = Path()
                drop.move(to: CGPoint(x: x, y: y))
                drop.addLine(to: CGPoint(x: x - slant, y: y + 16))
                canvas.stroke(drop, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
    }

    /// A double flicker of lightning every seven seconds or so, washing the whole sky.
    private func lightning(_ canvas: inout GraphicsContext) {
        guard isFlashing else { return }
        canvas.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.55)))
    }

    private var isFlashing: Bool {
        let beat = time.truncatingRemainder(dividingBy: 7.3)
        return beat < 0.08 || (beat > 0.18 && beat < 0.27)
    }

    // MARK: The sky drawn in the pet's style

    /// The same sky, moved the same way, out of the server's pieces instead of painted shapes.
    private func paintDrawn(_ pieces: SkyPieces, _ canvas: inout GraphicsContext) {
        switch kind {
        case .rainy, .snowy: wetCloud(pieces.body, canvas)
        case .stormy: break
        default: celestial(pieces.body, canvas)
        }
        if kind == .foggy {
            mist(pieces, canvas)
        } else {
            drift(pieces, canvas)
        }
        hills(&canvas)
        particles(pieces.particle, canvas)
        if kind == .stormy {
            lightning(&canvas)
            if isFlashing { bolt(pieces.body, canvas) }
        }
    }

    /// Draws `image` square, `side` points across, centred on `center`.
    private func place(
        _ image: GraphicsContext.ResolvedImage, at center: CGPoint, side: Double, in canvas: GraphicsContext,
        angle: Angle = .zero, scaleY: Double = 1, opacity: Double = 1
    ) {
        var layer = canvas
        layer.opacity = opacity
        layer.translateBy(x: center.x, y: center.y)
        layer.rotate(by: angle)
        layer.scaleBy(x: 1, y: scaleY)
        layer.draw(image, in: CGRect(x: -side / 2, y: -side / 2, width: side, height: side))
    }

    /// The sun turning slowly and breathing its glow, or the moon; hazy behind fog and cloud.
    private func celestial(_ image: GraphicsContext.ResolvedImage, _ canvas: GraphicsContext) {
        guard let placement = celestialPlacement else { return }
        let center = placement.center
        // The moon keeps its full fixed size. Only the spinning sun reserves rotation clearance.
        let side = isDay ? placement.side / 1.48 : placement.side
        let pulse = 1 + sin(time * 2 * .pi / 4) * 0.04
        let glow = (isDay ? 120 : 90) * pulse
        let light = isDay ? Color(red: 1, green: 0.95, blue: 0.7).opacity(0.6) : Color.white.opacity(0.22)
        canvas.fill(Path(ellipseIn: CGRect(x: center.x - glow, y: center.y - glow, width: glow * 2, height: glow * 2)),
                    with: .radialGradient(Gradient(colors: [light, .clear]), center: center, startRadius: 0, endRadius: glow))
        let hazy = kind == .foggy || kind == .cloudy
        place(image, at: center, side: side * (isDay ? pulse : 1), in: canvas,
              angle: .degrees(isDay ? time * 6 : 0), opacity: hazy ? 0.75 : 1)
    }

    /// The wide rain or snow cloud hanging over everything, heaving a little.
    private func wetCloud(_ image: GraphicsContext.ResolvedImage, _ canvas: GraphicsContext) {
        let side = max(size.width * 1.15, 360)
        for (index, offset) in [-0.3, 0.35].enumerated() {
            let sway = sin(time / (9 + Double(index) * 3) + Double(index)) * 24
            place(image, at: CGPoint(x: size.width * (0.5 + offset) + sway, y: size.height * 0.02 + Double(index) * 18),
                  side: side * (index == 0 ? 1 : 0.85), in: canvas, opacity: 0.97)
        }
    }

    /// Clouds crossing the window, big and small, faster in the wind and in wet weather.
    private func drift(_ pieces: SkyPieces, _ canvas: GraphicsContext) {
        let count: Int
        let speed: Double
        switch kind {
        case .sunny: (count, speed) = (3, 6)
        case .windy: (count, speed) = (5, 40)
        case .cloudy: (count, speed) = (7, 8)
        default: (count, speed) = (6, 14)
        }
        let span = size.width + 400
        for index in 0..<count {
            let wide = index.isMultiple(of: 2)
            let side = wide ? 200 + seed(index, 6) * 140 : 110 + seed(index, 6) * 70
            let y = size.height * (0.06 + seed(index, 7) * (falls ? 0.2 : 0.3))
            let x = (seed(index, 8) * span + time * speed * (0.7 + seed(index, 9) * 0.6))
                .truncatingRemainder(dividingBy: span) - 200
            place(wide ? pieces.wideCloud : pieces.smallCloud, at: CGPoint(x: x, y: y), side: side, in: canvas,
                  opacity: falls ? 0.95 : 0.9)
        }
    }

    /// Bands of mist swaying slowly at different heights.
    private func mist(_ pieces: SkyPieces, _ canvas: GraphicsContext) {
        for index in 0..<5 {
            let y = size.height * (0.12 + Double(index) * 0.08)
            let drift = sin(time / (7 + Double(index) * 2) + Double(index)) * 40
            let wide = index.isMultiple(of: 2)
            place(wide ? pieces.wideCloud : pieces.smallCloud,
                  at: CGPoint(x: size.width * (wide ? 0.35 : 0.7) + drift, y: y),
                  side: max(size.width, 320) * (wide ? 1.2 : 0.8), in: canvas, opacity: 0.7)
        }
    }

    /// The particle, repeated: falling rain and snow, tumbling leaves, birds, twinkling stars, curls of mist.
    private func particles(_ image: GraphicsContext.ResolvedImage, _ canvas: GraphicsContext) {
        switch kind {
        case .rainy, .stormy:
            let slant = kind == .stormy ? 0.22 : 0.08
            for index in 0..<(kind == .stormy ? 60 : 44) {
                let progress = ((time / 1.1) * (0.8 + seed(index, 11) * 0.4) + seed(index, 12)).truncatingRemainder(dividingBy: 1)
                let y = progress * (size.height + 60) - 30
                let x = seed(index, 14) * (size.width + 60) - progress * slant * size.height * 0.3
                place(image, at: CGPoint(x: x, y: y), side: 18 + seed(index, 15) * 10, in: canvas,
                      angle: .radians(slant), opacity: isDay ? 0.9 : 0.75)
            }
        case .snowy:
            for index in 0..<36 {
                let progress = ((time / 8) * (0.8 + seed(index, 11) * 0.4) + seed(index, 12)).truncatingRemainder(dividingBy: 1)
                let y = progress * (size.height + 60) - 30
                let x = seed(index, 14) * size.width + sin(time * 1.3 + seed(index, 13) * 6) * 16
                place(image, at: CGPoint(x: x, y: y), side: 16 + seed(index, 15) * 16, in: canvas,
                      angle: .degrees(time * (20 + seed(index, 16) * 40)))
            }
        case .windy:
            let span = size.width + 120
            for index in 0..<8 {
                let x = (seed(index, 8) * span + time * (90 + seed(index, 9) * 60)).truncatingRemainder(dividingBy: span) - 60
                let y = size.height * (0.1 + seed(index, 7) * 0.4) + sin(time * 2 + seed(index, 13) * 6) * 18
                place(image, at: CGPoint(x: x, y: y), side: 26 + seed(index, 15) * 12, in: canvas,
                      angle: .degrees(time * (120 + seed(index, 16) * 120)))
            }
        case .sunny where isDay:
            let span = size.width + 160
            for index in 0..<3 {
                let x = (seed(index, 8) * span + time * (18 + seed(index, 9) * 10)).truncatingRemainder(dividingBy: span) - 80
                let y = size.height * (0.08 + seed(index, 7) * 0.2) + sin(time * 0.9 + Double(index)) * 8
                place(image, at: CGPoint(x: x, y: y), side: 30 + seed(index, 15) * 10, in: canvas,
                      scaleY: 0.75 + 0.25 * sin(time * 9 + Double(index) * 2))
            }
        case .sunny:
            for index in 0..<18 {
                let twinkle = 0.45 + 0.55 * sin(time * (1 + seed(index, 3) * 2) + seed(index, 4) * 6)
                place(image, at: CGPoint(x: seed(index, 1) * size.width, y: seed(index, 2) * size.height * 0.42),
                      side: 10 + seed(index, 5) * 14, in: canvas, scaleY: 0.85 + 0.15 * twinkle, opacity: max(0, twinkle))
            }
        case .foggy, .cloudy:
            let span = size.width + 120
            for index in 0..<(kind == .foggy ? 6 : 4) {
                let x = (seed(index, 8) * span + time * (6 + seed(index, 9) * 6)).truncatingRemainder(dividingBy: span) - 60
                let y = size.height * (0.15 + seed(index, 7) * 0.3)
                place(image, at: CGPoint(x: x, y: y), side: 40 + seed(index, 15) * 30, in: canvas, opacity: 0.7)
            }
        default:
            break
        }
    }

    /// The storm's bolt, struck at a different place each flash.
    private func bolt(_ image: GraphicsContext.ResolvedImage, _ canvas: GraphicsContext) {
        let strike = Int(time / 7.3)
        place(image, at: CGPoint(x: size.width * (0.2 + seed(strike, 17) * 0.6), y: size.height * 0.22),
              side: max(size.height * 0.28, 160), in: canvas)
    }
}

#Preview {
    ScrollView(.horizontal) {
        HStack {
            ForEach([PetWeatherKind.sunny, .cloudy, .rainy, .snowy, .stormy, .foggy, .windy], id: \.self) { kind in
                VStack {
                    PetWindowSky(weather: PetWeather(kind: kind, temperatureC: 14, isDay: true))
                    PetWindowSky(weather: PetWeather(kind: kind, temperatureC: 4, isDay: false))
                }
                .frame(width: 180, height: 640)
            }
        }
    }
}
