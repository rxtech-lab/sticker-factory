import XCTest

@MainActor
final class StickerGeniOSUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reduce-motion"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 8))
    }

    @MainActor
    func testAuthenticatedTabsAndLibraryAccessibility() {
        XCTAssertTrue(app.tabBars.buttons["Library"].isSelected)
        XCTAssertFalse(app.tabBars.buttons["Create"].exists)
        XCTAssertTrue(app.tabBars.buttons["Marketplace"].exists)
        XCTAssertTrue(app.tabBars.buttons["Account"].exists)
        XCTAssertTrue(element("create-sticker-button").exists)
        XCTAssertTrue(element("library-filter-menu").exists)
        XCTAssertTrue(element("library-sticker-sticker-demo").waitForExistence(timeout: 5))

        app.tabBars.buttons["Account"].tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 3))
        XCTAssertTrue(element("signed-in-profile").exists)
        XCTAssertTrue(element("privacy-policy-link").exists)
        XCTAssertTrue(element("terms-of-service-link").exists)
        XCTAssertTrue(element("sign-out-button").exists)
    }

    @MainActor
    func testStaticCreationOpensChat() {
        openCreateSheet()
        XCTAssertTrue(element("sticker-kind-picker").exists)
        XCTAssertTrue(element("add-reference-images").exists)
        XCTAssertFalse(app.buttons["Review privacy"].exists)

        let prompt = element("sticker-prompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: 3))
        prompt.tap()
        prompt.typeText("A cheerful blue cloud with a thick white outline")

        let generate = element("generate-sticker-button")
        XCTAssertTrue(generate.isEnabled)
        generate.tap()

        // Generation always continues in the chat; there is no separate detail screen.
        XCTAssertTrue(element("chat-composer").waitForExistence(timeout: 8))
        XCTAssertTrue(element("sticker-actions-menu").exists)
        XCTAssertFalse(app.tabBars.buttons["Library"].exists)
    }

    @MainActor
    func testAnimatedPreviewOpensFullScreenPlayer() {
        let card = element("library-sticker-sticker-demo")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()

        // The assistant attaches the sticker to its own message; that attachment is the preview.
        let preview = element("show-sticker-attachment")
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        preview.tap()
        XCTAssertTrue(element("full-screen-sticker-player").waitForExistence(timeout: 3))
        element("dismiss-full-screen-player").tap()
        XCTAssertFalse(element("full-screen-sticker-player").exists)
    }

    @MainActor
    func testChatToolbarMenuExposesGroupedActions() {
        let card = element("library-sticker-sticker-demo")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()

        // Scope to the navigation bar and to buttons: an unscoped `descendants(matching: .any)`
        // query against an open menu walks the whole hierarchy and times out.
        let menu = app.navigationBars.buttons["sticker-actions-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()

        XCTAssertTrue(app.buttons["export-sticker"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["view-versions"].exists)
        XCTAssertTrue(app.buttons["delete-project"].exists)
    }

    @MainActor
    func testChatUsesInlineComposerAndStickerAttachments() {
        openCreateSheet()
        let picker = app.segmentedControls.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        picker.buttons["Animated"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'confirm the base image'")).firstMatch.exists)

        element("dismiss-create-button").tap()
        let card = element("library-sticker-sticker-demo")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()

        // The library card now lands directly in the chat.
        XCTAssertTrue(element("show-sticker-attachment").waitForExistence(timeout: 5))
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

        XCTAssertTrue(element("rxauth-sign-in").waitForExistence(timeout: 8))
        XCTAssertFalse(app.tabBars.buttons["Library"].exists)
    }

    @MainActor
    func testUploadFailureRemainsRecoverableInCreate() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reduce-motion", "--ui-upload-failure"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 8))
        openCreateSheet()

        let prompt = element("sticker-prompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: 3))
        prompt.tap()
        prompt.typeText("A recoverable upload failure")
        element("generate-sticker-button").tap()

        let error = element("error-banner")
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.label.localizedCaseInsensitiveContains("upload"))
        XCTAssertTrue(element("generate-sticker-button").isEnabled)
    }

    @MainActor
    func testComposerClearsWhenTheMessageIsSent() {
        // The transcript is read below, and in landscape the keyboard covers it. The simulator keeps
        // whatever orientation the last run left it in, so this asks for one rather than assuming.
        XCUIDevice.shared.orientation = .portrait

        let card = element("library-sticker-sticker-demo")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()

        let composer = element("chat-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Try again")
        XCTAssertEqual(composer.value as? String, "Try again")

        XCTAssertTrue(element("send-chat-message").isEnabled, "send stayed disabled while the field showed a draft")
        element("send-chat-message").tap()

        // The transcript is what says the draft was sent rather than dropped. Matched on a
        // substring: a message row's label is the whole bubble, speaker prefix and all.
        let sent = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Try again")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 10), "the draft never reached the transcript")
        // A focused field that has been emptied reports an empty value, not its placeholder. The
        // draft belongs to the tap, so it is gone from the moment the send starts — not when the
        // turn it started comes back.
        expectation(for: NSPredicate(format: "value == %@", ""), evaluatedWith: composer)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    func testAdaptiveLayoutKeepsPrimaryActionsVisible() {
        openCreateSheet()
        XCTAssertTrue(element("sticker-kind-picker").waitForExistence(timeout: 3))
        XCTAssertTrue(element("sticker-prompt").isHittable)
        XCTAssertTrue(element("generate-sticker-button").exists)
    }

    private func openCreateSheet() {
        let create = element("create-sticker-button")
        XCTAssertTrue(create.waitForExistence(timeout: 3))
        create.tap()
        XCTAssertTrue(app.navigationBars["Create"].waitForExistence(timeout: 3))
        XCTAssertTrue(element("dismiss-create-button").exists)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
