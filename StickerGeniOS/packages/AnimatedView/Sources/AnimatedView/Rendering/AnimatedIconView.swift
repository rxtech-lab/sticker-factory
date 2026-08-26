import SwiftUI

/// Plays an `AnimatedDocument`.
///
/// The public entry point of the package. It is a thin driver over `AnimatedIconFrame`: a
/// `TimelineView` supplies the clock and the frame does all the drawing, which keeps the animated
/// and the exported paths on exactly the same code.
public struct AnimatedIconView: View {
    public var document: AnimatedDocument
    public var assets: any AnimatedAssetProvider
    /// Overrides the document's own `speed`. `nil` uses what the document says.
    public var speed: Double?
    /// Forces a `once` document to keep looping. Useful for a preview tile, where a one-shot
    /// animation that has already played reads as a broken image.
    public var repeats: Bool
    public var isPlaying: Bool
    /// A fixed square/rect size. `nil` fills whatever space the parent offers, at the document's
    /// aspect ratio.
    public var size: CGSize?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var origin = Date()
    /// Where playback sat when it was paused, so pausing and resuming does not jump.
    @State private var pausedAt: Double = 0

    public init(
        document: AnimatedDocument,
        assets: any AnimatedAssetProvider = EmptyAnimatedAssets(),
        speed: Double? = nil,
        repeats: Bool = false,
        isPlaying: Bool = true,
        size: CGSize? = nil
    ) {
        self.document = document
        self.assets = assets
        self.speed = speed
        self.repeats = repeats
        self.isPlaying = isPlaying
        self.size = size
    }

    /// Honours the system setting, and a `--reduce-motion` launch argument so UI tests can pin the
    /// renderer to a single deterministic frame without a device setting.
    private var shouldReduceMotion: Bool {
        reduceMotion || ProcessInfo.processInfo.arguments.contains("--reduce-motion")
    }

    private var playbackDocument: AnimatedDocument {
        var result = document
        if let speed { result.speed = speed }
        if repeats, result.kind == .animated, result.loop == .once { result.loop = .loop }
        return result
    }

    public var body: some View {
        content
            .frame(width: size?.width, height: size?.height)
    }

    @ViewBuilder
    private var content: some View {
        let playback = playbackDocument
        if playback.kind == .animated, isPlaying, !shouldReduceMotion {
            TimelineView(.animation(minimumInterval: 1 / Double(max(playback.fps, 1)))) { context in
                AnimatedIconFrame(
                    document: playback,
                    time: pausedAt + context.date.timeIntervalSince(origin),
                    assets: assets
                )
            }
            .onDisappear { pausedAt += Date().timeIntervalSince(origin) }
            .onAppear { origin = Date() }
        } else {
            // A still document, a paused one, or reduce-motion: show the settled end state rather
            // than frame zero, which for an entrance animation would be a blank canvas.
            AnimatedIconFrame(
                document: playback,
                time: playback.kind == .static ? 0 : restingTime(playback),
                assets: assets
            )
        }
    }

    private func restingTime(_ playback: AnimatedDocument) -> Double {
        isPlaying ? playback.playbackDuration : pausedAt
    }
}

/// A document rendered at one explicit moment, with a scrubbable time.
///
/// Separate from `AnimatedIconView` because a scrubber, a filmstrip, and the exporter all want to
/// drive time themselves rather than be driven by a clock.
public struct AnimatedIconScrubber: View {
    public var document: AnimatedDocument
    public var assets: any AnimatedAssetProvider
    @Binding public var time: Double

    public init(document: AnimatedDocument, assets: any AnimatedAssetProvider = EmptyAnimatedAssets(), time: Binding<Double>) {
        self.document = document
        self.assets = assets
        self._time = time
    }

    public var body: some View {
        AnimatedIconFrame(document: document, time: time, assets: assets)
    }
}
