import AnimatedView
import CryptoKit
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import StickerGeniOS

@Suite("Store and publisher regressions")
@MainActor
struct StoreAndPublisherTests {
    @Test("Publishing overlaps uploads and registers only verified files")
    func concurrentPublishUploads() async throws {
        var revision = PreviewFixtures.accepted
        revision.document = PreviewFixtures.staticDocument
        let api = ConcurrentPublishProbe()
        let result = try await StickerPublisher(api: api).publish(
            stickerID: "publish-test", revision: revision, assets: .init(), verifiedAssetIDs: []
        )
        defer { result.localExports.forEach { try? FileManager.default.removeItem(at: $0.url) } }
        #expect(await api.maximumInFlight >= 2)
        #expect(await api.registeredAfterUploads)
    }

    @Test("Refreshing an older failed chat preserves the publish failure")
    func transcriptPreservesPublishFailure() async throws {
        let api = FailedTranscriptAPI()
        let store = StickerStore(api: api)
        store.observeExternalJob(jobID: "publish-job", stickerID: api.stickerID)
        try await waitUntil { store.jobs[api.stickerID]?.isTerminal == true }
        await store.loadMessages(stickerID: api.stickerID)
        #expect(store.jobs[api.stickerID]?.jobID == "publish-job")
        #expect(store.jobs[api.stickerID]?.failureMessage == "Animation timing does not match")
        store.reset()
    }

    @Test("A transcript refresh before the send response does not duplicate the user message")
    func refreshedMessageBeforeSendResponse() async throws {
        let api = SlowChatAPI()
        let store = StickerStore(api: api)
        let send = Task {
            try await store.sendMessage(
                stickerID: api.stickerID, content: "Add particles", references: [],
                mask: nil, targetLayerID: nil, intent: .chat
            )
        }
        await api.waitUntilSending()
        let refreshed = await store.loadMessages(stickerID: api.stickerID)
        #expect(refreshed)
        await api.finishSending()
        try await send.value

        let messages = store.messages[api.stickerID] ?? []
        // Identical text from an earlier turn must remain; only server identity is deduplicated.
        #expect(messages.map(\.id) == ["earlier-source-message", "slow-source-message"])
        #expect(messages.last?.sequence == 42)
        #expect(messages.last?.createdAt == Date(timeIntervalSince1970: 1234))
        store.reset()
    }

    @Test("A chat message appears before the network request completes")
    func chatSendIsOptimistic() async throws {
        let api = SlowChatAPI()
        let store = StickerStore(api: api)
        let send = Task {
            try await store.sendMessage(
                stickerID: api.stickerID,
                content: "Add particles",
                references: [],
                mask: nil,
                targetLayerID: nil,
                intent: .chat
            )
        }

        await api.waitUntilSending()
        let optimistic = try #require(store.messages[api.stickerID]?.first)
        #expect(optimistic.id.hasPrefix("local-"))
        #expect(optimistic.content == "Add particles")
        #expect(optimistic.status == .streaming)

        await api.finishSending()
        try await send.value
        let persisted = try #require(store.messages[api.stickerID]?.first)
        #expect(persisted.id == "slow-source-message")
        #expect(persisted.jobId == "slow-job")
    }

    /// A send the server refused created nothing, so the composer is safe to repopulate.
    @Test("A rejected send reports that nothing was delivered")
    func rejectedSendIsNotDelivered() async throws {
        let failure = try await #require(await sendFailure(StickerAPIError.http(422)))
        #expect(failure.mayHaveBeenDelivered == false)
    }

    @Test("A server error envelope also reports that nothing was delivered")
    func envelopeSendIsNotDelivered() async throws {
        let envelope = try JSONDecoder.api.decode(APIErrorEnvelope.self, from: Data("""
        {"error":{"code":"AI_TURN_IN_PROGRESS","message":"Already running","requestId":"req-1"}}
        """.utf8))
        let failure = try await #require(await sendFailure(envelope))
        #expect(failure.mayHaveBeenDelivered == false)
    }

    /// A dropped connection may still have created the turn, so the composer must NOT restore the
    /// text — the user would see their message twice and could send a duplicate.
    @Test("A transport failure reports that the send may have landed")
    func ambiguousSendIsTreatedAsDelivered() async throws {
        let failure = try await #require(await sendFailure(URLError(.timedOut)))
        #expect(failure.mayHaveBeenDelivered == true)
    }

    @MainActor
    private func sendFailure(_ error: any Error) async -> SendMessageFailure? {
        let api = FailingChatAPI(error: error)
        let store = StickerStore(api: api)
        do {
            try await store.sendMessage(
                stickerID: api.stickerID, content: "Add particles",
                references: [], mask: nil, targetLayerID: nil, intent: .chat
            )
            return nil
        } catch let failure as SendMessageFailure {
            // The optimistic row is rolled back however the send failed.
            #expect(store.messages[api.stickerID]?.isEmpty != false)
            return failure
        } catch {
            return nil
        }
    }

    @Test("Mask normalization rejects opaque padding tricks and empty masks")
    func maskSourceAlphaValidation() throws {
        let opaqueFormat = UIGraphicsImageRendererFormat()
        opaqueFormat.opaque = true
        opaqueFormat.scale = 1
        let opaque = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 60), format: opaqueFormat).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
        }
        #expect(throws: MediaNormalizationError.self) {
            try MediaNormalizer.mask(data: try #require(opaque.jpegData(compressionQuality: 0.9)))
        }

        let alphaFormat = UIGraphicsImageRendererFormat()
        alphaFormat.opaque = false
        alphaFormat.scale = 1
        let empty = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 60), format: alphaFormat).image { _ in }
        #expect(throws: MediaNormalizationError.self) {
            try MediaNormalizer.mask(data: try #require(empty.pngData()))
        }

        let valid = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 60), format: alphaFormat).image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 60, height: 60))
        }
        let normalized = try MediaNormalizer.mask(data: try #require(valid.pngData()))
        #expect(normalized.mimeType == "image/png")
        #expect(UIImage(data: normalized.data)?.size == CGSize(width: 1_024, height: 1_024))
    }

    @Test("A failed pre-observe chat request never leaves the sticker computing")
    func preObserveFailureClearsComputing() async throws {
        let api = TurnFailureAPI()
        let store = StickerStore(api: api)
        let stickerID = api.stickerID

        try await store.sendMessage(stickerID: stickerID, content: "first", references: [], mask: nil, targetLayerID: nil)
        try await waitUntil {
            store.jobs[stickerID]?.isFailed == true && !store.computingStickerIDs.contains(stickerID)
        }
        #expect(store.jobs[stickerID]?.isFailed == true)
        #expect(!store.computingStickerIDs.contains(stickerID))

        do {
            try await store.sendMessage(stickerID: stickerID, content: "retry later", references: [], mask: nil, targetLayerID: nil)
            #expect(Bool(false), "The stub's second request must fail")
        } catch {
            try await waitUntil { !store.computingStickerIDs.contains(stickerID) }
            #expect(!store.computingStickerIDs.contains(stickerID))
        }
    }

    @Test("Loading a transcript resumes the latest unfinished job for replay and Retry")
    func transcriptResumesSSE() async throws {
        let api = ResumeJobAPI()
        let store = StickerStore(api: api)
        await store.loadMessages(stickerID: api.stickerID)
        try await waitUntil {
            store.jobs[api.stickerID]?.isFailed == true && !store.computingStickerIDs.contains(api.stickerID)
        }

        #expect(store.jobs[api.stickerID]?.jobID == "resume-job")
        #expect(store.jobs[api.stickerID]?.sourceMessageID == "resume-source")
        #expect(store.jobs[api.stickerID]?.isFailed == true)
        #expect(!store.computingStickerIDs.contains(api.stickerID))
    }

    @Test("A failed transcript reconstructs Retry without reconnecting")
    func failedTranscriptRestoresRetry() async {
        let api = FailedTranscriptAPI()
        let store = StickerStore(api: api)
        await store.loadMessages(stickerID: api.stickerID)

        #expect(store.jobs[api.stickerID]?.jobID == "failed-transcript-job")
        #expect(store.jobs[api.stickerID]?.sourceMessageID == "failed-transcript-source")
        #expect(store.jobs[api.stickerID]?.isFailed == true)
        #expect(!store.computingStickerIDs.contains(api.stickerID))
    }

    @Test("An event this client cannot use never strands the turn")
    func undecodableEventStillResolvesTheTurn() async throws {
        let api = PoisonEventAPI()
        let store = StickerStore(api: api)

        try await store.sendMessage(stickerID: api.stickerID, content: "Make it blue", references: [], mask: nil, targetLayerID: nil)
        try await waitUntil {
            store.messages[api.stickerID]?.contains { $0.role == .assistant } == true
                && !store.computingStickerIDs.contains(api.stickerID)
        }

        // The candidate event carries an invalid document. Dropping that one field must not stop
        // the turn from resolving, which is what leaves the chat silent until a manual refresh.
        #expect(store.messages[api.stickerID]?.contains { $0.role == .assistant } == true)
        #expect(!store.computingStickerIDs.contains(api.stickerID))
        #expect(store.jobs[api.stickerID]?.streamErrorMessage == nil)
    }

    @Test("A stream that dies mid-turn still reconciles against the server")
    func brokenStreamStillReconciles() async throws {
        let api = BrokenStreamAPI()
        let store = StickerStore(api: api)

        try await store.sendMessage(stickerID: api.stickerID, content: "Make it blue", references: [], mask: nil, targetLayerID: nil)
        try await waitUntil {
            store.messages[api.stickerID]?.contains { $0.role == .assistant } == true
                && !store.computingStickerIDs.contains(api.stickerID)
        }

        #expect(store.messages[api.stickerID]?.contains { $0.role == .assistant } == true)
        #expect(!store.computingStickerIDs.contains(api.stickerID))
        // The refetch found the assistant turn, so this is not a user-visible failure.
        #expect(store.jobs[api.stickerID]?.streamErrorMessage == nil)
    }

    @Test("A dead observation can be re-attached instead of staying pinned to a finished job")
    func deadObservationReattaches() async throws {
        let api = BrokenStreamAPI()
        let store = StickerStore(api: api)

        try await store.sendMessage(stickerID: api.stickerID, content: "Make it blue", references: [], mask: nil, targetLayerID: nil)
        try await waitUntil { store.messages[api.stickerID]?.contains { $0.role == .assistant } == true }
        let first = await api.streamCount()

        store.reattach(stickerID: api.stickerID)
        var reattached = await api.streamCount()
        let deadline = ContinuousClock.now + .seconds(10)
        while reattached <= first, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            reattached = await api.streamCount()
        }

        #expect(reattached > first)
    }

    @Test("A confirmed plan stays live while the server is still building it")
    func confirmedPlanSurvivesRepeatedStreamDeaths() async throws {
        let api = LiveTurnStreamAPI()
        let store = StickerStore(api: api)

        try await store.confirmPlan(stickerID: api.stickerID, planID: "live-plan")
        // Five opened streams is two past the re-attach budget. A plan build runs for minutes and
        // reconnects every time the app is backgrounded, so spending that budget says nothing about
        // whether the turn is over — and the server's own word for it, the source message's
        // `streaming` status, still says it is not.
        try await waitUntil(timeout: .seconds(20)) { api.streams.value >= 5 }

        #expect(api.streams.value >= 5)
        #expect(store.computingStickerIDs.contains(api.stickerID))
        // The transcript kept flowing, so the composer must still be showing Stop rather than
        // sitting idle over a build that is still running.
        #expect(store.jobs[api.stickerID]?.isTerminal == false)
        // A stream the system merely cancelled is not something to warn about.
        #expect(store.jobs[api.stickerID]?.streamErrorMessage == nil)

        store.reset()
    }

    /// The chat's waiting card is only as good as what the store keeps, and the store used to keep
    /// none of this: `stage`, the label and the counts were decoded and then dropped, so a turn that
    /// was audibly busy on the Lock Screen was three dots in the app.
    @Test("A stage and its count reach the job the chat draws from")
    func stageAndCountsAreKept() async throws {
        let api = StagedProgressAPI(events: [
            .init(stage: "preparing_context"),
            .init(note: "Drawing the artwork from 2 references", outputTokens: 120),
            .init(note: "Saved the artwork", outputTokens: 80, imagesDrawn: 1),
            .init(stage: "composing", completedUnits: 2, totalUnits: 5, progressLabel: "Artwork parts")
        ])
        let store = StickerStore(api: api)

        try await store.confirmPlan(stickerID: api.stickerID, planID: "staged-plan")
        try await waitUntil { store.jobs[api.stickerID]?.completedUnits == 2 }

        let job = store.jobs[api.stickerID]
        #expect(job?.statusDetail == "Composing the artwork")
        #expect(job?.progressLabel == "Artwork parts")
        #expect(job?.progressCountText == "2/5")
        #expect(job?.unitProgress == 0.4)
        // A new stage retires the old note; the spend is a sum of every delta that arrived.
        #expect(job?.note == nil)
        #expect(job?.outputTokens == 200)
        #expect(job?.imagesDrawn == 1)

        store.reset()
    }

    /// Counts belong to the stage that reported them. A stage that clears them and does not count
    /// must leave no bar behind, or the card shows 2/5 of work that is already finished.
    @Test("A cleared count leaves no progress behind, and a message outranks its stage")
    func clearedCountsAndMessagePrecedence() async throws {
        let api = StagedProgressAPI(events: [
            .init(stage: "composing", completedUnits: 2, totalUnits: 5, progressLabel: "Artwork parts"),
            .init(message: "Finishing your sticker…", stage: "finalizing", clearProgress: true)
        ])
        let store = StickerStore(api: api)

        try await store.confirmPlan(stickerID: api.stickerID, planID: "staged-plan")
        try await waitUntil { store.jobs[api.stickerID]?.statusDetail == "Finishing your sticker…" }

        let job = store.jobs[api.stickerID]
        #expect(job?.completedUnits == nil)
        #expect(job?.totalUnits == nil)
        #expect(job?.progressLabel == nil)
        #expect(job?.unitProgress == nil)
        #expect(job?.progressCountText == nil)

        store.reset()
    }

    @Test("Library requests each sticker page separately as the user reaches it")
    func libraryPagination() async {
        let api = PaginatedLibraryAPI()
        let store = StickerStore(api: api)

        await store.refresh()
        #expect(store.stickers.map(\.id) == ["page-1"])
        #expect(store.nextStickerCursor == "2")
        #expect(await api.requestedCursors() == ["<first>"])

        await store.loadMoreStickers()
        #expect(store.stickers.map(\.id) == ["page-1", "page-2"])
        #expect(store.nextStickerCursor == "3")
        #expect(await api.requestedCursors() == ["<first>", "2"])

        await store.loadMoreStickers()
        #expect(store.stickers.map(\.id) == ["page-1", "page-2", "page-3"])
        #expect(store.nextStickerCursor == nil)
        #expect(await api.requestedCursors() == ["<first>", "2", "3"])

        // Once the server ends the listing, another sentinel event is a no-op.
        await store.loadMoreStickers()
        #expect(await api.requestedCursors() == ["<first>", "2", "3"])
    }

    @Test("The pack picker pages published stickers and restarts paging on a new search")
    func packStickerPickerPaging() async {
        let api = PublishedStickerPickerAPI()
        let model = StickerPickerModel(api: api)

        await model.load(query: "", debounce: .zero)
        #expect(model.stickers.map(\.id) == ["published-1"])
        #expect(model.nextCursor == "2")

        await model.loadMore()
        #expect(model.stickers.map(\.id) == ["published-1", "published-2"])
        #expect(model.nextCursor == nil)
        #expect(await api.requestedPages() == ["<all>:<first>", "<all>:2"])

        // A finished listing means the sentinel can fire again without asking for anything.
        await model.loadMore()
        #expect(await api.requestedPages().count == 2)

        // Searching is a fresh listing, not an append: the previous page must not linger under it.
        await model.load(query: "  cat  ", debounce: .zero)
        #expect(model.stickers.map(\.id) == ["published-1"])
        #expect(await api.requestedPages().last == "cat:<first>")

        await model.loadMore()
        #expect(await api.requestedPages().last == "cat:2")
    }

    @Test("The Marketplace pages both feeds and stops when the server repeats a cursor")
    func marketplacePagination() async {
        let api = PagedPacksAPI()
        let store = MarketplaceStore(api: api)

        await store.refresh()
        #expect(store.packs.map(\.id) == ["browse-1"])
        #expect(store.myPacks.map(\.id) == ["mine-1"])
        #expect(store.nextCursor == "2")
        #expect(store.nextMyPacksCursor == "2")

        await store.loadMore()
        #expect(store.packs.map(\.id) == ["browse-1", "browse-2"])
        #expect(store.nextCursor == nil)

        await store.loadMoreMyPacks()
        #expect(store.myPacks.map(\.id) == ["mine-1", "mine-2"])
        // The stub answers the second page with the cursor it was given; repeating it must end the
        // feed rather than leave the sentinel asking for the same page forever.
        #expect(store.nextMyPacksCursor == nil)

        let requests = await api.requestedPages()
        await store.loadMoreMyPacks()
        #expect(await api.requestedPages() == requests)
    }

    @Test("A published pack can still be renamed, reordered, and taken back to draft")
    func editPublishedPack() async throws {
        let api = EditablePackAPI()
        let store = MarketplaceStore(api: api)
        await store.refresh()
        #expect(store.myPacks.map(\.title) == ["Cozy Cats"])

        await store.loadDetail(packID: EditablePackAPI.packID)
        let originalSlug = store.details[EditablePackAPI.packID]?.slug

        try await store.updateDetails(packID: EditablePackAPI.packID, title: "Cozier Cats", summary: nil)
        #expect(store.details[EditablePackAPI.packID]?.title == "Cozier Cats")
        // The list behind the detail screen holds the same pack, and a rename it did not hear about
        // would leave the old title on the tile the reader came from.
        #expect(store.myPacks.map(\.title) == ["Cozier Cats"])
        // The slug is the shared link, so it survives a rename — a URL somebody already sent must
        // not break because the pack was renamed after they got it.
        #expect(store.details[EditablePackAPI.packID]?.slug == originalSlug)

        let reversed = (store.details[EditablePackAPI.packID]?.stickers ?? []).map(\.id).reversed()
        try await store.setItems(packID: EditablePackAPI.packID, stickerIDs: Array(reversed))
        #expect(store.details[EditablePackAPI.packID]?.stickers.map(\.id) == Array(reversed))

        try await store.unpublish(packID: EditablePackAPI.packID)
        #expect(store.details[EditablePackAPI.packID]?.state == .draft)
        #expect(store.myPacks.first?.state == .draft)
    }

    @Test("Clearing a pack description sends an explicit null rather than nothing at all")
    func updatePackRequestEncodesAClearedSummary() throws {
        // The server reads an absent field as "leave it alone", so a dropped nil would make erasing
        // a description the one edit that silently did nothing.
        let encoded = try JSONEncoder.api.encode(UpdatePackRequest(title: "Cozier Cats", summary: nil))
        let json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["title"] as? String == "Cozier Cats")
        #expect(json["summary"] is NSNull)

        let rewritten = try JSONEncoder.api.encode(UpdatePackRequest(title: "Cozier Cats", summary: "Now with dogs."))
        let rewrittenJSON = try #require(try JSONSerialization.jsonObject(with: rewritten) as? [String: Any])
        #expect(rewrittenJSON["summary"] as? String == "Now with dogs.")
    }

    @Test("A pack tile is the same height whatever its cover holds")
    func packCardHeightIsIndependentOfItsCover() {
        // A cover that took its height from the artwork gave the same pack two different tiles:
        // a short one while its cells still held spinners, a tall one once the images were cached.
        // Coming back from a search — where the artwork is already in hand — is where it showed.
        let empty = Self.packCardHeight(coverStickers: [])
        let single = Self.packCardHeight(coverStickers: [PreviewFixtures.borrowedSticker])
        let full = Self.packCardHeight(coverStickers: Array(repeating: PreviewFixtures.borrowedSticker, count: 4))
        let withArtwork = Self.packCardHeight(coverStickers: (0..<4).map { index in
            var sticker = PreviewFixtures.borrowedSticker
            sticker.id = "cover-\(index)"
            sticker.previewAsset = AssetRecord(
                id: "asset-\(index)",
                stickerId: sticker.id,
                kind: .preview,
                state: .ready,
                mimeType: "image/png",
                sha256: nil
            )
            return sticker
        })

        #expect(single == empty)
        #expect(full == empty)
        #expect(withArtwork == empty)
    }

    @MainActor
    private static func packCardHeight(coverStickers: [Sticker]) -> CGFloat {
        var pack = PreviewFixtures.pack
        pack.coverStickers = coverStickers
        let renderer = ImageRenderer(
            content: PackCard(pack: pack, api: MockStickerAPIClient()).frame(width: 165)
        )
        renderer.scale = 1
        return renderer.uiImage?.size.height ?? 0
    }

    @Test("Marketplace search reaches both feeds and clearing it reloads them")
    func marketplaceSearch() async {
        let api = SearchablePacksAPI()
        let store = MarketplaceStore(api: api)

        await store.refresh()
        #expect(store.packs.map(\.title) == ["Cozy Cats", "Angry Dogs"])
        #expect(store.myPacks.map(\.title) == ["My Cats"])
        #expect(store.appliedQuery.isEmpty)

        // "My packs" used to ignore the query outright, so its feed is asserted alongside browse.
        store.searchQuery = "  cats  "
        await store.refresh()
        #expect(store.packs.map(\.title) == ["Cozy Cats"])
        #expect(store.myPacks.map(\.title) == ["My Cats"])
        #expect(store.appliedQuery == "cats")

        // Dismissing the search field clears the text without submitting. The results have to come
        // back, and the empty state has to stop claiming a search is in effect.
        store.searchQuery = ""
        await store.refresh()
        #expect(store.packs.map(\.title) == ["Cozy Cats", "Angry Dogs"])
        #expect(store.appliedQuery.isEmpty)

        #expect(await api.browseQueries() == [nil, "cats", nil])
        #expect(await api.mineQueries() == [nil, "cats", nil])
    }

    @Test("A search started while a reload is in flight is not answered by the old one")
    func marketplaceSearchSupersedesInFlightRefresh() async throws {
        let api = SearchablePacksAPI()
        let store = MarketplaceStore(api: api)
        await api.hold()

        let first = Task { await store.refresh() }
        try await waitForBrowseRequests(api, count: 1)

        store.searchQuery = "cats"
        let second = Task { await store.refresh() }
        try await waitForBrowseRequests(api, count: 2)
        await api.release()
        _ = await (first.value, second.value)

        // Both requests were made and the search's answer is the one on screen: sharing the
        // in-flight reload was what left a typed query showing the unfiltered feed.
        #expect(store.packs.map(\.title) == ["Cozy Cats"])
        #expect(store.appliedQuery == "cats")
    }

    /// `waitUntil` takes a synchronous condition, and asking an actor stub how many requests it has
    /// seen is not one.
    private func waitForBrowseRequests(
        _ api: SearchablePacksAPI,
        count: Int,
        timeout: Duration = .seconds(10)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await api.browseQueries().count >= count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("Renaming updates detail, Library, and active search caches together")
    func renameSticker() async {
        let api = MockStickerAPIClient()
        let store = StickerStore(api: api)
        await store.refresh()
        await store.loadDetail(stickerID: PreviewFixtures.sticker.id)
        await store.searchLibrary(query: "Happy", debounce: .zero)

        let renamed = await store.rename(stickerID: PreviewFixtures.sticker.id, title: "  Bouncy Cloud  ")

        #expect(renamed)
        #expect(store.stickers.first?.title == "Bouncy Cloud")
        #expect(store.librarySearchResults.first?.title == "Bouncy Cloud")
        #expect(store.details[PreviewFixtures.sticker.id]?.title == "Bouncy Cloud")
        #expect(store.errorMessage == nil)
    }

    @Test("Library search uses remote owned and installed-pack results")
    func remoteLibrarySearch() async {
        let api = RemoteSearchLibraryAPI()
        let store = StickerStore(api: api)

        await store.searchLibrary(query: "  cloud  ", debounce: .zero)

        #expect(store.activeLibrarySearchQuery == "cloud")
        #expect(store.librarySearchResults.map(\.title) == ["Blue Cloud"])
        #expect(store.librarySearchSections.map(\.title) == ["Weather Cats"])
        #expect(store.librarySearchSections[0].stickers.map(\.title) == ["Cloud Cat"])
        #expect(store.nextLibrarySearchCursor == "second")
        #expect(await api.requestedPages() == ["cloud:<first>"])

        await store.loadMoreLibrarySearchResults()
        #expect(store.librarySearchResults.map(\.title) == ["Blue Cloud", "Cloud Nine"])
        #expect(store.nextLibrarySearchCursor == nil)
        #expect(await api.requestedPages() == ["cloud:<first>", "cloud:second"])

        store.clearLibrarySearch()
        #expect(store.activeLibrarySearchQuery == nil)
        #expect(store.librarySearchResults.isEmpty)
        #expect(store.librarySearchSections.isEmpty)
    }

    @Test("A cancelled Library refresh keeps its content and does not show an error")
    func cancelledLibraryRefreshIsSilent() async {
        let api = CancelledLibraryAPI()
        let store = StickerStore(api: api)
        await store.refresh()

        await store.refresh()

        #expect(store.stickers.map(\.id) == [api.stickerID])
        #expect(store.errorMessage == nil)
        #expect(!store.isLoading)
    }

    /// The alert is not the whole story. It is dismissed within a second of appearing, and what it
    /// leaves behind on a dead network is an empty grid that reads as an empty account — with no
    /// list on screen, and therefore no pull-to-refresh, to say otherwise.
    @Test("A library that could not load says so after its alert is dismissed, and clears on retry")
    func offlineLibraryKeepsItsFailureForTheRetry() async {
        let api = OfflineLibraryAPI()
        let store = StickerStore(api: api)

        await store.refresh()
        #expect(store.stickers.isEmpty)
        #expect(store.errorMessage != nil)
        #expect(store.libraryLoadFailure != nil)

        // The alert's OK button, which must not take the reason for the empty screen with it.
        store.errorMessage = nil
        #expect(store.libraryLoadFailure != nil)

        await store.refresh()
        #expect(store.stickers.map(\.id) == [api.stickerID])
        #expect(store.libraryLoadFailure == nil)
    }

    /// Credits are spent by the server, so nothing on the client knows the balance moved unless it
    /// is told to look. Both ends of the turn are worth a look: the debit lands as it starts, and a
    /// failure is refunded by the time it ends.
    @Test("A generation asks for the credit balance at both ends of the turn")
    func generationRefreshesTheCreditBalance() async throws {
        let api = FailedTranscriptAPI()
        let store = StickerStore(api: api)
        var checks = 0
        store.onCreditsMayHaveChanged = { checks += 1 }

        store.observeExternalJob(jobID: "publish-job", stickerID: api.stickerID)
        #expect(checks == 1)

        try await waitUntil { store.jobs[api.stickerID]?.isTerminal == true }
        #expect(checks > 1)
        store.reset()
    }

    @Test("Failed cleanup dispatch keeps the local sticker and surfaces retry")
    func failedDeletionKeepsSticker() async {
        let api = DeleteFailureAPI()
        let store = StickerStore(api: api)
        await store.refresh()

        let deleted = await store.delete(stickerID: api.stickerID)

        #expect(!deleted)
        #expect(store.stickers.contains { $0.id == api.stickerID })
        #expect(store.errorMessage?.contains("unchanged") == true)
    }

    @Test("Publisher refuses a missing or unverified image asset")
    func publisherRequiresVerifiedAssets() async {
        var revision = PreviewFixtures.candidate
        revision.candidateState = .accepted
        // The layer that names an asset is what this test is about, and the composite fixture no
        // longer carries one: without it the publisher has nothing to refuse, and the test quietly
        // rendered a complete export set instead of checking anything.
        revision.document.layers.append(.image(.init(
            base: .init(id: "hero", name: "Hero"),
            assetId: PreviewFixtures.imageAssetID
        )))
        let publisher = StickerPublisher(api: MockStickerAPIClient())
        do {
            _ = try await publisher.publish(
                stickerID: PreviewFixtures.sticker.id,
                revision: revision,
                assets: .init(),
                verifiedAssetIDs: []
            )
            #expect(Bool(false), "Publishing with a placeholder must fail")
        } catch let error as StickerPublishError {
            guard case .missingVerifiedAssets(let missing) = error else {
                #expect(Bool(false), "Expected missing verified assets")
                return
            }
            #expect(missing == [PreviewFixtures.imageAssetID])
        } catch {
            #expect(Bool(false), "Unexpected publisher error: \(error)")
        }
    }

    @Test("Animated base images cannot publish until motion exists")
    func animatedPublishGate() async {
        let base = PreviewFixtures.accepted
        #expect(!base.containsMotion)
        #expect(!base.canPublishExports)

        var animated = PreviewFixtures.candidate
        animated.candidateState = .accepted
        #expect(animated.containsMotion)
        #expect(animated.canPublishExports)

        let publisher = StickerPublisher(api: MockStickerAPIClient())
        do {
            _ = try await publisher.publish(
                stickerID: PreviewFixtures.sticker.id,
                revision: base,
                assets: .init(),
                verifiedAssetIDs: []
            )
            #expect(Bool(false), "Publishing an animation-free base must fail before upload")
        } catch let error as StickerPublishError {
            guard case .animationRequired = error else {
                #expect(Bool(false), "Expected the animation publish gate")
                return
            }
        } catch {
            #expect(Bool(false), "Unexpected publisher error: \(error)")
        }
    }

    @Test("Animation-free local export produces one PNG without publishing")
    func animationFreeLocalExport() async throws {
        var revision = PreviewFixtures.accepted
        revision.document.layers = [
            .shape(.init(
                base: .init(id: "base", name: "Base"),
                shape: .roundedRectangle,
                fill: .solid("#A88BFF"),
                cornerRadius: 0.2
            ))
        ]
        let exports = try await StickerPublisher(api: MockStickerAPIClient()).export(
            revision: revision,
            assets: .init(),
            verifiedAssetIDs: []
        )
        defer { exports.forEach { try? FileManager.default.removeItem(at: $0.url) } }

        #expect(exports.count == 1)
        #expect(exports.first?.metadata.format == .png)
        #expect(exports.first?.metadata.hasAlpha == true)
    }

    @Test("Published export state requires the sticker renditions, but not the video")
    func publishedExportStateRequiresTheStickerRenditions() {
        var revision = PreviewFixtures.candidate
        revision.candidateState = .accepted
        revision.apngAssetId = "apng"
        revision.mp4AssetId = "mp4"
        revision.systemAssetId = "system"
        #expect(revision.hasPublishedExports)
        #expect(revision.hasPublishedVideo)

        // A sticker-only publish never encoded a video. The sticker is published all the same —
        // nothing on the platform reads the MP4, and one can be rendered later for a share.
        revision.mp4AssetId = nil
        #expect(revision.hasPublishedExports)
        #expect(!revision.hasPublishedVideo)

        // The sharing rendition is not optional: it is what every surface outside Messages shows.
        revision.apngAssetId = nil
        #expect(!revision.hasPublishedExports)

        // A revision published before APNG replaced GIF resolves through the legacy column, and is
        // no less published for it.
        revision.gifAssetId = "gif"
        #expect(revision.hasPublishedExports)
    }

    @Test("Accepting a candidate updates the active revision")
    func revisionTransition() async throws {
        let store = StickerStore(api: MockStickerAPIClient())
        await store.loadDetail(stickerID: PreviewFixtures.sticker.id)
        try await store.transition(stickerID: PreviewFixtures.sticker.id, revisionID: PreviewFixtures.candidate.id, action: .accept)
        #expect(store.details[PreviewFixtures.sticker.id]?.activeRevisionId == PreviewFixtures.candidate.id)
    }
}

private actor ConcurrentPublishProbe: StickerAPIClientProtocol {
    var inFlight = 0
    var maximumInFlight = 0
    var completed: Set<String> = []
    var registeredAfterUploads = false

    func upload(data: Data, stickerID: String?, kind: AssetKind, filename: String, mimeType: String, sequence: SequenceMetadata?, idempotencyKey: String) async throws -> String {
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        defer { inFlight -= 1 }
        try await Task.sleep(for: .milliseconds(100))
        let id = UUID().uuidString
        completed.insert(id)
        return id
    }

    func registerExport(stickerID: String, request: PublishExportsRequest, idempotencyKey: String) async throws -> PublishExportsResponse {
        let required = [request.pngAssetId, request.systemAssetId].compactMap { $0 }
        registeredAfterUploads = inFlight == 0 && required.count == 2 && required.allSatisfy { completed.contains($0) }
        return .init(job: .init(id: "published", state: .queued, eventsUrl: "/events"))
    }
}
