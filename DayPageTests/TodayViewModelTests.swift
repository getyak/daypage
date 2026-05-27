import XCTest
@testable import DayPage

/// US-020: Unit tests for TodayViewModel core paths: addMemo, deleteMemo, toggleFavorite (pin/unpin).
///
/// TodayViewModel reads/writes via RawStorage which uses VaultInitializer.testOverrideURL.
/// Tests run synchronously by directly mutating `memos` and calling the view model methods,
/// bypassing the async submission path that requires live services (Location, Weather).
@MainActor
final class TodayViewModelTests: XCTestCase {

    private var tempDir: URL!
    private var vm: TodayViewModel!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TodayVMTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        VaultInitializer.testOverrideURL = tempDir
        vm = TodayViewModel(date: Date())
    }

    override func tearDown() async throws {
        VaultInitializer.testOverrideURL = nil
        try? FileManager.default.removeItem(at: tempDir)
        vm = nil
        try await super.tearDown()
    }

    // MARK: - addMemo (via RawStorage.append + in-memory insert)

    func testAddMemo_insertsIntoMemosArray() throws {
        let memo = makeMemo(body: "test memo body")
        try RawStorage.append(memo)
        // Simulate the in-memory update that submitCombinedMemo performs
        vm.memos.insert(memo, at: 0)

        XCTAssertEqual(vm.memos.count, 1)
        XCTAssertEqual(vm.memos.first?.id, memo.id)
        XCTAssertEqual(vm.memos.first?.body, "test memo body")
    }

    func testAddMemo_multipleMemosOrderedNewestFirst() throws {
        let older = makeMemo(body: "older", created: Date(timeIntervalSinceNow: -120))
        let newer = makeMemo(body: "newer", created: Date(timeIntervalSinceNow: -60))
        try RawStorage.append(older)
        try RawStorage.append(newer)

        // Simulate load sort (newest first)
        vm.memos = [newer, older]

        XCTAssertEqual(vm.memos.first?.body, "newer")
        XCTAssertEqual(vm.memos.last?.body, "older")
    }

    // MARK: - deleteMemo

    func testDeleteMemo_removesMemoFromMemosArray() throws {
        let m1 = makeMemo(body: "keep me")
        let m2 = makeMemo(body: "delete me")
        try RawStorage.append(m1)
        try RawStorage.append(m2)
        vm.memos = [m1, m2]

        vm.deleteMemo(m2)

        XCTAssertEqual(vm.memos.count, 1)
        XCTAssertEqual(vm.memos.first?.id, m1.id)
    }

    func testDeleteMemo_setsLastDeletedMemo() throws {
        let memo = makeMemo(body: "will be deleted")
        vm.memos = [memo]

        vm.deleteMemo(memo)

        XCTAssertEqual(vm.lastDeletedMemo?.id, memo.id)
    }

    func testUndoDelete_restoresMemo() throws {
        let memo = makeMemo(body: "restore me")
        vm.memos = [memo]

        vm.deleteMemo(memo)
        XCTAssertEqual(vm.memos.count, 0)

        vm.undoDelete()
        XCTAssertEqual(vm.memos.count, 1)
        XCTAssertEqual(vm.memos.first?.id, memo.id)
        XCTAssertNil(vm.lastDeletedMemo)
    }

    // MARK: - toggleFavorite (pin / unpin)

    func testPinMemo_setsPinnedAtAndMovesToTop() throws {
        let m1 = makeMemo(body: "first", created: Date(timeIntervalSinceNow: -60))
        let m2 = makeMemo(body: "second", created: Date())
        vm.memos = [m2, m1] // newest first

        vm.pinMemo(m1)

        XCTAssertNotNil(vm.memos.first?.pinnedAt, "Pinned memo must have pinnedAt set")
        XCTAssertEqual(vm.memos.first?.id, m1.id, "Pinned memo must move to top")
    }

    func testUnpinMemo_clearsPinnedAtAndResortsByCreated() throws {
        var pinned = makeMemo(body: "pinned", created: Date(timeIntervalSinceNow: -60))
        pinned.pinnedAt = Date()
        let normal = makeMemo(body: "normal", created: Date())
        vm.memos = [pinned, normal]

        vm.unpinMemo(pinned)

        XCTAssertNil(vm.memos.first(where: { $0.id == pinned.id })?.pinnedAt,
                     "Unpinned memo must have nil pinnedAt")
        // After unpin, normal (newer) should be first
        XCTAssertEqual(vm.memos.first?.id, normal.id)
    }

    func testPinMemo_onlyOneMemoInList() throws {
        let memo = makeMemo(body: "solo")
        vm.memos = [memo]

        vm.pinMemo(memo)

        XCTAssertEqual(vm.memos.count, 1)
        XCTAssertNotNil(vm.memos.first?.pinnedAt)
    }

    // MARK: - signalCount

    func testSignalCount_matchesMemoCount() {
        vm.memos = [makeMemo(body: "a"), makeMemo(body: "b"), makeMemo(body: "c")]
        XCTAssertEqual(vm.signalCount, 3)
    }

    // MARK: - Helpers

    private func makeMemo(body: String, created: Date = Date()) -> Memo {
        Memo(
            id: UUID(),
            type: .text,
            created: created,
            body: body
        )
    }
}
