import Foundation
import Testing
@testable import StickerGeniOS

@Suite("Account about page")
struct AboutPageTests {
    @Test("About content resolves beneath the configured API base URL")
    func endpointURL() throws {
        let baseURL = try #require(URL(string: "https://sticker.rxlab.app"))

        let url = AboutPage.url(relativeTo: baseURL)

        #expect(url.absoluteString == "https://sticker.rxlab.app/api/v1/about")
    }

    @Test("A cancelled request never surfaces as a document failure")
    func cancelledRequestIsNotAFailure() {
        // `URLSession` reports a cancelled request as `URLError.cancelled`, so pull-to-refresh used
        // to render "Unable to Load — cancelled" until the user refreshed a second time.
        #expect(StickerStore.isCancellation(URLError(.cancelled)))
        #expect(StickerStore.isCancellation(CancellationError()))
        #expect(!StickerStore.isCancellation(URLError(.timedOut)))
        #expect(!StickerStore.isCancellation(MarkdownDocumentLoadingError.httpStatus(500)))
    }
}
