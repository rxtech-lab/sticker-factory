import XCTest

@MainActor
final class TutorialUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reduce-motion", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["TUTORIAL_BASE_URL"] = "http://127.0.0.1:3117"
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    func testCreateTutorialPreservesPromptAndReturnsToSameForm() {
        app.launch()
        XCTAssertTrue(element("create-sticker-button").waitForExistence(timeout: 10))
        element("create-sticker-button").tap()
        let prompt = element("sticker-prompt")
        prompt.tap(); prompt.typeText("A cheerful corgi")
        element("creation-next").tap()
        element("tutorial-link-static").tap()
        XCTAssertTrue(element("tutorial-sheet").waitForExistence(timeout: 5))
        XCTAssertTrue(element("tutorial-step-title").waitForExistence(timeout: 15))
        // Tutorials resume saved progress. Return to the creation lesson before trying its action.
        let previousLesson = element("tutorial-sheet").buttons["Back"]
        for _ in 0..<3 where previousLesson.isEnabled { previousLesson.tap() }
        XCTAssertEqual(element("tutorial-step-title").label, "Start with Static")
        let sheet = element("tutorial-sheet")
        sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03))
            .press(forDuration: 0.1, thenDragTo: sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        XCTAssertTrue(element("tutorial-sheet").exists)
        XCTAssertTrue(element("tutorial-try-it").waitForExistence(timeout: 15))
        for _ in 0..<6 where !element("tutorial-try-it").isHittable { app.swipeUp() }
        element("tutorial-try-it").tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: sheet)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed)
        let back = element("creation-back")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: back)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        back.tap()
        XCTAssertTrue(element("sticker-prompt").waitForExistence(timeout: 5))
        XCTAssertEqual(element("sticker-prompt").value as? String, "A cheerful corgi")
    }
    func testFirstRunOffersTutorialOnlyOnLastFeatureCard() {
        app.launchArguments += ["--ui-show-welcome", "--ui-show-feature-cards"]
        app.launch()
        XCTAssertTrue(element("welcome-next-button").waitForExistence(timeout: 10))
        for _ in 0..<5 { element("welcome-next-button").tap() }
        XCTAssertFalse(element("welcome-read-tutorials").exists)
        element("welcome-next-button").tap()
        for _ in 0..<3 {
            XCTAssertFalse(element("feature-read-tutorials").exists)
            element("feature-card-next-button").tap()
        }
        XCTAssertTrue(element("feature-read-tutorials").waitForExistence(timeout: 5))
        element("feature-read-tutorials").tap()
        XCTAssertTrue(element("tutorial-sheet").waitForExistence(timeout: 5))
        XCTAssertFalse(element("feature-cards-sheet").exists)
        XCTAssertTrue(element("tutorial-chapter-static").waitForExistence(timeout: 15))
    }
    func testAccountLanguageDropdownDoesNotReopenTutorial() {
        app.launch()
        app.tabBars.buttons.element(boundBy: 2).tap()
        let entry = element("tutorial-link-index")
        for _ in 0..<4 where !entry.isHittable { app.swipeUp() }
        entry.tap()
        XCTAssertTrue(element("tutorial-chapter-static").waitForExistence(timeout: 15))
        element("tutorial-chapter-static").tap()
        XCTAssertTrue(element("tutorial-step-title").waitForExistence(timeout: 5))
        let originalTitle = element("tutorial-step-title").label
        element("tutorial-language").tap()
        XCTAssertTrue(element("tutorial-language-dropdown").waitForExistence(timeout: 3))
        for language in ["en", "zh-CN", "zh-HK"] {
            XCTAssertTrue(element("tutorial-language-\(language)").isHittable)
        }
        element("tutorial-language").tap()
        XCTAssertFalse(element("tutorial-language-dropdown").exists)
        XCTAssertEqual(element("tutorial-step-title").label, originalTitle)
        XCTAssertFalse(element("tutorial-chapter-static").exists)
        element("tutorial-language").tap()
        element("tutorial-language-en").tap()
        XCTAssertEqual(element("tutorial-step-title").label, originalTitle)
        XCTAssertTrue(element("tutorial-sheet").exists)
    }
    func testAccountTutorialAndUnavailableRetry() {
        app.launchEnvironment["TUTORIAL_BASE_URL"] = "http://127.0.0.1:3199"
        app.launch()
        app.tabBars.buttons.element(boundBy: 2).tap()
        let entry = element("tutorial-link-index")
        for _ in 0..<4 where !entry.isHittable { app.swipeUp() }
        entry.tap()
        XCTAssertTrue(element("tutorial-retry").waitForExistence(timeout: 15))
        element("tutorial-retry").tap()
        XCTAssertTrue(element("tutorial-close").exists)
        element("tutorial-close").tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
    }
}
