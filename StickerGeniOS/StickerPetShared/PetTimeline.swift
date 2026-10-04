import Foundation
import WidgetKit

/// One moment of the pet, as a widget or complication draws it.
nonisolated struct PetEntry: TimelineEntry {
    var date: Date
    var snapshot: PetSnapshot?
    var pose: Data?

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
        completion(Timeline(entries: [Self.current()], policy: .never))
    }

    private static func current() -> PetEntry {
        guard let stored = PetSnapshotStore()?.load() else { return PetEntry(date: .now, snapshot: nil, pose: nil) }
        return PetEntry(date: .now, snapshot: stored.snapshot, pose: stored.pose)
    }
}
