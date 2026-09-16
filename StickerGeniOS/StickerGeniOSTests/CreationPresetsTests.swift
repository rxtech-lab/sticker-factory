import AnimatedView
import Foundation
import Testing
import UIKit
@testable import StickerGeniOS

@MainActor @Suite("Guided sticker creation")
struct CreationPresetsTests {
    private func catalog() throws -> CreationPresetCatalog {
        let url = try #require(Bundle.main.url(forResource: "creation-presets-preview", withExtension: "json"))
        return try JSONDecoder().decode(CreationPresetCatalog.self, from: Data(contentsOf: url)).validated()
    }
    @Test func previewMatrixRejectsMissingAndDuplicateVariants() throws {
        var catalog = try catalog()
        var preview = try #require(catalog.groups[0].options[0].preview)
        #expect(preview.isValid && preview.variants.count == 24)
        #expect(preview.animation(pose: "wave", mood: "happy") != preview.animation(pose: "bounce", mood: "happy"))
        preview.variants[0] = preview.variants[1]
        catalog.groups[0].options[0].preview = preview
        #expect(throws: (any Error).self) { try catalog.validated() }
    }
    @Test func requiredOptionalAndMultipleChoices() throws {
        var flow = CreationWizardState()
        let catalog = try catalog(); flow.apply(catalog, review: false)
        let style = catalog.groups[0], theme = catalog.groups[1]
        #expect(!flow.canSubmit)
        #expect(flow.valid(theme))
        flow.toggle("clay", in: style)
        #expect(flow.canSubmit)
        flow.toggle("space", in: theme); flow.toggle("cozy", in: theme); flow.toggle("nature", in: theme)
        #expect(flow.selections["theme"] == ["space", "cozy"])
        flow.toggle("clay", in: style)
        #expect(!flow.canSubmit)
    }
    @Test func overviewEditingAndChangedCatalogKeepValidChoices() throws {
        var flow = CreationWizardState()
        var catalog = try catalog(); flow.apply(catalog, review: false)
        flow.toggle("clay", in: catalog.groups[0]); flow.toggle("space", in: catalog.groups[1])
        flow.step = .overview; flow.edit(.kind); flow.advance(kind: .animated)
        #expect(flow.step == .animation)
        flow.advance(kind: .animated)
        #expect(flow.step == .overview && flow.animationReviewed)
        flow.edit(.preset("theme")); flow.advance(kind: .animated)
        #expect(flow.step == .overview)
        flow.requiresCatalogRefresh = true
        #expect(!flow.canSubmit)
        catalog.version += ".new"; catalog.groups[0].options.removeAll { $0.id == "clay" }
        flow.apply(catalog, review: true)
        #expect(flow.selections["theme"] == ["space"])
        #expect(flow.selections["style"] == [])
        #expect(flow.step == .preset("style") && !flow.canSubmit)
    }
    @Test func futureAndUnsupportedGroups() throws {
        var flow = CreationWizardState(); var catalog = try catalog()
        var future = catalog.groups[1]; future.id = "future"; catalog.groups.append(future)
        flow.apply(catalog, review: false)
        #expect(flow.steps(kind: .static).contains(.preset("future")))
        catalog.groups[2].type = "future_picker"
        catalog.groups[2].options = []
        catalog.groups[2].maxSelections = 0
        catalog = try catalog.validated()
        flow.apply(catalog, review: false)
        #expect(!flow.steps(kind: .static).contains(.preset("future")))
        catalog.groups[2].minSelections = 1
        catalog = try catalog.validated()
        flow.apply(catalog, review: false)
        #expect(flow.steps(kind: .static).contains(.preset("future")))
        #expect(!flow.valid(catalog.groups[2]))
        catalog.groups = []; flow.step = .catalog
        flow.apply(catalog, review: false, kind: .animated)
        #expect(flow.step == .animation)
    }
    @Test func bundledControlDemoRendersEveryMoodAndPoseAtEachLevel() throws {
        let demo = try CreationDemo.load()
        for (level, count) in [(PosePreset.low, 2), (.medium, 3), (.high, 5), (.ultra, 8)] {
            let document = try demo.document(for: level).validated()
            let poses = try #require(document.configuration?.controls.first { $0.id == "pose" }?.options)
            #expect(poses.count == count && poses.first?.id == "idle")
            var settings = StickerControlSettings.defaults(for: document)
            var moodPictures = Set<Data>()
            for mood in ["neutral", "happy", "surprised"] {
                settings.values["mood"] = .string(mood)
                for pose in poses {
                    settings.values["pose"] = .string(pose.id)
                    let resolved = try settings.resolvedDocument(document)
                    let renderer = AnimatedIconRenderer(document: resolved, assets: AnimatedAssetDictionary(images: demo.images))
                    let first = try #require(renderer.cgImage(at: 0, dimension: 128))
                    let firstData = try #require(UIImage(cgImage: first).pngData())
                    var frames = Set([firstData])
                    for index in 1..<8 {
                        let frame = try #require(renderer.cgImage(at: resolved.durationSeconds * Double(index) / 8, dimension: 128))
                        frames.insert(try #require(UIImage(cgImage: frame).pngData()))
                    }
                    #expect(frames.count > 1)
                    #expect(StickerPosterFrame.opaqueCoverage(of: first) > 1000)
                    if pose.id == "idle" { moodPictures.insert(firstData) }
                    settings.animate = false
                    #expect(settings.stillTime(in: resolved) == 0)
                    settings.animate = true
                }
            }
            #expect(moodPictures.count == 3)
        }
    }
    @Test func bundledWorkflowGIFActuallyDecodesMotion() throws {
        let url = try #require(Bundle.main.url(forResource: "creation-type-animated", withExtension: "gif"))
        let animation = try #require(StickerAnimationDecoder.decode(Data(contentsOf: url), id: "demo", maxPixelSize: 128))
        #expect(animation.frames.count > 2)
        #expect(animation.duration >= 2 && animation.duration <= 4)
        #expect(Set(animation.frames.compactMap { $0.pngData() }).count > 1)
    }
}
