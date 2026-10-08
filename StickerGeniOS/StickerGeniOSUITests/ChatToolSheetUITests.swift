import XCTest

@MainActor
final class ChatToolSheetUITests: StickerGeniOSUITestCase {
    func testSVGStatusCardShowsRetryAndTokenProgress() {
        app.terminate()
        app.launchArguments.append("--ui-svg-working-progress")
        app.launch()
        element("library-sticker-sticker-demo").tap()
        let card = element("assistant-working-card")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "label CONTAINS %@", "Attempt 3 of 3"), evaluatedWith: card)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(card.label.contains("610"))
        XCTAssertTrue(element("chat-title-chip").label.contains("Drawing SVG artwork for Cat"))
        XCTAssertTrue(element("tool-call-group").exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "svg-live-status-and-tool-cards"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
    func testSVGValidationCardShowsAttemptDurationAndRetryDetails() {
        app.terminate()
        app.launchArguments.append("--ui-svg-progress")
        app.launch()
        element("library-sticker-sticker-demo").tap()
        let tool = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Tool Checking SVG animation · Cat (2),")).firstMatch
        XCTAssertTrue(tool.waitForExistence(timeout: 15))
        tool.tap()
        XCTAssertTrue(app.staticTexts["Missing walk pose"].waitForExistence(timeout: 5))
        XCTAssertEqual(element("svg-tool-attempt").value as? String, "2 of 3")
        XCTAssertTrue(element("svg-tool-duration").exists)
        XCTAssertTrue(app.staticTexts["Trying again with the same reference (attempt 3 of 3)."].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "svg-validation-tool-card"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
    @MainActor
    func testViewToolSheetShowsSavedImage() {
        app.terminate()
        app.launchArguments.append("--ui-tool-preview")
        app.launch()
        element("library-sticker-sticker-demo").tap()
        let tool = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Tool view_sticker,")).firstMatch
        XCTAssertTrue(tool.waitForExistence(timeout: 15))
        tool.tap()
        XCTAssertTrue(element("tool-result-image").waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "previewAssetId")).firstMatch.exists)
    }

    @MainActor
    func testComposePartToolSheetShowsSavedImage() {
        assertToolPreview(argument: "--ui-compose-preview", name: "compose-part:0 Heart")
    }

    @MainActor
    func testAdjustLayoutToolSheetShowsSavedImage() {
        assertToolPreview(argument: "--ui-layout-preview", name: "adjust_layout")
    }

    @MainActor
    private func assertToolPreview(argument: String, name: String) {
        app.terminate()
        app.launchArguments += ["--ui-tool-preview", argument]
        app.launch()
        element("library-sticker-sticker-demo").tap()
        let tool = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Tool \(name),")).firstMatch
        XCTAssertTrue(tool.waitForExistence(timeout: 15))
        tool.tap()
        XCTAssertTrue(element("tool-result-image").waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "previewAssetId")).firstMatch.exists)
    }
}
