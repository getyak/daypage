import XCTest

final class CardShareUITests: XCTestCase {
  private let app = XCUIApplication()

  override func setUp() {
    continueAfterFailure = false
    app.launchArguments = [
      "-qaNotebookSession", "-qaResetNotebook", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ]
  }

  private var note: XCUIElement {
    app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'note-'")).firstMatch
  }

  private var cardMenu: XCUIElement {
    app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'card-actions-'")).firstMatch
  }

  private func element(_ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  private func closeSystemShare() {
    let close = app.buttons["header.closeButton"]
    XCTAssertTrue(close.waitForExistence(timeout: 5))
    XCTAssertTrue(app.frame.contains(close.frame))
    // The iOS remote share container reports its visible button as non-hittable.
    // Tap the current, identifier-resolved frame and verify actual dismissal.
    close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: app.buttons["share-export"])
    XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed)
  }

  private func write(_ body: String) {
    XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 10))
    app.buttons["new-note"].tap()
    let editor = app.textViews["note-editor"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.tap()
    editor.typeText(body)
    app.buttons["save-note"].tap()
    XCTAssertTrue(note.waitForExistence(timeout: 5))
  }

  // Catches leading swipe handlers targeting the wrong note or omitting note-scoped chat.
  func testLeadingSwipePinsAndOpensNoteScopedChat() {
    app.launch()
    write("A thought to pin and discuss.")
    note.swipeRight()
    XCTAssertTrue(app.buttons["swipe-pin-note"].waitForExistence(timeout: 5))
    app.buttons["swipe-pin-note"].tap()
    cardMenu.tap()
    XCTAssertTrue(app.buttons["Unpin note"].waitForExistence(timeout: 5))
    app.buttons["Unpin note"].tap()
    note.swipeRight()
    app.buttons["swipe-chat-note"].tap()
    XCTAssertTrue(app.buttons["chat-setup-ai"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["send-chat"].isEnabled)
  }

  // Catches accidental full-swipe deletion and a Trash action that skips confirmation/recovery.
  func testTrailingSwipeRequiresConfirmationAndKeepsUndo() {
    app.launch()
    write("Keep this note until I confirm Trash.")
    note.swipeLeft(velocity: .fast)
    XCTAssertTrue(note.exists)
    XCTAssertTrue(app.buttons["swipe-trash-note"].waitForExistence(timeout: 5))
    app.buttons["swipe-trash-note"].tap()
    XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
    app.buttons["Cancel"].tap()
    XCTAssertTrue(note.exists)
    note.swipeLeft()
    app.buttons["swipe-trash-note"].tap()
    app.buttons["Move to Trash"].firstMatch.tap()
    XCTAssertTrue(app.buttons["undo-trash"].waitForExistence(timeout: 5))
    app.buttons["undo-trash"].tap()
    XCTAssertTrue(note.waitForExistence(timeout: 5))
  }

  // Catches bypassing the preview and sharing attachments under an image/text label.
  func testCardSharePreviewChangesStyleDateAndFormat() {
    app.launch()
    write("A complete thought for a friend.")
    note.swipeLeft()
    app.buttons["swipe-share-note"].tap()
    XCTAssertTrue(element("note-share-preview").waitForExistence(timeout: 5))
    XCTAssertTrue(element("share-card-preview").exists)
    app.buttons["share-style-ink"].tap()
    app.buttons["share-style-minimal"].tap()
    let date = app.switches["share-show-date"]
    XCTAssertTrue(date.exists)
    date.tap()
    XCTAssertFalse(element("share-preview-date").exists)
    app.buttons["share-format-text"].tap()
    XCTAssertTrue(element("share-complete-text").exists)
    XCTAssertTrue(element("share-attachment-semantics").label.contains("not included"))
    XCTAssertTrue(app.buttons["share-export"].isEnabled)
    app.buttons["share-format-original"].tap()
    XCTAssertTrue(element("share-attachment-semantics").label.contains("No attachments"))
  }

  // Catches a detail action using a separate unreviewable direct-export path.
  func testDetailShareOpensTheSamePreview() {
    app.launch()
    write("The detail and card share the same preview.")
    note.tap()
    app.buttons["Note actions"].tap()
    app.buttons["share-note"].tap()
    XCTAssertTrue(element("note-share-preview").waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["share-style-paper"].exists)
    XCTAssertTrue(app.buttons["share-format-original"].exists)
  }

  // Catches attachment loss when opening the original format and accidental image export of files.
  func testAttachmentOnlyNoteExplainsFormatsBeforeExport() {
    app.launchArguments += ["-qaSeedCaptureDraft"]
    app.launch()
    XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 10))
    app.buttons["new-note"].tap()
    XCTAssertTrue(app.textViews["note-editor"].waitForExistence(timeout: 5))
    app.buttons["save-note"].tap()
    XCTAssertTrue(note.waitForExistence(timeout: 5))
    cardMenu.tap()
    app.buttons["Share note"].tap()
    XCTAssertTrue(element("note-share-preview").waitForExistence(timeout: 5))
    app.buttons["share-format-image"].tap()
    XCTAssertFalse(app.buttons["share-export"].isEnabled)
    XCTAssertTrue(element("share-image-unavailable").exists)
    app.buttons["share-format-original"].tap()
    XCTAssertTrue(app.buttons["share-export"].isEnabled)
    XCTAssertTrue(element("share-original-attachments").exists)
    app.buttons["share-export"].tap()
    let systemShare = app.otherElements["ActivityListView"]
    XCTAssertTrue(systemShare.waitForExistence(timeout: 10), app.debugDescription)
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = "original-attachment-system-share"
    image.lifetime = .keepAlways
    add(image)
    closeSystemShare()
  }

  func testArchiveAndSearchRowsKeepSwipeActionsAndSuppressThemDuringSelection() {
    app.launchArguments += ["-qaSeedNotebook"]
    app.launch()
    XCTAssertTrue(app.buttons["open-sidebar"].waitForExistence(timeout: 10))
    app.buttons["open-sidebar"].tap()
    app.buttons["sidebar-archive"].tap()
    note.swipeRight()
    XCTAssertTrue(app.buttons["swipe-pin-note"].waitForExistence(timeout: 5))
    app.buttons["swipe-pin-note"].tap()
    app.buttons["select-notes"].tap()
    note.swipeLeft()
    XCTAssertFalse(app.buttons["swipe-trash-note"].exists)
    app.buttons["select-notes"].tap()
    app.buttons["search-notes"].tap()
    let search = app.textFields["archive-search"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText("headphones\n")
    let resultCount = app.staticTexts["search-result-count"]
    let filtered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '1 note'"), object: resultCount)
    let keyboardGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
    XCTAssertEqual(XCTWaiter.wait(for: [filtered, keyboardGone], timeout: 5), .completed)
    let results = element("search-list")
    let foundNote = results.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'note-'")).firstMatch
    XCTAssertTrue(foundNote.waitForExistence(timeout: 5))
    XCTAssertTrue(foundNote.label.contains("headphones"))
    let row = results.cells.containing(.button, identifier: foundNote.identifier).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    XCTAssertTrue(row.buttons[foundNote.identifier].exists)
    XCTAssertTrue(results.frame.intersection(app.frame).insetBy(dx: -0.000001, dy: -0.000001).contains(row.frame))
    let geometry = XCTAttachment(string: "cell=\(row.frame)\nreading=\(foundNote.frame)\nlist=\(results.frame)")
    geometry.name = "search-native-row-geometry"; geometry.lifetime = .keepAlways; add(geometry)
    capture("search-before-native-row-swipe")
    let origin = row.coordinate(withNormalizedOffset: .zero)
    origin.withOffset(CGVector(dx: row.frame.width - 24, dy: row.frame.height / 2))
      .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 24, dy: row.frame.height / 2)))
    let share = app.buttons["swipe-share-note"]
    let revealed = share.waitForExistence(timeout: 5)
    capture("search-after-native-row-swipe")
    if !revealed {
      let hierarchy = XCTAttachment(string: app.debugDescription)
      hierarchy.name = "search-native-row-swipe-failure"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }
    XCTAssertTrue(revealed)
    XCTAssertTrue(share.isHittable)
    share.tap()
    XCTAssertTrue(element("note-share-preview").waitForExistence(timeout: 5))
  }

  private func capture(_ name: String) {
    XCTAssertEqual(app.state, .runningForeground)
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = name; image.lifetime = .keepAlways; add(image)
  }

  func testImageActuallyExportsAndSystemShareCancellationReturnsToPreview() {
    app.launchArguments += ["-qaExportShareImage"]
    app.launch()
    write("A quiet thought, shared with care.\n\nKeep the first line upright.\nAnd keep this final line.")
    cardMenu.tap()
    app.buttons["Share note"].tap()
    XCTAssertTrue(app.buttons["share-export"].waitForExistence(timeout: 5))
    app.buttons["share-style-ink"].tap()
    app.buttons["share-export"].tap()
    let systemShare = app.otherElements["ActivityListView"]
    XCTAssertTrue(systemShare.waitForExistence(timeout: 10), app.debugDescription)
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = "rendered-image-system-share"
    image.lifetime = .keepAlways
    add(image)
    closeSystemShare()
  }

  // Catches silent clipping or image export of content past the rendering budget.
  func testLongNoteKeepsItsFinalLineInCompleteText() {
    app.launch()
    write(String(repeating: "Every word remains part of this local note. ", count: 100) + "Final line kept.")
    cardMenu.tap()
    app.buttons["Share note"].tap()
    XCTAssertTrue(element("note-share-preview").waitForExistence(timeout: 5))
    XCTAssertTrue(element("share-complete-text").label.hasSuffix("Final line kept."))
    app.buttons["share-format-image"].tap()
    XCTAssertFalse(app.buttons["share-export"].isEnabled)
    XCTAssertTrue(element("share-image-unavailable").exists)
    app.buttons["share-format-text"].tap()
    XCTAssertTrue(app.buttons["share-export"].isEnabled)
  }
}
