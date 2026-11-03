import XCTest
@testable import DayPageCore

final class NotebookCatalogTests: XCTestCase {
  private func entry(_ text: String, day: String = "2026-10-31", namespace: String = "", pinned: Bool = false,
                     attachments: [Memo.Attachment] = []) -> NotebookEntry {
    var memo = Memo(created: Date(timeIntervalSince1970: 1_793_347_200), attachments: attachments, body: text)
    if pinned { memo.pinnedAt = memo.created }
    return NotebookEntry(memo: memo, day: day, namespace: namespace)
  }

  func testGroupsThousandsOfNotesOnceWithoutDroppingImportedIdentities() {
    let entries = (0..<5000).map { index in
      entry("Thought \(index)", day: String(format: "2026-%02d-%02d", index % 12 + 1, index % 28 + 1),
            namespace: index.isMultiple(of: 2) ? "" : "old-vault")
    }
    let catalog = NotebookCatalog(entries: entries)
    let result = catalog.search()
    XCTAssertEqual(result.count, 5000)
    XCTAssertEqual(result.sections.flatMap(\.entries).count, 5000)
    XCTAssertEqual(Set(result.sections.flatMap(\.entries).map(\.id)).count, 5000)
    XCTAssertEqual(result.sections.map(\.day), result.sections.map(\.day).sorted(by: >))
    XCTAssertEqual(catalog.dayCounts.values.reduce(0, +), 5000)
  }

  func testSearchCombinesTranscriptDateKindAndTagAndTrimsWhitespace() {
    let voice = entry("Walk home #日常", pinned: true,
                      attachments: [.init(file: "voice.m4a", kind: "audio", transcript: "雨停了")])
    let other = entry("Rain #Ideas", day: "2026-10-30")
    let catalog = NotebookCatalog(entries: [other, voice])
    XCTAssertEqual(catalog.search(text: "  雨停了\n", kind: .voice, tag: "日常", day: "2026-10-31").count, 1)
    XCTAssertEqual(catalog.search(text: "2026-10-30").count, 1)
    XCTAssertEqual(catalog.search(kind: .pinned).sections.first?.entries.first?.id, voice.id)
    XCTAssertEqual(catalog.search(kind: .photos).count, 0)
    XCTAssertEqual(catalog.search(text: "  \n").count, 2)
    XCTAssertEqual(catalog.tags, ["Ideas", "日常"])
  }

  func testTagBoundariesAndEmptyCatalog() {
    let catalog = NotebookCatalog(entries: [entry("#idea #idea #日常 https://example.com/#ignored foo#ignored")])
    XCTAssertEqual(catalog.tags, ["idea", "日常"])
    XCTAssertEqual(catalog.search(tag: "ide").count, 0)
    XCTAssertTrue(NotebookCatalog(entries: []).search().sections.isEmpty)
  }

  func testSameMemoIDInDifferentImportedVaultsRemainsSelectable() {
    let original = entry("Same body")
    let imported = NotebookEntry(memo: original.memo, day: original.day, namespace: "imported")
    let result = NotebookCatalog(entries: [original, imported]).search()
    XCTAssertEqual(Set(result.sections.flatMap(\.entries).map(\.id)).count, 2)
  }

  func testDiaryKeepsHistoryAroundEmptySelectedDaysAndPinsWithinTheirOwnDay() {
    let older = entry("Older", day: "2026-09-30", pinned: true)
    let recent = entry("Recent", day: "2026-11-02")
    let pinned = entry("Pinned", day: "2026-11-02", pinned: true)
    let imported = NotebookEntry(memo: recent.memo, day: recent.day, namespace: "imported")
    let catalog = NotebookCatalog(entries: [recent, older, imported, pinned])
    let sections = catalog.diary(including: ["2026-11-03", "2026-10-01", "2026-11-03"])
    XCTAssertEqual(sections.map(\.day), ["2026-11-03", "2026-11-02", "2026-10-01", "2026-09-30"])
    XCTAssertTrue(sections[0].entries.isEmpty)
    XCTAssertEqual(sections[1].entries.first?.id, pinned.id)
    XCTAssertEqual(Set(sections.flatMap(\.entries).map(\.id)).count, 4)
    XCTAssertEqual(catalog.diary(including: []).flatMap(\.entries).count, 4)
    XCTAssertEqual(catalog.months.map(\.id), ["2026-11", "2026-09"])
    XCTAssertEqual(catalog.months.first?.latestDay, "2026-11-02")
    XCTAssertEqual(catalog.months.first?.noteCount, 3)
    XCTAssertEqual(catalog.months.first?.dayCount, 1)
  }

  func testDiaryEmptyNotebookAndMonthBoundaries() {
    XCTAssertEqual(NotebookCatalog(entries: []).diary(including: ["2026-01-01"]).map(\.day), ["2026-01-01"])
    XCTAssertTrue(NotebookCatalog(entries: []).months.isEmpty)
    let catalog = NotebookCatalog(entries: [
      entry("New year", day: "2026-01-01"), entry("Last year", day: "2025-12-31"),
      entry("Earlier December", day: "2025-12-01")
    ])
    XCTAssertEqual(catalog.months.map(\.id), ["2026-01", "2025-12"])
    XCTAssertEqual(catalog.months.last?.dayCount, 2)
    XCTAssertEqual(catalog.months.last?.latestDay, "2025-12-31")
    XCTAssertEqual(catalog.diary(including: []).map(\.day), ["2026-01-01", "2025-12-31", "2025-12-01"])
  }
}
