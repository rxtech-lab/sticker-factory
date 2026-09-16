import XCTest

@MainActor
final class ChatToolSheetUITests: StickerGeniOSUITestCase {
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
