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

  func testAppStoreScreenshotsUseTheLocalNotebookAndExposeItsPrivacyPolicy() {
    app.launchArguments = [
      "-qaNotebookSession", "-qaResetNotebook", "-qaSeedNotebook",
      "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
    ]
    app.launch()
    XCTAssertTrue(app.buttons["open-sidebar"].waitForExistence(timeout: 10))
    XCTAssertTrue(visibleText("回家的时候没有戴耳机。").waitForExistence(timeout: 10))
    screenshot("appstore-diary")
    app.buttons["open-sidebar"].tap()
    XCTAssertTrue(app.buttons["sidebar-archive"].waitForExistence(timeout: 5))
    screenshot("appstore-sidebar")
    app.buttons["sidebar-archive"].tap()
    XCTAssertTrue(element("archive-summary").waitForExistence(timeout: 5))
    screenshot("appstore-archive")
    app.buttons["open-sidebar"].tap()
    app.buttons["sidebar-settings"].tap()
    XCTAssertTrue(app.buttons["settings-ai-models"].waitForExistence(timeout: 5))
    let policy = element("settings-privacy-policy")
    for _ in 0..<4 {
      if policy.isHittable { break }
      app.swipeUp()
    }
    XCTAssertTrue(policy.isHittable)
    XCTAssertGreaterThanOrEqual(policy.frame.height, 44 - 0.000_001)
    screenshot("appstore-settings-privacy")
  }

  private func openInformation(_ id: String) {
    XCTAssertTrue(app.buttons["open-sidebar"].waitForExistence(timeout: 10))
    app.buttons["open-sidebar"].tap()
    app.buttons["sidebar-settings"].tap()
    let destination = element(id)
    for _ in 0..<6 {
      if destination.isHittable { break }
      app.swipeUp()
    }
    XCTAssertTrue(destination.isHittable)
    XCTAssertGreaterThanOrEqual(destination.frame.height, 44 - 0.000_001)
    destination.tap()
    XCTAssertTrue(element("app-information-page").waitForExistence(timeout: 5))
  }

  private func informationFooter() {
    let minimumTouchSize: CGFloat = 44
    let window = app.frame
    // A clipped target can be hittable at the screen's bottom edge. Requiring
    // its complete 44-point body plus half a touch height of edge clearance
    // keeps the target's center at least one touch height inside the window.
    let edgeClearance = minimumTouchSize / 2
    var top = window.minY + edgeClearance
    for bar in app.navigationBars.allElementsBoundByAccessibilityElement
      where bar.exists && bar.isHittable {
      if window.intersects(bar.frame) { top = max(top, bar.frame.maxY) }
    }
    let viewport = CGRect(x: window.minX, y: top, width: window.width,
      height: max(0, window.maxY - edgeClearance - top))
    guard !viewport.isNull, !viewport.isEmpty, viewport.height >= minimumTouchSize else {
      XCTFail("The public-information page needs an unobscured touch area")
      return
    }
    let buttons = app.buttons.matching(identifier: "app-information-check-latest")
    for _ in 0..<24 {
      let candidates = buttons.allElementsBoundByAccessibilityElement
      guard candidates.count <= 1 else {
        XCTFail("The public-information footer needs one unambiguous check button")
        return
      }
      if let button = candidates.first {
        let frame = button.frame
        if frame.width >= minimumTouchSize - 0.000_001,
          frame.height >= minimumTouchSize - 0.000_001,
          viewport.contains(frame), button.isHittable { return }
      }
      app.swipeUp()
    }
    XCTFail("The public-information footer is not reachable")
  }

  func testBundledPrivacyInformationIsReadableInEnglishAfterRelaunch() {
    app.launch()
    openInformation("settings-privacy-policy")
    XCTAssertTrue(visibleText("This policy covers the local iOS edition").waitForExistence(timeout: 5))
    screenshot("app-information-privacy-en")
    informationFooter()
    XCTAssertEqual(element("app-information-source").label, "Information included with this app")
    XCTAssertFalse(element("app-information-failure").exists)
    app.terminate()
    app.launchArguments.removeAll { $0 == "-qaResetNotebook" }
    app.launch()
    openInformation("settings-privacy-policy")
    XCTAssertTrue(visibleText("This policy covers the local iOS edition").waitForExistence(timeout: 5))
  }

  func testBundledAboutAndSupportUseChineseAtAccessibilitySize() {
    app.launchArguments = ["-qaNotebookSession", "-qaResetNotebook", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                           "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    app.launch()
    openInformation("settings-about-support")
    XCTAssertTrue(visibleText("无需账户的本地笔记应用").waitForExistence(timeout: 5))
    XCTAssertTrue(element("app-information-installed-version").exists)
    screenshot("app-information-about-zh")
    informationFooter()
    XCTAssertEqual(element("app-information-source").label, "随 App 提供的说明")
  }

  func testManualInformationCheckKeepsReadableContentAndRecordsItsActualOutcome() {
    app.launch()
    openInformation("settings-about-support")
    informationFooter()
    element("app-information-check-latest").tap()
    XCTAssertTrue(element("app-information-check-latest").waitForExistence(timeout: 12))
    let done = NSPredicate(format: "enabled == true")
    expectation(for: done, evaluatedWith: element("app-information-check-latest"))
    waitForExpectations(timeout: 12)
    let source = element("app-information-source").label
    if element("app-information-failure").exists {
      XCTAssertEqual(source, "Information included with this app")
      XCTAssertTrue(element("app-information-check-latest").isEnabled, "Failed refresh must permit retry")
      let bundledAbout = "An account-free local notebook. Write, read, search, import and export offline. The installed version is read from this device."
      for _ in 0..<12 {
        if visibleText(bundledAbout).isHittable { break }
        app.swipeDown()
      }
      XCTAssertTrue(visibleText(bundledAbout).isHittable, "Failed refresh must retain actual bundled content")
      screenshot("app-information-failure-retained-bundle")
    } else {
      XCTAssertEqual(source, "Latest information from DayPage")
    }
    let outcome = XCTAttachment(string: "Observed source: " + source + "; no network override or offline simulation used.")
    outcome.name = "app-information-network-outcome"
    outcome.lifetime = .keepAlways
    add(outcome)
    screenshot("app-information-after-manual-check")
    app.swipeDown()
    XCTAssertTrue(element("app-information-page").exists)
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

  func testDevicesAndICloudStartsLocalAndExplainsTheBackupScope() {
    app.launch()
    XCTAssertTrue(app.buttons["open-sidebar"].waitForExistence(timeout: 10))
    app.buttons["open-sidebar"].tap()
    app.buttons["sidebar-settings"].tap()
    let devices = element("settings-continuity")
    XCTAssertTrue(devices.waitForExistence(timeout: 5))
    devices.tap()
    let cloud = app.switches["icloud-enabled"]
    for _ in 0..<4 {
      if cloud.isHittable { break }
      app.swipeUp()
    }
    XCTAssertTrue(cloud.isHittable)
    XCTAssertEqual(cloud.value as? String, "0")
    XCTAssertFalse(app.buttons["icloud-sync-now"].isEnabled)
    XCTAssertTrue(visibleText("iCloud uses Apple’s servers").exists)
    screenshot("local-devices-and-icloud-off")
    let recover = element("icloud-versions")
    for _ in 0..<4 {
      if recover.isHittable { break }
      app.swipeUp()
    }
    XCTAssertFalse(recover.isEnabled)
    XCTAssertTrue(visibleText("note relationships and action history").exists)
    screenshot("local-icloud-recovery-scope")
  }

  func testSidebarKeepsItsDestinationsAndSettingsNeedsNoAccount() {
    app.launchArguments += ["-qaSeedNotebook"]
    app.launch()
    XCTAssertTrue(app.buttons["open-sidebar"].waitForExistence(timeout: 10))
    app.buttons["open-sidebar"].tap()
    XCTAssertTrue(app.buttons["sidebar-archive"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["notebook-home"].exists)
    XCTAssertTrue(app.buttons["sidebar-feedback"].exists)
    XCTAssertTrue(app.buttons["sidebar-settings"].exists)
    screenshot("local-sidebar")
    app.buttons["sidebar-settings"].tap()
    XCTAssertTrue(app.buttons["settings-ai-models"].waitForExistence(timeout: 5))
    XCTAssertFalse(element("ai-provider").exists)
    app.buttons["settings-ai-models"].tap()
    XCTAssertTrue(element("ai-provider").waitForExistence(timeout: 5))
    XCTAssertTrue(app.secureTextFields["ai-key"].exists)
    XCTAssertFalse(app.buttons["Sign in"].exists)
    screenshot("local-ai-settings")
    app.buttons["Done"].tap()
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
    let models = app.buttons["settings-ai-models"]
    XCTAssertTrue(models.waitForExistence(timeout: 5))
    models.tap()
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
    let visibleKeyboard = app.keyboards.allElementsBoundByIndex.contains { keyboard in
      guard keyboard.exists else { return false }
      let overlap = keyboard.frame.intersection(app.frame)
      return !overlap.isNull && overlap.width > 1 && overlap.height > 1
    }
    XCTAssertFalse(visibleKeyboard, "Returning from a note must not steal search focus")
    let deleted = element("search-list").buttons["recently-deleted"]
    XCTAssertTrue(deleted.waitForExistence(timeout: 5))
    XCTAssertTrue(app.frame.contains(deleted.frame))
    // List's AX row extends past its inset content. Its synthesized safe point
    // can land on that padding/scrollbar; the current center is inside the label.
    deleted.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(app.navigationBars["Recently Deleted"].waitForExistence(timeout: 5), "The footer must open the recovery page")
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
    let emptyDate = element("diary-empty-" + yesterday)
    XCTAssertTrue(emptyDate.waitForExistence(timeout: 5))
    XCTAssertTrue(emptyDate.frame.intersects(element("today-timeline").frame))
    screenshot("restored-history-on-empty-date")
    app.buttons["diary-back-today"].tap()
    XCTAssertEqual(app.buttons["choose-date"].value as? String, today)
    XCTAssertTrue(visibleText("Walked home without headphones.").waitForExistence(timeout: 5))
    XCTAssertTrue(visibleText("Walked home without headphones.").isHittable)
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
