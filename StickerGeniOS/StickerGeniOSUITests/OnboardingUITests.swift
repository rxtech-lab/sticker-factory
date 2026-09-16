// The first-run sheets: the welcome tour and the feature cards that follow it. They are their own
// case because each one relaunches the app with the flags that force a sheet the default automation
// launch suppresses — see `--ui-show-welcome` and `--ui-show-feature-cards`.

import XCTest

@MainActor
final class OnboardingUITests: XCTestCase {
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
        next.tap()
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: app.staticTexts["Controllable animation"])
        waitForExpectations(timeout: 3)
        next.tap()
        XCTAssertTrue(app.staticTexts["Learn with tutorials"].waitForExistence(timeout: 3))
        XCTAssertTrue(element("feature-read-tutorials").exists)
        XCTAssertTrue(app.buttons["Got it"].exists)
        app.buttons["Got it"].tap()
        XCTAssertFalse(app.staticTexts["Controllable animation"].waitForExistence(timeout: 2))
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
        element("feature-card-next-button").tap()
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

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
