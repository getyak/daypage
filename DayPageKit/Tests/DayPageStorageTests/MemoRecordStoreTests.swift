import XCTest
import DayPageModels
@testable import DayPageStorage

final class MemoRecordStoreTests: XCTestCase {
    private var vaultURL: URL!
    private let day = Date(timeIntervalSince1970: 1_775_520_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoRecordStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: vaultURL.appendingPathComponent("raw", isDirectory: true),
            withIntermediateDirectories: true
        )
        VaultInitializer.testOverrideURL = vaultURL
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = nil
        if let vaultURL {
            try? FileManager.default.removeItem(at: vaultURL)
        }
        try super.tearDownWithError()
    }

    func testLoadsUpdatesAndDeletesByStableID() async throws {
        let target = Memo(id: UUID(), created: day, body: "before")
        let sibling = Memo(id: UUID(), created: day.addingTimeInterval(10), body: "keep")
        try RawStorage.rewrite([target, sibling], for: day)

        let store = MemoRecordStore()
        let loaded = try await store.memo(id: target.id, day: day)
        XCTAssertEqual(loaded.body, "before")

        let updated = try await store.updateBody(id: target.id, day: day, body: "after")
        XCTAssertEqual(updated.body, "after")
        XCTAssertEqual(try RawStorage.read(for: day).first(where: { $0.id == sibling.id })?.body, "keep")

        try await store.delete(id: target.id, day: day)
        let remaining = try RawStorage.read(for: day)
        XCTAssertEqual(remaining.map(\.id), [sibling.id])

        try await store.restore(target, day: day)
        XCTAssertEqual(try RawStorage.read(for: day).map(\.id), [target.id, sibling.id])

        // A repeated undo or a delayed sync replay must stay idempotent.
        try await store.restore(target, day: day)
        XCTAssertEqual(try RawStorage.read(for: day).map(\.id), [target.id, sibling.id])
    }

    func testMissingRecordAndEmptyBodyFailWithoutWriting() async throws {
        let memo = Memo(id: UUID(), created: day, body: "original")
        try RawStorage.rewrite([memo], for: day)
        let store = MemoRecordStore()

        do {
            _ = try await store.updateBody(id: memo.id, day: day, body: "  \n")
            XCTFail("Expected emptyBody")
        } catch {
            XCTAssertEqual(error as? MemoRecordStoreError, .emptyBody)
        }

        do {
            try await store.delete(id: UUID(), day: day)
            XCTFail("Expected notFound")
        } catch {
            guard let storeError = error as? MemoRecordStoreError,
                  case .notFound = storeError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try RawStorage.read(for: day), [memo])
    }

    func testTargetedFieldsPreserveBackgroundWritesAndCapturedVault() async throws {
        let root = try XCTUnwrap(vaultURL)
        let target = Memo(id: UUID(), created: day, body: "initial")
        let background = Memo(id: UUID(), created: day.addingTimeInterval(10), body: "background")
        try RawStorage.append(target, vaultRoot: root)
        try RawStorage.append(background, vaultRoot: root)
        let otherRoot = root.appendingPathComponent("another-vault")
        VaultInitializer.testOverrideURL = otherRoot
        let store = MemoRecordStore()
        let pinnedAt = day.addingTimeInterval(20)
        _ = try await store.updateBody(id: target.id, day: day, body: "latest", vaultRoot: root)
        _ = try await store.setPinnedAt(id: target.id, day: day, pinnedAt: pinnedAt, vaultRoot: root)
        let pinned = try await store.memo(id: target.id, day: day, vaultRoot: root)
        XCTAssertEqual(pinned.body, "latest")
        XCTAssertEqual(pinned.pinnedAt, pinnedAt)
        XCTAssertEqual(try RawStorage.read(for: day, vaultRoot: root).first { $0.id == background.id }, background)
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherRoot.path))
        try await store.delete(id: target.id, day: day, vaultRoot: root)
        try await store.restore(pinned, day: day, vaultRoot: root)
        XCTAssertEqual(try RawStorage.read(for: day, vaultRoot: root).count, 2)
    }

    func testPinCannotResurrectDeletedRecordOrReplaceRemoteBody() async throws {
        let target = Memo(id: UUID(), created: day, body: "local")
        try RawStorage.append(target)
        let store = MemoRecordStore()
        _ = try await store.updateBody(id: target.id, day: day, body: "updated elsewhere")
        let pinned = try await store.setPinnedAt(id: target.id, day: day, pinnedAt: day)
        XCTAssertEqual(pinned.body, "updated elsewhere")
        try await store.delete(id: target.id, day: day)
        do {
            _ = try await store.setPinnedAt(id: target.id, day: day, pinnedAt: nil)
            XCTFail("Pinning a deleted ID must fail without resurrecting it")
        } catch {
            XCTAssertEqual(error as? MemoRecordStoreError, .notFound(target.id))
        }
        XCTAssertTrue(try RawStorage.read(for: day).isEmpty)
    }

    func testCaptureAttachmentFilingIsSourceBoundAndIdempotent() throws {
        let memo = Memo(id: UUID(), created: day, body: "source")
        try RawStorage.rewrite([memo], for: day)
        let attachment = Memo.Attachment(
            file: "raw/assets/capture_fixed.pdf",
            kind: "file"
        )

        let first = try XCTUnwrap(try RawStorage.appendAttachment(
            attachment,
            toMemoID: memo.id
        ))
        let replay = try XCTUnwrap(try RawStorage.appendAttachment(
            attachment,
            toMemoID: memo.id
        ))

        XCTAssertEqual(first.attachments, [attachment])
        XCTAssertEqual(replay.attachments, [attachment])
        XCTAssertEqual(RawStorage.memo(id: memo.id)?.attachments, [attachment])
        XCTAssertNil(try RawStorage.appendAttachment(attachment, toMemoID: UUID()))
        XCTAssertNil(try RawStorage.appendAttachment(
            .init(file: "../outside", kind: "file"),
            toMemoID: memo.id
        ))
    }

    func testCanonicalDayKeyTargetsOwningFileAndFailsClosedOnInvalidDays() async throws {
        let root = try XCTUnwrap(vaultURL)
        // 2026-10-02T10:00:00Z is already 2026-10-03 in +14; the owning file
        // key is whatever the entry point recorded — never re-derived here.
        let memo = Memo(id: UUID(), created: Date(timeIntervalSince1970: 1_790_935_200), body: "owning file")
        let oct3URL = root.appendingPathComponent("raw/2026-10-03.md")
        try RawStorage.atomicWrite(string: RawStorage.serialize([memo]), to: oct3URL)
        let before = try Data(contentsOf: oct3URL)
        let store = MemoRecordStore()

        let updated = try await store.updateBody(
            id: memo.id, dayString: "2026-10-03", body: "edited", vaultRoot: root
        )
        XCTAssertEqual(updated.body, "edited")
        XCTAssertEqual(try RawStorage.read(dayString: "2026-10-03", vaultRoot: root).map(\.id), [memo.id])

        for invalid in ["", "2026-10-3", "2026-02-30", "../2026-10-03", "2026-10-03.md"] {
            do {
                _ = try await store.updateBody(id: memo.id, dayString: invalid, body: "x", vaultRoot: root)
                XCTFail("Expected invalidDay for \(invalid)")
            } catch {
                XCTAssertEqual(error as? MemoRecordStoreError, .invalidDay(invalid))
            }
            do {
                _ = try RawStorage.read(dayString: invalid, vaultRoot: root)
                XCTFail("Expected invalidDayString for \(invalid)")
            } catch let error as RawStorageError {
                guard case .invalidDayString = error else {
                    return XCTFail("Unexpected RawStorageError \(error)")
                }
            }
            XCTAssertNil(RawStorage.fileURL(forDayString: invalid, vaultRoot: root))
        }
        XCTAssertNotEqual(try Data(contentsOf: oct3URL), before)
    }

    func testWriteNotificationCarriesActualWrittenDayStringKey() async throws {
        let root = try XCTUnwrap(vaultURL)
        let memo = Memo(id: UUID(), created: day, body: "notify")
        let dayString = RawStorage.dayString(for: day)
        let store = MemoRecordStore()

        let observed = expectation(description: "rawStorageDidWrite carries dayString")
        var receivedKey: String?
        let token = NotificationCenter.default.addObserver(
            forName: .rawStorageDidWrite,
            object: nil,
            queue: nil
        ) { notification in
            if let key = notification.userInfo?[RawStorage.writtenDayStringKey] as? String {
                receivedKey = key
                observed.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        try await store.restore(memo, dayString: dayString, vaultRoot: root)
        await fulfillment(of: [observed], timeout: 2)
        XCTAssertEqual(receivedKey, dayString)
    }
}
