import XCTest

final class LaunchExperienceUITests: XCTestCase {
  private let app = XCUIApplication()
  private var editableAIKeys: XCUIElementQuery {
    // iOS may expose an additional privacy mirror with the same identifier.
    // The editable field keeps its public, localized placeholder.
    app.secureTextFields.matching(identifier: "ai-key")
      .matching(NSPredicate(format: "placeholderValue IN %@", ["API key", "API 密钥"]))
  }
  private var aiKeyField: XCUIElement { editableAIKeys.firstMatch }
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
      let key = aiKeyField
      XCTAssertTrue(key.waitForExistence(timeout: 5))
      XCTAssertEqual(editableAIKeys.count, 1)
      key.tap()
      key.typeText("get351-unpersisted-error-draft\n")
      XCTAssertEqual(app.state, .runningForeground)
      let draft = key.value as? String
      XCTAssertFalse(draft?.isEmpty ?? true)
      XCTAssertNotEqual(draft, "API key")
      app.buttons["ai-key-retry"].tap()
      XCTAssertEqual(app.state, .runningForeground, "Retry must not activate the separate provider link")
      XCTAssertTrue(keyIssue.exists)
      XCTAssertEqual(editableAIKeys.count, 1)
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
    // Creating 360 actual files is fixture preparation, not notebook read
    // latency. Keep the count contract, then verify a fresh read separately.
    let seeded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '360 notes'"), object: summary)
    let seedResult = XCTWaiter.wait(for: [seeded], timeout: 120)
    if seedResult != .completed {
      let state = XCTAttachment(string: "Fixture summary: \(summary.label)\n\(app.debugDescription)")
      state.name = "large-archive-fixture-state"; state.lifetime = .keepAlways; add(state)
    }
    XCTAssertEqual(seedResult, .completed)
    XCTAssertTrue(summary.label.contains("120 days"))
    app.terminate()
    app.launchArguments.removeAll { ["-qaResetNotebook", "-qaSeedNotebook", "-qaSeedLargeNotebook"].contains($0) }
    app.launch()
    XCTAssertTrue(app.buttons["open-sidebar"].waitForExistence(timeout: 10))
    app.buttons["open-sidebar"].tap()
    app.buttons["sidebar-archive"].tap()
    let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '360 notes'"), object: summary)
    let readResult = XCTWaiter.wait(for: [loaded], timeout: 20)
    if readResult != .completed {
      let state = XCTAttachment(string: "Read summary: \(summary.label)\n\(app.debugDescription)")
      state.name = "large-archive-read-state"; state.lifetime = .keepAlways; add(state)
    }
    XCTAssertEqual(readResult, .completed)
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
    XCTAssertEqual(app.state, .runningForeground, "A background app is not valid visual evidence")
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
  }

  func testProviderSetupNeedsOnlyChoicesAndKeepsKeyDraftsSeparate() throws {
    app.launch()
    openSettings()
    XCTAssertTrue(app.buttons["ai-provider"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.textFields["ai-base-url"].exists)
    XCTAssertTrue(app.buttons["ai-model-picker"].label.contains("Automatic"))
    app.buttons["ai-provider"].tap()
    app.buttons["ai-provider-deepSeek"].tap()
    let key = try visibleAIKeyField()
    clear(key)
    app.buttons["ai-provider"].tap()
    app.buttons["ai-provider-openAI"].tap()
    clear(key)
    key.typeText("get351-not-a-real-key")
    app.buttons["ai-provider"].tap()
    app.buttons["ai-provider-deepSeek"].tap()
    XCTAssertTrue(try aiKeySemanticValue().isEmpty, "A different service must not inherit the typed key")
    XCTAssertTrue(app.buttons["ai-model-picker"].label.contains("Automatic"))
    app.buttons["ai-provider"].tap()
    app.buttons["ai-provider-openAI"].tap()
    XCTAssertFalse(try aiKeySemanticValue().isEmpty, "Switching back retains the unsaved local key draft")
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
    try expectResolvedAIModel("fixture-model", timeout: 10)
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
    let restoredAddress = app.textFields["ai-base-url"]
    reveal(restoredAddress)
    XCTAssertEqual(restoredAddress.value as? String, "http://127.0.0.1:18763/v1")
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
    // The Test row may be virtualized after these scrolls. Check the actual
    // completion result in the visible AI section, not an offscreen button.
    try expectResolvedAIModel("fixture-model", timeout: 15)
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

  private enum AIInspectionError: Error { case unavailable }

  private func attachAIInspectionFailure() {
    let state = XCTAttachment(string: "Application state: \(app.state)")
    state.name = "ai-inspection-state"
    state.lifetime = .keepAlways
    add(state)
    guard app.state == .runningForeground else { return }
    let redacted = app.debugDescription.split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.contains("SecureTextField") ? "<SecureTextField redacted>" : String($0) }
      .joined(separator: "\n")
    let hierarchy = XCTAttachment(string: redacted)
    hierarchy.name = "ai-inspection-hierarchy"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "ai-inspection-foreground"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  private func failAIInspection(_ message: String, file: StaticString, line: UInt) throws -> Never {
    attachAIInspectionFailure()
    XCTFail(message, file: file, line: line)
    throw AIInspectionError.unavailable
  }

  private func isInAIViewport(_ element: XCUIElement) -> Bool {
    guard app.state == .runningForeground, element.exists else { return false }
    let frame = element.frame
    return !frame.isEmpty && app.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
  }

  private func showAISettingsOverview(file: StaticString = #filePath, line: UInt = #line) throws {
    guard app.state == .runningForeground else {
      try failAIInspection("AI settings must be inspected in the foreground", file: file, line: line)
    }
    let provider = app.buttons["ai-provider"]
    // Form virtualizes its rows. Rewind to the known AI section rather than
    // waiting for a lower, possibly disabled/offscreen control to reappear.
    for _ in 0..<6 {
      if isInAIViewport(provider) { return }
      app.swipeDown()
    }
    guard isInAIViewport(provider) else {
      try failAIInspection("The AI settings section did not return to the viewport", file: file, line: line)
    }
  }

  private func visibleAIKeyField(file: StaticString = #filePath, line: UInt = #line) throws -> XCUIElement {
    try showAISettingsOverview(file: file, line: line)
    let field = aiKeyField
    guard field.waitForExistence(timeout: 5), editableAIKeys.count == 1,
      isInAIViewport(field), field.isHittable else {
      try failAIInspection("The editable AI key field must exist and be visible", file: file, line: line)
    }
    return field
  }

  private func aiKeySemanticValue(file: StaticString = #filePath, line: UInt = #line) throws -> String {
    let field = try visibleAIKeyField(file: file, line: line)
    guard !app.staticTexts["ai-key-read-issue"].exists else {
      try failAIInspection("An unsuccessful Keychain read cannot establish an empty key", file: file, line: line)
    }
    guard let value = field.value as? String else {
      try failAIInspection("The AI key field must expose a String value", file: file, line: line)
    }
    // Different iOS versions expose an empty SecureField as either an empty
    // value or its exact localized placeholder. Every other value remains
    // nonempty, including masked credential text; nil never becomes empty.
    return ["API key", "API 密钥"].contains(value) ? "" : value
  }

  private func expectResolvedAIModel(_ expected: String, timeout: TimeInterval,
    file: StaticString = #filePath, line: UInt = #line) throws {
    try showAISettingsOverview(file: file, line: line)
    // Runner logs resolve this identifier to the checkmark Image first.
    // Require actual model text, retaining exact identity and model value.
    let resolved = app.staticTexts.matching(identifier: "ai-resolved-model")
      .matching(NSPredicate(format: "label == %@", expected)).firstMatch
    let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      self.isInAIViewport(resolved) && resolved.label == expected
    }, object: nil)
    guard XCTWaiter.wait(for: [completed], timeout: timeout) == .completed else {
      try failAIInspection("The visible resolved AI model did not equal \(expected)", file: file, line: line)
    }
    XCTAssertEqual(app.state, .runningForeground, file: file, line: line)
    XCTAssertEqual(resolved.label, expected, file: file, line: line)
  }

  func testClearedCustomKeyDoesNotReturnAfterSwitchingServices() throws {
    let serviceA = "https://get351-a.invalid/v1"
    let serviceB = "https://get351-b.invalid/v1"
    app.launchArguments += ["-qaEndpoint", serviceA]
    app.launch()
    openSettings()
    let key = try visibleAIKeyField()
    clear(key)
    key.typeText("get351-disposable-fixture-key\n")
    saveConnection()

    setCustomAddress(serviceB)
    XCTAssertTrue(try aiKeySemanticValue().isEmpty)
    saveConnection()

    setCustomAddress(serviceA)
    XCTAssertFalse(try aiKeySemanticValue().isEmpty)
    let restoredKey = try visibleAIKeyField()
    clear(restoredKey)
    restoredKey.typeText("\n")
    saveConnection()
    app.terminate()
    app.launchArguments.removeAll { $0 == "-qaResetNotebook" }
    if let index = app.launchArguments.firstIndex(of: "-qaEndpoint") {
      app.launchArguments.removeSubrange(index...index + 1)
    }
    app.launch()
    openSettings()
    XCTAssertTrue(try aiKeySemanticValue().isEmpty, "Explicitly cleared service credentials must stay removed")
    let restoredAddress = app.textFields["ai-base-url"]
    reveal(restoredAddress)
    XCTAssertEqual(restoredAddress.value as? String, serviceA)
    // A fresh draft at B forces an actual Keychain read for A, rather than
    // merely trusting A's saved anonymous preference or its in-memory cache.
    app.terminate()
    app.launchArguments += ["-qaEndpoint", serviceB]
    app.launch()
    openSettings()
    setCustomAddress(serviceA)
    XCTAssertTrue(try aiKeySemanticValue().isEmpty)
    XCTAssertFalse(app.staticTexts["ai-key-read-issue"].exists, "A failed read must not look like a deleted key")
  }

  func testSavedAnonymousIntentDoesNotReloadAHistoricalKey() throws {
    let serviceA = "https://get351-anonymous.invalid/v1"
    let serviceB = "https://get351-anonymous-other.invalid/v1"
    app.launchArguments += ["-qaEndpoint", serviceA]
    app.launch()
    openSettings()
    let key = try visibleAIKeyField()
    key.tap()
    key.typeText("get351-disposable-legacy-key\n")
    saveConnection()
    app.terminate()
    app.launchArguments.removeAll { $0 == "-qaResetNotebook" }
    // The existing QA endpoint override supplies usesAPIKey=false without
    // deleting the stored key: this reproduces an older anonymous preference.
    app.launch()
    openSettings()
    XCTAssertTrue(try aiKeySemanticValue().isEmpty)
    saveConnection()
    app.terminate()
    if let index = app.launchArguments.firstIndex(of: "-qaEndpoint") {
      app.launchArguments[index + 1] = serviceB
    }
    app.launch()
    openSettings()
    setCustomAddress(serviceA)
    XCTAssertTrue(try aiKeySemanticValue().isEmpty, "Saving anonymous must remove the historical stored key too")
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

  func testProviderWithoutARequiredKeyOffersSetupBeforeSending() {
    app.launchArguments += ["-qaEndpoint", "https://api.openai.com/v1"]
    app.launch()
    XCTAssertTrue(app.buttons["chat-with-notes"].waitForExistence(timeout: 10))
    app.buttons["chat-with-notes"].tap()
    XCTAssertTrue(app.buttons["chat-setup-ai"].waitForExistence(timeout: 5))
    let question = app.textFields["chat-question"]
    question.tap()
    question.typeText("Reflect on these notes")
    XCTAssertFalse(app.buttons["send-chat"].isEnabled)
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
    let previous = field.value as? String
    // iPhone selects a paragraph with a one-finger triple tap. This URL field
    // contains one paragraph; use its native selection instead of a key shortcut.
    field.tap(withNumberOfTaps: 3, numberOfTouches: 1)
    field.typeText(XCUIKeyboardKey.delete.rawValue)
    let cleared = field.value as? String
    XCTAssertTrue(cleared == "" || cleared == "https://your-provider.example/v1",
      "The custom address must be empty before entering its replacement; synthetic URL before=\(String(reflecting: previous)), after=\(String(reflecting: cleared))")
    field.typeText(address)
    XCTAssertEqual(field.value as? String, address, "The entire custom address must be replaced")
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
    let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS 'A new thought stays visible'")).firstMatch
    XCTAssertTrue(saved.waitForExistence(timeout: 5))
    let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: saved)
    XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
  }
}
