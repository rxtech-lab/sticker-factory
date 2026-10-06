import XCTest

@MainActor
final class PetUITests: StickerGeniOSUITestCase {
    /// Pet is the first tab, even though launch still lands on the Library.
    ///
    /// On iOS 27 the Pet tab takes the `.prominent` role, which the system lifts out of the tab
    /// group into its own slot at the trailing end of the bar, so there it is the last button and
    /// Library leads the rest.
    @MainActor
    func testPetIsTheFirstTab() {
        let tabs = app.tabBars.buttons
        if #available(iOS 27.0, *) {
            XCTAssertEqual(tabs.element(boundBy: 0).label, "Library")
            XCTAssertEqual(tabs.element(boundBy: tabs.count - 1).label, "Pet")
        } else {
            XCTAssertEqual(tabs.element(boundBy: 0).label, "Pet")
            XCTAssertEqual(tabs.element(boundBy: 1).label, "Library")
        }
    }

    /// Adopt from the Pet tab, see it shown, then spend time with it.
    @MainActor
    func testChoosingAPet() {
        app.terminate()
        app.launchArguments.append("--ui-installed-pack")
        app.launch()

        app.tabBars.buttons["Pet"].tap()
        XCTAssertTrue(app.tabBars.buttons["Pet"].isSelected)
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

    /// A friend the pet made on its own is welcomed full screen, with the tab put away, once.
    @MainActor
    func testWelcomingANewFriend() {
        app.terminate()
        app.launchArguments += ["--ui-installed-pack", "--ui-pet-friend"]
        app.launch()

        // The pet is already home, back from making a friend.
        app.tabBars.buttons["Pet"].tap()

        let welcome = element("pet-friend-headline")
        XCTAssertTrue(welcome.waitForExistence(timeout: 15))
        XCTAssertEqual(welcome.label, "Met new friends!")
        XCTAssertTrue(element("pet-friend-pet").exists)
        XCTAssertTrue(element("pet-friend-sticker").label.contains("Puddle"))
        XCTAssertTrue(element("pet-friend-greeting").label.contains("This is Puddle!"))
        // Everything else is put away while the friend is welcomed.
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "pet-friend-welcome"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        element("pet-friend-done").tap()
        XCTAssertTrue(welcome.waitForNonExistence(timeout: 10))
        XCTAssertTrue(element("current-pet").waitForExistence(timeout: 10))
        // Welcomed once: coming back to the tab does not show it again.
        app.tabBars.buttons["Library"].tap()
        app.tabBars.buttons["Pet"].tap()
        XCTAssertFalse(welcome.waitForExistence(timeout: 3))
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
        // Releasing asks first; dismissing the dialog keeps the pet. iOS 26 shows it as a popover
        // with no Cancel button, dismissed by a tap outside.
        let confirm = element("pet-release-confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        let outside = app.otherElements["PopoverDismissRegion"].firstMatch
        if outside.exists { outside.tap() } else { app.buttons["Cancel"].firstMatch.tap() }
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        XCTAssertTrue(element("current-pet").exists)

        element("change-pet-button").tap()
        XCTAssertTrue(release.waitForExistence(timeout: 5))
        release.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(element("choose-pet-button").waitForExistence(timeout: 15))
    }

    /// The Rooms tab lists the shop; a room opens in its own sheet, where buying it asks first, spends
    /// the gold and moves the pet in, drawing the room behind it. Moving out puts it back on the page.
    @MainActor
    func testBuyingARoomMovesThePetIn() {
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
        XCTAssertTrue(element("pet-room-backdrop-plain").exists)
        // The plain page keeps the time in its own chip.
        XCTAssertTrue(element("pet-clock").exists)

        element("pet-stats").swipeUp()
        element("pet-actions-button").tap()
        XCTAssertTrue(app.navigationBars["Spend Time Together"].waitForExistence(timeout: 5))
        app.buttons["Rooms"].firstMatch.tap()

        // The garden costs 90 gold and the pet has 20: it opens, but cannot be bought.
        let garden = element("pet-room-mock-room-garden")
        XCTAssertTrue(garden.waitForExistence(timeout: 15))
        garden.tap()
        XCTAssertTrue(app.navigationBars["Rooftop Garden"].waitForExistence(timeout: 5))
        XCTAssertFalse(element("pet-room-buy").isEnabled)
        app.navigationBars["Rooftop Garden"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Rooftop Garden"].waitForNonExistence(timeout: 5))

        element("pet-room-mock-room-burrow").tap()
        let buy = element("pet-room-buy")
        XCTAssertTrue(buy.waitForExistence(timeout: 5))
        XCTAssertTrue(buy.isEnabled)
        buy.tap()
        let confirm = element("pet-room-purchase-confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        // Bought: the detail closes, and the room is listed as the one the pet lives in.
        XCTAssertTrue(app.navigationBars["Moss Burrow"].waitForNonExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Living here"].waitForExistence(timeout: 5))

        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Spend Time Together"].waitForNonExistence(timeout: 5))
        let spent = NSPredicate(format: "label == %@", "5 gold")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: spent, evaluatedWith: element("pet-gold"))], timeout: 15), .completed)
        XCTAssertTrue(element("pet-room-backdrop").waitForExistence(timeout: 15))
        // The room has a clock and a weather board drawn in; the time and weather move onto them.
        XCTAssertTrue(element("pet-room-clock").waitForExistence(timeout: 15))
        XCTAssertTrue(element("pet-room-weather").exists)
        XCTAssertTrue(element("pet-clock").waitForNonExistence(timeout: 5))
        // So do the stats: the room's status board shows them, in place of the card.
        XCTAssertTrue(element("pet-room-status").waitForExistence(timeout: 5))
        XCTAssertTrue(element("pet-stats").waitForNonExistence(timeout: 5))
        // Still on the board after leaving the tab and coming back.
        app.tabBars.buttons["Library"].tap()
        app.tabBars.buttons["Pet"].tap()
        XCTAssertTrue(element("pet-room-status").waitForExistence(timeout: 5))
        XCTAssertTrue(element("pet-stats").waitForNonExistence(timeout: 5))
        let furnished = XCTAttachment(screenshot: app.screenshot())
        furnished.name = "pet-room-fixtures"
        furnished.lifetime = .keepAlways
        add(furnished)

        element("pet-actions-button").tap()
        app.buttons["Rooms"].firstMatch.tap()
        let burrow = element("pet-room-mock-room-burrow")
        XCTAssertTrue(burrow.waitForExistence(timeout: 15))
        burrow.tap()
        let moveOut = element("pet-room-move-out")
        XCTAssertTrue(moveOut.waitForExistence(timeout: 5))
        moveOut.tap()
        XCTAssertTrue(moveOut.waitForNonExistence(timeout: 15))
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(element("pet-room-backdrop-plain").waitForExistence(timeout: 15))
    }

    /// The Items tab sells medicine to a well pet and keeps food in the bag, each after a native
    /// confirmation; each shows how long it stays and keeps. The dose waits in the bag, and the food
    /// is used from it later without paying again.
    @MainActor
    func testItemShopKeepsMedicineAndFoodInTheBag() {
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
        app.buttons["Store"].firstMatch.tap()

        // The berry pie is food: keep it in the bag rather than using it now.
        let pie = element("pet-item-66666666-6666-4666-8666-666666666666")
        XCTAssertTrue(pie.waitForExistence(timeout: 15))
        XCTAssertTrue(pie.label.contains("Leaves the shop in"))
        XCTAssertTrue(pie.label.contains("Keeps for 10 hours once bought."))
        XCTAssertTrue(element("pet-item-55555555-5555-4555-8555-555555555555").label.contains("Never expires once bought."))
        // Info has its own tap target and reads the full details without buying or using the item.
        element("pet-item-66666666-6666-4666-8666-666666666666-info").tap()
        XCTAssertTrue(app.navigationBars["Item Details"].waitForExistence(timeout: 5))
        XCTAssertEqual(element("pet-item-detail-description").label, "Share a warm berry pie with Loaf.")
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(element("pet-item-detail-leaves").exists)
        XCTAssertTrue(element("pet-item-detail-lifetime").label.contains("10 hours"))
        XCTAssertFalse(app.buttons["Keep in Bag"].firstMatch.exists)
        element("pet-item-detail-done").tap()
        XCTAssertTrue(app.navigationBars["Item Details"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(element("pet-sheet-bag").value as? String, "0")

        // A permanent item also explains that it never expires after purchase.
        element("pet-item-55555555-5555-4555-8555-555555555555-info").tap()
        XCTAssertTrue(app.navigationBars["Item Details"].waitForExistence(timeout: 5))
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(element("pet-item-detail-lifetime").label.contains("Never expires once bought."))
        element("pet-item-detail-done").tap()
        XCTAssertTrue(app.navigationBars["Item Details"].waitForNonExistence(timeout: 5))

        // The tonic is unaffordable, but its info button remains available.
        let tonic = element("pet-item-88888888-8888-4888-8888-888888888888")
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertFalse(tonic.isEnabled)
        element("pet-item-88888888-8888-4888-8888-888888888888-info").tap()
        XCTAssertTrue(app.navigationBars["Item Details"].waitForExistence(timeout: 5))
        XCTAssertEqual(element("pet-item-detail-description").label, "A sparkling tonic that wakes Loaf right up.")
        element("pet-item-detail-done").tap()
        XCTAssertTrue(app.navigationBars["Item Details"].waitForNonExistence(timeout: 5))
        app.scrollViews.firstMatch.swipeDown()

        pie.tap()
        let keep = app.buttons["Keep in Bag"].firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        keep.tap()
        let bag = element("pet-sheet-bag")
        let kept = NSPredicate(format: "value == %@", "1")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: kept, evaluatedWith: bag)], timeout: 15), .completed)
        // Once owned, the sheet also shows the copy's actual expiry date.
        element("pet-item-66666666-6666-4666-8666-666666666666-info").tap()
        XCTAssertTrue(app.navigationBars["Item Details"].waitForExistence(timeout: 5))
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(element("pet-item-detail-expires").exists)
        let details = XCTAttachment(screenshot: app.screenshot())
        details.name = "pet-item-details"
        details.lifetime = .keepAlways
        add(details)
        element("pet-item-detail-done").tap()
        XCTAssertTrue(app.navigationBars["Item Details"].waitForNonExistence(timeout: 5))

        // Medicine is always for sale; a well pet keeps the dose in its bag.
        element("pet-shop-medicine").tap()
        let buy = app.buttons["Buy for 10 Gold"].firstMatch
        XCTAssertTrue(buy.waitForExistence(timeout: 5))
        buy.tap()
        // The bag button counts the pie and the dose; the bag opens in a sheet of its own.
        let both = NSPredicate(format: "value == %@", "2")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: both, evaluatedWith: bag)], timeout: 15), .completed)
        bag.tap()
        XCTAssertTrue(app.navigationBars["Bag"].waitForExistence(timeout: 5))
        let dose = element("pet-bag-medicine")
        XCTAssertTrue(dose.waitForExistence(timeout: 15))
        XCTAssertFalse(dose.isEnabled)
        let bagPie = element("pet-bag-item-66666666-6666-4666-8666-666666666666")
        XCTAssertTrue(bagPie.waitForExistence(timeout: 15))
        XCTAssertTrue(bagPie.label.contains("Expires in"))

        // Using the pie from the bag closes the sheet; the pet answers, and no more gold is spent.
        bagPie.tap()
        XCTAssertTrue(app.navigationBars["Spend Time Together"].waitForNonExistence(timeout: 15))
        let reply = NSPredicate(format: "label CONTAINS %@", "Share a warm berry pie with Loaf.")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: reply, evaluatedWith: element("pet-dialogue"))], timeout: 15), .completed)
        XCTAssertEqual(element("pet-gold").label, "2 gold")
    }

    /// A health update gets one brief appearance; revisiting the tab keeps it dismissed, while
    /// buying another dose shows the new medicine count.
    @MainActor
    func testHealthCardDismissesAndStaysDismissedWhenReturningToPet() {
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

        func buyMedicine() {
            element("pet-actions-button").tap()
            XCTAssertTrue(app.navigationBars["Spend Time Together"].waitForExistence(timeout: 5))
            app.buttons["Store"].firstMatch.tap()
            let medicine = element("pet-shop-medicine")
            XCTAssertTrue(medicine.waitForExistence(timeout: 15))
            medicine.tap()
            let buy = app.buttons["Buy for 10 Gold"].firstMatch
            XCTAssertTrue(buy.waitForExistence(timeout: 5))
            buy.tap()
            XCTAssertTrue(buy.waitForNonExistence(timeout: 15))
            app.buttons["Done"].firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Spend Time Together"].waitForNonExistence(timeout: 5))
        }

        buyMedicine()
        let health = element("pet-health")
        XCTAssertTrue(health.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 medicine"].exists)
        XCTAssertTrue(health.waitForNonExistence(timeout: 35))

        app.tabBars.buttons["Library"].tap()
        app.tabBars.buttons["Pet"].tap()
        XCTAssertTrue(element("current-pet").waitForExistence(timeout: 5))
        XCTAssertFalse(health.waitForExistence(timeout: 3), "Returning must not replay the same health update")

        buyMedicine()
        XCTAssertTrue(health.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["2 medicine"].exists)
    }

    /// The microphone beside the pet opens the talk sheet, which starts listening on its own. With
    /// nothing said yet there is nothing to send, and Cancel closes it.
    @MainActor
    func testTalkingToThePetOpensTheTalkPopover() {
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

        element("pet-stats").swipeUp()
        let talk = element("pet-talk-button")
        XCTAssertTrue(talk.waitForExistence(timeout: 5))
        talk.tap()
        let popover = element("pet-talk-popover")
        XCTAssertTrue(popover.waitForExistence(timeout: 5))

        // Tapping the mic asks for the microphone the first time.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        // A simulator without the speech model for its language says so; that is fine here.
        let ok = app.alerts.buttons["OK"]
        if ok.waitForExistence(timeout: 3) { ok.tap() }

        // Listening, the popover's close button drops what was heard; without the speech model the
        // popover has already gone.
        let close = element("pet-talk-cancel")
        if close.waitForExistence(timeout: 3) { close.tap() }
        XCTAssertTrue(popover.waitForNonExistence(timeout: 5))
        XCTAssertTrue(talk.isEnabled)
    }
}
