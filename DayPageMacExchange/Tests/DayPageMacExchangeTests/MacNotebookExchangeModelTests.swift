import DayPageCore
import XCTest
@testable import DayPageMacExchange

@MainActor
final class MacNotebookExchangeModelTests: XCTestCase {
  private let fm = FileManager.default
  private func folder() -> URL { fm.temporaryDirectory.appendingPathComponent("mac-exchange-\(UUID())") }
  private func date() throws -> Date { try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-07T12:00:00Z")) }
  private func rawDay(_ root: URL) async throws -> String {
    let entries = try await NotebookStore(root: root).entries()
    return try XCTUnwrap(entries.first).day
  }
  private func source(_ root: URL, memoID: UUID = UUID(), assets: Bool = false) async throws -> NotebookStore {
    let store = NotebookStore(root: root)
    let memo = Memo(id: memoID, created: try date(), body: "Synthetic Mac exchange note")
    if assets { try await store.append(memo, assets: [.init(data: Data("Synthetic text attachment".utf8), fileExtension: "txt", kind: "file")]) }
    else { try await store.append(memo) }
    return store
  }

  func testOpeningManagedConsumerNeverResolvesOrReadsLegacyVault() async throws {
    let managed = folder(), legacy = folder()
    defer { for p in [managed, legacy] { try? fm.removeItem(at: p) } }
    var legacyReads = 0
    let model = MacNotebookExchangeModel(managedRoot: managed, legacyVault: { legacyReads += 1; return legacy })
    model.refresh(); await model.waitUntilIdle()
    XCTAssertEqual(legacyReads, 0); XCTAssertTrue(model.entries.isEmpty); XCTAssertTrue(model.pending.isEmpty)
    XCTAssertFalse(fm.fileExists(atPath: legacy.path))
  }

  func testChooseOnlyPreviewsThenConfirmMakesImportedAttachmentNoteVisibleAndSelectable() async throws {
    let managed = folder(), legacy = folder(), chosen = folder()
    defer { for p in [managed, legacy, chosen] { try? fm.removeItem(at: p) } }
    _ = try await source(chosen, assets: true)
    let day = try await rawDay(chosen)
    let raw = chosen.appendingPathComponent("raw/\(day).md"), before = try Data(contentsOf: raw)
    try Data("Synthetic runtime sidecar".utf8).write(to: chosen.appendingPathComponent("runtime.json"))
    var legacyReads = 0
    let model = MacNotebookExchangeModel(managedRoot: managed, legacyVault: { legacyReads += 1; return legacy })
    model.receive(chosen); await model.waitUntilIdle()
    XCTAssertTrue(model.entries.isEmpty); XCTAssertEqual(model.pending.count, 1)
    XCTAssertEqual(model.importPreview?.notes.first?.body, "Synthetic Mac exchange note")
    model.confirmImport(); await model.waitUntilIdle()
    let entry = try XCTUnwrap(model.entries.first)
    XCTAssertFalse(entry.namespace.isEmpty); XCTAssertEqual(model.selectedEntry?.id, entry.id)
    XCTAssertEqual(entry.memo.attachments.count, 1); XCTAssertTrue(model.pending.isEmpty)
    model.previewAttachment(try XCTUnwrap(entry.memo.attachments.first), entry: entry); await model.waitUntilIdle()
    let preview = try XCTUnwrap(model.previewURL)
    XCTAssertTrue(preview.resolvingSymlinksInPath().path.hasPrefix(managed.resolvingSymlinksInPath().path + "/"))
    XCTAssertEqual(try String(contentsOf: preview), "Synthetic text attachment")
    XCTAssertEqual(try Data(contentsOf: raw), before); XCTAssertEqual(legacyReads, 0)
    XCTAssertFalse(fm.fileExists(atPath: managed.appendingPathComponent("imports/\(entry.namespace)/runtime.json").path))
  }

  func testSameMemoUUIDInCurrentAndNewNamespaceIsNotHiddenOrOverwritten() async throws {
    let managed = folder(), chosen = folder(), id = UUID()
    defer { for p in [managed, chosen] { try? fm.removeItem(at: p) } }
    _ = try await source(managed, memoID: id); _ = try await source(chosen, memoID: id)
    let day = try await rawDay(managed)
    let raw = managed.appendingPathComponent("raw/\(day).md"), before = try Data(contentsOf: raw)
    let model = MacNotebookExchangeModel(managedRoot: managed, legacyVault: { chosen })
    model.receive(chosen); await model.waitUntilIdle(); model.confirmImport(); await model.waitUntilIdle()
    XCTAssertEqual(model.entries.count, 2); XCTAssertEqual(Set(model.entries.map(\.id)).count, 2)
    XCTAssertTrue(model.entries.contains { $0.namespace.isEmpty }); XCTAssertTrue(model.entries.contains { !$0.namespace.isEmpty })
    XCTAssertEqual(try Data(contentsOf: raw), before)
  }

  func testPendingInterruptionReopensAndResumesInTheActualConsumer() async throws {
    let managed = folder(), chosen = folder()
    defer { for p in [managed, chosen] { try? fm.removeItem(at: p) } }
    _ = try await source(chosen)
    let first = MacNotebookExchangeModel(managedRoot: managed, legacyVault: { chosen })
    first.receive(chosen); await first.waitUntilIdle()
    let job = try XCTUnwrap(first.selectedImport)
    let day = try await rawDay(chosen)
    let raw = managed.appendingPathComponent(".daypage/exchange-imports-v1/\(job.id.uuidString)/vault/raw/\(day).md")
    try Data("Synthetic interrupted copy".utf8).write(to: raw)
    let reopened = MacNotebookExchangeModel(managedRoot: managed, legacyVault: { chosen })
    reopened.refresh(); await reopened.waitUntilIdle()
    XCTAssertEqual(reopened.pending.map(\.phase), [.needsSource]); XCTAssertTrue(reopened.entries.isEmpty)
    reopened.receive(chosen, resuming: try XCTUnwrap(reopened.pending.first)); await reopened.waitUntilIdle()
    XCTAssertEqual(reopened.selectedImport?.phase, .ready)
    reopened.confirmImport(); await reopened.waitUntilIdle()
    XCTAssertEqual(reopened.entries.count, 1); XCTAssertTrue(reopened.pending.isEmpty)
  }

  func testExplicitDiscardTouchesOnlyPendingCopyAndCollisionDoesNotReplaceUserFiles() async throws {
    let managed = folder(), chosen = folder()
    defer { for p in [managed, chosen] { try? fm.removeItem(at: p) } }
    _ = try await source(chosen)
    let model = MacNotebookExchangeModel(managedRoot: managed, legacyVault: { chosen })
    model.receive(chosen); await model.waitUntilIdle()
    let job = try XCTUnwrap(model.selectedImport), collision = managed.appendingPathComponent("imports/\(job.id.uuidString)")
    try fm.createDirectory(at: collision, withIntermediateDirectories: true)
    try Data("Existing user file".utf8).write(to: collision.appendingPathComponent("keep.txt"))
    model.confirmImport(); await model.waitUntilIdle()
    XCTAssertNotNil(model.message); XCTAssertTrue(model.entries.isEmpty)
    XCTAssertEqual(try String(contentsOf: collision.appendingPathComponent("keep.txt")), "Existing user file")
    model.discard(job); await model.waitUntilIdle()
    XCTAssertTrue(model.pending.isEmpty)
    XCTAssertEqual(try String(contentsOf: collision.appendingPathComponent("keep.txt")), "Existing user file")
    let day = try await rawDay(chosen)
    XCTAssertTrue(fm.fileExists(atPath: chosen.appendingPathComponent("raw/\(day).md").path))
  }

  func testLegacyExportIsExplicitReadOnlyAndManagedExportUsesADifferentRoot() async throws {
    let managed = folder(), legacy = folder()
    defer { for p in [managed, legacy] { try? fm.removeItem(at: p) } }
    let oldStore = try await source(legacy), oldEntries = try await oldStore.entries()
    try await oldStore.update(XCTUnwrap(oldEntries.first), body: "Legacy source only")
    _ = try await source(managed)
    let day = try await rawDay(legacy)
    let raw = legacy.appendingPathComponent("raw/\(day).md"), before = try Data(contentsOf: raw)
    var reads = 0
    let model = MacNotebookExchangeModel(managedRoot: managed, legacyVault: { reads += 1; return legacy })
    model.prepareExport(source: .managed, scope: "all", date: try date()); await model.waitUntilIdle()
    XCTAssertEqual(reads, 0); XCTAssertEqual(model.outgoing?.snapshot.records.notes.first?.body, "Synthetic Mac exchange note")
    model.prepareExport(source: .legacy, scope: "all", date: try date()); await model.waitUntilIdle()
    XCTAssertEqual(reads, 1); XCTAssertEqual(model.outgoing?.snapshot.records.notes.first?.body, "Legacy source only")
    XCTAssertNil(model.exportAuthority(source: .managed, scope: "all", date: try date()))
    XCTAssertEqual(try Data(contentsOf: raw), before)
  }

  func testScopeChangeRejectsNoncooperativeLateWholeNotebookResult() async throws {
    let managed = folder(), chosen = folder()
    defer { for p in [managed, chosen] { try? fm.removeItem(at: p) } }
    let store = try await source(chosen), snapshot = try await store.exchangeSnapshot(), gate = MacExportGate()
    let model = MacNotebookExchangeModel(managedRoot: managed, legacyVault: { chosen }, exporter: { _, _ in await gate.read() })
    let request = model.prepareExport(source: .legacy, scope: "all", date: try date())
    await gate.started()
    model.clearExport() // The exact synchronous source/range/date binding path.
    await gate.finish(snapshot); await request?.value
    XCTAssertNil(model.outgoing); XCTAssertFalse(model.busy)
    XCTAssertNil(model.exportAuthority(source: .legacy, scope: "day", date: try date()))
  }

  func testImportedReviewHistoryAndSourceLinksAreReadInTheMacConsumer() async throws {
    let managed = folder(), chosen = folder()
    defer { for p in [managed, chosen] { try? fm.removeItem(at: p) } }
    let store = try await source(chosen), entries = try await store.entries()
    let period = try ReviewPeriod(kind: .day, anchor: date(), timeZone: .gmt)
    let snapshot = try ManualReviewSnapshot.make(period: period, entries: entries, selectedIDs: Set(entries.map(\.id)))
    let session = ManualReviewSession(store: store) { _, _, _ in "Synthetic saved review" }
    let draft = try await session.generate(snapshot: snapshot, configuration: AIConfiguration(baseURL: "https://ai.example.invalid", model: "synthetic"), apiKey: "", enabled: true)
    _ = try await session.save(draft, editedBody: draft.body)
    let model = MacNotebookExchangeModel(managedRoot: managed, legacyVault: { chosen })
    model.receive(chosen); await model.waitUntilIdle(); model.confirmImport(); await model.waitUntilIdle()
    let page = try XCTUnwrap(model.reviews.first), citation = try XCTUnwrap(page.page.citations.first)
    model.selectReview(page)
    XCTAssertEqual(model.selectedReview?.page.body, "Synthetic saved review")
    let source = try XCTUnwrap(model.sourceEntry(citation, page: page))
    XCTAssertEqual(source.revision, citation.revision)
    model.selectEntry(source); XCTAssertEqual(model.selectedEntry?.memo.body, "Synthetic Mac exchange note")
    let saved = managed.appendingPathComponent("imports/\(page.namespace)/wiki/manual-reviews/\(page.page.id.uuidString).md")
    try Data("Synthetic damaged review header".utf8).write(to: saved)
    model.refresh(); await model.waitUntilIdle()
    XCTAssertEqual(model.entries.count, 1, "A damaged review must not hide an otherwise published notebook")
    XCTAssertTrue(model.reviews.isEmpty); XCTAssertNotNil(model.reviewWarning)
  }
}

private actor MacExportGate {
  private var continuation: CheckedContinuation<VaultExchangeSnapshot, Never>?
  private var waiter: CheckedContinuation<Void, Never>?
  func read() async -> VaultExchangeSnapshot {
    await withCheckedContinuation { continuation in self.continuation = continuation; waiter?.resume(); waiter = nil }
  }
  func started() async {
    if continuation != nil { return }
    await withCheckedContinuation { waiter = $0 }
  }
  func finish(_ value: VaultExchangeSnapshot) { continuation?.resume(returning: value); continuation = nil }
}
