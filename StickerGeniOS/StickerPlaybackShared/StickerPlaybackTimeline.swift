import AnimatedView
import Foundation
import SwiftUI

/// Local playback composition. Each segment retains the original document's time mapping.
nonisolated struct StickerPlaybackTimeline: Hashable, Sendable {
    struct Segment: Hashable, Sendable {
        var id: UUID
        var document: AnimatedDocument
        var start: Double
        var duration: Double
    }
    struct Sample {
        var index: Int
        var document: AnimatedDocument
        var time: Double
    }
    struct Frame {
        var time: Double
        var duration: Double
    }
    let segments: [Segment]
    let duration: Double

    init(document: AnimatedDocument, settings: StickerControlSettings) throws {
        guard settings.mode == .multiple, !settings.entries.isEmpty else { throw StickerExportError.invalidDocument }
        var segments: [Segment] = []
        var cursor = 0.0
        for entry in settings.entries {
            let resolved = try entry.settings.resolvedDocument(document)
            let duration = resolved.renderedCycleDuration
            guard duration.isFinite, duration > 0 else { throw StickerExportError.invalidDocument }
            segments.append(.init(id: entry.id, document: resolved, start: cursor, duration: duration))
            cursor += duration
        }
        self.segments = segments
        self.duration = cursor
    }

    func sample(at elapsed: Double, repeats: Bool = true) -> Sample {
        let finite = elapsed.isFinite ? max(0, elapsed) : 0
        let time = repeats ? finite.truncatingRemainder(dividingBy: duration) : min(finite, duration.nextDown)
        let index = segments.lastIndex { $0.start <= time } ?? 0
        let segment = segments[index]
        return .init(index: index, document: segment.document, time: min(time - segment.start, segment.duration.nextDown))
    }

    /// Keep at least one sample of every item, even at the Messages ladder's lowest frame rate.
    /// Each item's frames divide its duration exactly, so boundaries never acquire a pause.
    func frames(fps: Int) -> [Frame] {
        segments.flatMap { segment in
            let count = max(1, Int(ceil(segment.duration * Double(max(1, fps)) - 1e-8)))
            let step = segment.duration / Double(count)
            return (0..<count).map { Frame(time: segment.start + Double($0) * step, duration: step) }
        }
    }
}

/// Used by both hosts, with the same clock passed to the controls for row highlighting.
struct StickerConfiguredPreview: View {
    let document: AnimatedDocument
    let settings: StickerControlSettings
    let assets: StickerRenderAssets
    var repeats = true
    var origin = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var shouldReduceMotion: Bool {
        reduceMotion || ProcessInfo.processInfo.arguments.contains("--reduce-motion")
    }

    var body: some View {
        if settings.mode == .multiple {
            if let timeline = try? StickerPlaybackTimeline(document: document, settings: settings) {
                TimelineView(.animation(minimumInterval: 1 / Double(max(1, document.fps)), paused: shouldReduceMotion)) { context in
                    let restingTime = min(timeline.segments[0].document.playbackDuration, timeline.segments[0].duration.nextDown)
                    let sample = timeline.sample(at: shouldReduceMotion ? restingTime : context.date.timeIntervalSince(origin), repeats: repeats)
                    AnimatedIconFrame(document: sample.document, time: sample.time, assets: assets.dictionary)
                }
            } else {
                Text("Add animation").foregroundStyle(.secondary)
            }
        } else if let resolved = try? settings.resolvedDocument(document) {
            if settings.animate {
                AnimatedIconView(document: resolved, assets: assets.dictionary, repeats: repeats)
            } else {
                AnimatedIconFrame(document: resolved, time: settings.stillTime(in: resolved), assets: assets.dictionary)
            }
        }
    }
}

extension StickerRenderAssets {
    mutating func merge(_ other: Self) {
        images.merge(other.images, uniquingKeysWith: { _, new in new })
        videos.merge(other.videos, uniquingKeysWith: { _, new in new })
    }

    func containsArtwork(for document: AnimatedDocument) -> Bool {
        var required = Set(document.layers.filter { !$0.hidden }.flatMap(\.referencedImageAssetIDs))
        if case .image(let id, _) = document.background { required.insert(id) }
        return required.allSatisfy { images[$0] != nil } && document.layers.allSatisfy { layer in
            if case .video(let video) = layer, !layer.hidden { return videos[video.assetId] != nil }
            return true
        }
    }
}

extension StickerControlSettings {
    func playbackDocuments(_ document: AnimatedDocument) throws -> [AnimatedDocument] {
        if mode == .multiple { return try StickerPlaybackTimeline(document: document, settings: self).segments.map(\.document) }
        return [try resolvedDocument(document)]
    }
}
