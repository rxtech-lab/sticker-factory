import Foundation
import Testing
@testable import StickerGeniOS

@Suite("Live Activity updates")
struct GenerationActivityTests {
    private func event(_ id: Int64, _ data: GenerationEventData, type: GenerationEventType = .progress) -> GenerationEvent {
        .init(id: id, jobId: "job", type: type, createdAt: .now, data: data)
    }

    @Test func detailOnlyEventsAdvanceWithoutLosingStatus() throws {
        var state = StickerGenerationAttributes.ContentState(message: "Composing the artwork", phase: "running")
        state = try #require(state.applying(event(1, .init(note: "Drawing the cat expressions"))))
        #expect(state.message == "Drawing the cat expressions")
        state = try #require(state.applying(event(2, .init(completedUnits: 1, totalUnits: 3, progressLabel: "Sprite sheets"))))
        #expect(state.message == "Drawing the cat expressions")
        #expect(state.progressCountText == "1/3")
        #expect(state.applying(event(1, .init(message: "Old status"))) == nil)
        state = try #require(state.applying(event(3, .init(clearProgress: true))))
        #expect(state.unitProgress == nil)
        state = try #require(state.applying(event(4, .init(stage: "validating_candidate"))))
        #expect(state.message == "Checking the result")
        state = try #require(state.applying(event(5, .init(), type: .completed)))
        #expect(state.isFinished)
        #expect(state.message == "Done!")
        #expect(state.applying(event(6, .init(note: "Late note"))) == nil)
    }

    @Test func mascotPoseCoversEveryPhaseAndTerminalStateWinsOverStale() {
        let pose = { (phase: String, stale: Bool) in
            StickerGenerationAttributes.ContentState(message: phase, phase: phase).mascotPose(isStale: stale)
        }
        #expect(pose("queued", false) == .queued)
        #expect(pose("running", false) == .running)
        #expect(pose("waiting", false) == .waiting)
        #expect(pose("unknown-working-phase", false) == .running)
        #expect(pose("running", true) == .stale)
        #expect(pose("completed", true) == .completed)
        #expect(pose("failed", true) == .failed)
        #expect(pose("cancelled", true) == .cancelled)
    }

    @Test @MainActor func pollingChecksImmediatelyAndStopsAtCompletion() async throws {
        var delays: [TimeInterval] = []
        var requests = 0
        let poller = GenerationActivityPoller { delay in delays.append(delay) }
        poller.start(jobID: "job") {
            requests += 1
            return requests < 3
        }
        try await eventually { requests == 3 }
        #expect(delays == [5, 5])
        poller.stop()
    }

    @Test @MainActor func transientErrorsBackOffAndSuccessRestoresCadence() async throws {
        var delays: [TimeInterval] = []
        var requests = 0
        let poller = GenerationActivityPoller { delay in delays.append(delay) }
        poller.start(jobID: "job") {
            requests += 1
            if requests <= 5 { throw URLError(.notConnectedToInternet) }
            return requests < 7
        }
        try await eventually { requests == 7 }
        #expect(delays == [5, 10, 20, 30, 30, 5])
        poller.stop()
    }

    @Test @MainActor func duplicateWatchDoesNotRestartAndResumeFetchesImmediately() async throws {
        var requests = 0
        let poller = GenerationActivityPoller { _ in try await Task.sleep(for: .seconds(60)) }
        poller.start(jobID: "job") { requests += 1; return true }
        try await eventually { requests == 1 }
        poller.start(jobID: "job") { requests += 100; return true }
        await Task.yield()
        #expect(requests == 1)
        poller.stop()
        poller.start(jobID: "job") { requests += 1; return true }
        try await eventually { requests == 2 }
        poller.start(jobID: "new-job") { requests += 1; return false }
        try await eventually { requests == 3 }
        poller.stop()
    }

    @MainActor private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(predicate())
    }
}

@Suite("Assistant working details")
struct AssistantWorkingSummaryTests {
    private func tool(_ id: String, _ name: String, job: String = "job", status: ChatMessageStatus = .complete) -> ChatMessage {
        .init(id: id, role: .system, kind: .status, content: name, imagePlacement: .replace,
              sequence: 1, jobId: job, status: status, createdAt: .now, attachments: [])
    }

    @Test func completedToolsFillTheCardWithoutMeterEvents() {
        let messages = [tool("phase", "build-plan"), tool("old", "view_sticker", job: "old-job"),
                        tool("plan", "view_plan_image"), tool("sticker", "view_sticker")]
        let summary = AssistantWorkingSummary(job: .init(jobID: "job"), messages: messages, titleStatus: "Finishing up")
        #expect(summary.completedSteps == 2)
        #expect(summary.note == "Last finished: Reviewing the sticker")
    }

    @Test func duplicateTitleIsSuppressedEvenWithDifferentPunctuation() {
        var job = StickerJobState(jobID: "job")
        job.statusDetail = "Reviewing the sticker"
        job.note = "Reviewing the sticker…"
        let summary = AssistantWorkingSummary(job: job, messages: [tool("sticker", "view_sticker")], titleStatus: "Reviewing the sticker")
        #expect(summary.note == nil)
        #expect(summary.completedSteps == 1)
    }

    @Test func specificNoteOutranksToolHistory() {
        var job = StickerJobState(jobID: "job")
        job.note = "Drawing the cat expressions"
        let summary = AssistantWorkingSummary(job: job, messages: [tool("plan", "view_plan_image")], titleStatus: "Composing the artwork")
        #expect(summary.note == job.note)
    }
}
