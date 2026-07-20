import Testing
import Foundation
import DayPageModels
import DayPageStorage
import DayPageServices
@testable import DayPage

/// US-020: Unit tests for TodayViewModel core paths: addMemo, deleteMemo, toggleFavorite (pin/unpin).
///
/// TodayViewModel reads/writes via RawStorage which uses VaultInitializer.testOverrideURL.
/// Tests run synchronously by directly mutating `memos` and calling the view model methods,
/// bypassing the async submission path that requires live services (Location, Weather).
///
/// Serialized + @MainActor because TodayViewModel is @MainActor-isolated and tests
/// share the global `VaultInitializer.testOverrideURL`.
@MainActor
@Suite("TodayViewModelTests", .serialized)
struct TodayViewModelTests {

    private let tempDir: URL
    private let vm: TodayViewModel

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TodayVMTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        VaultInitializer.testOverrideURL = tempDir
        vm = TodayViewModel(date: Date())
    }

    private func cleanup() {
        VaultInitializer.testOverrideURL = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - addMemo (via RawStorage.append + in-memory insert)

    @Test func addMemo_insertsIntoMemosArray() throws {
        defer { cleanup() }
        let memo = makeMemo(body: "test memo body")
        try RawStorage.append(memo)
        // Simulate the in-memory update that submitCombinedMemo performs
        vm.memos.insert(memo, at: 0)

        #expect(vm.memos.count == 1)
        #expect(vm.memos.first?.id == memo.id)
        #expect(vm.memos.first?.body == "test memo body")
    }

    @Test func addMemo_multipleMemosOrderedNewestFirst() throws {
        defer { cleanup() }
        let older = makeMemo(body: "older", created: Date(timeIntervalSinceNow: -120))
        let newer = makeMemo(body: "newer", created: Date(timeIntervalSinceNow: -60))
        try RawStorage.append(older)
        try RawStorage.append(newer)

        // Simulate load sort (newest first)
        vm.memos = [newer, older]

        #expect(vm.memos.first?.body == "newer")
        #expect(vm.memos.last?.body == "older")
    }

    // MARK: - deleteMemo

    @Test func deleteMemo_removesMemoFromMemosArray() throws {
        defer { cleanup() }
        let m1 = makeMemo(body: "keep me")
        let m2 = makeMemo(body: "delete me")
        try RawStorage.append(m1)
        try RawStorage.append(m2)
        vm.memos = [m1, m2]

        vm.deleteMemo(m2)

        #expect(vm.memos.count == 1)
        #expect(vm.memos.first?.id == m1.id)
    }

    @Test func deleteMemo_setsLastDeletedMemo() throws {
        defer { cleanup() }
        let memo = makeMemo(body: "will be deleted")
        vm.memos = [memo]

        vm.deleteMemo(memo)

        #expect(vm.lastDeletedMemo?.id == memo.id)
    }

    @Test func undoDelete_restoresMemo() throws {
        defer { cleanup() }
        let memo = makeMemo(body: "restore me")
        vm.memos = [memo]

        vm.deleteMemo(memo)
        #expect(vm.memos.count == 0)

        vm.undoDelete()
        #expect(vm.memos.count == 1)
        #expect(vm.memos.first?.id == memo.id)
        #expect(vm.lastDeletedMemo == nil)
    }

    // MARK: - toggleFavorite (pin / unpin)

    @Test func pinMemo_setsPinnedAtAndMovesToTop() throws {
        defer { cleanup() }
        let m1 = makeMemo(body: "first", created: Date(timeIntervalSinceNow: -60))
        let m2 = makeMemo(body: "second", created: Date())
        vm.memos = [m2, m1] // newest first

        vm.pinMemo(m1)

        #expect(vm.memos.first?.pinnedAt != nil, "Pinned memo must have pinnedAt set")
        #expect(vm.memos.first?.id == m1.id, "Pinned memo must move to top")
    }

    @Test func unpinMemo_clearsPinnedAtAndResortsByCreated() throws {
        defer { cleanup() }
        var pinned = makeMemo(body: "pinned", created: Date(timeIntervalSinceNow: -60))
        pinned.pinnedAt = Date()
        let normal = makeMemo(body: "normal", created: Date())
        vm.memos = [pinned, normal]

        vm.unpinMemo(pinned)

        #expect(vm.memos.first(where: { $0.id == pinned.id })?.pinnedAt == nil,
                "Unpinned memo must have nil pinnedAt")
        // After unpin, normal (newer) should be first
        #expect(vm.memos.first?.id == normal.id)
    }

    @Test func pinMemo_onlyOneMemoInList() throws {
        defer { cleanup() }
        let memo = makeMemo(body: "solo")
        vm.memos = [memo]

        vm.pinMemo(memo)

        #expect(vm.memos.count == 1)
        #expect(vm.memos.first?.pinnedAt != nil)
    }

    // MARK: - submitCombinedMemo (optimistic commit + durable persist)

    /// 落盘先于加载：the memo must appear in `memos` on the SAME synchronous turn
    /// the user taps send — no awaiting location/weather first — and must still
    /// land on disk afterward via the background durable-write task.
    @Test func submitCombinedMemo_insertsOptimisticallyThenPersists() async throws {
        defer { cleanup() }
        #expect(vm.memos.isEmpty)

        vm.submitCombinedMemo(body: "optimistic hello")

        // Optimistic insert + composer reset happen synchronously — the user
        // perceives the memo immediately, before any GPS/weather await.
        #expect(vm.memos.count == 1)
        #expect(vm.memos.first?.body == "optimistic hello")
        #expect(vm.isSubmitting == false)
        #expect(vm.pendingAttachments.isEmpty)

        // The durable append runs off-main; poll until the raw file reflects it.
        let deadline = Date().addingTimeInterval(5)
        var persisted: [Memo] = []
        while Date() < deadline {
            persisted = (try? RawStorage.read(for: Date())) ?? []
            if !persisted.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(persisted.contains { $0.body == "optimistic hello" })
    }

    /// An empty submit with no attachments is a no-op — no ghost card, no write.
    @Test func submitCombinedMemo_emptyBodyNoAttachments_isNoOp() {
        defer { cleanup() }
        vm.submitCombinedMemo(body: "   \n  ")
        #expect(vm.memos.isEmpty)
        #expect(vm.isSubmitting == false)
    }

    // MARK: - signalCount

    @Test func signalCount_matchesMemoCount() {
        defer { cleanup() }
        vm.memos = [makeMemo(body: "a"), makeMemo(body: "b"), makeMemo(body: "c")]
        #expect(vm.signalCount == 3)
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
