import XCTest

@MainActor
final class StickerPlanUITests: StickerGeniOSUITestCase {
    @MainActor
    func testPlanSpriteAddOptionAppearsAndSurvivesSave() {
        app.terminate()
        app.launchArguments.append("--ui-sprite-plan")
        app.launch()
        let card = element("library-sticker-sticker-demo")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        let editLayers = element("plan-edit-layers")
        XCTAssertTrue(editLayers.waitForExistence(timeout: 15))
        editLayers.tap()
        XCTAssertTrue(element("plan-editor-sheet").waitForExistence(timeout: 15))

        let scroll = app.scrollViews.firstMatch
        let pose = app.buttons["Pose"]
        for _ in 0..<8 where !pose.isHittable { scroll.swipeUp() }
        XCTAssertTrue(pose.isHittable)
        pose.tap()
        let addOption = app.buttons["Add option"]
        for _ in 0..<4 where !addOption.isHittable { scroll.swipeUp() }
        XCTAssertTrue(addOption.isHittable)
        addOption.tap()

        let option = app.textFields.matching(NSPredicate(format: "value == %@", "New option")).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 15))
        option.tap()
        option.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "New option".count) + "Resting")
        let save = app.buttons["plan-editor-save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(element("plan-editor-sheet").waitForNonExistence(timeout: 15))

        XCTAssertTrue(editLayers.waitForExistence(timeout: 15))
        editLayers.tap()
        XCTAssertTrue(element("plan-editor-sheet").waitForExistence(timeout: 15))
        for _ in 0..<8 where !pose.isHittable { scroll.swipeUp() }
        XCTAssertTrue(pose.isHittable)
        pose.tap()
        let savedOption = app.textFields.matching(NSPredicate(format: "value == %@", "Resting")).firstMatch
        XCTAssertTrue(savedOption.waitForExistence(timeout: 15))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Added sprite option after saving"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testPlanImagesOpenFullScreenAndZoom() {
        app.terminate()
        app.launchArguments.append("--ui-plan-versions")
        app.launch()
        element("library-sticker-sticker-demo").tap()
        for imageID in ["plan-static-reference", "plan-animation-summary"] {
            let image = app.buttons[imageID]
            XCTAssertTrue(image.waitForExistence(timeout: 15))
            let scroll = app.scrollViews.firstMatch
            for _ in 0..<8 {
                if image.frame.midY < 220 {
                    scroll.swipeDown()
                } else if image.frame.midY > 700 {
                    scroll.swipeUp()
                } else {
                    break
                }
            }
            XCTAssertTrue(image.isHittable)
            image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let close = app.buttons["plan-image-close"]
            XCTAssertTrue(close.waitForExistence(timeout: 15))
            let reset = app.buttons["plan-image-reset-zoom"]
            XCTAssertEqual(reset.value as? String, "100%")
            app.buttons["plan-image-zoom-in"].tap()
            XCTAssertEqual(reset.value as? String, "150%")
            app.buttons["plan-image-zoom-out"].tap()
            XCTAssertEqual(reset.value as? String, "100%")
            let surface = element("plan-image-zoom-surface")
            surface.pinch(withScale: 2, velocity: 1)
            XCTAssertNotEqual(reset.value as? String, "100%")
            surface.swipeLeft()
            reset.tap()
            XCTAssertEqual(reset.value as? String, "100%")
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = imageID + " fullscreen"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            close.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: 15))
        }
    }

    @MainActor
    func testPlanVersionPickerActivatesSelectedVersionInLatestCard() {
        app.terminate()
        app.launchArguments.append("--ui-plan-versions")
        app.launch()
        element("library-sticker-sticker-demo").tap()

        let picker = element("plan-version-picker")
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        app.scrollViews.firstMatch.swipeDown()
        XCTAssertEqual(picker.value as? String, "Version 2")
        XCTAssertTrue(app.staticTexts["Revised bounce"].exists)
        let currentScreenshot = XCTAttachment(screenshot: app.screenshot())
        currentScreenshot.name = "Current plan version"
        currentScreenshot.lifetime = .keepAlways
        add(currentScreenshot)
        XCTAssertTrue(picker.isEnabled)
        app.scrollViews.firstMatch.swipeUp()
        picker.tap()
        XCTAssertTrue(element("plan-versions-sheet").waitForExistence(timeout: 15))
        let carousel = element("plan-version-carousel")
        XCTAssertTrue(carousel.exists)
        carousel.swipeRight()
        let sheetScreenshot = XCTAttachment(screenshot: app.screenshot())
        sheetScreenshot.name = "Horizontal plan version selector"
        sheetScreenshot.lifetime = .keepAlways
        add(sheetScreenshot)
        element("select-plan-version-1").tap()
        XCTAssertTrue(element("plan-versions-sheet").waitForNonExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Original wave"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Waving character"].exists)
        XCTAssertFalse(element("plan-preview-only").exists)
        XCTAssertEqual(picker.value as? String, "Version 1")
        let historyScreenshot = XCTAttachment(screenshot: app.screenshot())
        historyScreenshot.name = "Historical plan preview"
        historyScreenshot.lifetime = .keepAlways
        add(historyScreenshot)
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(element("composition-plan-generate").exists)
        XCTAssertTrue(element("composition-plan-dismiss").exists)
        let generate = app.buttons["composition-plan-generate"]
        XCTAssertTrue(generate.isEnabled)
        generate.tap()
        XCTAssertTrue(app.buttons["Build"].waitForExistence(timeout: 15))
        // Compact confirmation popovers can omit Cancel; tapping outside dismisses them.
        app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Build"].waitForNonExistence(timeout: 15))

        picker.tap()
        XCTAssertTrue(element("plan-versions-sheet").waitForExistence(timeout: 15))
        carousel.swipeLeft()
        element("select-plan-version-2").tap()
        XCTAssertTrue(element("plan-versions-sheet").waitForNonExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Revised bounce"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Bouncing character"].exists)
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(element("composition-plan-generate").exists)
        XCTAssertTrue(element("composition-plan-dismiss").exists)
        XCTAssertFalse(element("plan-preview-only").exists)
    }
}
