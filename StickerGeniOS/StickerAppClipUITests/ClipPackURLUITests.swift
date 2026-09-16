import XCTest

@MainActor
final class ClipPackURLUITests: ClipUITestCase {
    func testPackInvocationURL() {
        open("https://STICKER.RXLAB.APP:443/share/ios/packs/happy-cats?source=messages")
        assertPack("Happy Cats", sticker: "Waving cat")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "App Clip shared pack"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testPackURLVariants() {
        for url in ["https://sticker.rxlab.app/share/ios/packs/happy-cats",
                    "https://sticker.rxlab.app/share/ios/packs/happy-cats/?source=messages#preview"] {
            open(url)
            assertPack("Happy Cats", sticker: "Waving cat")
            app.terminate()
        }
    }

    func testSuccessiveURLLaunchesShowRequestedContent() {
        open("https://sticker.rxlab.app/share/ios/packs/happy-cats")
        assertPack("Happy Cats", sticker: "Waving cat")
        open("https://sticker.rxlab.app/share/ios/packs/space-dogs")
        assertPack("Space Dogs", sticker: "Moon dog")
        XCTAssertFalse(app.staticTexts["Happy Cats"].exists)
        open("https://sticker.rxlab.app/share/ios")
        assertQuick()
    }

    func testUnavailablePackAndRetry() {
        open("https://sticker.rxlab.app/share/ios/packs/missing-pack")
        XCTAssertTrue(app.staticTexts["Pack unavailable"].waitForExistence(timeout: 15))
        app.buttons["Try again"].tap()
        XCTAssertTrue(app.staticTexts["This pack is no longer available."].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Install in Sticker Factory"].exists)
    }
}
