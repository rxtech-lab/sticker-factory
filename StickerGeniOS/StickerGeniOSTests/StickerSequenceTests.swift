import AnimatedView
import AVFoundation
import Foundation
import ImageIO
import Testing
import UIKit
@testable import StickerGeniOS

@MainActor
struct StickerSequenceTests {
    private func document(loop: AnimatedLoop = .loop) -> AnimatedDocument {
        var document = AnimatedDocument(kind: .animated, durationSeconds: 0.4, fps: 10, loop: loop, layers: [
            .shape(.init(base: .init(id: "red", name: "Red"), shape: .circle, fill: .solid("#FF0000"))),
            .shape(.init(base: .init(id: "blue", name: "Blue"), shape: .circle, fill: .solid("#0000FF")))
        ])
        document.configuration = .init(controls: [
            .init(id: "red", label: "Red", type: .toggle, defaultValue: .bool(true), layerIds: ["red"]),
            .init(id: "blue", label: "Blue", type: .toggle, defaultValue: .bool(false), layerIds: ["blue"])
        ])
        return document
    }

    private func sequence(_ document: AnimatedDocument) -> StickerControlSettings {
        var settings = StickerControlSettings.defaults(for: document)
        settings.selectMode(.multiple)
        var second = StickerControlSettings.defaults(for: document)
        second.values["red"] = .bool(false)
        second.values["blue"] = .bool(true)
        second.speed = 2
        settings.entries.append(.init(settings: second))
        return settings
    }

    @Test func legacyPreferencesAndSequenceEditingStayIndependent() throws {
        let legacy = Data(#"{"values":{"red":false},"animate":false,"speed":0.5,"stillPosition":0.75,"signatures":{}}"#.utf8)
        var settings = try JSONDecoder().decode(StickerControlSettings.self, from: legacy)
        #expect(settings.mode == .single && !settings.animate && settings.speed == 0.5)
        settings.selectMode(.multiple)
        let firstID = settings.entries[0].id
        settings.entries[0].speed = 2
        settings.selectMode(.single)
        #expect(settings.speed == 0.5 && settings.stillPosition == 0.75)
        settings.selectMode(.multiple)
        #expect(settings.entries[0].id == firstID && settings.entries[0].speed == 2)
        settings.entries.removeAll()
        settings.selectMode(.single); settings.selectMode(.multiple)
        #expect(settings.entries.isEmpty && !settings.canPlay)
        #expect(throws: (any Error).self) { try StickerPlaybackTimeline(document: document(), settings: settings) }
    }

    @Test func sequencePersistenceReconciliationAndCacheIdentity() throws {
        let doc = document()
        let suite = "sequence-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = StickerControlPreferences(defaults: defaults)
        let settings = sequence(doc)
        try preferences.save(settings, accountID: "alice", stickerID: "pet", document: doc)
        #expect(preferences.load(accountID: "alice", stickerID: "pet", document: doc) == settings)
        #expect(preferences.load(accountID: "bob", stickerID: "pet", document: doc).mode == .single)
        func key(_ settings: StickerControlSettings) throws -> String {
            try StickerControlPreferences.renderKey(accountID: "alice", stickerID: "pet", revisionID: "r1",
                                                   settings: settings, image: false)
        }
        var changed = settings
        changed.entries.reverse()
        #expect(try key(changed) != key(settings))
        changed = settings; changed.entries[1].speed = 0.5
        #expect(try key(changed) != key(settings))
        var revised = doc
        revised.configuration?.controls.removeLast()
        let reconciled = settings.reconciled(with: revised)
        #expect(reconciled.entries.map(\.id) == settings.entries.map(\.id))
        #expect(reconciled.entries.allSatisfy { $0.values["blue"] == nil })
    }

    @Test func timelineHonorsBoundariesSpeedPingPongAndSpeedBinding() throws {
        let doc = document(loop: .pingPong)
        let timeline = try StickerPlaybackTimeline(document: doc, settings: sequence(doc))
        #expect(abs(timeline.duration - 1.2) < 0.0001)
        #expect(timeline.sample(at: 0.799).index == 0)
        #expect(timeline.sample(at: 0.8).index == 1)
        #expect(abs(timeline.sample(at: 0.9).time - 0.1) < 0.0001)
        #expect(timeline.sample(at: timeline.duration).index == 0)
        #expect(timeline.sample(at: timeline.duration, repeats: false).index == 1)
        var bound = document()
        bound.configuration?.controls.append(.init(id: "tempo", label: "Tempo", type: .number,
            defaultValue: .number(1), binding: "speed", minimum: 0.25, maximum: 2, step: 0.05))
        var settings = sequence(bound)
        settings.entries[0].values["tempo"] = .number(2)
        settings.entries[0].speed = 0.25
        let boundTimeline = try StickerPlaybackTimeline(document: bound, settings: settings)
        #expect(boundTimeline.segments[0].duration == 0.2)
        let frames = boundTimeline.frames(fps: 4)
        #expect(frames.contains { boundTimeline.sample(at: $0.time).index == 0 })
        #expect(frames.contains { boundTimeline.sample(at: $0.time).index == 1 })
        #expect(abs(frames.reduce(0) { $0 + $1.duration } - boundTimeline.duration) < 0.0001)
    }

    @Test func fallbackUsesOnlyFirstAnimationAndDoesNotMaskCancellation() async throws {
        let doc = document()
        let settings = sequence(doc)
        var attempts: [Int] = []
        let result = try await StickerConfiguredExport.systemSequence(document: doc, settings: settings) { timeline in
            attempts.append(timeline.segments.count)
            if timeline.segments.count > 1 { throw StickerSequenceExportError.animationDoesNotFit }
            #expect(timeline.segments[0].id == settings.entries[0].id)
            return .init(url: URL(fileURLWithPath: "/tmp/unused.png"), metadata: .init(format: .apng,
                width: 300, height: 300, byteCount: 100, durationSeconds: 0.4, fps: 10, hasAlpha: true))
        }
        #expect(attempts == [2, 1] && result.firstAnimationOnly)
        attempts = []
        do {
            _ = try await StickerConfiguredExport.systemSequence(document: doc, settings: settings) { timeline in
                attempts.append(timeline.segments.count)
                throw CancellationError()
            }
            Issue.record("Cancellation must propagate")
        } catch is CancellationError {}
        #expect(attempts == [2])
        do {
            _ = try await StickerConfiguredExport.systemSequence(document: doc, settings: settings) { _ in
                throw StickerSequenceExportError.animationDoesNotFit
            }
            Issue.record("A first animation that cannot fit must fail")
        } catch StickerSequenceExportError.animationDoesNotFit {}
    }

    @Test func exportedImagesMatchSequenceOrderTimingAndTransparency() async throws {
        let doc = document()
        let settings = sequence(doc)
        for format in [StickerExportFormat.gif, .webp, .apng] {
            let result: RenderedStickerExport
            if format == .apng {
                result = try await StickerConfiguredExport.render(document: doc, settings: settings, assets: .init(), image: true)
            } else {
                result = try await StickerConfiguredExport.share(document: doc, settings: settings, assets: .init(), format: format)
            }
            defer { try? FileManager.default.removeItem(at: result.url) }
            let source = try #require(CGImageSourceCreateWithURL(result.url as CFURL, nil))
            let count = CGImageSourceGetCount(source)
            #expect(count >= 2)
            var elapsed = 0.0
            for index in 0..<count {
                let image = try #require(CGImageSourceCreateImageAtIndex(source, index, nil))
                let pixels = try #require(IndexedPNGEncoder.rgbaBytes(from: image)?.pixels)
                let middle = (image.height / 2 * image.width + image.width / 2) * 4
                if elapsed < 0.399 {
                    #expect(pixels[middle] > 200 && pixels[middle + 2] < 40)
                } else {
                    #expect(pixels[middle + 2] > 200 && pixels[middle] < 40)
                }
                #expect(pixels[3] == 0)
                let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
                let keys: (CFString, CFString) = format == .gif
                    ? (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime)
                    : format == .webp ? (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime)
                    : (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime)
                let timing = try #require(properties[keys.0] as? [CFString: Any])
                elapsed += try #require(timing[keys.1] as? Double)
            }
            #expect(abs(elapsed - 0.6) < 0.02)
        }
    }

    @Test func videoHasOneSequenceAndSelectedOpaqueBackground() async throws {
        let doc = document()
        let result = try await StickerConfiguredExport.share(document: doc, settings: sequence(doc), assets: .init(),
            format: .mp4, background: .solid("#00FF00"))
        defer { try? FileManager.default.removeItem(at: result.url) }
        let asset = AVURLAsset(url: result.url)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 0.6) < 0.11)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for (time, blue) in [(0.1, false), (0.5, true)] {
            let (image, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
            let pixels = try #require(IndexedPNGEncoder.rgbaBytes(from: image)?.pixels)
            #expect(pixels[1] > 200 && pixels[3] == 255)
            let middle = (image.height / 2 * image.width + image.width / 2) * 4
            #expect(pixels[middle + (blue ? 2 : 0)] > 200)
        }
    }

    @Test func sequenceFramesMatchPreviewAtDifferentSpeedsAndReversePlayback() throws {
        var doc = PreviewFixtures.configurableDocument
        doc.loop = .pingPong
        var settings = StickerControlSettings.defaults(for: doc)
        settings.speed = 0.5
        settings.selectMode(.multiple)
        var second = settings.entries[0]
        second.id = UUID(); second.speed = 2
        settings.entries.append(second)
        let timeline = try StickerPlaybackTimeline(document: doc, settings: settings)
        let exporter = StickerExporter(timeline: timeline)
        for segment in timeline.segments {
            for fraction in [0.15, 0.65, 0.9] {
                let localTime = segment.duration * fraction
                let expected = try #require(AnimatedIconRenderer(document: segment.document).cgImage(at: localTime, dimension: 96))
                let actual = try #require(exporter.renderFrame(document: timeline.segments[0].document,
                    time: segment.start + localTime, dimension: 96, assets: .init()))
                let expectedPixels = try #require(IndexedPNGEncoder.rgbaBytes(from: expected)?.pixels)
                let actualPixels = try #require(IndexedPNGEncoder.rgbaBytes(from: actual)?.pixels)
                let meanError = zip(expectedPixels, actualPixels).reduce(0.0) {
                    $0 + abs(Double($1.0) - Double($1.1))
                } / Double(expectedPixels.count)
                #expect(meanError < 0.25)
            }
        }
    }
}
