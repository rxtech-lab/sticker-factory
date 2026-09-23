import AnimatedView
import CryptoKit
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import StickerGeniOS

// Stubs, fixtures and API doubles shared by the tests in this target.

struct APIFixture: Decodable {
    var stickerList: Page<Sticker>
    var assetDownload: AssetDownload
    var chatMessages: ChatMessagePage
    var publishExports: PublishExportsRequest
    var packList: Page<StickerPack>
    var packDetail: StickerPackDetail
    var librarySections: LibrarySectionsResponse
}

final class FixtureBundleToken: NSObject {}
enum TestFixtureError: Error { case missing(String), stub }

func fixtureData(_ name: String) throws -> Data {
    let bundle = Bundle(for: FixtureBundleToken.self)
    guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        ?? bundle.url(forResource: name, withExtension: "json")
    else { throw TestFixtureError.missing(name) }
    return try Data(contentsOf: url)
}

func uniqueLockURL() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "sticker-auth-test-\(UUID().uuidString).lock")
}

func jwt(subject: String, expiresAt: Date) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: ["sub": subject, "exp": expiresAt.timeIntervalSince1970])
    let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "header.\(payload).signature"
}

final class InMemoryTokenVault: SharedTokenVaultProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var bundle: SharedTokenBundle?

    init(_ bundle: SharedTokenBundle? = nil) { self.bundle = bundle }

    func load() throws -> SharedTokenBundle? {
        lock.lock(); defer { lock.unlock() }
        return bundle
    }

    func replace(with bundle: SharedTokenBundle) throws {
        lock.lock(); defer { lock.unlock() }
        self.bundle = bundle
    }

    func clear() throws {
        lock.lock(); defer { lock.unlock() }
        bundle = nil
    }
}

// A lock rather than an actor. `OAuthRefreshTransport` is a `nonisolated` protocol, and an actor
// conforming to one picks up an implicit `nonisolated` that the compiler then rejects on both the
// actor and its synchronous initialiser. Counting calls needs mutual exclusion, not an isolation
// domain, so this follows `InMemoryTokenVault` above.
final class CountingRefreshTransport: OAuthRefreshTransport, @unchecked Sendable {
    let response: OAuthRefreshResponse
    let delay: Duration?
    private let lock = NSLock()
    private var calls = 0

    init(response: OAuthRefreshResponse, delay: Duration? = nil) {
        self.response = response
        self.delay = delay
    }

    func refresh(tokenURL: URL, clientID: String, refreshToken: String) async throws -> OAuthRefreshResponse {
        // `withLock` rather than a bare lock/unlock pair: the latter is unavailable from an async
        // context, since a suspension between the two would leave the lock held across a hop.
        lock.withLock { calls += 1 }
        if let delay { try await Task.sleep(for: delay) }
        return response
    }

    func callCount() -> Int { lock.withLock { calls } }
}

struct RejectingRefreshTransport: OAuthRefreshTransport {
    func refresh(tokenURL: URL, clientID: String, refreshToken: String) async throws -> OAuthRefreshResponse {
        throw TokenBrokerError.refreshRejected(400)
    }
}

final class NotificationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func mark() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

actor VideoFrameLoadProbe {
    private(set) var loadCount = 0

    func recordLoad() {
        loadCount += 1
    }
}

actor VideoFrameCacheAPI: StickerAPIClientProtocol {}

extension StickerAPIClientProtocol {
    func selectPlanVersion(stickerID: String, versionID: String, request: SelectPlanVersionRequest, idempotencyKey: String) async throws -> SelectPlanVersionResponse { throw TestFixtureError.stub }
    func planVersions(stickerID: String) async throws -> Page<PlanRecord> { throw TestFixtureError.stub }
    func editPlan(stickerID: String, planID: String, request: PlanEditRequest, idempotencyKey: String) async throws -> EditPlanResponse { throw TestFixtureError.stub }
    func listStickers(cursor: String?) async throws -> Page<Sticker> { throw TestFixtureError.stub }
    func searchStickers(query: String, cursor: String?) async throws -> Page<Sticker> { throw TestFixtureError.stub }
    func publishedStickers(query: String?, cursor: String?) async throws -> Page<Sticker> { throw TestFixtureError.stub }
    func createSticker(_ request: CreateStickerRequest, idempotencyKey: String) async throws -> CreateStickerResponse { throw TestFixtureError.stub }
    func importSticker(_ request: ImportStickerRequest, idempotencyKey: String) async throws -> ImportStickerResponse { throw TestFixtureError.stub }
    func sticker(id: String) async throws -> StickerDetail { throw TestFixtureError.stub }
    func stickerPlayback(stickerID: String, revisionID: String?) async throws -> StickerPlaybackBundle { throw TestFixtureError.stub }
    func updateSticker(id: String, request: UpdateStickerRequest, idempotencyKey: String) async throws -> StickerDetail { throw TestFixtureError.stub }
    func deleteSticker(id: String, idempotencyKey: String) async throws -> DeleteStickerResponse { throw TestFixtureError.stub }
    func chatMessages(stickerID: String, beforeSequence: Int?) async throws -> ChatMessagePage { throw TestFixtureError.stub }
    func sendChatMessage(stickerID: String, request: SendChatMessageRequest, idempotencyKey: String) async throws -> SendChatMessageResponse { throw TestFixtureError.stub }
    func retryChatMessage(stickerID: String, messageID: String, idempotencyKey: String) async throws -> RetryChatMessageResponse { throw TestFixtureError.stub }
    func confirmPlan(stickerID: String, planID: String, idempotencyKey: String) async throws -> ConfirmPlanResponse { throw TestFixtureError.stub }
    func cancelPlan(stickerID: String, planID: String, reason: String?, idempotencyKey: String) async throws -> CancelPlanResponse { throw TestFixtureError.stub }
    func cancelGeneration(jobID: String, idempotencyKey: String) async throws -> CancelGenerationResponse { throw TestFixtureError.stub }
    func transitionRevision(stickerID: String, revisionID: String, action: RevisionAction, idempotencyKey: String) async throws -> RevisionTransitionResponse { throw TestFixtureError.stub }
    func registerExport(stickerID: String, request: PublishExportsRequest, idempotencyKey: String) async throws -> PublishExportsResponse { throw TestFixtureError.stub }
    func bindMessengerRenditions(stickerID: String, request: MessengerRenditionsRequest, idempotencyKey: String) async throws -> Sticker { throw TestFixtureError.stub }
    func saveEditedDocument(stickerID: String, request: SaveEditedDocumentRequest, idempotencyKey: String) async throws -> SaveEditedDocumentResponse { throw TestFixtureError.stub }
    func upload(data: Data, stickerID: String?, kind: AssetKind, filename: String, mimeType: String, sequence: SequenceMetadata?, idempotencyKey: String) async throws -> String { throw TestFixtureError.stub }
    func assetDownload(assetID: String) async throws -> AssetDownload { throw TestFixtureError.stub }
    nonisolated func generationEvents(jobID: String, after lastEventID: Int64?) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    /// Silent rather than throwing: enrolling for push is something the app does alongside every
    /// other request, and a stub with no opinion about it must not fail a test about the library.
    func registerDevice(token: String, environment: PushEnvironment, bundleID: String?, appVersion: String?) async throws {}
    func unregisterDevice(token: String) async throws {}

    /// Nothing pending rather than throwing: account deletion is a state every double is asked
    /// about and none of them is a test *about*, and a stub that throws here fails suites that
    /// only wanted to exercise the library.
    func accountDeletionState() async throws -> AccountDeletionState { .none }
    func requestAccountDeletion() async throws -> AccountDeletionState { .none }
    func cancelAccountDeletion() async throws -> AccountDeletionState { .none }

    func marketplacePacks(sort: PackSort, query: String?, cursor: String?) async throws -> Page<StickerPack> { throw TestFixtureError.stub }
    func myPacks(query: String?, cursor: String?) async throws -> Page<StickerPack> { throw TestFixtureError.stub }
    func packsByCreator(handle: String, cursor: String?) async throws -> CreatorPacksResponse { throw TestFixtureError.stub }
    func pack(id: String) async throws -> StickerPackDetail { throw TestFixtureError.stub }
    func createPack(_ request: CreatePackRequest, idempotencyKey: String) async throws -> StickerPackDetail { throw TestFixtureError.stub }
    func updatePack(id: String, request: UpdatePackRequest, idempotencyKey: String) async throws -> StickerPackDetail { throw TestFixtureError.stub }
    func setPackItems(id: String, stickerIDs: [String], idempotencyKey: String) async throws -> StickerPackDetail { throw TestFixtureError.stub }
    func publishPack(id: String, idempotencyKey: String) async throws -> StickerPackDetail { throw TestFixtureError.stub }
    func unpublishPack(id: String, state: PackState, idempotencyKey: String) async throws -> StickerPackDetail { throw TestFixtureError.stub }
    func deletePack(id: String, idempotencyKey: String) async throws -> DeletePackResponse { throw TestFixtureError.stub }
    func installPack(id: String, idempotencyKey: String) async throws -> InstallPackResponse { throw TestFixtureError.stub }
    func uninstallPack(id: String, idempotencyKey: String) async throws -> InstallPackResponse { throw TestFixtureError.stub }
    /// Empty rather than throwing: `StickerStore.refresh()` now reloads sections alongside the
    /// paged library, and a stub that has nothing to say about packs must not turn every existing
    /// library test into a failure.
    func librarySections(status: LibrarySectionStatus) async throws -> LibrarySectionsResponse {
        .init(sections: [], generatedAt: Date())
    }
    func searchLibrarySections(query: String, status: LibrarySectionStatus) async throws -> LibrarySectionsResponse {
        .init(sections: [], generatedAt: Date())
    }
}

actor PaginatedLibraryAPI: StickerAPIClientProtocol {
    private var cursors: [String] = []

    func listStickers(cursor: String?) async throws -> Page<Sticker> {
        cursors.append(cursor ?? "<first>")
        let index = cursor.flatMap(Int.init) ?? 1
        let sticker = Sticker(
            id: "page-\(index)", title: "Page \(index)", kind: .static, status: .published,
            activeRevisionId: nil, createdAt: Date(), updatedAt: Date(), previewAsset: nil, systemSticker: nil
        )
        return .init(data: [sticker], nextCursor: index < 3 ? String(index + 1) : nil)
    }

    func requestedCursors() -> [String] { cursors }
}

actor PagedPacksAPI: StickerAPIClientProtocol {
    private var pages: [String] = []

    func marketplacePacks(sort: PackSort, query: String?, cursor: String?) async throws -> Page<StickerPack> {
        pages.append("browse:\(cursor ?? "<first>")")
        return page(prefix: "browse", cursor: cursor)
    }

    func myPacks(query: String?, cursor: String?) async throws -> Page<StickerPack> {
        pages.append("mine:\(cursor ?? "<first>")")
        // The second page deliberately answers with the cursor it was handed, which is how a server
        // that has run out of pages without saying so looks from here.
        return page(prefix: "mine", cursor: cursor, repeatsCursor: true)
    }

    func requestedPages() -> [String] { pages }

    private func page(prefix: String, cursor: String?, repeatsCursor: Bool = false) -> Page<StickerPack> {
        let index = cursor.flatMap(Int.init) ?? 1
        var pack = PreviewFixtures.pack
        pack.id = "\(prefix)-\(index)"
        let next = index < 2 ? String(index + 1) : (repeatsCursor ? cursor : nil)
        return .init(data: [pack], nextCursor: next)
    }
}

/// One published pack the creator owns, which every authoring call mutates in place — so a store
/// test sees what a second read of the same pack would really return.
actor EditablePackAPI: StickerAPIClientProtocol {
    static let packID = "pack-mine"

    private var detail: StickerPackDetail = {
        var detail = PreviewFixtures.packDetail
        detail.id = EditablePackAPI.packID
        detail.title = "Cozy Cats"
        detail.state = .published
        detail.isMine = true
        detail.stickers = [PreviewFixtures.sticker, PreviewFixtures.borrowedSticker]
        detail.itemCount = 2
        return detail
    }()

    func marketplacePacks(sort: PackSort, query: String?, cursor: String?) async throws -> Page<StickerPack> {
        .init(data: detail.state == .published ? [detail.pack] : [], nextCursor: nil)
    }

    func myPacks(query: String?, cursor: String?) async throws -> Page<StickerPack> {
        .init(data: [detail.pack], nextCursor: nil)
    }

    func pack(id: String) async throws -> StickerPackDetail { detail }

    func updatePack(id: String, request: UpdatePackRequest, idempotencyKey: String) async throws -> StickerPackDetail {
        // The slug is deliberately left alone, exactly as the server leaves it: it is the public
        // link, and a rename must never break a URL somebody already shared.
        if let title = request.title { detail.title = title }
        detail.summary = request.summary
        detail.updatedAt = Date()
        return detail
    }

    func setPackItems(id: String, stickerIDs: [String], idempotencyKey: String) async throws -> StickerPackDetail {
        detail.stickers = stickerIDs.compactMap { wanted in detail.stickers.first { $0.id == wanted } }
        detail.itemCount = detail.stickers.count
        detail.coverStickers = Array(detail.stickers.prefix(4))
        return detail
    }

    func publishPack(id: String, idempotencyKey: String) async throws -> StickerPackDetail {
        detail.state = .published
        detail.publishedAt = detail.publishedAt ?? Date()
        return detail
    }

    func unpublishPack(id: String, state: PackState, idempotencyKey: String) async throws -> StickerPackDetail {
        detail.state = state == .unlisted ? .unlisted : .draft
        return detail
    }
}

/// A marketplace that answers both feeds by title, and can be held open mid-request so a second
/// reload can overtake the first.
actor SearchablePacksAPI: StickerAPIClientProtocol {
    private var browse: [String?] = []
    private var mine: [String?] = []
    private var isHolding = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func hold() { isHolding = true }

    func release() {
        isHolding = false
        for continuation in waiting { continuation.resume() }
        waiting = []
    }

    func browseQueries() -> [String?] { browse }
    func mineQueries() -> [String?] { mine }

    func marketplacePacks(sort: PackSort, query: String?, cursor: String?) async throws -> Page<StickerPack> {
        browse.append(query)
        await waitForRelease()
        return .init(data: Self.packs(titled: ["Cozy Cats", "Angry Dogs"], matching: query), nextCursor: nil)
    }

    func myPacks(query: String?, cursor: String?) async throws -> Page<StickerPack> {
        mine.append(query)
        await waitForRelease()
        return .init(data: Self.packs(titled: ["My Cats"], matching: query), nextCursor: nil)
    }

    private func waitForRelease() async {
        guard isHolding else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private static func packs(titled titles: [String], matching query: String?) -> [StickerPack] {
        titles
            .filter { query.map($0.localizedCaseInsensitiveContains) ?? true }
            .map { title in
                var pack = PreviewFixtures.pack
                pack.id = title
                pack.title = title
                return pack
            }
    }
}

actor PublishedStickerPickerAPI: StickerAPIClientProtocol {
    private var pages: [String] = []

    func publishedStickers(query: String?, cursor: String?) async throws -> Page<Sticker> {
        pages.append("\(query ?? "<all>"):\(cursor ?? "<first>")")
        let index = cursor.flatMap(Int.init) ?? 1
        return .init(data: [
            .init(
                id: "published-\(index)",
                title: "Published \(index)",
                kind: .static,
                status: .published,
                activeRevisionId: nil,
                createdAt: Date(),
                updatedAt: Date(),
                previewAsset: nil,
                systemSticker: nil
            )
        ], nextCursor: index < 2 ? String(index + 1) : nil)
    }

    func requestedPages() -> [String] { pages }
}

actor RemoteSearchLibraryAPI: StickerAPIClientProtocol {
    private var pages: [String] = []

    func searchStickers(query: String, cursor: String?) async throws -> Page<Sticker> {
        pages.append("\(query):\(cursor ?? "<first>")")
        let title = cursor == nil ? "Blue Cloud" : "Cloud Nine"
        return .init(data: [
            .init(
                id: cursor == nil ? "cloud-first" : "cloud-second",
                title: title,
                kind: .static,
                status: .published,
                activeRevisionId: nil,
                createdAt: Date(),
                updatedAt: Date(),
                previewAsset: nil,
                systemSticker: nil
            )
        ], nextCursor: cursor == nil ? "second" : nil)
    }

    func searchLibrarySections(query: String, status: LibrarySectionStatus) async throws -> LibrarySectionsResponse {
        var sticker = PreviewFixtures.borrowedSticker
        sticker.title = "Cloud Cat"
        var section = PreviewFixtures.installedSection
        section.title = "Weather Cats"
        section.stickers = [sticker]
        return .init(sections: [section], generatedAt: Date())
    }

    func requestedPages() -> [String] { pages }
}

actor CancelledLibraryAPI: StickerAPIClientProtocol {
    nonisolated let stickerID = "cancelled-refresh-sticker"
    private var calls = 0

    func listStickers(cursor: String?) async throws -> Page<Sticker> {
        calls += 1
        guard calls == 1 else { throw URLError(.cancelled) }
        return .init(data: [
            .init(
                id: stickerID, title: "Keep me", kind: .animated, status: .draft,
                activeRevisionId: nil, createdAt: Date(), updatedAt: Date(), previewAsset: nil, systemSticker: nil
            )
        ], nextCursor: nil)
    }
}

/// A library that cannot be reached at all on the first attempt, and can on the second.
///
/// Both endpoints fail: a dead network takes the packs with the stickers, which is exactly the
/// case where the Library is left with nothing on screen and no list to pull down.
actor OfflineLibraryAPI: StickerAPIClientProtocol {
    nonisolated let stickerID = "offline-library-sticker"
    private var calls = 0

    func listStickers(cursor: String?) async throws -> Page<Sticker> {
        calls += 1
        guard calls > 1 else { throw URLError(.notConnectedToInternet) }
        return .init(data: [
            .init(
                id: stickerID, title: "Back online", kind: .static, status: .published,
                activeRevisionId: nil, createdAt: Date(), updatedAt: Date(), previewAsset: nil, systemSticker: nil
            )
        ], nextCursor: nil)
    }

    func librarySections(status: LibrarySectionStatus) async throws -> LibrarySectionsResponse {
        guard calls > 1 else { throw URLError(.notConnectedToInternet) }
        return .init(sections: [], generatedAt: Date())
    }
}

actor TurnFailureAPI: StickerAPIClientProtocol {
    nonisolated let stickerID = "turn-failure-sticker"
    private var sends = 0

    func sendChatMessage(stickerID: String, request: SendChatMessageRequest, idempotencyKey: String) async throws -> SendChatMessageResponse {
        sends += 1
        guard sends == 1 else { throw StickerAPIError.http(503) }
        return .init(
            message: .init(id: "source-message", status: .complete),
            job: .init(id: "failed-job", state: .queued, workflowRunId: nil, eventsUrl: "/api/v1/jobs/failed-job/events")
        )
    }

    nonisolated func generationEvents(jobID: String, after lastEventID: Int64?) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.init(
                id: 1, jobId: jobID, type: .failed, createdAt: Date(),
                data: .init(message: "Generation failed", progress: 1, messageId: "source-message", revisionId: nil, document: nil)
            ))
            continuation.finish()
        }
    }
}

actor SlowChatAPI: StickerAPIClientProtocol {
    nonisolated let stickerID = "slow-chat-sticker"
    private var sendStarted = false
    private var canFinish = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    func chatMessages(stickerID: String, beforeSequence: Int?) async throws -> ChatMessagePage {
        .init(data: ["earlier-source-message", "slow-source-message"].enumerated().map { index, id in
            .init(
                id: id, role: .user, kind: .text, content: "Add particles",
                targetLayerId: nil, imagePlacement: .replace, baseRevisionId: nil,
                sequence: 41 + index, revisionId: nil, jobId: nil, status: .streaming,
                createdAt: Date(timeIntervalSince1970: 1234), attachments: []
            )
        }, nextBeforeSequence: nil)
    }

    func sendChatMessage(stickerID: String, request: SendChatMessageRequest, idempotencyKey: String) async throws -> SendChatMessageResponse {
        sendStarted = true
        let waiters = startWaiters
        startWaiters = []
        waiters.forEach { $0.resume() }
        if !canFinish {
            await withCheckedContinuation { finishWaiters.append($0) }
        }
        return .init(
            message: .init(id: "slow-source-message", status: .streaming),
            job: .init(id: "slow-job", state: .queued, workflowRunId: nil, eventsUrl: "/api/v1/jobs/slow-job/events")
        )
    }

    func waitUntilSending() async {
        guard !sendStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finishSending() {
        canFinish = true
        let waiters = finishWaiters
        finishWaiters = []
        waiters.forEach { $0.resume() }
    }
}

/// Fails the send with a supplied error, to exercise how the store classifies delivery.
actor FailingChatAPI: StickerAPIClientProtocol {
    nonisolated let stickerID = "failing-chat-sticker"
    private let error: any Error

    init(error: any Error) { self.error = error }

    func sendChatMessage(stickerID: String, request: SendChatMessageRequest, idempotencyKey: String) async throws -> SendChatMessageResponse {
        throw error
    }
}

actor DeleteFailureAPI: StickerAPIClientProtocol {
    nonisolated let stickerID = "delete-failure-sticker"

    func listStickers(cursor: String?) async throws -> Page<Sticker> {
        .init(data: [
            .init(
                id: stickerID, title: "Keep me", kind: .static, status: .published,
                activeRevisionId: nil, createdAt: Date(), updatedAt: Date(), previewAsset: nil, systemSticker: nil
            )
        ], nextCursor: nil)
    }

    func deleteSticker(id: String, idempotencyKey: String) async throws -> DeleteStickerResponse {
        .init(
            stickerId: id,
            status: .deleteFailed,
            job: .init(id: "failed-cleanup", state: .failed, workflowRunId: nil, retryable: true)
        )
    }
}

actor ResumeJobAPI: StickerAPIClientProtocol {
    nonisolated let stickerID = "resume-sticker"

    func chatMessages(stickerID: String, beforeSequence: Int?) async throws -> ChatMessagePage {
        .init(data: [
            .init(
                id: "resume-source", role: .user, kind: .imageEdit, content: "Make it blue",
                targetLayerId: "hero", imagePlacement: .replace, baseRevisionId: nil, sequence: 1,
                revisionId: nil, jobId: "resume-job", status: .streaming, createdAt: Date(), attachments: []
            )
        ], nextBeforeSequence: nil)
    }

    nonisolated func generationEvents(jobID: String, after lastEventID: Int64?) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.init(
                id: 8, jobId: jobID, type: .failed, createdAt: Date(),
                data: .init(message: "Generation failed", progress: 1, messageId: "resume-source", revisionId: nil, document: nil)
            ))
            continuation.finish()
        }
    }
}

actor FailedTranscriptAPI: StickerAPIClientProtocol {
    nonisolated let stickerID = "failed-transcript-sticker"

    nonisolated func generationEvents(jobID: String, after lastEventID: Int64?) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.init(
                id: 8, jobId: jobID, type: .failed, createdAt: Date(),
                data: .init(message: "Animation timing does not match", progress: 1, messageId: nil, revisionId: nil, document: nil)
            ))
            continuation.finish()
        }
    }

    func chatMessages(stickerID: String, beforeSequence: Int?) async throws -> ChatMessagePage {
        .init(data: [
            .init(
                id: "failed-transcript-source", role: .user, kind: .imageEdit, content: "Make it blue",
                targetLayerId: "hero", imagePlacement: .replace, baseRevisionId: nil, sequence: 1,
                revisionId: nil, jobId: "failed-transcript-job", status: .failed, createdAt: Date(), attachments: []
            )
        ], nextBeforeSequence: nil)
    }
}

/// Streams a `candidate` whose document cannot be decoded into `AnimatedDocument`.
actor PoisonEventAPI: StickerAPIClientProtocol {
    nonisolated let stickerID = "poison-sticker"

    func sendChatMessage(stickerID: String, request: SendChatMessageRequest, idempotencyKey: String) async throws -> SendChatMessageResponse {
        .init(
            message: .init(id: "poison-source", status: .streaming),
            job: .init(id: "poison-job", state: .queued, workflowRunId: nil, eventsUrl: "/events")
        )
    }

    func sticker(id: String) async throws -> StickerDetail { PreviewFixtures.detail }

    func chatMessages(stickerID: String, beforeSequence: Int?) async throws -> ChatMessagePage {
        .init(data: [
            .init(
                id: "poison-source", role: .user, kind: .text, content: "Make it blue",
                targetLayerId: nil, imagePlacement: .replace, baseRevisionId: nil, sequence: 1,
                revisionId: nil, jobId: "poison-job", status: .complete, createdAt: Date(), attachments: []
            ),
            .init(
                id: "poison-assistant", role: .assistant, kind: .image, content: "Here it is",
                targetLayerId: nil, imagePlacement: .replace, baseRevisionId: nil, sequence: 2,
                revisionId: nil, jobId: "poison-job", status: .complete, createdAt: Date(), attachments: []
            )
        ], nextBeforeSequence: nil)
    }

    nonisolated func generationEvents(jobID: String, after lastEventID: Int64?) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let poisoned = Data("""
            {"id":1,"jobId":"poison-job","type":"candidate","createdAt":"2026-01-01T00:00:00Z",
             "data":{"revisionId":"r1","document":{"version":9,"nope":true}}}
            """.utf8)
            if let event = try? JSONDecoder.api.decode(GenerationEvent.self, from: poisoned) {
                continuation.yield(event)
            }
            continuation.yield(.init(
                id: 2, jobId: jobID, type: .completed, createdAt: Date(), data: .init(message: "Done", progress: 1)
            ))
            continuation.finish()
        }
    }
}

/// Throws partway through the stream, as a dropped connection does.
actor BrokenStreamAPI: StickerAPIClientProtocol {
    nonisolated let stickerID = "broken-sticker"
    private nonisolated let streams = StreamCounter()

    func streamCount() -> Int { streams.value }

    func sendChatMessage(stickerID: String, request: SendChatMessageRequest, idempotencyKey: String) async throws -> SendChatMessageResponse {
        .init(
            message: .init(id: "broken-source", status: .streaming),
            job: .init(id: "broken-job", state: .queued, workflowRunId: nil, eventsUrl: "/events")
        )
    }

    func sticker(id: String) async throws -> StickerDetail { PreviewFixtures.detail }

    func chatMessages(stickerID: String, beforeSequence: Int?) async throws -> ChatMessagePage {
        .init(data: [
            .init(
                id: "broken-source", role: .user, kind: .text, content: "Make it blue",
                targetLayerId: nil, imagePlacement: .replace, baseRevisionId: nil, sequence: 1,
                revisionId: nil, jobId: "broken-job", status: .complete, createdAt: Date(), attachments: []
            ),
            .init(
                id: "broken-assistant", role: .assistant, kind: .image, content: "Here it is",
                targetLayerId: nil, imagePlacement: .replace, baseRevisionId: nil, sequence: 2,
                revisionId: nil, jobId: "broken-job", status: .complete, createdAt: Date(), attachments: []
            )
        ], nextBeforeSequence: nil)
    }

    nonisolated func generationEvents(jobID: String, after lastEventID: Int64?) -> AsyncThrowingStream<GenerationEvent, Error> {
        streams.mark()
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(
                id: 1, jobId: jobID, type: .progress, createdAt: Date(), data: .init(message: "Working", progress: 0.4)
            ))
            continuation.finish(throwing: TestFixtureError.stub)
        }
    }
}

/// A turn the server is still running while every stream the client opens dies on it.
///
/// Modelled on a confirmed plan: the transcript keeps reporting the source message as `streaming`,
/// and the stream drops the way a backgrounded app's does — cancelled, which the store reads as no
/// error at all — so the message's status is the only thing left saying the turn is still live.
actor LiveTurnStreamAPI: StickerAPIClientProtocol {
    nonisolated let stickerID = "live-turn-sticker"
    nonisolated let streams = StreamCounter()
    private nonisolated let timesOutDuringReconciliation: Bool

    init(timesOutDuringReconciliation: Bool = false) {
        self.timesOutDuringReconciliation = timesOutDuringReconciliation
    }

    func confirmPlan(stickerID: String, planID: String, idempotencyKey: String) async throws -> ConfirmPlanResponse {
        .init(
            message: .init(id: "live-source", status: .streaming),
            job: .init(id: "live-job", state: .queued, workflowRunId: nil, eventsUrl: "/events")
        )
    }

    func sticker(id: String) async throws -> StickerDetail {
        if timesOutDuringReconciliation { throw URLError(.timedOut) }
        return PreviewFixtures.detail
    }

    func chatMessages(stickerID: String, beforeSequence: Int?) async throws -> ChatMessagePage {
        if timesOutDuringReconciliation { throw URLError(.timedOut) }
        return .init(data: [
            .init(
                id: "live-source", role: .user, kind: .text,
                content: "Build this plan: 8 layers, 4 to generate.",
                targetLayerId: nil, imagePlacement: .replace, baseRevisionId: nil, sequence: 1,
                revisionId: nil, jobId: "live-job", status: .streaming, createdAt: Date(), attachments: []
            ),
            .init(
                id: "live-tool", role: .system, kind: .status, content: "build-plan",
                targetLayerId: nil, imagePlacement: .replace, baseRevisionId: nil, sequence: 2,
                revisionId: nil, jobId: "live-job", status: .streaming, createdAt: Date(), attachments: []
            )
        ], nextBeforeSequence: nil)
    }

    nonisolated func generationEvents(jobID: String, after lastEventID: Int64?) -> AsyncThrowingStream<GenerationEvent, Error> {
        streams.mark()
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(
                id: 1, jobId: jobID, type: .progress, createdAt: Date(),
                data: .init(message: "Composing", progress: 0.2)
            ))
            continuation.finish(throwing: URLError(timesOutDuringReconciliation ? .timedOut : .cancelled))
        }
    }
}

/// A turn that reports stages and counts the way the workflow does, and then stays live.
///
/// The stream ends cancelled rather than completed on purpose — that is how a backgrounded app's
/// stream dies — so the job keeps the status it was left with and the test can read it.
actor StagedProgressAPI: StickerAPIClientProtocol {
    nonisolated let stickerID = "staged-progress-sticker"
    nonisolated let streams = StreamCounter()
    nonisolated let events: [GenerationEventData]

    init(events: [GenerationEventData]) { self.events = events }

    func confirmPlan(stickerID: String, planID: String, idempotencyKey: String) async throws -> ConfirmPlanResponse {
        .init(
            message: .init(id: "staged-source", status: .streaming),
            job: .init(id: "staged-job", state: .queued, workflowRunId: nil, eventsUrl: "/events")
        )
    }

    func sticker(id: String) async throws -> StickerDetail { PreviewFixtures.detail }

    func chatMessages(stickerID: String, beforeSequence: Int?) async throws -> ChatMessagePage {
        .init(data: [
            .init(
                id: "staged-source", role: .user, kind: .text, content: "Make it.",
                targetLayerId: nil, imagePlacement: .replace, baseRevisionId: nil, sequence: 1,
                revisionId: nil, jobId: "staged-job", status: .streaming, createdAt: Date(), attachments: []
            )
        ], nextBeforeSequence: nil)
    }

    nonisolated func generationEvents(jobID: String, after lastEventID: Int64?) -> AsyncThrowingStream<GenerationEvent, Error> {
        streams.mark()
        return AsyncThrowingStream { continuation in
            for (index, data) in events.enumerated() {
                continuation.yield(.init(
                    id: Int64(index + 1), jobId: jobID, type: .progress, createdAt: Date(), data: data
                ))
            }
            continuation.finish(throwing: URLError(.cancelled))
        }
    }
}

final class StreamCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func mark() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
