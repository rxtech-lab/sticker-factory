import AnimatedView
import Foundation
import Testing
@testable import StickerGeniOS

/// The export timeline is the only thing on screen during the longest operation the app performs,
/// and every number it shows is one it computed itself — a step whose clock never stops, or a row
/// that stays pending after the work went past it, reads as a hang rather than as a display bug.
@MainActor
@Suite("Export progress timeline")
struct StickerExportProgressTests {
    private func revision(kind: AnimatedKind, animated: Bool) -> StickerRevision {
        let animation = animated
            ? AnimatedLayerAnimation(position: [
                .init(timeSeconds: 0, x: 0, y: 0.5, easing: .linear),
                .init(timeSeconds: 1, x: 1, y: 0.5, easing: .linear),
            ])
            : AnimatedLayerAnimation()
        let layer = AnimatedLayer.shape(.init(
            base: .init(id: "shape", name: "Shape", animation: animation),
            shape: .circle,
            fill: .solid("#FFFFFF")
        ))
        return StickerRevision(
            id: "rev",
            candidateState: .accepted,
            document: AnimatedDocument(kind: kind, durationSeconds: 1, fps: 30, loop: .loop, layers: [layer]),
            createdAt: .init(timeIntervalSince1970: 0)
        )
    }

    @Test("Durations roll up into minutes and hours")
    func durationText() {
        #expect(StickerExportDuration.text(0.4) == "0.4s")
        #expect(StickerExportDuration.text(9.94) == "9.9s")
        #expect(StickerExportDuration.text(42.4) == "42s")
        #expect(StickerExportDuration.text(60) == "1m")
        #expect(StickerExportDuration.text(65) == "1m 5s")
        #expect(StickerExportDuration.text(3600) == "1h")
        #expect(StickerExportDuration.text(3960) == "1h 6m")
        // A clock that reads backwards is worse than one that reads zero.
        #expect(StickerExportDuration.text(-3) == "0.0s")
    }

    @Test("The plan covers the renditions the publisher will actually render")
    func plannedStages() {
        let animated = revision(kind: .animated, animated: true)
        #expect(StickerExportProgress.stages(for: animated, selection: .both) == [
            .prepare, .renderVideo, .renderAPNG, .renderSticker, .upload, .publish,
        ])
        // Choosing Sticker skips the MP4 encode outright, so no row is drawn for it.
        #expect(StickerExportProgress.stages(for: animated, selection: .sticker) == [
            .prepare, .renderAPNG, .renderSticker, .upload, .publish,
        ])
        #expect(StickerExportProgress.stages(for: revision(kind: .static, animated: false), selection: .both) == [
            .prepare, .renderImage, .renderSticker, .upload, .publish,
        ])
        // An animated document with no motion cannot be published; it exports one still locally.
        #expect(StickerExportProgress.stages(for: revision(kind: .animated, animated: false), selection: .both) == [
            .prepare, .renderImage,
        ])
    }

    @Test("Each step is timed from the moment the next one starts")
    func stepsCarryTheirDuration() {
        let start = Date(timeIntervalSince1970: 1_000)
        let progress = StickerExportProgress(stages: [.prepare, .renderAPNG, .upload], isPublish: false, now: start)

        progress.begin(.prepare, at: start)
        progress.begin(.renderAPNG, at: start.addingTimeInterval(2))
        progress.report("Encoding at 768 px", for: .renderAPNG)

        #expect(progress.steps[0].state == .done)
        #expect(progress.steps[0].duration == 2)
        #expect(progress.steps[1].state == .running)
        #expect(progress.steps[1].detail == "Encoding at 768 px")
        // A running step's clock comes from the frame being drawn, not from a stored value.
        #expect(progress.elapsed(progress.steps[1], now: start.addingTimeInterval(5)) == 3)
        // A step that has not started shows no time at all rather than a zero.
        #expect(progress.elapsed(progress.steps[2], now: start.addingTimeInterval(5)) == nil)

        progress.succeed(at: start.addingTimeInterval(9))
        #expect(progress.steps[1].duration == 7)
        // The upload never ran — nothing was published — so it is dropped rather than left pending.
        #expect(progress.steps.count == 2)
        #expect(progress.outcome == .succeeded)
        #expect(progress.totalElapsed(now: start.addingTimeInterval(400)) == 9)
        // A detail line belongs to the work in flight; a finished step keeps only its time.
        #expect(progress.steps[1].detail == nil)
    }

    @Test("A stage the publisher skips does not stay on the timeline")
    func skippedStagesAreDropped() {
        let progress = StickerExportProgress(
            stages: [.prepare, .renderVideo, .renderAPNG, .renderSticker],
            isPublish: true
        )
        progress.begin(.prepare)
        progress.begin(.renderAPNG)

        #expect(progress.steps.map(\.stage) == [.prepare, .renderAPNG, .renderSticker])
        #expect(progress.currentStep?.stage == .renderAPNG)
    }

    @Test("A failure marks the step it happened in and stops the timeline")
    func failureStopsOnTheRunningStep() {
        let start = Date(timeIntervalSince1970: 1_000)
        let progress = StickerExportProgress(stages: [.prepare, .renderAPNG, .upload], isPublish: true, now: start)
        progress.begin(.prepare, at: start)
        progress.begin(.renderAPNG, at: start.addingTimeInterval(1))
        progress.fail("Out of disk", at: start.addingTimeInterval(4))

        #expect(progress.steps.map(\.state) == [.done, .failed])
        #expect(progress.steps[1].duration == 3)
        #expect(progress.failureMessage == "Out of disk")
        #expect(!progress.isRunning)
        // Nothing after the failure may reopen the timeline: the run is over either way.
        progress.begin(.upload, at: start.addingTimeInterval(5))
        #expect(progress.steps.count == 2)
    }

    @Test("Cancelling stops the timeline without calling it a failure")
    func cancelStopsTheTimeline() {
        let start = Date(timeIntervalSince1970: 1_000)
        let progress = StickerExportProgress(stages: [.prepare, .renderVideo, .upload], isPublish: true, now: start)
        progress.begin(.prepare, at: start)
        progress.begin(.renderVideo, at: start.addingTimeInterval(1))
        #expect(progress.isCancellable)

        progress.cancel(at: start.addingTimeInterval(6))

        #expect(progress.outcome == .cancelled)
        #expect(progress.steps.map(\.state) == [.done, .cancelled])
        // The step still reports what it cost before it was stopped.
        #expect(progress.steps[1].duration == 5)
        // Nothing went wrong, so there is nothing for a banner to say.
        #expect(progress.failureMessage == nil)
        #expect(!progress.isCancellable)
        #expect(!progress.isRunning)
    }

    @Test("Cancel is withdrawn once the export reaches the server")
    func cancelIsWithdrawnOnTheServerStep() {
        let progress = StickerExportProgress(stages: [.prepare, .upload, .publish], isPublish: true)
        progress.begin(.prepare)
        progress.begin(.upload)
        #expect(progress.isCancellable)

        // `.publish` starts with the register call: past it the server may already hold the export,
        // and a button offering to undo that would be claiming more than this app can do.
        progress.begin(.publish)
        #expect(!progress.isCancellable)
        #expect(progress.isWaitingOnServer)
    }

    @Test("The server half of a publish lands in the same timeline")
    func publishJobDrivesTheLastStep() {
        let progress = StickerExportProgress(stages: [.prepare, .upload, .publish], isPublish: true)
        progress.begin(.prepare)
        progress.begin(.upload)
        progress.begin(.publish)

        progress.apply(publishJob: .init(jobID: "job", message: "Packing sticker set"))
        #expect(progress.isWaitingOnServer)
        #expect(progress.currentStep?.detail == "Packing sticker set")

        progress.apply(publishJob: .init(jobID: "job", message: "Done", isTerminal: true))
        #expect(progress.outcome == .succeeded)
        #expect(!progress.isWaitingOnServer)
    }

    @Test("A failed publish job is a failed export, in the job's own words")
    func failedPublishJobFailsTheTimeline() {
        let progress = StickerExportProgress(stages: [.prepare, .publish], isPublish: true)
        progress.begin(.prepare)
        progress.begin(.publish)
        progress.apply(publishJob: .init(
            jobID: "job",
            message: "Publishing",
            isTerminal: true,
            isFailed: true,
            failureMessage: "Sticker set rejected"
        ))

        #expect(progress.outcome == .failed)
        #expect(progress.failureMessage == "Sticker set rejected")
        #expect(progress.steps.last?.state == .failed)
    }

    /// The revision a publish produces, as the server builds it: a *new* row whose parent is the
    /// revision that was exported, carrying the assets that were uploaded, and active from the
    /// moment the job succeeds.
    private func published(from parent: StickerRevision) -> StickerRevision {
        var published = parent
        published.id = "rev-published"
        published.parentRevisionId = parent.id
        published.apngAssetId = "apng"
        published.systemAssetId = "system"
        return published
    }

    @Test("The revision a publish produces settles the timeline it came from")
    func publishedRevisionSettlesTheTimeline() {
        let source = revision(kind: .animated, animated: true)
        let model = StickerExportModel()
        model.seed(from: source)

        let progress = model.beginProgress(for: source)
        progress.begin(.upload)
        progress.begin(.publish)
        model.publishJobID = "job"
        model.publishedURLs = [URL(fileURLWithPath: "/tmp/sticker.png")]

        // Publishing rotates the active revision, so the sheet is re-seeded by its own success.
        model.seed(from: published(from: source))

        #expect(progress.outcome == .succeeded)
        // The files were rendered for exactly this publish; the new revision is its result, not a
        // version the user edited away from.
        #expect(model.publishJobID == "job")
        #expect(model.publishedURLs.count == 1)
    }

    @Test("An unrelated revision still invalidates what was rendered for the old one")
    func unrelatedRevisionInvalidatesExports() {
        let source = revision(kind: .animated, animated: true)
        let model = StickerExportModel()
        model.seed(from: source)
        model.publishJobID = "job"
        model.publishedURLs = [URL(fileURLWithPath: "/tmp/sticker.png")]

        var edited = revision(kind: .animated, animated: true)
        edited.id = "rev-edited"

        model.seed(from: edited)

        #expect(model.publishJobID == nil)
        #expect(model.publishedURLs.isEmpty)
    }

    @Test("A revision with no published exports leaves the timeline running")
    func unpublishedRevisionDoesNotSettle() {
        let source = revision(kind: .animated, animated: true)
        let model = StickerExportModel()
        model.seed(from: source)

        let progress = model.beginProgress(for: source)
        progress.begin(.publish)

        // A child revision that carries no exports is an edit, not a publish result.
        var child = source
        child.id = "rev-child"
        child.parentRevisionId = source.id
        model.seed(from: child)

        #expect(progress.outcome == .running)
    }
}
