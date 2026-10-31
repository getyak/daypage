import XCTest

final class LaunchExperienceUITests: XCTestCase {
  private let app = XCUIApplication()
  override func setUp() {
    continueAfterFailure = false
    app.launchArguments = ["-qaNotebookSession", "-qaResetNotebook", "-qaSeedNotebook", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
  }

  func testArchiveIsBrowseAndSearchReturnsToItsOrigin() {
    app.launch()
    XCTAssertTrue(app.buttons["open-sidebar"].waitForExistence(timeout: 10))
    app.buttons["open-sidebar"].tap()
    app.buttons["sidebar-archive"].tap()
    XCTAssertTrue(app.staticTexts["archive-summary"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.textFields["archive-search"].exists)
    XCTAssertTrue(app.buttons["return-today"].isHittable)
    app.buttons["search-notes"].tap()
    XCTAssertTrue(app.textFields["archive-search"].waitForExistence(timeout: 5))
    app.textFields["archive-search"].tap()
    app.textFields["archive-search"].typeText("headphones")
    XCTAssertTrue(app.staticTexts["search-result-count"].waitForExistence(timeout: 5))
    app.buttons["close-search"].tap()
    XCTAssertTrue(app.staticTexts["archive-summary"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["search-result-count"].exists, "Closing search must restore unfiltered Archive browsing")
    app.buttons["return-today"].tap()
    XCTAssertTrue(app.buttons["choose-date"].waitForExistence(timeout: 5))
    app.buttons["search-notes"].tap()
    app.buttons["close-search"].tap()
    XCTAssertTrue(app.buttons["choose-date"].waitForExistence(timeout: 5))
  }

  func testNoSearchMatchesHasClearRecovery() {
    app.launch()
    XCTAssertTrue(app.buttons["search-notes"].waitForExistence(timeout: 10))
    app.buttons["search-notes"].tap()
    app.textFields["archive-search"].tap()
    app.textFields["archive-search"].typeText("this-never-matches")
    XCTAssertTrue(app.buttons["reset-archive-filters"].waitForExistence(timeout: 5))
    app.buttons["reset-archive-filters"].tap()
    XCTAssertEqual(app.textFields["archive-search"].value as? String, "Search your notes")
    XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'note-'")).firstMatch.waitForExistence(timeout: 5))
  }

  func testAISetupKeepsQuestionAndEmptyNotebookExplainsScope() {
    app.launchArguments.removeAll { $0 == "-qaSeedNotebook" }
    app.launch()
    XCTAssertTrue(app.buttons["chat-with-notes"].waitForExistence(timeout: 10))
    app.buttons["chat-with-notes"].tap()
    let question = app.textFields["chat-question"]
    XCTAssertTrue(question.waitForExistence(timeout: 5))
    question.tap()
    question.typeText("Keep this question while I set up AI")
    app.buttons["chat-setup-ai"].tap()
    XCTAssertTrue(app.textFields["ai-base-url"].waitForExistence(timeout: 5))
    app.buttons["Done"].tap()
    XCTAssertEqual(question.value as? String, "Keep this question while I set up AI")
    XCTAssertFalse(app.buttons["send-chat"].isEnabled)
    XCTAssertTrue(app.staticTexts["chat-empty-context"].exists)
  }

  func testSuggestionsOnlyDraftAQuestion() {
    app.launch()
    XCTAssertTrue(app.buttons["chat-with-notes"].waitForExistence(timeout: 10))
    app.buttons["chat-with-notes"].tap()
    XCTAssertTrue(app.buttons["chat-suggestion-0"].waitForExistence(timeout: 5))
    app.buttons["chat-suggestion-0"].tap()
    XCTAssertFalse(app.buttons["send-chat"].isEnabled)
    XCTAssertNotEqual(app.textFields["chat-question"].value as? String, "Ask about your notes…")
    XCTAssertFalse(app.otherElements["chat-thinking"].exists)
  }

  func testLargeArchiveFindsOlderNotesWithoutLeakingItsSearchFilter() {
    app.launchArguments += ["-qaSeedLargeNotebook"]
    app.launch()
    XCTAssertTrue(app.buttons["open-sidebar"].waitForExistence(timeout: 30))
    app.buttons["open-sidebar"].tap()
    app.buttons["sidebar-archive"].tap()
    let summary = app.staticTexts["archive-summary"]
    XCTAssertTrue(summary.waitForExistence(timeout: 20))
    let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '360 notes'"), object: summary)
    XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 30), .completed)
    XCTAssertTrue(summary.label.contains("120 days"))
    app.swipeUp()
    app.swipeUp()
    app.buttons["search-notes"].tap()
    let search = app.textFields["archive-search"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText("history 359.\n")
    XCTAssertEqual(app.staticTexts["search-result-count"].label, "1 note")
    let searchList = app.descendants(matching: .any).matching(identifier: "search-list").firstMatch
    let note = searchList.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'note-'")).firstMatch
    XCTAssertTrue(note.waitForExistence(timeout: 5))
    note.tap()
    XCTAssertTrue(app.staticTexts["note-original"].waitForExistence(timeout: 5))
    app.navigationBars.buttons.firstMatch.tap()
    app.buttons["close-search"].tap()
    XCTAssertFalse(app.staticTexts["search-result-count"].exists)
  }

  func testChineseArchiveCalendarAndShareUseTheSameDesignLanguage() {
    app.launchArguments = ["-qaNotebookSession", "-qaResetNotebook", "-qaSeedNotebook", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
    app.launch()
    XCTAssertTrue(app.buttons["open-sidebar"].waitForExistence(timeout: 10))
    app.buttons["open-sidebar"].tap()
    app.buttons["sidebar-archive"].tap()
    XCTAssertTrue(app.staticTexts["回头看看。"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["翻阅记录"].exists)
    capture("launch-archive-zh")
    app.buttons["archive-calendar"].tap()
    XCTAssertTrue(app.buttons["calendar-done"].waitForExistence(timeout: 5))
    capture("launch-calendar-zh")
    app.buttons["calendar-done"].tap()
    let menu = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'card-actions-'")).firstMatch
    XCTAssertTrue(menu.waitForExistence(timeout: 5))
    app.swipeUp()
    XCTAssertTrue(menu.isHittable)
    menu.tap()
    XCTAssertTrue(app.buttons["分享记录"].waitForExistence(timeout: 5))
    app.buttons["分享记录"].tap()
    XCTAssertTrue(app.buttons["share-style-paper"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.buttons["share-style-paper"].label, "纸笺")
    capture("launch-share-zh")
  }

  private func capture(_ name: String) {
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
  }

  func testCaptureFromHistoricalDateReturnsToTheSavedNoteToday() throws {
    app.launch()
    let chooser = app.buttons["choose-date"]
    XCTAssertTrue(chooser.waitForExistence(timeout: 10))
    let today = try XCTUnwrap(chooser.value as? String)
    let past = String(today.prefix(8)) + (today.hasSuffix("01") ? "02" : "01")
    chooser.tap()
    app.buttons["calendar-day-" + past].tap()
    app.buttons["calendar-done"].tap()
    XCTAssertEqual(chooser.value as? String, past)
    app.buttons["new-note"].tap()
    let editor = app.textViews["note-editor"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.tap()
    editor.typeText("A new thought stays visible after browsing history.")
    app.buttons["save-note"].tap()
    XCTAssertTrue(chooser.waitForExistence(timeout: 5))
    XCTAssertEqual(chooser.value as? String, today)
    XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'A new thought stays visible'")).firstMatch.exists)
  }
}
