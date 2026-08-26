import XCTest

final class StickerGeniOSUITestsLaunchTests: XCTestCase {
    override class var runsForEachTargetApplicationUIConfiguration: Bool { true }

    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testAuthenticatedReduceMotionLaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reduce-motion"]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "library-sticker-sticker-demo").firstMatch.exists)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Authenticated Library - Reduce Motion"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
