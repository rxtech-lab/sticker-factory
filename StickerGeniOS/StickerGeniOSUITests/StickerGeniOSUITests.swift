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
            "-AppleLocale", "en_US"
        ]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 8))
    }

    @MainActor
    func testPlanSpriteAddOptionAppearsAndSurvivesSave() {
        app.terminate()
        app.launchArguments.append("--ui-sprite-plan")
        app.launch()
        let card = element("library-sticker-sticker-demo")
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        card.tap()
        let editLayers = element("plan-edit-layers")
        XCTAssertTrue(editLayers.waitForExistence(timeout: 8))
        editLayers.tap()
        XCTAssertTrue(element("plan-editor-sheet").waitForExistence(timeout: 3))

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
        XCTAssertTrue(option.waitForExistence(timeout: 3))
        option.tap()
        option.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "New option".count) + "Resting")
        let save = app.buttons["plan-editor-save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(element("plan-editor-sheet").waitForNonExistence(timeout: 5))

        XCTAssertTrue(editLayers.waitForExistence(timeout: 5))
        editLayers.tap()
        XCTAssertTrue(element("plan-editor-sheet").waitForExistence(timeout: 3))
        for _ in 0..<8 where !pose.isHittable { scroll.swipeUp() }
        XCTAssertTrue(pose.isHittable)
        pose.tap()
        let savedOption = app.textFields.matching(NSPredicate(format: "value == %@", "Resting")).firstMatch
        XCTAssertTrue(savedOption.waitForExistence(timeout: 3))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Added sprite option after saving"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testPlanVersionPickerActivatesSelectedVersionInLatestCard() {
        app.terminate()
        app.launchArguments.append("--ui-plan-versions")
        app.launch()
        element("library-sticker-sticker-demo").tap()

        let picker = element("plan-version-picker")
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
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
        XCTAssertTrue(element("plan-versions-sheet").waitForExistence(timeout: 3))
        let carousel = element("plan-version-carousel")
        XCTAssertTrue(carousel.exists)
        carousel.swipeRight()
        let sheetScreenshot = XCTAttachment(screenshot: app.screenshot())
        sheetScreenshot.name = "Horizontal plan version selector"
        sheetScreenshot.lifetime = .keepAlways
        add(sheetScreenshot)
        element("select-plan-version-1").tap()
        XCTAssertTrue(element("plan-versions-sheet").waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Original wave"].waitForExistence(timeout: 3))
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
        XCTAssertTrue(app.buttons["Build"].waitForExistence(timeout: 3))
        // Compact confirmation popovers can omit Cancel; tapping outside dismisses them.
        app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Build"].waitForNonExistence(timeout: 3))

        picker.tap()
        XCTAssertTrue(element("plan-versions-sheet").waitForExistence(timeout: 3))
        carousel.swipeLeft()
        element("select-plan-version-2").tap()
        XCTAssertTrue(element("plan-versions-sheet").waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Revised bounce"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Bouncing character"].exists)
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(element("composition-plan-generate").exists)
        XCTAssertTrue(element("composition-plan-dismiss").exists)
        XCTAssertFalse(element("plan-preview-only").exists)
    }

    @MainActor
    func testSubscriptionControlsRemainVisibleWhenStoreKitCannotInitialize() {
        app.terminate()
        app.launchArguments.append("--ui-subscription-unavailable")
        app.launch()

        XCTAssertTrue(element("credits-chip").waitForExistence(timeout: 5))
        app.tabBars.buttons["Account"].tap()
        XCTAssertTrue(element("view-plans-button").waitForExistence(timeout: 3))
        XCTAssertTrue(element("manage-subscription-button").exists)
        element("view-plans-button").tap()
        let errorAlert = app.alerts["Subscription Error"]
        XCTAssertTrue(errorAlert.waitForExistence(timeout: 5))
        XCTAssertTrue(errorAlert.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Unable to Complete Request")
        ).firstMatch.exists)
        XCTAssertTrue(errorAlert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "ASDErrorDomain (530)")).firstMatch.exists)
        errorAlert.buttons["Close"].tap()
        XCTAssertTrue(element("subscription-connection-error").waitForExistence(timeout: 3))
        let unavailable = XCTAttachment(screenshot: app.screenshot())
        unavailable.name = "Subscription connection can be retried"
        unavailable.lifetime = .keepAlways
        add(unavailable)
        XCTAssertTrue(element("subscription-connection-retry").exists, app.debugDescription)

        // An authenticated refresh can still fail. Its new error must open another alert.
        element("subscription-connection-retry").tap()
        XCTAssertTrue(errorAlert.waitForExistence(timeout: 5))
        XCTAssertTrue(errorAlert.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "storekit.refresh.request")
        ).firstMatch.exists)
        let diagnosticAlert = XCTAttachment(screenshot: app.screenshot())
        diagnosticAlert.name = "StoreKit error details after failed retry"
        diagnosticAlert.lifetime = .keepAlways
        add(diagnosticAlert)
        errorAlert.buttons["Copy Diagnostics"].tap()
        XCTAssertTrue(errorAlert.waitForNonExistence(timeout: 3))
        element("subscription-connection-error-details").tap()
        XCTAssertTrue(errorAlert.waitForExistence(timeout: 3))
        errorAlert.buttons["Close"].tap()

        element("subscription-connection-retry").tap()
        XCTAssertTrue(app.staticTexts["Choose your plan"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Monthly Points"].exists)
        let recovered = XCTAttachment(screenshot: app.screenshot())
        recovered.name = "Subscription plans after retry"
        recovered.lifetime = .keepAlways
        add(recovered)
        element("paywall-done").tap()
        let credits = element("subscription-credits")
        XCTAssertTrue(credits.waitForExistence(timeout: 3))
        XCTAssertEqual(credits.label, "Credits, 42")
    }

    @MainActor
    func testBalanceRefreshCancellationPreservesDataAndCanRefreshAgain() {
        app.terminate()
        app.launchArguments.append("--ui-balance-refresh")
        app.launch()
        let picker = element("credits-section-picker")
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        picker.buttons["Balance"].tap()
        let originalGrant = app.staticTexts["Refresh fixture grant 100"]
        XCTAssertTrue(originalGrant.waitForExistence(timeout: 8))

        let scroll = element("balance-scroll")
        pullToRefresh(scroll)
        // The second request returns URLSession's cancellation error for both endpoints.
        XCTAssertFalse(app.staticTexts["cancelled"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Something went wrong"].exists)
        XCTAssertTrue(originalGrant.exists)

        pullToRefresh(scroll)
        XCTAssertTrue(app.staticTexts["Refresh fixture grant 250"].waitForExistence(timeout: 8))
        XCTAssertFalse(originalGrant.exists)
        XCTAssertTrue(app.staticTexts["250"].exists)
        XCTAssertFalse(app.staticTexts["cancelled"].exists)
    }

    @MainActor
    func testAuthenticatedTabsAndLibraryAccessibility() {
        XCTAssertTrue(app.tabBars.buttons["Library"].isSelected)
        XCTAssertFalse(app.tabBars.buttons["Create"].exists)
        XCTAssertFalse(app.tabBars.buttons["Marketplace"].exists)
        XCTAssertTrue(app.tabBars.buttons["Sticker Packs"].exists)
        XCTAssertTrue(app.tabBars.buttons["Account"].exists)
        XCTAssertTrue(element("create-sticker-button").exists)
        XCTAssertTrue(element("library-filter-menu").exists)
        XCTAssertTrue(element("library-sticker-sticker-demo").waitForExistence(timeout: 5))

        app.tabBars.buttons["Account"].tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 3))
        XCTAssertTrue(element("signed-in-profile").exists)
        XCTAssertTrue(element("privacy-policy-link").exists)
        XCTAssertTrue(element("terms-of-service-link").exists)
        XCTAssertTrue(app.buttons["How Winky Sticker Factory works"].exists)
        XCTAssertTrue(element("about-page-link").exists)
        // Delete Account sits between About and Sign Out, which puts Sign Out below the fold, and a
        // `Form` does not build a row it has never scrolled to.
        let signOut = element("sign-out-button")
        for _ in 0..<6 where !signOut.exists { app.swipeUp() }
        XCTAssertTrue(signOut.exists)

        let aboutLink = element("about-page-link")
        for _ in 0..<6 where !aboutLink.isHittable { app.swipeDown() }
        aboutLink.tap()
        XCTAssertTrue(element("about-page-view").waitForExistence(timeout: 3))
        XCTAssertTrue(element("app-version").waitForExistence(timeout: 3))
        XCTAssertFalse(app.tabBars.buttons["Library"].exists)
    }

    @MainActor
    func testHomeActionsMenuOffersShareAlongsideFilter() {
        let menu = element("library-filter-menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 5))

        menu.tap()

        XCTAssertTrue(element("home-share").waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["All"].exists)
        XCTAssertTrue(app.buttons["Static"].exists)
        XCTAssertTrue(app.buttons["Animated"].exists)
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
    func testLibraryServerErrorShowsAnAlertWithItsMessage() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reduce-motion",
            "--ui-library-list-failure",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        app.launch()

        XCTAssertTrue(app.alerts["Couldn’t Complete Action"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Update Winky Sticker Factory to version 1.2 or later to view your stickers."].exists)
        XCTAssertFalse(element("error-banner").exists)

        app.buttons["OK"].tap()
        XCTAssertFalse(app.alerts["Couldn’t Complete Action"].exists)
    }

    /// Dismissing the alert used to leave "No stickers yet" over an account that has plenty — and
    /// no grid on screen, so not even a pull to try again. The failure state has to carry its own
    /// way back.
    @MainActor
    func testLibraryOfferedARetryAfterAFailedLoad() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reduce-motion",
            "--ui-library-list-failure",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        app.launch()

        XCTAssertTrue(app.alerts["Couldn’t Complete Action"].waitForExistence(timeout: 8))
        app.buttons["OK"].tap()

        XCTAssertTrue(app.staticTexts["Couldn’t load your library"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["No stickers yet"].exists)
        let retry = element("library-retry-button")
        XCTAssertTrue(retry.exists)

        // The mock fails every listing, so the retry is expected to fail again — what matters is
        // that it ran, and that the way back is still there afterwards.
        retry.tap()
        XCTAssertTrue(app.alerts["Couldn’t Complete Action"].waitForExistence(timeout: 8))
        app.buttons["OK"].tap()
        XCTAssertTrue(element("library-retry-button").waitForExistence(timeout: 3))
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
    func testConfigurablePreviewRemembersApplyAndDiscardsCancel() {
        app.terminate()
        app.launchArguments.append("--ui-configurable-sticker")
        app.launch()
        let card = element("library-sticker-sticker-demo")
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        card.tap()
        let preview = element("show-sticker-attachment")
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        preview.tap()
        XCTAssertTrue(element("sticker-controls-sheet").waitForExistence(timeout: 5))
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
        XCTAssertTrue(element("sticker-controls-sheet").waitForNonExistence(timeout: 5))
        element("dismiss-full-screen-player").tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
        for _ in 0..<10 where !preview.isHittable { usleep(200_000) }
        preview.tap()
        XCTAssertTrue(element("sticker-controls-sheet").waitForExistence(timeout: 5))
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
    func testViewToolSheetShowsSavedImage() {
        app.terminate()
        app.launchArguments.append("--ui-tool-preview")
        app.launch()
        element("library-sticker-sticker-demo").tap()
        let tool = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Tool view_sticker,")).firstMatch
        XCTAssertTrue(tool.waitForExistence(timeout: 8))
        tool.tap()
        XCTAssertTrue(element("tool-result-image").waitForExistence(timeout: 8))
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
        XCTAssertTrue(tool.waitForExistence(timeout: 8))
        tool.tap()
        XCTAssertTrue(element("tool-result-image").waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "previewAssetId")).firstMatch.exists)
    }

    @MainActor
    func testSendingBelowPlanPinsMessageToTop() {
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
        app.launchArguments.append("--ui-plan-versions")
        app.launch()
        element("library-sticker-sticker-demo").tap()
        XCTAssertTrue(element("plan-version-picker").waitForExistence(timeout: 8))
        let composer = element("chat-composer")
        composer.tap()
        composer.typeText("add text hi")
        element("send-chat-message").tap()
        let sent = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "add text hi")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 8))
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
    func testWorkingCardShowsCompletedStepsWithoutRepeatingTitle() {
        app.terminate()
        app.launchArguments.append("--ui-working-progress")
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let sticker = element("library-sticker-sticker-demo")
        XCTAssertTrue(sticker.waitForExistence(timeout: 8))
        sticker.tap()
        // Opening this fixture reattaches its in-progress generation.
        let card = element("assistant-working-card")
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        expectation(for: NSPredicate(format: "label CONTAINS %@", "2 steps done"), evaluatedWith: card)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(card.label.contains("Last finished: Reviewing the sticker"))
        XCTAssertFalse(card.label.contains("Finishing up"))
        // The transcript deliberately keeps its scroll position as new content arrives.
        // Bring the entire growing card above the floating candidate/composer controls.
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(card.isHittable)
        XCTAssertTrue(card.label.contains("2 steps done"))
        XCTAssertTrue(card.label.contains("Last finished: Reviewing the sticker"))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Working card with completed steps"
        screenshot.lifetime = .keepAlways
        add(screenshot)
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

    /// The switch that asks for a character whose mood and pose are switchable, instead of the user
    /// having to know to write "moods I can switch between" in the prompt. It belongs to animated
    /// stickers alone: a still has no clips to switch between.
    @MainActor
    func testControllableSwitchFollowsTheStickerType() {
        openCreateSheet()
        let picker = element("sticker-kind-picker")
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        XCTAssertFalse(element("sticker-controllable-toggle").exists)

        picker.buttons.element(boundBy: 1).tap()
        let toggle = element("sticker-controllable-toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.switches.firstMatch.value as? String, "1")

        picker.buttons.element(boundBy: 0).tap()
        XCTAssertFalse(element("sticker-controllable-toggle").exists)
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

        XCTAssertTrue(app.staticTexts["Welcome to Winky Sticker Factory"].waitForExistence(timeout: 8))

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
        app.tabBars.buttons["Sticker Packs"].tap()
        XCTAssertTrue(app.navigationBars["Sticker Packs"].waitForExistence(timeout: 5))

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

        // The demo sticker has no WhatsApp or Telegram copy, so creating the pack pushes the
        // conversion screen before anything else. There is no back button and no swipe-down: the
        // fixture has no artwork to encode, so the run fails fast, says so beside the sticker, and
        // offers Done — which is what lands on the pack.
        let preparation = element("messenger-preparation-sheet")
        XCTAssertTrue(preparation.waitForExistence(timeout: 8))
        XCTAssertTrue(element("messenger-preparation-sticker-sticker-demo").waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Preparing stickers"].exists)
        let done = element("messenger-preparation-done")
        XCTAssertTrue(done.waitForExistence(timeout: 15))
        XCTAssertTrue(element("messenger-preparation-incomplete").exists)
        done.tap()

        // The sheet closes straight onto the pack it made: the messenger buttons live there, and
        // sending the new pack somewhere is the next thing to do with it.
        let edit = element("pack-edit-button")
        XCTAssertTrue(edit.waitForExistence(timeout: 8))
        XCTAssertTrue(element("pack-messenger-whatsapp").exists)
        XCTAssertTrue(element("pack-messenger-telegram").exists)
        XCTAssertTrue(app.navigationBars["Editable pack"].exists)
        // The creator is told the pack still cannot be sent, and where to fix that.
        XCTAssertTrue(element("pack-messenger-unprepared").exists)
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()

        let editorTitle = element("pack-editor-title-field")
        XCTAssertTrue(editorTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(editorTitle.value as? String, "Editable pack")
        XCTAssertTrue(element("pack-editor-publish-button").exists)
        XCTAssertTrue(element("pack-editor-member-sticker-demo").exists)
        // The member is still unprepared, so the editor offers to prepare it without an edit.
        XCTAssertTrue(element("pack-editor-prepare-button").exists)
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

        // Saving a pack with an unprepared member goes through the conversion screen again, and
        // Done there is what closes the editor.
        XCTAssertTrue(element("messenger-preparation-sheet").waitForExistence(timeout: 8))
        let preparationDone = element("messenger-preparation-done")
        XCTAssertTrue(preparationDone.waitForExistence(timeout: 15))
        preparationDone.tap()

        // The editor is gone, and the detail screen behind it shows the edit rather than the copy
        // it was opened with.
        XCTAssertTrue(app.staticTexts["Edited after it was created"].waitForExistence(timeout: 8))
        XCTAssertFalse(element("pack-editor-title-field").exists)
    }

    /// The feature cards come up after the welcome tour, one card per Next, and the last one is
    /// dismissed by Got it. Forced by flag, exactly as the tour is.
    @MainActor
    func testFeatureCardsFollowTheWelcomeTour() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reduce-motion", "--ui-show-welcome", "--ui-show-feature-cards"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Welcome to Winky Sticker Factory"].waitForExistence(timeout: 8))
        for _ in 0..<5 { app.buttons["Next"].tap() }
        app.buttons["Get started"].tap()

        // The cards follow the tour inside the same sheet; the first card's title is what says
        // they arrived.
        XCTAssertTrue(app.staticTexts["Your packs, in WhatsApp"].waitForExistence(timeout: 8))
        let next = element("feature-card-next-button")
        XCTAssertTrue(next.exists)
        next.tap()
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: app.staticTexts["Your packs, in Telegram"])
        waitForExpectations(timeout: 3)
        XCTAssertTrue(app.buttons["Got it"].exists)
        app.buttons["Got it"].tap()
        XCTAssertFalse(app.staticTexts["Your packs, in Telegram"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.tabBars.buttons["Library"].exists)
    }

    @MainActor
    func testLibraryErrorWaitsUntilWelcomeAndFeatureCardsFinish() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--reduce-motion", "--ui-show-welcome",
            "--ui-show-feature-cards", "--ui-library-list-failure",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Welcome to Winky Sticker Factory"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.alerts["Couldn’t Complete Action"].waitForExistence(timeout: 2))
        for _ in 0..<5 { app.buttons["Next"].tap() }
        app.buttons["Get started"].tap()

        XCTAssertTrue(app.staticTexts["Your packs, in WhatsApp"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Couldn’t Complete Action"].exists)
        element("feature-card-next-button").tap()
        XCTAssertTrue(app.buttons["Got it"].waitForExistence(timeout: 3))
        app.buttons["Got it"].tap()

        XCTAssertTrue(app.alerts["Couldn’t Complete Action"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Update Winky Sticker Factory to version 1.2 or later to view your stickers."].exists)
        app.buttons["OK"].tap()
        XCTAssertFalse(app.alerts["Couldn’t Complete Action"].exists)
    }

    /// Feature cards alone, with no tour in front of them, on a launch that has already seen it.
    @MainActor
    func testFeatureCardsShowWithoutTheWelcomeTour() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reduce-motion", "--ui-show-feature-cards"]
        app.launch()

        XCTAssertTrue(element("feature-cards-sheet").waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["Welcome to Winky Sticker Factory"].exists)
        XCTAssertTrue(app.staticTexts["Your packs, in WhatsApp"].exists)
    }

    /// The default launch shows no cards at all under automation, the same as the welcome tour.
    @MainActor
    func testFeatureCardsAreSuppressedUnderAutomationByDefault() {
        XCTAssertFalse(element("feature-cards-sheet").waitForExistence(timeout: 2))
    }

    /// The pack screen offers both messengers, and the export sheet explains how the pack will be
    /// cut and what to expect. It starts fetching the prepared files by itself — there is no button
    /// to press first. Neither messenger is installed on a simulator, so the sheet says so and
    /// keeps its send buttons disabled rather than opening nothing.
    @MainActor
    func testPackDetailOffersMessengerExport() {
        app.tabBars.buttons["Sticker Packs"].tap()
        XCTAssertTrue(app.navigationBars["Sticker Packs"].waitForExistence(timeout: 5))
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "marketplace-pack-"))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()

        let whatsapp = element("pack-messenger-whatsapp")
        XCTAssertTrue(whatsapp.waitForExistence(timeout: 5))
        XCTAssertTrue(element("pack-messenger-telegram").exists)

        // Telegram: a single sticker is a valid set, so the fixture pack becomes one part.
        element("pack-messenger-telegram").tap()
        XCTAssertTrue(element("messenger-export-sheet").waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Add to Telegram"].exists)
        XCTAssertTrue(element("messenger-not-installed").waitForExistence(timeout: 3))
        let telegramPart = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "messenger-part-"))
            .firstMatch
        XCTAssertTrue(telegramPart.waitForExistence(timeout: 5))
        XCTAssertTrue(element("messenger-emoji-sticker-borrowed").waitForExistence(timeout: 3))
        XCTAssertFalse(element("messenger-export-start").exists)
        // The fixture's rendition is served locally, so the part is sendable — barring the app.
        let send = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "messenger-send-"))
            .firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 8))
        XCTAssertFalse(send.isEnabled)
        element("messenger-export-close").tap()

        // WhatsApp: one sticker is under its minimum of three, so nothing can be sent and the
        // sticker is listed with the reason.
        whatsapp.tap()
        XCTAssertTrue(app.navigationBars["Add to WhatsApp"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("messenger-skipped-sticker-borrowed").waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "messenger-send-"))
            .firstMatch.exists)
        element("messenger-export-close").tap()
        XCTAssertTrue(whatsapp.waitForExistence(timeout: 3))
    }

    private func openCreateSheet() {
        let create = element("create-sticker-button")
        XCTAssertTrue(create.waitForExistence(timeout: 3))
        create.tap()
        XCTAssertTrue(app.navigationBars["Create"].waitForExistence(timeout: 3))
        XCTAssertTrue(element("dismiss-create-button").exists)
    }

    /// A flick from `swipeDown()` does not reliably travel far enough to trigger `.refreshable`;
    /// a held drag past the threshold does.
    private func pullToRefresh(_ scroll: XCUIElement) {
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0.3)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
