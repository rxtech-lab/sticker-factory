import Foundation
import WidgetKit

/// One moment of the pet, as a widget or complication draws it.
nonisolated struct PetEntry: TimelineEntry {
    var date: Date
    var snapshot: PetSnapshot?
    var pose: Data?
    /// The drawing of the pet's weather, when the phone has one.
    var weatherArt: Data? = nil
    /// Alternates entry by entry, so the weather drifts a little each time the widget moves on.
    var phase = 0

    static let placeholder = PetEntry(
        date: .now,
        snapshot: PetSnapshot(stickerID: "placeholder", title: "Winky", caption: "Happy to see you!",
                              statusUpdatedAt: .now, selectedAt: .now, poseKey: "placeholder"),
        pose: nil
    )
}

/// Reads the snapshot the phone app wrote, or the one the watch app received — never the network.
///
/// The app that writes the snapshot reloads this timeline whenever it does, so one entry and
/// `.never` is the whole schedule.
nonisolated struct PetTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> PetEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (PetEntry) -> Void) {
        let entry = Self.current()
        // The gallery shows a pet even to someone who has not chosen one yet.
        completion(context.isPreview && entry.snapshot == nil ? .placeholder : entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PetEntry>) -> Void) {
        let current = Self.current()
        guard current.weatherArt != nil else {
            completion(Timeline(entries: [current], policy: .never))
            return
        }
        // With weather to show, an hour of entries a minute apart: each one nudges the weather the
        // other way, and the system animates between them so the sky drifts behind the pet.
        let entries = (0..<60).map { minute in
            var entry = current
            entry.date = current.date.addingTimeInterval(Double(minute) * 60)
            entry.phase = minute
            return entry
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private static func current() -> PetEntry {
        guard let store = PetSnapshotStore(), let stored = store.load() else { return PetEntry(date: .now, snapshot: nil, pose: nil) }
        return PetEntry(date: .now, snapshot: stored.snapshot, pose: stored.pose, weatherArt: store.weatherArt())
    }
}
