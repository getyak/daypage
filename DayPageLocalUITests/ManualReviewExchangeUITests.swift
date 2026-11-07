import XCTest

/// Native journeys through production review/exchange models. The exact QA
/// bundle/session/vault replaces only the paid transport and folder ingress.
/// System Files selection, export destination and real BYOK remain separate
/// acceptance surfaces; these tests never claim to exercise them.
final class ManualReviewExchangeUITests: XCTestCase {
  private let app = XCUIApplication()
  private var session = UUID()
  private let memoID = "44200000-0000-4000-8000-000000000001"
  private var formID = "manual-review-form"

  override func setUp() {
    continueAfterFailure = false
    session = UUID()
  }
  override func tearDown() {
    app.terminate()
    super.tearDown()
  }
  private func element(_ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }
  private func launch(reset: Bool) {
    app.launchArguments = [
      "-qaNotebookSession", "-qaManualReviewExchangeSession", session.uuidString,
      "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ] + (reset ? ["-qaResetNotebook"] : [])
    app.launch()
    XCTAssertTrue(app.buttons["open-sidebar"].waitForExistence(timeout: 10))
  }
  private func open(_ kind: String) {
    app.buttons["open-sidebar"].tap()
    XCTAssertTrue(app.buttons["sidebar-settings"].waitForExistence(timeout: 5))
    app.buttons["sidebar-settings"].tap()
    let target = app.buttons[kind == "review" ? "settings-manual-reviews" : "import-vault"]
    XCTAssertTrue(target.waitForExistence(timeout: 5))
    // Settings is a separate owning list, before the modal Form appears.
    for _ in 0..<8 where !target.isHittable { app.swipeUp() }
    XCTAssertTrue(target.isHittable); target.tap()
    formID = kind == "review" ? "manual-review-form" : "vault-exchange-form"
    XCTAssertTrue(element(formID).waitForExistence(timeout: 10))
    if kind == "review" { waitLabel("qa-review-state", contains: ["sources=1", "selected=1"]) }
    else { waitLabel("qa-exchange-state", contains: ["phase=none"]) }
  }
  private func reveal(_ target: XCUIElement) {
    let form = element(formID)
    XCTAssertTrue(form.waitForExistence(timeout: 5))
    for attempt in 0..<24 {
      var visible = form.frame.intersection(app.frame).insetBy(dx: 0, dy: 12)
      let keyboard = app.keyboards.firstMatch
      if keyboard.exists { visible.size.height = max(0, min(visible.maxY, keyboard.frame.minY) - visible.minY) }
      if target.exists, target.isHittable, visible.contains(target.frame) { return }
      if target.exists, target.frame.height > 0 {
        if target.frame.minY < visible.minY { form.swipeDown() } else { form.swipeUp() }
      } else if attempt < 8 { form.swipeDown() }
      else { form.swipeUp() }
    }
    capture("unreachable-control")
    XCTFail("The complete control must be reachable in its owning Form: \(target.identifier)")
  }
  private func tap(_ id: String) {
    let target = element(id); reveal(target); target.tap()
  }
  private func waitLabel(_ id: String, contains parts: [String], timeout: TimeInterval = 10) {
    let target = element(id)
    reveal(target)
    let check = NSCompoundPredicate(andPredicateWithSubpredicates:
      [NSPredicate(format: "identifier == %@", id)]
        + parts.map { NSPredicate(format: "label CONTAINS %@", $0) })
    let ready = app.staticTexts.matching(check).firstMatch
    XCTAssertTrue(ready.waitForExistence(timeout: timeout),
      "Expected \(parts) in \(id); actual \(target.exists ? target.label : "absent")")
  }
  private func assertStored(_ kind: String, contains parts: [String]) {
    let prefix = kind == "review" ? "qa-review" : "qa-exchange"
    let proof = element(prefix + "-proof")
    reveal(proof)
    let old = proof.label.split(separator: " ").first.flatMap { Int($0.dropFirst("readbacks=".count)) } ?? -1
    XCTAssertGreaterThanOrEqual(old, 0)
    tap(prefix + "-readback")
    let imported = parts.contains("imported=1") ? "verified" : "none"
    waitLabel(prefix + "-proof", contains: ["readbacks=\(old + 1)", "local=1", "originals=unchanged", "importedBytes=" + imported] + parts)
  }
  private func setSwitch(_ id: String, on: Bool) {
    let target = app.switches[id]
    reveal(target)
    XCTAssertTrue(target.exists)
    if (target.value as? String == "1") != on { target.tap() }
    XCTAssertEqual(target.value as? String, on ? "1" : "0")
  }
  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "GET442-" + name; attachment.lifetime = .keepAlways; add(attachment)
  }
  private func saved(_ kind: String) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "saved-manual-review-" + kind + "-")).firstMatch
  }
  private func generateAndSave(_ kind: String) {
    waitLabel("qa-review-state", contains: ["period=" + kind, "loading=false", "sources=1", "selected=1"])
    let generate = element("generate-manual-review")
    reveal(generate); XCTAssertFalse(generate.isEnabled, "Opening a preview cannot grant send consent")
    waitLabel("qa-review-counts", contains: ["calls=0", "completed=0", "settled=0"])
    let source = "manual-review-source-" + memoID
    let sourceRow = element(source); reveal(sourceRow)
    XCTAssertTrue(sourceRow.label.contains("GET442 original local note."))
    tap(source)
    waitLabel("qa-review-state", contains: ["selected=0", "consent=false", "result=false"])
    tap(source)
    setSwitch("manual-review-consent", on: true)
    tap("generate-manual-review")
    waitLabel("qa-review-state", contains: ["result=true"], timeout: 15)
    waitLabel("qa-review-counts", contains: ["calls=1", "completed=1", "settled=1"])
    assertStored("review", contains: ["pages=0", "imported=0", "pending=0"])
    let editor = app.textViews["manual-review-editor"]
    reveal(editor)
    XCTAssertTrue((editor.value as? String ?? "").contains("GET442 synthetic " + kind + " review"))
    editor.tap()
    editor.typeText("\nGET442 edited before explicit Save.")
    // Reveal Save above the keyboard in its real owning Form.
    tap("save-manual-review")
    waitLabel("qa-review-state", contains: ["consent=false", "result=false"])
    assertStored("review", contains: ["pages=1", "imported=0", "pending=0"])
    let row = saved(kind)
    reveal(row); XCTAssertTrue(row.exists)
    capture(kind + "-saved-independent-page")
    row.tap()
    let body = element("saved-manual-review-body")
    XCTAssertTrue(body.waitForExistence(timeout: 5))
    XCTAssertTrue(body.label.contains("GET442 edited before explicit Save."))
  }

  func testDayPreviewRequiresSendAndSaveThenSurvivesRelaunchWithoutChangingOriginals() {
    launch(reset: true); open("review")
    generateAndSave("day")
    app.terminate(); launch(reset: false); open("review")
    assertStored("review", contains: ["pages=1", "day=1", "week=0", "imported=0", "pending=0"])
    waitLabel("qa-review-counts", contains: ["calls=0", "completed=0"])
    let row = saved("day"); reveal(row); row.tap()
    XCTAssertTrue(element("saved-manual-review-body").waitForExistence(timeout: 5))
    XCTAssertTrue(element("saved-manual-review-body").label.contains("GET442 edited before explicit Save."))
    capture("day-relaunched-page")
  }

  func testWeekReviewUsesExplicitSelectionAndSavesASeparatePage() {
    launch(reset: true); open("review")
    let period = element("manual-review-period"); reveal(period)
    period.buttons["Week"].tap()
    waitLabel("qa-review-state", contains: ["period=week", "loading=false", "sources=1", "selected=1", "consent=false"])
    generateAndSave("week")
    app.terminate(); launch(reset: false); open("review")
    assertStored("review", contains: ["pages=1", "day=0", "week=1", "imported=0"])
  }

  func testCancelledNoncooperativeLateReplyCannotReappearOrSave() {
    launch(reset: true); open("review")
    setSwitch("qa-review-hold", on: true)
    setSwitch("manual-review-consent", on: true)
    tap("generate-manual-review")
    waitLabel("qa-review-counts", contains: ["calls=1", "completed=0", "settled=0"])
    tap("cancel-manual-review")
    waitLabel("qa-review-state", contains: ["consent=false", "result=false"])
    tap("qa-review-release")
    waitLabel("qa-review-counts", contains: ["calls=1", "completed=1", "settled=1"], timeout: 15)
    waitLabel("qa-review-state", contains: ["consent=false", "result=false"])
    XCTAssertFalse(element("save-manual-review").exists)
    assertStored("review", contains: ["pages=0", "imported=0", "pending=0"])
    capture("cancelled-late-reply-fenced")
  }

  func testExportAndImportPreviewsDoNotPublishUntilConfirmThenUseANewNamespace() {
    launch(reset: true); open("exchange")
    tap("preview-vault-exchange-export")
    waitLabel("qa-exchange-state", contains: ["exportNotes=1", "pending=0"])
    reveal(element("confirm-vault-exchange-export"))
    XCTAssertTrue(element("confirm-vault-exchange-export").exists)
    assertStored("exchange", contains: ["pages=0", "imported=0", "pending=0"])
    tap("qa-exchange-source")
    waitLabel("qa-exchange-state", contains: ["pending=1", "phase=ready", "previewNotes=1"])
    assertStored("exchange", contains: ["imported=0", "pending=1"])
    capture("import-preview-before-confirmation")
    tap("confirm-vault-exchange-import")
    waitLabel("qa-exchange-state", contains: ["pending=0", "phase=none"])
    assertStored("exchange", contains: ["imported=1", "importedReviews=1", "pending=0"])
    app.terminate(); launch(reset: false); open("exchange")
    assertStored("exchange", contains: ["imported=1", "importedReviews=1", "pending=0", "pages=1"])
    capture("confirmed-new-namespace-readback")
  }

  func testPendingCopySurvivesRelaunchAndRequiresExplicitDiscard() {
    launch(reset: true); open("exchange")
    tap("qa-exchange-source")
    waitLabel("qa-exchange-state", contains: ["pending=1", "phase=ready", "previewNotes=1"])
    assertStored("exchange", contains: ["imported=0", "pending=1"])
    tap("close-vault-exchange")
    app.terminate(); launch(reset: false); open("exchange")
    waitLabel("qa-exchange-state", contains: ["pending=1", "phase=none"])
    let review = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "review-pending-import-")).firstMatch
    reveal(review); review.tap()
    waitLabel("qa-exchange-state", contains: ["phase=ready", "previewNotes=1"])
    let discard = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "discard-pending-import-")).firstMatch
    reveal(discard); discard.tap()
    let confirm = element("confirm-discard-pending-import")
    XCTAssertTrue(confirm.waitForExistence(timeout: 5))
    // Merely opening the dialog must not remove the pending copy.
    app.buttons["Cancel"].tap()
    waitLabel("qa-exchange-state", contains: ["pending=1", "phase=ready"])
    reveal(discard); discard.tap()
    XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
    waitLabel("qa-exchange-state", contains: ["pending=0", "phase=none"])
    assertStored("exchange", contains: ["imported=0", "pending=0"])
    capture("pending-copy-explicitly-discarded")
  }
}
