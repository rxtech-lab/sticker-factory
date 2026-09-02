import Foundation
import Testing
@testable import StickerGeniOS

@Suite("Sticker deep links")
struct StickerDeepLinkTests {
    @Test("Messages creation links open the exact sticker project")
    func createdStickerLink() throws {
        let id = "4A1EF35B-436F-481A-B733-43A890DA6154"
        let url = try #require(URL(string: "stickerfactory://sticker/\(id)?source=fullsize"))
        #expect(StickerDeepLink.stickerID(from: url) == id.lowercased())
    }

    @Test("OAuth and malformed links are not consumed as sticker links")
    func unrelatedLinks() throws {
        #expect(StickerDeepLink.stickerID(from: try #require(URL(string: "stickerfactory://oauth/callback?code=abc"))) == nil)
        #expect(StickerDeepLink.stickerID(from: try #require(URL(string: "stickerfactory://sticker/not-a-uuid"))) == nil)
        #expect(StickerDeepLink.stickerID(from: try #require(URL(string: "https://example.com/sticker/4A1EF35B-436F-481A-B733-43A890DA6154"))) == nil)
    }
}
