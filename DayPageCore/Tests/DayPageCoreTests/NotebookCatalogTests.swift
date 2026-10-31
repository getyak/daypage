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
}
