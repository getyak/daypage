import XCTest
@testable import DayPageCore

final class ManualReviewTests: XCTestCase {
  private func date(_ value: String = "2026-11-07T02:03:04Z") throws -> Date {
    try XCTUnwrap(ISO8601DateFormatter().date(from: value))
  }
  private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("review-\(UUID())") }
  private var configuration: AIConfiguration { AIConfiguration(baseURL: "https://ai.example.invalid", model: "synthetic") }
  private func snapshot(_ store: NotebookStore, kind: ReviewPeriod.Kind = .day) async throws -> ManualReviewSnapshot {
    let entries = try await store.entries()
    let period = try ReviewPeriod(kind: kind, anchor: date(), timeZone: XCTUnwrap(TimeZone(identifier: "Asia/Shanghai")))
    return try .make(period: period, entries: entries, selectedIDs: Set(entries.map(\.id)))
  }

  func testLocalDayAndMondayWeekRespectDSTAndExclusiveEnd() throws {
    let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
    let day = try ReviewPeriod(kind: .day, anchor: date("2026-03-08T16:00:00Z"), timeZone: zone)
    XCTAssertEqual(day.end.timeIntervalSince(day.start), 23 * 3600)
    XCTAssertEqual(day.firstDay, "2026-03-08")
    XCTAssertTrue(day.contains(day.start)); XCTAssertFalse(day.contains(day.end))
    let week = try ReviewPeriod(kind: .week, anchor: date("2026-03-08T16:00:00Z"), timeZone: zone)
    XCTAssertEqual(week.firstDay, "2026-03-02"); XCTAssertEqual(week.lastDay, "2026-03-08")
    XCTAssertEqual(week.end.timeIntervalSince(week.start), 167 * 3600)
  }

  func testExactSelectedTextExcludesOtherNotesAttachmentTranscriptsAndMetadata() async throws {
    let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    let memo = Memo(created: try date(), location: .init(name: "Excluded place"),
      attachments: [.init(file: "raw/assets/absent.wav", kind: "audio", transcript: "Excluded transcript")], body: "Selected text")
    try await store.append(memo)
    try await store.append(Memo(created: date(), body: "Excluded note"))
    let entries = try await store.entries(), selected = try XCTUnwrap(entries.first { $0.memo.id == memo.id })
    let period = try ReviewPeriod(kind: .day, anchor: date(), timeZone: .gmt)
    let value = try ManualReviewSnapshot.make(period: period, entries: entries, selectedIDs: [selected.id])
    XCTAssertTrue(value.contextText.contains("Selected text"))
    for excluded in ["Excluded place", "Excluded transcript", "Excluded note", "absent.wav"] {
      XCTAssertFalse(value.contextText.contains(excluded))
    }
    XCTAssertEqual(value.citations.map(\.revision), [selected.revision])
  }

  func testOverLimitAndMissingSourcesFailWithoutTruncation() throws {
    let period = try ReviewPeriod(kind: .day, anchor: date(), timeZone: .gmt)
    let entries = try (0..<13).map { NotebookEntry(memo: Memo(created: date(), body: "Source \($0)"), day: "2026-11-07") }
    XCTAssertThrowsError(try ManualReviewSnapshot.make(period: period, entries: entries, selectedIDs: Set(entries.map(\.id))))
    XCTAssertThrowsError(try ManualReviewSnapshot.make(period: period, entries: entries, selectedIDs: ["missing"]))
    let long = NotebookEntry(memo: Memo(created: try date(), body: String(repeating: "字", count: 18_001)), day: "2026-11-07")
    XCTAssertThrowsError(try ManualReviewSnapshot.make(period: period, entries: [long], selectedIDs: [long.id]))
  }

  func testConsentAndInvalidConfigurationNeverInvokeGenerator() async throws {
    let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root); try await store.append(Memo(created: date(), body: "Synthetic source"))
    let value = try await snapshot(store), calls = ReviewCalls()
    let session = ManualReviewSession(store: store) { _, _, _ in await calls.increment(); return "Review" }
    do { _ = try await session.generate(snapshot: value, configuration: configuration, apiKey: "", enabled: false); XCTFail() }
    catch ManualReviewError.consent { }
    do { _ = try await session.generate(snapshot: value, configuration: AIConfiguration(), apiKey: "", enabled: true); XCTFail() }
    catch { }
    let count = await calls.count; XCTAssertEqual(count, 0)
  }

  func testSaveIsIndependentReopenableAndIdempotentWithoutChangingRawOrDraft() async throws {
    let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root); try await store.append(Memo(created: date(), body: "Source"))
    let value = try await snapshot(store), raw = root.appendingPathComponent("raw/2026-11-07.md")
    let bytes = try Data(contentsOf: raw), draft = root.appendingPathComponent(".daypage/capture.json")
    try FileManager.default.createDirectory(at: draft.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("Unfinished capture".utf8).write(to: draft)
    let session = ManualReviewSession(store: store) { _, _, _ in "## Highlights\nSynthetic review [S1]" }
    let generated = try await session.generate(snapshot: value, configuration: configuration, apiKey: "", enabled: true)
    let page = try await session.save(generated, editedBody: generated.body)
    let retry = try await session.save(generated, editedBody: generated.body)
    XCTAssertEqual(page, retry)
    let reopened = try await NotebookStore(root: root).manualReviews()
    XCTAssertEqual(reopened.map(\.page), [page]); XCTAssertEqual(try Data(contentsOf: raw), bytes)
    XCTAssertEqual(try String(contentsOf: draft), "Unfinished capture")
    let notes = try await store.entries(); XCTAssertEqual(notes.count, 1)
    XCTAssertEqual(try ManualReviewPage.decode(page.encoded()), page)
  }

  func testSourceChangedBeforeSendDoesNotInvokeGenerator() async throws {
    let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root); try await store.append(Memo(created: date(), body: "Before"))
    let value = try await snapshot(store), calls = ReviewCalls()
    try await store.update(XCTUnwrap(value.entries.first), body: "After")
    let session = ManualReviewSession(store: store) { _, _, _ in await calls.increment(); return "Review" }
    do { _ = try await session.generate(snapshot: value, configuration: configuration, apiKey: "", enabled: true); XCTFail() }
    catch ManualReviewError.changed { }
    let count = await calls.count; XCTAssertEqual(count, 0)
  }

  func testSourceChangedDuringRequestRejectsLateResult() async throws {
    let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root); try await store.append(Memo(created: date(), body: "Before"))
    let value = try await snapshot(store), gate = ReviewGate()
    let session = ManualReviewSession(store: store) { _, _, _ in await gate.run() }
    let config = configuration
    let request = Task { try await session.generate(snapshot: value, configuration: config, apiKey: "", enabled: true) }
    await gate.started()
    try await store.update(XCTUnwrap(value.entries.first), body: "Changed while requesting")
    await gate.finish("Late review")
    do { _ = try await request.value; XCTFail() } catch ManualReviewError.changed { }
    let pages = try await store.manualReviews(); XCTAssertTrue(pages.isEmpty)
  }

  func testCancelRevokesGeneratorThatIgnoresTaskCancellation() async throws {
    let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root); try await store.append(Memo(created: date(), body: "Source"))
    let value = try await snapshot(store), gate = ReviewGate()
    let session = ManualReviewSession(store: store) { _, _, _ in await gate.run() }
    let config = configuration
    let request = Task { try await session.generate(snapshot: value, configuration: config, apiKey: "", enabled: true) }
    await gate.started(); session.cancel(); await gate.finish("Ignored late output")
    do { _ = try await request.value; XCTFail() } catch ManualReviewError.revoked { }
    let pages = try await store.manualReviews(); XCTAssertTrue(pages.isEmpty)
  }

  func testNewRequestRevokesEarlierDraftAndCancellationRevokesSave() async throws {
    let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root); try await store.append(Memo(created: date(), body: "Source"))
    let value = try await snapshot(store)
    let session = ManualReviewSession(store: store) { _, _, _ in "Review" }
    let old = try await session.generate(snapshot: value, configuration: configuration, apiKey: "", enabled: true)
    let current = try await session.generate(snapshot: value, configuration: configuration, apiKey: "", enabled: true)
    do { _ = try await session.save(old, editedBody: old.body); XCTFail() } catch ManualReviewError.revoked { }
    session.cancel()
    do { _ = try await session.save(current, editedBody: current.body); XCTFail() } catch ManualReviewError.revoked { }
  }

  func testSourceChangedBeforeSaveAndSameIdentityCollisionPreserveFiles() async throws {
    let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root); try await store.append(Memo(created: date(), body: "Before"))
    let value = try await snapshot(store)
    let session = ManualReviewSession(store: store) { _, _, _ in "Review" }
    let draft = try await session.generate(snapshot: value, configuration: configuration, apiKey: "", enabled: true)
    try await store.update(XCTUnwrap(value.entries.first), body: "After")
    do { _ = try await session.save(draft, editedBody: draft.body); XCTFail() } catch ManualReviewError.changed { }
    let pages = try await store.manualReviews(); XCTAssertTrue(pages.isEmpty)
    let fresh = try await snapshot(store)
    let next = try await session.generate(snapshot: fresh, configuration: configuration, apiKey: "", enabled: true)
    let pagePath = root.appendingPathComponent("wiki/manual-reviews/\(next.id.uuidString).md")
    try Data("Different existing page".utf8).write(to: pagePath)
    do { _ = try await session.save(next, editedBody: next.body); XCTFail() } catch ManualReviewError.conflict { }
    XCTAssertEqual(try String(contentsOf: pagePath), "Different existing page")
  }

  func testPageCodecRejectsTamperedBodyAndKeepsSourceReferences() async throws {
    let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root); try await store.append(Memo(created: date(), body: "Source"))
    let value = try await snapshot(store)
    let page = ManualReviewPage(id: UUID(), created: try date(), snapshot: value, body: "Saved body")
    let bytes = try page.encoded(), text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
    XCTAssertTrue(text.contains("../../raw/2026-11-07.md"))
    XCTAssertThrowsError(try ManualReviewPage.decode(Data(text.replacingOccurrences(of: "Saved body", with: "Other body").utf8)))
    XCTAssertEqual(try ManualReviewPage.decode(bytes).citations, value.citations)
  }
}

private actor ReviewCalls {
  var count = 0
  func increment() { count += 1 }
}

/// The fake intentionally ignores cancellation so the session's authority fence
/// is exercised, rather than relying on a cooperative network implementation.
private actor ReviewGate {
  private var continuation: CheckedContinuation<String, Never>?
  private var waiter: CheckedContinuation<Void, Never>?
  func run() async -> String {
    await withCheckedContinuation { continuation in
      self.continuation = continuation; waiter?.resume(); waiter = nil
    }
  }
  func started() async {
    if continuation != nil { return }
    await withCheckedContinuation { waiter = $0 }
  }
  func finish(_ text: String) { continuation?.resume(returning: text); continuation = nil }
}
