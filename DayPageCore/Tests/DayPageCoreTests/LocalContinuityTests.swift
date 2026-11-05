import XCTest
@testable import DayPageCore

final class LocalContinuityTests: XCTestCase {
  var directory: URL!
  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("continuity-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
  func store(_ name: String) -> NotebookStore { NotebookStore(root: directory.appendingPathComponent(name)) }
  func engine(_ name: String) -> VaultReplica {
    VaultReplica(store: store(name), stateRoot: directory.appendingPathComponent(name + "-state"))
  }
  func transport() -> DirectoryReplicaTransport {
    DirectoryReplicaTransport(root: directory.appendingPathComponent("remote"))
  }
  func testWatchReplayAndTrashNeverDuplicatesOrLosesAudio() async throws {
    let inbox = WatchCaptureStore(root: directory.appendingPathComponent("inbox"))
    let audio = Data("original AAC fixture".utf8)
    let capture = WatchCapture(id: UUID(), created: Date(), duration: 3, digest: ReplicaDigest.hash(audio))
    try await inbox.stage(capture, audio: audio)
    let notebook = store("phone")
    let receipt = try await inbox.importCapture(capture.id, into: notebook)
    XCTAssertEqual(receipt.digest, capture.digest)
    try await inbox.stage(capture, audio: audio)
    _ = try await inbox.importCapture(capture.id, into: notebook)
    let entries = try await notebook.entries()
    XCTAssertEqual(entries.count, 1)
    let entry = try XCTUnwrap(entries.first)
    let asset = try await notebook.assetURL(try XCTUnwrap(entry.memo.attachments.first).file, for: entry)
    XCTAssertEqual(try Data(contentsOf: asset), audio)
    _ = try await notebook.trash(entry)
    try await inbox.stage(capture, audio: audio)
    _ = try await inbox.importCapture(capture.id, into: notebook)
    let after = try await notebook.entries()
    XCTAssertTrue(after.isEmpty)
  }
  func testWrongWatchDigestIsRejected() async throws {
    let inbox = WatchCaptureStore(root: directory.appendingPathComponent("inbox"))
    do {
      try await inbox.stage(WatchCapture(id: UUID(), created: Date(), duration: 1, digest: String(repeating: "a", count: 64)), audio: Data([1]))
      XCTFail("invalid audio accepted")
    } catch {}
  }
  func testLegacyWatchReplayKeepsExistingMemoIdentityAndOriginalAudio() async throws {
    let notebook = store("phone"), audio = Data("legacy original".utf8)
    let digest = ReplicaDigest.hash(audio)
    let assetFolder = directory.appendingPathComponent("phone/raw/assets")
    try FileManager.default.createDirectory(at: assetFolder, withIntermediateDirectories: true)
    let name = "watch_" + digest + ".m4a"
    try audio.write(to: assetFolder.appendingPathComponent(name))
    let old = Memo(type: .voice, device: "Apple Watch", attachments: [.init(file: "raw/assets/" + name, kind: "audio")])
    try await notebook.append(old)
    let inbox = WatchCaptureStore(root: directory.appendingPathComponent("legacy-inbox"))
    let legacy = try WatchCapture.legacy(audio: audio, created: old.created, duration: 4)
    try await inbox.stage(legacy, audio: audio)
    _ = try await inbox.importCapture(legacy.id, into: notebook)
    var entries = try await notebook.entries()
    XCTAssertEqual(entries.map(\.memo.id), [old.id])
    _ = try await notebook.trash(try XCTUnwrap(entries.first))
    let another = WatchCaptureStore(root: directory.appendingPathComponent("legacy-replay"))
    try await another.stage(legacy, audio: audio)
    _ = try await another.importCapture(legacy.id, into: notebook)
    entries = try await notebook.entries()
    XCTAssertTrue(entries.isEmpty)
    XCTAssertEqual(try Data(contentsOf: assetFolder.appendingPathComponent(name)), audio)
  }
  func testLegacyWatchRetriesTolerateDurationProbeDifferencesWithoutReplacingMetadata() async throws {
    let audio = Data("one old clip".utf8), created = Date()
    let one = try WatchCapture.legacy(audio: audio, created: created, duration: 4)
    let two = try WatchCapture.legacy(audio: audio, created: created.addingTimeInterval(1), duration: 3.95)
    XCTAssertEqual(one.id, two.id)
    let outbox = WatchCaptureStore(root: directory.appendingPathComponent("legacy-watch"))
    try await outbox.stage(one, audio: audio)
    try await outbox.stage(two, audio: audio)
    let stored = try await outbox.capture(one.id)
    XCTAssertEqual(stored, one)
  }
  func testLegacyFileIsPreservedWithoutReadingBeforeConversion() throws {
    let original = directory.appendingPathComponent("incoming.m4a")
    let audio = Data("an unreadable original must survive conversion failure".utf8)
    try audio.write(to: original)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: original.path)
    let destination = try WatchCaptureStore.preserveLegacyFile(original, in: directory.appendingPathComponent("durable"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    XCTAssertEqual(try Data(contentsOf: destination), audio)
  }
  func testTwoDevicesExchangeUpdateDeleteAndHistoricalRestore() async throws {
    let a = store("a"), b = store("b"), ea = engine("a"), eb = engine("b")
    let memo = Memo(body: "Original")
    try await a.append(memo, assets: [.init(data: Data([1, 2, 3]), fileExtension: "m4a", kind: "audio")])
    try await ea.exchange(with: transport())
    try await eb.exchange(with: transport())
    var entries = try await b.entries()
    XCTAssertEqual(entries.first?.memo.body, "Original")
    let old = try await eb.history()
    try await b.update(try XCTUnwrap(entries.first), body: "Edited on B")
    try await eb.exchange(with: transport())
    try await ea.exchange(with: transport())
    entries = try await a.entries()
    XCTAssertEqual(entries.first?.memo.body, "Edited on B")
    _ = try await a.trash(try XCTUnwrap(entries.first))
    try await ea.exchange(with: transport())
    try await eb.exchange(with: transport())
    entries = try await b.entries()
    XCTAssertTrue(entries.isEmpty)
    try await eb.restore(try XCTUnwrap(old.first).id)
    try await eb.restore(try XCTUnwrap(old.first).id)
    entries = try await b.entries()
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries.first?.memo.body, "Original")
    let url = try await b.assetURL(try XCTUnwrap(entries.first?.memo.attachments.first?.file), for: try XCTUnwrap(entries.first))
    XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
  }
  func testConcurrentEditAndDeletePreserveEditedBranch() async throws {
    let a = store("a"), b = store("b"), ea = engine("a"), eb = engine("b")
    try await a.append(Memo(body: "Before"))
    try await ea.exchange(with: transport()); try await eb.exchange(with: transport())
    let originalA = try await a.entries(), originalB = try await b.entries()
    _ = try await a.trash(try XCTUnwrap(originalA.first))
    try await b.update(try XCTUnwrap(originalB.first), body: "Surviving edit")
    try await ea.exchange(with: transport()); try await eb.exchange(with: transport())
    try await ea.exchange(with: transport())
    let afterA = try await a.entries(), afterB = try await b.entries()
    XCTAssertEqual(afterA.map(\.memo.body), ["Surviving edit"])
    XCTAssertEqual(afterA, afterB)
  }
  func testConcurrentEditsKeepBothCopiesWithoutGrowthOnReplay() async throws {
    let a = store("a"), b = store("b"), ea = engine("a"), eb = engine("b")
    try await a.append(Memo(body: "Base"))
    try await ea.exchange(with: transport()); try await eb.exchange(with: transport())
    let aa = try await a.entries(), bb = try await b.entries()
    try await a.update(try XCTUnwrap(aa.first), body: "A")
    try await b.update(try XCTUnwrap(bb.first), body: "B")
    try await ea.exchange(with: transport()); try await eb.exchange(with: transport())
    try await ea.exchange(with: transport()); try await eb.exchange(with: transport())
    let result = try await b.entries()
    XCTAssertEqual(Set(result.map(\.memo.body)), ["A", "B"])
    XCTAssertEqual(result.count, 2)
    let history = try await eb.history()
    XCTAssertEqual(history.count, 3)
  }
  func testSyncPreservesUnknownYAMLAndRejectsAmbiguousUUIDs() async throws {
    let memo = Memo(body: "keep original")
    let raw = memo.toMarkdown().replacingOccurrences(of: "type: text", with: "type: text\nfuture: retain-this")
    let folder = directory.appendingPathComponent("a/raw")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try raw.write(to: folder.appendingPathComponent("2026-11-04.md"), atomically: true, encoding: .utf8)
    try await engine("a").exchange(with: transport())
    try await engine("b").exchange(with: transport())
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("b/raw/2026-11-04.md")), raw)
    try raw.write(to: folder.appendingPathComponent("2026-11-05.md"), atomically: true, encoding: .utf8)
    do { try await engine("a").exchange(with: transport()); XCTFail("ambiguous key accepted") } catch {}
  }
  func testTransportRejectsTraversalSymlinksAndCorruption() async throws {
    let transport = transport()
    do { _ = try await transport.read("../outside"); XCTFail("unsafe key") } catch {}
    let remote = directory.appendingPathComponent("remote")
    try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
    let hash = ReplicaDigest.hash(Data([1]))
    try FileManager.default.createSymbolicLink(at: remote.appendingPathComponent("objects"), withDestinationURL: directory)
    do { try await transport.write(Data([1]), key: "objects/" + hash); XCTFail("link followed") } catch {}
  }
  func testStaleIntegrationCannotReplaceAUserEdit() async throws {
    let notebook = store("phone")
    try await notebook.append(Memo(body: "before"))
    let before = try await notebook.replicaRecords()
    let original = try XCTUnwrap(before.first)
    let entries = try await notebook.entries()
    try await notebook.update(try XCTUnwrap(entries.first), body: "new edit")
    do {
      try await notebook.applyReplica(nil, identity: original.identity, expected: original.fingerprint)
      XCTFail("stale delete applied")
    } catch {}
    let after = try await notebook.entries()
    XCTAssertEqual(after.first?.memo.body, "new edit")
  }
  func testMissingParentAndAttachmentNeverMaterializeAnIncompleteNote() async throws {
    let note = Memo(body: "not yet complete")
    let missingParent = VaultRevision(version: 1, key: "/" + note.id.uuidString,
      parents: [String(repeating: "a", count: 64)], day: "2026-11-05", markdown: note.toMarkdown(), assets: [:])
    let remote = transport()
    try await remote.write(ReplicaDigest.encode(missingParent), key: "revisions/" + missingParent.id + ".json")
    do { try await engine("phone").exchange(with: remote); XCTFail("missing parent accepted") } catch {}
    let entries = try await store("phone").entries()
    XCTAssertTrue(entries.isEmpty)
    let destination = directory.appendingPathComponent("other-remote")
    let other = DirectoryReplicaTransport(root: destination)
    var audio = note
    audio.attachments = [.init(file: "raw/assets/original.m4a", kind: "audio")]
    let missingObject = VaultRevision(version: 1, key: "/" + note.id.uuidString, parents: [],
      day: "2026-11-05", markdown: audio.toMarkdown(), assets: ["raw/assets/original.m4a": ReplicaDigest.hash(Data([1]))])
    try await other.write(ReplicaDigest.encode(missingObject), key: "revisions/" + missingObject.id + ".json")
    do { try await engine("other").exchange(with: other); XCTFail("missing object accepted") } catch {}
    let noAudio = try await store("other").entries()
    XCTAssertTrue(noAudio.isEmpty)
  }
  func testInterruptedApplyReplansAroundAFreshUserEdit() async throws {
    let source = store("source"), target = store("target")
    try await source.append(Memo(body: "One")); try await source.append(Memo(body: "Two"))
    try await engine("source").exchange(with: transport())
    let lease = FailingContinuityLease(rawRoot: directory.appendingPathComponent("target/raw"), recordCount: 1)
    let interrupted = VaultReplica(store: target, stateRoot: directory.appendingPathComponent("target-state"), validateSession: { try lease.check() })
    do { try await interrupted.exchange(with: transport()); XCTFail("interruption not exercised") } catch {}
    let partial = try await target.entries()
    XCTAssertEqual(partial.count, 1)
    try await target.update(try XCTUnwrap(partial.first), body: "New edit after interruption")
    let restarted = engine("target")
    do { try await restarted.exchange(with: transport()) } catch ReplicaError.changed { }
    try await restarted.exchange(with: transport())
    let result = try await target.entries()
    XCTAssertEqual(result.count, 2)
    XCTAssertTrue(result.contains { $0.memo.body == "New edit after interruption" })
    try await engine("source").exchange(with: transport())
    let other = try await source.entries()
    XCTAssertEqual(Set(other.map(\.memo.body)), Set(result.map(\.memo.body)))
  }
  func testRevokedSessionCannotWriteOrMaterialize() async throws {
    let notebook = store("phone")
    try await notebook.append(Memo(body: "local only"))
    let revoked = DirectoryReplicaTransport(root: directory.appendingPathComponent("blocked"), validateSession: { throw CancellationError() })
    do { try await engine("phone").exchange(with: revoked); XCTFail("revoked session used") } catch {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("blocked").path))
    let entries = try await notebook.entries()
    XCTAssertEqual(entries.first?.memo.body, "local only")
  }
  func testInterruptedNewDownloadDoesNotUndoUserDeletion() async throws {
    let source = store("source"), target = store("target")
    try await source.append(Memo(body: "One")); try await source.append(Memo(body: "Two"))
    try await engine("source").exchange(with: transport())
    let lease = FailingContinuityLease(rawRoot: directory.appendingPathComponent("target/raw"), recordCount: 1)
    let interrupted = VaultReplica(store: target, stateRoot: directory.appendingPathComponent("target-state"), validateSession: { try lease.check() })
    do { try await interrupted.exchange(with: transport()); XCTFail("not interrupted") } catch {}
    let partial = try await target.entries()
    let removed = try XCTUnwrap(partial.first)
    _ = try await target.trash(removed)
    do { try await engine("target").exchange(with: transport()) } catch ReplicaError.changed { }
    try await engine("target").exchange(with: transport())
    let result = try await target.entries()
    XCTAssertEqual(result.count, 1)
    XCTAssertFalse(result.contains { $0.memo.id == removed.memo.id })
  }
  func testInterruptedRemoteDeletionDoesNotUndoUserRestore() async throws {
    let source = store("source"), target = store("target")
    try await source.append(Memo(body: "One")); try await source.append(Memo(body: "Two"))
    try await engine("source").exchange(with: transport()); try await engine("target").exchange(with: transport())
    for entry in try await source.entries() { _ = try await source.trash(entry) }
    try await engine("source").exchange(with: transport())
    let lease = FailingContinuityLease(rawRoot: directory.appendingPathComponent("target/raw"), recordCount: 1)
    let interrupted = VaultReplica(store: target, stateRoot: directory.appendingPathComponent("target-state"), validateSession: { try lease.check() })
    do { try await interrupted.exchange(with: transport()); XCTFail("not interrupted") } catch {}
    let receipts = try await target.trashReceipts()
    let recovered = try XCTUnwrap(receipts.first)
    try await target.restore(recovered)
    do { try await engine("target").exchange(with: transport()) } catch ReplicaError.changed { }
    try await engine("target").exchange(with: transport())
    let result = try await target.entries()
    XCTAssertTrue(result.contains { $0.memo.id == recovered.entry.memo.id })
  }
  func testStoreRejectsRevokedLeaseAtCommitBoundary() async throws {
    let source = store("source"), target = store("target")
    try await source.append(Memo(body: "private account A"))
    let original = try await source.replicaRecords()
    let record = try XCTUnwrap(original.first)
    do {
      try await target.applyReplica(record, identity: record.identity, expected: nil, validateSession: { throw CancellationError() })
      XCTFail("revoked account applied")
    } catch {}
    let entries = try await target.entries()
    XCTAssertTrue(entries.isEmpty)
  }
  func testCaseVariantRemoteNamespaceCannotOverwriteAnotherLocalIdentity() async throws {
    let namespace = "AAAAAAAA-1111-4111-8111-111111111111"
    let notebook = store("phone"), replica = engine("phone"), remote = transport()
    let memo = Memo(body: "Keep this original")
    let original = ReplicaRecord(namespace: namespace, day: "2026-11-05", markdown: memo.toMarkdown(), assets: [:])
    try await notebook.applyReplica(original, identity: original.identity, expected: nil)
    try await replica.exchange(with: remote)
    var changed = memo
    changed.body = "Different remote logical identity"
    let collision = VaultRevision(version: 1, key: namespace.lowercased() + "/" + memo.id.uuidString,
      parents: [], day: original.day, markdown: changed.toMarkdown(), assets: [:])
    try await remote.write(ReplicaDigest.encode(collision), key: "revisions/" + collision.id + ".json")
    do { try await replica.exchange(with: remote); XCTFail("case-colliding identities were accepted") } catch {}
    let records = try await notebook.replicaRecords()
    XCTAssertEqual(records, [original])
    // Correcting an invalid remote graph must not leave a poisoned local cache.
    try FileManager.default.removeItem(at: directory.appendingPathComponent("remote/revisions/" + collision.id + ".json"))
    try await replica.exchange(with: remote)
    let recovered = try await notebook.replicaRecords()
    XCTAssertEqual(recovered, [original])
  }
  func testCaseVariantNamespacePrefixesWithDifferentMemosAreRejected() throws {
    let upper = "AAAAAAAA-1111-4111-8111-111111111111"
    let childA = "BBBBBBBB-1111-4111-8111-111111111111"
    let childB = "CCCCCCCC-1111-4111-8111-111111111111"
    XCTAssertThrowsError(try ReplicaNamespace.validateAliases([upper + "/" + childA, upper.lowercased() + "/" + childB]))
    XCTAssertThrowsError(try ReplicaNamespace.validateAliases([upper, upper.lowercased()]))
    XCTAssertNoThrow(try ReplicaNamespace.validateAliases([upper.lowercased(), upper.lowercased() + "/" + childA]))
  }
  func testStoreRejectsAnEmptyCaseAliasDirectoryAndKeepsLowercaseCompatibility() async throws {
    let namespace = "AAAAAAAA-1111-4111-8111-111111111111"
    let notebook = store("phone")
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("phone/imports/" + namespace), withIntermediateDirectories: true)
    let memo = Memo(body: "must not drift between namespaces")
    let lower = ReplicaRecord(namespace: namespace.lowercased(), day: "2026-11-05", markdown: memo.toMarkdown(), assets: [:])
    do { try await notebook.applyReplica(lower, identity: lower.identity, expected: nil); XCTFail("empty namespace alias accepted") } catch {}
    let untouched = try await notebook.entries()
    XCTAssertTrue(untouched.isEmpty)
    let another = store("lowercase")
    try await another.applyReplica(lower, identity: lower.identity, expected: nil)
    let records = try await another.replicaRecords()
    XCTAssertEqual(records, [lower])
  }
  func testRecoveryRejectsANamespaceAliasImportedAfterTheJournalWasWritten() async throws {
    let upper = "AAAAAAAA-1111-4111-8111-111111111111"
    let remote = transport(), notebook = store("phone")
    let remoteMemo = Memo(body: "remote memo")
    let revision = VaultRevision(version: 1, key: upper.lowercased() + "/" + remoteMemo.id.uuidString,
      parents: [], day: "2026-11-05", markdown: remoteMemo.toMarkdown(), assets: [:])
    try await remote.write(ReplicaDigest.encode(revision), key: "revisions/" + revision.id + ".json")
    let state = directory.appendingPathComponent("phone-state")
    let journal = state.appendingPathComponent("apply.json")
    let interrupted = VaultReplica(store: notebook, stateRoot: state, validateSession: {
      if FileManager.default.fileExists(atPath: journal.path) { throw CancellationError() }
    })
    do { try await interrupted.exchange(with: remote); XCTFail("not interrupted before apply") } catch {}
    XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
    let localMemo = Memo(body: "a new local import")
    let local = ReplicaRecord(namespace: upper, day: "2026-11-05", markdown: localMemo.toMarkdown(), assets: [:])
    try await notebook.applyReplica(local, identity: local.identity, expected: nil)
    do { try await engine("phone").exchange(with: remote); XCTFail("journal ignored the new local alias") } catch {}
    let result = try await notebook.replicaRecords()
    XCTAssertEqual(result, [local])
  }
  func testOldOrWrongReceiptDoesNotAcknowledgeAnotherCapture() async throws {
    let outbox = WatchCaptureStore(root: directory.appendingPathComponent("watch"))
    let audio = Data([1, 2]), capture = WatchCapture(id: UUID(), created: Date(), duration: 2, digest: ReplicaDigest.hash(Data([1, 2])))
    try await outbox.stage(capture, audio: audio)
    do { try await outbox.markDelivered(.init(id: capture.id, digest: ReplicaDigest.hash(Data([3])))); XCTFail("wrong receipt") } catch {}
    let receipt = try await outbox.receipt(capture.id)
    XCTAssertNil(receipt)
    let original = try await outbox.audioURL(capture.id)
    XCTAssertEqual(try Data(contentsOf: original), audio)
  }
}

private final class FailingContinuityLease: @unchecked Sendable {
  private let rawRoot: URL
  private let recordCount: Int
  init(rawRoot: URL, recordCount: Int) { self.rawRoot = rawRoot; self.recordCount = recordCount }
  func check() throws {
    let files = (try? FileManager.default.contentsOfDirectory(at: rawRoot, includingPropertiesForKeys: nil)) ?? []
    let count = files.filter { $0.pathExtension == "md" }.reduce(0) { sum, file in
      sum + ((try? String(contentsOf: file)) ?? "").components(separatedBy: "\n\n<!-- daypage-memo-separator -->\n\n").compactMap(Memo.fromMarkdown).count
    }
    if count == recordCount { throw CancellationError() }
  }
}
