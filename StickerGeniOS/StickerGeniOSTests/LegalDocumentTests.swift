import Foundation
import Testing
@testable import StickerGeniOS

@Suite("Account legal documents")
struct LegalDocumentTests {
    @Test("Legal documents resolve beneath the configured API base URL")
    func endpointURLs() throws {
        let baseURL = try #require(URL(string: "https://sticker.rxlab.app"))

        #expect(LegalDocument.privacy.url(relativeTo: baseURL).absoluteString == "https://sticker.rxlab.app/api/v1/legal/privacy")
        #expect(LegalDocument.terms.url(relativeTo: baseURL).absoluteString == "https://sticker.rxlab.app/api/v1/legal/terms")
    }
}
