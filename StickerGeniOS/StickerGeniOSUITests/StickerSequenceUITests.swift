import XCTest

@MainActor
final class StickerSequenceUITests: XCTestCase {
    override func tearDown() async throws {
        await MainActor.run {
            let shot = XCTAttachment(screenshot: XCUIApplication().screenshot())
            shot.name = "Sequence controls result"
            shot.lifetime = .keepAlways
            add(shot)
        }
    }

    func testSequenceEditingPersistenceAndDraftExport() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-configurable-sticker", "--reduce-motion",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
        let card = element("library-sticker-sticker-demo")
        XCTAssertTrue(card.waitForExistence(timeout: 10)); card.tap()
        let preview = element("show-sticker-attachment")
        XCTAssertTrue(preview.waitForExistence(timeout: 5)); preview.tap()
        XCTAssertTrue(element("sticker-controls-sheet").waitForExistence(timeout: 5))
        // Expand the drawer so the list and actions can be exercised together.
        app.navigationBars["Sticker Controls"].swipeUp()
        element("sticker-controls-reset").tap()
        app.segmentedControls["sticker-playback-mode"].buttons["Multiple"].tap()
        XCTAssertTrue(element("sticker-sequence-entry-0").waitForExistence(timeout: 3))
        element("sticker-sequence-add").tap()
        XCTAssertTrue(app.navigationBars["Animation 2"].waitForExistence(timeout: 3))
        XCTAssertTrue(element("sticker-control-mood").waitForExistence(timeout: 3))
        element("sticker-control-mood").tap()
        XCTAssertTrue(app.buttons["Calm"].waitForExistence(timeout: 3))
        app.buttons["Calm"].tap()
        app.sliders["sticker-controls-speed"].adjust(toNormalizedSliderPosition: 0.8)
        app.buttons["Done"].tap()
        XCTAssertTrue(element("sticker-sequence-entry-1").waitForExistence(timeout: 3))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Multiple animation controls"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Use the list's real native reorder handle, then verify the edited pose moved with it.
        let handles = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder'"))
        XCTAssertEqual(handles.count, 2)
        handles.element(boundBy: 1).press(forDuration: 0.5, thenDragTo: handles.element(boundBy: 0))
        XCTAssertTrue(element("sticker-sequence-entry-0").label.contains("Calm"))
        element("sticker-controls-apply").tap()
        XCTAssertTrue(element("sticker-controls-sheet").waitForNonExistence(timeout: 5))
        element("show-sticker-controls").tap()
        XCTAssertTrue(element("sticker-sequence-entry-0").waitForExistence(timeout: 5))
        XCTAssertTrue(element("sticker-sequence-entry-0").label.contains("Calm"))

        // Delete through the row action and confirm a draft export opens without publishing.
        element("sticker-sequence-entry-1").coordinate(withNormalizedOffset: CGVector(dx: 0.075, dy: 0.5)).tap()
        app.buttons["Delete"].tap()
        XCTAssertFalse(element("sticker-sequence-entry-1").exists)
        XCTAssertFalse(app.navigationBars["Sticker Controls"].buttons["sticker-viewer-export"].exists)
        // Collapse the controls to reach the viewer toolbar without applying the draft.
        app.navigationBars["Sticker Controls"].swipeUp()
        app.navigationBars["Sticker Controls"].swipeDown()
        XCTAssertTrue(element("sticker-controls-sheet").exists)
        XCTAssertFalse(element("sticker-sequence-entry-1").exists)
        let export = app.buttons["sticker-viewer-export"]
        XCTAssertTrue(export.exists)
        XCTAssertFalse(element("sticker-controls-sheet").buttons["Full Screen"].exists)
        XCTAssertFalse(element("sticker-controls-sheet").buttons["Edit"].exists)
        export.tap()
        XCTAssertTrue(element("viewer-export-format").waitForExistence(timeout: 5))
        element("viewer-export-start").tap()
        XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 30) || app.otherElements["ActivityListView"].exists)
    }
}
