import XCTest

final class LocalNotebookUITests: XCTestCase {
  private let app = XCUIApplication()
  override func setUp() {
    continueAfterFailure = false
    app.launchArguments = [
      "-qaNotebookSession", "-qaResetNotebook", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ]
  }
  private func element(_ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }
  private func visibleText(_ value: String) -> XCUIElement {
    app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", value))
      .firstMatch
  }
  private func write(_ text: String) {
    XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 10))
    app.buttons["new-note"].tap()
    let editor = app.textViews["note-editor"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.tap()
    editor.typeText(text)
    app.buttons["save-note"].tap()
    // The collapsed card's AX label can be truncated along with its six-line
    // visual preview. Verify the visible opening before testing full reading.
    XCTAssertTrue(visibleText(String(text.prefix(120))).waitForExistence(timeout: 5))
  }
  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testOfflineWritingSurvivesRelaunchAndCanBeEdited() {
    app.launch()
    write("A small thought saved entirely on this device.")
    app.terminate()
    app.launchArguments.removeAll { $0 == "-qaResetNotebook" }
    app.launch()
    XCTAssertTrue(
      visibleText("A small thought saved entirely on this device.").waitForExistence(timeout: 10))
    let note = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'note-'")).firstMatch
    XCTAssertTrue(note.waitForExistence(timeout: 5))
    note.tap()
    XCTAssertTrue(element("note-original").waitForExistence(timeout: 5))
    app.buttons["edit-note"].tap()
    let editor = app.textViews["note-editor"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.tap()
    editor.typeText(" A later detail.")
    app.buttons["save-note"].tap()
    XCTAssertTrue(visibleText("A later detail.").waitForExistence(timeout: 5))
    screenshot("local-note-detail")
  }

  func testSidebarHasExactlyThreeDestinationsAndSettingsNeedsNoAccount() {
    app.launchArguments += ["-qaSeedNotebook"]
    app.launch()
    XCTAssertTrue(app.buttons["open-sidebar"].waitForExistence(timeout: 10))
    app.buttons["open-sidebar"].tap()
    XCTAssertTrue(app.buttons["sidebar-archive"].waitForExistence(timeout: 5))
    XCTAssertEqual(
      app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar-'")).count, 3)
    screenshot("local-sidebar")
    app.buttons["sidebar-settings"].tap()
    XCTAssertTrue(element("ai-provider").waitForExistence(timeout: 5))
    XCTAssertTrue(app.secureTextFields["ai-key"].exists)
    XCTAssertFalse(app.buttons["Sign in"].exists)
    screenshot("local-ai-settings")
    app.buttons["open-sidebar"].tap()
    app.buttons["sidebar-feedback"].tap()
    XCTAssertTrue(element("feedback-draft").waitForExistence(timeout: 5))
  }

  func testUnconfiguredChatMakesConfigurationExplicit() {
    app.launchArguments += ["-qaSeedNotebook"]
    app.launch()
    XCTAssertTrue(app.buttons["chat-with-notes"].waitForExistence(timeout: 10))
    app.buttons["chat-with-notes"].tap()
    XCTAssertTrue(app.buttons["chat-setup-ai"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["send-chat"].isEnabled)
    app.buttons["chat-setup-ai"].tap()
    XCTAssertTrue(element("ai-provider").waitForExistence(timeout: 5))
    screenshot("local-chat-configuration")
  }

  func testLargeTextSidebarKeepsSettingsReachable() {
    app.launchArguments += [
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
      "-qaSeedNotebook",
    ]
    app.launch()
    XCTAssertTrue(app.buttons["open-sidebar"].waitForExistence(timeout: 10))
    app.buttons["open-sidebar"].tap()
    let settings = app.buttons["sidebar-settings"]
    for _ in 0..<4 {
      if settings.isHittable { break }
      element("notebook-sidebar").swipeUp()
    }
    XCTAssertTrue(settings.isHittable)
    screenshot("local-sidebar-accessibility")
    settings.tap()
    for _ in 0..<4 {
      if element("ai-provider").exists { break }
      app.swipeUp()
    }
    XCTAssertTrue(element("ai-provider").waitForExistence(timeout: 5))
  }

  func testDarkArchive() {
    app.launchArguments += ["-qaSeedNotebook", "-local.appearance", "dark"]
    app.launch()
    if !app.buttons["new-note"].waitForExistence(timeout: 3) { print("ROOT ACCESSIBILITY:\n" + app.debugDescription) }
    XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 10))
    app.buttons["open-sidebar"].tap()
    app.buttons["sidebar-archive"].tap()
    XCTAssertTrue(element("archive-summary").waitForExistence(timeout: 5))
    screenshot("local-archive-dark")
  }

  func testCaptureDraftAndAttachmentSurviveCollapseAndRelaunch() {
    app.launchArguments += ["-qaSeedCaptureDraft"]
    app.launch()
    XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 10))
    app.buttons["new-note"].tap()
    let editor = app.textViews["note-editor"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.tap()
    editor.typeText("A draft with a local file. #travel")
    XCTAssertTrue(visibleText("Trip checklist.txt").exists)
    screenshot("restored-capture-draft")
    app.buttons["collapse-note"].tap()
    app.terminate()
    app.launchArguments.removeAll { $0 == "-qaResetNotebook" || $0 == "-qaSeedCaptureDraft" }
    app.launch()
    XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 10))
    app.buttons["new-note"].tap()
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    XCTAssertTrue((editor.value as? String)?.contains("A draft with a local file.") == true)
    XCTAssertTrue(visibleText("Trip checklist.txt").exists)
    app.buttons["save-note"].tap()
    XCTAssertTrue(visibleText("A draft with a local file.").waitForExistence(timeout: 8))
    app.terminate()
    app.launch()
    XCTAssertTrue(visibleText("A draft with a local file.").waitForExistence(timeout: 10))
    screenshot("restored-file-note")
  }

  func testPinnedSearchAndRecoverableTrash() {
    app.launch()
    write("A local note worth finding again. #travel")
    let note = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'note-'")).firstMatch
    note.tap()
    app.navigationBars["Note"].buttons["Note actions"].tap()
    app.buttons["pin-note"].tap()
    XCTAssertTrue(visibleText("Pinned").waitForExistence(timeout: 5))
    app.navigationBars.buttons.firstMatch.tap()
    app.buttons["search-notes"].tap()
    let search = app.textFields["archive-search"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText("worth finding")
    app.buttons["filter-pinned"].tap()
    XCTAssertTrue(visibleText("A local note worth finding again.").waitForExistence(timeout: 5))
    screenshot("restored-archive-search")
    let foundNote = element("search-list").buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'note-'")).firstMatch
    foundNote.tap()
    app.navigationBars["Note"].buttons["Note actions"].tap()
    app.buttons["trash-note"].tap()
    app.buttons["Move to Trash"].firstMatch.tap()
    XCTAssertTrue(app.buttons["search-undo-trash"].waitForExistence(timeout: 5))
    app.buttons["search-undo-trash"].tap()
    XCTAssertTrue(visibleText("A local note worth finding again.").waitForExistence(timeout: 5))
    foundNote.tap()
    app.navigationBars["Note"].buttons["Note actions"].tap()
    app.buttons["trash-note"].tap()
    app.buttons["Move to Trash"].firstMatch.tap()
    let returnedToSearch = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: app.buttons["search-undo-trash"])
    XCTAssertEqual(XCTWaiter.wait(for: [returnedToSearch], timeout: 5), .completed)
    let deleted = element("search-list").buttons["recently-deleted"]
    XCTAssertTrue(deleted.waitForExistence(timeout: 5))
    XCTAssertTrue(app.frame.contains(deleted.frame))
    // List's AX row extends past its inset content. Its synthesized safe point
    // can land on that padding/scrollbar; the current center is inside the label.
    deleted.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(app.buttons["restore-note"].waitForExistence(timeout: 5))
    screenshot("restored-recently-deleted")
    app.buttons["restore-note"].tap()
    XCTAssertTrue(visibleText("No deleted notes").waitForExistence(timeout: 5))
    app.buttons["Done"].tap()
    XCTAssertTrue(foundNote.waitForExistence(timeout: 5))
    XCTAssertTrue(foundNote.label.contains("A local note worth finding again."))
  }

  func testRestoredTodayHasCompactHeaderAndPersistentCaptureDockInChinese() {
    app.launchArguments = ["-qaNotebookSession", "-qaResetNotebook", "-qaSeedNotebook",
                           "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
    app.launch()
    XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 10))
    XCTAssertTrue(element("capture-dock").exists)
    XCTAssertTrue(element("today-timeline").exists)
    XCTAssertTrue(visibleText("把规则当作游戏").exists)
    XCTAssertFalse(visibleText("A place for passing thoughts.").exists)
    screenshot("restored-today-zh")
    app.buttons["new-note"].tap()
    XCTAssertTrue(app.textViews["note-editor"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["capture-photo"].exists)
    XCTAssertTrue(app.buttons["capture-file"].exists)
    XCTAssertTrue(app.buttons["capture-voice"].exists)
    screenshot("restored-editor-zh")
  }

  func testFullAttachmentDraftKeepsCaptureSafeAndCanStillBeSaved() {
    app.launchArguments += ["-qaSeedCaptureQuota"]
    app.launch()
    XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["dock-voice"].isEnabled)
    app.buttons["new-note"].tap()
    XCTAssertTrue(app.textViews["note-editor"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["capture-voice"].isEnabled)
    XCTAssertFalse(app.buttons["capture-photo"].isEnabled)
    XCTAssertTrue(app.buttons["save-note"].isEnabled)
    app.buttons["save-note"].tap()
    XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["dock-voice"].isEnabled)
    screenshot("restored-attachment-capacity")
  }

  func testArchiveSelectionOpensExplicitScopedChat() {
    app.launchArguments += ["-qaSeedNotebook"]
    app.launch()
    XCTAssertTrue(app.buttons["search-notes"].waitForExistence(timeout: 10))
    app.buttons["search-notes"].tap()
    app.buttons["select-notes"].tap()
    let selections = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'select-note-'"))
    XCTAssertGreaterThanOrEqual(selections.count, 2)
    selections.element(boundBy: 0).tap()
    selections.element(boundBy: 1).tap()
    screenshot("restored-selection")
    app.buttons["chat-selected-notes"].tap()
    XCTAssertTrue(app.buttons["chat-setup-ai"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["send-chat"].isEnabled)
  }

  func testDayRolloverTracksTodayAndPreservesChosenHistoricalDay() {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy-MM-dd"
    let today = formatter.string(from: Date())
    let yesterday = formatter.string(from: Calendar.current.date(byAdding: .day, value: -1, to: Date())!)
    app.launchArguments += ["-qaSeedNotebook", "-qaForegroundPreviousDay"]
    app.launch()
    XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.buttons["choose-date"].value as? String, today)
    app.terminate()
    app.launchArguments.removeAll { $0 == "-qaForegroundPreviousDay" }
    app.launchArguments += ["-qaBrowsePreviousDay"]
    app.launch()
    XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.buttons["choose-date"].value as? String, yesterday)
    XCTAssertTrue(visibleText("Walked home without headphones.").exists)
    screenshot("restored-history-on-empty-date")
  }

  func testLongMemoExpandsInPlaceAndCollapsesWithoutLosingCaptureDock() {
    app.launch()
    write(String(repeating: "A paragraph worth keeping and rereading. ", count: 30))
    let note = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'note-'" )).firstMatch
    let expand = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'expand-note-'" )).firstMatch
    XCTAssertTrue(expand.waitForExistence(timeout: 5))
    let height = note.frame.height
    expand.tap()
    XCTAssertGreaterThan(note.frame.height, height + 100)
    XCTAssertTrue(app.buttons["new-note"].isHittable)
    screenshot("restored-inline-expansion")
    for _ in 0..<8 {
      if expand.isHittable { break }
      app.swipeUp()
    }
    XCTAssertTrue(expand.isHittable)
    expand.tap()
    XCTAssertLessThan(note.frame.height, height + 50)
  }

  func testExplicitChatWithIsolatedLoopbackFixtureAndReopenPersistence() async throws {
    let health = URL(string: "http://127.0.0.1:18763/health")!
    var request = URLRequest(url: health)
    request.timeoutInterval = 2
    let data: Data
    do { (data, _) = try await URLSession.shared.data(for: request) } catch {
      throw XCTSkip("Task-owned loopback AI fixture is not running")
    }
    guard String(decoding: data, as: UTF8.self) == "GET-326-local-fixture" else {
      throw XCTSkip("Loopback port is not the task fixture")
    }
    await MainActor.run {
      app.launchArguments += ["-qaSeedNotebook", "-qaEndpoint", "http://127.0.0.1:18763/v1"]
      app.launch()
      XCTAssertTrue(app.buttons["chat-with-notes"].waitForExistence(timeout: 10))
      app.buttons["chat-with-notes"].tap()
      let field = element("chat-question")
      XCTAssertTrue(field.waitForExistence(timeout: 5))
      field.tap()
      field.typeText("What did I write?")
      app.buttons["send-chat"].tap()
      XCTAssertTrue(visibleText("Fixture reply").waitForExistence(timeout: 15))
      screenshot("local-note-chat")
      app.buttons["Close"].firstMatch.tap()
      app.buttons["chat-with-notes"].tap()
      XCTAssertTrue(visibleText("Fixture reply").waitForExistence(timeout: 5))
      let reopened = element("chat-question")
      reopened.tap()
      reopened.typeText("Keep this second question too.")
      app.buttons["send-chat"].tap()
      XCTAssertTrue(visibleText("Keep this second question too.").waitForExistence(timeout: 10))
      app.terminate()
      app.launchArguments.removeAll { $0 == "-qaResetNotebook" }
      app.launch()
      XCTAssertTrue(app.buttons["chat-with-notes"].waitForExistence(timeout: 10))
      app.buttons["chat-with-notes"].tap()
      XCTAssertTrue(visibleText("Keep this second question too.").waitForExistence(timeout: 10))
    }
  }
}
