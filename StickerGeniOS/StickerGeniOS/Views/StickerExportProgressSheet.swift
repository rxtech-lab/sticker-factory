import SwiftUI

/// The live timeline of an export, over the sheet that started it.
///
/// A publish is the longest thing this app does on device — two or three encodes, four uploads, and
/// a server job — and it used to be a spinner next to one word. This shows which step is running,
/// which are done and what each one cost, so a thirty-second encode of a dense animation reads as
/// work rather than as a hang.
///
/// Nothing here can be swiped away: a sheet that slides off while the export continues invites a
/// second tap on a button that is still busy. Every way out is stated — "Cancel Export" while the
/// work is still local and undoable, "Continue in Background" once the only thing left is a server
/// job that outlives this screen either way, and "Done" once it has landed.
struct StickerExportProgressSheet: View {
    let progress: StickerExportProgress
    let onCancel: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            StickerBackground {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Only a running timeline needs a clock. Once it stops, every step
                        // carries its own recorded duration and there is nothing left to tick.
                        if progress.isRunning {
                            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                                content(now: context.date)
                            }
                        } else {
                            content(now: progress.finishedAt ?? .now)
                        }

                        if let note = progress.note, !progress.isRunning {
                            NoticeBanner(message: note)
                        }
                        if let failure = progress.failureMessage {
                            ErrorBanner(message: failure)
                        }

                        if progress.isCancellable {
                            Divider()
                            // On the sheet rather than in the toolbar: "Cancel" beside a title bar
                            // reads as a way out of the screen, and this stops the export.
                            Button(role: .cancel, action: onCancel) {
                                Text("Cancel Export")
                                    .fontWeight(.semibold)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.posterSecondary)
                            .controlSize(.large)
                            .tint(.red)
                            .accessibilityIdentifier("cancel-export")

                            Text("Nothing has been published yet. Stopping now leaves this sticker exactly as it is.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(progress.isPublish ? Text("Publishing") : Text("Exporting"))
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("sticker-export-progress-sheet")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if !progress.isRunning {
                        Button("Done", action: onDismiss)
                            .accessibilityIdentifier("export-progress-done")
                    } else if progress.isWaitingOnServer {
                        Button("Continue in Background", action: onDismiss)
                            .accessibilityIdentifier("export-progress-background")
                    }
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            header(now: now)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(progress.steps.enumerated()), id: \.element.id) { index, step in
                    row(step, now: now, isLast: index == progress.steps.count - 1)
                }
            }
        }
    }

    private func header(now: Date) -> some View {
        HStack(alignment: .top, spacing: 12) {
            statusMark

            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(.title3.bold())
                Text(subheadline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(StickerExportDuration.text(progress.totalElapsed(now: now)))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("Total time"))
        }
        .accessibilityIdentifier("export-progress-header")
    }

    @ViewBuilder
    private var statusMark: some View {
        switch progress.outcome {
        case .running:
            ProgressView()
                .controlSize(.small)
                .frame(width: 32, height: 32)
                .background(AppColors.accentSoft.opacity(0.5), in: Circle())
        case .succeeded:
            mark("checkmark", tint: .green)
        case .failed:
            mark("exclamationmark", tint: .red)
        case .cancelled:
            mark("xmark", tint: .secondary)
        }
    }

    private func mark(_ symbol: String, tint: Color) -> some View {
        PosterSymbol(symbol)
            .font(.subheadline.bold())
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(tint, in: Circle())
    }

    private var headline: String {
        switch progress.outcome {
        case .running:
            progress.isPublish
                ? String(localized: "Publishing your sticker")
                : String(localized: "Exporting your sticker")
        case .succeeded:
            progress.isPublish ? String(localized: "Published") : String(localized: "Export complete")
        case .failed:
            progress.isPublish ? String(localized: "Publish failed") : String(localized: "Export failed")
        case .cancelled:
            progress.isPublish ? String(localized: "Publish cancelled") : String(localized: "Export cancelled")
        }
    }

    private var subheadline: String {
        switch progress.outcome {
        case .running:
            // The step currently on the clock, said once at the top so the reader does not have to
            // find the spinner in the list.
            progress.currentStep?.title ?? String(localized: "Getting ready…")
        case .succeeded:
            progress.isPublish
                ? String(localized: "Saved to your Library")
                : String(localized: "Your files are ready to share")
        case .failed:
            progress.isPublish
                ? String(localized: "This sticker is still a draft")
                : String(localized: "Nothing was written")
        case .cancelled:
            progress.isPublish
                ? String(localized: "Stopped before anything was published")
                : String(localized: "Stopped before anything was written")
        }
    }

    private func row(_ step: StickerExportProgress.Step, now: Date, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                marker(for: step)
                if !isLast {
                    // Drawn only between rows, and stretched to whatever the row beside it needs, so
                    // a step with a detail line does not break the thread.
                    Capsule()
                        .fill(step.state == .done ? AppColors.accent.opacity(0.3) : Color.primary.opacity(0.12))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, 3)
                }
            }
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(step.title)
                        .font(.subheadline.weight(step.state == .running ? .semibold : .regular))
                        .foregroundStyle(step.state == .pending ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    Spacer(minLength: 0)
                    if let elapsed = progress.elapsed(step, now: now) {
                        Text(StickerExportDuration.text(elapsed))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if let detail = step.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, isLast ? 0 : 14)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("export-step-\(step.id)")
    }

    @ViewBuilder
    private func marker(for step: StickerExportProgress.Step) -> some View {
        ZStack {
            Circle()
                .fill(markerFill(for: step))
                .frame(width: 22, height: 22)
            switch step.state {
            case .pending:
                PosterSymbol(step.stage.symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            case .running:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .tint(AppColors.accent)
            case .done:
                PosterSymbol("checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            case .failed, .cancelled:
                PosterSymbol("xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }

    private func markerFill(for step: StickerExportProgress.Step) -> AnyShapeStyle {
        switch step.state {
        case .pending: AnyShapeStyle(Color.primary.opacity(0.07))
        case .running: AnyShapeStyle(AppColors.accentSoft.opacity(0.55))
        case .done: AnyShapeStyle(AppColors.accent)
        case .failed: AnyShapeStyle(Color.red)
        // Grey, not red: the run stopped because it was asked to.
        case .cancelled: AnyShapeStyle(Color.secondary)
        }
    }
}
