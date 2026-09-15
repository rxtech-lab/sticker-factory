// ActivityKit handles its own synchronization but its Activity reference lacks Sendable annotations.
// All app-side access is confined to this MainActor manager.
@preconcurrency import ActivityKit
import Foundation
import OSLog
import UIKit

@MainActor
final class GenerationLiveActivityManager {
    private typealias GenerationActivity = Activity<StickerGenerationAttributes>
    private let api: StickerAPIClient
    private var tokenTasks: [String: Task<Void, Never>] = [:]
    private var uploadTasks: [String: Task<Void, Never>] = [:]
    private var stateTasks: [String: Task<Void, Never>] = [:]
    private let poller = GenerationActivityPoller()
    private var selectedJobID: String?
    private var seenJobIDs: Set<String> = []
    private static let log = Logger(subsystem: "app.rxlab.stickerfactory", category: "live-activity")

    init(api: StickerAPIClient) { self.api = api }

    /// A new generation replaces the previous one. Stream reconnection never steals selection.
    func start(jobID: String, stickerID: String, title: String, startsGeneration: Bool) {
        guard UIApplication.shared.applicationState == .active,
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if let existing = GenerationActivity.activities.first(where: { $0.attributes.jobID == jobID }) {
            if selectedJobID == nil { selectedJobID = jobID }
            watch(existing)
            return
        }
        guard startsGeneration || selectedJobID == nil else { return }
        guard seenJobIDs.insert(jobID).inserted else { return }
        let previousSelection = selectedJobID
        selectedJobID = jobID
        let previous = GenerationActivity.activities
        do {
            let activity = try GenerationActivity.request(
                attributes: .init(jobID: jobID, stickerID: stickerID, title: String(title.prefix(80)), startedAt: .now),
                content: .init(state: .init(message: "Waiting to start…", phase: "queued"), staleDate: .now.addingTimeInterval(180)),
                pushType: .token
            )
            watch(activity)
            Task {
                for old in previous { await retire(old) }
            }
        } catch {
            seenJobIDs.remove(jobID)
            selectedJobID = previousSelection
            Self.log.error("Could not start Live Activity: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Called after sign-in and when returning to the foreground; retries missed token uploads.
    func resume() {
        let activities = GenerationActivity.activities.sorted { $0.attributes.startedAt > $1.attributes.startedAt }
        poller.stop()
        guard let latest = activities.first else { return }
        selectedJobID = latest.attributes.jobID
        seenJobIDs.formUnion(activities.map { $0.attributes.jobID })
        watch(latest)
        if let token = latest.pushToken { upload(token, for: latest) }
        Task {
            for old in activities.dropFirst() { await retire(old) }
        }
    }

    func apply(_ event: GenerationEvent) async {
        guard let activity = GenerationActivity.activities.first(where: { $0.attributes.jobID == event.jobId }),
              event.jobId == selectedJobID else { return }
        guard let state = activity.content.state.applying(event) else { return }
        await update(activity, state: state)
    }

    func pause() {
        poller.stop()
    }

    func signedOut() async {
        poller.stop()
        selectedJobID = nil
        seenJobIDs.removeAll()
        for task in tokenTasks.values { task.cancel() }
        for task in uploadTasks.values { task.cancel() }
        for task in stateTasks.values { task.cancel() }
        tokenTasks.removeAll(); uploadTasks.removeAll(); stateTasks.removeAll()
        for activity in GenerationActivity.activities { await retire(activity) }
    }

    private func watch(_ activity: GenerationActivity) {
        if selectedJobID == activity.attributes.jobID,
           UIApplication.shared.applicationState == .active,
           !activity.content.state.isFinished {
            poller.start(jobID: activity.attributes.jobID) { [weak self] in
                guard let self, selectedJobID == activity.attributes.jobID,
                      activity.activityState == .active || activity.activityState == .stale,
                      !activity.content.state.isFinished else { return false }
                let snapshot = try await api.liveActivitySnapshot(jobID: activity.attributes.jobID)
                try Task.checkCancellation()
                await update(activity, state: snapshot.state)
                return !snapshot.state.isFinished
            }
        }
        guard tokenTasks[activity.id] == nil else { return }
        tokenTasks[activity.id] = Task { [weak self] in
            for await token in activity.pushTokenUpdates {
                guard !Task.isCancelled else { return }
                self?.upload(token, for: activity)
            }
        }
        stateTasks[activity.id] = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled else { return }
                if state == .ended || state == .dismissed {
                    if self?.selectedJobID == activity.attributes.jobID { self?.poller.stop() }
                    self?.tokenTasks.removeValue(forKey: activity.id)?.cancel()
                    self?.uploadTasks.removeValue(forKey: activity.id)?.cancel()
                    self?.stateTasks.removeValue(forKey: activity.id)
                    try? await self?.api.unregisterLiveActivity(activityID: activity.id)
                    return
                }
            }
        }
        if let token = activity.pushToken { upload(token, for: activity) }
    }

    private func upload(_ token: Data, for activity: GenerationActivity) {
        uploadTasks[activity.id]?.cancel()
        uploadTasks[activity.id] = Task { [weak self] in
            guard let self else { return }
            let hex = token.map { String(format: "%02x", $0) }.joined()
            for delay in [0, 2, 5, 15] {
                do {
                    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                    try Task.checkCancellation()
                    guard selectedJobID == activity.attributes.jobID else { return }
                    let snapshot = try await api.registerLiveActivity(activityID: activity.id, jobID: activity.attributes.jobID, token: hex)
                    try Task.checkCancellation()
                    await update(activity, state: snapshot.state)
                    return
                } catch {
                    if Task.isCancelled { return }
                }
            }
            Self.log.error("Live Activity token upload failed; retrying on next foreground")
        }
    }

    private func update(_ activity: GenerationActivity, state: StickerGenerationAttributes.ContentState) async {
        guard selectedJobID == activity.attributes.jobID,
              state.eventID >= activity.content.state.eventID,
              !activity.content.state.isFinished else { return }
        let content = ActivityContent(state: state, staleDate: state.isFinished ? nil : .now.addingTimeInterval(180))
        if state.isFinished {
            poller.stop()
            await activity.end(content, dismissalPolicy: .after(.now.addingTimeInterval(120)))
        } else {
            await activity.update(content)
        }
    }

    private func retire(_ activity: GenerationActivity) async {
        if selectedJobID == activity.attributes.jobID { poller.stop() }
        tokenTasks.removeValue(forKey: activity.id)?.cancel()
        uploadTasks.removeValue(forKey: activity.id)?.cancel()
        stateTasks.removeValue(forKey: activity.id)?.cancel()
        await activity.end(nil, dismissalPolicy: .immediate)
        try? await api.unregisterLiveActivity(activityID: activity.id)
    }

}

nonisolated struct LiveActivitySnapshot: Decodable, Sendable {
    var state: StickerGenerationAttributes.ContentState
    var terminal: Bool
}

/// The same event policy for every foreground update, including detail-only progress.
nonisolated extension StickerGenerationAttributes.ContentState {
    func applying(_ event: GenerationEvent) -> Self? {
        guard event.id > eventID, !isFinished else { return nil }
        var state = self
        switch event.type {
        case .completed:
            state.phase = event.data.cancelled == true ? "cancelled" : "completed"
            state.message = event.data.cancelled == true ? "Generation stopped" : "Sticker ready"
        case .failed:
            state.phase = "failed"
            state.message = "Generation failed. Open to retry."
        case .queued, .started, .progress, .waiting:
            let message = event.data.note ?? event.data.message
                ?? event.data.stage.map(StickerToolLabel.text(forStage:))
                ?? (event.data.toolStatus == .streaming ? event.data.toolName.map(StickerToolLabel.text(for:)) : nil)
            guard event.type != .progress || message != nil || event.data.completedUnits != nil
                    || event.data.clearProgress == true else { return nil }
            state.phase = event.type == .waiting ? "waiting" : event.type == .queued ? "queued" : "running"
            if let message {
                let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
                state.message = String((text.prefix(1).uppercased() + text.dropFirst()).prefix(180))
            } else if event.type != .progress {
                state.message = event.type == .queued ? "Waiting to start…"
                    : event.type == .waiting ? "Waiting for your input" : "Creating your sticker…"
            }
        default: return nil
        }
        if state.isFinished || event.data.clearProgress == true {
            state.progressLabel = nil
            state.completedUnits = nil
            state.totalUnits = nil
        } else if let completed = event.data.completedUnits, let total = event.data.totalUnits,
                  total > 0, completed >= 0, completed <= total {
            state.completedUnits = completed
            state.totalUnits = total
            state.progressLabel = event.data.progressLabel ?? "Artwork parts"
        }
        state.eventID = event.id
        return state
    }
}
