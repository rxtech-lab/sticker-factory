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
}
