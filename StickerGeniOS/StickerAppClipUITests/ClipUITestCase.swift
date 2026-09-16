import XCTest

/// Shared setup and assertions for the App Clip UI suites.
///
/// The suites are split by subject rather than kept in one class because XCTest distributes parallel
/// UI testing per *class*, not per test: a single class runs on a single simulator clone however many
/// workers are available, so one big class sets the floor on the job's wall-clock.
@MainActor
class ClipUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    }

    override func tearDownWithError() throws { app.terminate() }

    func open(_ url: String) {
        app.open(URL(string: url)!)
    }

    func assertQuick(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.staticTexts["Make a sticker"].waitForExistence(timeout: 15), file: file, line: line)
        XCTAssertTrue(app.buttons["Sign in with RxLab"].exists, file: file, line: line)
        XCTAssertFalse(app.navigationBars["Sticker pack"].exists, file: file, line: line)
    }

    func assertPack(_ title: String, sticker: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 15), file: file, line: line)
        XCTAssertTrue(app.staticTexts["by Clip Creator"].exists, file: file, line: line)
        XCTAssertTrue(app.staticTexts[sticker].exists, file: file, line: line)
        XCTAssertTrue(app.buttons["Install in Sticker Factory"].exists, file: file, line: line)
        XCTAssertTrue(app.buttons["Share pack"].exists, file: file, line: line)
        XCTAssertFalse(app.buttons["Sign in with RxLab"].exists, file: file, line: line)
    }

    func launchLibrary(_ extra: String...) {
        app.launchArguments += ["--clip-signed-in", "--clip-library-fixtures"] + extra
        app.launch()
        XCTAssertTrue(app.navigationBars["My stickers"].waitForExistence(timeout: 15))
    }

    func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
