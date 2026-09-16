import XCTest

@MainActor
final class TutorialNativeReaderTests: XCTestCase {
    private var app: XCUIApplication!
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func launch(locale: String = "en", route: String = "stickerfactory://tutorial", large: Bool = false, reduceMotion: Bool = true) {
        app?.terminate(); app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--ui-tutorial-capture",
            "-AppleLanguages", "(\(locale))",
            "-AppleLocale", locale.replacingOccurrences(of: "-", with: "_")
        ]
        if reduceMotion { app.launchArguments += ["--reduce-motion"] }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["TUTORIAL_BASE_URL"] = "http://127.0.0.1:3117"
        app.launchEnvironment["TUTORIAL_DEEP_LINK"] = route
        app.launch()
    }
    private func tap(_ id: String) {
        let target = element(id)
        for _ in 0..<10 where !target.isHittable { app.swipeUp() }
        XCTAssertTrue(target.isHittable, id)
        target.tap()
    }
    private func top() { for _ in 0..<5 { app.swipeDown() } }
    /// The primary button pages through a long step before it offers the forward action.
    private func advance() {
        for _ in 0..<20 where element("tutorial-scroll-down").exists { element("tutorial-scroll-down").tap() }
        tap("tutorial-next")
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testRefreshedReferenceScreenshotsLoadInEveryLanguage() {
        let captions = ["en": "Add references if they help", "zh-CN": "按需添加参考图片", "zh-HK": "按需要加入參考圖片"]
        for locale in ["en", "zh-CN", "zh-HK"] {
            launch(locale: locale, route: "stickerfactory://tutorial/static?step=references")
            XCTAssertTrue(element("tutorial-step-title").waitForExistence(timeout: 15))
            let screenshot = app.images[captions[locale]!]
            for _ in 0..<8 where !screenshot.isHittable { app.swipeUp() }
            XCTAssertTrue(screenshot.waitForExistence(timeout: 15))
            XCTAssertTrue(screenshot.isHittable)
            XCTAssertFalse(element("tutorial-play-demo").exists)
            capture("refreshed-reference-\(locale)")
        }
    }
    func testEveryChapterInThreeLanguagesUsesNativeViews() {
        for locale in ["en", "zh-CN", "zh-HK"] {
            launch(locale: locale)
            XCTAssertTrue(element("tutorial-chapter-static").waitForExistence(timeout: 15))
            XCTAssertEqual(app.webViews.count, 0)
            capture("native-index-\(locale)")
            for chapter in ["static", "animated", "controllable", "finish", "packs", "new-pack", "whatsapp", "telegram"] {
                tap("tutorial-chapter-\(chapter)")
                XCTAssertTrue(element("tutorial-step-title").waitForExistence(timeout: 15))
                capture("native-\(locale)-\(chapter)")
                XCTAssertFalse(element("tutorial-play-demo").exists)
                element("tutorial-index").tap()
            }
        }
    }
    func testLargeTextProgressAndExplicitClose() {
        launch(route: "stickerfactory://tutorial/static?step=describe", large: true)
        XCTAssertTrue(element("tutorial-step-title").waitForExistence(timeout: 15))
        XCTAssertEqual(element("tutorial-step-title").label, "Describe your idea")
        capture("native-large-text")
        advance()
        advance()
        advance()
        XCTAssertTrue(element("tutorial-completion-banner").exists)
        XCTAssertTrue(element("tutorial-next-chapter").exists)
        XCTAssertFalse(element("tutorial-next").exists)
        XCTAssertTrue(element("tutorial-completion-banner").waitForNonExistence(timeout: 15))
        element("tutorial-close").tap()
        XCTAssertFalse(element("tutorial-sheet").exists)
        launch()
        XCTAssertTrue(element("tutorial-continue").waitForExistence(timeout: 15))
        tap("tutorial-continue")
        XCTAssertEqual(element("tutorial-step-title").label, "Review, build and accept")
    }
    func testLanguageDropdownKeepsTheCurrentStep() {
        launch(route: "stickerfactory://tutorial/static?step=describe")
        XCTAssertTrue(element("tutorial-step-title").waitForExistence(timeout: 15))
        element("tutorial-language").tap()
        for language in ["English", "简体中文", "繁體中文"] { XCTAssertTrue(app.buttons[language].waitForExistence(timeout: 15)) }
        XCTAssertTrue(element("tutorial-sheet").exists)
        XCTAssertTrue(element("tutorial-language-dropdown").exists)
        XCTAssertFalse(element("tutorial-chapter-static").exists)
        // Re-selecting the current language closes only the menu and leaves the reader untouched.
        app.buttons["English"].tap()
        XCTAssertEqual(element("tutorial-step-title").label, "Describe your idea")
        element("tutorial-language").tap()
        app.buttons["繁體中文"].tap()
        XCTAssertTrue(element("tutorial-step-title").waitForExistence(timeout: 15))
        XCTAssertEqual(element("tutorial-step-title").label, "描述你的想法")
        element("tutorial-language").tap()
        app.buttons["English"].tap()
        XCTAssertTrue(element("tutorial-step-title").waitForExistence(timeout: 15))
        XCTAssertEqual(element("tutorial-step-title").label, "Describe your idea")
    }
    func testInvalidChapterShowsRetryAndClose() {
        launch(route: "stickerfactory://tutorial/missing?step=bad")
        XCTAssertTrue(element("tutorial-retry").waitForExistence(timeout: 15))
        XCTAssertTrue(element("tutorial-close").isHittable)
    }
    func testNativeScreenshotAccessibility() throws {
        launch(route: "stickerfactory://tutorial/controllable?step=controls", reduceMotion: false)
        XCTAssertTrue(element("tutorial-step-title").waitForExistence(timeout: 15))
        let screenshot = app.images["Try the controls"]
        for _ in 0..<8 where !screenshot.isHittable { app.swipeUp() }
        XCTAssertTrue(screenshot.waitForExistence(timeout: 15))
        XCTAssertFalse(element("tutorial-play-demo").exists)
        capture("native-controls-screenshot")
        // Native labels, focus order and text must survive VoiceOver and larger content sizes.
        try app.performAccessibilityAudit(for: [.elementDetection, .trait, .textClipped])
    }
}
