import CoreGraphics
import DayPageCapture
import Foundation
import ImageIO
import XCTest
@testable import DayPageCore

final class ScreenshotInboxTests: XCTestCase {
  private func scratch() throws -> URL {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("daypage-screenshot-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }

  private func png(red: CGFloat = 0.2) throws -> Data {
    let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
      bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: red, green: 0.4, blue: 0.3, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    let image = try XCTUnwrap(context.makeImage())
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
  }

  func testStageRestartReadAndExplicitDiscard() async throws {
    let root = try scratch().appendingPathComponent("inbox")
    let first = ScreenshotInbox(root: root), data = try png()
    let capture = try await first.stage(data)
    let restarted = ScreenshotInbox(root: root)
    let captures = try await restarted.captures()
    XCTAssertEqual(captures, [capture])
    XCTAssertEqual(capture.kind, .png)
    let recovered = try await restarted.image(capture)
    XCTAssertEqual(recovered, data)
    try await restarted.remove(capture)
    let remaining = try await restarted.captures()
    XCTAssertTrue(remaining.isEmpty)
  }

  func testRejectsInvalidEmptyTruncatedAndOversizeBytes() async throws {
    let inbox = ScreenshotInbox(root: try scratch().appendingPathComponent("inbox"))
    for data in [Data(), Data("not an image".utf8), Data(try png().prefix(32)),
      Data(repeating: 0, count: ScreenshotInbox.maximumBytes + 1)] {
      do { _ = try await inbox.stage(data); XCTFail("Invalid input accepted") } catch { }
    }
    let captures = try await inbox.captures()
    XCTAssertTrue(captures.isEmpty)
  }

  func testTamperedOriginalCannotBeReadOrDeleted() async throws {
    let root = try scratch().appendingPathComponent("inbox")
    let inbox = ScreenshotInbox(root: root), capture = try await inbox.stage(png())
    let original = root.appendingPathComponent(capture.id.uuidString + "/original.image")
    try Data("changed".utf8).write(to: original)
    do { _ = try await inbox.image(capture); XCTFail("Tampered bytes read") } catch { }
    do { try await inbox.remove(capture); XCTFail("Tampered evidence removed") } catch { }
    XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
  }

  func testSymlinkedRootAndOriginalAreRejectedWithoutTouchingTarget() async throws {
    let scratch = try scratch(), outside = scratch.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    let link = scratch.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    do { _ = try await ScreenshotInbox(root: link).stage(png()); XCTFail("Root link followed") } catch { }
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    let root = scratch.appendingPathComponent("inbox"), inbox = ScreenshotInbox(root: root)
    let capture = try await inbox.stage(png())
    let original = root.appendingPathComponent(capture.id.uuidString + "/original.image")
    try FileManager.default.removeItem(at: original)
    let target = outside.appendingPathComponent("private.png")
    let data = try png(); try data.write(to: target)
    try FileManager.default.createSymbolicLink(at: original, withDestinationURL: target)
    do { _ = try await inbox.image(capture); XCTFail("Image link followed") } catch { }
    do { try await inbox.remove(capture); XCTFail("Image link deleted") } catch { }
    XCTAssertEqual(try Data(contentsOf: target), data)
  }

  func testPendingAndInterruptedStagingQuotas() async throws {
    let root = try scratch().appendingPathComponent("inbox"), inbox = ScreenshotInbox(root: root)
    let data = try png()
    for _ in 0..<ScreenshotInbox.maximumPending { _ = try await inbox.stage(data) }
    do { _ = try await inbox.stage(data); XCTFail("Pending quota ignored") } catch { }
    let otherRoot = try scratch().appendingPathComponent("inbox")
    let orphan = otherRoot.appendingPathComponent(".staging-interrupted")
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
    let file = orphan.appendingPathComponent("original.image")
    XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: UInt64(ScreenshotInbox.maximumStoredBytes)); try handle.close()
    do { _ = try await ScreenshotInbox(root: otherRoot).stage(data); XCTFail("Orphan quota ignored") } catch { }
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    let recoveryInbox = ScreenshotInbox(root: otherRoot)
    let recoveries = try await recoveryInbox.recoveries()
    XCTAssertEqual(recoveries.count, 1)
    try await recoveryInbox.discardRecovery(recoveries[0])
    _ = try await recoveryInbox.stage(data)
  }

  func testIndependentWritersPublishCompleteUniqueCaptures() async throws {
    let root = try scratch().appendingPathComponent("inbox"), data = try png()
    let first = ScreenshotInbox(root: root), second = ScreenshotInbox(root: root)
    async let a = first.stage(data)
    async let b = second.stage(data)
    let result = try await [a, b]
    XCTAssertNotEqual(result[0].id, result[1].id)
    let captures = try await first.captures()
    XCTAssertEqual(captures.count, 2)
    for capture in captures { let stored = try await second.image(capture); XCTAssertEqual(stored, data) }
  }

  func testConfirmedSaveAndCrashRetryPreserveStableIdentity() async throws {
    let root = try scratch(), inbox = ScreenshotInbox(root: root.appendingPathComponent("inbox"))
    let store = NotebookStore(root: root.appendingPathComponent("vault"))
    let data = try png(), capture = try await inbox.stage(data)
    let before = try await store.entries(); XCTAssertTrue(before.isEmpty)
    // Reproduce the crash boundary: raw commit completed, inbox acknowledgement did not.
    try await store.append(Memo(id: capture.id, created: capture.created, body: "Original caption"),
      assets: [NotebookAssetInput(data: data, fileExtension: "png", kind: "photo")])
    let result = try await ScreenshotNoteSaver.save(capture, caption: "Retry caption", inbox: inbox, store: store)
    XCTAssertTrue(result.alreadySaved); XCTAssertTrue(result.inboxAcknowledged)
    let entries = try await store.entries()
    XCTAssertEqual(entries.count, 1); XCTAssertEqual(entries[0].memo.body, "Original caption")
    XCTAssertEqual(entries[0].memo.attachments.count, 1)
    let pending = try await inbox.captures(); XCTAssertTrue(pending.isEmpty)
  }

  func testConfirmedSaveCreatesNoteWithOriginalImageAndCaption() async throws {
    let root = try scratch(), inbox = ScreenshotInbox(root: root.appendingPathComponent("inbox"))
    let store = NotebookStore(root: root.appendingPathComponent("vault"))
    let data = try png(), capture = try await inbox.stage(data)
    let result = try await ScreenshotNoteSaver.save(capture, caption: "Synthetic screenshot", inbox: inbox, store: store)
    XCTAssertFalse(result.alreadySaved); XCTAssertTrue(result.inboxAcknowledged)
    let entries = try await store.entries(); XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries[0].memo.id, capture.id)
    XCTAssertEqual(entries[0].memo.body, "Synthetic screenshot")
    let asset = try await store.assetURL(entries[0].memo.attachments[0].file, for: entries[0])
    XCTAssertEqual(try Data(contentsOf: asset), data)
  }

  func testWriteFailureKeepsPendingOriginalAndExistingDraftBytes() async throws {
    let root = try scratch(), inbox = ScreenshotInbox(root: root.appendingPathComponent("inbox"))
    let data = try png(), capture = try await inbox.stage(data)
    let vault = root.appendingPathComponent("vault")
    let untouched = Data("existing unrelated bytes".utf8)
    try untouched.write(to: vault) // A file cannot become a writable Vault directory.
    do {
      _ = try await ScreenshotNoteSaver.save(capture, caption: "retry", inbox: inbox, store: NotebookStore(root: vault))
      XCTFail("Broken destination reported success")
    } catch { }
    let preserved = try await inbox.image(capture)
    XCTAssertEqual(preserved, data)
    XCTAssertEqual(try Data(contentsOf: vault), untouched)
  }

  func testCancelledStageDoesNotPublish() async throws {
    let inbox = ScreenshotInbox(root: try scratch().appendingPathComponent("inbox")), data = try png()
    let work = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await inbox.stage(data)
    }
    do { _ = try await work.value; XCTFail("Cancelled task published") } catch is CancellationError { }
    let pending = try await inbox.captures()
    XCTAssertTrue(pending.isEmpty)
  }

  func testCrashRetryDoesNotResurrectTrashedCapture() async throws {
    let root = try scratch(), inbox = ScreenshotInbox(root: root.appendingPathComponent("inbox"))
    let store = NotebookStore(root: root.appendingPathComponent("vault"))
    let data = try png(), capture = try await inbox.stage(data)
    try await store.append(Memo(id: capture.id, created: capture.created, body: "Already deleted"),
      assets: [NotebookAssetInput(data: data, fileExtension: "png", kind: "photo")])
    let entries = try await store.entries()
    _ = try await store.trash(entries[0])
    let result = try await ScreenshotNoteSaver.save(capture, caption: "Must not resurrect", inbox: inbox, store: store)
    XCTAssertTrue(result.alreadySaved); XCTAssertTrue(result.inboxAcknowledged)
    let after = try await store.entries(); XCTAssertTrue(after.isEmpty)
    let receipts = try await store.trashReceipts(); XCTAssertEqual(receipts.count, 1)
  }

  func testRawOnlyInterruptionIsVisibleAndExplicitlyRecoverable() async throws {
    let root = try scratch().appendingPathComponent("inbox")
    let directory = root.appendingPathComponent(".staging-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try png(); try data.write(to: directory.appendingPathComponent("original.image"))
    let inbox = ScreenshotInbox(root: root)
    let before = try await inbox.captures(); XCTAssertTrue(before.isEmpty)
    let recoveries = try await inbox.recoveries(); XCTAssertEqual(recoveries.count, 1)
    let capture = try await inbox.recover(recoveries[0])
    let original = try await inbox.image(capture); XCTAssertEqual(original, data)
    let restarted = ScreenshotInbox(root: root)
    let ready = try await restarted.captures(); XCTAssertEqual(ready, [capture])
    let repeated = try await restarted.captures(); XCTAssertEqual(repeated, [capture])
    let remaining = try await restarted.recoveries(); XCTAssertTrue(remaining.isEmpty)
  }

  func testCompleteEnvelopeBeforeMoveIsPublishedOnRestartOnce() async throws {
    let root = try scratch().appendingPathComponent("inbox"), inbox = ScreenshotInbox(root: root)
    let capture = try await inbox.stage(png())
    try FileManager.default.moveItem(at: root.appendingPathComponent(capture.id.uuidString),
      to: root.appendingPathComponent(".staging-" + capture.id.uuidString))
    let restarted = ScreenshotInbox(root: root)
    let first = try await restarted.captures(); XCTAssertEqual(first, [capture])
    let second = try await restarted.captures(); XCTAssertEqual(second, [capture])
    let recovery = try await restarted.recoveries(); XCTAssertTrue(recovery.isEmpty)
  }

  func testDamagedMetadataIsPreservedDuringUserRecovery() async throws {
    let root = try scratch().appendingPathComponent("inbox"), inbox = ScreenshotInbox(root: root)
    let data = try png(), capture = try await inbox.stage(data)
    let interrupted = root.appendingPathComponent(".staging-" + capture.id.uuidString)
    try FileManager.default.moveItem(at: root.appendingPathComponent(capture.id.uuidString), to: interrupted)
    let damaged = Data("{incomplete metadata".utf8)
    try damaged.write(to: interrupted.appendingPathComponent("capture.json"))
    let pending = try await inbox.captures(); XCTAssertTrue(pending.isEmpty)
    let items = try await inbox.recoveries(); XCTAssertEqual(items.count, 1)
    let recovered = try await inbox.recover(items[0])
    XCTAssertEqual(recovered.id, capture.id)
    let retained = root.appendingPathComponent(recovered.id.uuidString + "/capture.previous.json")
    XCTAssertEqual(try Data(contentsOf: retained), damaged)
    let image = try await inbox.image(recovered); XCTAssertEqual(image, data)
  }

  func testUndecodableOriginalRemainsVisibleUntilExplicitDiscard() async throws {
    let root = try scratch().appendingPathComponent("inbox")
    let interrupted = root.appendingPathComponent(".staging-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: interrupted, withIntermediateDirectories: true)
    let original = interrupted.appendingPathComponent("original.image")
    let bytes = Data("partially written image".utf8); try bytes.write(to: original)
    let inbox = ScreenshotInbox(root: root), items = try await inbox.recoveries()
    XCTAssertEqual(items.count, 1)
    do { _ = try await inbox.recover(items[0]); XCTFail("Broken image recovered") } catch { }
    XCTAssertEqual(try Data(contentsOf: original), bytes)
    let retained = try await inbox.recoveries(); XCTAssertEqual(retained, items)
    try await inbox.discardRecovery(items[0])
    let after = try await inbox.recoveries(); XCTAssertTrue(after.isEmpty)
  }

  func testUUIDCollisionWithoutMatchingPhotoNeverAcknowledgesCapture() async throws {
    let root = try scratch(), inbox = ScreenshotInbox(root: root.appendingPathComponent("inbox"))
    let store = NotebookStore(root: root.appendingPathComponent("vault")), data = try png()
    let capture = try await inbox.stage(data)
    try await store.append(Memo(id: capture.id, body: "Unrelated note"))
    do {
      _ = try await ScreenshotNoteSaver.save(capture, caption: "Incoming screenshot", inbox: inbox, store: store)
      XCTFail("Unrelated UUID acknowledged")
    } catch ScreenshotInboxError.changed { }
    let original = try await inbox.image(capture); XCTAssertEqual(original, data)
    let notes = try await store.entries(); XCTAssertEqual(notes.count, 1)
    XCTAssertEqual(notes[0].memo.body, "Unrelated note")
  }

  func testConcurrentConfirmationsCannotCreateTwoNotes() async throws {
    let root = try scratch(), inbox = ScreenshotInbox(root: root.appendingPathComponent("inbox"))
    let capture = try await inbox.stage(png()), vault = root.appendingPathComponent("vault")
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<2 {
        group.addTask {
          _ = try? await ScreenshotNoteSaver.save(capture, caption: "Concurrent confirmation", inbox: inbox,
            store: NotebookStore(root: vault))
        }
      }
    }
    let notes = try await NotebookStore(root: vault).entries()
    XCTAssertEqual(notes.count, 1)
    XCTAssertEqual(notes[0].memo.id, capture.id)
  }

  func testUUIDCollisionWithDifferentPhotoPreservesBothOriginals() async throws {
    let root = try scratch(), inbox = ScreenshotInbox(root: root.appendingPathComponent("inbox"))
    let store = NotebookStore(root: root.appendingPathComponent("vault"))
    let incoming = try png(), existing = try png(red: 0.8), capture = try await inbox.stage(incoming)
    try await store.append(Memo(id: capture.id, body: "Different existing photo"),
      assets: [NotebookAssetInput(data: existing, fileExtension: "png", kind: "photo")])
    do {
      _ = try await ScreenshotNoteSaver.save(capture, caption: "Must not overwrite", inbox: inbox, store: store)
      XCTFail("Different photo acknowledged as this capture")
    } catch ScreenshotInboxError.changed { }
    let original = try await inbox.image(capture); XCTAssertEqual(original, incoming)
    let notes = try await store.entries(); XCTAssertEqual(notes.count, 1)
    let oldAsset = try await store.assetURL(notes[0].memo.attachments[0].file, for: notes[0])
    XCTAssertEqual(try Data(contentsOf: oldAsset), existing)
  }

  func testPublishedMetadataDamageAlsoHasVisibleRecovery() async throws {
    let root = try scratch().appendingPathComponent("inbox"), inbox = ScreenshotInbox(root: root)
    let data = try png(), capture = try await inbox.stage(data)
    try Data("damaged".utf8).write(to: root.appendingPathComponent(capture.id.uuidString + "/capture.json"))
    let items = try await inbox.recoveries(); XCTAssertEqual(items.count, 1)
    let recovered = try await inbox.recover(items[0])
    XCTAssertEqual(recovered.id, capture.id)
    let original = try await inbox.image(recovered); XCTAssertEqual(original, data)
  }
}
