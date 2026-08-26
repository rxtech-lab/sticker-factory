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
    @Test("Browser exposes verified local stickers through Apple's system interaction controller")
    func stickerBrowserUsesSystemTapAndPeelController() throws {
        let data = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300)).pngData { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
        }
        let fileURL = FileManager.default.temporaryDirectory.appending(path: "messages-browser-\(UUID().uuidString).png")
        try data.write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let controller = StickerBrowserViewController()
        controller.loadViewIfNeeded()
        controller.replaceStickers(with: [
            .init(stickerID: "sticker", assetID: "asset", title: "Purple", fileURL: fileURL, updatedAt: Date()),
        ])

        #expect(controller is MSStickerBrowserViewController)
        #expect(controller.numberOfStickers(in: controller.stickerBrowserView) == 1)
        _ = controller.stickerBrowserView(controller.stickerBrowserView, stickerAt: 0)
        #expect(controller.view.accessibilityIdentifier == "sticker-factory-messages-browser")
        // Tap-to-insert and peel/drag are owned by MSStickerBrowserViewController;
        // the physical gestures remain part of the real-device release check.
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
