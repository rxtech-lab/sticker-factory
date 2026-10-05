import XCTest

/// Captures the app's main screens for the PR screenshot comment (`.github/workflows/ios-screenshots.yml`).
///
/// These are a design check, not a behaviour check: CI runs the `ScreenshotTests` plan once per
/// device class (iPhone, iPad), exports every `screenshot__` attachment from the result
/// bundle, and posts them side by side so a reviewer can see each layout. Each screen is its own test
/// so one screen that cannot be reached on a device still leaves the rest of that device's set.
///
/// Not a subclass of `StickerGeniOSUITestCase`: that setup forces portrait and finds tabs through
/// `app.tabBars`, and on iPad the tab bar is drawn as a top bar or sidebar that
/// does not always surface as one.
@MainActor
final class ScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    func testLibrary() {
        launch()
        capture("01-library")
    }

    func testStickerPacks() {
        launch()
        openTab("Sticker Packs")
        XCTAssertTrue(app.navigationBars["Sticker Packs"].waitForExistence(timeout: 15))
        capture("02-sticker-packs")
    }

    func testCreate() {
        launch()
        let create = element("create-sticker-button")
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        create.tap()
        XCTAssertTrue(app.navigationBars["Create"].waitForExistence(timeout: 15))
        capture("03-create")
    }

    func testPet() {
        launch(["--ui-installed-pack"])
        openTab("Pet")
        let choose = element("choose-pet-button")
        XCTAssertTrue(choose.waitForExistence(timeout: 15))
        capture("04-pet-empty")

        choose.tap()
        XCTAssertTrue(app.navigationBars["Choose a Pet"].waitForExistence(timeout: 15))
        capture("05-pet-picker")

        let candidate = element("pet-candidate-sticker-borrowed")
        XCTAssertTrue(candidate.waitForExistence(timeout: 15))
        candidate.tap()
        XCTAssertTrue(element("current-pet").waitForExistence(timeout: 15))
        capture("06-pet")
    }

    func testAccount() {
        launch()
        openTab("Account")
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 15))
        capture("07-account")
    }

    private func launch(_ extra: [String] = []) {
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reduce-motion",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ] + extra
        app.launch()
        XCTAssertTrue(element("library-sticker-sticker-demo").waitForExistence(timeout: 20), app.debugDescription)
    }

    /// Taps a tab by its title wherever the system drew it: the bottom tab bar on iPhone, the
    /// floating top bar or sidebar on iPad.
    private func openTab(_ title: String) {
        let barButton = app.tabBars.buttons[title]
        let tab = barButton.waitForExistence(timeout: 5)
            ? barButton
            : app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10), app.debugDescription)
        tab.tap()
    }

    /// Lets transitions and image loads settle before the shot; reduce-motion shortens but does not
    /// remove them.
    private func capture(_ name: String) {
        pause(1)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "screenshot__\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
