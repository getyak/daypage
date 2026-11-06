import XCTest

final class DiaryUITests: XCTestCase {
  private let app = XCUIApplication()

  override func setUp() {
    continueAfterFailure = false
    app.launchArguments = ["-qaNotebookSession", "-qaResetNotebook", "-qaSeedDiaryHistory",
      "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
  }

  func testHomeScrollsAcrossDaysAndReturnsToToday() {
    launchDiary()
    let earlier = note("Diary history 4.")
    let feed = element("today-timeline")
    reveal(earlier, in: feed)
    XCTAssertTrue(earlier.isHittable, "Previous days must be reachable directly on Home")
    let todayHeading = element("diary-heading-" + day(0))
    XCTAssertFalse(todayHeading.exists && todayHeading.frame.intersects(feed.frame))
    XCTAssertTrue(app.buttons["diary-back-today"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["diary-back-today"].isHittable)
    capture("diary-earlier-days")
    earlier.tap()
    XCTAssertTrue(app.staticTexts["note-original"].waitForExistence(timeout: 5))
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertTrue(earlier.isHittable, "Back must retain the historical reading position")
    app.buttons["diary-back-today"].tap()
    XCTAssertTrue(note("Diary history 0.").isHittable)
    XCTAssertTrue(app.buttons["new-note"].isHittable)
    capture("diary-home-today")
  }

  func testMonthJumpKeepsNeighboringDaysAndCanRepeat() throws {
    launchDiary()
    let oldDay = day(140)
    openSidebar()
    XCTAssertTrue(element("sidebar-summary").label.contains("8 notes"))
    reveal(app.buttons["sidebar-all-months"], in: element("notebook-sidebar"))
    app.buttons["sidebar-all-months"].tap()
    let month = app.buttons["sidebar-month-" + oldDay.prefix(7)]
    reveal(month, in: element("notebook-sidebar"))
    month.tap()
    XCTAssertEqual(app.buttons["choose-date"].value as? String, oldDay)
    XCTAssertTrue(note("Diary history 7.").isHittable)
    capture("diary-month-position")
    let neighbor = note("Diary history 6.")
    reveal(neighbor, in: element("today-timeline"), newer: true)
    XCTAssertTrue(neighbor.isHittable, "Month selection must position the continuous diary")
    neighbor.tap()
    XCTAssertTrue(app.staticTexts["note-original"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["note-original"].label.contains("Diary history 6."))
    app.navigationBars.buttons.firstMatch.tap()
    openSidebar()
    app.buttons["notebook-home"].tap()
    XCTAssertTrue(note("Diary history 0.").isHittable)
    element("today-timeline").swipeUp()
    openSidebar()
    app.buttons["notebook-home"].tap()
    XCTAssertTrue(note("Diary history 0.").isHittable, "Choosing Home again must return to the top")
  }

  func testRediscoveryOpensAnExistingPastNoteWithoutCreatingOne() {
    launchDiary()
    openSidebar()
    capture("diary-sidebar-en")
    let rediscover = app.buttons["sidebar-rediscover"]
    reveal(rediscover, in: element("notebook-sidebar"))
    rediscover.tap()
    let original = app.staticTexts["note-original"]
    XCTAssertTrue(original.waitForExistence(timeout: 5))
    XCTAssertTrue(original.label.contains("Diary history"))
    XCTAssertFalse(original.label.contains("Diary history 0."))
    capture("diary-rediscovered-note")
    app.navigationBars.buttons.firstMatch.tap()
    openSidebar()
    XCTAssertTrue(element("sidebar-summary").label.contains("8 notes"))
  }

  func testCaptureFromPastDayReturnsToItsNewRecordAndKeepsHistory() {
    app.launchArguments += ["-qaSeedDiaryPins"]
    launchDiary()
    app.buttons["choose-date"].tap()
    if day(1).prefix(7) != day(0).prefix(7) { app.buttons["calendar-previous-month"].tap() }
    app.buttons["calendar-day-" + day(1)].tap()
    app.buttons["calendar-done"].tap()
    XCTAssertTrue(note("Diary history 1.").isHittable)
    app.buttons["new-note"].tap()
    let editor = app.textViews["note-editor"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.tap()
    editor.typeText("A fresh thought while revisiting yesterday.")
    app.buttons["save-note"].tap()
    XCTAssertEqual(app.buttons["choose-date"].value as? String, day(0))
    XCTAssertTrue(note("A fresh thought while revisiting yesterday.").waitForExistence(timeout: 5))
    XCTAssertTrue(note("A fresh thought while revisiting yesterday.").isHittable)
    reveal(note("Diary history 1."), in: element("today-timeline"))
    XCTAssertTrue(note("Diary history 1.").isHittable)
  }

  func testChineseDarkSidebarAndLargeTextStayReachable() {
    let chinese = ["-qaNotebookSession", "-qaResetNotebook", "-qaSeedDiaryHistory",
      "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
    app.launchArguments = chinese + ["-local.appearance", "light"]
    launchDiary()
    openSidebar()
    XCTAssertEqual(app.buttons["notebook-home"].label, "日记")
    capture("diary-sidebar-zh-normal")
    app.terminate()
    app.launchArguments = chinese + ["-local.appearance", "dark",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    launchDiary()
    openSidebar()
    XCTAssertEqual(app.buttons["notebook-home"].label, "日记")
    capture("diary-sidebar-zh-dark-large-text")
    let settings = app.buttons["sidebar-settings"]
    reveal(settings, in: element("notebook-sidebar"))
    settings.tap()
    XCTAssertTrue(app.buttons["settings-ai-models"].waitForExistence(timeout: 5))
  }

  func testEmptyNotebookHasNoRediscoveryAndDrawerDismisses() {
    app.launchArguments.removeAll { $0 == "-qaSeedDiaryHistory" }
    app.launch()
    XCTAssertTrue(app.buttons["open-sidebar"].waitForExistence(timeout: 10))
    openSidebar()
    XCTAssertFalse(app.buttons["sidebar-rediscover"].exists)
    XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar-month-'")).firstMatch.exists)
    app.buttons["close-sidebar"].tap()
    XCTAssertTrue(app.buttons["new-note"].isHittable)
  }

  func testReadingPreferencesPersistAndExternalHeadingsAreHidden() {
    launchDiary()
    XCTAssertFalse(app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'diary-heading-'")).firstMatch.exists)
    XCTAssertFalse(app.staticTexts["All saved on this device"].exists)
    openReadingSettings()
    let stepper = app.steppers["note-font-size"]
    XCTAssertEqual(stepper.value as? String, "15")
    stepper.buttons["note-font-size-Increment"].tap()
    XCTAssertEqual(stepper.value as? String, "16")
    app.buttons["note-font-style"].tap()
    app.buttons["Rounded"].tap()
    captureDiagnostics("card-reading-font-selected")
    let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Rounded"),
                                              object: app.buttons["note-font-style"])
    XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
    reveal(element("note-typography-preview"), in: app.collectionViews.firstMatch)
    capture("card-reading-font-preview")
    app.terminate()
    app.launchArguments.removeAll { $0 == "-qaResetNotebook" }
    app.launch()
    XCTAssertTrue(app.buttons["open-sidebar"].waitForExistence(timeout: 10))
    openReadingSettings()
    XCTAssertEqual(app.steppers["note-font-size"].value as? String, "16")
    XCTAssertEqual(app.buttons["note-font-style"].value as? String, "Rounded")
  }

  func testOptionalLocationSurvivesDraftRelaunchAndClearsForNextNote() {
    app.launchArguments += ["-qaLocationFixture"]
    launchDiary()
    openEditor("A place to remember.")
    XCTAssertFalse(element("capture-selected-location").exists)
    app.buttons["capture-location"].tap()
    XCTAssertTrue(element("capture-selected-location").waitForExistence(timeout: 5))
    XCTAssertTrue(element("capture-selected-location").label.contains("Synthetic place"))
    capture("card-location-selected")
    app.buttons["collapse-note"].tap()
    app.terminate()
    app.launchArguments.removeAll { $0 == "-qaResetNotebook" }
    app.launch()
    XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 10))
    app.buttons["new-note"].tap()
    XCTAssertTrue(app.textViews["note-editor"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.textViews["note-editor"].value as? String, "A place to remember.")
    XCTAssertTrue(element("capture-selected-location").exists)
    app.buttons["save-note"].tap()
    let saved = note("A place to remember.")
    XCTAssertTrue(saved.waitForExistence(timeout: 5))
    saved.tap()
    XCTAssertTrue(element("note-location").waitForExistence(timeout: 5))
    XCTAssertTrue(element("note-location").label.contains("Synthetic place"))
    capture("card-location-saved-detail")
    app.navigationBars.buttons.firstMatch.tap()
    app.buttons["new-note"].tap()
    XCTAssertTrue(app.textViews["note-editor"].waitForExistence(timeout: 5))
    XCTAssertFalse(element("capture-selected-location").exists)
  }

  func testCancelledLocationCannotArriveLaterAndRemovalSurvivesRelaunch() {
    app.launchArguments += ["-qaLocationFixture", "-qaLocationDelay"]
    launchDiary()
    openEditor("Keep writing without a place.")
    app.buttons["capture-location"].tap()
    XCTAssertTrue(app.buttons["cancel-capture-location"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["save-note"].isEnabled)
    XCTAssertTrue(app.buttons["collapse-note"].isEnabled)
    app.buttons["cancel-capture-location"].tap()
    let stopped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                             object: app.buttons["cancel-capture-location"])
    XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 3), .completed,
                   "Cancel must end the pending request before the ten-second fixture completes")
    XCTAssertTrue(app.buttons["capture-location"].exists)
    XCTAssertFalse(element("capture-selected-location").exists)
    capture("card-location-cancelled")
    let late = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"),
                                         object: element("capture-selected-location"))
    late.isInverted = true
    XCTAssertEqual(XCTWaiter.wait(for: [late], timeout: 11), .completed)
    XCTAssertTrue(app.buttons["save-note"].isEnabled)
    app.buttons["capture-location"].tap()
    XCTAssertTrue(element("capture-selected-location").waitForExistence(timeout: 14))
    app.buttons["remove-capture-location"].tap()
    let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                            object: element("capture-selected-location"))
    XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed)
    app.buttons["collapse-note"].tap()
    app.terminate()
    app.launchArguments.removeAll { $0 == "-qaResetNotebook" }
    app.launch()
    XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 10))
    app.buttons["new-note"].tap()
    XCTAssertTrue(app.textViews["note-editor"].waitForExistence(timeout: 5))
    XCTAssertFalse(element("capture-selected-location").exists)
    app.buttons["save-note"].tap()
    XCTAssertTrue(note("Keep writing without a place.").waitForExistence(timeout: 5))
    note("Keep writing without a place.").tap()
    XCTAssertFalse(element("note-location").exists)
  }

  func testRealLocationPermissionDenialStillAllowsSavingWithoutLocation() {
    app.resetAuthorizationStatus(for: .location)
    launchDiary()
    openEditor("No location is required to save this note.")
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    XCTAssertFalse(springboard.alerts.firstMatch.exists, "Opening Write a note must not request location")
    app.buttons["capture-location"].tap()
    let alert = springboard.alerts.firstMatch
    XCTAssertTrue(alert.waitForExistence(timeout: 10))
    let deny = alert.buttons.matching(NSPredicate(format: "label MATCHES[c] %@", "Don.*Allow")).firstMatch
    XCTAssertTrue(deny.waitForExistence(timeout: 5))
    deny.tap()
    XCTAssertTrue(app.staticTexts["Location access is off. You can enable it in Settings or save without a location."]
      .waitForExistence(timeout: 5))
    XCTAssertFalse(element("capture-selected-location").exists)
    XCTAssertTrue(app.buttons["save-note"].isEnabled)
    capture("card-location-real-permission-denied")
    app.buttons["save-note"].tap()
    XCTAssertTrue(note("No location is required to save this note.").waitForExistence(timeout: 5))
  }

  private func openReadingSettings() {
    openSidebar()
    let settings = app.buttons["sidebar-settings"]
    reveal(settings, in: element("notebook-sidebar"))
    settings.tap()
    let font = app.buttons["note-font-style"]
    reveal(font, in: app.collectionViews.firstMatch)
    XCTAssertTrue(font.waitForExistence(timeout: 5))
    reveal(element("note-font-size"), in: app.collectionViews.firstMatch)
  }

  private func openEditor(_ body: String) {
    app.buttons["new-note"].tap()
    let editor = app.textViews["note-editor"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.tap()
    editor.typeText(body)
  }

  private func launchDiary() {
    app.launch()
    let first = app.launchArguments.contains("-qaSeedDiaryPins") ? "Pinned diary" : "Diary history 0."
    XCTAssertTrue(note(first).waitForExistence(timeout: 15))
  }

  private func openSidebar() {
    app.buttons["open-sidebar"].tap()
    XCTAssertTrue(app.buttons["notebook-home"].waitForExistence(timeout: 5))
  }

  private func element(_ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  private func note(_ text: String) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'note-' AND label CONTAINS %@", text)).firstMatch
  }

  private func reveal(_ control: XCUIElement, in container: XCUIElement, newer: Bool = false) {
    for _ in 0..<16 {
      let visible = container.frame.intersection(app.frame)
      if control.exists && control.isHittable && visible.contains(control.frame) { return }
      // A full-screen flick can skip a nearby dated section. Move a bounded
      // portion of the actual container, then inspect the target again.
      let origin = container.coordinate(withNormalizedOffset: .zero)
      let x = visible.midX - container.frame.minX
      let high = visible.minY + visible.height * 0.35 - container.frame.minY
      let low = visible.minY + visible.height * 0.65 - container.frame.minY
      origin.withOffset(CGVector(dx: x, dy: newer ? high : low))
        .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: x, dy: newer ? low : high)))
    }
    XCTAssertTrue(control.isHittable)
    XCTAssertTrue(container.frame.intersection(app.frame).contains(control.frame))
  }

  private func day(_ offset: Int) -> String {
    let calendar = Calendar(identifier: .gregorian)
    let date = calendar.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  private func capture(_ name: String) {
    XCTAssertEqual(app.state, .runningForeground)
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func captureDiagnostics(_ name: String) {
    capture(name)
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = name + "-accessibility"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
  }
}
