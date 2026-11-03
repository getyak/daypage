import XCTest

/// Acceptance journeys use the isolated QA notebook and task-owned synthetic HTTP/audio fixture.
final class CardToolsSpeechUITests: XCTestCase {
  private let app = XCUIApplication()
  private let fixture = "http://127.0.0.1:18763"
  private let notebookOpening = "A good notebook leaves room for unfinished thoughts."

  override func setUpWithError() throws {
    continueAfterFailure = false
    app.launchArguments = [
      "-qaNotebookSession", "-qaResetNotebook", "-qaSeedNotebook",
      "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-qaEndpoint", fixture + "/v1",
    ]
    let url = try XCTUnwrap(URL(string: fixture + "/health"))
    let response = expectation(description: "Task-owned fixture is healthy")
    URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 3)) { data, reply, error in
      XCTAssertNil(error, "Start scripts/qa/local_notebook_ai_fixture.py before this suite")
      XCTAssertEqual((reply as? HTTPURLResponse)?.statusCode, 200)
      XCTAssertEqual(data.map { String(decoding: $0, as: UTF8.self) }, "GET-326-local-fixture")
      response.fulfill()
    }.resume()
    wait(for: [response], timeout: 5)
  }

  override func tearDown() {
    app.terminate()
    super.tearDown()
  }

  private func element(_ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  private func text(_ value: String) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
  }

  private func button(prefix: String) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
  }

  private var form: XCUIElement {
    // The notebook's today-timeline remains in AX below the modal sheet. A
    // global firstMatch selects that hidden list rather than the speech Form.
    let speech = element("speech-settings-form")
    if speech.exists { return speech }
    return element("today-timeline")
  }

  private func captureLookupFailure(_ target: XCUIElement, scroller: XCUIElement) {
    let targetExists = target.exists
    let scrollExists = scroller.exists
    let targetID = targetExists ? target.identifier : "unresolved-target"
    let scrollID = scrollExists ? scroller.identifier : "unresolved-scroller"
    let targetFrame = targetExists ? target.frame.debugDescription : "absent"
    let scrollFrame = scrollExists ? scroller.frame.debugDescription : "absent"
    capture("lookup-failed-" + targetID)
    let hierarchy = XCTAttachment(string: app.debugDescription
      .replacingOccurrences(of: "fixture-speech-key", with: "<synthetic credential redacted>"))
    hierarchy.name = "lookup-failed-accessibility-tree"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    let frames = XCTAttachment(string:
      "target=\(targetID) exists=\(targetExists) frame=\(targetFrame)\n"
        + "scroller=\(scrollID) exists=\(scrollExists) frame=\(scrollFrame)")
    frames.name = "lookup-failed-target-and-scroller"
    frames.lifetime = .keepAlways
    add(frames)
  }

  private func reveal(_ target: XCUIElement, in scroller: XCUIElement? = nil, down: Bool = false) {
    let scroll = scroller ?? form
    guard scroll.exists else {
      captureLookupFailure(target, scroller: scroll)
      XCTFail("The owning scroll container must exist before revealing the target")
      return
    }
    for _ in 0..<8 {
      if target.exists && target.isHittable { return }
      scrollVisibleContent(scroll, toward: target, down: down)
    }
    captureLookupFailure(target, scroller: scroll)
    guard target.exists else {
      XCTFail("The expected control is absent; see the saved accessibility tree")
      return
    }
    XCTAssertTrue(target.isHittable, "Control must be reachable: \(target.identifier)")
  }

  private func scrollVisibleContent(_ scroller: XCUIElement, toward target: XCUIElement, down: Bool) {
    let frame = scroller.frame.intersection(app.frame)
    var top = frame.minY
    var bottom = frame.maxY
    for bar in app.navigationBars.allElementsBoundByIndex where bar.isHittable {
      top = max(top, bar.frame.maxY)
    }
    let keyboard = app.keyboards.firstMatch
    if keyboard.exists {
      // The native Form keeps its full-screen AX frame while the keyboard covers
      // its lower half. The AX Keyboard starts at the keys; reserve its rounded
      // top too. Full-container swipeUp previously began inside this keyboard.
      bottom = min(bottom, keyboard.frame.minY - 24)
    }
    guard bottom - top >= 80 else {
      captureLookupFailure(target, scroller: scroller)
      XCTFail("The scroll container needs an unobscured gesture area")
      return
    }
    var moveDown = down
    if target.exists {
      if target.frame.maxY <= top { moveDown = true }
      else if target.frame.minY >= bottom { moveDown = false }
    }
    let low = top + (bottom - top) * 0.75
    let high = top + (bottom - top) * 0.25
    let origin = scroller.coordinate(withNormalizedOffset: .zero)
    let start = origin.withOffset(CGVector(dx: frame.midX - scroller.frame.minX,
      dy: (moveDown ? high : low) - scroller.frame.minY))
    let end = origin.withOffset(CGVector(dx: frame.midX - scroller.frame.minX,
      dy: (moveDown ? low : high) - scroller.frame.minY))
    start.press(forDuration: 0.05, thenDragTo: end)
  }

  private func tap44(_ target: XCUIElement) {
    XCTAssertTrue(target.waitForExistence(timeout: 5))
    XCTAssertTrue(target.isHittable)
    XCTAssertGreaterThanOrEqual(target.frame.height, 44)
    target.tap()
  }

  private func setSwitch(_ id: String, on: Bool) {
    let control = app.switches[id]
    XCTAssertTrue(control.waitForExistence(timeout: 5))
    if (control.value as? String == "1") != on {
      XCTAssertTrue(control.isHittable)
      // UIKit exposes the native switch's 28pt intrinsic AX footprint even when
      // SwiftUI gives its row a 44pt activation area. Keep geometry assertions
      // distinct from the 44pt custom buttons and verify the semantic change.
      XCTAssertGreaterThanOrEqual(control.frame.width, 44)
      XCTAssertGreaterThanOrEqual(control.frame.height, 28)
      control.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    }
    let updated = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", on ? "1" : "0"), object: control)
    XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 5), .completed)
  }

  private func openChat() {
    XCTAssertTrue(app.buttons["chat-with-notes"].waitForExistence(timeout: 10))
    app.buttons["chat-with-notes"].tap()
    XCTAssertTrue(app.textFields["chat-question"].waitForExistence(timeout: 5))
  }

  private func openContext() {
    if !app.switches["chat-note-tools"].exists { tap44(app.buttons["chat-context"]) }
    XCTAssertTrue(app.switches["chat-note-tools"].waitForExistence(timeout: 5))
  }

  private func send(_ question: String) {
    let input = app.textFields["chat-question"]
    input.tap()
    input.typeText(question)
    tap44(app.buttons["send-chat"])
  }

  private func relaunch() {
    app.terminate()
    app.launchArguments.removeAll { $0 == "-qaResetNotebook" || $0 == "-qaSeedCaptureDraft" }
    app.launch()
  }

  private func capture(_ name: String) {
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
  }

  func testCardToolsOpenTheOriginalAndSavedReplySurvivesRelaunchWithoutConsumingCaptureDraft() {
    app.launchArguments += ["-qaSeedCaptureDraft"]
    app.launch()
    XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 10))
    app.buttons["new-note"].tap()
    let editor = app.textViews["note-editor"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.tap()
    editor.typeText("Keep this capture draft while saving a reply.")
    app.buttons["collapse-note"].tap()
    openChat()
    openContext()
    XCTAssertEqual(app.switches["chat-note-tools"].value as? String, "0")
    setSwitch("chat-note-tools", on: true)
    tap44(app.buttons["chat-context"])
    send("Find my notebook thought using card tools")
    XCTAssertTrue(text("Tool reply: " + notebookOpening).waitForExistence(timeout: 15))
    XCTAssertTrue(app.buttons["send-chat"].waitForExistence(timeout: 10))

    let transcript = app.scrollViews["chat-transcript"]
    reveal(app.buttons["chat-sources"], in: transcript)
    tap44(app.buttons["chat-sources"])
    let source = button(prefix: "chat-source-")
    reveal(source, in: transcript)
    let sourceID = source.identifier
    tap44(source)
    XCTAssertTrue(element("note-original").waitForExistence(timeout: 5))
    XCTAssertTrue(text(notebookOpening).exists)
    XCTAssertTrue(text("Longer ones deserve space to breathe.").exists)
    XCTAssertEqual(app.state, .runningForeground, "Opening a source stays inside DayPage")
    capture("card-tool-original-source")
    app.buttons["Done"].tap()

    let save = button(prefix: "chat-save-reply-")
    reveal(save, in: transcript)
    let replyID = String(save.identifier.dropFirst("chat-save-reply-".count))
    let speak = app.buttons["chat-speak-" + replyID]
    reveal(speak, in: transcript)
    XCTAssertGreaterThanOrEqual(speak.frame.height, 44)
    XCTAssertTrue(speak.isEnabled)
    tap44(speak)
    let reading = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label CONTAINS 'Stop speech'"), object: speak)
    XCTAssertEqual(XCTWaiter.wait(for: [reading], timeout: 5), .completed)
    tap44(speak)
    XCTAssertTrue(speak.label.contains("Read aloud"))
    XCTAssertEqual(app.state, .runningForeground)
    reveal(save, in: transcript)
    tap44(save)
    XCTAssertTrue(element("chat-reply-saved").waitForExistence(timeout: 5))
    XCTAssertFalse(save.isEnabled, "Repeated taps must not duplicate a saved reply")
    capture("card-tool-reply-saved")
    app.buttons["Close"].firstMatch.tap()
    relaunch()

    let savedCard = app.buttons.matching(NSPredicate(
      format: "identifier BEGINSWITH 'note-' AND label CONTAINS %@", "Tool reply: " + notebookOpening))
    reveal(savedCard.firstMatch)
    XCTAssertTrue(savedCard.firstMatch.waitForExistence(timeout: 10))
    XCTAssertEqual(savedCard.count, 1)
    savedCard.firstMatch.tap()
    XCTAssertTrue(element("note-original").waitForExistence(timeout: 5))
    XCTAssertTrue(text("Tool reply: " + notebookOpening).exists)
    XCTAssertTrue(text("Source:").exists)
    app.navigationBars.buttons.firstMatch.tap()
    app.buttons["new-note"].tap()
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    XCTAssertEqual(editor.value as? String, "Keep this capture draft while saving a reply.")
    XCTAssertTrue(text("Trip checklist.txt").exists)
    app.buttons["collapse-note"].tap()

    openChat()
    XCTAssertTrue(text("Tool reply: " + notebookOpening).waitForExistence(timeout: 5))
    openContext()
    XCTAssertEqual(app.switches["chat-note-tools"].value as? String, "1")
    tap44(app.buttons["chat-context"])
    reveal(app.buttons["chat-sources"], in: transcript)
    if !app.buttons[sourceID].exists { tap44(app.buttons["chat-sources"]) }
    XCTAssertTrue(app.buttons[sourceID].waitForExistence(timeout: 5), "The saved source identity survives reopening")
  }

  func testTurningOffNoteExcerptsDisablesToolsAndPersistsAnOrdinaryConversation() {
    app.launch()
    openChat()
    openContext()
    setSwitch("chat-note-tools", on: true)
    setSwitch("chat-include-notes", on: false)
    XCTAssertEqual(app.switches["chat-note-tools"].value as? String, "0")
    XCTAssertFalse(app.switches["chat-note-tools"].isEnabled)
    tap44(app.buttons["chat-context"])
    send("Talk without reading any note excerpts")
    XCTAssertTrue(text("Fixture reply:").waitForExistence(timeout: 15))
    XCTAssertTrue(app.buttons["send-chat"].waitForExistence(timeout: 10))
    XCTAssertFalse(button(prefix: "chat-source-").exists)
    XCTAssertFalse(text("Tool reply:").exists)
    app.buttons["Close"].firstMatch.tap()
    relaunch()
    openChat()
    openContext()
    XCTAssertEqual(app.switches["chat-include-notes"].value as? String, "0")
    XCTAssertEqual(app.switches["chat-note-tools"].value as? String, "0")
    XCTAssertFalse(app.switches["chat-note-tools"].isEnabled)
    capture("card-tools-note-access-off")
  }

  private func openSpeechSettings() {
    XCTAssertTrue(app.buttons["open-sidebar"].waitForExistence(timeout: 10))
    app.buttons["open-sidebar"].tap()
    app.buttons["sidebar-settings"].tap()
    tap44(app.buttons["settings-speech"])
    XCTAssertTrue(app.buttons["speech-channel-system"].waitForExistence(timeout: 5))
  }

  private func replace(_ id: String, with value: String) {
    let field = app.textFields[id]
    reveal(field)
    field.tap()
    let current = field.value as? String ?? ""
    let placeholders = ["Channel name", "Service address", "Model", "Voice", "Voice ID"]
    if !current.isEmpty && !placeholders.contains(current) {
      // A tap can place the caret in the middle of an address. Observe native
      // whole-field selection before deleting, as in the existing AI settings tests.
      field.press(forDuration: 1.1)
      let selectAllButton = app.buttons["Select All"]
      let selectAllMenu = app.menuItems["Select All"]
      let selectable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        (selectAllButton.exists && selectAllButton.isHittable)
          || (selectAllMenu.exists && selectAllMenu.isHittable)
      }, object: nil)
      guard XCTWaiter.wait(for: [selectable], timeout: 3) == .completed else {
        XCTFail("The native Select All action must be available before replacing a saved field")
        return
      }
      (selectAllButton.exists && selectAllButton.isHittable ? selectAllButton : selectAllMenu).tap()
      field.typeText(XCUIKeyboardKey.delete.rawValue)
    }
    field.typeText(value)
    XCTAssertEqual(field.value as? String, value)
  }

  private func addAnonymousSpeechChannel(named name: String, endpoint: String) {
    tap44(app.buttons["speech-add-channel"])
    let provider = element("speech-provider")
    reveal(provider)
    provider.tap()
    XCTAssertTrue(app.buttons["OpenAI-compatible"].waitForExistence(timeout: 5))
    app.buttons["OpenAI-compatible"].tap()
    replace("speech-channel-name", with: name)
    replace("speech-base-url", with: endpoint)
    replace("speech-model", with: "fixture-tts")
    replace("speech-voice", with: "fixture-voice")
    let local = app.switches["speech-local-http"]
    reveal(local)
    setSwitch("speech-local-http", on: true)
    XCTAssertEqual(app.switches["speech-requires-key"].value as? String, "0")
    reveal(app.buttons["speech-save-channel"])
    XCTAssertTrue(app.buttons["speech-save-channel"].isEnabled)
    tap44(app.buttons["speech-save-channel"])
    XCTAssertTrue(element("speech-save-status").waitForExistence(timeout: 5))
    XCTAssertTrue(element("speech-save-status").label.contains("saved"))
    XCTAssertFalse(element("speech-status").exists, "Saving a channel must not start speech")
  }

  private func savedChannel(named name: String) -> XCUIElement {
    app.buttons.matching(NSPredicate(
      format: "identifier BEGINSWITH 'speech-channel-' AND label CONTAINS %@", name)).firstMatch
  }

  private func previewAndStop() {
    let preview = app.buttons["speech-preview"]
    reveal(preview)
    tap44(preview)
    let status = element("speech-status")
    let playing = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == true AND label == 'Reading aloud'"), object: status)
    XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 10), .completed,
      "Only decoded audio reaching playback counts as a successful preview")
    XCTAssertFalse(element("speech-error").exists)
    let stop = app.buttons["speech-stop"]
    reveal(stop)
    tap44(stop)
    let stopped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: stop)
    XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 5), .completed)
    XCTAssertTrue(preview.isEnabled)
    XCTAssertEqual(app.state, .runningForeground, "Preview must not open another application")
  }

  func testSystemAndSavedCustomSpeechChannelsSwitchReopenAndPreviewExplicitly() {
    app.launch()
    openSpeechSettings()
    let system = app.buttons["speech-channel-system"]
    XCTAssertEqual(system.value as? String, "Selected")
    XCTAssertFalse(element("speech-provider").isEnabled)
    XCTAssertFalse(app.secureTextFields["speech-api-key"].exists)
    addAnonymousSpeechChannel(named: "Loopback voice", endpoint: fixture + "/v1")
    let channel = savedChannel(named: "Loopback voice")
    reveal(channel, down: true)
    XCTAssertEqual(channel.value as? String, "Selected")
    let channelID = channel.identifier

    tap44(system)
    reveal(app.buttons["speech-save-channel"])
    tap44(app.buttons["speech-save-channel"])
    reveal(system, down: true)
    XCTAssertEqual(system.value as? String, "Selected")
    app.buttons["Done"].tap()
    relaunch()
    openSpeechSettings()
    XCTAssertEqual(app.buttons["speech-channel-system"].value as? String, "Selected")
    tap44(app.buttons[channelID])
    reveal(app.textFields["speech-base-url"])
    XCTAssertEqual(app.textFields["speech-base-url"].value as? String, fixture + "/v1")
    XCTAssertEqual(app.textFields["speech-model"].value as? String, "fixture-tts")
    reveal(app.buttons["speech-save-channel"])
    tap44(app.buttons["speech-save-channel"])
    app.buttons["Done"].tap()
    relaunch()
    openSpeechSettings()
    XCTAssertEqual(app.buttons[channelID].value as? String, "Selected")
    reveal(app.textFields["speech-base-url"])
    XCTAssertEqual(app.textFields["speech-base-url"].value as? String, fixture + "/v1")
    previewAndStop()
    capture("speech-custom-preview-stopped")
  }

  // Run this exact journey in both the signed suite and the unsigned fixture
  // stage where Keychain access is denied. Anonymous speech must need neither
  // a credential nor a successful Keychain read, write, or delete.
  func testAnonymousSpeechWorksWithoutKeychain() {
    app.launch()
    openSpeechSettings()
    addAnonymousSpeechChannel(named: "No Keychain voice", endpoint: fixture + "/v1")
    XCTAssertFalse(element("speech-key-error").exists)
    previewAndStop()
    let channel = savedChannel(named: "No Keychain voice")
    reveal(channel, down: true)
    let channelID = channel.identifier
    XCTAssertEqual(channel.value as? String, "Selected")
    app.buttons["Done"].tap()
    relaunch()

    openSpeechSettings()
    XCTAssertEqual(app.buttons[channelID].value as? String, "Selected")
    reveal(app.textFields["speech-base-url"])
    XCTAssertEqual(app.textFields["speech-base-url"].value as? String, fixture + "/v1")
    reveal(app.textFields["speech-model"])
    XCTAssertEqual(app.textFields["speech-model"].value as? String, "fixture-tts")
    reveal(app.textFields["speech-voice"])
    XCTAssertEqual(app.textFields["speech-voice"].value as? String, "fixture-voice")
    reveal(app.switches["speech-requires-key"])
    XCTAssertEqual(app.switches["speech-requires-key"].value as? String, "0")
    XCTAssertFalse(element("speech-key-error").exists)
    // The audio fixture rejects all authentication headers, so decoded playback
    // also verifies that no retained credential was sent after loading settings.
    previewAndStop()
    capture("speech-anonymous-no-keychain")
  }

  func testSpeechFailureKeepsTheSavedChannelAndEditingItsAddressCanRetry() {
    app.launch()
    openSpeechSettings()
    addAnonymousSpeechChannel(named: "Recoverable voice", endpoint: fixture + "/failure/v1")
    let preview = app.buttons["speech-preview"]
    reveal(preview)
    tap44(preview)
    let error = element("speech-error")
    XCTAssertTrue(error.waitForExistence(timeout: 10))
    XCTAssertTrue(error.label.contains("rejected this key"))
    XCTAssertTrue(preview.isEnabled)
    XCTAssertFalse(app.buttons["speech-stop"].exists)
    reveal(app.textFields["speech-base-url"], down: true)
    XCTAssertEqual(app.textFields["speech-base-url"].value as? String, fixture + "/failure/v1")
    replace("speech-base-url", with: fixture + "/v1")
    reveal(app.buttons["speech-save-channel"])
    tap44(app.buttons["speech-save-channel"])
    previewAndStop()
    reveal(savedChannel(named: "Recoverable voice"), down: true)
    XCTAssertEqual(savedChannel(named: "Recoverable voice").value as? String, "Selected")
    XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'speech-channel-'")).count, 2)
    capture("speech-channel-recovered")
    app.buttons["Done"].tap()
    relaunch()
    openSpeechSettings()
    XCTAssertEqual(savedChannel(named: "Recoverable voice").value as? String, "Selected")
    reveal(app.textFields["speech-base-url"])
    XCTAssertEqual(app.textFields["speech-base-url"].value as? String, fixture + "/v1")
    XCTAssertFalse(element("speech-error").exists)
  }

  func testElevenLabsSavedKeySurvivesRelaunchAndStaysSeparateFromAnAnonymousChannel() {
    app.launch()
    openSpeechSettings()
    addAnonymousSpeechChannel(named: "Anonymous sibling", endpoint: fixture + "/v1")
    reveal(app.buttons["speech-add-channel"], down: true)
    tap44(app.buttons["speech-add-channel"])
    let provider = element("speech-provider")
    reveal(provider)
    provider.tap()
    XCTAssertTrue(app.buttons["ElevenLabs"].waitForExistence(timeout: 5))
    app.buttons["ElevenLabs"].tap()
    replace("speech-channel-name", with: "ElevenLabs fixture")
    replace("speech-base-url", with: fixture + "/v1")
    replace("speech-model", with: "fixture-tts")
    replace("speech-voice", with: "fixture-voice")
    reveal(app.switches["speech-local-http"])
    setSwitch("speech-local-http", on: true)
    reveal(app.buttons["speech-save-channel"])
    XCTAssertFalse(app.buttons["speech-save-channel"].isEnabled,
      "The ElevenLabs dialect requires its own channel key")
    let key = app.secureTextFields["speech-api-key"]
    reveal(key, down: true)
    key.tap()
    // This is an intentionally public synthetic fixture token, never an account credential.
    // Do not read, attach, or print the secure field's contents.
    key.typeText("fixture-speech-key")
    reveal(app.buttons["speech-save-channel"])
    XCTAssertTrue(app.buttons["speech-save-channel"].isEnabled)
    tap44(app.buttons["speech-save-channel"])
    XCTAssertTrue(element("speech-save-status").waitForExistence(timeout: 5))
    XCTAssertFalse(element("speech-status").exists)
    let elevenLabs = savedChannel(named: "ElevenLabs fixture")
    reveal(elevenLabs, down: true)
    let channelID = elevenLabs.identifier
    XCTAssertEqual(elevenLabs.value as? String, "Selected")
    app.buttons["Done"].tap()
    relaunch()

    openSpeechSettings()
    XCTAssertEqual(app.buttons[channelID].value as? String, "Selected")
    XCTAssertTrue(savedChannel(named: "Anonymous sibling").exists)
    XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'speech-channel-'")).count, 3)
    reveal(app.textFields["speech-base-url"])
    XCTAssertEqual(app.textFields["speech-base-url"].value as? String, fixture + "/v1")
    XCTAssertEqual(app.textFields["speech-model"].value as? String, "fixture-tts")
    reveal(app.textFields["speech-voice"])
    XCTAssertEqual(app.textFields["speech-voice"].value as? String, "fixture-voice")
    // The server accepts only xi-api-key: fixture-speech-key on this voice route.
    // Successful decoded playback after relaunch proves that Keychain restored the key.
    previewAndStop()

    let anonymous = savedChannel(named: "Anonymous sibling")
    reveal(anonymous, down: true)
    tap44(anonymous)
    reveal(app.buttons["speech-save-channel"])
    tap44(app.buttons["speech-save-channel"])
    // The same-origin compatible endpoint rejects Authorization and xi-api-key.
    // A successful sibling preview therefore also proves channel-key isolation.
    previewAndStop()
    reveal(anonymous, down: true)
    XCTAssertEqual(anonymous.value as? String, "Selected")
    XCTAssertTrue(app.buttons[channelID].exists)
    capture("speech-elevenlabs-and-anonymous-channels")
  }
}
