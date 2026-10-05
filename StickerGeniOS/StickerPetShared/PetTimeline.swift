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

    /// This entry moved to `date`, saying the line due then.
    func at(_ date: Date, phase: Int) -> PetEntry {
        var entry = self
        entry.date = date
        entry.phase = phase
        entry.snapshot = snapshot?.speaking(at: date)
        return entry
    }

    static let placeholder = PetEntry(
        date: .now,
        snapshot: PetSnapshot(stickerID: "placeholder", title: "Winky", caption: "Happy to see you!",
                              statusUpdatedAt: .now, selectedAt: .now, poseKey: "placeholder"),
        pose: nil
    )
}

/// Reads the snapshot the phone app wrote, or the one the watch app received — never the network.
///
/// The app that writes the snapshot reloads this timeline whenever it does. Between writes, the pet
/// moves on to each line its agent queued at the time it chose, so the timeline has an entry there too.
nonisolated struct PetTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> PetEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (PetEntry) -> Void) {
        let entry = Self.current()
        // The gallery shows a pet even to someone who has not chosen one yet.
        completion(context.isPreview && entry.snapshot == nil ? .placeholder : entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PetEntry>) -> Void) {
        let current = Self.current()
        let musingDates = current.snapshot?.musingDates.filter { $0 > current.date } ?? []
        guard current.weatherArt != nil else {
            // After the last queued line the pet keeps saying it until the app writes again.
            let entries = [current] + musingDates.map { current.at($0, phase: 0) }
            completion(Timeline(entries: entries, policy: .never))
            return
        }
        // With weather to show, an hour of entries a minute apart: each one nudges the weather the
        // other way, and the system animates between them so the sky drifts behind the pet. A line
        // due within the hour lands on its minute; the next timeline picks up the ones after.
        let entries = (0..<60).map { minute in
            current.at(current.date.addingTimeInterval(Double(minute) * 60), phase: minute)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private static func current() -> PetEntry {
        guard let store = PetSnapshotStore(), let stored = store.load() else { return PetEntry(date: .now, snapshot: nil, pose: nil) }
        return PetEntry(date: .now, snapshot: stored.snapshot.speaking(at: .now), pose: stored.pose, weatherArt: store.weatherArt())
    }
}
