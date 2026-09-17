import ActivityKit
import SwiftUI
import WidgetKit

@main
struct StickerGenerationActivityBundle: WidgetBundle {
    var body: some Widget { StickerGenerationActivity() }
}

struct StickerGenerationActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StickerGenerationAttributes.self) { context in
            GenerationActivityCard(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Color(red: 1, green: 0.96, blue: 0.84))
                .activitySystemActionForegroundColor(.black)
                .widgetURL(context.attributes.stickerURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    WinkyActivityMascot(state: context.state, isStale: context.isStale, size: 28)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let count = context.state.progressCountText {
                        Text(count).font(.caption.monospacedDigit())
                    } else if !context.state.isFinished {
                        Text(context.attributes.startedAt, style: .timer)
                            .font(.caption.monospacedDigit()).frame(maxWidth: 70)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(context.attributes.title)
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Text(context.state.message)
                            .font(.subheadline)
                            .lineLimit(context.state.unitProgress == nil ? 3 : 2)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
                        GenerationCountProgress(state: context.state)
                            .tint(.yellow)
                        if context.isStale && !context.state.isFinished {
                            Text("Waiting for an update…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Let the status request its wrapped height and keep its last line
                    // above the Island's rounded bottom edge.
                    .padding(.horizontal, 4)
                    .padding(.bottom, 8)
                }
            } compactLeading: {
                WinkyActivityMascot(state: context.state, isStale: context.isStale, size: 22)
            } compactTrailing: {
                GenerationCompactStatus(attributes: context.attributes, state: context.state, isStale: context.isStale)
            } minimal: {
                WinkyActivityMascot(state: context.state, isStale: context.isStale, size: 22)
            }
            .widgetURL(context.attributes.stickerURL)
            .keylineTint(.yellow)
        }
    }
}

private struct WinkyActivityMascot: View {
    let state: StickerGenerationAttributes.ContentState
    let isStale: Bool
    let size: CGFloat

    private var pose: GenerationMascotPose { state.mascotPose(isStale: isStale) }

    var body: some View {
        Image(pose.assetName)
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: size, height: size)
            .id(pose)
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
            .animation(.easeInOut(duration: 0.25), value: pose)
            .accessibilityLabel("Winky, \(pose.rawValue)")
    }
}

private struct GenerationCompactStatus: View {
    let attributes: StickerGenerationAttributes
    let state: StickerGenerationAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text(isStale && !state.isFinished ? "Updating" : state.compactLabel)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            if state.isFinished {
                Image(systemName: state.symbol).font(.caption2).foregroundStyle(.yellow)
            } else if let count = state.progressCountText {
                Text(count)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.yellow)
            } else {
                Text(attributes.startedAt, style: .timer)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: 64)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.progressCountText.map {
            "\(state.message), \(state.progressLabel ?? "Artwork parts") \($0)"
        } ?? state.message)
    }
}

private extension StickerGenerationAttributes.ContentState {
    /// Compact mode only has room for the current action; the expanded view keeps the full message.
    var compactLabel: String {
        switch phase {
        case "completed": return String(localized: "Done!")
        case "failed": return String(localized: "Failed")
        case "cancelled": return String(localized: "Stopped")
        case "queued", "waiting": return String(localized: "Waiting")
        default: break
        }
        let action = message.split(whereSeparator: { $0.isWhitespace || $0 == ":" }).first.map(String.init) ?? ""
        switch action.lowercased() {
        case "compose": return String(localized: "Composing")
        case "generate": return String(localized: "Generating")
        case "render": return String(localized: "Rendering")
        default: return action.isEmpty ? String(localized: "Creating") : action
        }
    }
}

struct GenerationActivityCard: View {
    let attributes: StickerGenerationAttributes
    let state: StickerGenerationAttributes.ContentState
    var isStale = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            WinkyActivityMascot(state: state, isStale: isStale, size: 44)
            VStack(alignment: .leading, spacing: 5) {
                Text(attributes.title).font(.headline).lineLimit(1)
                Text(state.message).font(.subheadline).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                GenerationCountProgress(state: state)
                    .tint(.black)
                if isStale && !state.isFinished {
                    Text("Waiting for an update…").font(.caption).foregroundStyle(.black.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.black)
        .padding(16)
    }
}

private struct GenerationCountProgress: View {
    let state: StickerGenerationAttributes.ContentState

    var body: some View {
        if let progress = state.unitProgress, let count = state.progressCountText {
            VStack(spacing: 3) {
                HStack {
                    Text(state.progressLabel ?? String(localized: "Artwork parts"))
                    Spacer()
                    Text(count).monospacedDigit()
                }
                .font(.caption2)
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.progressLabel ?? String(localized: "Artwork parts"))
            .accessibilityValue(count)
        }
    }
}

private let previewAttributes = StickerGenerationAttributes(
    jobID: "preview-job", stickerID: "00000000-0000-0000-0000-000000000001",
    title: "Dancing avocado", startedAt: .now.addingTimeInterval(-42)
)

#Preview("Lock Screen", as: .content, using: previewAttributes) {
    StickerGenerationActivity()
} contentStates: {
    StickerGenerationAttributes.ContentState(message: "Drawing your dancing avocado…", phase: "running")
    StickerGenerationAttributes.ContentState(message: "Adding the finishing touches to your animation…", phase: "running")
    StickerGenerationAttributes.ContentState(message: "Done!", phase: "completed")
    StickerGenerationAttributes.ContentState(message: "Generation failed. Open to retry.", phase: "failed")
    StickerGenerationAttributes.ContentState(message: "Generation stopped", phase: "cancelled")
}

#Preview("Expanded", as: .dynamicIsland(.expanded), using: previewAttributes) {
    StickerGenerationActivity()
} contentStates: {
    StickerGenerationAttributes.ContentState(message: "Animating the dance moves…", phase: "running")
}

#Preview("Compact", as: .dynamicIsland(.compact), using: previewAttributes) {
    StickerGenerationActivity()
} contentStates: {
    StickerGenerationAttributes.ContentState(message: "Drawing your sticker artwork…", phase: "running")
    StickerGenerationAttributes.ContentState(
        message: "Composing PC robot emoji", phase: "running", completedUnits: 1, totalUnits: 10
    )
    StickerGenerationAttributes.ContentState(
        message: "Composing sprite sheets…", phase: "running",
        completedUnits: 0, totalUnits: 3, progressLabel: "Sprite sheets"
    )
    StickerGenerationAttributes.ContentState(
        message: "Composing sprite sheets…", phase: "running",
        completedUnits: 1, totalUnits: 3, progressLabel: "Sprite sheets"
    )
    StickerGenerationAttributes.ContentState(message: "Animating the dance moves…", phase: "running")
    StickerGenerationAttributes.ContentState(message: "Done!", phase: "completed")
    StickerGenerationAttributes.ContentState(message: "Generation failed. Open to retry.", phase: "failed")
}

#Preview("Composition • Lock Screen", as: .content, using: longMessagePreviewAttributes) {
    StickerGenerationActivity()
} contentStates: {
    StickerGenerationAttributes.ContentState(message: "Composing artwork…", phase: "running", completedUnits: 0, totalUnits: 10)
    StickerGenerationAttributes.ContentState(message: "Composing the robot controls…", phase: "running", completedUnits: 1, totalUnits: 10)
    StickerGenerationAttributes.ContentState(message: "Artwork parts ready…", phase: "running", completedUnits: 10, totalUnits: 10)
    StickerGenerationAttributes.ContentState(message: "Assembling the animation…", phase: "running")
}

#Preview("Composition • Expanded", as: .dynamicIsland(.expanded), using: longMessagePreviewAttributes) {
    StickerGenerationActivity()
} contentStates: {
    StickerGenerationAttributes.ContentState(
        message: "Composing the robot expressions and mood controls…", phase: "running", completedUnits: 1, totalUnits: 10
    )
    StickerGenerationAttributes.ContentState(
        message: "Composing the robot expressions and mood controls…", phase: "running", completedUnits: 7, totalUnits: 10
    )
}

#Preview("Minimal", as: .dynamicIsland(.minimal), using: previewAttributes) {
    StickerGenerationActivity()
} contentStates: {
    StickerGenerationAttributes.ContentState(message: "Creating your sticker…", phase: "running")
}

#Preview("Stale update") {
    GenerationActivityCard(attributes: previewAttributes,
        state: .init(message: "Rendering the animation…", phase: "running"), isStale: true)
        .background(Color(red: 1, green: 0.96, blue: 0.84))
}

private let longMessagePreviewAttributes = StickerGenerationAttributes(
    jobID: "preview-long-job", stickerID: "00000000-0000-0000-0000-000000000002",
    title: "PC Robot Mood Controls", startedAt: .now.addingTimeInterval(-47)
)

#Preview("Expanded • Long status", as: .dynamicIsland(.expanded), using: longMessagePreviewAttributes) {
    StickerGenerationActivity()
} contentStates: {
    StickerGenerationAttributes.ContentState(
        message: "Compose part:0 PC robot emoji — adding the mood controls and finishing the animated expressions…",
        phase: "running"
    )
    StickerGenerationAttributes.ContentState(
        message: "Preparing the robot artwork, drawing each expression, and assembling the animation for your sticker…",
        phase: "running"
    )
}

#Preview("Review • Compact", as: .dynamicIsland(.compact), using: longMessagePreviewAttributes) {
    StickerGenerationActivity()
} contentStates: {
    StickerGenerationAttributes.ContentState(
        message: "Reviewing sticker configurations…", phase: "running",
        completedUnits: 1, totalUnits: 6, progressLabel: "Review checks"
    )
    StickerGenerationAttributes.ContentState(message: "Finishing your sticker…", phase: "running")
}

#Preview("Review • Expanded", as: .dynamicIsland(.expanded), using: longMessagePreviewAttributes) {
    StickerGenerationActivity()
} contentStates: {
    StickerGenerationAttributes.ContentState(
        message: "Reviewing sticker configurations…", phase: "running",
        completedUnits: 0, totalUnits: 6, progressLabel: "Review checks"
    )
    StickerGenerationAttributes.ContentState(
        message: "Reviewing sticker configurations…", phase: "running",
        completedUnits: 4, totalUnits: 6, progressLabel: "Review checks"
    )
}

#Preview("Review • Lock Screen", as: .content, using: longMessagePreviewAttributes) {
    StickerGenerationActivity()
} contentStates: {
    StickerGenerationAttributes.ContentState(
        message: "Reviewing sticker configurations…", phase: "running",
        completedUnits: 1, totalUnits: 6, progressLabel: "Review checks"
    )
}
