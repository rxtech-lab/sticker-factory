import Foundation
import Messages
import Testing
import UIKit
@testable import StickerMessages

@Suite("Progressive Messages library", .serialized)
struct MessagesLibraryLoadingTests {
    @MainActor
    @Test("Cached stickers are published before token refresh or the listing request")
    func cacheAppearsBeforeNetwork() async throws {
        let fixture = try LoadingFixture(expired: true)
        defer { fixture.removeFiles() }
        _ = try await fixture.cache.store(fixture.png, descriptor: fixture.descriptor("a"), for: "user")
        let snapshot = try await fixture.service.refresh { update in
            if update.isRefreshing, update.stickers.count == 1, await fixture.service.lastDescriptors().isEmpty {
                #expect(await fixture.transport.requestCount() == 0)
                #expect(await fixture.refreshTransport.callCount() == 0)
            }
        }
        #expect(snapshot.stickers.count == 2)
        #expect(!snapshot.isRefreshing)
    }

    @MainActor
    @Test("A slow first download does not block a later sticker from appearing and being selected")
    func firstStickerBeforeAllDownloads() async throws {
        let fixture = try LoadingFixture(slowAsset: "a")
        defer { fixture.removeFiles() }
        let grid = StickerGridViewController()
        grid.view.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        let snapshot = try await fixture.service.refresh { update in
            if update.isRefreshing, update.stickers.map(\.assetID) == ["b"] {
                #expect(!(await fixture.transport.completedAssets()).contains("a"))
                await MainActor.run {
                    grid.replaceSections(with: update.sections)
                    var selected = false
                    grid.onSelect = { _ in selected = true }
                    grid.selectSticker(at: 0)
                    #expect(selected)
                }
            }
        }
        #expect(snapshot.stickers.map(\.assetID) == ["a", "b"])
        #expect(await MainActor.run { grid.stickerCount } == 1)
    }

    @MainActor
    @Test("Cancellation after the first sticker stops remaining downloads and updates")
    func cancelAfterFirstSticker() async throws {
        let fixture = try LoadingFixture(slowAsset: "a")
        defer { fixture.removeFiles() }
        let task = Task {
            try await fixture.service.refresh { update in
                if !update.stickers.isEmpty { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(await fixture.transport.completedAssets() == ["b"])
        #expect(try await fixture.cache.cachedStickers(for: "user").map(\.assetID) == ["b"])
    }

    @MainActor
    @Test("Reopening reuses asset files without downloading or rewriting them")
    func cachedFilesAreReused() async throws {
        let fixture = try LoadingFixture()
        defer { fixture.removeFiles() }
        let first = try await fixture.service.refresh()
        let file = try #require(first.stickers.first?.fileURL)
        let oldDate = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)
        let second = try await fixture.service.refresh()
        #expect(second.stickers == first.stickers)
        #expect(await fixture.transport.completedAssets().count == 2)
        #expect(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == oldDate)
    }

    @MainActor
    @Test("Shared assets download once across packs; removed packs disappear on reconciliation")
    func sharedAssetsAndRemovedPacks() async throws {
        let fixture = try LoadingFixture(duplicatePack: true)
        defer { fixture.removeFiles() }
        var removed = fixture.descriptor("old")
        removed.sectionID = "pack:removed"
        _ = try await fixture.cache.store(fixture.png, descriptor: removed, for: "user")
        let snapshot = try await fixture.service.refresh()
        #expect(snapshot.sections.map(\.id) == ["mine", "pack:shared"])
        #expect(snapshot.stickers.count == 3)
        #expect(await fixture.transport.completedAssets().count == 2)
        #expect(snapshot.stickers[0].fileURL == snapshot.stickers[2].fileURL)
    }

    @MainActor
    @Test("Offline refresh keeps the cached grid, while rejected sign-in purges it")
    func offlineAndRejectedAuthentication() async throws {
        let offline = try LoadingFixture(listingFails: true)
        defer { offline.removeFiles() }
        _ = try await offline.cache.store(offline.png, descriptor: offline.descriptor("a"), for: "user")
        let snapshot = try await offline.service.refresh()
        #expect(snapshot.isOffline)
        #expect(snapshot.stickers.count == 1)

        let rejected = try LoadingFixture(expired: true, refreshRejected: true)
        defer { rejected.removeFiles() }
        _ = try await rejected.cache.store(rejected.png, descriptor: rejected.descriptor("a"), for: "user")
        do {
            _ = try await rejected.service.refresh()
            Issue.record("Expected sign-in rejection")
        } catch SharedAuthenticationError.refreshRejected {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(try await rejected.cache.cachedStickers(for: "user").isEmpty)
    }

    @MainActor
    @Test("Image sends from the initial cached snapshot still resolve the full-size rendition")
    func earlyImageSend() async throws {
        let fixture = try LoadingFixture()
        defer { fixture.removeFiles() }
        _ = try await fixture.cache.store(fixture.png, descriptor: fixture.descriptor("a"), for: "user")
        let full = FullSizeStickerLibraryService(
            inner: fixture.service, tokenBroker: fixture.broker, client: fixture.client,
            fullCache: try SharedStickerCache(rootURL: fixture.root.appending(path: "full"), policy: .fullSize)
        )
        _ = try await full.refresh { update in
            if update.isRefreshing, update.stickers.count == 1, await fixture.transport.requestCount() == 0 {
                let result = try? await full.attachment(for: CacheKey(sectionID: "mine", stickerID: "a"))
                #expect(result?.isFullSize == true)
                #expect(!(await fixture.transport.completedAssets()).contains("b"))
            }
        }
        #expect(await fixture.transport.completedAssets().contains("full-a"))
    }

    @MainActor
    @Test("Progressive grid updates retain prepared stickers, selection and scroll position")
    func gridKeepsExistingItems() async throws {
        let fixture = try LoadingFixture()
        defer { fixture.removeFiles() }
        let a = try await fixture.cache.store(fixture.png, descriptor: fixture.descriptor("a"), for: "user")
        let items = (0..<80).map { index in
            CachedSticker(
                stickerID: "\(index)", assetID: a.assetID, title: "Sticker \(index)",
                fileURL: a.fileURL, updatedAt: a.updatedAt, position: index
            )
        }
        let grid = StickerGridViewController()
        grid.view.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        grid.replaceStickers(with: items)
        grid.view.layoutIfNeeded()
        let itemID = StickerGridViewController.StickerItemID(sectionID: "mine", stickerID: "0")
        let prepared = try #require(grid.sticker(for: itemID))
        grid.collectionView.setContentOffset(CGPoint(x: 0, y: 400), animated: false)
        grid.setBusy(true, for: itemID)
        grid.replaceStickers(with: items + [a])
        grid.view.layoutIfNeeded()
        #expect(grid.sticker(for: itemID) === prepared)
        #expect(grid.isBusy(itemID))
        #expect(grid.collectionView.contentOffset.y == 400)
        #expect(grid.stickerCount == 81)
    }
}

private struct LoadingFixture: Sendable {
    let root: URL
    let png: Data
    let cache: SharedStickerCache
    let transport: LoadingTransport
    let refreshTransport: LoadingRefreshTransport
    let broker: SharedTokenBroker
    let client: StickerLibraryClient
    let service: MessagesLibraryService

    @MainActor
    init(expired: Bool = false, slowAsset: String? = nil, duplicatePack: Bool = false, listingFails: Bool = false, refreshRejected: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "messages-loading-\(UUID().uuidString)")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        png = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300), format: format).pngData { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
        }
        cache = try SharedStickerCache(rootURL: root.appending(path: "system"))
        transport = LoadingTransport(png: png, slowAsset: slowAsset, duplicatePack: duplicatePack, listingFails: listingFails)
        refreshTransport = LoadingRefreshTransport(rejected: refreshRejected)
        broker = SharedTokenBroker(
            configuration: .init(tokenURL: URL(string: "https://example.test/token")!, clientID: "ios", accessGroup: "test"),
            storage: MessagesInMemoryTokenStorage(.init(accessToken: "fixture", refreshToken: "refresh", idToken: nil,
                expiresAt: Date().addingTimeInterval(expired ? -60 : 3600), subject: "user")),
            transport: refreshTransport, lockURL: root.appending(path: "refresh.lock")
        )
        client = StickerLibraryClient(baseURL: URL(string: "https://example.test")!, transport: transport)
        service = MessagesLibraryService(tokenBroker: broker, client: client, cache: cache)
    }

    func descriptor(_ id: String) -> SystemStickerDescriptor {
        .init(stickerID: id, assetID: id, title: id, mimeType: "image/png", updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func removeFiles() { try? FileManager.default.removeItem(at: root) }
}

private actor LoadingRefreshTransport: SharedOAuthRefreshTransport {
    let rejected: Bool
    var calls = 0
    init(rejected: Bool) { self.rejected = rejected }
    func refresh(tokenURL: URL, clientID: String, refreshToken: String) async throws -> RefreshTokenResponse {
        calls += 1
        if rejected { throw SharedAuthenticationError.refreshRejected }
        return RefreshTokenResponse(accessToken: "fixture-refreshed", refreshToken: "refresh-new", idToken: nil, expiresIn: 3600)
    }
    func callCount() -> Int { calls }
}

private actor LoadingTransport: StickerHTTPTransport {
    let png: Data
    let slowAsset: String?
    let duplicatePack: Bool
    let listingFails: Bool
    var requests = 0
    var completed: [String] = []

    init(png: Data, slowAsset: String?, duplicatePack: Bool, listingFails: Bool) {
        self.png = png
        self.slowAsset = slowAsset
        self.duplicatePack = duplicatePack
        self.listingFails = listingFails
    }

    func data(for request: URLRequest) async throws -> StickerHTTPResult {
        requests += 1
        let url = try #require(request.url)
        if url.path.contains("library/sections") {
            if listingFails { throw URLError(.notConnectedToInternet) }
            func item(_ id: String) -> String {
                let system = "\"systemSticker\":{\"assetId\":\"\(id)\",\"mimeType\":\"image/png\"}"
                let preview = "\"previewAsset\":{\"assetId\":\"full-\(id)\",\"mimeType\":\"image/png\"}"
                return "{\"id\":\"\(id)\",\"title\":\"\(id)\",\"updatedAt\":\"2026-08-24T12:00:00Z\",\(system),\(preview)}"
            }
            let pack = duplicatePack ? ",{\"id\":\"pack:shared\",\"title\":\"Shared\",\"stickers\":[\(item("a"))]}" : ""
            let json = "{\"sections\":[{\"id\":\"mine\",\"title\":\"My Stickers\",\"stickers\":[\(item("a")),\(item("b"))]}\(pack)]}"
            return result(Data(json.utf8), url: url, type: "application/json")
        }
        let id = url.pathComponents.dropLast().last ?? ""
        try await Task.sleep(for: .milliseconds(id == slowAsset ? 600 : 20))
        completed.append(id)
        return result(png, url: url, type: "image/png")
    }

    private func result(_ data: Data, url: URL, type: String) -> StickerHTTPResult {
        .init(data: data, response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": type])!)
    }
    func requestCount() -> Int { requests }
    func completedAssets() -> [String] { completed }
}
