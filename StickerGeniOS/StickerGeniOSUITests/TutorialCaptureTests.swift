import XCTest

/// Captures real app views with the mock service and curated assets. No live account or AI calls.
@MainActor
final class TutorialCaptureTests: XCTestCase {
    private var app: XCUIApplication!
    private var locale = "en"
    override func setUpWithError() throws { continueAfterFailure = false }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func launch(_ extra: [String] = []) {
        app?.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--ui-tutorial-capture", "--reduce-motion",
            "-AppleLanguages", "(\(locale))",
            "-AppleLocale", locale.replacingOccurrences(of: "-", with: "_")
        ] + extra
        app.launchEnvironment["TUTORIAL_BASE_URL"] = "http://127.0.0.1:3117"
        app.launch()
        XCTAssertTrue(element("create-sticker-button").waitForExistence(timeout: 10))
    }
    private func capture(_ name: String) {
        Thread.sleep(forTimeInterval: 0.6)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "tutorial__\(locale)__\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func marker(_ name: String, _ edge: String) {
        print("TUTORIAL_VIDEO \(locale) \(name) \(edge) \(Date().timeIntervalSince1970)")
    }
    func testCaptureEnglish() { locale = "en"; captureAll() }
    func testCaptureSimplifiedChinese() { locale = "zh-CN"; captureAll() }
    func testCaptureTraditionalChinese() { locale = "zh-HK"; captureAll() }
    func testCaptureCreationEnglish() { locale = "en"; captureAll(creationOnly: true) }
    func testCaptureCreationSimplifiedChinese() { locale = "zh-CN"; captureAll(creationOnly: true) }
    func testCaptureCreationTraditionalChinese() { locale = "zh-HK"; captureAll(creationOnly: true) }
    func testCaptureRemainingEnglish() { locale = "en"; captureRemaining() }
    func testCaptureRemainingSimplifiedChinese() { locale = "zh-CN"; captureRemaining() }
    func testCaptureRemainingTraditionalChinese() { locale = "zh-HK"; captureRemaining() }
    private func captureAll(creationOnly: Bool = false) {
        launch()
        element("create-sticker-button").tap()
        let prompt = element("sticker-prompt")
        prompt.tap()
        prompt.typeText(locale == "en" ? "A cheerful corgi in a yellow raincoat" : locale == "zh-CN" ? "穿黄色雨衣的开心柯基" : "穿黃色雨衣的開心哥基")
        app.swipeDown()
        capture("create-prompt")
        element("creation-next").tap()
        element("creation-back").tap()
        app.swipeUp()
        capture("create-references")
        element("creation-next").tap()
        XCTAssertTrue(element("sticker-kind-picker").waitForExistence(timeout: 5))
        capture("create-static")
        marker("create-animated", "start")
        element("sticker-kind-picker").buttons.element(boundBy: 1).tap()
        capture("create-animated")
        element("creation-next").tap()
        element("preset-option-style-bold-cartoon").tap()
        element("creation-next").tap()
        element("creation-next").tap()
        let toggle = element("sticker-controllable-toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.switches.firstMatch.tap()
        app.swipeUp()
        capture("create-controllable")
        let picker = element("sticker-pose-preset-picker")
        picker.buttons.element(boundBy: 2).tap()
        Thread.sleep(forTimeInterval: 0.8)
        picker.buttons.element(boundBy: 1).tap()
        marker("create-animated", "end")
        if creationOnly {
            element("creation-next").tap()
            XCTAssertTrue(element("generate-sticker-button").waitForExistence(timeout: 5))
            capture("create-overview")
            return
        }

        captureRemaining()
    }
    private func captureRemaining() {
        launch(["--ui-plan-versions"])
        element("library-sticker-sticker-demo").tap()
        XCTAssertTrue(element("tutorial-link-finish").waitForExistence(timeout: 8))
        app.swipeDown()
        capture("plan")

        launch(["--ui-configurable-sticker"])
        element("library-sticker-sticker-demo").tap()
        XCTAssertTrue(element("show-sticker-attachment").waitForExistence(timeout: 8))
        capture("sticker")
        element("show-sticker-attachment").tap()
        XCTAssertTrue(element("sticker-controls-sheet").waitForExistence(timeout: 5))
        capture("controls")
        marker("controls", "start")
        let mood = element("sticker-control-mood")
        if mood.isHittable { mood.tap(); app.buttons["Calm"].tap() }
        let animate = app.switches["sticker-controls-animate"]
        if animate.isHittable { animate.tap(); Thread.sleep(forTimeInterval: 1); animate.tap() }
        Thread.sleep(forTimeInterval: 1)
        marker("controls", "end")
        element("sticker-controls-apply").tap()
        element("dismiss-full-screen-player").tap()
        element("sticker-actions-menu").tap()
        element("export-sticker").tap()
        XCTAssertTrue(element("sticker-export-sheet").waitForExistence(timeout: 5))
        capture("export")

        launch()
        app.tabBars.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(element("create-pack-button").waitForExistence(timeout: 5))
        capture("packs")
        element("create-pack-button").tap()
        XCTAssertTrue(element("pack-title-field").waitForExistence(timeout: 5))
        let packTitle = locale == "en" ? "Winky friends" : locale == "zh-CN" ? "Winky 好朋友" : "Winky 好朋友"
        element("pack-title-field").tap(); element("pack-title-field").typeText(packTitle)
        app.swipeDown()
        marker("new-pack", "start")
        element("pack-choose-stickers-button").tap()
        XCTAssertTrue(element("pack-pick-tutorial-0").waitForExistence(timeout: 5))
        capture("pack-picker")
        for index in 0..<3 { element("pack-pick-tutorial-\(index)").tap() }
        element("sticker-picker-done-button").tap()
        capture("new-pack")
        marker("new-pack", "end")
        element("pack-create-draft-button").tap()
        launch()
        app.tabBars.buttons.element(boundBy: 1).tap()
        element("marketplace-pack-pack-demo").tap()
        XCTAssertTrue(element("pack-messenger-whatsapp").waitForExistence(timeout: 10))
        capture("pack-detail")
        for destination in ["whatsapp", "telegram"] {
            marker(destination, "start")
            element("pack-messenger-\(destination)").tap()
            XCTAssertTrue(element("messenger-export-sheet").waitForExistence(timeout: 5))
            XCTAssertTrue(element("messenger-not-installed").waitForExistence(timeout: 5))
            capture(destination)
            let emoji = element("messenger-emoji-tutorial-0")
            if emoji.isHittable { emoji.tap(); Thread.sleep(forTimeInterval: 1); app.alerts.buttons.element(boundBy: 0).tap() }
            Thread.sleep(forTimeInterval: 1)
            marker(destination, "end")
            element("messenger-export-close").tap()
        }
    }
}
