import Foundation
import Testing
@testable import StickerGeniOS

struct StickerShareRouteTests {
    @Test func quickAndPackLinks() throws {
        #expect(StickerShareRoute(url: StickerShareRoute.homeURL) == .quick)
        #expect(StickerShareRoute(url: StickerShareRoute.packURL("happy-corgis")) == .pack("happy-corgis"))
        #expect(StickerShareRoute(url: URL(string: "https://sticker.rxlab.app/share/ios?source=messages")!) == .quick)
        #expect(StickerShareRoute.appStoreURL.absoluteString == "https://apps.apple.com/app/id6805825708")
    }
    @Test func ignoresForeignOrMalformedLinks() {
        for string in ["http://sticker.rxlab.app/share/ios", "https://other.rxlab.app/share/ios",
                       "https://sticker.rxlab.app/marketplace/a", "https://sticker.rxlab.app/share/ios/packs",
                       "https://sticker.rxlab.app/share/ios/packs/a/extra", "https://user@sticker.rxlab.app/share/ios",
                       "https://sticker.rxlab.app/share/ios/packs/%2Fsecret", "https://sticker.rxlab.app:444/share/ios"] {
            #expect(StickerShareRoute(url: URL(string: string)!) == nil)
        }
    }
}
