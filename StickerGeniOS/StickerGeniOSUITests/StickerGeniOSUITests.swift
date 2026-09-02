import XCTest

@MainActor
final class StickerGeniOSUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reduce-motion",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
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
        XCTAssertTrue(app.buttons["How Winky Sticker House works"].exists)
        XCTAssertTrue(element("about-page-link").exists)
        XCTAssertTrue(element("sign-out-button").exists)

        element("about-page-link").tap()
        XCTAssertTrue(element("about-page-view").waitForExistence(timeout: 3))
        XCTAssertTrue(element("app-version").waitForExistence(timeout: 3))
        XCTAssertFalse(app.tabBars.buttons["Library"].exists)
    }

    @MainActor
    func testLegalDocumentHidesTabBar() {
        app.tabBars.buttons["Account"].tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 3))

        element("privacy-policy-link").tap()
        XCTAssertTrue(element("legal-document-view").waitForExistence(timeout: 3))
        XCTAssertFalse(app.tabBars.buttons["Library"].exists)
    }

    @MainActor
    func testLibrarySearchShowsRemoteNoResultsState() {
        let search = app.searchFields["Search stickers"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("No such sticker")

        XCTAssertTrue(app.staticTexts["No matching stickers"].waitForExistence(timeout: 5))
        XCTAssertFalse(element("library-sticker-sticker-demo").exists)
    }

    @MainActor
    func testLibraryStickerContextMenuOffersRenameAndConfirmedDelete() {
        let card = element("library-sticker-sticker-demo")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.press(forDuration: 1)

        let rename = element("rename-library-sticker-sticker-demo")
        XCTAssertTrue(rename.waitForExistence(timeout: 3))
        XCTAssertTrue(element("delete-library-sticker-sticker-demo").exists)
        rename.tap()

        // SwiftUI's alert hosts the field outside the app's ordinary accessibility container and
        // drops its custom identifier, while preserving the visible prompt as the field label.
        let renameField = app.textFields["Sticker name"]
        XCTAssertTrue(renameField.waitForExistence(timeout: 3))
        XCTAssertEqual(renameField.value as? String, "Happy bounce")
        app.buttons["Cancel"].tap()

        card.press(forDuration: 1)
        element("delete-library-sticker-sticker-demo").tap()
        XCTAssertTrue(app.staticTexts["Delete this sticker project?"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Delete “Happy bounce”"].exists)
        // On this compact confirmation-dialog presentation XCTest exposes the destructive action
        // but not SwiftUI's cancel role, so dismiss through the modal backdrop as a user can.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        XCTAssertTrue(card.exists)
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
        // Tap the artwork itself, not the title or kind label. The animated UIKit-backed preview
        // must still hand the gesture to the card's navigation link.
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()

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
        XCTAssertTrue(app.buttons["rename-sticker"].exists)
        XCTAssertTrue(app.buttons["view-versions"].exists)
        XCTAssertTrue(app.buttons["delete-project"].exists)
    }

    @MainActor
    func testChatUsesInlineComposerAndStickerAttachments() {
        openCreateSheet()
        let picker = app.segmentedControls.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        picker.buttons["Animated"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'review a static visual reference'")).firstMatch.exists)

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
    func testRejectedChatMessageShowsAnAlertInsteadOfInlineError() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reduce-motion",
            "--ui-insufficient-credits",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 8))

        element("library-sticker-sticker-demo").tap()
        let composer = element("chat-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Add text hi")
        element("send-chat-message").tap()

        XCTAssertTrue(app.alerts["Couldn’t Complete Action"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["You do not have enough points for this. Top up or upgrade your plan to keep creating."].exists)
        XCTAssertFalse(element("error-banner").exists)
        app.buttons["OK"].tap()

        XCTAssertEqual(composer.value as? String, "Add text hi")
        XCTAssertFalse(app.alerts["Couldn’t Complete Action"].exists)
    }

    @MainActor
    func testAdaptiveLayoutKeepsPrimaryActionsVisible() {
        openCreateSheet()
        XCTAssertTrue(element("sticker-kind-picker").waitForExistence(timeout: 3))
        XCTAssertTrue(element("sticker-prompt").isHittable)
        XCTAssertTrue(element("generate-sticker-button").exists)
    }

    @MainActor
    func testFirstLaunchWelcomeExplainsTheFullWorkflow() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reduce-motion", "--ui-show-welcome"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Welcome to Winky Sticker House"].waitForExistence(timeout: 8))

        for title in ["1. Generate", "2. Confirm", "3. Keep every version", "4. Publish", "5. Use it"] {
            app.buttons["Next"].tap()
            expectation(
                for: NSPredicate(format: "hittable == true"),
                evaluatedWith: app.staticTexts[title]
            )
            waitForExpectations(timeout: 3)
        }

        let getStarted = app.buttons["Get started"]
        XCTAssertTrue(getStarted.exists)
        getStarted.tap()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["5. Use it"].exists)
    }

    /// A pack you created stays editable once it exists — the whole point of the editor is that
    /// publishing is not a one-way door, so the screen has to be reachable from the pack itself.
    @MainActor
    func testOwnedPackIsEditableFromItsDetailScreen() {
        app.tabBars.buttons["Marketplace"].tap()
        XCTAssertTrue(app.navigationBars["Marketplace"].waitForExistence(timeout: 5))

        element("create-pack-button").tap()
        let title = element("pack-title-field")
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        title.tap()
        title.typeText("Editable pack")

        element("pack-choose-stickers-button").tap()
        let pick = element("pack-pick-sticker-demo")
        XCTAssertTrue(pick.waitForExistence(timeout: 5))
        pick.tap()
        element("sticker-picker-done-button").tap()
        element("pack-create-draft-button").tap()

        // The composer closes onto the marketplace, and a pack of your own only lists under "My
        // packs" — a draft is invisible in browse by design.
        XCTAssertTrue(app.navigationBars["Marketplace"].waitForExistence(timeout: 8))
        app.segmentedControls.buttons["My packs"].tap()
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "marketplace-pack-"))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()

        let edit = element("pack-edit-button")
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()

        let editorTitle = element("pack-editor-title-field")
        XCTAssertTrue(editorTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(editorTitle.value as? String, "Editable pack")
        XCTAssertTrue(element("pack-editor-publish-button").exists)
        // Scoped to buttons: an unscoped descendants query resolves the toolbar item's container
        // first, and a container reports itself enabled whatever the button inside it says.
        let save = app.buttons["pack-editor-save-button"]
        // Nothing has been touched yet, so there is nothing to send.
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        XCTAssertFalse(save.isEnabled)

        let summary = element("pack-editor-summary-field")
        summary.tap()
        summary.typeText("Edited after it was created")
        XCTAssertTrue(save.isEnabled)
        save.tap()

        // Saving closes the editor, and the detail screen behind it shows the edit rather than the
        // copy it was opened with.
        XCTAssertTrue(app.staticTexts["Edited after it was created"].waitForExistence(timeout: 8))
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
