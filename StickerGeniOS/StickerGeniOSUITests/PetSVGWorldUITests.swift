import XCTest

@MainActor
final class PetSVGWorldUITests: StickerGeniOSUITestCase {
    func testLegacyPetInSVGWorldMovesByTapAndSurvivesRotationAndBackgrounding() {
        app.terminate()
        app.launchArguments += ["--ui-installed-pack", "--ui-svg-world"]
        app.launch()
        app.tabBars.buttons["Pet"].tap()
        let world = element("pet-svg-world")
        let pet = element("current-pet")
        XCTAssertTrue(world.waitForExistence(timeout: 15))
        XCTAssertTrue(pet.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(element("pet-dialogue").exists)
        let before = pet.frame.midX
        let roaming = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in abs(pet.frame.midX - before) > 5 }, object: nil)
        roaming.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [roaming], timeout: 6), .completed)
        // Reduce Motion is on in this suite. Deliberate movement remains available.
        world.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.72)).tap()
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in abs(pet.frame.midX - before) > 12 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 10), .completed)
        pet.tap()
        XCTAssertTrue(element("pet-dialogue").exists)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(world.waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(pet.waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .portrait
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "svg-world-with-legacy-pet"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
