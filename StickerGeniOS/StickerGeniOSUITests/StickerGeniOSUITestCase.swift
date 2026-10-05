import XCTest

/// Shared setup and helpers for the Sticker Factory app's UI suites.
///
/// The suites are split by subject rather than kept in one class because XCTest distributes parallel
/// UI testing per *class*, not per test: a single class runs on a single simulator clone however many
/// workers are available, so one big class sets the floor on the job's wall-clock.
@MainActor
class StickerGeniOSUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // `StickerGeniOSUITestsLaunchTests` runs once per target application UI configuration and
        // leaves its clone in landscape, which whichever suite XCTest schedules next on that clone
        // then inherits. Sideways, the keyboard takes most of the window and a form's lower rows
        // are never laid out at all, so the run fails on a button that is genuinely absent from the
        // hierarchy with nothing on the failure to say the device was the reason.
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reduce-motion",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 15))
        // Rotation is asynchronous and the app can come up before it has settled, so this waits
        // rather than asserts — and it fails here, on the orientation itself, rather than leaving
        // a landscape run to fail somewhere further on that reads as a missing element.
        let launched: XCUIApplication = app
        let portrait = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in launched.frame.height > launched.frame.width },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [portrait], timeout: 10), .completed,
                       "The suite runs portrait; landscape hides the lower half of every form")
    }

    func enterCreationIdea() {
        let prompt = element("sticker-prompt")
        XCTAssertTrue(focusTextField(prompt, in: app), app.debugDescription)
        prompt.typeText("A friendly cat")
        element("creation-next").tap()
    }

    /// Walks from the type page to the overview, picking the one required preset on the way.
    ///
    /// Driven by what is on screen rather than by a tap count. The number of pages in between is
    /// not fixed — the preset catalog decides how many preset pages there are, it is still loading
    /// when this runs, and references and animation add their own — so counting taps made this
    /// helper fail whenever a step was added or the catalog resolved at a different moment.
    func finishCreationChoices() {
        let style = element("preset-option-style-bold-cartoon")
        let generate = element("generate-sticker-button")
        advance(until: style)
        XCTAssertTrue(style.waitForExistence(timeout: 15), app.debugDescription)
        style.tap()
        advance(until: generate)
        XCTAssertTrue(generate.waitForExistence(timeout: 15), app.debugDescription)
    }

    /// Taps Next until `target` appears, leaving the wizard alone once it has.
    ///
    /// Subclasses that stop somewhere short of the overview — on the animation page, on references —
    /// drive themselves with this for the same reason `finishCreationChoices` does: the pages
    /// between the presets and the end are not a fixed count.
    func advance(until target: XCUIElement, limit: Int = 6) {
        for _ in 0..<limit {
            if target.waitForExistence(timeout: 2) { return }
            let next = element("creation-next")
            guard next.exists, next.isHittable else { continue }
            next.tap()
        }
    }

    func openCreateSheet() {
        let create = element("create-sticker-button")
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        create.tap()
        XCTAssertTrue(app.navigationBars["Create"].waitForExistence(timeout: 15))
        XCTAssertTrue(element("dismiss-create-button").exists)
    }

    /// A flick from `swipeDown()` does not reliably travel far enough to trigger `.refreshable`;
    /// a held drag past the threshold does.
    func pullToRefresh(_ scroll: XCUIElement) {
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0.3)
    }

    /// Pulls until the refresh takes, and reports whether it did.
    ///
    /// The single-shot version above is enough on an idle machine. On a CI clone sharing a host
    /// with three other simulators the synthesized drag is stretched over seconds and can be
    /// spent scrolling rather than refreshing, which arrives as "the new row never appeared"
    /// however long the wait after it. Only use this where pulling again is harmless.
    func pullToRefresh(_ scroll: XCUIElement, until confirmation: XCUIElement,
                       timeout: TimeInterval = 8, attempts: Int = 3) -> Bool {
        for _ in 0..<attempts {
            if confirmation.exists { return true }
            pullToRefresh(scroll)
            if confirmation.waitForExistence(timeout: timeout) { return true }
        }
        return confirmation.exists
    }

    /// Taps until the tap takes, and reports whether it did.
    ///
    /// Controls are in the hierarchy before the transition that brings them in has finished, and a
    /// tap sent in that window is swallowed leaving no trace: the run continues on the screen it
    /// was already on and fails steps later somewhere that reads as an unrelated missing element.
    /// `confirmation` is whatever the tap is supposed to put on screen, so the tap is retried
    /// against its own result. The tap must be one that is harmless to repeat.
    func tap(_ target: XCUIElement, until confirmation: XCUIElement,
             timeout: TimeInterval = 5, attempts: Int = 3) -> Bool {
        for _ in 0..<attempts {
            if confirmation.exists { return true }
            target.tap()
            if confirmation.waitForExistence(timeout: timeout) { return true }
        }
        return confirmation.exists
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// A button inside an open `Menu`. iOS 27 drops the identifiers of menu items, keeping only
    /// their labels, so this matches either.
    func menuItem(_ identifier: String, label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", identifier, label)).firstMatch
    }
}

@MainActor
extension XCTestCase {
    /// Focuses a text field, and reports whether the field took the focus.
    ///
    /// A sheet still animating in already has its field in the hierarchy, so a tap sent in that
    /// window lands on a view that is moving and is swallowed. Nothing fails there: the run reaches
    /// `typeText` and fails on "Neither element nor any descendant has keyboard focus", which reads
    /// as a broken field rather than as the tap that never took. The frame is therefore waited out
    /// until it stops moving, and the tap is retried against the keyboard it is supposed to raise.
    func focusTextField(_ field: XCUIElement, in app: XCUIApplication,
                        attempts: Int = 3, settleSamples: Int = 10) -> Bool {
        guard field.waitForExistence(timeout: 15) else { return false }
        var previous = field.frame
        for _ in 0..<settleSamples {
            pause(0.2)
            let current = field.frame
            if current == previous && field.isHittable { break }
            previous = current
        }
        for _ in 0..<attempts {
            if field.hasFocus { return true }
            field.tap()
            // `hasFocus` is the direct answer; a raised keyboard is accepted alongside it so this
            // can only wait where the old single tap already typed.
            if app.keyboards.firstMatch.waitForExistence(timeout: 5) || field.hasFocus { return true }
        }
        return field.hasFocus
    }

    /// Lets the UI run for `interval` without blocking the runner's main thread.
    func pause(_ interval: TimeInterval) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "pause")], timeout: interval)
    }
}
