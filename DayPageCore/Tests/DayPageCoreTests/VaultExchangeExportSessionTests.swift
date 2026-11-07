import XCTest
@testable import DayPageCore

final class VaultExchangeExportSessionTests: XCTestCase {
  private func selection(_ scope: String = "all", date: Date = Date(timeIntervalSince1970: 1_793_500_000)) throws -> VaultExchangeExportSelection {
    try .init(scope: scope, date: date, timeZone: .gmt)
  }
  private func snapshot() async throws -> VaultExchangeSnapshot {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("export-authority-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    try await store.append(Memo(body: "Synthetic private notebook source"))
    return try await store.exchangeSnapshot()
  }

  func testChangingAllToDayWhileReadIsSuspendedRejectsLateWholeNotebookPreview() async throws {
    let bytes = try await snapshot(), gate = ExchangeExportGate(), old = try selection()
    let session = VaultExchangeExportSession { _ in await gate.read() }
    let ticket = session.begin(old), pending = Task { try await session.prepare(ticket) }
    await gate.started()
    // This is the synchronous scope-binding action, without relying on a
    // disabled Picker or a reader's cooperation with Task cancellation.
    session.invalidate()
    _ = session.begin(try selection("day"))
    await gate.finish(bytes)
    do { _ = try await pending.value; XCTFail("Old full-notebook data must not refill a day preview") }
    catch VaultExchangeError.changed { }
  }

  func testChangingDateWhileReadIsSuspendedRejectsLateOldDayPreview() async throws {
    let bytes = try await snapshot(), gate = ExchangeExportGate(), old = try selection("day")
    let session = VaultExchangeExportSession { _ in await gate.read() }
    let ticket = session.begin(old), pending = Task { try await session.prepare(ticket) }
    await gate.started()
    session.invalidate()
    _ = session.begin(try selection("day", date: old.date.addingTimeInterval(86_400)))
    await gate.finish(bytes)
    do { _ = try await pending.value; XCTFail("An older date may not restore a stale destination action") }
    catch VaultExchangeError.changed { }
  }

  func testRevocationBeforeActorStartsCannotBeResurrectedByQueuedRead() async throws {
    let calls = ExchangeExportCalls(), bytes = try await snapshot()
    let session = VaultExchangeExportSession { _ in await calls.increment(); return bytes }
    let ticket = session.begin(try selection())
    session.invalidate()
    do { _ = try await session.prepare(ticket); XCTFail() } catch VaultExchangeError.changed { }
    let count = await calls.count; XCTAssertEqual(count, 0)
  }

  func testPreparedPreviewLosesDestinationAuthorityOnDateScopeCancelOrNewRequest() async throws {
    let bytes = try await snapshot(), original = try selection("day")
    let session = VaultExchangeExportSession { _ in bytes }
    let preview = try await session.prepare(session.begin(original))
    XCTAssertTrue(session.canExport(preview, selection: original))
    XCTAssertFalse(session.canExport(preview, selection: try selection("all")))
    XCTAssertFalse(session.canExport(preview, selection: try selection("day", date: original.date.addingTimeInterval(86_400))))
    session.invalidate(); XCTAssertFalse(session.isCurrent(preview))
    let current = try await session.prepare(session.begin(original))
    XCTAssertFalse(session.isCurrent(preview)); XCTAssertTrue(session.isCurrent(current))
    _ = session.begin(original) // Even the same date/range is a new request.
    XCTAssertFalse(session.isCurrent(current))
  }

  func testDefaultReaderUsesSelectedDayInsteadOfEntireNotebookAndPreservesSource() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("export-scope-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    let first = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-07T12:00:00Z"))
    try await store.append(Memo(created: first, body: "Selected day"))
    try await store.append(Memo(created: first.addingTimeInterval(2 * 86_400), body: "Other day"))
    let session = VaultExchangeExportSession(store: store)
    let all = try await session.prepare(session.begin(selection("all", date: first)))
    XCTAssertEqual(all.snapshot.records.notes.count, 2)
    let day = try await session.prepare(session.begin(selection("day", date: first)))
    XCTAssertEqual(day.snapshot.records.notes.map(\.body), ["Selected day"])
    XCTAssertFalse(session.isCurrent(all)); XCTAssertTrue(session.isCurrent(day))
    let source = try await store.entries(); XCTAssertEqual(source.count, 2)
  }
}

private actor ExchangeExportCalls {
  var count = 0
  func increment() { count += 1 }
}

/// Deliberately ignores cancellation, like a provider completing a queued read.
private actor ExchangeExportGate {
  private var continuation: CheckedContinuation<VaultExchangeSnapshot, Never>?
  private var waiter: CheckedContinuation<Void, Never>?
  func read() async -> VaultExchangeSnapshot {
    await withCheckedContinuation { continuation in
      self.continuation = continuation; waiter?.resume(); waiter = nil
    }
  }
  func started() async {
    if continuation != nil { return }
    await withCheckedContinuation { waiter = $0 }
  }
  func finish(_ snapshot: VaultExchangeSnapshot) { continuation?.resume(returning: snapshot); continuation = nil }
}
