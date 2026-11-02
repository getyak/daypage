import XCTest

final class ChatExperienceUITests: XCTestCase {
  private let app = XCUIApplication()
  override func setUp() {
    continueAfterFailure = false
    app.launchArguments = ["-qaNotebookSession", "-qaResetNotebook", "-qaSeedNotebook", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
  }
  private func openChat() {
    XCTAssertTrue(app.buttons["chat-with-notes"].waitForExistence(timeout: 10))
    app.buttons["chat-with-notes"].tap()
    XCTAssertTrue(app.textFields["chat-question"].waitForExistence(timeout: 5))
  }
  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
  }
  private func text(_ value: String) -> XCUIElement {
    app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
  }
  func testModelsHaveTheirOwnPageAndChatDraftSurvivesIt() {
    app.launch(); openChat()
    let question = app.textFields["chat-question"]
    question.tap(); question.typeText("A question to keep")
    app.buttons["chat-ai-settings"].tap()
    XCTAssertTrue(app.buttons["ai-provider"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["import-vault"].exists)
    capture("chat-dedicated-model-page")
    app.buttons["Done"].tap()
    XCTAssertEqual(question.value as? String, "A question to keep")
    capture("chat-compact-composer")
  }
  func testNewConversationKeepsOldDraftInHistoryAfterRelaunch() {
    app.launch(); openChat()
    let question = app.textFields["chat-question"]
    question.tap(); question.typeText("An older conversation draft")
    app.buttons["chat-new"].tap()
    XCTAssertTrue(app.staticTexts["A little room to think."].waitForExistence(timeout: 5))
    app.buttons["chat-history"].tap()
    let older = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chat-history-' AND label CONTAINS 'An older conversation draft'")).firstMatch
    XCTAssertTrue(older.waitForExistence(timeout: 5)); older.tap()
    XCTAssertEqual(question.value as? String, "An older conversation draft")
    app.buttons["Close"].firstMatch.tap()
    app.terminate(); app.launchArguments.removeAll { $0 == "-qaResetNotebook" }; app.launch(); openChat()
    XCTAssertEqual(app.textFields["chat-question"].value as? String, "An older conversation draft")
    app.buttons["chat-history"].tap(); capture("chat-saved-history")
  }
  func testCharacterCreationAndRotationSurviveReopen() {
    app.launch(); openChat()
    app.buttons["chat-characters"].tap()
    app.buttons["chat-new-character"].tap()
    let name = app.textFields["character-name"]
    XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Moss")
    app.textFields["character-role"].tap(); app.textFields["character-role"].typeText("Thoughtful editor")
    let soul = app.textViews["character-soul"]
    soul.tap(); soul.typeText("Be candid, kind and concrete.")
    app.buttons["character-save"].tap()
    let rotation = app.switches["chat-rotate"]
    XCTAssertTrue(rotation.waitForExistence(timeout: 5))
    // The native AX switch includes its label; its center is outside the thumb.
    rotation.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    XCTAssertEqual(rotation.value as? String, "1")
    let moss = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chat-character-' AND label CONTAINS 'Moss'")).firstMatch
    XCTAssertTrue(moss.waitForExistence(timeout: 5)); moss.tap()
    capture("chat-character-library")
    app.buttons["chat-use-characters"].tap()
    app.buttons["chat-characters"].tap()
    XCTAssertEqual(app.switches["chat-rotate"].value as? String, "1")
    XCTAssertTrue(moss.exists)
    app.buttons["Done"].tap()
    app.buttons["Close"].firstMatch.tap(); openChat()
    app.buttons["chat-characters"].tap()
    XCTAssertEqual(app.switches["chat-rotate"].value as? String, "1")
    XCTAssertTrue(moss.exists)
  }
  func testStreamingMarkdownReasoningAndSavedHistory() throws {
    guard let data = try? Data(contentsOf: URL(string: "http://127.0.0.1:18763/health")!),
      String(decoding: data, as: UTF8.self) == "GET-326-local-fixture"
    else { throw XCTSkip("Task-owned loopback fixture is not running") }
    app.launchArguments += ["-qaEndpoint", "http://127.0.0.1:18763/v1"]
    app.launch(); openChat()
    app.textFields["chat-question"].tap(); app.textFields["chat-question"].typeText("Reflect on my notes")
    app.buttons["send-chat"].tap()
    XCTAssertTrue(text("Fixture reply").waitForExistence(timeout: 15))
    XCTAssertTrue(text("A small reflection").waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["send-chat"].waitForExistence(timeout: 10))
    let transcript = app.scrollViews["chat-transcript"]
    let reasoning = app.buttons.matching(NSPredicate(format: "identifier == 'chat-reasoning' OR label == 'Thinking'")).firstMatch
    for _ in 0..<4 {
      if reasoning.exists && reasoning.isHittable { break }
      transcript.swipeDown()
    }
    XCTAssertTrue(reasoning.waitForExistence(timeout: 5))
    XCTAssertGreaterThanOrEqual(reasoning.frame.height, 44)
    reasoning.tap()
    XCTAssertTrue(text("I will use only the supplied excerpts.").waitForExistence(timeout: 5))
    capture("chat-streamed-markdown")
    app.buttons["chat-new"].tap(); app.buttons["chat-history"].tap()
    let older = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chat-history-' AND label CONTAINS 'Reflect on my notes'")).firstMatch
    XCTAssertTrue(older.waitForExistence(timeout: 5)); older.tap()
    XCTAssertTrue(text("Fixture reply").waitForExistence(timeout: 5))
  }
  func testLargeTypeKeepsComposerAndCharacterControlsReachable() {
    app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    app.launch(); openChat()
    XCTAssertTrue(app.textFields["chat-question"].isHittable)
    XCTAssertGreaterThanOrEqual(app.buttons["chat-characters"].frame.height, 44)
    XCTAssertGreaterThanOrEqual(app.buttons["chat-ai-settings"].frame.height, 44)
    XCTAssertTrue(app.staticTexts["A little room to think."].isHittable,
      "An empty conversation must begin at its greeting, rather than the last suggestion.")
    capture("chat-accessibility-size")
  }
}
