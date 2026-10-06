import SwiftUI
import UIKit

/// The weather where the owner is, standing behind the pet: the server's drawing of it in the pet's
/// own style, or bundled weather artwork until that is drawn. It moves the way its weather does — a sun
/// rocks and glows, clouds drift, rain and snow fall from under their cloud, a storm flashes — and
/// holds still when the system asks for reduced motion.
struct PetWeatherSticker: View {
    let weather: PetWeather
    let art: UIImage?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let motion = PetWeatherMotion(kind: weather.kind, isDay: weather.isDay, time: time)
            ZStack {
                if motion.falls {
                    PetWeatherFall(kind: weather.kind, time: time)
                        .allowsHitTesting(false)
                }
                picture
                    .scaleEffect(motion.scale)
                    .rotationEffect(.degrees(motion.tilt))
                    .offset(x: motion.drift, y: motion.bob)
                    .brightness(motion.flash)
                    .opacity(motion.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: art == nil)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var picture: some View {
        if let art {
            Image(uiImage: art)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
        } else {
            Image(weather.kind.defaultArtworkName(isDay: weather.isDay))
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .transition(.opacity)
        }
    }
}

extension PetWeatherKind {
    /// Bundled artwork is available immediately, including while offline or waiting for custom art.
    func defaultArtworkName(isDay: Bool) -> String {
        switch self {
        case .sunny: isDay ? "PetWeatherSunny" : "PetWeatherMoon"
        case .rainy: "PetWeatherRainy"
        case .snowy: "PetWeatherSnowy"
        case .stormy: "PetWeatherStormy"
        case .foggy: "PetWeatherFoggy"
        case .windy: "PetWeatherWindy"
        default: "PetWeatherCloudy"
        }
    }

    /// The weather's colour, for its symbol on the poster paper, where a white cloud would vanish.
    func tint(isDay: Bool) -> Color {
        switch self {
        case .sunny: isDay ? .orange : .indigo
        case .rainy: .blue
        case .snowy: .cyan
        case .stormy: .purple
        case .windy: .teal
        default: AppColors.muted
        }
    }
}

/// One moment of a weather's motion. Every part is a slow sine of the clock, at periods that do not
/// line up, so the loop never visibly repeats.
private struct PetWeatherMotion {
    var drift = 0.0
    var bob = 0.0
    var tilt = 0.0
    var scale = 1.0
    var flash = 0.0
    var opacity = 1.0
    /// Whether rain or snow falls from under the picture.
    var falls = false

    init(kind: PetWeatherKind, isDay: Bool, time: TimeInterval) {
        func wave(_ period: Double, phase: Double = 0) -> Double { sin((time + phase) * 2 * .pi / period) }
        switch kind {
        case .sunny where isDay:
            tilt = wave(6) * 6
            scale = 1 + wave(3.1) * 0.04
        case .sunny:
            bob = wave(4.2) * 4
            tilt = wave(7.5) * 3
            opacity = 0.9 + wave(2.3) * 0.1
        case .cloudy, .foggy:
            drift = wave(9) * 12
            bob = wave(5.3) * 3
            opacity = kind == .foggy ? 0.8 + wave(6.1) * 0.15 : 1
        case .windy:
            drift = wave(3.2) * 14
            tilt = wave(1.7) * 5
        case .rainy, .snowy:
            bob = wave(3.4) * 5
            drift = wave(8.3) * 6
            falls = true
        case .stormy:
            bob = wave(2.8) * 4
            drift = wave(1.1) * 1.5
            falls = true
            // A double flicker of lightning every five seconds or so.
            let beat = time.truncatingRemainder(dividingBy: 5.2)
            flash = beat < 0.08 || (beat > 0.18 && beat < 0.26) ? 0.35 : 0
        default:
            bob = wave(4) * 4
        }
    }
}

/// Drops or flakes falling from under the weather's cloud, drawn in one canvas pass.
private struct PetWeatherFall: View {
    let kind: PetWeatherKind
    let time: TimeInterval

    /// Each particle's column across the cloud, its speed, and where in the fall it starts.
    private static let particles: [(x: Double, speed: Double, phase: Double)] = [
        (0.24, 1.0, 0.0), (0.38, 1.25, 0.45), (0.52, 0.9, 0.2), (0.66, 1.15, 0.7), (0.78, 1.05, 0.35),
        (0.31, 0.95, 0.85), (0.59, 1.3, 0.6), (0.45, 1.1, 0.1)
    ]

    var body: some View {
        Canvas { context, size in
            let snowy = kind == .snowy
            let color = snowy ? Color.white : Color(red: 0.36, green: 0.62, blue: 0.95)
            let cycle = snowy ? 2.6 : 0.9
            for particle in Self.particles {
                let progress = ((time * particle.speed / cycle) + particle.phase).truncatingRemainder(dividingBy: 1)
                let sway = snowy ? sin((time + particle.phase * 4) * 2) * 6 : 0
                // From the cloud's underside, around the middle of the picture, to its bottom edge.
                let point = CGPoint(x: particle.x * size.width + sway, y: size.height * (0.55 + progress * 0.4))
                // Fades in under the cloud and out before the ground.
                context.opacity = min(progress * 5, 1) * (1 - progress)
                if snowy {
                    let flake = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
                    context.fill(Path(ellipseIn: flake), with: .color(color))
                    context.stroke(Path(ellipseIn: flake), with: .color(AppColors.ink.opacity(0.35)), lineWidth: 1)
                } else {
                    var drop = Path()
                    drop.move(to: point)
                    drop.addLine(to: CGPoint(x: point.x - 2, y: point.y + 10))
                    context.stroke(drop, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }
            }
        }
    }
}

/// The weather in words: its symbol, the temperature, and what kind it is, like the gold badge.
struct PetWeatherChip: View {
    let weather: PetWeather

    private var temperature: String {
        Measurement(value: weather.temperatureC, unit: UnitTemperature.celsius)
            .formatted(.measurement(width: .narrow, numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: weather.kind.symbol(isDay: weather.isDay))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(weather.kind.tint(isDay: weather.isDay))
            Text(verbatim: temperature)
                .monospacedDigit()
                .contentTransition(.numericText(value: weather.temperatureC))
        }
        .font(.system(size: 13, weight: .heavy, design: .monospaced))
        .foregroundStyle(AppColors.ink)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(AppColors.card, in: .capsule)
        .overlay { Capsule().strokeBorder(AppColors.ink, lineWidth: 2) }
        .animation(.snappy(duration: 0.45), value: weather)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Weather: \(weather.kind.displayName), \(temperature)"))
        .accessibilityIdentifier("pet-weather")
    }
}

/// The owner's time, in the same badge as the weather, for the plain page and rooms drawn without a clock.
struct PetClockChip: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: 4) {
                Image(systemName: "clock.fill")
                    .symbolRenderingMode(.hierarchical)
                Text(context.date, format: .dateTime.hour().minute())
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .font(.system(size: 13, weight: .heavy, design: .monospaced))
            .foregroundStyle(AppColors.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(AppColors.card, in: .capsule)
            .overlay { Capsule().strokeBorder(AppColors.ink, lineWidth: 2) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Time: \(context.date.formatted(date: .omitted, time: .shortened))"))
        }
        .accessibilityIdentifier("pet-clock")
    }
}

#Preview {
    VStack(spacing: 24) {
        ForEach([PetWeatherKind.sunny, .rainy, .snowy, .stormy], id: \.self) { kind in
            let weather = PetWeather(kind: kind, temperatureC: 14, isDay: true)
            HStack {
                PetWeatherSticker(weather: weather, art: nil).frame(width: 110, height: 110)
                PetWeatherChip(weather: weather)
            }
        }
    }
    .padding()
}
