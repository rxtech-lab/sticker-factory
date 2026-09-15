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
        let current = activity.content.state
        guard event.id > current.eventID, !current.isFinished else { return }
        var state = current
        switch event.type {
        case .completed:
            state.phase = event.data.cancelled == true ? "cancelled" : "completed"
            state.message = event.data.cancelled == true ? "Generation stopped" : "Sticker ready"
        case .failed:
            state.phase = "failed"
            state.message = "Generation failed. Open to retry."
        case .queued, .started, .progress, .waiting:
            let message = event.data.message ?? event.data.stage
                ?? (event.data.toolStatus == .streaming ? event.data.toolName.map(StickerToolLabel.text(for:)) : nil)
            if event.type == .progress && message == nil { return }
            state.phase = event.type == .waiting ? "waiting" : event.type == .queued ? "queued" : "running"
            state.message = message.map(Self.readableStatus)
                ?? (event.type == .queued ? "Waiting to start…"
                    : event.type == .waiting ? "Waiting for your input" : "Creating your sticker…")
        default: return // A candidate/document can arrive while the generation is still working.
        }
        state.eventID = event.id
        await update(activity, state: state)
    }

    func signedOut() async {
        selectedJobID = nil
        seenJobIDs.removeAll()
        for task in tokenTasks.values { task.cancel() }
        for task in uploadTasks.values { task.cancel() }
        for task in stateTasks.values { task.cancel() }
        tokenTasks.removeAll(); uploadTasks.removeAll(); stateTasks.removeAll()
        for activity in GenerationActivity.activities { await retire(activity) }
    }

    private func watch(_ activity: GenerationActivity) {
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
            await activity.end(content, dismissalPolicy: .after(.now.addingTimeInterval(120)))
        } else {
            await activity.update(content)
        }
    }

    private func retire(_ activity: GenerationActivity) async {
        tokenTasks.removeValue(forKey: activity.id)?.cancel()
        uploadTasks.removeValue(forKey: activity.id)?.cancel()
        stateTasks.removeValue(forKey: activity.id)?.cancel()
        await activity.end(nil, dismissalPolicy: .immediate)
        try? await api.unregisterLiveActivity(activityID: activity.id)
    }

    private static func readableStatus(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: " ")
        return String((text.prefix(1).uppercased() + text.dropFirst()).prefix(180))
    }
}

nonisolated struct LiveActivitySnapshot: Decodable, Sendable {
    var state: StickerGenerationAttributes.ContentState
    var terminal: Bool
}
