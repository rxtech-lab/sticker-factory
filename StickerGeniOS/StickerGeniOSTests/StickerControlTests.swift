import AnimatedView
import Foundation
import Testing
import UIKit
@testable import StickerGeniOS

@MainActor
struct StickerControlTests {
    private func document() -> AnimatedDocument { PreviewFixtures.configurableDocument }
    @Test func settingsAreAccountScopedAndRestoreCompatibleValues() throws {
        let suite = "controls-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = StickerControlPreferences(defaults: defaults)
        var selection = StickerControlSettings.defaults(for: document())
        selection.values["mood"] = .string("calm"); selection.animate = false; selection.stillPosition = 0.75; selection.speed = 0.5
        try preferences.save(selection, accountID: "alice", stickerID: "pet", document: document())
        #expect(preferences.load(accountID: "alice", stickerID: "pet", document: document()) == selection)
        let explicit = preferences.load(
            accountID: "alice", stickerID: "pet", document: document(), explicitValues: ["mood": .string("happy")]
        )
        #expect(explicit.values["mood"] == .string("happy"))
        #expect(preferences.load(accountID: "bob", stickerID: "pet", document: document()).values["mood"] == .string("happy"))
        var draft = selection; draft.values["mood"] = .string("happy")
        // Dismissing the sheet never writes its draft.
        #expect(preferences.load(accountID: "alice", stickerID: "pet", document: document()).values["mood"] == .string("calm"))
        var updated = document()
        updated.configuration?.controls[0].options?[1] = .init(id: "sleepy", label: "Sleepy")
        #expect(preferences.load(accountID: "alice", stickerID: "pet", document: updated).values["mood"] == .string("happy"))
        #expect(StickerControlSettings.defaults(for: document()).animate)
        #expect(StickerControlSettings.defaults(for: document()).speed == 1)
    }
    @Test func cacheKeysSeparateRevisionFrameAndSendMode() throws {
        let selected = StickerControlSettings.defaults(for: document())
        func key(_ settings: StickerControlSettings, _ revision: String = "1", _ image: Bool = false) throws -> String {
            try StickerControlPreferences.renderKey(
                accountID: "alice", stickerID: "pet", revisionID: revision, settings: settings, image: image
            )
        }
        #expect(try key(selected) == key(selected))
        #expect(try key(selected) != key(selected, "2"))
        #expect(try key(selected) != key(selected, "1", true))
        var still = selected; still.animate = false; still.stillPosition = 0.5
        #expect(try key(selected) != key(still))
    }
    @Test func cancellationDuringRenderingNeverInsertsOrSucceeds() async throws {
        let session = StickerSendSession()
        var inserted = false, completed = false
        var resume: CheckedContinuation<Int, Never>?
        let task = Task { @MainActor in
            try await session.perform(
                prepare: { await withCheckedContinuation { resume = $0 } },
                validate: {},
                insert: { _ in inserted = true }
            )
            completed = true
        }
        while resume == nil { await Task.yield() }
        #expect(session.begin() == nil)
        session.cancel()
        resume?.resume(returning: 1)
        do { try await task.value; Issue.record("Cancelled send succeeded") } catch is CancellationError {} catch { Issue.record(error) }
        #expect(!inserted && !completed && !session.isSending)
        try await session.perform(prepare: { 1 }, validate: {}, insert: { _ in inserted = true })
        #expect(inserted)
    }
    @Test func failedInsertionCannotCommitRememberedSettings() async throws {
        enum Failure: Error { case insertion }
        let session = StickerSendSession()
        var committed = false
        do {
            try await session.perform(prepare: { 1 }, validate: {}, insert: { _ in throw Failure.insertion })
            committed = true
        } catch Failure.insertion {}
        #expect(!committed && !session.isSending)
    }
    @Test func exactStillSelectionMatchesPreviewWithoutRescalingArtwork() async throws {
        let document = document()
        var settings = StickerControlSettings.defaults(for: document); settings.animate = false; settings.stillPosition = 0.5
        let resolved = try settings.resolvedDocument(document)
        let expected = try #require(AnimatedIconRenderer(document: resolved).cgImage(at: settings.stillTime(in: resolved), dimension: 1024))
        let export = try await StickerConfiguredExport.render(document: resolved, settings: settings, assets: .init(), image: true)
        defer { try? FileManager.default.removeItem(at: export.url) }
        let actual = try #require(UIImage(contentsOfFile: export.url.path)?.cgImage)
        #expect(actual.width == expected.width && actual.height == expected.height)
        // Summed alpha detects an extra fit-to-layer margin even when PNG encoders differ.
        let actualCoverage = StickerPosterFrame.opaqueCoverage(of: actual)
        let expectedCoverage = StickerPosterFrame.opaqueCoverage(of: expected)
        #expect(abs(actualCoverage - expectedCoverage) < 100)
    }
}
