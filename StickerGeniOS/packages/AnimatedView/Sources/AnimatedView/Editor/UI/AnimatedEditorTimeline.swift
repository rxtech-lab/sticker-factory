#if os(iOS)
import SwiftUI

/// One track per channel, a playhead, and the keyframes on them.
///
/// This is the surface raw keyframe editing actually happens on. It is shown only for animated
/// documents: a static one is required to keep every keyframe at t=0, so it has no timeline to draw.
struct AnimatedEditorTimeline: View {
    /// Height of one channel's track, including the gap under it.
    private static let trackHeight: CGFloat = 22

    /// The tracks alone, without the header.
    static var tracksHeight: CGFloat {
        CGFloat(AnimationChannel.allCases.count) * trackHeight
    }

    /// Room for the header, the playhead's cap, and the gap between them.
    private static let chromeHeight: CGFloat = 30

    /// What a caller placing this in a fixed-height slot should give it to show every track at once.
    ///
    /// Derived rather than a constant because the track count is `AnimationChannel.allCases`: the
    /// regular-width editor used to pin this to 150pt, which fitted exactly six tracks and silently
    /// clipped the bottom ones the moment the model grew a channel.
    static var preferredHeight: CGFloat { tracksHeight + chromeHeight }

    /// What to give it on iPhone, where the canvas and the pane below are competing for the same
    /// screen. Anything the cap cuts off is reachable by scrolling the tracks.
    static var compactHeight: CGFloat { min(preferredHeight, 170) }

    @Bindable var editor: AnimatedDocumentEditor

    @State private var pendingDetachLayerID: String?

    private var duration: Double { max(editor.document.durationSeconds, 0.0001) }
    private var layer: AnimatedLayer? { editor.selectedLayer }
    private var isDeclarative: Bool { layer.map { !$0.animations.isEmpty } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header

            if let layer {
                // The stack is one row per channel, so it outgrows any fixed slot the moment the
                // model gains a channel. Scrolling keeps the overflow inside the timeline instead
                // of letting it draw over the transport above and the pane picker below.
                ScrollView(.vertical) {
                    GeometryReader { proxy in
                        ZStack(alignment: .topLeading) {
                            VStack(spacing: 2) {
                                ForEach(AnimationChannel.allCases, id: \.self) { channel in
                                    track(channel, layer: layer, width: proxy.size.width)
                                }
                            }
                            playhead(width: proxy.size.width)
                        }
                    }
                    .frame(height: Self.tracksHeight)
                    // Leaves room for the playhead's cap, which sits above the first track.
                    .padding(.top, 4)
                    // Preset motion is generated, so its tracks are shown but not touchable. Dimming
                    // rather than hiding keeps the shape of the motion visible, which is what you want
                    // when deciding whether to convert it. Applied to the content rather than the
                    // scroll view so the tracks can still be scrolled into view.
                    .opacity(isDeclarative ? 0.55 : 1)
                    .allowsHitTesting(!isDeclarative)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: Self.tracksHeight + 4)
            } else {
                Text("Select a layer to see its timeline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            }
        }
        .padding(.horizontal, 12)
        .confirmationDialog(
            "Convert preset motion to keyframes?",
            isPresented: Binding(
                get: { pendingDetachLayerID != nil },
                set: { if !$0 { pendingDetachLayerID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Convert") {
                if let id = pendingDetachLayerID { editor.detachAnimations(forLayer: id) }
                pendingDetachLayerID = nil
            }
            Button("Cancel", role: .cancel) { pendingDetachLayerID = nil }
        } message: {
            Text("""
                Its presets become \(layer?.animation.keyframeCount ?? 0) editable keyframes. \
                Changing the sticker's duration will no longer re-time them automatically.
                """)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if isDeclarative, let id = layer?.id {
                AnimatedCartoonLabel("Preset motion", icon: "wand.and.stars")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Edit Keyframes") { pendingDetachLayerID = id }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            } else {
                Text(String(format: "%.2f s of %.2f s", editor.scrubDocumentTime, editor.document.durationSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            let total = editor.document.totalKeyframeCount
            Text("\(total)/\(AnimatedDocument.maximumKeyframeCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(total >= AnimatedDocument.maximumKeyframeCount ? .red : .secondary)
                .accessibilityLabel("\(total) of \(AnimatedDocument.maximumKeyframeCount) keyframes used")
        }
    }

    // MARK: - Tracks

    private func track(_ channel: AnimationChannel, layer: AnimatedLayer, width: CGFloat) -> some View {
        // Trim only means something where there is a path to trim. Images, text, and particles have
        // none, so the row is shown disabled rather than silently accepting keyframes that would
        // never render.
        let supported = channel != .trim || layer.supportsTrim
        let count = layer.animation.count(of: channel)

        return HStack(spacing: 6) {
            AnimatedCartoonSymbol(channel.symbolName)
                .font(.caption2)
                .frame(width: 18)
                .foregroundStyle(supported ? .secondary : .tertiary)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 3)

                ForEach(Array(layer.animation.times(on: channel).enumerated()), id: \.offset) { index, time in
                    keyframeMarker(channel: channel, layer: layer, index: index, time: time, width: trackWidth(width))
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())

            Button {
                editor.insertKeyframe(on: channel, forLayer: layer.id)
            } label: {
                AnimatedCartoonSymbol("plus.circle.fill").font(.caption)
            }
            .buttonStyle(.plain)
            .disabled(
                !supported
                    || count >= AnimatedLayerAnimation.maximumKeyframesPerChannel
                    || editor.document.totalKeyframeCount >= AnimatedDocument.maximumKeyframeCount
            )
            .accessibilityLabel("Add \(channel.label) keyframe")

            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .frame(width: 16, alignment: .trailing)
                .foregroundStyle(count >= 28 ? .orange : .secondary)
        }
        .frame(height: 20)
        .opacity(supported ? 1 : 0.4)
    }

    private func keyframeMarker(
        channel: AnimationChannel,
        layer: AnimatedLayer,
        index: Int,
        time: Double,
        width: CGFloat
    ) -> some View {
        let isSelected = editor.selectedKeyframe == .init(layerID: layer.id, channel: channel, index: index)
        return AnimatedCartoonSymbol(isSelected ? "diamond.fill" : "diamond")
            .font(.system(size: 11))
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .offset(x: max(0, CGFloat(time / duration) * width) - 5.5)
            .contentShape(Rectangle().size(width: 26, height: 22))
            .onTapGesture {
                editor.selectedKeyframe = .init(layerID: layer.id, channel: channel, index: index)
                editor.isPlaying = false
                editor.scrubDocumentTime = time
            }
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        editor.isPlaying = false
                        editor.beginGesture("retime-\(layer.id)-\(channel.rawValue)-\(index)")
                        let delta = Double(value.translation.width / max(width, 1)) * duration
                        editor.moveKeyframe(on: channel, forLayer: layer.id, index: index, toTime: time + delta)
                    }
                    .onEnded { _ in editor.endGesture() }
            )
            .contextMenu {
                Button(role: .destructive) {
                    editor.removeKeyframe(on: channel, forLayer: layer.id, index: index)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
    }

    // MARK: - Playhead

    /// The track area starts after the channel icon and ends before the add button and the count,
    /// so the playhead has to use the same inset the markers do or the two would disagree.
    private static let trackLeadingInset: CGFloat = 24
    private static let trackTrailingInset: CGFloat = 54

    private func trackWidth(_ width: CGFloat) -> CGFloat {
        max(width - Self.trackLeadingInset - Self.trackTrailingInset, 1)
    }

    private func playhead(width: CGFloat) -> some View {
        let track = trackWidth(width)
        let x = Self.trackLeadingInset + CGFloat(editor.scrubDocumentTime / duration) * track
        return Rectangle()
            .fill(Color.accentColor)
            .frame(width: 1.5)
            .overlay(alignment: .top) {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 10, height: 6)
                    .offset(y: -3)
            }
            .offset(x: x)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // Scrubbing implies looking at a specific frame, so it takes over from
                        // playback rather than fighting it.
                        editor.isPlaying = false
                        // `value.location` is local to the playhead itself, which sits at `x`, so
                        // the absolute position is the sum of the two.
                        let absolute = x + value.location.x - Self.trackLeadingInset
                        // The setter clamps to the timeline; this only has to produce a time.
                        editor.scrubDocumentTime = Double(absolute / track) * duration
                    }
            )
            .accessibilityLabel("Playhead")
    }
}
#endif
