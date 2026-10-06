import XCTest

@MainActor
final class PetThemeUITests: StickerGeniOSUITestCase {
    /// The Places tab lists where the pet can go. A place opens in its own sheet: an open one takes
    /// the pet there and draws it behind the pet, a closed one says why and cannot be gone to, and a
    /// one-time place that has passed offers no way back. Bringing the pet home shows the page again.
    @MainActor
    func testTakingThePetToAPlaceAndBringingItHome() {
        app.terminate()
        app.launchArguments.append("--ui-installed-pack")
        app.launch()

        app.tabBars.buttons["Pet"].tap()
        let choose = element("choose-pet-button")
        XCTAssertTrue(choose.waitForExistence(timeout: 15))
        choose.tap()
        let candidate = element("pet-candidate-sticker-borrowed")
        XCTAssertTrue(candidate.waitForExistence(timeout: 15))
        candidate.tap()
        XCTAssertTrue(element("current-pet").waitForExistence(timeout: 15))
        XCTAssertTrue(element("pet-room-backdrop-plain").exists)
        XCTAssertFalse(element("pet-bring-home-button").exists)

        element("pet-stats").swipeUp()
        element("pet-actions-button").tap()
        XCTAssertTrue(app.navigationBars["Spend Time Together"].waitForExistence(timeout: 5))
        app.buttons["Places"].firstMatch.tap()

        // The night market only opens in the evening: it says so, and cannot be gone to.
        let market = element("pet-theme-mock-theme-market")
        XCTAssertTrue(market.waitForExistence(timeout: 15))
        market.tap()
        XCTAssertTrue(app.navigationBars["Night Market"].waitForExistence(timeout: 5))
        XCTAssertFalse(element("pet-theme-go").isEnabled)
        app.navigationBars["Night Market"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Night Market"].waitForNonExistence(timeout: 5))

        // The trip has passed: it is kept to look back on, with no way to go.
        let kyoto = element("pet-theme-mock-theme-kyoto")
        kyoto.swipeUp()
        kyoto.tap()
        XCTAssertTrue(app.navigationBars["Kyoto Streets"].waitForExistence(timeout: 5))
        XCTAssertFalse(element("pet-theme-go").exists)
        app.navigationBars["Kyoto Streets"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Kyoto Streets"].waitForNonExistence(timeout: 5))

        let cafe = element("pet-theme-mock-theme-cafe")
        cafe.swipeDown()
        cafe.tap()
        let go = element("pet-theme-go")
        XCTAssertTrue(go.waitForExistence(timeout: 5))
        XCTAssertTrue(go.isEnabled)
        go.tap()
        XCTAssertTrue(app.navigationBars["Corner Café"].waitForNonExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Your pet is here"].waitForExistence(timeout: 5))

        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Spend Time Together"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(element("pet-room-backdrop").waitForExistence(timeout: 15))
        // The place has its own clock, weather board and status board, like a room.
        XCTAssertTrue(element("pet-room-clock").waitForExistence(timeout: 15))
        XCTAssertTrue(element("pet-room-weather").exists)
        XCTAssertTrue(element("pet-room-status").waitForExistence(timeout: 5))
        XCTAssertTrue(element("pet-stats").waitForNonExistence(timeout: 5))
        let there = XCTAttachment(screenshot: app.screenshot())
        there.name = "pet-theme-cafe"
        there.lifetime = .keepAlways
        add(there)

        // The exit button brings the pet home directly from the screen.
        let home = element("pet-bring-home-button")
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        XCTAssertTrue(home.isHittable)
        home.tap()
        XCTAssertTrue(home.waitForNonExistence(timeout: 15))
        XCTAssertTrue(element("pet-room-backdrop-plain").waitForExistence(timeout: 15))
    }
}
