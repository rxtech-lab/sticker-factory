import XCTest

@MainActor
final class SubscriptionUITests: StickerGeniOSUITestCase {
    @MainActor
    func testFreeGenerationNumberAndFreeTagAppearOnLibraryCreateButton() {
        app.terminate()
        app.launchArguments.append("--ui-free-generation-allowance")
        app.launch()

        let create = element("create-sticker-button")
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        XCTAssertEqual(create.value as? String, "3 free sticker generations remaining today")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Number above and FREE below Create"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        create.tap()
        XCTAssertTrue(element("sticker-prompt").waitForExistence(timeout: 15))
    }

    @MainActor
    func testFreeGenerationChipAppearsAboveReviewChoices() {
        app.terminate()
        app.launchArguments.append("--ui-free-generation-allowance")
        app.launch()

        openCreateSheet()
        let chip = element("free-sticker-generations-chip")
        XCTAssertFalse(chip.exists)
        enterCreationIdea()
        finishCreationChoices()

        let title = app.staticTexts["Ready to create?"]
        let review = app.staticTexts["Review your choices. Tap any section to change it."]
        XCTAssertTrue(chip.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(title.exists)
        XCTAssertTrue(review.exists)
        XCTAssertGreaterThan(chip.frame.minY, title.frame.maxY)
        XCTAssertLessThan(chip.frame.maxY, review.frame.minY)
        XCTAssertLessThan(chip.frame.maxY, element("generate-sticker-button").frame.minY)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Free generations above review choices"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testSubscriptionControlsRemainVisibleWhenStoreKitCannotInitialize() {
        app.terminate()
        app.launchArguments.append("--ui-subscription-unavailable")
        app.launch()

        XCTAssertTrue(element("credits-chip").waitForExistence(timeout: 15))
        app.tabBars.buttons["Account"].tap()
        XCTAssertTrue(element("view-plans-button").waitForExistence(timeout: 15))
        XCTAssertTrue(element("manage-subscription-button").exists)
        element("view-plans-button").tap()
        let errorAlert = app.alerts["Subscription Error"]
        XCTAssertTrue(errorAlert.waitForExistence(timeout: 15))
        XCTAssertTrue(errorAlert.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Unable to Complete Request")
        ).firstMatch.exists)
        XCTAssertTrue(errorAlert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "ASDErrorDomain (530)")).firstMatch.exists)
        errorAlert.buttons["Close"].tap()
        XCTAssertTrue(element("subscription-connection-error").waitForExistence(timeout: 15))
        let unavailable = XCTAttachment(screenshot: app.screenshot())
        unavailable.name = "Subscription connection can be retried"
        unavailable.lifetime = .keepAlways
        add(unavailable)
        XCTAssertTrue(element("subscription-connection-retry").exists, app.debugDescription)

        // An authenticated refresh can still fail. Its new error must open another alert.
        // Retried against the alert because a swallowed tap and a retry that failed silently look
        // identical from here — the same card, unchanged. A tap that did land is not repeated, so
        // the second retry, the one the fixture lets through, stays the user's own.
        XCTAssertTrue(tap(element("subscription-connection-retry"), until: errorAlert, timeout: 15, attempts: 2),
                      app.debugDescription)
        XCTAssertTrue(errorAlert.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "storekit.refresh.request")
        ).firstMatch.exists)
        let diagnosticAlert = XCTAttachment(screenshot: app.screenshot())
        diagnosticAlert.name = "StoreKit error details after failed retry"
        diagnosticAlert.lifetime = .keepAlways
        add(diagnosticAlert)
        errorAlert.buttons["Copy Diagnostics"].tap()
        XCTAssertTrue(errorAlert.waitForNonExistence(timeout: 15))
        element("subscription-connection-error-details").tap()
        XCTAssertTrue(errorAlert.waitForExistence(timeout: 15))
        errorAlert.buttons["Close"].tap()

        element("subscription-connection-retry").tap()
        XCTAssertTrue(app.staticTexts["Choose your plan"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Monthly Points"].exists)
        let recovered = XCTAttachment(screenshot: app.screenshot())
        recovered.name = "Subscription plans after retry"
        recovered.lifetime = .keepAlways
        add(recovered)
        element("paywall-done").tap()
        let credits = element("subscription-credits")
        XCTAssertTrue(credits.waitForExistence(timeout: 15))
        XCTAssertEqual(credits.label, "Credits, 42")
    }

    @MainActor
    func testBalanceRefreshCancellationPreservesDataAndCanRefreshAgain() {
        app.terminate()
        app.launchArguments.append("--ui-balance-refresh")
        app.launch()
        let picker = element("credits-section-picker")
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        picker.buttons["Balance"].tap()
        let originalGrant = app.staticTexts["Refresh fixture grant 100"]
        XCTAssertTrue(originalGrant.waitForExistence(timeout: 15))

        let scroll = element("balance-scroll")
        pullToRefresh(scroll)
        // The second request returns URLSession's cancellation error for both endpoints.
        XCTAssertFalse(app.staticTexts["cancelled"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Something went wrong"].exists)
        XCTAssertTrue(originalGrant.exists)

        // Pulled until the refresh takes rather than once: the fixture serves the new grant from
        // the third request onwards, so an extra pull cannot change what this asserts, and the
        // single pull that a loaded clone spends on a scroll instead reads as a missing row.
        XCTAssertTrue(pullToRefresh(scroll, until: app.staticTexts["Refresh fixture grant 250"]),
                      app.debugDescription)
        XCTAssertFalse(originalGrant.exists)
        // The balance and the ledger are two responses, and the row can be on screen a frame before
        // the number it changed. Waited on rather than read once: instantly is not what this asserts.
        XCTAssertTrue(app.staticTexts["250"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.staticTexts["cancelled"].exists)
    }
}
