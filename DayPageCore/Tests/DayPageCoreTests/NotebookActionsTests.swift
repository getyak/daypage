import XCTest
@testable import DayPageCore

final class NotebookActionsTests: XCTestCase {
    private var root: URL!
    private let separator = "\n\n<!-- daypage-memo-separator -->\n\n"
    private var date: Date { Date(timeIntervalSince1970: 1_793_347_200) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("daypage-actions-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("raw/assets"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func memo(_ body: String, attachments: [Memo.Attachment] = []) -> Memo {
        Memo(created: date, attachments: attachments, body: body)
    }

    @discardableResult
    private func write(_ content: String, base: URL? = nil) throws -> URL {
        let url = (base ?? root).appendingPathComponent("raw/2026-10-30.md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func first(_ store: NotebookStore, id: UUID? = nil) async throws -> NotebookEntry {
        let entries = try await store.entries()
        if let id { return try XCTUnwrap(entries.first { $0.memo.id == id }) }
        return try XCTUnwrap(entries.first)
    }

    func testUnknownYAMLChangeMakesAnExistingEntryStale() async throws {
        let original = memo("Original").toMarkdown().replacingOccurrences(of: "type: text", with: "type: text\nfuture: one")
        let file = try write(original)
        let store = NotebookStore(root: root)
        let entry = try await first(store)
        let external = original.replacingOccurrences(of: "future: one", with: "future: two")
        try external.write(to: file, atomically: true, encoding: .utf8)
        do {
            try await store.update(entry, body: "Stale edit")
            XCTFail("Unknown YAML changes must not be overwritten")
        } catch { }
        XCTAssertEqual(try String(contentsOf: file), external)
    }

    func testPinTogglePreservesUnknownYAMLBodyAndNeighborBytes() async throws {
        let original = memo("  Body\n\nExact spacing  ").toMarkdown().replacingOccurrences(of: "type: text", with: "type: text\nfuture:\n  nested: preserve-me")
        let neighbor = memo("Untouched").toMarkdown()
        let file = try write(original + separator + neighbor)
        let store = NotebookStore(root: root)
        let id = try XCTUnwrap(Memo.fromMarkdown(original)).id
        let entry = try await first(store, id: id)
        try await store.setPinned(entry, pinned: true)
        let pinned = try await first(store, id: id)
        XCTAssertNotNil(pinned.memo.pinnedAt)
        XCTAssertTrue(try String(contentsOf: file).hasSuffix(separator + neighbor))
        try await store.setPinned(pinned, pinned: false)
        XCTAssertEqual(try String(contentsOf: file), original + separator + neighbor)
    }

    func testTrashAndRelaunchRestoreExactOriginalFileAndAttachments() async throws {
        let attachment = root.appendingPathComponent("raw/assets/old.jpg")
        try Data([1, 2, 3]).write(to: attachment)
        let original = memo("Original", attachments: [.init(file: "old.jpg", kind: "photo")]).toMarkdown()
            .replacingOccurrences(of: "type: text", with: "type: text\nunknown: keep-this")
        let neighbor = memo("Neighbor").toMarkdown()
        let file = try write(original + separator + neighbor)
        let store = NotebookStore(root: root)
        let target = try await first(store, id: try XCTUnwrap(Memo.fromMarkdown(original)).id)
        let receipt = try await store.trash(target)
        XCTAssertEqual(receipt.entry, target)
        XCTAssertEqual(try String(contentsOf: file), neighbor)
        XCTAssertEqual(try Data(contentsOf: attachment), Data([1, 2, 3]))
        let reopened = NotebookStore(root: root)
        let receipts = try await reopened.trashReceipts()
        XCTAssertEqual(receipts.map(\.id), [receipt.id])
        try await reopened.restore(try XCTUnwrap(receipts.first))
        XCTAssertEqual(try String(contentsOf: file), original + separator + neighbor)
        let remaining = try await reopened.trashReceipts()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testTrashPreservesLegacySeparatorExactly() async throws {
        let first = memo("One").toMarkdown(), second = memo("Two").toMarkdown()
        let original = first + "\n\n---\n\n" + second
        let file = try write(original)
        let store = NotebookStore(root: root)
        let target = try await self.first(store, id: try XCTUnwrap(Memo.fromMarkdown(first)).id)
        let receipt = try await store.trash(target)
        XCTAssertEqual(try String(contentsOf: file), second)
        try await store.restore(receipt)
        XCTAssertEqual(try String(contentsOf: file), original)
    }

    func testRestorePreservesARecordAddedAfterTrash() async throws {
        let original = memo("Restore me")
        let file = try write(original.toMarkdown())
        let store = NotebookStore(root: root)
        let target = try await first(store)
        let receipt = try await store.trash(target)
        let added = memo("Added later")
        try await store.append(added)
        try await store.restore(receipt)
        let bytes = try String(contentsOf: file)
        XCTAssertTrue(bytes.contains(original.toMarkdown()))
        XCTAssertTrue(bytes.contains(added.toMarkdown()))
        let entries = try await store.entries()
        XCTAssertEqual(entries.count, 2)
    }

    func testStalePinAndTrashDoNotWriteEitherFileOrTrash() async throws {
        let file = try write(memo("Original").toMarkdown())
        let store = NotebookStore(root: root)
        let target = try await first(store)
        let external = try String(contentsOf: file).replacingOccurrences(of: "Original", with: "External")
        try external.write(to: file, atomically: true, encoding: .utf8)
        do { try await store.setPinned(target, pinned: true); XCTFail("Expected stale pin conflict") } catch { }
        do { _ = try await store.trash(target); XCTFail("Expected stale trash conflict") } catch { }
        XCTAssertEqual(try String(contentsOf: file), external)
        let receipts = try await store.trashReceipts()
        XCTAssertTrue(receipts.isEmpty)
    }

    func testDuplicateIdentityRefusesPinAndTrashWithoutAnyWrite() async throws {
        let note = memo("Duplicate").toMarkdown()
        let original = note + separator + note
        let file = try write(original)
        let target = NotebookEntry(memo: try XCTUnwrap(Memo.fromMarkdown(note)), day: "2026-10-30")
        let store = NotebookStore(root: root)
        do { try await store.setPinned(target, pinned: true); XCTFail("Expected ambiguous identity") } catch { }
        do { _ = try await store.trash(target); XCTFail("Expected ambiguous identity") } catch { }
        XCTAssertEqual(try String(contentsOf: file), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".daypage-trash").path))
    }

    func testRestoreRefusesAConflictingIdentityAndKeepsItsReceipt() async throws {
        let original = memo("Original")
        let file = try write(original.toMarkdown())
        let store = NotebookStore(root: root)
        let target = try await first(store)
        let receipt = try await store.trash(target)
        var conflict = original
        conflict.body = "External replacement"
        try await store.append(conflict)
        do { try await store.restore(receipt); XCTFail("Conflicting ID must survive") } catch { }
        XCTAssertEqual(try String(contentsOf: file), conflict.toMarkdown())
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".daypage-trash/\(receipt.id.uuidString)").path))
    }

    func testImportedNamespacePinTrashAndRestoreDoNotTouchLocalTwin() async throws {
        let note = memo("Same UUID in distinct namespaces")
        let local = try write(note.toMarkdown())
        let namespace = UUID().uuidString
        let imported = root.appendingPathComponent("imports/\(namespace)")
        let importedFile = try write(note.toMarkdown(), base: imported)
        let store = NotebookStore(root: root)
        let entries = try await store.entries()
        let target = try XCTUnwrap(entries.first { $0.namespace == namespace })
        try await store.setPinned(target, pinned: true)
        let updated = try await store.entries()
        let pinned = try XCTUnwrap(updated.first { $0.namespace == namespace })
        let receipt = try await store.trash(pinned)
        XCTAssertEqual(try String(contentsOf: importedFile), "")
        XCTAssertEqual(try String(contentsOf: local), note.toMarkdown())
        try await store.restore(receipt)
        XCTAssertTrue(try String(contentsOf: importedFile).contains("pinned_at:"))
        XCTAssertEqual(try String(contentsOf: local), note.toMarkdown())
    }

    func testNamespaceTraversalAndForeignRootReceiptsCannotWrite() async throws {
        let note = memo("Safe")
        let file = try write(note.toMarkdown())
        let store = NotebookStore(root: root)
        let traversal = NotebookEntry(memo: note, day: "2026-10-30", namespace: "../raw")
        do { _ = try await store.trash(traversal); XCTFail("Reject namespace traversal") } catch { }
        let target = try await first(store)
        let receipt = try await store.trash(target)
        let other = root.appendingPathComponent("other")
        _ = try write(note.toMarkdown(), base: other)
        do { try await NotebookStore(root: other).restore(receipt); XCTFail("Reject foreign receipt") } catch { }
        XCTAssertEqual(try String(contentsOf: file), "")
    }

    func testSymlinkedRecordAndTrashDirectoryAreRejected() async throws {
        let original = memo("Protected").toMarkdown()
        let outside = root.appendingPathComponent("protected.md")
        try original.write(to: outside, atomically: true, encoding: .utf8)
        let file = root.appendingPathComponent("raw/2026-10-30.md")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        let target = NotebookEntry(memo: try XCTUnwrap(Memo.fromMarkdown(original)), day: "2026-10-30")
        let store = NotebookStore(root: root)
        do { try await store.setPinned(target, pinned: true); XCTFail("Reject internal symlink") } catch { }
        do { _ = try await store.trash(target); XCTFail("Reject internal symlink") } catch { }
        XCTAssertEqual(try String(contentsOf: outside), original)
        try FileManager.default.removeItem(at: file)
        _ = try write(original)
        let linkedTrash = root.appendingPathComponent("other-trash")
        try FileManager.default.createDirectory(at: linkedTrash, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".daypage-trash"), withDestinationURL: linkedTrash)
        do { _ = try await store.trash(target); XCTFail("Reject trash symlink") } catch { }
        XCTAssertEqual(try String(contentsOf: file), original)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: linkedTrash.path).isEmpty)
    }

    func testImageAudioAndFileAssetsHaveCanonicalUniquePathsAndTypes() async throws {
        let store = NotebookStore(root: root)
        let cases: [(String, String, Memo.MemoType)] = [("photo", "jpg", .photo), ("audio", "m4a", .voice), ("file", "pdf", .mixed)]
        for (index, item) in cases.enumerated() {
            let note = memo("Attachment \(index)")
            try await store.append(note, assets: [.init(data: Data([UInt8(index), 9]), fileExtension: item.1, kind: item.0, duration: item.0 == "audio" ? 2.5 : nil)])
            let entries = try await store.entries()
            let entry = try XCTUnwrap(entries.first { $0.memo.id == note.id })
            XCTAssertEqual(entry.memo.type, item.2)
            let attachment = try XCTUnwrap(entry.memo.attachments.first)
            XCTAssertTrue(attachment.file.hasPrefix("raw/assets/"))
            XCTAssertEqual(attachment.kind, item.0)
            let url = try await store.assetURL(attachment.file, for: entry)
            XCTAssertNotNil(UUID(uuidString: url.deletingPathExtension().lastPathComponent))
            XCTAssertEqual(try Data(contentsOf: url), Data([UInt8(index), 9]))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("raw/assets").path).count, 3)
    }

    func testAppendingAssetsPreservesExistingAssetsAndRecordBytes() async throws {
        let originalAsset = root.appendingPathComponent("raw/assets/original.jpg")
        try Data([7]).write(to: originalAsset)
        let previous = memo("Previous", attachments: [.init(file: "original.jpg", kind: "photo")]).toMarkdown()
            .replacingOccurrences(of: "type: text", with: "type: text\ncustom: untouched")
        let file = try write(previous)
        let new = memo("New", attachments: [.init(file: "original.jpg", kind: "photo")])
        let store = NotebookStore(root: root)
        try await store.append(new, assets: [.init(data: Data([8]), fileExtension: "m4a", kind: "audio", duration: 1)])
        XCTAssertTrue(try String(contentsOf: file).hasPrefix(previous + separator))
        XCTAssertEqual(try Data(contentsOf: originalAsset), Data([7]))
        let entries = try await store.entries()
        let saved = try XCTUnwrap(entries.first { $0.memo.id == new.id })
        XCTAssertEqual(saved.memo.attachments.count, 2)
        XCTAssertEqual(saved.memo.attachments.first?.file, "original.jpg")
        XCTAssertEqual(saved.memo.type, .mixed)
    }

    func testAttachmentOnlyNoteCanBeSaved() async throws {
        let store = NotebookStore(root: root)
        try await store.append(memo(""), assets: [.init(data: Data([1]), fileExtension: "jpg", kind: "photo")])
        let saved = try await first(store)
        XCTAssertEqual(saved.memo.type, .photo)
        XCTAssertEqual(saved.memo.body, "")
    }

    func testInvalidAssetInputsAndOverLimitDataLeaveVaultUnchanged() async throws {
        let file = try write(memo("Original").toMarkdown())
        let original = try String(contentsOf: file)
        let store = NotebookStore(root: root)
        let invalid: [[NotebookAssetInput]] = [
            [.init(data: Data([1]), fileExtension: "../jpg", kind: "photo")],
            [.init(data: Data(), fileExtension: "jpg", kind: "photo")],
            [.init(data: Data([1]), fileExtension: "jpg", kind: "unknown")],
            [.init(data: Data([1]), fileExtension: "m4a", kind: "audio", duration: .infinity)],
            [.init(data: Data(repeating: 0, count: 25 * 1024 * 1024 + 1), fileExtension: "jpg", kind: "photo")],
            Array(repeating: .init(data: Data([1]), fileExtension: "jpg", kind: "photo"), count: 11)
        ]
        for inputs in invalid {
            do { try await store.append(memo("Invalid"), assets: inputs); XCTFail("Invalid input must fail") } catch { }
        }
        XCTAssertEqual(try String(contentsOf: file), original)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("raw/assets").path).isEmpty)
    }

    func testMalformedDayCommitKeepsOriginalAndDoesNotLeaveAssets() async throws {
        let file = try write("Original unparseable content")
        let store = NotebookStore(root: root)
        for kind in ["photo", "audio", "file"] {
            do {
                try await store.append(memo("Must not publish"), assets: [.init(data: Data([1]), fileExtension: "bin", kind: kind)])
                XCTFail("Malformed original must reject commit")
            } catch { }
        }
        XCTAssertEqual(try String(contentsOf: file), "Original unparseable content")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("raw/assets").path).isEmpty)
    }

    func testSymlinkedAssetsDirectoryCannotPublishOutsideTheVault() async throws {
        let assets = root.appendingPathComponent("raw/assets")
        try FileManager.default.removeItem(at: assets)
        let outside = root.appendingPathComponent("outside-assets")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: assets, withDestinationURL: outside)
        do {
            try await NotebookStore(root: root).append(memo("Must fail"), assets: [.init(data: Data([1]), fileExtension: "jpg", kind: "photo")])
            XCTFail("Reject symlinked assets even inside root")
        } catch { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("raw/2026-10-30.md").path))
    }

    func testCanonicallyEquivalentUnicodeByteChangesAreStillStale() async throws {
        let original = memo("Body").toMarkdown().replacingOccurrences(of: "type: text", with: "type: text\nfuture: caf\u{e9}")
        let file = try write(original)
        let store = NotebookStore(root: root)
        let entry = try await first(store)
        let external = original.replacingOccurrences(of: "caf\u{e9}", with: "cafe\u{301}")
        try external.write(to: file, atomically: true, encoding: .utf8)
        do { try await store.setPinned(entry, pinned: true); XCTFail("Exact original bytes changed") } catch { }
        XCTAssertEqual(try Data(contentsOf: file), Data(external.utf8))
    }

    func testFailedMarkdownReplacementRollsBackAllNewAssetKinds() async throws {
        let oldAsset = root.appendingPathComponent("raw/assets/previous.jpg")
        try Data([9]).write(to: oldAsset)
        let original = memo("Protected original").toMarkdown()
        let file = try write(original)
        let raw = root.appendingPathComponent("raw")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: raw.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: raw.path) }
        let store = NotebookStore(root: root)
        for kind in ["photo", "audio", "file"] {
            do {
                try await store.append(memo("Cannot replace day"), assets: [.init(data: Data([1, 2]), fileExtension: "bin", kind: kind)])
                XCTFail("Read-only raw directory must prevent atomic Markdown replacement")
            } catch { }
        }
        XCTAssertEqual(try String(contentsOf: file), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("raw/assets").path), ["previous.jpg"])
        XCTAssertEqual(try Data(contentsOf: oldAsset), Data([9]))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".daypage-assets-") })
    }

    func testRestoreChecksItsRecoveryDirectoryIsWritableBeforeChangingNotes() async throws {
        let original = memo("Restore only when its receipt can be consumed")
        let file = try write(original.toMarkdown())
        let store = NotebookStore(root: root)
        let target = try await first(store)
        let receipt = try await store.trash(target)
        let folder = root.appendingPathComponent(".daypage-trash/\(receipt.id.uuidString)")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        do { try await store.restore(receipt); XCTFail("Recovery metadata cannot be committed") } catch { }
        XCTAssertEqual(try String(contentsOf: file), "")
        let receipts = try await store.trashReceipts()
        XCTAssertEqual(receipts.map(\.id), [receipt.id])
    }

    func testTrashManifestTraversalAndSymlinkedBackupCannotBeReadOrRestored() async throws {
        let file = try write(memo("Safe recovery").toMarkdown())
        let store = NotebookStore(root: root)
        let target = try await first(store)
        let receipt = try await store.trash(target)
        let folder = root.appendingPathComponent(".daypage-trash/\(receipt.id.uuidString)")
        let manifest = folder.appendingPathComponent("manifest.json")
        let savedManifest = try Data(contentsOf: manifest)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: savedManifest) as? [String: Any])
        object["namespace"] = "../../outside"
        try JSONSerialization.data(withJSONObject: object).write(to: manifest)
        do { _ = try await store.trashReceipts(); XCTFail("Reject manifest traversal") } catch { }
        do { try await store.restore(receipt); XCTFail("Reject manifest traversal") } catch { }
        XCTAssertEqual(try String(contentsOf: file), "")
        try savedManifest.write(to: manifest)
        let backup = folder.appendingPathComponent("original.md")
        let outside = root.appendingPathComponent("unrelated.md")
        try FileManager.default.moveItem(at: backup, to: outside)
        try FileManager.default.createSymbolicLink(at: backup, withDestinationURL: outside)
        do { _ = try await store.trashReceipts(); XCTFail("Reject linked backups") } catch { }
        do { try await store.restore(receipt); XCTFail("Reject linked backups") } catch { }
        XCTAssertEqual(try String(contentsOf: file), "")
    }

    func testSameUUIDOnAnotherDayConflictsBeforeMutationOrRestore() async throws {
        let note = memo("Original")
        let original = note.toMarkdown()
        let file = try write(original)
        let store = NotebookStore(root: root)
        let target = try await first(store)
        let receipt = try await store.trash(target)
        let otherDay = root.appendingPathComponent("raw/2026-10-29.md")
        try original.write(to: otherDay, atomically: true, encoding: .utf8)
        do { try await store.restore(receipt); XCTFail("Reject duplicate ID across days") } catch { }
        do { try await store.append(note, assets: [.init(data: Data([1]), fileExtension: "jpg", kind: "photo")]); XCTFail("Reject duplicate ID across days") } catch { }
        XCTAssertEqual(try String(contentsOf: file), "")
        XCTAssertEqual(try String(contentsOf: otherDay), original)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("raw/assets").path).isEmpty)
    }

    func testTwoStoresCanAppendAssetsWithoutOverwritingNotesOrAssets() async throws {
        let stores = [NotebookStore(root: root), NotebookStore(root: root)]
        let notes = (0..<12).map { memo("Concurrent \($0)") }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, note) in notes.enumerated() {
                group.addTask {
                    try await stores[index % 2].append(note, assets: [.init(data: Data([UInt8(index)]), fileExtension: "jpg", kind: "photo")])
                }
            }
            try await group.waitForAll()
        }
        let saved = try await stores[0].entries()
        XCTAssertEqual(Set(saved.map(\.memo.id)), Set(notes.map(\.id)))
        XCTAssertEqual(Set(saved.flatMap { $0.memo.attachments.map(\.file) }).count, 12)
        for entry in saved {
            let attachment = try XCTUnwrap(entry.memo.attachments.first)
            let url = try await stores[0].assetURL(attachment.file, for: entry)
            let index = try XCTUnwrap(notes.firstIndex { $0.id == entry.memo.id })
            XCTAssertEqual(try Data(contentsOf: url), Data([UInt8(index)]))
        }
    }

    func testRestoredReceiptDoesNotReappearWhenTheSameNoteIsTrashedAgain() async throws {
        _ = try write(memo("Repeated recovery").toMarkdown())
        let store = NotebookStore(root: root)
        let original = try await first(store)
        let firstReceipt = try await store.trash(original)
        try await store.restore(firstReceipt)
        let restored = try await first(store)
        let secondReceipt = try await store.trash(restored)
        let remaining = try await NotebookStore(root: root).trashReceipts()
        XCTAssertEqual(remaining.map(\.id), [secondReceipt.id])
    }

    func testInterruptedRestoreJournalCanBeRetriedAndRecognizesCommittedNotes() async throws {
        let note = memo("Interrupted restore")
        _ = try write(note.toMarkdown())
        let store = NotebookStore(root: root)
        let target = try await first(store)
        let receipt = try await store.trash(target)
        let pending = root.appendingPathComponent(".daypage-trash/\(receipt.id.uuidString)/restoring")
        try Data().write(to: pending)
        let retryable = try await store.trashReceipts()
        XCTAssertEqual(retryable.map(\.id), [receipt.id])
        // Simulate the process exiting after the atomic note write, before journal finalization.
        try await store.append(note)
        let afterCommit = try await store.trashReceipts()
        XCTAssertTrue(afterCommit.isEmpty)
        let current = try await first(store)
        let nextReceipt = try await store.trash(current)
        let afterNextTrash = try await store.trashReceipts()
        XCTAssertEqual(afterNextTrash.map(\.id), [nextReceipt.id])
    }

    func testPreparedTrashBeforeRawCommitDoesNotAppearAsRecentlyDeleted() async throws {
        let original = memo("Still active").toMarkdown()
            .replacingOccurrences(of: "type: text", with: "type: text\nunknown: retained")
        let neighbor = memo("Neighbor survives").toMarkdown()
        let file = try write(original + separator + neighbor)
        let store = NotebookStore(root: root)
        let target = try await first(store, id: try XCTUnwrap(Memo.fromMarkdown(original)).id)
        let receipt = try await store.trash(target)
        let folder = root.appendingPathComponent(".daypage-trash/\(receipt.id.uuidString)")
        let committed = folder.appendingPathComponent("deleted")
        if FileManager.default.fileExists(atPath: committed.path) { try FileManager.default.removeItem(at: committed) }
        try Data().write(to: folder.appendingPathComponent("deleting"))
        // Reconstruct a process exit after durable backups, before replacing the raw file.
        try (original + separator + neighbor).write(to: file, atomically: true, encoding: .utf8)
        let reopened = NotebookStore(root: root)
        let active = try await reopened.entries()
        let deleted = try await reopened.trashReceipts()
        XCTAssertEqual(active.count, 2)
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), Data((original + separator + neighbor).utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("original.md").path))
        // A cancelled preparation cannot turn into a real deletion if this record changes later.
        try neighbor.write(to: file, atomically: true, encoding: .utf8)
        let afterExternalChange = try await NotebookStore(root: root).trashReceipts()
        XCTAssertTrue(afterExternalChange.isEmpty)
    }

    func testTrashAfterRawCommitButBeforeFinalMarkerRemainsRecoverable() async throws {
        let original = memo("Deleted during interrupted commit").toMarkdown()
        let file = try write(original)
        let store = NotebookStore(root: root)
        let target = try await first(store)
        let receipt = try await store.trash(target)
        let folder = root.appendingPathComponent(".daypage-trash/\(receipt.id.uuidString)")
        let committed = folder.appendingPathComponent("deleted")
        if FileManager.default.fileExists(atPath: committed.path) { try FileManager.default.removeItem(at: committed) }
        try Data().write(to: folder.appendingPathComponent("deleting"))
        // Raw replacement succeeded, but the process exited before finalizing deletion metadata.
        let reopened = NotebookStore(root: root)
        let deleted = try await reopened.trashReceipts()
        XCTAssertEqual(deleted.map(\.id), [receipt.id])
        try await reopened.restore(try XCTUnwrap(deleted.first))
        XCTAssertEqual(try Data(contentsOf: file), Data(original.utf8))
    }

    func testCommittedTrashSurvivesAnExactOriginalIdentityBeingReintroduced() async throws {
        let original = memo("Real deleted copy").toMarkdown()
        let file = try write(original)
        let store = NotebookStore(root: root)
        let target = try await first(store)
        let receipt = try await store.trash(target)
        try original.write(to: file, atomically: true, encoding: .utf8)
        let reopened = NotebookStore(root: root)
        let deleted = try await reopened.trashReceipts()
        XCTAssertEqual(deleted.map(\.id), [receipt.id])
        do { try await reopened.restore(try XCTUnwrap(deleted.first)); XCTFail("Reintroduced identity conflicts with the real deleted copy") } catch { }
        XCTAssertEqual(try Data(contentsOf: file), Data(original.utf8))
        let remaining = try await reopened.trashReceipts()
        XCTAssertEqual(remaining.map(\.id), [receipt.id])
    }

    func testIncompleteTrashPreparationKeepsBackupAndDoesNotBlockOtherReceipts() async throws {
        let firstMemo = memo("First").toMarkdown()
        let secondMemo = memo("Second").toMarkdown()
        let file = try write(firstMemo + separator + secondMemo)
        let store = NotebookStore(root: root)
        let target = try await first(store, id: try XCTUnwrap(Memo.fromMarkdown(firstMemo)).id)
        let receipt = try await store.trash(target)
        let partial = root.appendingPathComponent(".daypage-trash/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: false)
        try secondMemo.write(to: partial.appendingPathComponent("original.md"), atomically: true, encoding: .utf8)
        let deleted = try await NotebookStore(root: root).trashReceipts()
        XCTAssertEqual(deleted.map(\.id), [receipt.id])
        XCTAssertEqual(try String(contentsOf: file), secondMemo)
        XCTAssertEqual(try String(contentsOf: partial.appendingPathComponent("original.md")), secondMemo)
    }
}
