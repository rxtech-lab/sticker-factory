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
                    Image(systemName: context.state.symbol)
                        .font(.title2).foregroundStyle(.yellow)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !context.state.isFinished {
                        Text(context.attributes.startedAt, style: .timer)
                            .font(.caption.monospacedDigit()).frame(maxWidth: 70)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(context.attributes.title).font(.headline).lineLimit(1)
                        Text(context.state.message).font(.subheadline).lineLimit(2)
                        if context.isStale && !context.state.isFinished {
                            Text("Waiting for an update…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: context.state.symbol).foregroundStyle(.yellow)
            } compactTrailing: {
                if context.state.isFinished {
                    Image(systemName: context.state.symbol).foregroundStyle(.yellow)
                } else {
                    ProgressView().tint(.yellow)
                }
            } minimal: {
                Image(systemName: context.state.symbol).foregroundStyle(.yellow)
            }
            .widgetURL(context.attributes.stickerURL)
            .keylineTint(.yellow)
        }
    }
}

struct GenerationActivityCard: View {
    let attributes: StickerGenerationAttributes
    let state: StickerGenerationAttributes.ContentState
    var isStale = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: state.symbol)
                .font(.title2.weight(.bold))
                .frame(width: 44, height: 44)
                .background(Color.yellow, in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(.black, lineWidth: 2))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(attributes.title).font(.headline).lineLimit(1)
                Text(state.message).font(.subheadline).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                if isStale && !state.isFinished {
                    Text("Waiting for an update…").font(.caption).foregroundStyle(.black.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !state.isFinished {
                ProgressView().tint(.black).padding(.top, 12)
                    .accessibilityLabel("Generation in progress")
            }
        }
        .foregroundStyle(.black)
        .padding(16)
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
    StickerGenerationAttributes.ContentState(message: "Sticker ready", phase: "completed")
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
    StickerGenerationAttributes.ContentState(message: "Creating your sticker…", phase: "running")
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
