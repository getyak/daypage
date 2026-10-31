import XCTest

final class CalendarUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launchArguments = [
            "-qaNotebookSession", "-qaResetNotebook", "-qaSeedNotebook",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func testRecordCountsCancelAndExactEmptyDayCommit() throws {
        app.launch()
        let chooser = app.buttons["choose-date"]
        XCTAssertTrue(chooser.waitForExistence(timeout: 10))
        let original = try XCTUnwrap(chooser.value as? String)
        XCTAssertEqual(original.count, 10)
        let emptyDay = String(original.prefix(8)) + (original.hasSuffix("01") ? "02" : "01")

        chooser.tap()
        XCTAssertTrue(element("notebook-date-picker").waitForExistence(timeout: 5))
        XCTAssertEqual(element("calendar-selected-count").label, "3 notes")
        XCTAssertTrue(app.buttons["calendar-day-\(original)"].label.contains("3 notes"))
        app.buttons["calendar-day-\(emptyDay)"].tap()
        XCTAssertEqual(element("calendar-selected-count").label, "0 notes")
        app.buttons["calendar-cancel"].tap()
        XCTAssertEqual(chooser.value as? String, original)

        chooser.tap()
        XCTAssertTrue(element("calendar-selected-count").waitForExistence(timeout: 5))
        XCTAssertEqual(element("calendar-selected-count").label, "3 notes")
        app.buttons["calendar-day-\(emptyDay)"].tap()
        app.buttons["calendar-done"].tap()
        XCTAssertEqual(chooser.value as? String, emptyDay)

        chooser.tap()
        XCTAssertTrue(app.buttons["calendar-today"].waitForExistence(timeout: 5))
        app.buttons["calendar-today"].tap()
        XCTAssertEqual(element("calendar-selected-count").label, "3 notes")
        app.buttons["calendar-done"].tap()
        XCTAssertEqual(chooser.value as? String, original)
    }

    func testLargeTextMonthNavigationRetainsSelectionUntilDone() throws {
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        let chooser = app.buttons["choose-date"]
        XCTAssertTrue(chooser.waitForExistence(timeout: 10))
        let original = try XCTUnwrap(chooser.value as? String)
        chooser.tap()
        XCTAssertTrue(app.buttons["calendar-previous-month"].waitForExistence(timeout: 5))
        app.buttons["calendar-previous-month"].tap()
        app.buttons["calendar-next-month"].tap()
        let originalDay = app.buttons["calendar-day-\(original)"]
        if !originalDay.isHittable { element("notebook-date-picker").swipeUp() }
        XCTAssertTrue(originalDay.exists)
        XCTAssertTrue(app.buttons["calendar-cancel"].isHittable)
        XCTAssertTrue(app.buttons["calendar-done"].isHittable)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "record-aware-calendar-large-text"
        image.lifetime = .keepAlways
        add(image)
        app.buttons["calendar-done"].tap()
        XCTAssertEqual(chooser.value as? String, original)
    }
}
