import XCTest

@MainActor
final class PackDetailUITests: StickerGeniOSUITestCase {
    /// A pack you created stays editable once it exists — the whole point of the editor is that
    /// publishing is not a one-way door, so the screen has to be reachable from the pack itself.
    @MainActor
    func testOwnedPackIsEditableFromItsDetailScreen() {
        app.tabBars.buttons["Sticker Packs"].tap()
        XCTAssertTrue(app.navigationBars["Sticker Packs"].waitForExistence(timeout: 15))

        element("create-pack-button").tap()
        let title = element("pack-title-field")
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        title.tap()
        title.typeText("Editable pack")

        element("pack-choose-stickers-button").tap()
        let pick = element("pack-pick-sticker-demo")
        XCTAssertTrue(pick.waitForExistence(timeout: 15))
        pick.tap()
        element("sticker-picker-done-button").tap()
        // The picker dismisses with an animation, so the draft button is not on screen the instant
        // Done is tapped. `element` is a `firstMatch` query and does not wait, so tapping it
        // straight away is a race that only loses on a loaded machine.
        let draft = element("pack-create-draft-button")
        XCTAssertTrue(draft.waitForExistence(timeout: 15))
        draft.tap()

        // The demo sticker has no WhatsApp or Telegram copy, so creating the pack pushes the
        // conversion screen before anything else. There is no back button and no swipe-down: the
        // fixture has no artwork to encode, so the run fails fast, says so beside the sticker, and
        // offers Done — which is what lands on the pack.
        let preparation = element("messenger-preparation-sheet")
        XCTAssertTrue(preparation.waitForExistence(timeout: 15))
        XCTAssertTrue(element("messenger-preparation-sticker-sticker-demo").waitForExistence(timeout: 15))
        XCTAssertTrue(app.navigationBars["Preparing stickers"].exists)
        let done = element("messenger-preparation-done")
        XCTAssertTrue(done.waitForExistence(timeout: 15))
        XCTAssertTrue(element("messenger-preparation-incomplete").exists)
        done.tap()

        // The sheet closes straight onto the pack it made: the messenger buttons live there, and
        // sending the new pack somewhere is the next thing to do with it.
        let edit = element("pack-edit-button")
        XCTAssertTrue(edit.waitForExistence(timeout: 15))
        XCTAssertTrue(element("pack-messenger-whatsapp").exists)
        XCTAssertTrue(element("pack-messenger-telegram").exists)
        XCTAssertTrue(app.navigationBars["Editable pack"].exists)
        // The creator is told the pack still cannot be sent, and where to fix that.
        XCTAssertTrue(element("pack-messenger-unprepared").exists)
        XCTAssertTrue(edit.waitForExistence(timeout: 15))
        edit.tap()

        let editorTitle = element("pack-editor-title-field")
        XCTAssertTrue(editorTitle.waitForExistence(timeout: 15))
        XCTAssertEqual(editorTitle.value as? String, "Editable pack")
        XCTAssertTrue(element("pack-editor-publish-button").exists)
        XCTAssertTrue(element("pack-editor-member-sticker-demo").exists)
        // The member is still unprepared, so the editor offers to prepare it without an edit.
        XCTAssertTrue(element("pack-editor-prepare-button").exists)
        // Scoped to buttons: an unscoped descendants query resolves the toolbar item's container
        // first, and a container reports itself enabled whatever the button inside it says.
        let save = app.buttons["pack-editor-save-button"]
        // Nothing has been touched yet, so there is nothing to send.
        XCTAssertTrue(save.waitForExistence(timeout: 15))
        XCTAssertFalse(save.isEnabled)

        let summary = element("pack-editor-summary-field")
        summary.tap()
        summary.typeText("Edited after it was created")
        XCTAssertTrue(save.isEnabled)
        save.tap()

        // Saving a pack with an unprepared member goes through the conversion screen again, and
        // Done there is what closes the editor.
        XCTAssertTrue(element("messenger-preparation-sheet").waitForExistence(timeout: 15))
        let preparationDone = element("messenger-preparation-done")
        XCTAssertTrue(preparationDone.waitForExistence(timeout: 15))
        preparationDone.tap()

        // The editor is gone, and the detail screen behind it shows the edit rather than the copy
        // it was opened with.
        XCTAssertTrue(app.staticTexts["Edited after it was created"].waitForExistence(timeout: 15))
        XCTAssertFalse(element("pack-editor-title-field").exists)
    }

    /// The pack screen offers both messengers, and the export sheet explains how the pack will be
    /// cut and what to expect. It starts fetching the prepared files by itself — there is no button
    /// to press first. Neither messenger is installed on a simulator, so the sheet says so and
    /// keeps its send buttons disabled rather than opening nothing.
    @MainActor
    func testPackDetailOffersMessengerExport() {
        app.tabBars.buttons["Sticker Packs"].tap()
        XCTAssertTrue(app.navigationBars["Sticker Packs"].waitForExistence(timeout: 15))
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "marketplace-pack-"))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()

        let whatsapp = element("pack-messenger-whatsapp")
        XCTAssertTrue(whatsapp.waitForExistence(timeout: 15))
        XCTAssertTrue(element("pack-messenger-telegram").exists)

        // Telegram: a single sticker is a valid set, so the fixture pack becomes one part.
        element("pack-messenger-telegram").tap()
        XCTAssertTrue(element("messenger-export-sheet").waitForExistence(timeout: 15))
        XCTAssertTrue(app.navigationBars["Add to Telegram"].exists)
        XCTAssertTrue(element("messenger-not-installed").waitForExistence(timeout: 15))
        let telegramPart = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "messenger-part-"))
            .firstMatch
        XCTAssertTrue(telegramPart.waitForExistence(timeout: 15))
        XCTAssertTrue(element("messenger-emoji-sticker-borrowed").waitForExistence(timeout: 15))
        XCTAssertFalse(element("messenger-export-start").exists)
        // The fixture's rendition is served locally, so the part is sendable — barring the app.
        let send = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "messenger-send-"))
            .firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 15))
        XCTAssertFalse(send.isEnabled)
        element("messenger-export-close").tap()

        // WhatsApp: one sticker is under its minimum of three, so nothing can be sent and the
        // sticker is listed with the reason.
        whatsapp.tap()
        XCTAssertTrue(app.navigationBars["Add to WhatsApp"].waitForExistence(timeout: 15))
        XCTAssertTrue(element("messenger-skipped-sticker-borrowed").waitForExistence(timeout: 15))
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "messenger-send-"))
            .firstMatch.exists)
        element("messenger-export-close").tap()
        XCTAssertTrue(whatsapp.waitForExistence(timeout: 15))
    }
}
