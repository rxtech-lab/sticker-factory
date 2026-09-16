import XCTest

@MainActor
final class StickerSequenceUITests: XCTestCase {
    private func assertHalfHeight(in app: XCUIApplication, title: String) {
        let bar = app.navigationBars[title]
        XCTAssertTrue(bar.waitForExistence(timeout: 15))
        let settled = NSPredicate { _, _ in bar.frame.minY > app.frame.height * 0.4 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 8), .completed)
        XCTAssertLessThan(bar.frame.minY, app.frame.height * 0.65)
        let player = app.descendants(matching: .any).matching(identifier: "full-screen-sticker-player").firstMatch
        XCTAssertTrue(player.exists)
        XCTAssertGreaterThan(player.frame.height, 100)
        XCTAssertLessThanOrEqual(player.frame.maxY, bar.frame.minY + 30)
    }

    override func setUp() async throws {
        // `StickerGeniOSUITestsLaunchTests` runs once per target application UI configuration and
        // leaves the device in landscape; this suite sorts right after it. In that height the
        // controls sheet has to scroll, which slides the mode picker under the navigation bar and
        // sends its taps to the bar instead, so start every test from a known portrait device.
        await MainActor.run { XCUIDevice.shared.orientation = .portrait }
    }

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
        func assertHalfHeight(_ title: String) {
            self.assertHalfHeight(in: app, title: title)
        }
        let card = element("library-sticker-sticker-demo")
        XCTAssertTrue(card.waitForExistence(timeout: 15)); card.tap()
        let preview = element("show-sticker-attachment")
        XCTAssertTrue(preview.waitForExistence(timeout: 15)); preview.tap()
        XCTAssertTrue(element("sticker-controls-sheet").waitForExistence(timeout: 15))
        // Expand the drawer so the list and actions can be exercised together.
        app.navigationBars["Sticker Controls"].swipeUp()
        element("sticker-controls-reset").tap()
        app.segmentedControls["sticker-playback-mode"].buttons["Multiple"].tap()
        XCTAssertTrue(element("sticker-sequence-entry-0").waitForExistence(timeout: 15))
        element("sticker-sequence-add").tap()
        assertHalfHeight("Animation 2")
        app.navigationBars["Animation 2"].swipeUp()
        assertHalfHeight("Animation 2")
        XCTAssertTrue(element("sticker-control-mood").waitForExistence(timeout: 15))
        element("sticker-control-mood").tap()
        XCTAssertTrue(app.buttons["Calm"].waitForExistence(timeout: 15))
        XCTAssertGreaterThan(app.buttons["Calm"].frame.minY, app.frame.height * 0.4)
        app.buttons["Calm"].tap()
        app.sliders["sticker-controls-speed"].adjust(toNormalizedSliderPosition: 0.8)
        app.buttons["Done"].tap()
        XCTAssertTrue(element("sticker-sequence-entry-1").waitForExistence(timeout: 15))
        assertHalfHeight("Sticker Controls")
        element("sticker-sequence-entry-1").tap()
        assertHalfHeight("Animation 2")
        XCTAssertTrue(element("sticker-control-mood").label.contains("Calm"))
        app.buttons["Done"].tap()
        // The main drawer can expand again after returning from the editor.
        app.navigationBars["Sticker Controls"].swipeUp()
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Multiple animation controls"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Use the list's real native reorder handle, then verify the edited pose moved with it.
        //
        // A row has to be picked up before it can be moved, and dropped deliberately once it is
        // there. The default drag is too quick on both counts for a loaded clone: the press ends
        // before the lift, or the release lands while the list is still animating, and the row
        // returns to where it started — which arrives here as the edited pose never having moved,
        // with no sign that anything was dragged at all. A drag that did not take leaves nothing
        // to undo, so it is simply repeated until the list agrees.
        let handles = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder'"))
        XCTAssertEqual(handles.count, 2)
        let promoted = element("sticker-sequence-entry-0")
        for _ in 0..<3 where !promoted.label.contains("Calm") {
            handles.element(boundBy: 1).press(
                forDuration: 1,
                thenDragTo: handles.element(boundBy: 0),
                withVelocity: .slow,
                thenHoldForDuration: 0.5
            )
        }
        XCTAssertTrue(promoted.label.contains("Calm"), app.debugDescription)
        element("sticker-controls-apply").tap()
        XCTAssertTrue(element("sticker-controls-sheet").waitForNonExistence(timeout: 15))
        element("show-sticker-controls").tap()
        XCTAssertTrue(element("sticker-sequence-entry-0").waitForExistence(timeout: 15))
        XCTAssertTrue(element("sticker-sequence-entry-0").label.contains("Calm"))

        // Delete through the row action and confirm a draft export opens without publishing.
        element("sticker-sequence-entry-1").coordinate(withNormalizedOffset: CGVector(dx: 0.075, dy: 0.5)).tap()
        app.buttons["Delete"].tap()
        XCTAssertFalse(element("sticker-sequence-entry-1").exists)
        XCTAssertFalse(app.navigationBars["Sticker Controls"].buttons["sticker-viewer-export"].exists)
        // Collapse the controls to reach the viewer toolbar without applying the draft. A flick
        // carries the drawer past `.medium` often enough to dismiss the sheet outright, so the
        // way back down is a held drag at a controlled speed — the same reason `pullToRefresh`
        // in `StickerGeniOSUITests` does not use `swipeDown()`.
        let controlsBar = app.navigationBars["Sticker Controls"]
        controlsBar.swipeUp()
        XCTAssertTrue(controlsBar.waitForExistence(timeout: 15))
        controlsBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)),
            withVelocity: .slow,
            thenHoldForDuration: 0.5
        )
        XCTAssertTrue(element("sticker-controls-sheet").exists)
        XCTAssertFalse(element("sticker-sequence-entry-1").exists)
        let export = app.buttons["sticker-viewer-export"]
        XCTAssertTrue(export.exists)
        XCTAssertFalse(element("sticker-controls-sheet").buttons["Full Screen"].exists)
        XCTAssertFalse(element("sticker-controls-sheet").buttons["Edit"].exists)
        export.tap()
        XCTAssertTrue(element("viewer-export-format").waitForExistence(timeout: 15))
        element("viewer-export-start").tap()
        // A real encode followed by the system share sheet, both of which slow down sharply when
        // sibling simulator clones are competing for the host.
        XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 90) || app.otherElements["ActivityListView"].exists)
    }

}
