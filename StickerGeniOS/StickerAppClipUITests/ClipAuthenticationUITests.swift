import XCTest

@MainActor
final class ClipAuthenticationUITests: ClipUITestCase {
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
        XCTAssertTrue(signOut.waitForExistence(timeout: 15))
        signOut.tap()
        XCTAssertTrue(app.buttons["Sign in with RxLab"].waitForExistence(timeout: 15), app.debugDescription)
        assertQuick()
        XCTAssertFalse(signOut.exists)
        XCTAssertFalse(app.textFields["quick-prompt"].exists)

        app.buttons["Sign in with RxLab"].tap()
        XCTAssertTrue(app.buttons["clip-sign-in-close"].waitForExistence(timeout: 15))
    }

    func testNativeSignInSheetRequiresToolbarDismissal() {
        app.launch()
        assertQuick()
        XCTAssertTrue(app.staticTexts["Sign in to see your allowance."].exists)
        XCTAssertFalse(app.staticTexts["Five free generations daily"].exists)
        app.buttons["Sign in with RxLab"].tap()
        let close = app.buttons["clip-sign-in-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 15))
        let passwordMethod = app.buttons["sign-in-button"]
        XCTAssertTrue(passwordMethod.waitForExistence(timeout: 20))
        passwordMethod.tap()
        XCTAssertTrue(app.secureTextFields["password-field"].waitForExistence(timeout: 15))
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
        XCTAssertTrue(close.waitForNonExistence(timeout: 15))
        assertQuick()
        app.buttons["Sign in with RxLab"].tap()
        XCTAssertTrue(close.waitForExistence(timeout: 15))
        XCTAssertTrue(passwordMethod.waitForExistence(timeout: 15))
        close.tap()
    }
}
