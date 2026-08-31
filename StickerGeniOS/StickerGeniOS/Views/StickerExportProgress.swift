import AnimatedView
import Foundation
import Observation

/// One line of the export timeline.
///
/// The stages are the work a publish actually does, in the order `StickerPublisher` does it, rather
/// than a percentage: an export spends most of its time in two or three encodes whose cost varies by
/// an order of magnitude with the document, so "which of these is running, and for how long" is the
/// only honest thing to show.
nonisolated enum StickerExportStage: String, Identifiable, Hashable, Sendable {
    case prepare
    case renderImage
    case renderVideo
    case renderAPNG
    /// Only when the share sheet was asked for a GIF — see `StickerSharingFormat`. A second full
    /// encode of the same cycle, so it is never folded into the row above it.
    case renderGIF
    case renderSticker
    case upload
    case publish

    var id: String { rawValue }

    var title: String {
        switch self {
        case .prepare: String(localized: "Checking artwork")
        case .renderImage: String(localized: "Rendering image")
        case .renderVideo: String(localized: "Encoding video")
        case .renderAPNG: String(localized: "Encoding animation")
        case .renderGIF: String(localized: "Encoding GIF")
        case .renderSticker: String(localized: "Fitting Messages sticker")
        case .upload: String(localized: "Uploading files")
        case .publish: String(localized: "Publishing to your library")
        }
    }

    var symbol: String {
        switch self {
        case .prepare: "checkmark.seal"
        case .renderImage: "photo"
        case .renderVideo: "film"
        case .renderAPNG: "photo.stack"
        case .renderGIF: "photo.stack.fill"
        case .renderSticker: "message"
        case .upload: "icloud.and.arrow.up"
        case .publish: "shippingbox"
        }
    }
}

/// A step's elapsed time, rolled up so a long publish does not read as a four-digit second count.
nonisolated enum StickerExportDuration {
    static func text(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        if total < 60 {
            // A tenth of a second below ten: most steps finish there, and "0s" next to a step that
            // visibly took a moment reads as a timer that never started.
            return total < 10 ? String(format: "%.1fs", total) : "\(Int(total.rounded()))s"
        }
        let whole = Int(total)
        if total < 3600 {
            let minutes = whole / 60
            let seconds = whole % 60
            return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
        }
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }
}

/// The live timeline of one export or publish.
///
/// Owned by `StickerExportModel` rather than by the sheet that draws it, so dismissing the sheet
/// mid-publish does not take the record of the run with it — and so a publish that is still running
/// on the server can keep reporting into the same timeline it started in.
@MainActor
@Observable
final class StickerExportProgress {
    enum StepState: Sendable { case pending, running, done, failed, cancelled }

    struct Step: Identifiable, Sendable {
        var stage: StickerExportStage
        var state: StepState = .pending
        /// What the stage is doing right now — the ladder rung being tried, the frame being
        /// encoded. Cleared when the stage starts, so a finished step never shows a stale rung.
        var detail: String?
        var startedAt: Date?
        var duration: TimeInterval?

        var id: String { stage.id }
        var title: String { stage.title }
    }

    enum Outcome: Sendable { case running, succeeded, failed, cancelled }

    private(set) var steps: [Step]
    private(set) var outcome: Outcome = .running
    private(set) var failureMessage: String?
    /// What the ladder gave up to fit Apple's ceiling, when it gave up anything. Not a failure —
    /// see `SystemStickerCompromise` — so it is shown alongside a finished timeline, not instead of
    /// one.
    var note: String?
    let startedAt: Date
    private(set) var finishedAt: Date?
    /// Whether this run ends on the server. A local export is over when the last encode returns; a
    /// publish is not, and the two states need different words for the same green checkmark.
    let isPublish: Bool

    var isRunning: Bool { outcome == .running }

    /// Everything on this device is finished and the server is still working. The one point where
    /// leaving the sheet costs nothing: the job outlives it, and the export sheet underneath tracks
    /// the same job.
    var isWaitingOnServer: Bool {
        isRunning && steps.contains { $0.stage == .publish && $0.state == .running }
    }

    /// Whether stopping the run is still an offer this app can keep.
    ///
    /// Only the local half is cancellable. `.publish` begins with the register call, and once that
    /// is in flight the server may already have accepted the export — a button that claims to undo
    /// it would be lying about which side of that line the run is on.
    var isCancellable: Bool { isRunning && !isWaitingOnServer }

    var currentStep: Step? { steps.first { $0.state == .running } }

    init(stages: [StickerExportStage], isPublish: Bool, now: Date = .now) {
        self.steps = stages.map { Step(stage: $0) }
        self.isPublish = isPublish
        self.startedAt = now
    }

    /// The timeline as it is drawn before anything has run.
    ///
    /// Mirrors the branching in `StickerPublisher.renderExports`: a rendition this selection does
    /// not ask for is never rendered, and a row for it would sit pending forever. Getting this
    /// wrong is not fatal — `begin` drops a planned stage the publisher skipped, and inserts one it
    /// did not plan for — but a plan that matches means the reader sees the whole shape of the work
    /// up front instead of watching rows appear.
    /// - Parameter sharing: a GIF share costs a second encode of the same cycle on top of the APNG
    ///   every publish uploads, so it earns a row of its own rather than hiding inside one.
    static func stages(
        for revision: StickerRevision,
        selection: StickerExportSelection,
        sharing: StickerSharingFormat = .default
    ) -> [StickerExportStage] {
        // Nothing to publish means the local still-image path, which is one render and no upload.
        guard revision.canPublishExports else { return [.prepare, .renderImage] }
        var stages: [StickerExportStage] = [.prepare]
        if revision.document.kind == .static {
            stages.append(.renderImage)
        } else {
            // A publish always renders the sticker set — the library and the Messages extension are
            // entitled to it — so only the video is optional here.
            if selection.includesVideo { stages.append(.renderVideo) }
            stages.append(.renderAPNG)
            if sharing == .gif { stages.append(.renderGIF) }
        }
        stages.append(contentsOf: [.renderSticker, .upload, .publish])
        return stages
    }

    static func planned(
        for revision: StickerRevision,
        selection: StickerExportSelection,
        sharing: StickerSharingFormat = .default
    ) -> StickerExportProgress {
        .init(
            stages: stages(for: revision, selection: selection, sharing: sharing),
            isPublish: revision.canPublishExports
        )
    }

    /// Starts `stage`, closing whatever was running before it.
    func begin(_ stage: StickerExportStage, detail: String? = nil, at now: Date = .now) {
        guard isRunning else { return }
        completeRunningStep(at: now)
        if let planned = steps.firstIndex(where: { $0.stage == stage }) {
            // Stages still pending in front of the one that actually started were planned for work
            // this export turned out not to need. A row that never runs and never times reads as a
            // step that is stuck, so it is dropped rather than left behind.
            let skipped = Set(steps[..<planned].filter { $0.state == .pending }.map(\.stage))
            steps.removeAll { skipped.contains($0.stage) }
        } else {
            steps.insert(Step(stage: stage), at: steps.firstIndex { $0.state == .pending } ?? steps.count)
        }
        guard let index = steps.firstIndex(where: { $0.stage == stage }) else { return }
        steps[index].state = .running
        steps[index].startedAt = now
        steps[index].detail = detail
    }

    /// Replaces the running step's detail line — the rung, the frame, the file being sent.
    func report(_ detail: String, for stage: StickerExportStage) {
        guard let index = steps.firstIndex(where: { $0.stage == stage && $0.state == .running }) else { return }
        steps[index].detail = detail
    }

    func succeed(at now: Date = .now) {
        guard isRunning else { return }
        completeRunningStep(at: now)
        steps.removeAll { $0.state == .pending }
        outcome = .succeeded
        finishedAt = now
    }

    /// Stopped by the person who started it. Deliberately not a failure: nothing went wrong, no
    /// file was written, and colouring the step red would say otherwise.
    func cancel(at now: Date = .now) {
        guard isRunning else { return }
        if let index = steps.firstIndex(where: { $0.state == .running }) {
            steps[index].state = .cancelled
            steps[index].duration = elapsed(of: steps[index], at: now)
            steps[index].detail = nil
        }
        steps.removeAll { $0.state == .pending }
        outcome = .cancelled
        finishedAt = now
    }

    func fail(_ message: String?, at now: Date = .now) {
        guard isRunning else { return }
        if let index = steps.firstIndex(where: { $0.state == .running }) {
            steps[index].state = .failed
            steps[index].duration = elapsed(of: steps[index], at: now)
        }
        steps.removeAll { $0.state == .pending }
        failureMessage = message
        outcome = .failed
        finishedAt = now
    }

    /// The server half of a publish, folded into the same timeline as the local half.
    ///
    /// The publish call returns as soon as the export is registered, so nothing throws when the job
    /// behind it fails; the job state is the only thing that says how it ended.
    func apply(publishJob job: StickerJobState, at now: Date = .now) {
        guard isRunning else { return }
        if job.isFailed {
            fail(
                job.failureMessage
                    ?? String(localized: "Publishing failed. This sticker is still a draft — try publishing it again."),
                at: now
            )
        } else if job.isTerminal {
            succeed(at: now)
        } else {
            if !steps.contains(where: { $0.stage == .publish && $0.state == .running }) {
                begin(.publish, at: now)
            }
            report(job.message, for: .publish)
        }
    }

    /// How long a step has been running, or how long it took. `nil` for one that has not started —
    /// a pending row shows no time rather than a zero.
    func elapsed(_ step: Step, now: Date) -> TimeInterval? {
        if let duration = step.duration { return duration }
        guard step.state == .running else { return nil }
        return elapsed(of: step, at: now)
    }

    func totalElapsed(now: Date) -> TimeInterval {
        max(0, (finishedAt ?? now).timeIntervalSince(startedAt))
    }

    private func elapsed(of step: Step, at now: Date) -> TimeInterval {
        guard let startedAt = step.startedAt else { return 0 }
        return max(0, now.timeIntervalSince(startedAt))
    }

    private func completeRunningStep(at now: Date) {
        guard let index = steps.firstIndex(where: { $0.state == .running }) else { return }
        steps[index].state = .done
        steps[index].duration = elapsed(of: steps[index], at: now)
        steps[index].detail = nil
    }
}
