import XCTest

@MainActor
final class ClipLibraryUITests: ClipUITestCase {
    func testPastStickerOpensDetailAndLibraryPaginates() {
        launchLibrary()
        let past = app.buttons["clip-sticker-past-sticker"]
        XCTAssertTrue(past.waitForExistence(timeout: 15))
        XCTAssertFalse(app.textFields["quick-prompt"].exists)
        capture("App Clip sticker library")
        past.tap()
        XCTAssertTrue(app.navigationBars["Happy cat"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Share sticker"].waitForExistence(timeout: 15))
        capture("App Clip sticker detail")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Load more stickers"].tap()
        XCTAssertTrue(app.buttons["clip-sticker-older-sticker"].waitForExistence(timeout: 15))
    }

    func testDetailOpensFullScreenWithPoses() {
        launchLibrary()
        let past = app.buttons["clip-sticker-past-sticker"]
        XCTAssertTrue(past.waitForExistence(timeout: 15))
        past.tap()
        let image = app.buttons["quick-result-image"]
        XCTAssertTrue(image.waitForExistence(timeout: 15))
        image.tap()
        XCTAssertTrue(app.navigationBars["Poses"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["clip-viewer-live"].waitForExistence(timeout: 15))
        capture("App Clip library sticker poses")
        app.buttons["Done"].tap()
        app.buttons["clip-viewer-close"].tap()
        XCTAssertTrue(app.buttons["Share sticker"].waitForExistence(timeout: 15))
    }

    func testLibraryWithLargeText() {
        launchLibrary("-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL")
        XCTAssertTrue(app.buttons["clip-sticker-past-sticker"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["clip-new-sticker"].isHittable)
        capture("App Clip library with large text")
    }

    func testEmptyLibraryAndSheetDismissal() {
        launchLibrary("--clip-library-empty")
        XCTAssertTrue(app.staticTexts["Your first sticker starts here"].waitForExistence(timeout: 15))
        capture("App Clip empty library")
        app.buttons["clip-new-sticker"].tap()
        let close = app.buttons["clip-generation-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 15))
        close.tap()
        XCTAssertTrue(app.navigationBars["My stickers"].waitForExistence(timeout: 15))
    }

    func testLibraryFailureCanRetryAndStillCreate() {
        launchLibrary("--clip-library-error")
        XCTAssertTrue(app.staticTexts["Your stickers could not be loaded. Please try again."].waitForExistence(timeout: 15))
        app.buttons["Try again"].tap()
        XCTAssertTrue(app.buttons["clip-new-sticker"].exists)
        app.buttons["clip-new-sticker"].tap()
        XCTAssertTrue(app.navigationBars["New sticker"].waitForExistence(timeout: 15))
    }
}
