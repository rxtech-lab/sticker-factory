import SwiftUI

/// The pet's stats as the room's status board shows them.
struct PetRoomStats: Equatable {
    var happiness: Int
    var hp: Int
    var maxHp: Int
    var energy: Int
}

/// The time, the weather and the pet's stats written onto the clock face, weather board and status
/// board drawn into a room or place. Laid over the drawing at its own size, so each lands on the
/// blank surface the server painted, in the ink taken from the frame around it, and reads as part
/// of the picture.
struct PetRoomFixturesLayer: View {
    let fixtures: PetRoomFixtures
    let weather: PetWeather?
    /// What the status board shows; nil leaves it blank.
    var stats: PetRoomStats?
    /// The weather drawn in the pet's style, chalked onto the board when it is ready.
    var weatherArt: UIImage?
    /// Where the room's drawing sits in the backdrop, and the backdrop it is cropped to.
    var drawn: CGRect = .zero
    var bounds: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let shown = fixtures.visible(drawnIn: drawn, bounds: bounds)
            ZStack(alignment: .topLeading) {
                if let clock = shown?.clock {
                    // Hands reach to the rim and are cropped with the room like the rest of the
                    // clock; digits are kept to the part on screen.
                    PetRoomClockFace(fixture: clock)
                        .fixtureFrame(clock, in: proxy.size, insetsRound: false,
                                      content: clock.shape == .round ? nil : clock.onScreen(drawnIn: drawn, bounds: bounds))
                }
                if let board = shown?.weather {
                    // A board the screen's edge cuts through keeps its writing on the part in view.
                    PetRoomWeatherBoard(fixture: board, weather: weather, art: weatherArt)
                        .fixtureFrame(board, in: proxy.size, insetsRound: true,
                                      content: board.onScreen(drawnIn: drawn, bounds: bounds))
                }
                if let board = shown?.status, let stats {
                    PetRoomStatusBoard(fixture: board, stats: stats)
                        .fixtureFrame(board, in: proxy.size, insetsRound: true,
                                      content: board.onScreen(drawnIn: drawn, bounds: bounds))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// The room's clock, telling the owner's time: hands on a round face, digits on a square one.
struct PetRoomClockFace: View {
    let fixture: PetRoomFixture

    var body: some View {
        TimelineView(.everyMinute) { context in
            Group {
                switch fixture.shape {
                case .round: PetRoomClockHands(date: context.date, ink: fixture.inkColor)
                case .rect:
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: 200, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.05)
                        .lineLimit(1)
                        .foregroundStyle(fixture.inkColor)
                        .padding(.horizontal, 6)
                        .contentTransition(.numericText())
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Time: \(context.date.formatted(date: .omitted, time: .shortened))"))
            .accessibilityIdentifier("pet-room-clock")
        }
    }
}

/// An analog face: twelve marks, an hour hand and a minute hand, drawn in the frame's ink.
private struct PetRoomClockHands: View {
    let date: Date
    let ink: Color

    var body: some View {
        Canvas { context, size in
            let radius = min(size.width, size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            let minute = Double(parts.minute ?? 0)
            let hour = Double((parts.hour ?? 0) % 12) + minute / 60

            for mark in 0..<12 {
                let angle = Angle.degrees(Double(mark) * 30 - 90).radians
                let long = mark % 3 == 0
                let outer = radius * 0.86
                let inner = radius * (long ? 0.7 : 0.77)
                var tick = Path()
                tick.move(to: point(center, angle, inner))
                tick.addLine(to: point(center, angle, outer))
                context.stroke(tick, with: .color(ink.opacity(0.85)),
                               style: StrokeStyle(lineWidth: radius * (long ? 0.07 : 0.035), lineCap: .round))
            }
            hand(&context, center, angle: hour * 30, length: radius * 0.48, width: radius * 0.1)
            hand(&context, center, angle: minute * 6, length: radius * 0.72, width: radius * 0.065)
            let pin = radius * 0.08
            context.fill(Path(ellipseIn: CGRect(x: center.x - pin, y: center.y - pin, width: pin * 2, height: pin * 2)),
                         with: .color(ink))
        }
        .animation(.snappy, value: date)
    }

    private func hand(_ context: inout GraphicsContext, _ center: CGPoint, angle: Double, length: CGFloat, width: CGFloat) {
        var path = Path()
        path.move(to: center)
        path.addLine(to: point(center, Angle.degrees(angle - 90).radians, length))
        context.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    private func point(_ center: CGPoint, _ radians: Double, _ distance: CGFloat) -> CGPoint {
        CGPoint(x: center.x + cos(radians) * distance, y: center.y + sin(radians) * distance)
    }
}

/// The room's weather board: the weather's symbol and the temperature where the owner is, or a
/// dash while the pet does not know it.
struct PetRoomWeatherBoard: View {
    let fixture: PetRoomFixture
    let weather: PetWeather?
    var art: UIImage?

    /// The reading without its unit, for a board too narrow to spell it out.
    private var shortTemperature: String { String(format: "%.0f°", weather?.temperatureC ?? 0) }

    private var temperature: String {
        guard let weather else { return "–°" }
        return Measurement(value: weather.temperatureC, unit: UnitTemperature.celsius)
            .formatted(.measurement(width: .narrow, numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    var body: some View {
        // Laid out for the room the board has on screen: side by side on a wide board, stacked on
        // a tall one, and the bare reading on a sliver the screen's edge leaves.
        GeometryReader { proxy in
            let size = proxy.size
            Group {
                if size.height < 24 {
                    // A short sliver: a small icon in the board's ink beside the bare reading.
                    HStack(spacing: 2) {
                        symbolGlyph.frame(width: size.height * 0.7, height: size.height * 0.7)
                        reading(shortTemperature, size: size.height * 0.6)
                    }
                } else if size.width < 56 {
                    // A narrow sliver: a small icon in the board's ink over the bare reading.
                    VStack(spacing: size.height * 0.04) {
                        symbolGlyph.frame(width: size.width * 0.55, height: min(size.height * 0.36, size.width * 0.55))
                        reading(shortTemperature, size: min(size.height * 0.34, size.width * 0.42))
                    }
                } else if size.width >= size.height * 1.4 {
                    HStack(spacing: size.height * 0.08) {
                        symbol.frame(width: size.height * 0.8, height: size.height * 0.8)
                        reading(temperature, size: size.height * 0.5)
                    }
                } else {
                    VStack(spacing: 0) {
                        symbol.frame(maxHeight: size.height * 0.55)
                        reading(temperature, size: min(size.height * 0.32, size.width * 0.3))
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .foregroundStyle(fixture.inkColor)
        .padding(2)
        .animation(.snappy(duration: 0.45), value: weather)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(weather.map { Text("Weather: \($0.kind.displayName), \(temperature)") } ?? Text("Weather unknown"))
        .accessibilityIdentifier("pet-room-weather")
    }

    @ViewBuilder
    private var symbol: some View {
        if let art {
            Image(uiImage: art)
                .resizable()
                .scaledToFit()
                .frame(minWidth: 8, minHeight: 8)
        } else {
            symbolGlyph
        }
    }

    private var symbolGlyph: some View {
        Image(systemName: weather?.kind.symbol(isDay: weather?.isDay ?? true) ?? "thermometer.medium")
            .resizable()
            .scaledToFit()
            .fontWeight(.bold)
            .symbolRenderingMode(.monochrome)
            .contentTransition(.symbolEffect(.replace))
    }

    private func reading(_ text: String, size: CGFloat) -> some View {
        Text(verbatim: weather == nil ? "–°" : text)
            .font(.system(size: max(size, 6), weight: .heavy, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.4)
            .lineLimit(1)
            .contentTransition(.numericText(value: weather?.temperatureC ?? 0))
    }
}

/// The room's status board: how the pet is doing, written on the board drawn into the room in the
/// board's own ink, the way chalk or paint on it would be, rather than an app card laid on top. A
/// wide board holds the three gauges side by side; a squarer one stacks them with their names.
struct PetRoomStatusBoard: View {
    let fixture: PetRoomFixture
    let stats: PetRoomStats

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let wide = size.width >= size.height * 2.2
            // The height each gauge has, which its writing is sized from.
            let unit = wide ? size.height : size.height / 3
            let layout = wide
                ? AnyLayout(HStackLayout(alignment: .center, spacing: size.width * 0.05))
                : AnyLayout(VStackLayout(spacing: unit * 0.1))
            layout {
                PetBoardGauge(title: "Happiness", value: stats.happiness, symbol: "heart.fill", color: .pink,
                              ink: fixture.inkColor, unit: unit, wide: wide)
                PetBoardGauge(title: "HP", value: stats.hp, maximum: stats.maxHp, symbol: "cross.vial.fill", color: .red,
                              ink: fixture.inkColor, unit: unit, wide: wide)
                PetBoardGauge(title: "Energy", value: stats.energy, symbol: "bolt.fill", color: .orange,
                              ink: fixture.inkColor, unit: unit, wide: wide)
            }
            .padding(.horizontal, size.width * (wide ? 0.06 : 0.08))
            .padding(.vertical, size.height * (wide ? 0.16 : 0.06))
            .frame(width: size.width, height: size.height)
        }
        // An action's effects land as the gauges sliding to their new values.
        .animation(.snappy(duration: 0.45), value: stats)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pet-room-status")
    }
}

/// One stat on the status board: its icon, its reading, and a segmented gauge outlined in the
/// board's ink. A small change indicator sits above the icon for a while.
private struct PetBoardGauge: View {
    let title: LocalizedStringKey
    let value: Int
    var maximum: Int = 100
    let symbol: String
    let color: Color
    let ink: Color
    let unit: CGFloat
    /// Side by side on a wide board: the icon stands for the name, and the gauge has fewer segments.
    let wide: Bool

    private static let highlightDuration: Duration = .seconds(60)
    @State private var delta: Int?
    @State private var changeCount = 0

    private var textSize: CGFloat { max(7, unit * (wide ? 0.24 : 0.3)) }
    private var gaugeHeight: CGFloat { max(5, unit * (wide ? 0.22 : 0.26)) }
    private var lineWidth: CGFloat { max(1.2, unit * 0.035) }

    var body: some View {
        VStack(alignment: .leading, spacing: unit * 0.08) {
            HStack(spacing: textSize * 0.3) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .frame(width: textSize * 1.2, height: textSize * 1.2)
                    .overlay(alignment: .top) {
                        if let delta {
                            Text(verbatim: delta > 0 ? "+\(delta)" : "\(delta)")
                                .font(.system(size: textSize * 0.55, weight: .heavy, design: .rounded))
                                .foregroundStyle(delta > 0 ? AppColors.mint : AppColors.coral)
                                .fixedSize()
                                .contentTransition(.numericText(value: Double(delta)))
                                .transition(.scale(scale: 0.5, anchor: .bottom).combined(with: .opacity))
                                .offset(y: -textSize * 0.7)
                        }
                    }
                if !wide {
                    Text(title)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(verbatim: "\(value)/\(maximum)")
                    .lineLimit(1)
                    .minimumScaleFactor(0.1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .contentTransition(.numericText(value: Double(value)))
            }
            .font(.system(size: textSize, weight: .heavy, design: .rounded))
            .monospacedDigit()
            // Reserve the indicator's space even when there is no change, so the icon and
            // reading stay aligned and the board does not jump as feedback appears.
            .padding(.top, textSize * 0.7)
            gauge
        }
        .foregroundStyle(ink)
        .onChange(of: value) { old, new in
            guard new != old else { return }
            withAnimation(.snappy(duration: 0.3)) { delta = (delta ?? 0) + (new - old) }
            if delta == 0 { withAnimation(.easeOut(duration: 0.3)) { delta = nil } }
            changeCount += 1
        }
        .task(id: changeCount) {
            guard delta != nil else { return }
            try? await Task.sleep(for: Self.highlightDuration)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.5)) { delta = nil }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: "\(value)/\(maximum)"))
    }

    private var gauge: some View {
        let segments = wide ? 10 : 20
        let ceiling = max(maximum, 1)
        let filled = Int((Double(min(max(value, 0), ceiling)) / Double(ceiling) * Double(segments)).rounded())
        return HStack(spacing: max(1, lineWidth * 0.8)) {
            ForEach(0..<segments, id: \.self) { index in
                Rectangle()
                    .fill(index < filled ? color.opacity(0.85) : ink.opacity(0.1))
            }
        }
        .padding(lineWidth * 1.4)
        .frame(height: gaugeHeight)
        .overlay { RoundedRectangle(cornerRadius: lineWidth).strokeBorder(ink, lineWidth: lineWidth) }
        .accessibilityHidden(true)
    }
}

private extension View {
    /// Places a fixture's view over its box in the room's drawing, on the surface drawn there.
    /// `insetsRound` keeps writing inside the square that fits in a round face, and `content`, the
    /// part of the fixture on screen in its own points, keeps it out of the part cropped off.
    func fixtureFrame(_ fixture: PetRoomFixture, in size: CGSize, insetsRound: Bool, content: CGRect? = nil) -> some View {
        let width = fixture.width * size.width
        let height = fixture.height * size.height
        let visible = content ?? CGRect(x: 0, y: 0, width: width, height: height)
        let inset = fixture.shape == .round && insetsRound ? min(visible.width, visible.height) * 0.15 : 2
        let shape = fixture.shape == .round ? AnyShape(Ellipse()) : AnyShape(Rectangle())
        return padding(inset)
            .padding(EdgeInsets(top: visible.minY, leading: visible.minX,
                                bottom: max(0, height - visible.maxY), trailing: max(0, width - visible.maxX)))
            .frame(width: width, height: height)
            // Shaded toward the rim the way the room's own light falls on it, so the writing sits
            // in the picture rather than on top of it.
            .overlay {
                shape.fill(EllipticalGradient(colors: [.clear, fixture.inkColor.opacity(0.2)],
                                              startRadiusFraction: 0.3, endRadiusFraction: 0.75))
                    .blendMode(.multiply)
            }
            .compositingGroup()
            .opacity(0.92)
            .clipShape(shape)
            .offset(x: fixture.x * size.width, y: fixture.y * size.height)
    }
}

extension PetRoomFixtures {
    /// The fixtures that show when the room's drawing fills `drawn` and is cropped to `bounds`; nil
    /// when none does. A fixture the crop cuts through still counts while a good part of it is in
    /// view, and a clock while its middle is: it is part of the picture, cropped like the rest of it.
    /// The status board needs most of it in view, or its gauges would not read.
    func visible(drawnIn drawn: CGRect, bounds: CGSize) -> PetRoomFixtures? {
        let result = PetRoomFixtures(
            clock: clock.flatMap { Self.shownFraction($0, needsMiddle: true, drawn: drawn, bounds: bounds) >= 0.35 ? $0 : nil },
            weather: weather.flatMap { Self.shownFraction($0, needsMiddle: false, drawn: drawn, bounds: bounds) >= 0.35 ? $0 : nil },
            status: status.flatMap { Self.shownFraction($0, needsMiddle: false, drawn: drawn, bounds: bounds) >= 0.8 ? $0 : nil }
        )
        return result.clock == nil && result.weather == nil && result.status == nil ? nil : result
    }

    /// How far to slide a room drawn at `drawn` size sideways from centre, within what filling
    /// `bounds` crops off, so the worse shown of its clock and boards shows as much as it can. A
    /// room that has it all in view either way stays centred.
    func bestShift(drawn: CGSize, bounds: CGSize) -> CGFloat {
        let slack = (drawn.width - bounds.width) / 2
        guard slack > 1, clock != nil || weather != nil || status != nil else { return 0 }
        func score(_ shift: CGFloat) -> Double {
            let rect = CGRect(x: (bounds.width - drawn.width) / 2 + shift, y: (bounds.height - drawn.height) / 2,
                              width: drawn.width, height: drawn.height)
            let shown = [
                clock.map { Self.shownFraction($0, needsMiddle: true, drawn: rect, bounds: bounds) },
                weather.map { Self.shownFraction($0, needsMiddle: false, drawn: rect, bounds: bounds) },
                status.map { Self.shownFraction($0, needsMiddle: false, drawn: rect, bounds: bounds) }
            ].compactMap { $0 }
            return shown.min() ?? 0
        }
        var best: (shift: CGFloat, score: Double) = (0, score(0))
        for step in -20...20 {
            let shift = slack * CGFloat(step) / 20
            let value = score(shift)
            if value > best.score + 0.01 || (abs(value - best.score) <= 0.01 && abs(shift) < abs(best.shift)) {
                best = (shift, value)
            }
        }
        return best.shift
    }

    /// The share of `fixture` on screen, or none of it when `needsMiddle` and its middle is cut off.
    private static func shownFraction(_ fixture: PetRoomFixture, needsMiddle: Bool, drawn: CGRect, bounds: CGSize) -> Double {
        guard let onScreen = fixture.onScreen(drawnIn: drawn, bounds: bounds) else { return 0 }
        let width = fixture.width * drawn.width
        let height = fixture.height * drawn.height
        if needsMiddle, !onScreen.contains(CGPoint(x: width / 2, y: height / 2)) { return 0 }
        return Double(onScreen.width * onScreen.height / max(width * height, 1))
    }
}

extension PetRoomFixture {
    /// The part of this fixture on screen, in its own points, when the room's drawing fills `drawn`
    /// and is cropped to `bounds`; nil when none of it is.
    func onScreen(drawnIn drawn: CGRect, bounds: CGSize) -> CGRect? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let rect = CGRect(x: drawn.minX + x * drawn.width, y: drawn.minY + y * drawn.height,
                          width: width * drawn.width, height: height * drawn.height)
        let visible = rect.intersection(CGRect(origin: .zero, size: bounds))
        guard !visible.isNull, visible.width > 1, visible.height > 1 else { return nil }
        return visible.offsetBy(dx: -rect.minX, dy: -rect.minY)
    }

    var inkColor: Color { Color(hexString: ink) ?? AppColors.ink }
}

private extension Color {
    /// `#RRGGBB`, as the server writes a room's colours.
    init?(hexString: String) {
        guard hexString.count == 7, hexString.hasPrefix("#"),
              let value = UInt32(hexString.dropFirst(), radix: 16) else { return nil }
        self.init(hex: value)
    }
}

#Preview {
    let fixtures = PetRoomFixtures(
        clock: PetRoomFixture(x: 0.08, y: 0.12, width: 0.3, height: 0.2, shape: .round, face: "#F0E6D2", ink: "#5A3B22"),
        weather: PetRoomFixture(x: 0.55, y: 0.4, width: 0.35, height: 0.12, shape: .rect, face: "#EDE7DA", ink: "#2F2F2F"),
        status: PetRoomFixture(x: 0.22, y: 0.6, width: 0.56, height: 0.17, shape: .rect, face: "#EDE7DA", ink: "#2F2F2F")
    )
    GeometryReader { proxy in
        ZStack {
            Color(hex: 0xF0D6A8)
            PetRoomFixturesLayer(fixtures: fixtures, weather: PetWeather(kind: .rainy, temperatureC: 14, isDay: true),
                                 stats: PetRoomStats(happiness: 80, hp: 60, maxHp: 120, energy: 30),
                                 drawn: CGRect(origin: .zero, size: proxy.size), bounds: proxy.size)
        }
    }
    .aspectRatio(2.0 / 3.0, contentMode: .fit)
    .padding()
}
