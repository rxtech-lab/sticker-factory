import XCTest

final class StickerGeniOSUITestsLaunchTests: XCTestCase {
    override class var runsForEachTargetApplicationUIConfiguration: Bool { true }

    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testAuthenticatedReduceMotionLaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reduce-motion"]
        app.launch()

        // This test runs once per target application UI configuration, which includes every
        // localization the app ships (en, zh-CN, zh-HK). Matching a tab by its English title would
        // fail in all of them but English, so identify the launch state by accessibility
        // identifiers, which are the same in every language.
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "library-sticker-sticker-demo")
                .firstMatch
                .waitForExistence(timeout: 8)
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Authenticated Library - Reduce Motion"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
