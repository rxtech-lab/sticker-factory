import XCTest

@MainActor
final class ClipGenerationUITests: ClipUITestCase {
    func testQuickGenerationSheetNavigatesToFinishedSticker() {
        launchLibrary()
        app.buttons["clip-new-sticker"].tap()
        XCTAssertTrue(app.navigationBars["New sticker"].waitForExistence(timeout: 15))
        let prompt = app.textFields["quick-prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 15))
        capture("App Clip quick generation sheet")
        prompt.tap()
        prompt.typeText("Skateboarding cat")
        app.swipeUp()
        app.buttons["Generate sticker"].tap()
        XCTAssertTrue(app.navigationBars["Skateboarding cat"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.buttons["clip-generation-close"].exists)
        XCTAssertTrue(app.buttons["Share sticker"].exists)
        capture("App Clip generation completed detail")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["clip-sticker-new-sticker"].waitForExistence(timeout: 15))
        app.buttons["clip-new-sticker"].tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 15))
        XCTAssertEqual(prompt.value as? String, "Describe your sticker")
    }

    func testGenerationFinishesAfterClosingSheet() {
        launchLibrary("--clip-slow-generation")
        app.buttons["clip-new-sticker"].tap()
        let prompt = app.textFields["quick-prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 15))
        prompt.tap()
        prompt.typeText("Skateboarding cat")
        app.swipeUp()
        app.buttons["Generate sticker"].tap()
        app.buttons["clip-generation-close"].tap()
        XCTAssertTrue(app.buttons["clip-generation-status"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.navigationBars["Skateboarding cat"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Share sticker"].exists)
    }
}
