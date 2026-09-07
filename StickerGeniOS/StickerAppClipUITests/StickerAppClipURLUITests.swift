import XCTest

@MainActor
final class StickerAppClipURLUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    }

    override func tearDownWithError() throws { app.terminate() }

    private func open(_ url: String) {
        app.open(URL(string: url)!)
    }

    private func assertQuick(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.staticTexts["Make a sticker"].waitForExistence(timeout: 8), file: file, line: line)
        XCTAssertTrue(app.buttons["Sign in with RxLab"].exists, file: file, line: line)
        XCTAssertFalse(app.navigationBars["Sticker pack"].exists, file: file, line: line)
    }

    private func assertPack(_ title: String, sticker: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 8), file: file, line: line)
        XCTAssertTrue(app.staticTexts["by Clip Creator"].exists, file: file, line: line)
        XCTAssertTrue(app.staticTexts[sticker].exists, file: file, line: line)
        XCTAssertTrue(app.buttons["Install in Sticker Factory"].exists, file: file, line: line)
        XCTAssertTrue(app.buttons["Share pack"].exists, file: file, line: line)
        XCTAssertFalse(app.buttons["Sign in with RxLab"].exists, file: file, line: line)
    }

    private func launchLibrary(_ extra: String... ) {
        app.launchArguments += ["--clip-signed-in", "--clip-library-fixtures"] + extra
        app.launch()
        XCTAssertTrue(app.navigationBars["My stickers"].waitForExistence(timeout: 8))
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPastStickerOpensDetailAndLibraryPaginates() {
        launchLibrary()
        let past = app.buttons["clip-sticker-past-sticker"]
        XCTAssertTrue(past.waitForExistence(timeout: 8))
        XCTAssertFalse(app.textFields["quick-prompt"].exists)
        capture("App Clip sticker library")
        past.tap()
        XCTAssertTrue(app.navigationBars["Happy cat"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Share sticker"].waitForExistence(timeout: 8))
        capture("App Clip sticker detail")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Load more stickers"].tap()
        XCTAssertTrue(app.buttons["clip-sticker-older-sticker"].waitForExistence(timeout: 8))
    }

    func testQuickGenerationSheetNavigatesToFinishedSticker() {
        launchLibrary()
        app.buttons["clip-new-sticker"].tap()
        XCTAssertTrue(app.navigationBars["New sticker"].waitForExistence(timeout: 8))
        let prompt = app.textFields["quick-prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 8))
        capture("App Clip quick generation sheet")
        prompt.tap()
        prompt.typeText("Skateboarding cat")
        app.swipeUp()
        app.buttons["Generate sticker"].tap()
        XCTAssertTrue(app.navigationBars["Skateboarding cat"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.buttons["clip-generation-close"].exists)
        XCTAssertTrue(app.buttons["Share sticker"].exists)
        capture("App Clip generation completed detail")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["clip-sticker-new-sticker"].waitForExistence(timeout: 8))
        app.buttons["clip-new-sticker"].tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 8))
        XCTAssertEqual(prompt.value as? String, "Describe your sticker")
    }

    func testGenerationFinishesAfterClosingSheet() {
        launchLibrary("--clip-slow-generation")
        app.buttons["clip-new-sticker"].tap()
        let prompt = app.textFields["quick-prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 8))
        prompt.tap()
        prompt.typeText("Skateboarding cat")
        app.swipeUp()
        app.buttons["Generate sticker"].tap()
        app.buttons["clip-generation-close"].tap()
        XCTAssertTrue(app.buttons["clip-generation-status"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.navigationBars["Skateboarding cat"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Share sticker"].exists)
    }

    func testLibraryWithLargeText() {
        launchLibrary("-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL")
        XCTAssertTrue(app.buttons["clip-sticker-past-sticker"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["clip-new-sticker"].isHittable)
        capture("App Clip library with large text")
    }

    func testEmptyLibraryAndSheetDismissal() {
        launchLibrary("--clip-library-empty")
        XCTAssertTrue(app.staticTexts["Your first sticker starts here"].waitForExistence(timeout: 8))
        capture("App Clip empty library")
        app.buttons["clip-new-sticker"].tap()
        let close = app.buttons["clip-generation-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 8))
        close.tap()
        XCTAssertTrue(app.navigationBars["My stickers"].waitForExistence(timeout: 8))
    }

    func testLibraryFailureCanRetryAndStillCreate() {
        launchLibrary("--clip-library-error")
        XCTAssertTrue(app.staticTexts["Your stickers could not be loaded. Please try again."].waitForExistence(timeout: 8))
        app.buttons["Try again"].tap()
        XCTAssertTrue(app.buttons["clip-new-sticker"].exists)
        app.buttons["clip-new-sticker"].tap()
        XCTAssertTrue(app.navigationBars["New sticker"].waitForExistence(timeout: 8))
    }

    func testLaunchWithoutURLDefaultsToQuickMode() {
        app.launch()
        assertQuick()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "App Clip welcome"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testSignOutReturnsToWelcomeAndAllowsSignIn() {
        app.launchArguments.append("--clip-signed-in")
        app.launch()
        let signOut = app.buttons["clip-sign-out"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 8))
        signOut.tap()
        XCTAssertTrue(app.buttons["Sign in with RxLab"].waitForExistence(timeout: 8), app.debugDescription)
        assertQuick()
        XCTAssertFalse(signOut.exists)
        XCTAssertFalse(app.textFields["quick-prompt"].exists)

        app.buttons["Sign in with RxLab"].tap()
        XCTAssertTrue(app.buttons["clip-sign-in-close"].waitForExistence(timeout: 8))
    }

    func testNativeSignInSheetRequiresToolbarDismissal() {
        app.launch()
        assertQuick()
        XCTAssertTrue(app.staticTexts["Sign in to see your allowance."].exists)
        XCTAssertFalse(app.staticTexts["Five free generations daily"].exists)
        app.buttons["Sign in with RxLab"].tap()
        let close = app.buttons["clip-sign-in-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 8))
        let passwordMethod = app.buttons["sign-in-button"]
        XCTAssertTrue(passwordMethod.waitForExistence(timeout: 20))
        passwordMethod.tap()
        XCTAssertTrue(app.secureTextFields["password-field"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.textFields.firstMatch.exists)
        XCTAssertFalse(app.webViews.firstMatch.exists)

        let bar = app.navigationBars["Sign in"]
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        XCTAssertTrue(close.exists)
        XCTAssertTrue(app.secureTextFields["password-field"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Native sign-in sheet after attempted swipe dismissal"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        assertQuick()
        app.buttons["Sign in with RxLab"].tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(passwordMethod.waitForExistence(timeout: 10))
        close.tap()
    }

    func testQuickModeURLVariants() {
        for url in ["https://sticker.rxlab.app/share/ios", "https://sticker.rxlab.app/share/ios/?source=messages#open",
                    "https://sticker.rxlab.app:443/share/ios"] {
            open(url)
            assertQuick()
            app.terminate()
        }
    }

    func testPackInvocationURL() {
        open("https://STICKER.RXLAB.APP:443/share/ios/packs/happy-cats?source=messages")
        assertPack("Happy Cats", sticker: "Waving cat")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "App Clip shared pack"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testPackURLVariants() {
        for url in ["https://sticker.rxlab.app/share/ios/packs/happy-cats",
                    "https://sticker.rxlab.app/share/ios/packs/happy-cats/?source=messages#preview"] {
            open(url)
            assertPack("Happy Cats", sticker: "Waving cat")
            app.terminate()
        }
    }

    func testSuccessiveURLLaunchesShowRequestedContent() {
        open("https://sticker.rxlab.app/share/ios/packs/happy-cats")
        assertPack("Happy Cats", sticker: "Waving cat")
        open("https://sticker.rxlab.app/share/ios/packs/space-dogs")
        assertPack("Space Dogs", sticker: "Moon dog")
        XCTAssertFalse(app.staticTexts["Happy Cats"].exists)
        open("https://sticker.rxlab.app/share/ios")
        assertQuick()
    }

    func testUnavailablePackAndRetry() {
        open("https://sticker.rxlab.app/share/ios/packs/missing-pack")
        XCTAssertTrue(app.staticTexts["Pack unavailable"].waitForExistence(timeout: 8))
        app.buttons["Try again"].tap()
        XCTAssertTrue(app.staticTexts["This pack is no longer available."].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Install in Sticker Factory"].exists)
    }

    func testEncodedPathSeparatorsAreRejected() {
        for url in ["https://sticker.rxlab.app/share/ios/packs/happy%2Fcats",
                    "https://sticker.rxlab.app/share/ios/packs/happy%5Ccats"] {
            open(url)
            assertQuick()
            app.terminate()
        }
    }

    func testUnsupportedURLsStayInQuickMode() {
        for url in ["http://sticker.rxlab.app/share/ios", "stickerfactoryclip://share/ios",
                    "https://example.com/share/ios", "https://sticker.rxlab.app:444/share/ios",
                    "https://user@sticker.rxlab.app/share/ios", "https://sticker.rxlab.app/share/android",
                    "https://sticker.rxlab.app/share/ios/packs", "https://sticker.rxlab.app/share/ios/packs/cats/extra"] {
            open(url)
            assertQuick()
            app.terminate()
        }
    }
}
