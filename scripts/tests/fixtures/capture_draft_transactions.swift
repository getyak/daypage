import DayPageCore
import Foundation

@main
@MainActor
struct DraftTests {
  static let fm = FileManager.default
  static let asset = Data("synthetic attachment".utf8)
  static func require(_ condition: Bool, _ message: String) throws {
    if !condition {
      throw NSError(domain: "DraftTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
  }
  static func withRoot(_ name: String, _ operation: (URL) async throws -> Void) async throws {
    guard let fixtureRoot = ProcessInfo.processInfo.environment["DAYPAGE_DRAFT_TEST_ROOT"] else {
      throw NSError(
        domain: "DraftTests", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Missing isolated fixture root"])
    }
    let fixture = URL(fileURLWithPath: fixtureRoot, isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL
      .appendingPathComponent("draft-fixture-" + UUID().uuidString)
    let root = fixture.appendingPathComponent("vault")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
      for path in [root.appendingPathComponent(".daypage"), root.appendingPathComponent("raw")] {
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
      }
      try? fm.removeItem(at: fixture)
    }
    try await operation(root)
    print("PASS: " + name)
  }
  static func expectDraftError(_ operation: () async throws -> Void) async throws {
    do { try await operation() } catch is CaptureDraftError { return }
    throw NSError(
      domain: "DraftTests", code: 2,
      userInfo: [NSLocalizedDescriptionKey: "Expected protected draft operation to fail"])
  }
  static func settle() async throws { try await Task.sleep(for: .milliseconds(80)) }

  static func main() async throws {
    try await withRoot("chmod cleanup failure + relaunch suppress committed text/assets") { root in
      let model = NotebookModel(root: root)
      await model.load()
      model.draft = "Committed exactly once"
      model.saveDraft()
      let added = await model.addCaptureAsset(
        data: asset, filename: "voice.m4a", kind: "audio", duration: 1)
      try require(added, "Fixture attachment did not persist: \(model.error ?? "no error")")
      try await settle()
      let savedDraft = try await CaptureDraftStore(root: root).load()
      try await model.store.append(
        Memo(id: savedDraft.memoID, body: model.draft),
        assets: [NotebookAssetInput(data: asset, fileExtension: "m4a", kind: "audio", duration: 1)])
      let metadata = root.appendingPathComponent(".daypage")
      try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: metadata.path)
      var cleanupFailed = false
      do {
        try await CaptureDraftStore(root: root).save(CaptureDraftSnapshot(), revision: 10)
      } catch { cleanupFailed = true }
      try require(cleanupFailed, "chmod fixture did not reject cleanup")
      let relaunched = NotebookModel(root: root)
      await relaunched.load()
      let notes = try await relaunched.store.entries()
      try require(notes.count == 1, "Expected exactly one committed raw note")
      try require(
        relaunched.pendingAssets.isEmpty && relaunched.draft.isEmpty,
        "Committed note reappeared as draft")
      try require(notes[0].memo.attachments.count == 1, "Committed attachment was lost")
      try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: metadata.path)
      let nextSaved = await relaunched.save(body: "The next note", editing: nil)
      try require(nextSaved, "A new draft could not be committed after recovery")
      let afterNext = try await relaunched.store.entries()
      try require(
        afterNext.count == 2 && Set(afterNext.map { $0.memo.id }).count == 2,
        "Recovery duplicated or reused the committed note identity")
      let nextNote = afterNext.first { $0.memo.body == "The next note" }
      try require(
        nextNote?.memo.attachments.isEmpty == true, "Consumed attachment leaked into the next note")
    }
    try await withRoot("cleanup failure then trash does not resurrect the committed draft") {
      root in
      let model = NotebookModel(root: root)
      await model.load()
      model.draft = "Committed then trashed"
      let added = await model.addCaptureAsset(data: asset, filename: "fixture.txt", kind: "file")
      try require(added, "Fixture attachment did not persist")
      model.draft = "Committed then trashed after a text-sidecar update"
      model.saveDraft()
      try await settle()
      let prepared = try await CaptureDraftStore(root: root).load()
      try await model.store.append(
        Memo(id: prepared.memoID, body: prepared.body),
        assets: [NotebookAssetInput(data: asset, fileExtension: "txt", kind: "file")])
      try fm.setAttributes(
        [.posixPermissions: 0o555], ofItemAtPath: root.appendingPathComponent(".daypage").path)
      var cleanupFailed = false
      do {
        try await CaptureDraftStore(root: root).save(CaptureDraftSnapshot(), revision: 10)
      } catch { cleanupFailed = true }
      try require(cleanupFailed, "Readonly cleanup unexpectedly succeeded")
      let entry = try await model.store.entries()[0]
      _ = try await model.store.trash(entry)
      let launch = NotebookModel(root: root)
      await launch.load()
      try require(
        launch.entries.isEmpty && launch.pendingAssets.isEmpty && launch.draft.isEmpty,
        "Trashed committed note reappeared as a draft")
      let receipts = try await launch.store.trashReceipts()
      try require(
        receipts.count == 1 && receipts[0].entry.memo.id == prepared.memoID,
        "Reconciliation damaged recoverable Trash")
    }
    try await withRoot("read-only precommit preserves draft and writes no raw note") { root in
      let model = NotebookModel(root: root)
      await model.load()
      model.draft = "Preserve before commit"
      let added = await model.addCaptureAsset(data: asset, filename: "fixture.txt", kind: "file")
      try require(added, "Fixture attachment did not persist")
      let before = try await CaptureDraftStore(root: root).load()
      try fm.setAttributes(
        [.posixPermissions: 0o555], ofItemAtPath: root.appendingPathComponent(".daypage").path)
      let saved = await model.save(body: model.draft, editing: nil)
      let notes = try await model.store.entries()
      try require(!saved && notes.isEmpty, "Precommit failure published raw data")
      try require(
        model.draft == before.body && model.pendingAssets.count == 1,
        "Precommit failure cleared the in-memory draft")
      let relaunched = NotebookModel(root: root)
      await relaunched.load()
      try require(
        relaunched.draft == before.body && relaunched.pendingAssets.count == 1,
        "Precommit failure lost the restart draft")
    }
    try await withRoot(
      "raw failure + restart retains identity, retry commits once, next draft rotates"
    ) { root in
      let model = NotebookModel(root: root)
      await model.load()
      let added = await model.addCaptureAsset(data: asset, filename: "fixture.txt", kind: "file")
      try require(added, "Fixture attachment did not persist")
      model.draft = "Earlier typed text"
      model.saveDraft()
      try await settle()
      let invalid = "Keep this text\n\n<!-- daypage-memo-separator -->\n\nReserved separator"
      let saved = await model.save(body: invalid, editing: nil)
      try require(
        !saved && model.pendingAssets.count == 1 && model.draft == invalid,
        "Raw rejection did not preserve the draft")
      let prepared = try await CaptureDraftStore(root: root).load()
      let relaunched = NotebookModel(root: root)
      await relaunched.load()
      try require(
        relaunched.draft == invalid && relaunched.pendingAssets.count == 1,
        "Prepared but uncommitted draft did not recover")
      let retry = await relaunched.save(body: "Corrected content", editing: nil)
      try require(retry, "Corrected draft did not save")
      let notes = try await relaunched.store.entries()
      try require(
        notes.count == 1 && notes[0].memo.id == prepared.memoID,
        "Retry lost stable identity or duplicated the note")
      let cleared = try await CaptureDraftStore(root: root).load()
      try require(
        cleared.memoID != prepared.memoID && cleared.body.isEmpty && cleared.assets.isEmpty,
        "Successful save did not rotate and clear the draft")
      let finalLaunch = NotebookModel(root: root)
      await finalLaunch.load()
      try require(
        finalLaunch.draft.isEmpty && finalLaunch.pendingAssets.isEmpty,
        "Successful save reloaded an old draft")
    }
    try await withRoot("legacy array/text migration, authoritative envelope, and discard rotation")
    { root in
      let metadata = root.appendingPathComponent(".daypage")
      try fm.createDirectory(at: metadata, withIntermediateDirectories: true)
      let oldAsset = PendingNoteAsset(
        data: asset, name: "legacy.txt", fileExtension: "txt", kind: "file", duration: nil)
      try JSONEncoder().encode([oldAsset]).write(
        to: metadata.appendingPathComponent("capture-draft.json"))
      try "Legacy body".write(
        to: metadata.appendingPathComponent("draft.txt"), atomically: true, encoding: .utf8)
      let model = NotebookModel(root: root)
      await model.load()
      try require(
        model.draft == "Legacy body" && model.pendingAssets.first?.id == oldAsset.id,
        "Legacy draft migration lost text or bytes")
      model.draft = "Updated envelope body"
      model.saveDraft()
      try await settle()
      let migrated = try await CaptureDraftStore(root: root).load()
      try require(
        migrated.body == model.draft && migrated.assets.first?.data == asset,
        "Envelope migration did not preserve current content")
      let nextLaunch = NotebookModel(root: root)
      await nextLaunch.load()
      try require(nextLaunch.draft == model.draft, "Stale draft.txt overrode the envelope")
      await nextLaunch.discardDraft()
      let discarded = try await CaptureDraftStore(root: root).load()
      try require(
        discarded.memoID != migrated.memoID && discarded.body.isEmpty && discarded.assets.isEmpty,
        "Discard failed to rotate or clear the draft")
      let lastLaunch = NotebookModel(root: root)
      await lastLaunch.load()
      try require(
        lastLaunch.draft.isEmpty && lastLaunch.pendingAssets.isEmpty,
        "Discard resurrected legacy text")
    }
    try await withRoot("text-only legacy draft stays recoverable") { root in
      let metadata = root.appendingPathComponent(".daypage")
      try fm.createDirectory(at: metadata, withIntermediateDirectories: true)
      try "Only text, no attachments".write(
        to: metadata.appendingPathComponent("draft.txt"), atomically: true, encoding: .utf8)
      let model = NotebookModel(root: root)
      await model.load()
      try require(model.draft == "Only text, no attachments", "Text-only legacy recovery failed")
      let saved = await model.save(body: model.draft, editing: nil)
      try require(saved, "Text-only legacy note could not save")
      let launch = NotebookModel(root: root)
      await launch.load()
      try require(launch.draft.isEmpty, "Legacy draft text resurrected after commit")
    }
    try await withRoot("imported UUID collision does not consume the local capture draft") { root in
      let capture = CaptureDraftSnapshot(body: "Local uncommitted draft", assets: [])
      try await CaptureDraftStore(root: root).save(capture, revision: 1)
      let source = root.deletingLastPathComponent().appendingPathComponent("source")
      let sourceStore = NotebookStore(root: source)
      try await sourceStore.append(Memo(id: capture.memoID, body: "Imported note with same UUID"))
      try await NotebookStore(root: root).importVault(from: source)
      let model = NotebookModel(root: root)
      await model.load()
      try require(
        model.entries.count == 1 && !model.entries[0].namespace.isEmpty,
        "Imported fixture did not retain its namespace")
      try require(model.draft == capture.body, "Imported namespace consumed a local draft")
      _ = try await model.store.trash(model.entries[0])
      let launch = NotebookModel(root: root)
      await launch.load()
      try require(launch.draft == capture.body, "Imported trash UUID consumed a local draft")
    }
    try await withRoot("corrupt trash metadata blocks reconciliation without erasing the draft") {
      root in
      let capture = CaptureDraftSnapshot(body: "Unconsumed draft")
      try await CaptureDraftStore(root: root).save(capture, revision: 1)
      let snapshotFile = root.appendingPathComponent(".daypage/capture-draft.json")
      let before = try Data(contentsOf: snapshotFile)
      let trash = root.appendingPathComponent(".daypage-trash")
      try fm.createDirectory(at: trash, withIntermediateDirectories: true)
      try "invalid-origin".write(
        to: trash.appendingPathComponent(".origin"), atomically: true, encoding: .utf8)
      let model = NotebookModel(root: root)
      await model.load()
      let saved = await model.save(body: "Must not publish", editing: nil)
      try require(
        model.error != nil && !saved, "Corrupt receipts allowed unsafe capture reconciliation")
      try require(
        try Data(contentsOf: snapshotFile) == before, "Failed reconciliation erased the draft")
    }
    try await withRoot("typing during attachment persistence preserves both changes") { root in
      let model = NotebookModel(root: root)
      await model.load()
      let adding = Task {
        await model.addCaptureAsset(
          data: Data(repeating: 7, count: 1024 * 1024), filename: "one.bin", kind: "file")
      }
      await Task.yield()
      model.draft = "Typed while the attachment was saving"
      model.saveDraft()
      let added = await adding.value
      try require(added, "Concurrent fixture did not add")
      try await settle()
      let launch = NotebookModel(root: root)
      await launch.load()
      try require(
        launch.draft == model.draft && launch.pendingAssets.count == 1,
        "Concurrent text and attachment snapshots overwrote one another")
    }
    try await withRoot("stale revision cannot overwrite the next draft identity") { root in
      let store = CaptureDraftStore(root: root)
      let latest = CaptureDraftSnapshot(body: "Current")
      try await store.save(latest, revision: 2)
      try await store.save(CaptureDraftSnapshot(body: "Stale"), revision: 1)
      let loaded = try await store.load()
      try require(
        loaded.memoID == latest.memoID && loaded.body == "Current",
        "Stale writer replaced current draft")
      try await store.saveBody(
        CaptureDraftSnapshot(memoID: latest.memoID, body: "Newer sidecar"), revision: 5)
      let withBody = try await CaptureDraftStore(root: root).load()
      try require(
        withBody.body == "Newer sidecar" && withBody.revision == 5,
        "Text sidecar revision did not survive restart")
      let model = NotebookModel(root: root)
      await model.load()
      model.draft = "Typed after restart"
      model.saveDraft()
      try await settle()
      let restarted = try await CaptureDraftStore(root: root).load()
      try require(
        restarted.body == model.draft && restarted.revision > withBody.revision,
        "Restart did not continue the monotonic revision")
      await model.discardDraft()
      let next = try await CaptureDraftStore(root: root).load()
      try require(
        next.memoID != latest.memoID && next.body.isEmpty,
        "A sidecar with a mismatched memo ID overlaid the next draft")
    }
    try await withRoot("quota and symbolic-link/oversized-file protections remain") { root in
      let store = CaptureDraftStore(root: root)
      let assets = (0..<11).map { index in
        PendingNoteAsset(
          data: asset, name: "\(index).txt", fileExtension: "txt", kind: "file", duration: nil)
      }
      try await expectDraftError {
        try await store.save(CaptureDraftSnapshot(assets: assets), revision: 1)
      }
      let metadata = root.appendingPathComponent(".daypage")
      try fm.createDirectory(at: metadata, withIntermediateDirectories: true)
      let snapshotFile = metadata.appendingPathComponent("capture-draft.json")
      let external = root.deletingLastPathComponent().appendingPathComponent("outside.json")
      try Data("[]".utf8).write(to: external)
      try fm.createSymbolicLink(at: snapshotFile, withDestinationURL: external)
      try await expectDraftError { _ = try await store.load() }
      try require(
        try Data(contentsOf: external) == Data("[]".utf8), "Symlink check mutated external bytes")
      try fm.removeItem(at: snapshotFile)
      try Data().write(to: snapshotFile)
      let handle = try FileHandle(forWritingTo: snapshotFile)
      try handle.truncate(atOffset: 73 * 1024 * 1024)
      try handle.close()
      try await expectDraftError { _ = try await store.load() }
      try fm.removeItem(at: snapshotFile)
      try fm.createSymbolicLink(
        at: metadata.appendingPathComponent("draft.txt"), withDestinationURL: external)
      try await expectDraftError { _ = try await store.load() }
      try fm.removeItem(at: metadata.appendingPathComponent("draft.txt"))
      try fm.createSymbolicLink(
        at: metadata.appendingPathComponent("capture-body.json"), withDestinationURL: external)
      try await expectDraftError { try await store.save(CaptureDraftSnapshot(), revision: 1) }
    }
    try await withRoot(
      "typing updates text without rewriting attachment snapshot bytes or timestamp"
    ) { root in
      let model = NotebookModel(root: root)
      await model.load()
      let added = await model.addCaptureAsset(data: asset, filename: "fixture.bin", kind: "file")
      try require(added, "Fixture attachment did not persist")
      let snapshotFile = root.appendingPathComponent(".daypage/capture-draft.json")
      let before = try Data(contentsOf: snapshotFile)
      let timestamp = try snapshotFile.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate
      model.draft = "Updated text, same attachment bytes"
      model.saveDraft()
      try await settle()
      let loaded = try await CaptureDraftStore(root: root).load()
      let finalTimestamp = try snapshotFile.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate
      try require(
        loaded.body == model.draft && loaded.assets.count == 1, "Text update lost draft content")
      try require(
        try Data(contentsOf: snapshotFile) == before && timestamp == finalTimestamp,
        "Typing rewrote the unchanged attachment snapshot")
    }
    try await withRoot("voice admission reserves 6 MiB without changing other capture admission") {
      root in
      let half = Data(count: 22 * 1024 * 1024)
      let first = PendingNoteAsset(
        data: half, name: "a.bin", fileExtension: "bin", kind: "file", duration: nil)
      let second = PendingNoteAsset(
        data: half, name: "b.bin", fileExtension: "bin", kind: "file", duration: nil)
      let byte = PendingNoteAsset(
        data: Data([1]), name: "c.bin", fileExtension: "bin", kind: "file", duration: nil)
      let withReserve = NotebookModel(root: root, fixtureAssets: [first, second])
      try require(
        withReserve.canRecordVoice && withReserve.canAddCaptureAsset,
        "A draft with 6 MiB reserve rejected voice")
      let insufficientReserve = NotebookModel(root: root, fixtureAssets: [first, second, byte])
      try require(
        !insufficientReserve.canRecordVoice && insufficientReserve.canAddCaptureAsset,
        "Voice did not reserve capacity independently from other media")
      let fullCount = NotebookModel(root: root, fixtureAssets: (0..<10).map { _ in byte })
      try require(
        !fullCount.canRecordVoice && !fullCount.canAddCaptureAsset,
        "The attachment count cap allowed recording")
    }
    print("PASS: 13 draft transaction regression groups")
  }
}
