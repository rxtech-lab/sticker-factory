import SwiftUI
import WidgetKit

/// The pet on the Home Screen and Lock Screen, posed the way it last read the user's stickers.
///
/// It draws what the app wrote to the app group (`PetCompanionSync`): the app reloads this timeline
/// whenever the pet changes, including when the server's silent push wakes it after a send. Between
/// those, the timeline comes back every five minutes and `PetWidgetRefresh` fetches the pet again if
/// the app has not written it lately, so the pet keeps living on the Home Screen with the app closed.
struct PetWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: PetCompanion.phoneWidgetKind,
            provider: PetTimelineProvider(refresh: { await PetWidgetRefresh.refreshIfNeeded() })
        ) { entry in
            PetWidgetView(entry: entry)
                .containerBackground(for: .widget) { PetWidgetBackground() }
        }
        .configurationDisplayName("Pet")
        .description("Your pet, and how it feels about the stickers you send.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct PetWidgetView: View {
    let entry: PetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .accessoryCircular:
                PetPoseImage(data: entry.pose)
                    .padding(2)
                    .accessibilityLabel(snapshot.title)
            case .accessoryInline:
                Label(snapshot.caption ?? snapshot.title, systemImage: "pawprint.fill")
            case .accessoryRectangular:
                HStack(spacing: 6) {
                    PetPoseImage(data: entry.pose)
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(snapshot.title).font(.headline).widgetAccentable().lineLimit(1)
                        Text(snapshot.caption ?? String(localized: "Waiting for your next sticker"))
                            .font(.caption)
                            .lineLimit(2)
                    }
                }
            case .systemMedium:
                HStack(spacing: 14) {
                    PetPoseImage(data: entry.pose)
                        .frame(maxHeight: .infinity)
                        .overlay(alignment: .topLeading) { weather(size: 48).offset(x: -10, y: -8) }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(snapshot.title)
                            .font(.system(.headline, design: .rounded, weight: .bold))
                            .lineLimit(1)
                        PetCaption(snapshot: snapshot)
                        Spacer(minLength: 0)
                        if let updated = snapshot.statusUpdatedAt {
                            Text(updated, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            default:
                VStack(spacing: 6) {
                    PetPoseImage(data: entry.pose)
                        .frame(maxHeight: .infinity)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .topTrailing) { weather(size: 40).offset(x: 6, y: -6) }
                    PetCaption(snapshot: snapshot)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
        } else {
            NoPetView(family: family)
        }
    }

    /// The weather beside the pet, when the phone knows it.
    @ViewBuilder
    private func weather(size: CGFloat) -> some View {
        if let weather = entry.snapshot?.weather {
            PetWidgetWeather(weather: weather, art: entry.weatherArt, size: size, phase: entry.phase)
        }
    }
}

/// The weather drawn in the pet's style, or its symbol, over the temperature. Widgets cannot run an
/// animation of their own, so each timeline entry nudges it the other way and the system animates
/// the move: a slow drift and bob from one minute to the next.
private struct PetWidgetWeather: View {
    let weather: PetSnapshotWeather
    let art: Data?
    let size: CGFloat
    let phase: Int

    private var temperature: String {
        Measurement(value: weather.temperatureC, unit: UnitTemperature.celsius)
            .formatted(.measurement(width: .narrow, numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    var body: some View {
        let swing: CGFloat = phase.isMultiple(of: 2) ? 1 : -1
        VStack(spacing: 0) {
            Group {
                if let art, let image = UIImage(data: art) {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .widgetAccentedRenderingMode(.fullColor)
                        .scaledToFit()
                } else {
                    Image(systemName: weather.symbol)
                        .resizable()
                        .scaledToFit()
                        .symbolRenderingMode(.multicolor)
                        .padding(size * 0.12)
                }
            }
            .frame(width: size, height: size)
            .offset(x: swing * size * 0.06, y: swing * -size * 0.04)
            .rotationEffect(.degrees(Double(swing) * 3))
            .animation(.smooth(duration: 1.6), value: phase)
            Text(verbatim: temperature)
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: temperature))
    }
}

/// The pet's words, in quotes, or a nudge until it has read a sticker.
private struct PetCaption: View {
    let snapshot: PetSnapshot

    var body: some View {
        Group {
            if let caption = snapshot.caption {
                Text("“\(caption)”")
            } else {
                Text("Send a sticker to see how I feel")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(.footnote, design: .rounded))
        .lineLimit(3)
    }
}

private struct NoPetView: View {
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryInline:
            Label("No pet yet", systemImage: "pawprint")
        case .accessoryCircular:
            Image(systemName: "pawprint")
                .font(.title2)
                .accessibilityLabel("No pet yet")
        default:
            VStack(spacing: 6) {
                Image(systemName: "pawprint")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text("Choose a pet in Winky")
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// The app's poster paper, so the pet sits on the same warm card it does in the Pet tab.
private struct PetWidgetBackground: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall, .systemMedium:
            Color(red: 1, green: 0.96, blue: 0.84)
        default:
            // Accessory families draw on the system's own material.
            Color.clear
        }
    }
}

#Preview(as: .systemSmall) {
    PetWidget()
} timeline: {
    PetEntry.placeholder
    PetEntry(
        date: .now,
        snapshot: PetSnapshot(stickerID: "placeholder", title: "Winky", caption: "Puddles!", statusUpdatedAt: .now,
                              selectedAt: .now, poseKey: "placeholder",
                              weather: PetSnapshotWeather(kind: "rainy", symbol: "cloud.rain.fill", temperatureC: 14,
                                                          isDay: true, artKey: nil)),
        pose: nil
    )
    PetEntry(date: .now, snapshot: nil, pose: nil)
}
