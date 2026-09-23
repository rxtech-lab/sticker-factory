import XCTest

@MainActor
final class ChatUITests: StickerGeniOSUITestCase {
    @MainActor
    func testUploadedReferenceImageOpensFullScreenAndZooms() {
        app.terminate()
        app.launchArguments.append("--ui-chat-reference-image")
        app.launch()
        element("library-sticker-sticker-demo").tap()

        let reference = app.buttons["open-chat-reference-image"]
        XCTAssertTrue(reference.waitForExistence(timeout: 15))
        reference.tap()

        let close = app.buttons["reference-image-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 15))
        let zoom = app.buttons["reference-image-reset-zoom"]
        XCTAssertEqual(zoom.value as? String, "100%")
        app.buttons["reference-image-zoom-in"].tap()
        XCTAssertEqual(zoom.value as? String, "150%")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 15))
    }

    @MainActor
    func testChatToolbarMenuExposesGroupedActions() {
        let card = element("library-sticker-sticker-demo")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()

        // Scope to the navigation bar and to buttons: an unscoped `descendants(matching: .any)`
        // query against an open menu walks the whole hierarchy and times out.
        let menu = app.navigationBars.buttons["sticker-actions-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()

        XCTAssertTrue(app.buttons["export-sticker"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["rename-sticker"].exists)
        XCTAssertTrue(app.buttons["view-versions"].exists)
        XCTAssertTrue(app.buttons["delete-project"].exists)
    }

    @MainActor
    func testChatUsesInlineComposerAndStickerAttachments() {
        openCreateSheet()
        enterCreationIdea()
        let picker = app.segmentedControls.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        picker.buttons["Animated"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'review a static visual reference'")).firstMatch.exists)

        element("dismiss-create-button").tap()
        let card = element("library-sticker-sticker-demo")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()

        // The library card now lands directly in the chat.
        XCTAssertTrue(element("show-sticker-attachment").waitForExistence(timeout: 15))
        XCTAssertTrue(element("chat-composer").exists)
        XCTAssertTrue(element("add-chat-attachment").exists)
        XCTAssertTrue(element("send-chat-message").exists)
        XCTAssertFalse(element("target-layer-picker").exists)
        XCTAssertFalse(app.segmentedControls.buttons["Animate"].exists)
    }

    @MainActor
    func testExpiredAuthenticationReturnsToRxAuthSignIn() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reduce-motion", "--ui-auth-expired"]
        app.launch()

        XCTAssertTrue(element("rxauth-sign-in").waitForExistence(timeout: 15))
        XCTAssertFalse(app.tabBars.buttons["Library"].exists)
    }

    @MainActor
    func testSendingBelowPlanPinsMessageToTop() {
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
        app.launchArguments.append("--ui-plan-versions")
        app.launch()
        element("library-sticker-sticker-demo").tap()
        XCTAssertTrue(element("plan-version-picker").waitForExistence(timeout: 15))
        let composer = element("chat-composer")
        composer.tap()
        composer.typeText("add text hi")
        element("send-chat-message").tap()
        let sent = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "add text hi")).firstMatch
        // Waiting longer than the 8s that sufficed serially: parallel testing runs this on a
        // simulator clone sharing the host with three others, and the wait returns as soon as
        // the element appears, so a higher ceiling costs nothing when the machine is idle.
        XCTAssertTrue(sent.waitForExistence(timeout: 20))
        let atTop = NSPredicate { _, _ in
            return sent.exists && sent.frame.minY >= self.app.navigationBars.firstMatch.frame.maxY
                && sent.frame.minY < self.app.navigationBars.firstMatch.frame.maxY + 60
        }
        expectation(for: atTop, evaluatedWith: sent)
        waitForExpectations(timeout: 5)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "New message above plan history"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testWorkingCardShowsOnlyTheNoteWhileTheChipCarriesProgress() {
        app.terminate()
        app.launchArguments.append("--ui-working-progress")
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let sticker = element("library-sticker-sticker-demo")
        XCTAssertTrue(sticker.waitForExistence(timeout: 15))
        sticker.tap()
        // Opening this fixture reattaches its in-progress generation.
        let card = element("assistant-working-card")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        let note = "Last finished: Reviewing the sticker"
        expectation(for: NSPredicate(format: "label CONTAINS %@", note), evaluatedWith: card)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(card.label.contains("Finishing up"))
        // Counted progress belongs to the chip and the Live Activity; the card is the note alone.
        XCTAssertFalse(card.label.contains("steps done"))
        let title = element("chat-title-chip")
        XCTAssertTrue(title.label.contains("Finishing up"))
        XCTAssertTrue(title.label.contains("2/6"))
        // The transcript deliberately keeps its scroll position as new content arrives.
        // Bring the entire growing card above the floating candidate/composer controls.
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(card.isHittable)
        XCTAssertTrue(card.label.contains(note))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Working card showing only its note"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testComposerClearsWhenTheMessageIsSent() {
        // The transcript is read below, and in landscape the keyboard covers it. The simulator keeps
        // whatever orientation the last run left it in, so this asks for one rather than assuming.
        XCUIDevice.shared.orientation = .portrait

        let card = element("library-sticker-sticker-demo")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()

        let composer = element("chat-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap()
        composer.typeText("Try again")
        XCTAssertEqual(composer.value as? String, "Try again")

        XCTAssertTrue(element("send-chat-message").isEnabled, "send stayed disabled while the field showed a draft")
        element("send-chat-message").tap()

        // The transcript is what says the draft was sent rather than dropped. Matched on a
        // substring: a message row's label is the whole bubble, speaker prefix and all.
        let sent = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Try again")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 15), "the draft never reached the transcript")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue(sent.isHittable, "sent text is outside the visible transcript with the keyboard open")
        XCTAssertGreaterThanOrEqual(sent.frame.minY, app.navigationBars.firstMatch.frame.maxY)
        XCTAssertLessThanOrEqual(sent.frame.maxY, composer.frame.minY)

        // A focused field that has been emptied reports an empty value, not its placeholder. The
        // draft belongs to the tap, so it is gone from the moment the send starts — not when the
        // turn it started comes back.
        expectation(for: NSPredicate(format: "value == %@", ""), evaluatedWith: composer)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    func testRejectedChatMessageShowsAnAlertInsteadOfInlineError() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reduce-motion",
            "--ui-insufficient-credits",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 15))

        element("library-sticker-sticker-demo").tap()
        let composer = element("chat-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap()
        composer.typeText("Add text hi")
        element("send-chat-message").tap()

        XCTAssertTrue(app.alerts["Couldn’t Complete Action"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["You do not have enough points for this. Top up or upgrade your plan to keep creating."].exists)
        XCTAssertFalse(element("error-banner").exists)
        app.buttons["OK"].tap()

        XCTAssertEqual(composer.value as? String, "Add text hi")
        XCTAssertFalse(app.alerts["Couldn’t Complete Action"].exists)
    }
}
