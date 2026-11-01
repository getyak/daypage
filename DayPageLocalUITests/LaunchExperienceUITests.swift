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
    XCTAssertTrue(app.buttons["ai-provider"].waitForExistence(timeout: 5))
    let keyIssue = app.staticTexts["ai-key-read-issue"]
    if keyIssue.exists {
      // Unsigned Simulator runs exercise the real denied-Keychain path. The
      // signed QA run covers successful storage in the separate key tests.
      XCTAssertFalse(app.alerts.firstMatch.exists)
      let key = app.secureTextFields["ai-key"]
      key.tap()
      key.typeText("get351-unpersisted-error-draft\n")
      let draft = key.value as? String
      app.buttons["ai-key-retry"].tap()
      XCTAssertTrue(keyIssue.exists)
      XCTAssertEqual(key.value as? String, draft)
      XCTAssertTrue(app.buttons["ai-provider"].exists)
      capture("ai-key-unavailable-inline")
    }
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
    reveal(menu)
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

  func testProviderSetupNeedsOnlyChoicesAndKeepsKeyDraftsSeparate() {
    app.launch()
    openSettings()
    XCTAssertTrue(app.buttons["ai-provider"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.textFields["ai-base-url"].exists)
    XCTAssertTrue(app.buttons["ai-model-picker"].label.contains("Automatic"))
    app.buttons["ai-provider"].tap()
    app.buttons["ai-provider-deepSeek"].tap()
    let key = app.secureTextFields["ai-key"]
    clear(key)
    app.buttons["ai-provider"].tap()
    app.buttons["ai-provider-openAI"].tap()
    clear(key)
    key.typeText("get351-not-a-real-key")
    app.buttons["ai-provider"].tap()
    app.buttons["ai-provider-deepSeek"].tap()
    XCTAssertEqual(key.value as? String, "API key", "A different service must not inherit the typed key")
    XCTAssertTrue(app.buttons["ai-model-picker"].label.contains("Automatic"))
    app.buttons["ai-provider"].tap()
    app.buttons["ai-provider-openAI"].tap()
    XCTAssertNotEqual(key.value as? String, "API key", "Switching back retains the unsaved local key draft")
    capture("ai-provider-first-en")
    app.buttons["ai-model-picker"].tap()
    XCTAssertTrue(app.buttons["ai-model-auto"].waitForExistence(timeout: 5))
    capture("ai-model-choice-en")
  }

  func testCustomModelDiscoveryAndSaveSurviveReopening() throws {
    let url = try XCTUnwrap(URL(string: "http://127.0.0.1:18763/health"))
    guard let data = try? Data(contentsOf: url), String(decoding: data, as: UTF8.self) == "GET-326-local-fixture" else {
      throw XCTSkip("Task-owned loopback AI fixture is not running")
    }
    app.launchArguments += ["-qaEndpoint", "http://127.0.0.1:18763/v1"]
    app.launch()
    openSettings()
    XCTAssertTrue(app.textFields["ai-base-url"].waitForExistence(timeout: 5))
    app.buttons["ai-model-picker"].tap()
    app.buttons["ai-refresh-models"].tap()
    XCTAssertTrue(app.buttons["ai-choice-fixture-alternative"].waitForExistence(timeout: 10))
    app.buttons["ai-choice-fixture-model"].tap()
    let save = app.buttons["save-ai-connection"]
    reveal(save)
    save.tap()
    XCTAssertTrue(save.label.contains("saved"))
    let test = app.buttons["test-ai-connection"]
    reveal(test)
    test.tap()
    XCTAssertTrue(app.staticTexts["ai-resolved-model"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.staticTexts["ai-resolved-model"].label, "fixture-model")
    capture("ai-custom-connected")
    app.terminate()
    app.launchArguments.removeAll { $0 == "-qaResetNotebook" }
    // Remove the debug override to prove saved preferences supply the connection.
    if let index = app.launchArguments.firstIndex(of: "-qaEndpoint") {
      app.launchArguments.removeSubrange(index...index + 1)
    }
    app.launch()
    openSettings()
    XCTAssertTrue(app.buttons["ai-model-picker"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["ai-model-picker"].label.contains("fixture-model"))
    XCTAssertEqual(app.textFields["ai-base-url"].value as? String, "http://127.0.0.1:18763/v1")
  }

  func testCardHeaderContainsFullDateAndMenuAboveTheReadingSurface() {
    app.launch()
    let note = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'note-'")).firstMatch
    XCTAssertTrue(note.waitForExistence(timeout: 10))
    let timestamp = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'card-timestamp-'")).firstMatch
    let menu = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'card-actions-'")).firstMatch
    XCTAssertTrue(timestamp.exists)
    XCTAssertTrue(timestamp.label.contains(String(Calendar.current.component(.year, from: Date()))))
    XCTAssertLessThan(timestamp.frame.minY, note.frame.minY)
    XCTAssertLessThan(menu.frame.minY, note.frame.minY)
    XCTAssertGreaterThan(menu.frame.minX, timestamp.frame.minX)
    XCTAssertGreaterThanOrEqual(menu.frame.height, 44)
    XCTAssertGreaterThanOrEqual(note.frame.height, 44)
    XCTAssertFalse(app.staticTexts["Recent notes"].exists)
    capture("quiet-cards-today")
    note.tap()
    XCTAssertTrue(app.staticTexts["note-original"].waitForExistence(timeout: 5))
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertTrue(app.buttons["choose-date"].waitForExistence(timeout: 5))
  }

  func testDiscoveryFailureKeepsTheCustomConnection() throws {
    let url = try XCTUnwrap(URL(string: "http://127.0.0.1:18763/health"))
    guard let data = try? Data(contentsOf: url), String(decoding: data, as: UTF8.self) == "GET-326-local-fixture" else {
      throw XCTSkip("Task-owned loopback AI fixture is not running")
    }
    app.launchArguments += ["-qaEndpoint", "http://127.0.0.1:18763/unavailable/v1"]
    app.launch()
    openSettings()
    XCTAssertTrue(app.buttons["ai-model-picker"].waitForExistence(timeout: 5))
    app.buttons["ai-model-picker"].tap()
    app.buttons["ai-refresh-models"].tap()
    let status = app.staticTexts["ai-model-status"]
    XCTAssertTrue(status.waitForExistence(timeout: 10))
    XCTAssertTrue(status.label.contains("404"))
    XCTAssertTrue(app.buttons["ai-choice-fixture-model"].exists)
    capture("ai-discovery-failure")
    app.buttons["Done"].tap()
    XCTAssertEqual(app.textFields["ai-base-url"].value as? String, "http://127.0.0.1:18763/unavailable/v1")
    XCTAssertTrue(app.buttons["ai-model-picker"].label.contains("fixture-model"))
  }

  func testScrollingSettingsDoesNotCancelAConnectionTest() throws {
    let url = try XCTUnwrap(URL(string: "http://127.0.0.1:18763/health"))
    guard let data = try? Data(contentsOf: url), String(decoding: data, as: UTF8.self) == "GET-326-local-fixture" else {
      throw XCTSkip("Task-owned loopback AI fixture is not running")
    }
    app.launchArguments += ["-qaEndpoint", "http://127.0.0.1:18763/slow/v1"]
    app.launch()
    openSettings()
    let test = app.buttons["test-ai-connection"]
    reveal(test)
    test.tap()
    app.swipeUp()
    app.swipeDown()
    let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: test)
    XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 15), .completed)
    reveal(app.staticTexts["ai-resolved-model"])
    XCTAssertTrue(app.staticTexts["ai-resolved-model"].waitForExistence(timeout: 15))
    XCTAssertEqual(app.staticTexts["ai-resolved-model"].label, "fixture-model")
  }

  func testChineseCardHeaderAtLargeTextInDarkMode() {
    app.launchArguments = ["-qaNotebookSession", "-qaResetNotebook", "-qaSeedNotebook",
      "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-local.appearance", "dark",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    app.launch()
    let timestamp = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'card-timestamp-'")).firstMatch
    XCTAssertTrue(timestamp.waitForExistence(timeout: 10))
    XCTAssertTrue(timestamp.label.contains("年"))
    XCTAssertTrue(timestamp.label.contains("月"))
    XCTAssertTrue(timestamp.label.contains("日"))
    let menu = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'card-actions-'")).firstMatch
    XCTAssertTrue(menu.isHittable)
    capture("quiet-cards-zh-dark-accessibility")
    menu.tap()
    XCTAssertTrue(app.buttons["分享记录"].waitForExistence(timeout: 5))
  }

  func testChineseAIChoicesAndFixedGLMDefaultAreClear() {
    app.launchArguments = ["-qaNotebookSession", "-qaResetNotebook", "-qaSeedNotebook",
      "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-local.appearance", "light"]
    app.launch()
    openSettings()
    XCTAssertTrue(app.buttons["ai-provider"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["ai-model-picker"].label.contains("自动"))
    capture("ai-settings-zh")
    app.buttons["ai-provider"].tap()
    XCTAssertTrue(app.buttons["ai-provider-qwen"].label.contains("通义千问"))
    capture("ai-providers-zh")
    app.buttons["ai-provider-qwen"].tap()
    XCTAssertTrue(app.buttons["ai-model-picker"].label.contains("自动"))
    app.buttons["ai-provider"].tap()
    app.buttons["ai-provider-glm"].tap()
    XCTAssertTrue(app.buttons["ai-model-picker"].label.contains("glm-5.3"))
    app.buttons["ai-model-picker"].tap()
    XCTAssertTrue(app.buttons["ai-choice-glm-5.3"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["ai-model-auto"].exists)
    XCTAssertFalse(app.buttons["ai-refresh-models"].exists)
  }

  private func openSettings() {
    XCTAssertTrue(app.buttons["open-sidebar"].waitForExistence(timeout: 10))
    app.buttons["open-sidebar"].tap()
    app.buttons["sidebar-settings"].tap()
  }

  func testClearedCustomKeyDoesNotReturnAfterSwitchingServices() {
    let serviceA = "https://get351-a.invalid/v1"
    let serviceB = "https://get351-b.invalid/v1"
    app.launchArguments += ["-qaEndpoint", serviceA]
    app.launch()
    openSettings()
    let key = app.secureTextFields["ai-key"]
    XCTAssertTrue(key.waitForExistence(timeout: 5))
    clear(key)
    key.typeText("get351-disposable-fixture-key\n")
    saveConnection()

    setCustomAddress(serviceB)
    XCTAssertEqual(key.value as? String, "API key")
    saveConnection()

    setCustomAddress(serviceA)
    XCTAssertNotEqual(key.value as? String, "API key")
    clear(key)
    key.typeText("\n")
    saveConnection()
    app.terminate()
    app.launchArguments.removeAll { $0 == "-qaResetNotebook" }
    if let index = app.launchArguments.firstIndex(of: "-qaEndpoint") {
      app.launchArguments.removeSubrange(index...index + 1)
    }
    app.launch()
    openSettings()
    XCTAssertTrue(key.waitForExistence(timeout: 5))
    XCTAssertEqual(key.value as? String, "API key", "Explicitly cleared service credentials must stay removed")
    XCTAssertEqual(app.textFields["ai-base-url"].value as? String, serviceA)
    // A fresh draft at B forces an actual Keychain read for A, rather than
    // merely trusting A's saved anonymous preference or its in-memory cache.
    app.terminate()
    app.launchArguments += ["-qaEndpoint", serviceB]
    app.launch()
    openSettings()
    setCustomAddress(serviceA)
    XCTAssertEqual(key.value as? String, "API key")
    XCTAssertFalse(app.staticTexts["ai-key-read-issue"].exists, "A failed read must not look like a deleted key")
  }

  func testSavedAnonymousIntentDoesNotReloadAHistoricalKey() {
    let serviceA = "https://get351-anonymous.invalid/v1"
    let serviceB = "https://get351-anonymous-other.invalid/v1"
    app.launchArguments += ["-qaEndpoint", serviceA]
    app.launch()
    openSettings()
    let key = app.secureTextFields["ai-key"]
    XCTAssertTrue(key.waitForExistence(timeout: 5))
    key.tap()
    key.typeText("get351-disposable-legacy-key\n")
    saveConnection()
    app.terminate()
    app.launchArguments.removeAll { $0 == "-qaResetNotebook" }
    // The existing QA endpoint override supplies usesAPIKey=false without
    // deleting the stored key: this reproduces an older anonymous preference.
    app.launch()
    openSettings()
    XCTAssertTrue(key.waitForExistence(timeout: 5))
    XCTAssertEqual(key.value as? String, "API key")
    saveConnection()
    app.terminate()
    if let index = app.launchArguments.firstIndex(of: "-qaEndpoint") {
      app.launchArguments[index + 1] = serviceB
    }
    app.launch()
    openSettings()
    setCustomAddress(serviceA)
    XCTAssertEqual(key.value as? String, "API key", "Saving anonymous must remove the historical stored key too")
    XCTAssertFalse(app.staticTexts["ai-key-read-issue"].exists, "The empty value must come from a successful Keychain read")
  }

  func testExistingProviderURLKeepsItsCorrectRegion() {
    app.launchArguments += ["-qaEndpoint", "https://DASHSCOPE-INTL.aliyuncs.com:443/compatible-mode/v1/"]
    app.launch()
    openSettings()
    let region = app.descendants(matching: .any).matching(identifier: "ai-region").firstMatch
    XCTAssertTrue(region.waitForExistence(timeout: 5))
    XCTAssertTrue(region.label.contains("Singapore") || (region.value as? String)?.contains("Singapore") == true)
    XCTAssertTrue(app.buttons["ai-model-picker"].label.contains("fixture-model"))
  }

  private func saveConnection() {
    let save = app.buttons["save-ai-connection"]
    reveal(save)
    XCTAssertTrue(save.isEnabled)
    save.tap()
    XCTAssertTrue(save.label.contains("saved"))
  }

  private func setCustomAddress(_ address: String) {
    let field = app.textFields["ai-base-url"]
    for _ in 0..<6 {
      if field.isHittable { break }
      app.swipeDown()
    }
    field.tap()
    let value = field.value as? String ?? ""
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count) + address)
    app.textFields["ai-model"].tap()
    app.textFields["ai-model"].typeText("\n")
  }

  private func reveal(_ element: XCUIElement) {
    for _ in 0..<5 {
      if element.isHittable { return }
      app.swipeUp()
    }
  }

  private func clear(_ field: XCUIElement) {
    field.tap()
    let value = field.value as? String ?? ""
    if value != "API key" { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count)) }
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
