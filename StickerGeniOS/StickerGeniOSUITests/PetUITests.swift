import XCTest

@MainActor
final class PetUITests: StickerGeniOSUITestCase {
    /// Pet is the first tab, even though launch still lands on the Library.
    @MainActor
    func testPetIsTheFirstTab() {
        XCTAssertEqual(app.tabBars.buttons.element(boundBy: 0).label, "Pet")
        XCTAssertEqual(app.tabBars.buttons.element(boundBy: 1).label, "Library")
    }

    /// Adopt from the Pet tab, see it shown, then spend time with it.
    @MainActor
    func testChoosingAPet() {
        app.terminate()
        app.launchArguments.append("--ui-installed-pack")
        app.launch()

        app.tabBars.buttons["Pet"].tap()
        XCTAssertTrue(app.navigationBars["Pet"].waitForExistence(timeout: 15))
        let choose = element("choose-pet-button")
        XCTAssertTrue(choose.waitForExistence(timeout: 15))
        choose.tap()

        XCTAssertTrue(app.navigationBars["Choose a Pet"].waitForExistence(timeout: 15))
        let candidate = element("pet-candidate-sticker-borrowed")
        XCTAssertTrue(candidate.waitForExistence(timeout: 15))
        candidate.tap()

        // Adopting closes the sheet and the tab now shows the pet.
        XCTAssertTrue(app.navigationBars["Choose a Pet"].waitForNonExistence(timeout: 15))
        let current = element("current-pet")
        XCTAssertTrue(current.waitForExistence(timeout: 15))
        XCTAssertTrue(current.label.contains("Loaf"))
        XCTAssertTrue(element("change-pet-button").exists)
        // The weather where the owner is stands behind the pet.
        XCTAssertTrue(element("pet-weather").waitForExistence(timeout: 5))

        XCTAssertTrue(element("pet-stats").exists)
        element("pet-stats").swipeUp()
        element("pet-actions-button").tap()
        XCTAssertTrue(app.navigationBars["Spend Time Together"].waitForExistence(timeout: 5))
        element("pet-action-22222222-2222-4222-8222-222222222222").tap()
        XCTAssertTrue(app.navigationBars["Spend Time Together"].waitForNonExistence(timeout: 15))
        // The sheet closes before the reply; the dialogue box fills in once it lands.
        let reply = NSPredicate(format: "label CONTAINS %@", "Move together with Loaf.")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: reply, evaluatedWith: element("pet-dialogue"))], timeout: 15), .completed)
    }

    /// Actions show only their gold, one the pet cannot afford is held back, and spending moves the
    /// gold beside the pet. The Change button then offers releasing the pet.
    @MainActor
    func testGoldActionsAndReleasingThePet() {
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
        XCTAssertEqual(element("pet-gold").label, "20 gold")

        element("pet-stats").swipeUp()
        element("pet-actions-button").tap()
        XCTAssertTrue(app.navigationBars["Spend Time Together"].waitForExistence(timeout: 5))
        // The cake costs 40 gold and the pet has 20.
        XCTAssertFalse(element("pet-action-44444444-4444-4444-8444-444444444444").isEnabled)
        element("pet-action-22222222-2222-4222-8222-222222222222").tap()
        XCTAssertTrue(app.navigationBars["Spend Time Together"].waitForNonExistence(timeout: 15))
        let spent = NSPredicate(format: "label == %@", "15 gold")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: spent, evaluatedWith: element("pet-gold"))], timeout: 15), .completed)

        element("change-pet-button").tap()
        let release = app.buttons["Release Pet"].firstMatch
        XCTAssertTrue(release.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Change Pet"].firstMatch.exists)
        release.tap()
        XCTAssertTrue(element("choose-pet-button").waitForExistence(timeout: 15))
    }
}
