import SwiftUI

/// The outside, as seen through the windows of the pet's room. The server cuts each room's window
/// glass out of its drawing, so this fills the whole tab behind the room and shows only where the
/// glass was: the owner's real weather, day or night, moving the way that weather does. With no
/// weather read yet it shows a clear sky for the time of day. Holds still under reduced motion.
struct PetWindowSky: View {
    let weather: PetWeather?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var kind: PetWeatherKind { weather?.kind ?? .sunny }
    private var isDay: Bool {
        if let weather { return weather.isDay }
        let hour = Calendar.current.component(.hour, from: .now)
        return (6..<19).contains(hour)
    }

    var body: some View {
        let palette = SkyPalette(kind: kind, isDay: isDay)
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                SkyPainter(kind: kind, isDay: isDay, palette: palette, time: time, size: size).paint(&canvas)
            }
        }
        .background(LinearGradient(colors: [palette.top, palette.bottom], startPoint: .top, endPoint: .bottom))
        // The glass: a faint sheen so the view reads as through a window, not a hole in the wall.
        .overlay(Color.white.opacity(0.08))
        .animation(.easeInOut(duration: 1.2), value: weather)
        .accessibilityHidden(true)
    }
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

    private var clear: Bool { kind == .sunny || kind == .windy }
    private var falls: Bool { kind == .rainy || kind == .stormy || kind == .snowy }

    func paint(_ canvas: inout GraphicsContext) {
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
        let center = CGPoint(x: size.width * 0.72, y: size.height * 0.14)
        if isDay {
            let pulse = 1 + sin(time * 2 * .pi / 4) * 0.04
            let glow = 120 * pulse
            canvas.fill(Path(ellipseIn: CGRect(x: center.x - glow, y: center.y - glow, width: glow * 2, height: glow * 2)),
                        with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.95, blue: 0.7).opacity(0.7), .clear]),
                                              center: center, startRadius: 0, endRadius: glow))
            canvas.fill(Path(ellipseIn: CGRect(x: center.x - 42, y: center.y - 42, width: 84, height: 84)),
                        with: .color(Color(red: 1, green: 0.9, blue: 0.55)))
        } else {
            canvas.fill(Path(ellipseIn: CGRect(x: center.x - 90, y: center.y - 90, width: 180, height: 180)),
                        with: .radialGradient(Gradient(colors: [Color.white.opacity(0.25), .clear]),
                                              center: center, startRadius: 0, endRadius: 90))
            var moon = Path(ellipseIn: CGRect(x: center.x - 30, y: center.y - 30, width: 60, height: 60))
            moon = moon.subtracting(Path(ellipseIn: CGRect(x: center.x - 16, y: center.y - 40, width: 60, height: 60)))
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
        let beat = time.truncatingRemainder(dividingBy: 7.3)
        guard beat < 0.08 || (beat > 0.18 && beat < 0.27) else { return }
        canvas.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.55)))
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
