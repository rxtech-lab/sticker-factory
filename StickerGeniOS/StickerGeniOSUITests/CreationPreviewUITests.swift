import XCTest

@MainActor
final class CreationPreviewUITests: StickerGeniOSUITestCase {
    @MainActor
    func testStaticCreationOpensChat() {
        openCreateSheet()
        XCTAssertFalse(element("sticker-kind-picker").exists)
        XCTAssertTrue(element("add-reference-images").exists)
        XCTAssertFalse(app.buttons["Review privacy"].exists)

        let prompt = element("sticker-prompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: 15))
        prompt.tap()
        prompt.typeText("A cheerful blue cloud with a thick white outline")

        finishCreationChoices()
        let generate = element("generate-sticker-button")
        XCTAssertTrue(generate.isEnabled)
        generate.tap()

        // Generation always continues in the chat; there is no separate detail screen.
        XCTAssertTrue(element("chat-composer").waitForExistence(timeout: 15))
        XCTAssertTrue(element("sticker-actions-menu").exists)
        XCTAssertFalse(app.tabBars.buttons["Library"].exists)
    }

    @MainActor
    func testAnimatedPreviewOpensFullScreenPlayer() {
        let card = element("library-sticker-sticker-demo")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        // Tap the artwork itself, not the title or kind label. The animated UIKit-backed preview
        // must still hand the gesture to the card's navigation link.
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()

        // The assistant attaches the sticker to its own message; that attachment is the preview.
        let preview = element("show-sticker-attachment")
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        preview.tap()
        XCTAssertTrue(element("full-screen-sticker-player").waitForExistence(timeout: 15))
        element("dismiss-full-screen-player").tap()
        XCTAssertFalse(element("full-screen-sticker-player").exists)
    }

    @MainActor
    func testConfigurablePreviewRemembersApplyAndDiscardsCancel() {
        app.terminate()
        app.launchArguments.append("--ui-configurable-sticker")
        app.launch()
        let card = element("library-sticker-sticker-demo")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        let preview = element("show-sticker-attachment")
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        preview.tap()
        XCTAssertTrue(element("sticker-controls-sheet").waitForExistence(timeout: 15))
        // The controls sheet stops at the medium detent with background interaction enabled, so the
        // sticker it is configuring stays on screen above it rather than being covered.
        XCTAssertTrue(element("full-screen-sticker-player").exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Configurable sticker medium sheet"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        element("sticker-controls-reset").tap()
        element("sticker-control-mood").tap()
        app.buttons["Calm"].tap()
        app.switches["sticker-controls-animate"].tap()
        XCTAssertTrue(element("sticker-controls-frame").exists)
        element("sticker-controls-apply").tap()

        // Applying saves and closes the controls, but leaves the player behind them up. Going all
        // the way back to the transcript and in again is what proves the pose was persisted rather
        // than merely still sitting in the sheet's own state.
        reopenControlsFromTranscript(preview)
        let mood = element("sticker-control-mood")
        XCTAssertTrue((mood.label + String(describing: mood.value)).contains("Calm"))
        XCTAssertEqual(app.switches["sticker-controls-animate"].value as? String, "0")

        element("sticker-controls-reset").tap()
        app.buttons["Cancel"].tap()
        reopenControlsFromTranscript(preview)
        XCTAssertTrue((mood.label + String(describing: mood.value)).contains("Calm"))
        element("sticker-controls-reset").tap()
        element("sticker-controls-apply").tap()
    }

    /// Leaves the full-screen player for the transcript and opens the controls again from the
    /// sticker attachment there. Both Apply and Cancel close the controls without closing the
    /// player, so the attachment is one more dismissal away than it looks.
    private func reopenControlsFromTranscript(_ preview: XCUIElement) {
        XCTAssertTrue(element("sticker-controls-sheet").waitForNonExistence(timeout: 15))
        element("dismiss-full-screen-player").tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        for _ in 0..<10 where !preview.isHittable { usleep(200_000) }
        preview.tap()
        XCTAssertTrue(element("sticker-controls-sheet").waitForExistence(timeout: 15))
    }

    /// The switch that asks for a character whose mood and pose are switchable, instead of the user
    /// having to know to write "moods I can switch between" in the prompt. It belongs to animated
    /// stickers alone: a still has no clips to switch between.
    @MainActor
    func testControllableSwitchFollowsTheStickerType() {
        openCreateSheet()
        enterCreationIdea()
        let picker = element("sticker-kind-picker")
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        // The kind has to actually be Animated before moving on, and the picker existing does not
        // mean its buttons are hittable yet. When this tap was dropped the run stayed on Static,
        // whose path has no controllable step at all, so it sailed past to the overview and failed
        // 12 lines later at the toggle — reading as "the toggle is missing" rather than "the kind
        // never changed". The demo preview is the segment's own confirmation that it took, and
        // selecting Animated twice selects Animated.
        XCTAssertTrue(tap(picker.buttons.element(boundBy: 1), until: element("creation-animated-preview")),
                      "the Animated kind never took: \(app.debugDescription)")
        element("creation-next").tap()
        let preset = element("preset-option-style-bold-cartoon")
        XCTAssertTrue(preset.waitForExistence(timeout: 15))
        preset.tap()
        element("creation-next").tap()
        element("creation-next").tap()
        let toggle = element("sticker-controllable-toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 15), app.debugDescription)
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.switches.firstMatch.value as? String, "1")
        element("creation-next").tap()
        element("creation-overview-kind").tap()
        element("sticker-kind-picker").buttons.element(boundBy: 0).tap()
        element("creation-next").tap()
        XCTAssertFalse(element("creation-overview-animation").exists)
    }

    @MainActor
    func testUploadFailureRemainsRecoverableInCreate() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reduce-motion", "--ui-upload-failure"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 15))
        openCreateSheet()

        let prompt = element("sticker-prompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: 15))
        prompt.tap()
        prompt.typeText("A recoverable upload failure")
        finishCreationChoices()
        element("generate-sticker-button").tap()

        let error = element("error-banner")
        XCTAssertTrue(error.waitForExistence(timeout: 15))
        XCTAssertTrue(error.label.localizedCaseInsensitiveContains("upload"))
        XCTAssertTrue(element("generate-sticker-button").isEnabled)
    }

    @MainActor
    func testAdaptiveLayoutKeepsPrimaryActionsVisible() {
        openCreateSheet()
        XCTAssertTrue(element("sticker-prompt").waitForExistence(timeout: 15))
        XCTAssertTrue(element("sticker-prompt").isHittable)
        XCTAssertTrue(element("creation-next").isHittable)
        XCTAssertFalse(element("generate-sticker-button").exists)
    }
}
