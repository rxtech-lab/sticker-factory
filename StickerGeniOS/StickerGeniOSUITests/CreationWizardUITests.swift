import XCTest

@MainActor final class CreationWizardUITests: XCTestCase {
    private var app: XCUIApplication!
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(_ flags: [String] = [], reduceMotion: Bool = true) {
        app = XCUIApplication()
        app.launchArguments =
            ["--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + flags
            + (reduceMotion ? ["--reduce-motion"] : [])
        if let covers =
            (ProcessInfo.processInfo.environment["CREATION_COVER_BASE_URL"]
                ?? ProcessInfo.processInfo.environment["TEST_RUNNER_CREATION_COVER_BASE_URL"]) {
            app.launchArguments.append("--ui-creation-covers=\(covers)")
        }
        app.launch()
        XCTAssertTrue(element("create-sticker-button").waitForExistence(timeout: 15))
        element("create-sticker-button").tap()
        XCTAssertTrue(element("sticker-prompt").waitForExistence(timeout: 15))
    }
    private func next() { element("creation-next").tap() }
    private func idea(_ text: String = "A friendly orange cat") {
        // The motion-enabled launch presents this sheet with a full animation, so the tap has to
        // wait the presentation out rather than fire as soon as the field exists.
        let prompt = element("sticker-prompt")
        XCTAssertTrue(focusTextField(prompt, in: app), app.debugDescription)
        prompt.typeText(text); next()
    }
    private func choices(style: String = "bold-cartoon", themes: [String] = []) {
        next()
        let option = element("preset-option-style-\(style)")
        XCTAssertTrue(option.waitForExistence(timeout: 15)); tapVisible(option)
        next()
        for id in themes { tapVisible(element("preset-option-theme-\(id)")) }
        next()
        skipReferences()
    }

    /// Steps over the references page when the wizard is sitting on it.
    ///
    /// References sit between the preset pages and whatever follows them, and no test here picks
    /// one. Stepping over it leaves the caller on the page after the presets — the overview for a
    /// static sticker, the animation page for an animated one.
    private func skipReferences() {
        if element("add-reference-images").waitForExistence(timeout: 2) { next() }
    }

    /// Advances to the review page from wherever the wizard is, by what is on screen.
    ///
    /// The steps between the last preset page and the overview are not a fixed count: references
    /// is one, animation is another and only exists for an animated sticker.
    private func toOverview() {
        let generate = element("generate-sticker-button")
        for _ in 0..<6 {
            if generate.waitForExistence(timeout: 2) { return }
            let forward = element("creation-next")
            guard forward.exists, forward.isHittable else { continue }
            forward.tap()
        }
        XCTAssertTrue(generate.waitForExistence(timeout: 15), app.debugDescription)
    }
    private func tapVisible(_ item: XCUIElement) {
        for _ in 0..<6 {
            let bottom = element("creation-next").frame.minY - 24
            if item.exists && item.isHittable && item.frame.midY < bottom && item.frame.midY > 180 { break }
            if item.exists && item.frame.midY < 180 { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(item.isHittable)
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
    private func previewReady(_ preview: XCUIElement) {
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        for _ in 0..<5 {
            if preview.frame.minY >= 100 && preview.frame.maxY < element("creation-next").frame.minY { break }
            app.swipeDown()
        }
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: preview.progressIndicators.firstMatch)
        waitForExpectations(timeout: 15)
        XCTAssertFalse(preview.buttons["Retry preview"].exists)
        Thread.sleep(forTimeInterval: 0.3)
    }
    private func assertMoving(_ preview: XCUIElement) {
        previewReady(preview)
        var frames = Set([preview.screenshot().pngRepresentation])
        for _ in 0..<3 {
            Thread.sleep(forTimeInterval: 0.45)
            frames.insert(preview.screenshot().pngRepresentation)
        }
        XCTAssertGreaterThan(frames.count, 1, "Loaded artwork must keep animating")
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "creation-\(name)"
        attachment.lifetime = .keepAlways; add(attachment)
    }
    func testStaticOverviewEditsAndChipsSurviveReopening() {
        launch(); XCTAssertFalse(element("creation-next").isEnabled)
        idea(); capture("type")
        choices(style: "clay", themes: ["space", "cozy"])
        XCTAssertTrue(element("generate-sticker-button").isEnabled); capture("overview")
        element("creation-overview-idea").tap()
        XCTAssertEqual(element("sticker-prompt").value as? String, "A friendly orange cat")
        next()
        XCTAssertTrue(element("generate-sticker-button").exists)
        element("creation-overview-theme").tap(); capture("themes")
        next()
        element("generate-sticker-button").tap()
        XCTAssertTrue(element("chat-composer").waitForExistence(timeout: 15))
        XCTAssertTrue(element("creation-preset-chips").waitForExistence(timeout: 15)); capture("chat-chips")
        XCTAssertTrue(element("creation-preset-chip-style-clay").exists)
        XCTAssertTrue(element("creation-preset-chip-theme-space").exists)
        let composer = element("chat-composer"); composer.tap(); composer.typeText("Keep the orange stripes")
        element("send-chat-message").tap()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Keep the orange stripes"))
                .firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "creation-preset-chips").count, 1)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let card = app.descendants(matching: .any).matching(
            NSPredicate(
                format:
                    "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "library-sticker-", "A friendly orange cat"
            )
        ).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15)); card.tap()
        XCTAssertTrue(element("creation-preset-chips").waitForExistence(timeout: 15))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "creation-preset-chips").count, 1)
        capture("chat-followup")
    }
    func testAnimatedControlsLevelsAndTypeSwitching() {
        launch(); idea()
        element("sticker-kind-picker").buttons.element(boundBy: 1).tap()
        choices()
        let toggle = element("sticker-controllable-toggle").switches.firstMatch
        XCTAssertEqual(toggle.value as? String, "0"); toggle.tap()
        XCTAssertTrue(element("creation-interactive-preview").waitForExistence(timeout: 15))
        let levels = element("sticker-pose-preset-picker")
        XCTAssertTrue(levels.buttons["Medium"].isSelected)
        let labels = ["Min", "Medium", "High", "Ultra"]
        let counts = [2, 3, 5, 8]
        for (index, label) in labels.enumerated() {
            tapVisible(levels.buttons[label])
            XCTAssertTrue(app.staticTexts["\(counts[index]) selectable poses per character"].exists)
            tapVisible(element("creation-demo-pose"))
            XCTAssertTrue(app.buttons["Idle"].waitForExistence(timeout: 15))
            XCTAssertEqual(app.buttons["Dance"].exists, index == 3)
            app.buttons[index == 3 ? "Dance" : "Wave"].tap()
        }
        tapVisible(element("creation-demo-mood")); app.buttons["Surprised"].tap(); capture("controllable")
        next(); element("creation-overview-kind").tap()
        element("sticker-kind-picker").buttons.element(boundBy: 0).tap(); next()
        XCTAssertFalse(element("creation-overview-animation").exists)
        XCTAssertTrue(element("generate-sticker-button").isEnabled)
        element("creation-overview-kind").tap()
        element("sticker-kind-picker").buttons.element(boundBy: 1).tap(); next()
        XCTAssertTrue(element("sticker-controllable-toggle").exists)
        next(); XCTAssertTrue(element("creation-overview-animation").exists)
    }
    func testPetCompanionStyleCreatesAPetReadySticker() {
        launch(); idea("A friendly orange cat")
        choices(style: "pet-companion")
        let toggle = element("sticker-controllable-toggle").switches.firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertFalse(toggle.isEnabled)
        XCTAssertTrue(element("creation-interactive-preview").exists)
        next()
        XCTAssertTrue(element("creation-overview-kind").label.contains("Animated"))
        XCTAssertTrue(element("creation-overview-style").label.contains("Pet Companion"))
        XCTAssertTrue(element("creation-overview-animation").label.contains("Switchable moods and poses"))
    }
    func testAnimatedTypeActuallyPlaysAndReducedMotionHoldsStill() {
        launch(reduceMotion: false); idea()
        element("sticker-kind-picker").buttons.element(boundBy: 1).tap()
        let animated = element("creation-animated-preview")
        assertMoving(animated)
        app.terminate()
        launch(); idea()
        element("sticker-kind-picker").buttons.element(boundBy: 1).tap()
        let still = element("creation-animated-preview")
        previewReady(still)
        let frozen = still.screenshot().pngRepresentation
        Thread.sleep(forTimeInterval: 0.35)
        XCTAssertEqual(frozen, still.screenshot().pngRepresentation)
    }
    func testAnimatedChoicesUseMovingSelectionPreviews() {
        launch(reduceMotion: false); idea()
        element("sticker-kind-picker").buttons.element(boundBy: 1).tap(); next()
        for style in ["clay", "pixel"] {
            tapVisible(element("preset-option-style-\(style)"))
            let preview = element("preset-preview-style")
            assertMoving(preview)
        }
        next(); tapVisible(element("preset-option-theme-space"))
        let preview = element("preset-preview-theme")
        assertMoving(preview)
        next()
        skipReferences()
        XCTAssertTrue(element("sticker-controllable-toggle").waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(element("creation-selection-preview-pixel").waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(element("creation-selection-preview-space").exists)
        capture("selected-pixel-and-space")
    }
    func testControllablePreviewKeepsMovingAfterSelections() {
        launch(reduceMotion: false); idea()
        element("sticker-kind-picker").buttons.element(boundBy: 1).tap()
        choices(style: "clay", themes: ["space"])
        element("sticker-controllable-toggle").switches.firstMatch.tap()
        let preview = element("creation-interactive-preview")
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        for pose in ["Wave", "Bounce"] {
            tapVisible(element("creation-demo-pose")); app.buttons[pose].tap()
            assertMoving(preview)
        }
        tapVisible(element("creation-demo-mood")); app.buttons["Surprised"].tap()
        assertMoving(preview)
        capture("controllable-selected-motion")
    }
    func testCatalogRetryAndRequiredChoice() {
        launch(["--ui-creation-catalog-failure"]); idea(); next()
        XCTAssertTrue(element("creation-catalog-retry").waitForExistence(timeout: 15))
        XCTAssertFalse(element("creation-next").isEnabled)
        element("creation-catalog-retry").tap()
        XCTAssertTrue(element("preset-option-style-bold-cartoon").waitForExistence(timeout: 15))
        XCTAssertFalse(element("creation-next").isEnabled)
        element("preset-option-style-bold-cartoon").tap(); toOverview()
        element("creation-overview-idea").tap()
        XCTAssertEqual(element("sticker-prompt").value as? String, "A friendly orange cat")
    }
    func testChangedCatalogRequiresReselectionAndPreservesTheme() {
        launch(["--ui-creation-catalog-changed"]); idea(); choices(style: "clay", themes: ["space"])
        element("generate-sticker-button").tap()
        XCTAssertTrue(element("preset-option-style-bold-cartoon").waitForExistence(timeout: 15))
        XCTAssertFalse(element("creation-next").isEnabled)
        XCTAssertFalse(element("preset-option-style-clay").exists)
        element("preset-option-style-bold-cartoon").tap(); toOverview()
        XCTAssertTrue(element("creation-overview-theme").label.contains("Space"))
        element("generate-sticker-button").tap()
        XCTAssertTrue(element("chat-composer").waitForExistence(timeout: 15))
    }
    func testFailedSubmissionPreservesOverviewAndDraft() {
        launch(["--ui-upload-failure", "--ui-creation-reference"]); idea(); choices()
        XCTAssertTrue(element("creation-overview-references").exists)
        element("generate-sticker-button").tap()
        XCTAssertTrue(element("error-banner").waitForExistence(timeout: 15))
        XCTAssertTrue(element("generate-sticker-button").isEnabled)
        element("creation-overview-references").tap()
        XCTAssertTrue(app.buttons["Remove reference"].exists)
        // The prompt lives on the idea page now that references have one of their own.
        next(); element("creation-overview-idea").tap()
        XCTAssertEqual(element("sticker-prompt").value as? String, "A friendly orange cat")
        next(); XCTAssertTrue(element("creation-overview-style").label.contains("Bold Cartoon"))
    }
    func testFutureGroupBecomesPageOverviewAndChip() {
        launch(["--ui-creation-future-group"]); idea(); choices()
        XCTAssertTrue(element("preset-option-occasion-everyday").waitForExistence(timeout: 15))
        element("preset-option-occasion-everyday").tap(); toOverview()
        XCTAssertTrue(element("creation-overview-occasion").exists)
        element("generate-sticker-button").tap()
        XCTAssertTrue(element("creation-preset-chip-occasion-everyday").waitForExistence(timeout: 15))
    }
}
