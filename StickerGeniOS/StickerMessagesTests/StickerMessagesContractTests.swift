import Foundation
import Messages
import Testing
import UIKit
@testable import StickerMessages

@Suite("Messages shared contracts")
struct StickerMessagesContractTests {
    @Test("Main and extension token codecs are bidirectional")
    func tokenCodecCompatibility() throws {
        let expiration = Date(timeIntervalSince1970: 1_893_459_845)
        let extensionBundle = SharedTokenBundle(
            accessToken: "fixture.header.payload.signature",
            refreshToken: "rotating-refresh-token",
            idToken: "fixture.id.token",
            expiresAt: expiration,
            subject: "fixture-user"
        )

        let extensionEncoded = try JSONEncoder().encode(extensionBundle)
        let mainDecoder = JSONDecoder()
        mainDecoder.dateDecodingStrategy = .iso8601
        let decodedByMain = try mainDecoder.decode(MainTokenBundle.self, from: extensionEncoded)
        #expect(decodedByMain.accessToken == extensionBundle.accessToken)
        #expect(decodedByMain.expiresAt == expiration)

        let mainEncoder = JSONEncoder()
        mainEncoder.dateEncodingStrategy = .iso8601
        let mainEncoded = try mainEncoder.encode(decodedByMain)
        let decodedByExtension = try JSONDecoder().decode(SharedTokenBundle.self, from: mainEncoded)
        #expect(decodedByExtension == extensionBundle)
    }

    @Test("System renditions stay below the conservative 500 KB threshold")
    func systemRenditionLimit() {
        #expect(SharedStickerCache.maximumByteCount == 500_000)
    }

    @Test("Only PNG, APNG, and GIF cache formats are accepted")
    func supportedCacheFormats() throws {
        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(try SharedStickerCache.validatedFileExtension(for: pngHeader, declaredMimeType: "image/png") == "png")

        let gifHeader = Data("GIF89a".utf8)
        #expect(try SharedStickerCache.validatedFileExtension(for: gifHeader, declaredMimeType: "image/gif") == "gif")

        let jpegHeader = Data([0xFF, 0xD8, 0xFF])
        #expect(throws: StickerCacheError.self) {
            try SharedStickerCache.validatedFileExtension(for: jpegHeader, declaredMimeType: "image/jpeg")
        }
    }

    @Test("System cache rejects non-preset and non-square local images")
    func strictSystemStickerDimensions() throws {
        let valid = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300)).pngData { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
        }
        try SharedStickerCache.validateImage(valid)

        let unsupported = UIGraphicsImageRenderer(size: CGSize(width: 301, height: 301)).pngData { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 301, height: 301))
        }
        #expect(throws: StickerCacheError.self) { try SharedStickerCache.validateImage(unsupported) }

        let nonsquare = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 408)).pngData { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 408))
        }
        #expect(throws: StickerCacheError.self) { try SharedStickerCache.validateImage(nonsquare) }
    }

    @Test("Concurrent extension callers share one detached refresh rotation")
    func concurrentRefreshIsSerialized() async throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let storage = MessagesInMemoryTokenStorage(.init(
            accessToken: "expired",
            refreshToken: "refresh-1",
            idToken: nil,
            expiresAt: now.addingTimeInterval(-10),
            subject: "user-a"
        ))
        let response = RefreshTokenResponse(
            accessToken: try messagesJWT(subject: "user-a", expiration: now.addingTimeInterval(3_600)),
            refreshToken: "refresh-2",
            idToken: nil,
            expiresIn: 3_600
        )
        let transport = MessagesCountingRefreshTransport(response: response)
        let broker = SharedTokenBroker(
            configuration: .init(tokenURL: URL(string: "https://auth.example/token")!, clientID: "ios", accessGroup: "test"),
            storage: storage,
            transport: transport,
            now: { now },
            lockURL: FileManager.default.temporaryDirectory.appending(path: "messages-refresh-\(UUID().uuidString).lock")
        )

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<12 {
                group.addTask { try await broker.authenticatedSession().accessToken }
            }
            var values: [String] = []
            for try await token in group { values.append(token) }
            return values
        }

        #expect(Set(tokens) == [response.accessToken])
        #expect(await transport.callCount() == 1)
        #expect(try storage.read()?.refreshToken == "refresh-2")
    }

    @Test("Messages library follows every cursor before returning a sync snapshot")
    func libraryPagination() async throws {
        let transport = PaginatedStickerTransport()
        let client = StickerLibraryClient(baseURL: URL(string: "https://api.example/")!, transport: transport)
        let stickers = try await client.fetchLibrary(accessToken: "access")

        #expect(Set(stickers.map(\.stickerID)) == ["sticker-1", "sticker-2"])
        #expect(await transport.requestedCursors() == ["<first>", "page-2"])
    }

    @Test("A partial live sync fails atomically so the service can keep its offline cache")
    func partialLibraryFailureDoesNotReturnPartialState() async {
        let transport = FailingSecondPageTransport()
        let client = StickerLibraryClient(baseURL: URL(string: "https://api.example/")!, transport: transport)
        do {
            _ = try await client.fetchLibrary(accessToken: "access")
            #expect(Bool(false), "A partial fetch must not look like a complete library")
        } catch {
            #expect(error is URLError)
        }
        #expect(await transport.callCount() == 2)
    }

    @MainActor
    @Test("Grid routes taps to an injectable insert handler and manages the animation lifecycle")
    func stickerGridRoutesTapsToInsertHandler() throws {
        let data = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300)).pngData { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
        }
        let fileURL = FileManager.default.temporaryDirectory.appending(path: "messages-grid-\(UUID().uuidString).png")
        try data.write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let controller = StickerGridViewController()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        controller.loadViewIfNeeded()

        var inserted: [String] = []
        // The seam that stands in for MSConversation, which is unavailable in a unit test.
        controller.onSelect = { inserted.append($0.localizedDescription) }

        controller.replaceStickers(with: [
            .init(stickerID: "sticker", assetID: "asset", title: "Purple", fileURL: fileURL, updatedAt: Date()),
        ])
        controller.view.layoutIfNeeded()

        #expect(controller.view.accessibilityIdentifier == "sticker-factory-messages-browser")
        #expect(controller.stickerCount == 1)

        controller.selectSticker(at: 0)
        #expect(inserted == ["Purple"])
        controller.selectSticker(at: 99)
        #expect(inserted == ["Purple"])

        let indexPath = IndexPath(item: 0, section: 0)
        // Through the collection view's own data source: the grid is diffable now, so the
        // controller no longer implements `cellForItemAt` itself.
        let cell = try #require(
            controller.collectionView.dataSource?
                .collectionView(controller.collectionView, cellForItemAt: indexPath) as? StickerCell
        )
        #expect(cell.accessibilityLabel == "Purple")
        #expect(cell.isAccessibilityElement)
        #expect(cell.displayedStickerFileURL == fileURL)

        // Assert our tracked intent, not MSStickerView.isAnimating(): a static PNG has an
        // animationDuration of zero and reports false even after startAnimating().
        controller.resumeAnimations()
        controller.collectionView(controller.collectionView, willDisplay: cell, forItemAt: indexPath)
        #expect(cell.animationRequested)
        controller.collectionView(controller.collectionView, didEndDisplaying: cell, forItemAt: indexPath)
        #expect(!cell.animationRequested)

        controller.collectionView(controller.collectionView, willDisplay: cell, forItemAt: indexPath)
        cell.prepareForReuse()
        #expect(!cell.animationRequested)
        #expect(cell.displayedStickerFileURL == nil)
        // Peel/drag stays owned by MSStickerView and remains part of the real-device check.
    }

    @Test("Sectioned library fetch groups stickers and stamps their pack byline")
    func fetchSectionsGroupsByPack() async throws {
        let transport = SectionedStickerTransport()
        let client = StickerLibraryClient(baseURL: URL(string: "https://api.example/")!, transport: transport)
        let descriptors = try await client.fetchSections(accessToken: "access")

        #expect(descriptors.map(\.stickerID) == ["mine-1", "borrowed-1", "borrowed-2"])
        #expect(descriptors[0].sectionID == "mine")
        #expect(descriptors[0].sectionTitle == "My Stickers")
        #expect(descriptors[0].sectionSubtitle == nil)
        #expect(descriptors[1].sectionID == "pack:p1")
        #expect(descriptors[1].sectionSubtitle == "by Mika Lin")
        // Section and item order come from the response, not from updatedAt.
        #expect(descriptors[1].sectionPosition == 1)
        #expect(descriptors[2].position == 1)
    }

    @Test("A server with no sections endpoint falls back to the flat library")
    func fetchSectionsFallsBackOn404() async throws {
        // The extension ships inside the app binary and can be newer than the server it talks to.
        let transport = SectionsMissingTransport()
        let client = StickerLibraryClient(baseURL: URL(string: "https://api.example/")!, transport: transport)
        let descriptors = try await client.fetchSections(accessToken: "access")

        #expect(descriptors.map(\.stickerID) == ["sticker-1"])
        #expect(descriptors[0].sectionID == "mine")
        #expect(await transport.paths() == ["/api/v1/library/sections", "/api/v1/stickers"])
    }

    @MainActor
    @Test("Grid draws one section per pack and routes taps by index path")
    func stickerGridGroupsSections() throws {
        let fileURL = try Self.writeStickerPNG()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let controller = StickerGridViewController()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        controller.loadViewIfNeeded()
        var inserted: [String] = []
        controller.onSelect = { inserted.append($0.localizedDescription) }

        controller.replaceSections(with: [
            .init(id: "mine", title: "My Stickers", subtitle: nil, stickers: [
                .init(stickerID: "own", assetID: "a1", title: "Mine", fileURL: fileURL, updatedAt: Date()),
            ]),
            .init(id: "pack:p1", title: "Cozy Cats", subtitle: "by Mika Lin", stickers: [
                .init(stickerID: "borrowed", assetID: "a2", title: "Loaf", fileURL: fileURL, updatedAt: Date()),
            ]),
        ])
        controller.view.layoutIfNeeded()

        #expect(controller.collectionView.numberOfSections == 2)
        #expect(controller.stickerCount == 2)

        controller.selectSticker(at: IndexPath(item: 0, section: 1))
        #expect(inserted == ["Loaf"])
        // The flat form still addresses the whole grid, in display order.
        controller.selectSticker(at: 0)
        #expect(inserted == ["Loaf", "Mine"])
        controller.selectSticker(at: IndexPath(item: 5, section: 9))
        #expect(inserted == ["Loaf", "Mine"])

        let header = try #require(
            controller.collectionView.dataSource?.collectionView?(
                controller.collectionView,
                viewForSupplementaryElementOfKind: UICollectionView.elementKindSectionHeader,
                at: IndexPath(item: 0, section: 1)
            ) as? StickerSectionHeaderView
        )
        #expect(header.accessibilityLabel == "Cozy Cats, by Mika Lin")
    }

    @MainActor
    @Test("An empty pack section is not drawn as a bare header")
    func stickerGridDropsEmptySections() throws {
        let fileURL = try Self.writeStickerPNG()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let controller = StickerGridViewController()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        controller.loadViewIfNeeded()
        // A pack whose members all fell back to draft still arrives, so the cache can reconcile
        // it — but there is nothing to draw under its header.
        controller.replaceSections(with: [
            .init(id: "mine", title: "My Stickers", subtitle: nil, stickers: [
                .init(stickerID: "own", assetID: "a1", title: "Mine", fileURL: fileURL, updatedAt: Date()),
            ]),
            .init(id: "pack:hollow", title: "Hollow", subtitle: "by Someone", stickers: []),
        ])
        controller.view.layoutIfNeeded()

        #expect(controller.collectionView.numberOfSections == 1)
        #expect(controller.stickerCount == 1)
    }

    @MainActor
    @Test("A tap after a refresh inserts the sticker now on screen, not the one that was")
    func stickerGridTapSurvivesReload() throws {
        let fileURL = try Self.writeStickerPNG()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let controller = StickerGridViewController()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        controller.loadViewIfNeeded()
        var inserted: [String] = []
        controller.onSelect = { inserted.append($0.localizedDescription) }

        controller.replaceStickers(with: [
            .init(stickerID: "first", assetID: "a1", title: "First", fileURL: fileURL, updatedAt: Date()),
        ])
        controller.view.layoutIfNeeded()
        // Cells capture an item id rather than an index path, which goes stale the moment a
        // snapshot is applied.
        controller.replaceStickers(with: [
            .init(stickerID: "second", assetID: "a2", title: "Second", fileURL: fileURL, updatedAt: Date()),
            .init(stickerID: "first", assetID: "a1", title: "First", fileURL: fileURL, updatedAt: Date()),
        ])
        controller.view.layoutIfNeeded()

        let cell = try #require(
            controller.collectionView.dataSource?
                .collectionView(controller.collectionView, cellForItemAt: IndexPath(item: 0, section: 0)) as? StickerCell
        )
        #expect(cell.accessibilityLabel == "Second")
        controller.selectSticker(at: 0)
        #expect(inserted == ["Second"])
    }

    @MainActor
    private static func writeStickerPNG() throws -> URL {
        let data = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300)).pngData { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
        }
        let fileURL = FileManager.default.temporaryDirectory.appending(path: "messages-grid-\(UUID().uuidString).png")
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    @Test("An offline extension stops offering a pack the user already removed")
    func allowlistFiltersCachedSections() {
        let sections: [StickerSection] = [
            .init(id: "mine", title: "My Stickers", subtitle: nil, stickers: []),
            .init(id: "pack:kept", title: "Kept", subtitle: "by A", stickers: []),
            .init(id: "pack:removed", title: "Removed", subtitle: "by B", stickers: []),
        ]

        // No allowlist means no opinion: the cache is served exactly as before.
        #expect(SharedSectionAllowlist.filter(sections, allowed: nil).count == 3)

        let filtered = SharedSectionAllowlist.filter(sections, allowed: ["mine", "pack:kept"])
        #expect(filtered.map(\.id) == ["mine", "pack:kept"])
    }

    @Test("Insert failures in a non-Messages host surface the peel/drag hint")
    func insertPolicyMapsContextRejectionToDragHint() {
        #expect(StickerInsertPolicy.outcome(domain: nil, code: nil) == .inserted)
        #expect(StickerInsertPolicy.outcome(
            domain: MSMessagesErrorDomain,
            code: MSMessageErrorCode.apiUnavailableInPresentationContext.rawValue
        ) == .unavailableInContext)
        #expect(StickerInsertPolicy.outcome(
            domain: MSStickersErrorDomain,
            code: MSMessageErrorCode.apiUnavailableInPresentationContext.rawValue
        ) == .unavailableInContext)
        #expect(StickerInsertPolicy.outcome(
            domain: MSStickersErrorDomain,
            code: MSMessageErrorCode.stickerFileImproperFileSize.rawValue
        ) == .failed)

        #expect(StickerInsertPolicy.hint(for: .inserted, context: .media) == nil)
        #expect(StickerInsertPolicy.hint(for: .noConversation, context: .media)?
            .contains("Press and hold") == true)
        #expect(StickerInsertPolicy.hint(for: .unavailableInContext, context: .messages)?
            .contains("Press and hold") == true)
    }
}

private struct MainTokenBundle: Codable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresAt: Date
    let subject: String?
}

private final class MessagesInMemoryTokenStorage: SharedTokenStorageProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var bundle: SharedTokenBundle?

    init(_ bundle: SharedTokenBundle?) { self.bundle = bundle }

    func read() throws -> SharedTokenBundle? {
        lock.lock(); defer { lock.unlock() }
        return bundle
    }

    func replace(with bundle: SharedTokenBundle) throws {
        lock.lock(); defer { lock.unlock() }
        self.bundle = bundle
    }

    func delete() throws {
        lock.lock(); defer { lock.unlock() }
        bundle = nil
    }
}

private actor MessagesCountingRefreshTransport: SharedOAuthRefreshTransport {
    let response: RefreshTokenResponse
    private var calls = 0

    init(response: RefreshTokenResponse) { self.response = response }

    func refresh(tokenURL: URL, clientID: String, refreshToken: String) async throws -> RefreshTokenResponse {
        calls += 1
        try await Task.sleep(for: .milliseconds(30))
        return response
    }

    func callCount() -> Int { calls }
}

private actor SectionedStickerTransport: StickerHTTPTransport {
    func data(for request: URLRequest) async throws -> StickerHTTPResult {
        let url = try #require(request.url)
        let body = Data("""
        {"sections":[
          {"id":"mine","kind":"mine","title":"My Stickers","creator":null,"stickers":[
            {"id":"mine-1","title":"Mine","updatedAt":"2026-08-24T12:00:00Z","systemSticker":{"assetId":"a1","mimeType":"image/png","byteSize":100,"sha256":"abc"}}
          ]},
          {"id":"pack:p1","kind":"pack","title":"Cozy Cats","creator":{"handle":"mika-lin-4f2a9c","displayName":"Mika Lin"},"stickers":[
            {"id":"borrowed-1","title":"Loaf","updatedAt":"2026-08-24T12:00:01Z","systemSticker":{"assetId":"a2","mimeType":"image/png","byteSize":100,"sha256":"def"}},
            {"id":"borrowed-2","title":"Nap","updatedAt":"2026-08-24T12:00:02Z","systemSticker":{"assetId":"a3","mimeType":"image/png","byteSize":100,"sha256":"ghi"}}
          ]}
        ],"generatedAt":"2026-08-24T12:00:05Z"}
        """.utf8)
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return .init(data: body, response: response)
    }
}

/// A server that predates the sections endpoint: 404 there, but the flat library still works.
private actor SectionsMissingTransport: StickerHTTPTransport {
    private var requestedPaths: [String] = []

    func data(for request: URLRequest) async throws -> StickerHTTPResult {
        let url = try #require(request.url)
        requestedPaths.append(url.path())
        if url.path().contains("library/sections") {
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil
            ))
            return .init(data: Data(), response: response)
        }
        let body = Data("""
        {"data":[{"id":"sticker-1","title":"Sticker","updatedAt":"2026-08-24T12:00:00Z","systemSticker":{"assetId":"a1","mimeType":"image/png","byteSize":100,"sha256":"abc"}}],"nextCursor":null}
        """.utf8)
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return .init(data: body, response: response)
    }

    func paths() -> [String] { requestedPaths }
}

private actor PaginatedStickerTransport: StickerHTTPTransport {
    private var cursors: [String] = []

    func data(for request: URLRequest) async throws -> StickerHTTPResult {
        let url = try #require(request.url)
        let cursor = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "cursor" })?.value
        cursors.append(cursor ?? "<first>")
        let suffix = cursor == nil ? "1" : "2"
        let next = cursor == nil ? "\"page-2\"" : "null"
        let body = Data("""
        {"data":[{"id":"sticker-\(suffix)","title":"Sticker \(suffix)","updatedAt":"2026-08-24T12:00:0\(suffix)Z","systemSticker":{"assetId":"asset-\(suffix)","mimeType":"image/png","byteSize":100,"sha256":"abc"}}],"nextCursor":\(next)}
        """.utf8)
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return .init(data: body, response: response)
    }

    func requestedCursors() -> [String] { cursors }
}

private actor FailingSecondPageTransport: StickerHTTPTransport {
    private var calls = 0

    func data(for request: URLRequest) async throws -> StickerHTTPResult {
        calls += 1
        if calls == 2 { throw URLError(.networkConnectionLost) }
        let url = try #require(request.url)
        let body = Data("""
        {"data":[{"id":"partial","title":"Partial","updatedAt":"2026-08-24T12:00:00Z","systemSticker":{"assetId":"asset-partial","mimeType":"image/png","byteSize":100,"sha256":"abc"}}],"nextCursor":"page-2"}
        """.utf8)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
        return .init(data: body, response: response)
    }

    func callCount() -> Int { calls }
}

private func messagesJWT(subject: String, expiration: Date) throws -> String {
    let payloadData = try JSONSerialization.data(withJSONObject: [
        "sub": subject,
        "exp": expiration.timeIntervalSince1970,
    ])
    let payload = payloadData.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(payload).signature"
}
