import XCTest
import Darwin
@testable import DayPageCore

final class VaultExchangeTests: XCTestCase {
  private let fm = FileManager.default
  private func folder() -> URL { fm.temporaryDirectory.appendingPathComponent("exchange-\(UUID())") }
  private func date() throws -> Date { try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-07T02:03:04Z")) }
  private func write(_ snapshot: VaultExchangeSnapshot, to folder: URL) throws {
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    for (path, data) in snapshot.files {
      let target = folder.appendingPathComponent(path)
      try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: target)
    }
    try ReplicaDigest.encode(snapshot.manifest).write(to: folder.appendingPathComponent("daypage-exchange.json"))
  }
  private func synthetic(_ root: URL, withAsset: Bool = false) async throws -> NotebookStore {
    let store = NotebookStore(root: root)
    if withAsset {
      try await store.append(Memo(created: date(), location: .init(name: "Synthetic place"), mood: "calm",
        entityMentions: ["Synthetic"], body: "Synthetic source"),
        assets: [.init(data: Data("Synthetic attachment".utf8), fileExtension: "txt", kind: "file")])
    } else { try await store.append(Memo(created: date(), body: "Synthetic source")) }
    return store
  }
  private func rebuilt(_ original: VaultExchangeSnapshot, records: ExchangeRecords? = nil,
    replacing: [String: Data] = [:]) throws -> VaultExchangeSnapshot {
    var files = original.files
    for (path, data) in replacing { files[path] = data }
    let projection = records ?? original.records
    files["records.json"] = try ReplicaDigest.encode(projection)
    let listing = try files.map { ExchangeFile(path: $0.key, bytes: $0.value.count,
      sha256: ReplicaDigest.hash($0.value), kind: try ExchangePath.kind($0.key)) }
    return VaultExchangeSnapshot(manifest: VaultExchangeManifest(notes: projection.notes.count, reviews: projection.reviews.count, files: listing),
      records: projection, files: files)
  }

  func testFrozenCrossClientFixtureHasExpectedDigestAndExactRawProjection() throws {
    let folder = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
      .appendingPathComponent("file-exchange-v1")
    let snapshot = try ExchangeIO.loadV1(folder)
    XCTAssertEqual(snapshot.manifest.contentSHA256, "89d0622ad0956166629ee3a13c2c86a7755f0fde85267176891aee1d4ccb862d")
    XCTAssertEqual(snapshot.records.notes.first?.revision, "0111563f6e9f1994365b05ea4da9fcbea06ed0479dbe57de0b8cdf817069663b")
    try NotebookStore.validateExchangeProjection(snapshot)
  }

  func testExportRoundTripsUnknownYAMLAndReferencedAttachmentButNotPrivateSidecars() async throws {
    let root = folder(), exported = folder(), target = folder()
    defer { for path in [root, exported, target] { try? fm.removeItem(at: path) } }
    let store = try await synthetic(root, withAsset: true)
    let raw = root.appendingPathComponent("raw/2026-11-07.md")
    let original = try String(contentsOf: raw).replacingOccurrences(of: "type: mixed", with: "type: mixed\nfuture_field: retained")
    try original.write(to: raw, atomically: true, encoding: .utf8)
    let privatePath = root.appendingPathComponent(".daypage/chat.json")
    try fm.createDirectory(at: privatePath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("Synthetic private chat".utf8).write(to: privatePath)
    let snapshot = try await store.exchangeSnapshot()
    XCTAssertEqual(snapshot.files["raw/2026-11-07.md"], Data(original.utf8))
    XCTAssertFalse(snapshot.files.keys.contains { $0.hasPrefix(".daypage") })
    XCTAssertEqual(snapshot.records.notes.first?.attachments.count, 1)
    try write(snapshot, to: exported)
    let coordinator = VaultExchangeImport(root: target)
    let pending = try await coordinator.prepare(from: exported)
    let before = try await NotebookStore(root: target).entries(); XCTAssertTrue(before.isEmpty)
    let preview = try await coordinator.preview(pending); XCTAssertEqual(preview, snapshot.records)
    let namespace = try await coordinator.confirm(pending)
    let entries = try await NotebookStore(root: target).entries()
    XCTAssertEqual(entries.count, 1); XCTAssertEqual(entries.first?.namespace, namespace)
    XCTAssertEqual(entries.first?.revision, snapshot.records.notes.first?.revision)
    XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("imports/\(namespace)/raw/2026-11-07.md")), Data(original.utf8))
    XCTAssertEqual(try String(contentsOf: privatePath), "Synthetic private chat")
  }

  func testWholeFileHashCannotSubstituteForPerMemoRevisionAndFalseTypedBodyIsRejected() async throws {
    let root = folder(); defer { try? fm.removeItem(at: root) }
    let store = try await synthetic(root)
    try await store.append(Memo(created: date(), body: "Second source"))
    let snapshot = try await store.exchangeSnapshot()
    let raw = try XCTUnwrap(snapshot.files["raw/2026-11-07.md"])
    XCTAssertTrue(snapshot.records.notes.allSatisfy { $0.revision != ReplicaDigest.hash(raw) })
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: ReplicaDigest.encode(snapshot.records)) as? [String: Any])
    var notes = try XCTUnwrap(json["notes"] as? [[String: Any]])
    notes[0]["body"] = "A forged typed body that does not exist in raw"
    json["notes"] = notes
    let altered = try ExchangeRecords.decode(JSONSerialization.data(withJSONObject: json))
    let forged = try rebuilt(snapshot, records: altered)
    try forged.validated() // Valid hashes alone are insufficient.
    XCTAssertThrowsError(try NotebookStore.validateExchangeProjection(forged))
  }

  func testVersionUnknownFieldsNullHashTraversalAndAliasAreRejected() async throws {
    let root = folder(); defer { try? fm.removeItem(at: root) }
    let store = try await synthetic(root), snapshot = try await store.exchangeSnapshot()
    let encoded = try ReplicaDigest.encode(snapshot.manifest)
    let mutations: [(inout [String: Any]) -> Void] = [
      { $0["version"] = 2 }, { $0["owner"] = "unexpected" }, { $0["created_at"] = NSNull() },
      { $0["content_sha256"] = String(repeating: "0", count: 64) }
    ]
    for mutation in mutations {
      var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any]); mutation(&object)
      XCTAssertThrowsError(try VaultExchangeManifest.decode(JSONSerialization.data(withJSONObject: object)))
    }
    for path in ["../raw/2026-11-07.md", "/raw/2026-11-07.md", "raw/../raw/2026-11-07.md", "raw\\asset.txt", "imports/not-a-uuid/raw/2026-11-07.md"] {
      XCTAssertThrowsError(try ExchangePath.kind(path))
    }
    let one = ExchangeFile(path: "raw/assets/A.txt", bytes: 1, sha256: ReplicaDigest.hash(Data([1])), kind: .asset)
    let two = ExchangeFile(path: "raw/assets/a.txt", bytes: 1, sha256: ReplicaDigest.hash(Data([1])), kind: .asset)
    XCTAssertThrowsError(try VaultExchangeManifest(notes: 1, reviews: 0, files: snapshot.manifest.files + [one, two]).validate())
  }

  func testUnreferencedPayloadAndSymlinksCannotBecomeLive() async throws {
    let root = folder(), source = folder(), target = folder(), outside = folder()
    defer { for path in [root, source, target, outside] { try? fm.removeItem(at: path) } }
    let store = try await synthetic(root), snapshot = try await store.exchangeSnapshot()
    let orphaned = try rebuilt(snapshot, replacing: ["raw/assets/orphan.txt": Data("Unreferenced".utf8)])
    XCTAssertThrowsError(try orphaned.validated())
    try write(snapshot, to: source)
    let coordinator = VaultExchangeImport(root: target), pending = try await coordinator.prepare(from: source)
    let staged = target.appendingPathComponent(".daypage/exchange-imports-v1/\(pending.id.uuidString)/vault")
    try Data("Unpreviewed sidecar".utf8).write(to: staged.appendingPathComponent("unexpected.json"))
    do { _ = try await coordinator.confirm(pending); XCTFail() } catch { }
    let notes = try await NotebookStore(root: target).entries(); XCTAssertTrue(notes.isEmpty)
    try fm.removeItem(at: staged.appendingPathComponent("unexpected.json"))
    let raw = staged.appendingPathComponent("raw/2026-11-07.md")
    try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    let original = try Data(contentsOf: raw), linked = outside.appendingPathComponent("raw.md")
    try original.write(to: linked); try fm.removeItem(at: raw)
    try fm.createSymbolicLink(at: raw, withDestinationURL: linked)
    do { _ = try await coordinator.confirm(pending); XCTFail() } catch { }
    XCTAssertEqual(try Data(contentsOf: linked), original)
  }

  func testInterruptedCopySurvivesReopenRequiresSameSourceAndCanResume() async throws {
    let root = folder(), source = folder(), target = folder(), other = folder()
    defer { for path in [root, source, target, other] { try? fm.removeItem(at: path) } }
    let store = try await synthetic(root), snapshot = try await store.exchangeSnapshot()
    try write(snapshot, to: source)
    let pending = try await VaultExchangeImport(root: target).prepare(from: source)
    let staged = target.appendingPathComponent(".daypage/exchange-imports-v1/\(pending.id.uuidString)/vault/raw/2026-11-07.md")
    try Data("Killed partial write".utf8).write(to: staged)
    let reopened = VaultExchangeImport(root: target), jobs = try await reopened.pendingImports()
    XCTAssertEqual(jobs.map(\.phase), [.needsSource])
    let otherStore = try await synthetic(other)
    let otherEntries = try await otherStore.entries()
    try await otherStore.update(XCTUnwrap(otherEntries.first), body: "Different source")
    do { _ = try await reopened.resume(XCTUnwrap(jobs.first), from: other); XCTFail() } catch VaultExchangeError.changed { }
    let resumed = try await reopened.resume(XCTUnwrap(jobs.first), from: source)
    XCTAssertEqual(resumed.phase, .ready)
    _ = try await reopened.confirm(resumed)
    let notes = try await NotebookStore(root: target).entries(); XCTAssertEqual(notes.count, 1)
  }

  func testUnreadablePreparationIsVisibleAndOnlyExplicitDiscardRemovesIt() async throws {
    let root = folder(); defer { try? fm.removeItem(at: root) }
    let id = UUID(), stage = root.appendingPathComponent(".daypage/exchange-imports-v1/\(id.uuidString)")
    try fm.createDirectory(at: stage, withIntermediateDirectories: true)
    try Data("Interrupted metadata".utf8).write(to: stage.appendingPathComponent("job.pending"))
    let coordinator = VaultExchangeImport(root: root), jobs = try await coordinator.pendingImports()
    XCTAssertEqual(jobs.map(\.phase), [.unreadable]); XCTAssertTrue(fm.fileExists(atPath: stage.path))
    try await coordinator.discard(XCTUnwrap(jobs.first))
    let after = try await coordinator.pendingImports(); XCTAssertTrue(after.isEmpty)
  }

  func testPublicationReceiptMakesRestartRetryIdempotentAndNeverOverwritesCollision() async throws {
    let root = folder(), source = folder(), target = folder(), backup = folder()
    defer { for path in [root, source, target, backup] { try? fm.removeItem(at: path) } }
    let store = try await synthetic(root), snapshot = try await store.exchangeSnapshot(); try write(snapshot, to: source)
    let coordinator = VaultExchangeImport(root: target), pending = try await coordinator.prepare(from: source)
    let job = target.appendingPathComponent(".daypage/exchange-imports-v1/\(pending.id.uuidString)")
    let collision = target.appendingPathComponent("imports/\(pending.id.uuidString)")
    try fm.createDirectory(at: collision, withIntermediateDirectories: true)
    try Data("Existing user content".utf8).write(to: collision.appendingPathComponent("keep.txt"))
    do { _ = try await coordinator.confirm(pending); XCTFail() } catch VaultExchangeError.conflict { }
    XCTAssertEqual(try String(contentsOf: collision.appendingPathComponent("keep.txt")), "Existing user content")
    try fm.removeItem(at: collision)
    try fm.copyItem(at: job, to: backup)
    let first = try await coordinator.confirm(pending)
    // Model termination after rename but before pending-directory cleanup.
    try fm.copyItem(at: backup, to: job)
    let reopened = VaultExchangeImport(root: target), jobs = try await reopened.pendingImports()
    XCTAssertEqual(jobs.map(\.phase), [.published])
    let retry = try await reopened.confirm(XCTUnwrap(jobs.first)); XCTAssertEqual(first, retry)
    let notes = try await NotebookStore(root: target).entries(); XCTAssertEqual(notes.count, 1)
  }

  func testSameMemoUUIDInDifferentImportedNamespaceStaysSeparateAndNestedCitationsProjectExternally() async throws {
    let root = folder(), target = folder()
    defer { for path in [root, target] { try? fm.removeItem(at: path) } }
    let store = try await synthetic(root), originalEntries = try await store.entries()
    let memo = try XCTUnwrap(originalEntries.first?.memo), importedID = UUID().uuidString
    let imported = root.appendingPathComponent("imports/\(importedID)/raw")
    try fm.createDirectory(at: imported, withIntermediateDirectories: true)
    try memo.toMarkdown().write(to: imported.appendingPathComponent("2026-11-07.md"), atomically: true, encoding: .utf8)
    let entries = try await store.entries()
    XCTAssertEqual(entries.count, 2)
    let period = try ReviewPeriod(kind: .day, anchor: date(), timeZone: .gmt)
    let selected = try ManualReviewSnapshot.make(period: period, entries: entries, selectedIDs: Set(entries.map(\.id)))
    let session = ManualReviewSession(store: store) { _, _, _ in "Review both namespaces" }
    let draft = try await session.generate(snapshot: selected, configuration: AIConfiguration(baseURL: "https://ai.example.invalid", model: "synthetic"), apiKey: "", enabled: true)
    _ = try await session.save(draft, editedBody: draft.body)
    let snapshot = try await store.exchangeSnapshot(), review = try XCTUnwrap(snapshot.records.reviews.first)
    XCTAssertEqual(Set(snapshot.records.notes.map(\.namespace)), ["", "imports/" + importedID])
    XCTAssertTrue(review.sources.contains { $0.namespace == "imports/" + importedID && $0.id.hasPrefix("imports/" + importedID + "/2026-11-07/") })
    try write(snapshot, to: target)
    try NotebookStore.validateExchangeProjection(ExchangeIO.loadV1(target))
    // A saved page's historical source revisions remain valid after later edits.
    try await store.update(XCTUnwrap(entries.first { $0.namespace.isEmpty }), body: "Later edited source")
    let changed = try await store.exchangeSnapshot()
    XCTAssertEqual(changed.records.reviews.first?.sources, review.sources)
  }

  func testLegacyFolderUsesSamePreviewAndExplicitConfirmationWithoutCopyingRuntimeFiles() async throws {
    let source = folder(), target = folder()
    defer { for path in [source, target] { try? fm.removeItem(at: path) } }
    _ = try await synthetic(source)
    try Data("Synthetic legacy runtime".utf8).write(to: source.appendingPathComponent("runtime.json"))
    let coordinator = VaultExchangeImport(root: target), job = try await coordinator.prepare(from: source)
    let before = try await NotebookStore(root: target).entries(); XCTAssertTrue(before.isEmpty)
    let namespace = try await coordinator.confirm(job)
    XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("imports/\(namespace)/runtime.json").path))
    XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("runtime.json")), "Synthetic legacy runtime")
  }

  func testPreparedCopyIsReadyThroughTemporaryDirectoryPathAliases() async throws {
    let source = folder(), target = folder()
    defer { for path in [source, target] { try? fm.removeItem(at: path) } }
    _ = try await synthetic(source)
    let coordinator = VaultExchangeImport(root: target)
    let pending = try await coordinator.prepare(from: source)
    XCTAssertEqual(pending.phase, .ready)
    // Reopen the same pending copy using the system's canonical spelling.
    let reopened = VaultExchangeImport(root: target.resolvingSymlinksInPath())
    let jobs = try await reopened.pendingImports()
    XCTAssertEqual(jobs.map(\.id), [pending.id])
    XCTAssertEqual(jobs.map(\.phase), [.ready])
    let preview = try await reopened.preview(XCTUnwrap(jobs.first))
    XCTAssertEqual(preview.notes.first?.body, "Synthetic source")
    let namespace = try await reopened.confirm(XCTUnwrap(jobs.first))
    let entries = try await NotebookStore(root: target).entries()
    XCTAssertEqual(entries.map(\.namespace), [namespace])
    XCTAssertEqual(entries.first?.memo.body, "Synthetic source")
  }

  func testPendingQuotaHasAnExplicitDiscardRecoveryPath() async throws {
    let source = folder(), target = folder()
    defer { for path in [source, target] { try? fm.removeItem(at: path) } }
    _ = try await synthetic(source)
    let coordinator = VaultExchangeImport(root: target)
    var jobs: [PendingVaultImport] = []
    for _ in 0..<3 { jobs.append(try await coordinator.prepare(from: source)) }
    do { _ = try await coordinator.prepare(from: source); XCTFail() } catch VaultExchangeError.full { }
    try await coordinator.discard(XCTUnwrap(jobs.first))
    let newJob = try await coordinator.prepare(from: source)
    XCTAssertEqual(newJob.phase, .ready)
    let notes = try await NotebookStore(root: target).entries(); XCTAssertTrue(notes.isEmpty)
  }

  func testDuplicateMemoIdentityAcrossDaysIsNotSilentlyReassigned() async throws {
    let root = folder(); defer { try? fm.removeItem(at: root) }
    let store = try await synthetic(root), entries = try await store.entries()
    var duplicate = try XCTUnwrap(entries.first?.memo)
    duplicate.created.addTimeInterval(86_400)
    try duplicate.toMarkdown().write(to: root.appendingPathComponent("raw/2026-11-08.md"), atomically: true, encoding: .utf8)
    do { _ = try await store.exchangeSnapshot(); XCTFail() } catch VaultExchangeError.invalid { }
    XCTAssertThrowsError(try ReplicaNamespace.validateAliases(["AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]))
  }

  func testExchangeRejectsRawFileBeforeParsingWithoutChangingOrdinaryReads() async throws {
    let root = folder(); defer { try? fm.removeItem(at: root) }
    let store = NotebookStore(root: root)
    try await store.append(Memo(created: date(), body: String(repeating: "Synthetic bounded source. ", count: 32)))
    do {
      _ = try await store.exchangeEntries(readLimits: ExchangeReadLimits(rawFileBytes: 64))
      XCTFail("An oversized legacy raw file must be rejected before decoding")
    } catch VaultExchangeError.limit { }
    let original = try await store.entries()
    XCTAssertEqual(original.count, 1, "Ordinary notebook reading retains its existing policy")
  }

  func testExchangeRawBudgetIsCumulativeAcrossDateFiles() async throws {
    let root = folder(); defer { try? fm.removeItem(at: root) }
    let store = NotebookStore(root: root)
    try await store.append(Memo(created: date(), body: "First synthetic day"))
    try await store.append(Memo(created: date().addingTimeInterval(86400), body: "Second synthetic day"))
    let raw = root.appendingPathComponent("raw")
    let sizes = try fm.contentsOfDirectory(at: raw, includingPropertiesForKeys: [.fileSizeKey])
      .map { try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
    let budget = try XCTUnwrap(sizes.max())
    XCTAssertGreaterThan(sizes.reduce(0, +), budget)
    do {
      _ = try await store.exchangeSnapshot(readLimits: ExchangeReadLimits(rawBytes: budget))
      XCTFail("Individually small files cannot exceed the combined raw budget")
    } catch VaultExchangeError.limit { }
  }

  func testExchangeCountsModernAndLegacyRecordsIncrementally() async throws {
    for separator in ["\n\n<!-- daypage-memo-separator -->\n\n", "\n\n---\n\n"] {
      let root = folder(); defer { try? fm.removeItem(at: root) }
      let raw = root.appendingPathComponent("raw")
      try fm.createDirectory(at: raw, withIntermediateDirectories: true)
      let notes = [Memo(created: try date(), body: "One"), Memo(created: try date(), body: "Two")]
      try notes.map { $0.toMarkdown() }.joined(separator: separator)
        .write(to: raw.appendingPathComponent("2026-11-07.md"), atomically: true, encoding: .utf8)
      let store = NotebookStore(root: root)
      do {
        _ = try await store.exchangeEntries(readLimits: ExchangeReadLimits(notes: 1))
        XCTFail("Both canonical separators must enforce the record budget")
      } catch VaultExchangeError.limit { }
      let entries = try await store.exchangeEntries()
      XCTAssertEqual(entries.count, 2)
      XCTAssertEqual(Set(entries.map(\.revision)), Set(notes.map { NoteActionIdentity.digest($0.toMarkdown()) }))
    }
  }

  func testExchangeKeepsLegacyHorizontalRuleInsideASingleMemo() async throws {
    let root = folder(); defer { try? fm.removeItem(at: root) }
    let store = NotebookStore(root: root)
    try await store.append(Memo(created: date(), body: "Before a rule\n\n---\n\nAfter a rule"))
    let ordinary = try await store.entries(), bounded = try await store.exchangeEntries()
    XCTAssertEqual(bounded, ordinary)
    XCTAssertEqual(bounded.map(\.revision), ordinary.map(\.revision))
    _ = try await store.exchangeSnapshot()
  }

  func testOneDayExchangeDoesNotCountOtherInventoryAgainstSelectedNoteLimit() async throws {
    let root = folder(); defer { try? fm.removeItem(at: root) }
    let raw = root.appendingPathComponent("raw")
    try fm.createDirectory(at: raw, withIntermediateDirectories: true)
    let selected = Memo(created: try date(), body: "Selected synthetic day")
    try selected.toMarkdown().write(to: raw.appendingPathComponent("2026-11-07.md"), atomically: true, encoding: .utf8)
    let otherDay = try date().addingTimeInterval(86400)
    let inventory = (0..<501).map { Memo(created: otherDay, body: "Other synthetic day \($0)").toMarkdown() }
    try inventory.joined(separator: "\n\n<!-- daypage-memo-separator -->\n\n")
      .write(to: raw.appendingPathComponent("2026-11-08.md"), atomically: true, encoding: .utf8)
    let store = NotebookStore(root: root)
    let period = try ReviewPeriod(kind: .day, anchor: date(), timeZone: .gmt)
    let entries = try await store.exchangeEntries(period: period)
    XCTAssertEqual(entries.map(\.memo.id), [selected.id])
    let snapshot = try await store.exchangeSnapshot(selectedIDs: Set(entries.map(\.id)))
    XCTAssertEqual(snapshot.records.notes.count, 1)
    XCTAssertEqual(Set(snapshot.files.keys), ["raw/2026-11-07.md", "records.json"])
  }

  func testLegacyImportRejectsFIFOWithoutReadingOrPublishingIt() async throws {
    let source = folder(), target = folder()
    defer { for path in [source, target] { try? fm.removeItem(at: path) } }
    let raw = source.appendingPathComponent("raw")
    try fm.createDirectory(at: raw, withIntermediateDirectories: true)
    XCTAssertEqual(mkfifo(raw.appendingPathComponent("2026-11-07.md").path, mode_t(0o600)), 0)
    let coordinator = VaultExchangeImport(root: target)
    do { _ = try await coordinator.prepare(from: source); XCTFail("A FIFO is never a canonical raw file") }
    catch VaultExchangeError.limit { }
    let jobs = try await coordinator.pendingImports()
    XCTAssertTrue(jobs.isEmpty)
    XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("imports").path))
  }

  func testExchangeDirectoryEnumerationHasABoundedEntryBudget() async throws {
    let root = folder(); defer { try? fm.removeItem(at: root) }
    let store = try await synthetic(root)
    try Data().write(to: root.appendingPathComponent("raw/ignored-one.txt"))
    try Data().write(to: root.appendingPathComponent("raw/ignored-two.txt"))
    do {
      _ = try await store.exchangeEntries(readLimits: ExchangeReadLimits(directoryEntries: 2))
      XCTFail("Ignored entries must not make folder enumeration unbounded")
    } catch VaultExchangeError.limit { }
  }

  func testCancelledExchangeRefusesLegacyReadBeforeAnyPendingCopy() async throws {
    let source = folder(), target = folder()
    defer { for path in [source, target] { try? fm.removeItem(at: path) } }
    _ = try await synthetic(source)
    let coordinator = VaultExchangeImport(root: target)
    let operation = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await coordinator.prepare(from: source)
    }
    do { _ = try await operation.value; XCTFail("Cancellation must be checked before source reading") }
    catch is CancellationError { }
    XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent(".daypage/exchange-imports-v1").path))
  }

  func testExchangeReviewBudgetRejectsBeforeCollectingAllSavedPages() async throws {
    let root = folder(); defer { try? fm.removeItem(at: root) }
    let store = try await synthetic(root), entries = try await store.entries()
    let period = try ReviewPeriod(kind: .day, anchor: date(), timeZone: .gmt)
    let snapshot = try ManualReviewSnapshot.make(period: period, entries: entries, selectedIDs: Set(entries.map(\.id)))
    let session = ManualReviewSession(store: store) { _, _, _ in "Synthetic review" }
    for _ in 0..<2 {
      let draft = try await session.generate(snapshot: snapshot,
        configuration: AIConfiguration(baseURL: "https://ai.example.invalid", model: "synthetic"), apiKey: "", enabled: true)
      _ = try await session.save(draft, editedBody: draft.body)
    }
    do {
      _ = try await store.exchangeSnapshot(readLimits: ExchangeReadLimits(reviews: 1))
      XCTFail("The exchange review budget applies before loading every page")
    } catch VaultExchangeError.limit { }
    let pages = try await store.manualReviews()
    XCTAssertEqual(pages.count, 2)
  }
}
