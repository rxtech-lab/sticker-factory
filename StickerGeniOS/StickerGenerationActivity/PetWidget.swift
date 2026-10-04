import SwiftUI
import WidgetKit

/// The pet on the Home Screen and Lock Screen, posed the way it last read the user's stickers.
///
/// It reads only what the app wrote to the app group (`PetCompanionSync`) and never goes to the
/// network: the app reloads this timeline whenever the pet changes, including when the server's
/// silent push wakes it after a send. So one entry and `.never` is the whole timeline.
struct PetWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: PetCompanion.phoneWidgetKind, provider: PetTimelineProvider()) { entry in
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
                    PetCaption(snapshot: snapshot)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
        } else {
            NoPetView(family: family)
        }
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
    PetEntry(date: .now, snapshot: nil, pose: nil)
}
