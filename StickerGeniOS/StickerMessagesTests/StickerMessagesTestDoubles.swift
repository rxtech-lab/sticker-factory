import Foundation
import Messages
import Testing
import UIKit
@testable import StickerMessages

// Token bundles, transports and JWT helpers shared by the Messages extension contract tests.

struct MainTokenBundle: Codable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresAt: Date
    let subject: String?
}

final class MessagesInMemoryTokenStorage: SharedTokenStorageProtocol, @unchecked Sendable {
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

actor MessagesCountingRefreshTransport: SharedOAuthRefreshTransport {
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

actor SectionedStickerTransport: StickerHTTPTransport {
    private var appVersions: [String?] = []
    private var languages: [String?] = []

    func data(for request: URLRequest) async throws -> StickerHTTPResult {
        appVersions.append(request.value(forHTTPHeaderField: "X-iOS-App-Version"))
        languages.append(request.value(forHTTPHeaderField: "Accept-Language"))
        let url = try #require(request.url)
        let body = Data("""
        {"sections":[
          {"id":"mine","kind":"mine","title":"My Stickers","creator":null,"stickers":[
            {"id":"mine-1","title":"Mine","updatedAt":"2026-08-24T12:00:00Z","systemSticker":{"assetId":"a1","mimeType":"image/png",\
            "byteSize":100,"sha256":"abc"}}
          ]},
          {"id":"pack:p1","kind":"pack","title":"Cozy Cats","creator":{"handle":"mika-lin-4f2a9c","displayName":"Mika Lin"},"stickers":[
            {"id":"borrowed-1","title":"Loaf","updatedAt":"2026-08-24T12:00:01Z","systemSticker":{"assetId":"a2","mimeType":"image/png",\
            "byteSize":100,"sha256":"def"}},
            {"id":"borrowed-2","title":"Nap","updatedAt":"2026-08-24T12:00:02Z","systemSticker":{"assetId":"a3","mimeType":"image/png",\
            "byteSize":100,"sha256":"ghi"}}
          ]}
        ],"generatedAt":"2026-08-24T12:00:05Z"}
        """.utf8)
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return .init(data: body, response: response)
    }

    func requestedAppVersions() -> [String?] { appVersions }
    func requestedLanguages() -> [String?] { languages }
}

/// One section covering every shape `previewAsset` arrives in, so the gating rules are exercised
/// against real JSON rather than hand-built descriptors.
actor PreviewAssetTransport: StickerHTTPTransport {
    func data(for request: URLRequest) async throws -> StickerHTTPResult {
        let url = try #require(request.url)
        func sticker(
            _ id: String,
            system: String,
            preview: String?,
            medium: String? = nil,
            small: String? = nil,
            webp: String? = nil
        ) -> String {
            let previewField = preview.map { "\"previewAsset\":\($0)," } ?? ""
            let mediumField = medium.map { "\"attachmentMedium\":\($0)," } ?? ""
            let smallField = small.map { "\"attachmentSmall\":\($0)," } ?? ""
            let webpField = webp.map { "\"webpAsset\":\($0)," } ?? ""
            return """
            {"id":"\(id)","title":"\(id)","updatedAt":"2026-08-24T12:00:00Z",\(previewField)\(mediumField)\(smallField)\(webpField)
             "systemSticker":{"assetId":"\(system)","mimeType":"image/png","byteSize":100,"sha256":"s"}}
            """
        }
        let stickers = [
            // The ordinary case: a 1024² master PNG alongside the 618 px sticker.
            sticker("full", system: "sys-1", preview: """
            {"id":"master-1","kind":"master","state":"ready","mimeType":"image/png","byteSize":900000,"width":1024,"height":1024,\
            "sha256":"m"}
            """),
            sticker("no-preview", system: "sys-2", preview: nil),
            // Animated with no APNG: the server's chain coalesces to the system asset itself.
            sticker("fallback", system: "sys-3", preview: """
            {"id":"sys-3","kind":"system","state":"ready","mimeType":"image/gif","byteSize":480000,"width":618,"height":618,"sha256":"f"}
            """),
            sticker("pending", system: "sys-4", preview: """
            {"id":"master-4","kind":"master","state":"pending","mimeType":"image/png","byteSize":900000,"width":1024,"height":1024,\
            "sha256":"p"}
            """),
            sticker("huge-pixels", system: "sys-5", preview: """
            {"id":"master-5","kind":"master","state":"ready","mimeType":"image/png","byteSize":900000,"width":4096,"height":4096,\
            "sha256":"h"}
            """),
            sticker("huge-bytes", system: "sys-6", preview: """
            {"id":"master-6","kind":"master","state":"ready","mimeType":"image/png","byteSize":99000000,"width":1024,"height":1024,\
            "sha256":"b"}
            """),
            sticker("webp", system: "sys-7", preview: """
            {"id":"master-7","kind":"master","state":"ready","mimeType":"image/webp","byteSize":900000,"width":1024,"height":1024,\
            "sha256":"w"}
            """),
            sticker("jpeg", system: "sys-7b", preview: """
            {"id":"master-7b","kind":"master","state":"ready","mimeType":"image/jpeg","byteSize":900000,"width":1024,"height":1024,\
            "sha256":"j"}
            """),
            // The ordinary published-since-WebP animated sticker: a 9.8 MB APNG and the WebP copy
            // of the same frames, which is what an `.image` send should reach for.
            sticker(
                "prefers-webp",
                system: "sys-11",
                preview: """
                {"id":"apng-11","kind":"apng","state":"ready","mimeType":"image/png","byteSize":9800000,"width":618,"height":618,\
                "sha256":"l11"}
                """,
                webp: """
                {"id":"webp-11","kind":"webp","state":"ready","mimeType":"image/webp","byteSize":410000,"width":618,"height":618,\
                "sha256":"w11"}
                """
            ),
            // A WebP that has not finished uploading. Offering it would spend a tap on a 404, and
            // the APNG that was always there is the right answer instead.
            sticker(
                "webp-pending",
                system: "sys-12",
                preview: """
                {"id":"apng-12","kind":"apng","state":"ready","mimeType":"image/png","byteSize":9800000,"width":618,"height":618,\
                "sha256":"l12"}
                """,
                webp: """
                {"id":"webp-12","kind":"webp","state":"pending","mimeType":"image/webp","byteSize":410000,"width":618,"height":618,\
                "sha256":"w12"}
                """
            ),
            sticker("gif", system: "sys-8", preview: """
            {"id":"share-8","kind":"gif","state":"ready","mimeType":"image/gif","byteSize":900000,"width":512,"height":512,"sha256":"g"}
            """),
            // What a sticker published since attachment renditions looks like: all three sizes.
            sticker(
                "sizes",
                system: "sys-9",
                preview: """
                {"id":"apng-9","kind":"apng","state":"ready","mimeType":"image/png","byteSize":900000,"width":618,"height":618,"sha256":"l"}
                """,
                medium: """
                {"id":"medium-9","kind":"attachment","state":"ready","mimeType":"image/png","byteSize":400000,"width":408,"height":408,\
                "sha256":"m9"}
                """,
                small: """
                {"id":"small-9","kind":"attachment","state":"ready","mimeType":"image/png","byteSize":200000,"width":300,"height":300,\
                "sha256":"s9"}
                """
            ),
            // Medium published, Small failed its gate. Asking for Small must land on Medium rather
            // than skipping straight to Large or refusing.
            sticker(
                "gap",
                system: "sys-10",
                preview: """
                {"id":"apng-10","kind":"apng","state":"ready","mimeType":"image/png","byteSize":900000,"width":618,"height":618,\
                "sha256":"l10"}
                """,
                medium: """
                {"id":"medium-10","kind":"attachment","state":"ready","mimeType":"image/png","byteSize":400000,"width":408,"height":408,\
                "sha256":"m10"}
                """,
                small: """
                {"id":"small-10","kind":"attachment","state":"pending","mimeType":"image/png","byteSize":200000,"width":300,"height":300,\
                "sha256":"s10"}
                """
            )
        ].joined(separator: ",")

        let body = Data("""
        {"sections":[{"id":"mine","kind":"mine","title":"My Stickers","creator":null,"stickers":[\(stickers)]}],
         "generatedAt":"2026-08-24T12:00:05Z"}
        """.utf8)
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return .init(data: body, response: response)
    }
}

/// Serves raw image bytes of a fixed size, so the same body can be accepted or rejected purely on
/// the ceiling the caller passed.
actor OversizedAssetTransport: StickerHTTPTransport {
    let byteCount: Int

    init(byteCount: Int) { self.byteCount = byteCount }

    func data(for request: URLRequest) async throws -> StickerHTTPResult {
        let url = try #require(request.url)
        var body = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        body.append(Data(repeating: 0, count: byteCount - body.count))
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png"]
        ))
        return .init(data: body, response: response)
    }
}

/// A server that predates the sections endpoint: 404 there, but the flat library still works.
actor SectionsMissingTransport: StickerHTTPTransport {
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
        {"data":[{"id":"sticker-1","title":"Sticker","updatedAt":"2026-08-24T12:00:00Z","systemSticker":{"assetId":"a1",\
        "mimeType":"image/png","byteSize":100,"sha256":"abc"}}],"nextCursor":null}
        """.utf8)
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return .init(data: body, response: response)
    }

    func paths() -> [String] { requestedPaths }
}

actor RejectedListingTransport: StickerHTTPTransport {
    func data(for request: URLRequest) async throws -> StickerHTTPResult {
        let url = try #require(request.url)
        let body = Data("""
        {"error":{"code":"IOS_APP_UPDATE_REQUIRED","message":"Update Winky Sticker Factory to version 1.2 or later to view your stickers.",\
        "requestId":"request-version"}}
        """.utf8)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 426,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return .init(data: body, response: response)
    }
}

actor PaginatedStickerTransport: StickerHTTPTransport {
    private var cursors: [String] = []

    func data(for request: URLRequest) async throws -> StickerHTTPResult {
        let url = try #require(request.url)
        let cursor = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "cursor" })?.value
        cursors.append(cursor ?? "<first>")
        let suffix = cursor == nil ? "1" : "2"
        let next = cursor == nil ? "\"page-2\"" : "null"
        let body = Data("""
        {"data":[{"id":"sticker-\(suffix)","title":"Sticker \(suffix)","updatedAt":"2026-08-24T12:00:0\(suffix)Z",\
        "systemSticker":{"assetId":"asset-\(suffix)","mimeType":"image/png","byteSize":100,"sha256":"abc"}}],"nextCursor":\(next)}
        """.utf8)
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return .init(data: body, response: response)
    }

    func requestedCursors() -> [String] { cursors }
}

actor FailingSecondPageTransport: StickerHTTPTransport {
    private var calls = 0

    func data(for request: URLRequest) async throws -> StickerHTTPResult {
        calls += 1
        if calls == 2 { throw URLError(.networkConnectionLost) }
        let url = try #require(request.url)
        let body = Data("""
        {"data":[{"id":"partial","title":"Partial","updatedAt":"2026-08-24T12:00:00Z","systemSticker":{"assetId":"asset-partial",\
        "mimeType":"image/png","byteSize":100,"sha256":"abc"}}],"nextCursor":"page-2"}
        """.utf8)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
        return .init(data: body, response: response)
    }

    func callCount() -> Int { calls }
}

func messagesJWT(subject: String, expiration: Date) throws -> String {
    let payloadData = try JSONSerialization.data(withJSONObject: [
        "sub": subject,
        "exp": expiration.timeIntervalSince1970
    ])
    let payload = payloadData.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(payload).signature"
}
