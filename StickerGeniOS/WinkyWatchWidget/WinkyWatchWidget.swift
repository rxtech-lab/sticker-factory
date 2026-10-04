import SwiftUI
import WidgetKit

@main
struct WinkyWatchWidgetBundle: WidgetBundle {
    var body: some Widget { PetComplication() }
}

/// The pet on the watch face and in the Smart Stack.
///
/// Draws only what the watch app saved from the phone, and is reloaded by it whenever a new pose
/// arrives; see `WatchPetModel`.
struct PetComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: PetCompanion.watchWidgetKind, provider: PetTimelineProvider()) { entry in
            PetComplicationView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Pet")
        .description("Your pet, and how it feels about the stickers you send.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

struct PetComplicationView: View {
    let entry: PetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .accessoryInline:
                Label(snapshot.caption ?? snapshot.title, systemImage: "pawprint.fill")
            case .accessoryCorner:
                PetPoseImage(data: entry.pose)
                    .widgetLabel(snapshot.caption ?? snapshot.title)
            case .accessoryRectangular:
                HStack(spacing: 6) {
                    PetPoseImage(data: entry.pose)
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(snapshot.title).font(.headline).widgetAccentable().lineLimit(1)
                        Text(snapshot.caption ?? String(localized: "Waiting for your next sticker"))
                            .font(.caption2)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            default:
                PetPoseImage(data: entry.pose)
                    .padding(2)
                    .accessibilityLabel(snapshot.title)
            }
        } else {
            switch family {
            case .accessoryInline:
                Label("No pet yet", systemImage: "pawprint")
            case .accessoryRectangular:
                Label("Choose a pet in Winky", systemImage: "pawprint")
                    .font(.caption)
            default:
                Image(systemName: "pawprint")
                    .font(.title3)
                    .accessibilityLabel("No pet yet")
            }
        }
    }
}

#Preview(as: .accessoryRectangular) {
    PetComplication()
} timeline: {
    PetEntry.placeholder
    PetEntry(date: .now, snapshot: nil, pose: nil)
}

#Preview(as: .accessoryCircular) {
    PetComplication()
} timeline: {
    PetEntry.placeholder
    PetEntry(date: .now, snapshot: nil, pose: nil)
}

#Preview(as: .accessoryCorner) {
    PetComplication()
} timeline: {
    PetEntry.placeholder
    PetEntry(date: .now, snapshot: nil, pose: nil)
}

#Preview(as: .accessoryInline) {
    PetComplication()
} timeline: {
    PetEntry.placeholder
    PetEntry(date: .now, snapshot: nil, pose: nil)
}
