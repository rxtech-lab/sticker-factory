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

    func testPackStickerOpensFullScreenWithPoses() {
        open("https://sticker.rxlab.app/share/ios/packs/happy-cats")
        assertPack("Happy Cats", sticker: "Waving cat")
        app.buttons["clip-pack-sticker-posable-1"].tap()
        XCTAssertTrue(app.navigationBars["Posable pet"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.navigationBars["Poses"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Mood"].exists)
        XCTAssertTrue(app.staticTexts["Pose"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["clip-viewer-live"].waitForExistence(timeout: 15))
        capture("App Clip pack sticker poses")
        app.buttons["Done"].tap()
        XCTAssertFalse(app.navigationBars["Poses"].waitForExistence(timeout: 2))
        app.buttons["clip-viewer-poses"].tap()
        XCTAssertTrue(app.navigationBars["Poses"].waitForExistence(timeout: 15))
        app.buttons["Done"].tap()
        app.buttons["clip-viewer-close"].tap()
        XCTAssertTrue(app.staticTexts["Happy Cats"].waitForExistence(timeout: 15))

        app.buttons["clip-pack-sticker-preview-1"].tap()
        XCTAssertTrue(app.navigationBars["Waving cat"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["clip-viewer-poses"].exists)
        app.buttons["clip-viewer-close"].tap()
    }

    func testUnavailablePackAndRetry() {
        open("https://sticker.rxlab.app/share/ios/packs/missing-pack")
        XCTAssertTrue(app.staticTexts["Pack unavailable"].waitForExistence(timeout: 15))
        app.buttons["Try again"].tap()
        XCTAssertTrue(app.staticTexts["This pack is no longer available."].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Install in Sticker Factory"].exists)
    }
}
