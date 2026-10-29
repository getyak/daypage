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
    XCTAssertTrue(visibleText(text).waitForExistence(timeout: 5))
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
    XCTAssertTrue(element("ai-base-url").waitForExistence(timeout: 5))
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
    XCTAssertTrue(element("ai-base-url").waitForExistence(timeout: 5))
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
      if element("ai-base-url").exists { break }
      app.swipeUp()
    }
    XCTAssertTrue(element("ai-base-url").waitForExistence(timeout: 5))
  }

  func testDarkArchive() {
    app.launchArguments += ["-qaSeedNotebook", "-local.appearance", "dark"]
    app.launch()
    XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 10))
    screenshot("local-archive-dark")
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
