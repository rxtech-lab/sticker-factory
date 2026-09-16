import XCTest

@MainActor
final class LibraryUITests: StickerGeniOSUITestCase {
    @MainActor
    func testAuthenticatedTabsAndLibraryAccessibility() {
        XCTAssertTrue(app.tabBars.buttons["Library"].isSelected)
        XCTAssertFalse(app.tabBars.buttons["Create"].exists)
        XCTAssertFalse(app.tabBars.buttons["Marketplace"].exists)
        XCTAssertTrue(app.tabBars.buttons["Sticker Packs"].exists)
        XCTAssertTrue(app.tabBars.buttons["Account"].exists)
        XCTAssertTrue(element("create-sticker-button").exists)
        XCTAssertTrue(element("library-filter-menu").exists)
        XCTAssertTrue(element("library-sticker-sticker-demo").waitForExistence(timeout: 15))

        app.tabBars.buttons["Account"].tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 15))
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
        XCTAssertTrue(element("about-page-view").waitForExistence(timeout: 15))
        XCTAssertTrue(element("app-version").waitForExistence(timeout: 15))
        XCTAssertFalse(app.tabBars.buttons["Library"].exists)
    }

    @MainActor
    func testHomeActionsMenuOffersShareAlongsideFilter() {
        let menu = element("library-filter-menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 15))

        menu.tap()

        XCTAssertTrue(element("home-share").waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["All"].exists)
        XCTAssertTrue(app.buttons["Static"].exists)
        XCTAssertTrue(app.buttons["Animated"].exists)
    }

    @MainActor
    func testLegalDocumentHidesTabBar() {
        app.tabBars.buttons["Account"].tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 15))

        element("privacy-policy-link").tap()
        XCTAssertTrue(element("legal-document-view").waitForExistence(timeout: 15))
        XCTAssertFalse(app.tabBars.buttons["Library"].exists)
    }

    @MainActor
    func testLibrarySearchShowsRemoteNoResultsState() {
        let search = app.searchFields["Search stickers"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap()
        search.typeText("No such sticker")

        XCTAssertTrue(app.staticTexts["No matching stickers"].waitForExistence(timeout: 15))
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

        XCTAssertTrue(app.alerts["Couldn’t Complete Action"].waitForExistence(timeout: 15))
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

        XCTAssertTrue(app.alerts["Couldn’t Complete Action"].waitForExistence(timeout: 15))
        app.buttons["OK"].tap()

        XCTAssertTrue(app.staticTexts["Couldn’t load your library"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["No stickers yet"].exists)
        let retry = element("library-retry-button")
        XCTAssertTrue(retry.exists)

        // The mock fails every listing, so the retry is expected to fail again — what matters is
        // that it ran, and that the way back is still there afterwards.
        retry.tap()
        XCTAssertTrue(app.alerts["Couldn’t Complete Action"].waitForExistence(timeout: 15))
        app.buttons["OK"].tap()
        XCTAssertTrue(element("library-retry-button").waitForExistence(timeout: 15))
    }

    @MainActor
    func testLibraryStickerContextMenuOffersRenameAndConfirmedDelete() {
        let card = element("library-sticker-sticker-demo")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.press(forDuration: 1)

        let rename = element("rename-library-sticker-sticker-demo")
        XCTAssertTrue(rename.waitForExistence(timeout: 15))
        XCTAssertTrue(element("delete-library-sticker-sticker-demo").exists)
        rename.tap()

        // SwiftUI's alert hosts the field outside the app's ordinary accessibility container and
        // drops its custom identifier, while preserving the visible prompt as the field label.
        let renameField = app.textFields["Sticker name"]
        XCTAssertTrue(renameField.waitForExistence(timeout: 15))
        XCTAssertEqual(renameField.value as? String, "Happy bounce")
        app.buttons["Cancel"].tap()

        card.press(forDuration: 1)
        element("delete-library-sticker-sticker-demo").tap()
        XCTAssertTrue(app.staticTexts["Delete this sticker project?"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Delete “Happy bounce”"].exists)
        // On this compact confirmation-dialog presentation XCTest exposes the destructive action
        // but not SwiftUI's cancel role, so dismiss through the modal backdrop as a user can.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        XCTAssertTrue(card.exists)
    }
}
