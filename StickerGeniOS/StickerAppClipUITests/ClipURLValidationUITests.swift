import XCTest

@MainActor
final class ClipURLValidationUITests: ClipUITestCase {
    func testQuickModeURLVariants() {
        for url in ["https://sticker.rxlab.app/share/ios", "https://sticker.rxlab.app/share/ios/?source=messages#open",
                    "https://sticker.rxlab.app:443/share/ios"] {
            open(url)
            assertQuick()
            app.terminate()
        }
    }

    func testEncodedPathSeparatorsAreRejected() {
        for url in ["https://sticker.rxlab.app/share/ios/packs/happy%2Fcats",
                    "https://sticker.rxlab.app/share/ios/packs/happy%5Ccats"] {
            open(url)
            assertQuick()
            app.terminate()
        }
    }

    func testUnsupportedURLsStayInQuickMode() {
        for url in ["http://sticker.rxlab.app/share/ios", "stickerfactoryclip://share/ios",
                    "https://example.com/share/ios", "https://sticker.rxlab.app:444/share/ios",
                    "https://user@sticker.rxlab.app/share/ios", "https://sticker.rxlab.app/share/android",
                    "https://sticker.rxlab.app/share/ios/packs", "https://sticker.rxlab.app/share/ios/packs/cats/extra"] {
            open(url)
            assertQuick()
            app.terminate()
        }
    }
}
