import Testing
import Foundation
import DayPageServices
import DayPageModels
import DayPageStorage
@testable import DayPage

extension DayPageSerialSwiftTests {
/// R4-B4: Unit tests for `ArchiveViewModel.groupedByMonth` — the
/// sectioning helper that powers list-mode month headers (issue #13).
///
/// We pin these behaviors:
///   1. **Month boundaries** — adjacent days in different months land in
///      separate groups (no leaking 06-01 into the 05 section).
///   2. **Year boundaries** — same rule across 12 → 01.
///   3. **Sort order** — newest month first (descending by "yyyy-MM").
///   4. **Empty input** — no crash, no sections.
///   5. **Filter** — empty days (memoCount=0, not compiled) are excluded.
///
/// The test injects a synthetic `dayStats` dictionary directly into the
/// view-model (`@Published`, internal access) so we never spin up vault IO.
@Suite("ArchiveViewModelGroupTests")
@MainActor
struct ArchiveViewModelGroupTests {

    // MARK: - Helpers

    /// Build a `DayStats` with the bare minimum needed to be visible in
    /// `sortedDays` (memoCount > 0 or a compiled daily page).
    private func makeStats(_ dateString: String, memoCount: Int = 1) -> DayStats {
        DayStats(
            dateString: dateString,
            memoCount: memoCount,
            photoCount: 0,
            voiceSeconds: 0,
            uniqueLocations: 0,
            isDailyPageCompiled: false,
            dailySummary: nil
        )
    }

    private func makeViewModel(stats: [DayStats]) -> ArchiveViewModel {
        let vm = ArchiveViewModel()
        var dict: [String: DayStats] = [:]
        for s in stats { dict[s.dateString] = s }
        vm.dayStats = dict
        return vm
    }

    // MARK: - Case 1: Month boundary

    /// 2026-05-31 + 2026-06-01 sit one day apart on the wall clock but
    /// belong to two separate month sections. A naive `prefix(7)` bug
    /// (e.g. off-by-one or reading more than 7 chars) would collapse them.
    @Test func groupsAcrossMonthBoundary_splitsInTwo() {
        let vm = makeViewModel(stats: [
            makeStats("2026-05-31"),
            makeStats("2026-06-01")
        ])

        let groups = vm.groupedByMonth
        #expect(groups.count == 2, "Adjacent days in different months must split: \(groups.map { $0.monthKey })")

        let keys = Set(groups.map { $0.monthKey })
        #expect(keys == ["2026-05", "2026-06"])

        // Each group should hold exactly its one day.
        let mayGroup = groups.first { $0.monthKey == "2026-05" }
        let junGroup = groups.first { $0.monthKey == "2026-06" }
        #expect(mayGroup?.days.count == 1)
        #expect(junGroup?.days.count == 1)
        #expect(mayGroup?.days.first?.dateString == "2026-05-31")
        #expect(junGroup?.days.first?.dateString == "2026-06-01")
    }

    // MARK: - Case 2: Year boundary

    /// 2025-12-31 → 2026-01-01 must split into two groups across the
    /// new-year boundary. Also pins descending sort: 2026-01 appears
    /// BEFORE 2025-12 (newest first).
    @Test func groupsAcrossYearBoundary_splitsInTwoAndOrdersNewestFirst() {
        let vm = makeViewModel(stats: [
            makeStats("2025-12-31"),
            makeStats("2026-01-01")
        ])

        let groups = vm.groupedByMonth
        #expect(groups.count == 2)
        // Newest year first.
        #expect(groups[0].monthKey == "2026-01")
        #expect(groups[1].monthKey == "2025-12")
    }

    // MARK: - Case 3: Descending sort with many months

    /// With three distinct months out of order, groups must come back
    /// strictly descending by "yyyy-MM" — that's what the list-mode
    /// section header pinning relies on.
    @Test func groupsAreSortedDescendingByMonthKey() {
        let vm = makeViewModel(stats: [
            makeStats("2026-03-15"),
            makeStats("2026-01-10"),
            makeStats("2026-02-20"),
            // Second entry inside Feb to verify intra-group day order is
            // preserved (sortedDays sorts dateString descending).
            makeStats("2026-02-05")
        ])

        let groups = vm.groupedByMonth
        let keys = groups.map { $0.monthKey }
        #expect(keys == ["2026-03", "2026-02", "2026-01"])

        // Intra-month: Feb has 2 entries, newest-first.
        let feb = groups.first { $0.monthKey == "2026-02" }
        #expect(feb?.days.count == 2)
        #expect(feb?.days.first?.dateString == "2026-02-20")
        #expect(feb?.days.last?.dateString == "2026-02-05")
    }

    // MARK: - Case 4: Empty input

    /// Empty dayStats must return an empty array — never crash, never
    /// return a synthetic "current month" empty section.
    @Test func groupedByMonth_emptyOnEmptyInput() {
        let vm = makeViewModel(stats: [])
        #expect(vm.groupedByMonth.isEmpty)
    }

    // MARK: - Case 5: Days with no content are filtered out

    /// `sortedDays` filters `memoCount == 0 && !isDailyPageCompiled`,
    /// so a `DayStats` with no memos and no compiled daily must NOT
    /// produce a group. Pins the grouped-by-month → sortedDays
    /// dependency so a future refactor doesn't accidentally surface
    /// empty calendar cells in list mode.
    @Test func groupedByMonth_excludesEmptyDays() {
        let vm = makeViewModel(stats: [
            makeStats("2026-04-10"),
            makeStats("2026-04-11", memoCount: 0),  // filtered out
        ])
        let groups = vm.groupedByMonth
        #expect(groups.count == 1)
        #expect(groups[0].days.count == 1)
        #expect(groups[0].days.first?.dateString == "2026-04-10")
    }

    // MARK: Archive refresh regression (real files and controlled late scans)

    private func refreshRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveRefreshTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("raw"), withIntermediateDirectories: true)
        return root
    }

    private func refreshCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = StorageSettings.currentTimeZone()
        return calendar
    }

    private func refreshMemo(_ body: String) throws -> Memo {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = StorageSettings.currentTimeZone()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return Memo(created: try #require(formatter.date(from: "2026-10-03 12:00")), body: body)
    }

    /// Pure serialization into this test's root avoids append's global sync work.
    private func writeRefreshMemos(_ memos: [Memo], root: URL) throws {
        let file = root.appendingPathComponent("raw/2026-10-03.md")
        if memos.isEmpty {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        } else {
            try RawStorage.atomicWrite(string: RawStorage.serialize(memos), to: file)
        }
    }

    private func refreshModel(root: URL) -> ArchiveViewModel {
        let calendar = refreshCalendar()
        let vm = ArchiveViewModel(vaultRootProvider: { root }, calendarProvider: { calendar })
        vm.goToMonth(year: 2026, month: 10)
        return vm
    }

    private func refreshResponse(_ request: ArchiveMonthRequest, count: Int) -> ArchiveMonthSnapshot {
        let date = String(format: "%04d-%02d-03", request.year, request.month)
        return ArchiveMonthSnapshot(
            dayStats: [date: makeStats(date, memoCount: count)],
            rawDates: [date], dailyDates: [], dayTeasers: [date: "root \(request.vaultRoot.lastPathComponent)"]
        )
    }

    @Test func archiveInactiveDoesNotScan_firstActivationLoads() async throws {
        let root = try refreshRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ArchiveRefreshScanGate()
        let calendar = refreshCalendar()
        let vm = ArchiveViewModel(vaultRootProvider: { root }, calendarProvider: { calendar }, loader: { try await gate.load($0) })
        vm.goToMonth(year: 2026, month: 10)
        vm.setActive(false)
        vm.invalidateVault()
        #expect(await gate.requestCount() == 0)
        #expect(!vm.isLoading)
        vm.setActive(true)
        let request = await gate.waitForRequest(0)
        #expect(request.vaultRoot == root.standardizedFileURL)
        #expect(request.year == 2026 && request.month == 10)
        vm.setActive(true)
        #expect(await gate.requestCount() == 1)
        try await gate.succeed(0, refreshResponse(request, count: 1))
        await vm.waitForCurrentLoad()
        #expect(vm.totalEntries == 1)
        vm.setActive(false)
    }

    @Test func archiveEmptyCache_hiddenWriteThenReturnReadsRealMemo() async throws {
        let root = try refreshRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = refreshModel(root: root)
        vm.setActive(true)
        await vm.waitForCurrentLoad()
        #expect(vm.totalEntries == 0 && vm.rawDates.isEmpty)
        vm.setActive(false)
        try writeRefreshMemos([refreshMemo("hidden write")], root: root)
        vm.invalidateVault()
        #expect(!vm.isLoading)
        vm.setActive(true)
        await vm.waitForCurrentLoad()
        #expect(vm.totalEntries == 1)
        #expect(vm.rawDates.contains("2026-10-03"))
        #expect(vm.sortedDays.map(\.dateString) == ["2026-10-03"])
        #expect(vm.dayTeasers["2026-10-03"]?.contains("hidden write") == true)
        vm.setActive(false)
    }

    @Test func archiveInvalidation_refreshesRealUpdatePinDeleteAndUndo() async throws {
        let root = try refreshRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var first = try refreshMemo("before edit")
        let second = try refreshMemo("second record")
        try writeRefreshMemos([first, second], root: root)
        let original = try Data(contentsOf: root.appendingPathComponent("raw/2026-10-03.md"))
        let vm = refreshModel(root: root)
        vm.setActive(true)
        await vm.waitForCurrentLoad()
        #expect(vm.totalEntries == 2)
        first.body = "after edit"
        first.pinnedAt = first.created
        try writeRefreshMemos([first], root: root)
        vm.invalidateVault()
        await vm.waitForCurrentLoad()
        #expect(vm.totalEntries == 1)
        #expect(vm.dayTeasers["2026-10-03"]?.contains("after edit") == true)
        #expect(try RawStorage.read(for: first.created, vaultRoot: root).first?.pinnedAt == first.created)
        try writeRefreshMemos([], root: root)
        vm.invalidateVault()
        await vm.waitForCurrentLoad()
        #expect(vm.totalEntries == 0 && vm.rawDates.isEmpty && vm.sortedDays.isEmpty)
        try original.write(to: root.appendingPathComponent("raw/2026-10-03.md"), options: .atomic)
        vm.invalidateVault()
        await vm.waitForCurrentLoad()
        #expect(vm.totalEntries == 2 && vm.rawDates.contains("2026-10-03"))
        #expect(try Data(contentsOf: root.appendingPathComponent("raw/2026-10-03.md")) == original)
        vm.setActive(false)
    }

    @Test func archiveRawAndCompiledDates_publishWithSameRealSnapshot() async throws {
        let root = try refreshRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeRefreshMemos([refreshMemo("raw teaser")], root: root)
        let daily = root.appendingPathComponent("wiki/daily")
        try FileManager.default.createDirectory(at: daily, withIntermediateDirectories: true)
        let file = daily.appendingPathComponent("2026-10-03.md")
        try "---\nsummary: Compiled local summary\n---\n\nDaily body".write(to: file, atomically: true, encoding: .utf8)
        let vm = refreshModel(root: root)
        vm.setActive(true)
        await vm.waitForCurrentLoad()
        #expect(vm.rawDates.contains("2026-10-03") && vm.dailyDates.contains("2026-10-03"))
        #expect(vm.dayStats["2026-10-03"]?.isDailyPageCompiled == true)
        #expect(vm.dayStats["2026-10-03"]?.dailySummary == "Compiled local summary")
        #expect(vm.totalEntries == 1 && vm.activeDayCount == 1)
        try FileManager.default.removeItem(at: file)
        vm.invalidateVault()
        await vm.waitForCurrentLoad()
        #expect(vm.dailyDates.isEmpty && vm.rawDates.contains("2026-10-03"))
        #expect(vm.dayStats["2026-10-03"]?.isDailyPageCompiled == false)
        #expect(vm.dayTeasers["2026-10-03"]?.contains("raw teaser") == true)
        vm.setActive(false)
    }

    @Test func archiveRootSwitch_readsOnlySelectedRealVault() async throws {
        let rootA = try refreshRoot(), rootB = try refreshRoot()
        defer { try? FileManager.default.removeItem(at: rootA); try? FileManager.default.removeItem(at: rootB) }
        try writeRefreshMemos([refreshMemo("only A")], root: rootA)
        try writeRefreshMemos([refreshMemo("only B one"), refreshMemo("only B two")], root: rootB)
        var root = rootA
        let calendar = refreshCalendar()
        let vm = ArchiveViewModel(vaultRootProvider: { root }, calendarProvider: { calendar })
        vm.goToMonth(year: 2026, month: 10)
        vm.setActive(true)
        await vm.waitForCurrentLoad()
        #expect(vm.totalEntries == 1)
        root = rootB
        vm.loadMonth()
        await vm.waitForCurrentLoad()
        #expect(vm.totalEntries == 2)
        #expect(vm.dayTeasers["2026-10-03"]?.contains("only B") == true)
        root = rootA
        vm.loadMonth()
        await vm.waitForCurrentLoad()
        #expect(vm.totalEntries == 1)
        #expect(vm.dayTeasers["2026-10-03"]?.contains("only A") == true)
        vm.setActive(false)
    }

    @Test func archiveCachedMonth_retiresLateOtherMonthResult() async throws {
        let root = try refreshRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ArchiveRefreshScanGate()
        let vm = ArchiveViewModel(vaultRootProvider: { root }, loader: { try await gate.load($0) })
        vm.goToMonth(year: 2026, month: 10)
        vm.setActive(true)
        let october = await gate.waitForRequest(0)
        try await gate.succeed(0, refreshResponse(october, count: 1))
        await vm.waitForCurrentLoad()
        vm.goToNextMonth()
        let november = await gate.waitForRequest(1)
        let oldTask = try #require(vm.loadMonthTask)
        vm.goToPreviousMonth()
        #expect(vm.totalEntries == 1 && !vm.isLoading)
        #expect(await gate.requestCount() == 2)
        try await gate.succeed(1, refreshResponse(november, count: 99))
        await oldTask.value
        #expect(vm.currentMonth == 10 && vm.totalEntries == 1 && !vm.isLoading)
        #expect(!vm.dayStats.keys.contains("2026-11-03"))
        vm.goToNextMonth()
        let retried = await gate.waitForRequest(2)
        try await gate.succeed(2, refreshResponse(retried, count: 2))
        await vm.waitForCurrentLoad()
        #expect(vm.totalEntries == 2)
        vm.setActive(false)
    }

    @Test func archiveOldCancelledScan_doesNotCloseNewLoading() async throws {
        let root = try refreshRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ArchiveRefreshScanGate()
        let vm = ArchiveViewModel(vaultRootProvider: { root }, loader: { try await gate.load($0) })
        vm.goToMonth(year: 2026, month: 10)
        vm.setActive(true)
        let oldRequest = await gate.waitForRequest(0)
        let oldTask = try #require(vm.loadMonthTask)
        vm.goToNextMonth()
        let current = await gate.waitForRequest(1)
        try await gate.succeed(0, refreshResponse(oldRequest, count: 99))
        await oldTask.value
        #expect(vm.isLoading && vm.dayStats.isEmpty)
        try await gate.succeed(1, refreshResponse(current, count: 2))
        await vm.waitForCurrentLoad()
        #expect(vm.totalEntries == 2 && !vm.isLoading)
        vm.setActive(false)
    }

    @Test func archiveInactive_rejectsLateResultAndReloadsOnReturn() async throws {
        let root = try refreshRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ArchiveRefreshScanGate()
        let vm = ArchiveViewModel(vaultRootProvider: { root }, loader: { try await gate.load($0) })
        vm.goToMonth(year: 2026, month: 10)
        vm.setActive(true)
        let first = await gate.waitForRequest(0)
        let oldTask = try #require(vm.loadMonthTask)
        vm.setActive(false)
        try await gate.succeed(0, refreshResponse(first, count: 99))
        await oldTask.value
        #expect(vm.dayStats.isEmpty && !vm.isLoading)
        vm.setActive(true)
        let current = await gate.waitForRequest(1)
        try await gate.succeed(1, refreshResponse(current, count: 1))
        await vm.waitForCurrentLoad()
        #expect(vm.totalEntries == 1 && vm.currentMonth == 10)
        vm.setActive(false)
    }

    @Test func archiveRootChange_rejectsLateOldRootWhileNewLoads() async throws {
        let rootA = try refreshRoot(), rootB = try refreshRoot()
        defer { try? FileManager.default.removeItem(at: rootA); try? FileManager.default.removeItem(at: rootB) }
        var root = rootA
        let gate = ArchiveRefreshScanGate()
        let vm = ArchiveViewModel(vaultRootProvider: { root }, loader: { try await gate.load($0) })
        vm.goToMonth(year: 2026, month: 10)
        vm.setActive(true)
        let first = await gate.waitForRequest(0)
        let oldTask = try #require(vm.loadMonthTask)
        root = rootB
        vm.invalidateVault()
        let current = await gate.waitForRequest(1)
        #expect(current.vaultRoot == rootB.standardizedFileURL)
        try await gate.succeed(0, refreshResponse(first, count: 99))
        await oldTask.value
        #expect(vm.isLoading && vm.dayStats.isEmpty)
        try await gate.succeed(1, refreshResponse(current, count: 2))
        await vm.waitForCurrentLoad()
        #expect(vm.totalEntries == 2)
        #expect(vm.dayTeasers["2026-10-03"]?.contains(rootB.lastPathComponent) == true)
        vm.setActive(false)
    }

    @Test func archiveFailedScan_doesNotCacheTrustedEmptyMonth() async throws {
        let root = try refreshRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ArchiveRefreshScanGate()
        let vm = ArchiveViewModel(vaultRootProvider: { root }, loader: { try await gate.load($0) })
        vm.goToMonth(year: 2026, month: 10)
        vm.setActive(true)
        _ = await gate.waitForRequest(0)
        try await gate.fail(0)
        await vm.waitForCurrentLoad()
        #expect(!vm.isLoading && vm.dayStats.isEmpty)
        vm.loadMonth()
        let retried = await gate.waitForRequest(1)
        try await gate.succeed(1, refreshResponse(retried, count: 1))
        await vm.waitForCurrentLoad()
        #expect(vm.totalEntries == 1)
        vm.setActive(false)
    }

    @Test func archiveCalendarContextChange_doesNotReuseOldContextCache() async throws {
        let root = try refreshRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var calendar = refreshCalendar()
        let gate = ArchiveRefreshScanGate()
        let vm = ArchiveViewModel(vaultRootProvider: { root }, calendarProvider: { calendar }, loader: { try await gate.load($0) })
        vm.goToMonth(year: 2026, month: 10)
        vm.setActive(true)
        let first = await gate.waitForRequest(0)
        try await gate.succeed(0, refreshResponse(first, count: 1))
        await vm.waitForCurrentLoad()
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        if calendar.timeZone == first.calendar.timeZone {
            calendar.timeZone = try #require(TimeZone(secondsFromGMT: 3600))
        }
        vm.loadMonth()
        let current = await gate.waitForRequest(1)
        #expect(current.calendar.timeZone == calendar.timeZone)
        #expect(current.calendar.timeZone != first.calendar.timeZone)
        try await gate.succeed(1, refreshResponse(current, count: 2))
        await vm.waitForCurrentLoad()
        #expect(vm.totalEntries == 2)
        vm.setActive(false)
    }

    @Test func archiveUnchangedMonthCache_avoidsAnotherScan() async throws {
        let root = try refreshRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ArchiveRefreshScanGate()
        let vm = ArchiveViewModel(vaultRootProvider: { root }, loader: { try await gate.load($0) })
        vm.goToMonth(year: 2026, month: 10)
        vm.setActive(true)
        let first = await gate.waitForRequest(0)
        try await gate.succeed(0, refreshResponse(first, count: 1))
        await vm.waitForCurrentLoad()
        vm.loadMonth()
        #expect(await gate.requestCount() == 1)
        #expect(vm.totalEntries == 1 && !vm.isLoading)
        vm.setActive(false)
    }

    @Test func archiveRepeatedInvalidation_onlyNewestScanCanPublish() async throws {
        let root = try refreshRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ArchiveRefreshScanGate()
        let vm = ArchiveViewModel(vaultRootProvider: { root }, loader: { try await gate.load($0) })
        vm.goToMonth(year: 2026, month: 10)
        vm.setActive(true)
        let first = await gate.waitForRequest(0)
        let firstTask = try #require(vm.loadMonthTask)
        vm.invalidateVault()
        let second = await gate.waitForRequest(1)
        let secondTask = try #require(vm.loadMonthTask)
        vm.invalidateVault()
        let last = await gate.waitForRequest(2)
        try await gate.succeed(1, refreshResponse(second, count: 99))
        try await gate.succeed(0, refreshResponse(first, count: 98))
        await firstTask.value
        await secondTask.value
        #expect(vm.isLoading && vm.dayStats.isEmpty)
        try await gate.succeed(2, refreshResponse(last, count: 3))
        await vm.waitForCurrentLoad()
        #expect(vm.totalEntries == 3 && !vm.isLoading)
        vm.setActive(false)
    }

    @Test func archiveContextDrift_withoutNewRequestAutomaticallyReloads() async throws {
        let rootA = try refreshRoot(), rootB = try refreshRoot()
        defer { try? FileManager.default.removeItem(at: rootA); try? FileManager.default.removeItem(at: rootB) }
        var root = rootA
        var calendar = refreshCalendar()
        let gate = ArchiveRefreshScanGate()
        let vm = ArchiveViewModel(vaultRootProvider: { root }, calendarProvider: { calendar }, loader: { try await gate.load($0) })
        vm.goToMonth(year: 2026, month: 10)
        vm.setActive(true)
        let first = await gate.waitForRequest(0)
        let oldTask = try #require(vm.loadMonthTask)
        // No invalidate/load call: only the providers change while I/O waits.
        root = rootB
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: first.calendar.timeZone.secondsFromGMT() == 0 ? 3600 : 0))
        try await gate.succeed(0, refreshResponse(first, count: 99))
        await oldTask.value
        let current = await gate.waitForRequest(1)
        #expect(current.vaultRoot == rootB.standardizedFileURL)
        #expect(current.calendar == calendar)
        #expect(vm.isLoading && vm.dayStats.isEmpty)
        try await gate.succeed(1, refreshResponse(current, count: 2))
        await vm.waitForCurrentLoad()
        #expect(vm.totalEntries == 2 && !vm.isLoading)
        vm.setActive(false)
    }

    @Test func archiveCrossRootFailure_neverDisplaysPreviousRootSnapshot() async throws {
        let rootA = try refreshRoot(), rootB = try refreshRoot()
        defer { try? FileManager.default.removeItem(at: rootA); try? FileManager.default.removeItem(at: rootB) }
        var root = rootA
        let gate = ArchiveRefreshScanGate()
        let vm = ArchiveViewModel(vaultRootProvider: { root }, loader: { try await gate.load($0) })
        vm.goToMonth(year: 2026, month: 10)
        vm.setActive(true)
        let first = await gate.waitForRequest(0)
        try await gate.succeed(0, refreshResponse(first, count: 1))
        await vm.waitForCurrentLoad()
        #expect(vm.totalEntries == 1 && !vm.dayTeasers.isEmpty)
        root = rootB
        vm.loadMonth()
        _ = await gate.waitForRequest(1)
        #expect(vm.dayStats.isEmpty && vm.rawDates.isEmpty && vm.dayTeasers.isEmpty)
        try await gate.fail(1)
        await vm.waitForCurrentLoad()
        #expect(!vm.isLoading && vm.dayStats.isEmpty && vm.dayTeasers.isEmpty)
        #expect(vm.dailyDates.isEmpty && vm.rawDates.isEmpty)
        vm.loadMonth()
        let retried = await gate.waitForRequest(2)
        try await gate.succeed(2, refreshResponse(retried, count: 2))
        await vm.waitForCurrentLoad()
        #expect(vm.totalEntries == 2)
        vm.setActive(false)
    }

    @Test func archiveCrossMonthFailure_neverDisplaysPreviousMonthStatistics() async throws {
        let root = try refreshRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ArchiveRefreshScanGate()
        let vm = ArchiveViewModel(vaultRootProvider: { root }, loader: { try await gate.load($0) })
        vm.goToMonth(year: 2026, month: 10)
        vm.setActive(true)
        let first = await gate.waitForRequest(0)
        try await gate.succeed(0, refreshResponse(first, count: 1))
        await vm.waitForCurrentLoad()
        vm.goToNextMonth()
        _ = await gate.waitForRequest(1)
        #expect(vm.currentMonth == 11 && vm.totalEntries == 0 && vm.sortedDays.isEmpty)
        try await gate.fail(1)
        await vm.waitForCurrentLoad()
        #expect(!vm.isLoading && vm.totalEntries == 0 && vm.dayStats.isEmpty)
        #expect(!vm.generateMarkdownExport(filter: .all).contains("2026-10-03"))
        vm.goToPreviousMonth()
        #expect(vm.totalEntries == 1 && !vm.isLoading)
        #expect(await gate.requestCount() == 2)
        vm.setActive(false)
    }

    @Test func archiveWholeVaultDateSets_includeOtherMonthsWithoutCountingThem() async throws {
        let root = try refreshRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeRefreshMemos([refreshMemo("October")], root: root)
        var november = try refreshMemo("November one")
        november.created = try #require(refreshCalendar().date(byAdding: .month, value: 1, to: november.created))
        var novemberTwo = november
        novemberTwo.id = UUID()
        novemberTwo.body = "November two"
        novemberTwo.created = november.created.addingTimeInterval(1)
        let raw = RawStorage.fileURL(for: november.created, vaultRoot: root)
        #expect(raw.lastPathComponent == "2026-11-03.md")
        try RawStorage.atomicWrite(string: RawStorage.serialize([november, novemberTwo]), to: raw)
        let daily = root.appendingPathComponent("wiki/daily")
        try FileManager.default.createDirectory(at: daily, withIntermediateDirectories: true)
        try "---\nsummary: December only\n---\n".write(to: daily.appendingPathComponent("2026-12-03.md"), atomically: true, encoding: .utf8)
        let vm = refreshModel(root: root)
        vm.setActive(true)
        await vm.waitForCurrentLoad()
        #expect(vm.rawDates == ["2026-10-03", "2026-11-03"])
        #expect(vm.dailyDates == ["2026-12-03"])
        #expect(vm.totalEntries == 1 && vm.sortedDays.map(\.dateString) == ["2026-10-03"])
        vm.goToNextMonth()
        await vm.waitForCurrentLoad()
        #expect(vm.totalEntries == 2 && vm.sortedDays.map(\.dateString) == ["2026-11-03"])
        #expect(vm.rawDates == ["2026-10-03", "2026-11-03"] && vm.dailyDates == ["2026-12-03"])
        vm.setActive(false)
    }

    @Test func archiveRealDirectoryReadFailure_isRetryable() async throws {
        let root = try refreshRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("raw")
        try FileManager.default.removeItem(at: raw)
        try "not a directory".write(to: raw, atomically: true, encoding: .utf8)
        let vm = refreshModel(root: root)
        vm.setActive(true)
        await vm.waitForCurrentLoad()
        #expect(vm.totalEntries == 0 && !vm.isLoading)
        try FileManager.default.removeItem(at: raw)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        try writeRefreshMemos([refreshMemo("after read failure")], root: root)
        vm.loadMonth()
        await vm.waitForCurrentLoad()
        #expect(vm.totalEntries == 1 && vm.rawDates.contains("2026-10-03"))
        vm.setActive(false)
    }
}
}


// MARK: - DayPageSerialSwiftTests namespace aliases (preserve global names for helpers,
// extensions, and qualified references after the serialized-root move)
typealias ArchiveViewModelGroupTests = DayPageSerialSwiftTests.ArchiveViewModelGroupTests

private enum ArchiveRefreshFixtureError: Error { case requestedFailure, missingRequest }

/// Cancellation intentionally does not resolve these continuations. Tests release
/// the old loader after a new request so they verify publication guards, not just
/// cooperative cancellation or a timing-dependent sleep.
private actor ArchiveRefreshScanGate {
    private var requests: [ArchiveMonthRequest] = []
    private var continuations: [Int: CheckedContinuation<ArchiveMonthSnapshot, any Error>] = [:]
    private var waiters: [Int: CheckedContinuation<ArchiveMonthRequest, Never>] = [:]

    func load(_ request: ArchiveMonthRequest) async throws -> ArchiveMonthSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            let index = requests.count
            requests.append(request)
            continuations[index] = continuation
            waiters.removeValue(forKey: index)?.resume(returning: request)
        }
    }

    func waitForRequest(_ index: Int) async -> ArchiveMonthRequest {
        if requests.indices.contains(index) { return requests[index] }
        return await withCheckedContinuation { waiters[index] = $0 }
    }

    func requestCount() -> Int { requests.count }

    func succeed(_ index: Int, _ snapshot: ArchiveMonthSnapshot) throws {
        guard let continuation = continuations.removeValue(forKey: index) else { throw ArchiveRefreshFixtureError.missingRequest }
        continuation.resume(returning: snapshot)
    }

    func fail(_ index: Int) throws {
        guard let continuation = continuations.removeValue(forKey: index) else { throw ArchiveRefreshFixtureError.missingRequest }
        continuation.resume(throwing: ArchiveRefreshFixtureError.requestedFailure)
    }
}

// MARK: - Canonical owning-day binding under a dynamic preferred time zone

extension DayPageSerialSwiftTests {

/// Settled-outcome regression for the confirmed dynamic-timezone source chain:
/// a memo detail is bound to its validated canonical owning raw
/// `YYYY-MM-DD` file key, so read/update/delete/restore and pin hit that exact
/// file even when preferredTimeZone changes after navigation (no restart).
/// Real RawStorage + MemoRecordStore at explicit temp vault roots, real App
/// `MemoDetailRef` values, byte-level sibling-file assertions.
@Suite("MemoDetailOwningDayTests", .serialized)
@MainActor
struct MemoDetailOwningDayTests {

    // MARK: Fixture

    private final class Fixture {
        let root: URL
        let decoyRoot: URL
        let oct2URL: URL
        let oct3URL: URL
        private let originalZoneValue: Any?
        private let originalOverride: URL?

        init() throws {
            originalZoneValue = UserDefaults.standard.object(forKey: StorageSettings.preferredTimeZoneKey)
            originalOverride = VaultInitializer.testOverrideURL
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("MemoDetailOwningDayTests-\(UUID().uuidString)", isDirectory: true)
            root = base.appendingPathComponent("vault", isDirectory: true)
            decoyRoot = base.appendingPathComponent("decoy", isDirectory: true)
            let raw = root.appendingPathComponent("raw", isDirectory: true)
            try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: decoyRoot, withIntermediateDirectories: true)
            oct2URL = raw.appendingPathComponent("2026-10-02.md")
            oct3URL = raw.appendingPathComponent("2026-10-03.md")
            // Explicit vault roots are passed at every call site; the override
            // is parked on a decoy root so any accidental global-root use is
            // visible instead of silently passing.
            VaultInitializer.testOverrideURL = decoyRoot
        }

        func preferZone(_ identifier: String) {
            UserDefaults.standard.set(identifier, forKey: StorageSettings.preferredTimeZoneKey)
        }

        func restore() {
            if let originalZoneValue {
                UserDefaults.standard.set(originalZoneValue, forKey: StorageSettings.preferredTimeZoneKey)
            } else {
                UserDefaults.standard.removeObject(forKey: StorageSettings.preferredTimeZoneKey)
            }
            VaultInitializer.testOverrideURL = originalOverride
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
    }

    /// 2026-10-02T10:00:00Z — 2026-10-03 00:00 in Pacific/Kiritimati (+14),
    /// 2026-10-02 03:00 in America/Los_Angeles (-07, PDT): the audit's exact
    /// cross-day instant.
    private var kiritimatiMidnight: Date { Date(timeIntervalSince1970: 1_790_935_200) }

    /// 2026-10-02T18:00:00Z — 2026-10-02 11:00 in Los Angeles (-07),
    /// 2026-10-03 08:00 in Kiritimati (+14): the reverse-zone instant.
    private var losAngelesAfternoon: Date { Date(timeIntervalSince1970: 1_790_964_000) }

    private func seed(_ memo: Memo, into url: URL, root: URL) throws {
        var existing = FileManager.default.fileExists(atPath: url.path)
            ? RawStorage.parse(fileContent: try String(contentsOf: url, encoding: .utf8), sourceFile: url)
            : []
        existing.append(memo)
        try RawStorage.atomicWrite(string: RawStorage.serialize(existing), to: url)
        _ = root // explicit-root semantics are asserted per call site
    }

    private func bytes(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    // MARK: +14 navigation, then -07 mutation without restart

    @Test func memoDetailRef_boundInPlus14_mutatesOnlyOwningFileAfterSwitchToMinus07() async throws {
        let fixture = try Fixture()
        defer { fixture.restore() }
        let store = MemoRecordStore()

        let oct2 = Memo(
            id: UUID(),
            created: Date(timeIntervalSince1970: 1_790_906_400), // 2026-10-02T02:00:00Z
            body: "oct2 body untouched"
        )
        let oct3 = Memo(id: UUID(), created: kiritimatiMidnight, body: "oct3 body original")
        try seed(oct2, into: fixture.oct2URL, root: fixture.root)
        try seed(oct3, into: fixture.oct3URL, root: fixture.root)
        let oct2Before = try bytes(fixture.oct2URL)
        let oct3Before = try bytes(fixture.oct3URL)

        // Navigate while +14 is the preferred zone (Archive-style Date ref).
        fixture.preferZone("Pacific/Kiritimati")
        let ref = try #require(MemoDetailRef(
            id: oct3.id,
            day: kiritimatiMidnight,
            source: .archive
        ))
        #expect(ref.dayString == "2026-10-03")
        #expect(try RawStorage.read(dayString: ref.dayString, vaultRoot: fixture.root).map(\.id) == [oct3.id])

        // Preferred zone flips to -07 in the same process, no restart. The
        // ref keeps its validated key; a Date re-read would now say "Oct 2".
        fixture.preferZone("America/Los_Angeles")
        #expect(ref.dayString == "2026-10-03")
        #expect(RawStorage.dayString(for: kiritimatiMidnight) == "2026-10-02",
               "control: the legacy Date now reinterprets to the neighbouring file")

        let loaded = try await store.memo(id: oct3.id, dayString: ref.dayString, vaultRoot: fixture.root)
        #expect(loaded.body == "oct3 body original")

        let updated = try await store.updateBody(
            id: oct3.id, dayString: ref.dayString, body: "oct3 body edited", vaultRoot: fixture.root
        )
        #expect(updated.body == "oct3 body edited")

        // The existing Markdown timestamp format preserves milliseconds.
        // An exact eighth of a second survives that format without comparing
        // Date() sub-millisecond precision against its serialized value.
        let pinnedAt = kiritimatiMidnight.addingTimeInterval(0.125)
        let pinned = try await store.setPinnedAt(
            id: oct3.id, dayString: ref.dayString, pinnedAt: pinnedAt, vaultRoot: fixture.root
        )
        #expect(pinned.pinnedAt == pinnedAt && pinned.body == "oct3 body edited")

        _ = try await store.delete(id: oct3.id, dayString: ref.dayString, vaultRoot: fixture.root)
        #expect(try RawStorage.read(dayString: "2026-10-03", vaultRoot: fixture.root).isEmpty)
        try await store.restore(pinned, dayString: ref.dayString, vaultRoot: fixture.root)
        let restored = try RawStorage.read(dayString: "2026-10-03", vaultRoot: fixture.root)
        #expect(restored.map(\.id) == [oct3.id] && restored[0].body == "oct3 body edited" && restored[0].pinnedAt == pinnedAt)

        // The sibling day file must be byte-identical throughout.
        #expect(try bytes(fixture.oct2URL) == oct2Before)
        #expect(try bytes(fixture.oct3URL) != oct3Before)
        // Explicit vault root is the captured authority — the decoy override
        // root stays empty.
        #expect((try? FileManager.default.contentsOfDirectory(atPath: fixture.decoyRoot.path).isEmpty) != false)
    }

    // MARK: Reverse zone change

    @Test func memoDetailRef_boundInMinus07_mutatesOnlyOwningFileAfterSwitchToPlus14() async throws {
        let fixture = try Fixture()
        defer { fixture.restore() }
        let store = MemoRecordStore()

        let oct2 = Memo(id: UUID(), created: losAngelesAfternoon, body: "owned by oct2 file")
        let oct3 = Memo(id: UUID(), created: kiritimatiMidnight, body: "owned by oct3 file")
        try seed(oct2, into: fixture.oct2URL, root: fixture.root)
        try seed(oct3, into: fixture.oct3URL, root: fixture.root)
        let oct3Before = try bytes(fixture.oct3URL)

        fixture.preferZone("America/Los_Angeles")
        let ref = try #require(MemoDetailRef(id: oct2.id, day: losAngelesAfternoon, source: .raw))
        #expect(ref.dayString == "2026-10-02")

        fixture.preferZone("Pacific/Kiritimati")
        _ = try await store.updateBody(
            id: oct2.id, dayString: ref.dayString, body: "edited after +14 switch", vaultRoot: fixture.root
        )
        #expect(try RawStorage.read(dayString: "2026-10-02", vaultRoot: fixture.root).first?.body == "edited after +14 switch")
        #expect(try bytes(fixture.oct3URL) == oct3Before)
    }

    @Test func dailyRawLoaderPreservesPageKeyAcrossBothZoneDirections() throws {
        for (startingZone, endingZone) in [
            ("Pacific/Kiritimati", "America/Los_Angeles"),
            ("America/Los_Angeles", "Pacific/Kiritimati")
        ] {
            let fixture = try Fixture()
            defer { fixture.restore() }
            fixture.preferZone(startingZone)
            let sibling = Memo(created: kiritimatiMidnight, body: "Oct2 sibling")
            let early = Memo(created: kiritimatiMidnight, body: "Oct3 earlier")
            let late = Memo(created: kiritimatiMidnight.addingTimeInterval(60), body: "Oct3 later")
            try seed(sibling, into: fixture.oct2URL, root: fixture.root)
            try seed(late, into: fixture.oct3URL, root: fixture.root)
            try seed(early, into: fixture.oct3URL, root: fixture.root)
            let siblingBefore = try bytes(fixture.oct2URL)
            let owningBefore = try bytes(fixture.oct3URL)
            let dayKey = "2026-10-03"
            fixture.preferZone(endingZone)
            let loaded = try DailyPageView.rawMemos(forDayString: dayKey, vaultRoot: fixture.root)
            #expect(loaded.map(\.id) == [early.id, late.id])
            #expect(loaded.map(\.body) == ["Oct3 earlier", "Oct3 later"])
            #expect(!loaded.contains { $0.id == sibling.id })
            do {
                _ = try DailyPageView.rawMemos(forDayString: "../2026-10-03", vaultRoot: fixture.root)
                Issue.record("Daily loader accepted an invalid page day")
            } catch let error as RawStorageError {
                guard case .invalidDayString(let value) = error else {
                    Issue.record("Unexpected Daily loader storage error: \(error)")
                    continue
                }
                #expect(value == "../2026-10-03")
            }
            #expect(try bytes(fixture.oct2URL) == siblingBefore)
            #expect(try bytes(fixture.oct3URL) == owningBefore)
        }
    }

    @Test func todayUndoImmediatelyRestoresLoadedOwningDayAfterZoneSwitch() async throws {
        let fixture = try Fixture()
        defer { fixture.restore() }
        fixture.preferZone("Pacific/Kiritimati")
        VaultInitializer.testOverrideURL = fixture.root
        let sibling = Memo(created: kiritimatiMidnight, body: "Oct2 sibling unchanged")
        let owning = Memo(created: kiritimatiMidnight.addingTimeInterval(-86400), body: "Oct3 across midnight")
        try seed(sibling, into: fixture.oct2URL, root: fixture.root)
        try seed(owning, into: fixture.oct3URL, root: fixture.root)
        let siblingBefore = try bytes(fixture.oct2URL)
        let vm = TodayViewModel(date: kiritimatiMidnight, observeChanges: false)
        #expect(vm.loadedDayString == "2026-10-03")
        vm.memos = [owning]
        fixture.preferZone("America/Los_Angeles")
        vm.deleteMemo(owning)
        #expect(vm.memos.isEmpty)
        vm.undoDelete()
        // Assert before yielding: delayed reload must not mask a wrong
        // optimistic undo decision based on the memo's created timestamp.
        #expect(vm.memos.map(\.id) == [owning.id])
        await vm.waitForMemoPersistence()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        await TimelineIndex.shared.waitUntilIdleForTesting()
        await SearchIndex.shared.waitUntilIdleForTesting()
        #expect(try RawStorage.read(dayString: "2026-10-03", vaultRoot: fixture.root).map(\.id) == [owning.id])
        #expect(try bytes(fixture.oct2URL) == siblingBefore)
    }

    @Test func dailyCoverFallbackUsesCanonicalPageKeyAfterTimeZoneSwitch() throws {
        for (startingZone, endingZone) in [
            ("Pacific/Kiritimati", "America/Los_Angeles"),
            ("America/Los_Angeles", "Pacific/Kiritimati")
        ] {
            let fixture = try Fixture()
            let originalFormatterZone = DateFormatters.isoDate.timeZone
            defer {
                DateFormatters.isoDate.timeZone = originalFormatterZone
                fixture.restore()
            }
            fixture.preferZone(startingZone)
            // Model the cached formatter's old zone independently from live
            // preferred settings, then restore it exactly at fixture exit.
            DateFormatters.isoDate.timeZone = try #require(TimeZone(identifier: startingZone))
            VaultInitializer.testOverrideURL = fixture.root
            let sibling = Memo(type: .photo, created: kiritimatiMidnight,
                attachments: [.init(file: "raw/assets/cover-sibling.jpg", kind: "photo")], body: "Oct2 sibling")
            let owning = Memo(type: .photo, created: kiritimatiMidnight,
                attachments: [
                    .init(file: "raw/assets/IMG-owning.jpg", kind: "photo"),
                    .init(file: "raw/assets/cover-owning.jpg", kind: "photo")
                ], body: "Oct3 owning")
            try seed(sibling, into: fixture.oct2URL, root: fixture.root)
            try seed(owning, into: fixture.oct3URL, root: fixture.root)
            let siblingBefore = try bytes(fixture.oct2URL)
            let owningBefore = try bytes(fixture.oct3URL)
            fixture.preferZone(endingZone)
            if startingZone == "Pacific/Kiritimati" {
                let oldDate = try #require(DateFormatters.isoDate.date(from: "2026-10-03"))
                #expect(RawStorage.dayString(for: oldDate) == "2026-10-02",
                    "Control: the old Date conversion targets the sibling file")
            }
            let markdown = "---\ntype: daily\nsummary: QA canonical cover\n---\n\n## MORNING\nQA source\n"
            let model = DailyPageParser.parse(content: markdown, dateString: "2026-10-03")
            #expect(model.coverAssetPath == "raw/assets/cover-owning.jpg")
            let explicit = DailyPageParser.parse(
                content: "---\ncover: raw/assets/explicit-cover.jpg\n---\n", dateString: "2026-10-03")
            #expect(explicit.coverAssetPath == "raw/assets/explicit-cover.jpg")
            #expect(DailyPageParser.parse(content: markdown, dateString: "../2026-10-03").coverAssetPath == nil)
            #expect(try bytes(fixture.oct2URL) == siblingBefore)
            #expect(try bytes(fixture.oct3URL) == owningBefore)
        }
    }

    // MARK: Identity stays the validated key

    @Test func memoDetailRef_identityIsCanonicalKeyNotReinterpretedDate() throws {
        let fixture = try Fixture()
        defer { fixture.restore() }
        fixture.preferZone("Pacific/Kiritimati")
        let id = UUID()
        let viaDate = MemoDetailRef(id: id, day: kiritimatiMidnight, source: .today)
        let viaKey = MemoDetailRef(id: id, dayString: "2026-10-03", source: .today)
        let zoomed = MemoDetailRef(id: id, dayString: "2026-10-03", source: .today, usesZoomTransition: true)
        #expect(viaDate == viaKey && viaKey == zoomed)
        #expect(Set([viaDate, viaKey, zoomed]).count == 1)

        // Equality must not re-derive the day when the zone later changes.
        fixture.preferZone("America/Los_Angeles")
        #expect(viaKey == MemoDetailRef(id: id, dayString: "2026-10-03", source: .today))
        #expect(viaKey != MemoDetailRef(id: id, dayString: "2026-10-02", source: .today))
        #expect(MemoDetailRef(id: id, dayString: "2026/10/03", source: .today) == nil)
    }

    // MARK: Fail-closed invalid days + empty body / missing UUID

    @Test func invalidCanonicalDays_failClosedWithoutAnyByteWrite() async throws {
        let fixture = try Fixture()
        defer { fixture.restore() }
        let store = MemoRecordStore()
        let memo = Memo(id: UUID(), created: kiritimatiMidnight, body: "guarded body")
        try seed(memo, into: fixture.oct3URL, root: fixture.root)
        let before = try bytes(fixture.oct3URL)
        let rawEntriesBefore = try FileManager.default.contentsOfDirectory(
            atPath: fixture.root.appendingPathComponent("raw").path
        ).sorted()

        let invalidDays = [
            "", "2026-10-3", "2026-2-03", "2026-02-30", "2026-13-01",
            "2026/10/03", "../2026-10-03", "..", "2026-10-03.md", "2026-10-03extra",
        ]
        for day in invalidDays {
            do {
                _ = try await store.memo(id: memo.id, dayString: day, vaultRoot: fixture.root)
                Issue.record("memo must fail closed for invalid day '\(day)'")
            } catch let error as MemoRecordStoreError {
                #expect(error == .invalidDay(day))
            }
            do {
                _ = try await store.updateBody(id: memo.id, dayString: day, body: "x", vaultRoot: fixture.root)
                Issue.record("updateBody must fail closed for invalid day '\(day)'")
            } catch let error as MemoRecordStoreError {
                #expect(error == .invalidDay(day))
            }
            do {
                _ = try await store.delete(id: memo.id, dayString: day, vaultRoot: fixture.root)
                Issue.record("delete must fail closed for invalid day '\(day)'")
            } catch let error as MemoRecordStoreError {
                #expect(error == .invalidDay(day))
            }
            do {
                _ = try await store.setPinnedAt(id: memo.id, dayString: day, pinnedAt: Date(), vaultRoot: fixture.root)
                Issue.record("setPinnedAt must fail closed for invalid day '\(day)'")
            } catch let error as MemoRecordStoreError {
                #expect(error == .invalidDay(day))
            }
            do {
                try await store.restore(memo, dayString: day, vaultRoot: fixture.root)
                Issue.record("restore must fail closed for invalid day '\(day)'")
            } catch let error as MemoRecordStoreError {
                #expect(error == .invalidDay(day))
            }
            do {
                _ = try RawStorage.read(dayString: day, vaultRoot: fixture.root)
                Issue.record("RawStorage.read must fail closed for invalid day '\(day)'")
            } catch let error as RawStorageError {
                guard case .invalidDayString = error else {
                    Issue.record("unexpected RawStorageError \(error) for '\(day)'")
                    continue
                }
            }
            #expect(RawStorage.fileURL(forDayString: day, vaultRoot: fixture.root) == nil)
        }

        // Empty body and missing UUID fail closed as well.
        do {
            _ = try await store.updateBody(
                id: memo.id, dayString: "2026-10-03", body: "  \n", vaultRoot: fixture.root
            )
            Issue.record("emptyBody must fail")
        } catch let error as MemoRecordStoreError {
            #expect(error == .emptyBody)
        }
        do {
            _ = try await store.updateBody(
                id: UUID(), dayString: "2026-10-03", body: "nobody", vaultRoot: fixture.root
            )
            Issue.record("missing UUID must fail")
        } catch let error as MemoRecordStoreError {
            guard case .notFound = error else {
                Issue.record("unexpected store error \(error)")
                return
            }
        }

        #expect(try bytes(fixture.oct3URL) == before)
        let rawEntriesAfter = try FileManager.default.contentsOfDirectory(
            atPath: fixture.root.appendingPathComponent("raw").path
        ).sorted()
        #expect(rawEntriesAfter == rawEntriesBefore)
    }

    // MARK: Repeated restore idempotence

    @Test func repeatedRestoreOnCanonicalKey_isIdempotent() async throws {
        let fixture = try Fixture()
        defer { fixture.restore() }
        let store = MemoRecordStore()
        let memo = Memo(id: UUID(), created: kiritimatiMidnight, body: "undo me")
        try seed(memo, into: fixture.oct3URL, root: fixture.root)

        fixture.preferZone("America/Los_Angeles")
        let deleted = try await store.delete(id: memo.id, dayString: "2026-10-03", vaultRoot: fixture.root)
        try await store.restore(deleted, dayString: "2026-10-03", vaultRoot: fixture.root)
        let afterFirst = try bytes(fixture.oct3URL)
        try await store.restore(deleted, dayString: "2026-10-03", vaultRoot: fixture.root)
        try await store.restore(deleted, dayString: "2026-10-03", vaultRoot: fixture.root)
        #expect(try bytes(fixture.oct3URL) == afterFirst)
        #expect(try RawStorage.read(dayString: "2026-10-03", vaultRoot: fixture.root).map(\.id) == [memo.id])
    }

    // MARK: Cross-midnight: memo.created differs from the owning file day

    @Test func crossMidnightMemo_mutatesOwningFileNotCreatedDay() async throws {
        let fixture = try Fixture()
        defer { fixture.restore() }
        let store = MemoRecordStore()
        fixture.preferZone("America/Los_Angeles")

        // The memo's timestamp lands on Oct 2 in the current zone, but its
        // owning raw file (as known by the entry point) is Oct 3.
        let memo = Memo(id: UUID(), created: losAngelesAfternoon, body: "filed across midnight")
        #expect(RawStorage.dayString(for: memo.created) == "2026-10-02")
        let sibling = Memo(created: losAngelesAfternoon, body: "Oct2 sibling unchanged")
        try seed(sibling, into: fixture.oct2URL, root: fixture.root)
        try seed(memo, into: fixture.oct3URL, root: fixture.root)
        let oct2Before = try bytes(fixture.oct2URL)
        let ref = try #require(MemoDetailRef(id: memo.id, dayString: "2026-10-03", source: .raw))

        _ = try await store.updateBody(
            id: ref.id, dayString: ref.dayString, body: "edited owning file", vaultRoot: fixture.root
        )
        #expect(try RawStorage.read(dayString: "2026-10-03", vaultRoot: fixture.root).first?.body == "edited owning file")
        #expect(try bytes(fixture.oct2URL) == oct2Before)
    }

    // MARK: Skipped local midnight

    @Test func skippedLocalMidnight_dayKeyStaysValidAndTargetsExactFile() async throws {
        let fixture = try Fixture()
        defer { fixture.restore() }
        let store = MemoRecordStore()
        // America/Santiago springs forward at 2026-09-06 00:00 → 01:00:
        // local midnight of that day does not exist.
        fixture.preferZone("America/Santiago")
        #expect(RawStorage.isValidDayString("2026-09-06"))

        let memo = Memo(id: UUID(), created: Date(timeIntervalSince1970: 1_791_024_000), body: "skipped midnight")
        let url = fixture.root.appendingPathComponent("raw/2026-09-06.md")
        try seed(memo, into: url, root: fixture.root)

        let ref = try #require(MemoDetailRef(id: memo.id, dayString: "2026-09-06", source: .archive))
        let loaded = try await store.memo(id: ref.id, dayString: ref.dayString, vaultRoot: fixture.root)
        #expect(loaded.body == "skipped midnight")
        _ = try await store.updateBody(
            id: ref.id, dayString: ref.dayString, body: "edited on skipped day", vaultRoot: fixture.root
        )
        #expect(try RawStorage.read(dayString: "2026-09-06", vaultRoot: fixture.root).first?.body == "edited on skipped day")
    }

    // MARK: Notification carries the actual written file key

    @Test func writeNotification_carriesActualWrittenFileKeyAfterZoneSwitch() async throws {
        let fixture = try Fixture()
        defer { fixture.restore() }
        let store = MemoRecordStore()
        let memo = Memo(id: UUID(), created: kiritimatiMidnight, body: "notify me")
        try seed(memo, into: fixture.oct3URL, root: fixture.root)

        final class Collector {
            var keys: [String] = []
        }
        let collector = Collector()
        let token = NotificationCenter.default.addObserver(
            forName: .rawStorageDidWrite,
            object: nil,
            queue: nil
        ) { notification in
            if let key = notification.userInfo?[RawStorage.writtenDayStringKey] as? String {
                collector.keys.append(key)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        fixture.preferZone("Pacific/Kiritimati")
        _ = try await store.updateBody(
            id: memo.id, dayString: "2026-10-03", body: "notified", vaultRoot: fixture.root
        )
        fixture.preferZone("America/Los_Angeles")
        _ = try await store.updateBody(
            id: memo.id, dayString: "2026-10-03", body: "notified again", vaultRoot: fixture.root
        )

        #expect(collector.keys.allSatisfy { $0 == "2026-10-03" })
        #expect(collector.keys.contains("2026-10-03"))
        #expect(!collector.keys.isEmpty)
    }
}
}

extension DayPageSerialSwiftTests {
@Suite("CanonicalDayIndexNotificationTests", .serialized)
@MainActor
struct CanonicalDayIndexNotificationTests {
    private final class WriteKeys: @unchecked Sendable {
        private let lock = NSLock()
        private var keys: [String?] = []
        func record(_ value: String?) {
            lock.lock()
            defer { lock.unlock() }
            keys.append(value)
        }
        func take() -> [String?] {
            lock.lock()
            defer { lock.unlock() }
            let result = keys
            keys.removeAll()
            return result
        }
    }

    private struct Fixture {
        let root: URL
        let previousURL: URL
        let owningURL: URL
        let previous: Memo
        let owning: Memo
        let previousBytes: Data
    }

    private func withFixture(
        startingZone: String,
        _ operation: (Fixture) async throws -> Void
    ) async throws {
        let defaults = UserDefaults.standard
        let originalZone = defaults.object(forKey: "preferredTimeZone")
        let originalRoot = VaultInitializer.testOverrideURL
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("canonical-cache-\(UUID().uuidString)")
        defer {
            TimelineIndex.shared.resetForTesting()
            SearchIndex.shared.resetForTesting()
            VaultInitializer.testOverrideURL = originalRoot
            if let originalZone {
                defaults.set(originalZone, forKey: "preferredTimeZone")
            } else {
                defaults.removeObject(forKey: "preferredTimeZone")
            }
            try? FileManager.default.removeItem(at: root)
        }
        defaults.set(startingZone, forKey: "preferredTimeZone")
        VaultInitializer.testOverrideURL = root
        let raw = root.appendingPathComponent("raw")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let previousURL = raw.appendingPathComponent("2026-10-02.md")
        let owningURL = raw.appendingPathComponent("2026-10-03.md")
        let instant = try #require(ISO8601DateFormatter().date(from: "2026-10-02T23:00:00Z"))
        let previous = Memo(created: instant.addingTimeInterval(-86400), body: "Oct2 untouched cache")
        // Owning file day is deliberately independent from created's local day.
        let owning = Memo(created: instant, body: "Oct3 original cache")
        try previous.toMarkdown().write(to: previousURL, atomically: true, encoding: .utf8)
        try owning.toMarkdown().write(to: owningURL, atomically: true, encoding: .utf8)
        TimelineIndex.shared.rebuildSynchronouslyForTesting()
        SearchIndex.shared.rebuildSynchronouslyForTesting(root: root)
        let fixture = Fixture(root: root, previousURL: previousURL, owningURL: owningURL,
            previous: previous, owning: owning, previousBytes: try Data(contentsOf: previousURL))
        do {
            try await operation(fixture)
        } catch {
            await settleIndexes()
            throw error
        }
        // Keep the private global root bound until delivered notifications and
        // all resulting incremental tasks have finished, including failures.
        await settleIndexes()
    }

    private func settleIndexes() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        await TimelineIndex.shared.waitUntilIdleForTesting()
        await SearchIndex.shared.waitUntilIdleForTesting()
    }

    private func assertOwningCache(id: UUID, body: String, count: Int = 1) async throws {
        let documents = await SearchIndex.shared.documents()
        let day = try #require(documents.first { $0.dateString == "2026-10-03" })
        #expect(day.memos.map(\.id) == [id])
        #expect(day.memos.map(\.body) == [body])
        let entry = try #require(TimelineIndex.shared.entries().first { $0.dateString == "2026-10-03" })
        #expect(entry.memoCount == count)
        #expect(entry.excerpt == body)
    }

    private func assertPreviousCache(body: String) async throws {
        let documents = await SearchIndex.shared.documents()
        let previous = try #require(documents.first { $0.dateString == "2026-10-02" })
        #expect(previous.memos.map(\.body) == [body])
        #expect(TimelineIndex.shared.entries().first { $0.dateString == "2026-10-02" }?.excerpt == body)
    }

    private func expectInvalidDay(_ value: String, operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("Invalid owning day was accepted: \(value)")
        } catch let error as MemoRecordStoreError {
            #expect(error == .invalidDay(value))
        } catch {
            Issue.record("Unexpected invalid-day error: \(error)")
        }
    }

    @Test func malformedOwningDayFailsBeforeRouteOrStorageWrites() async throws {
        try await withFixture(startingZone: "Pacific/Apia") { fixture in
            let store = MemoRecordStore()
            for value in ["10000-10-03", "0000-01-01", "2026-02-30", "2026-2-03",
                          "2026-10-3", "２０２６-10-03", "../2026-10-03",
                          "2026-10-03/../../outside", "2026-10-03\n", "2026-10-03T00:00:00Z"] {
                #expect(!RawStorage.isValidDayString(value))
                #expect(RawStorage.fileURL(forDayString: value, vaultRoot: fixture.root) == nil)
                #expect(MemoDetailRef(id: fixture.owning.id, dayString: value, source: .archive) == nil)
                await expectInvalidDay(value) {
                    _ = try await store.memo(id: fixture.owning.id, dayString: value, vaultRoot: fixture.root)
                }
                await expectInvalidDay(value) {
                    _ = try await store.updateBody(id: fixture.owning.id, dayString: value,
                        body: "Must never be written", vaultRoot: fixture.root)
                }
                await expectInvalidDay(value) {
                    _ = try await store.delete(id: fixture.owning.id, dayString: value, vaultRoot: fixture.root)
                }
                await expectInvalidDay(value) {
                    try await store.restore(fixture.owning, dayString: value, vaultRoot: fixture.root)
                }
                await expectInvalidDay(value) {
                    _ = try await store.setPinnedAt(id: fixture.owning.id, dayString: value,
                        pinnedAt: Date(), vaultRoot: fixture.root)
                }
                #expect(try Data(contentsOf: fixture.previousURL) == fixture.previousBytes)
                #expect(try Data(contentsOf: fixture.owningURL) == Data(fixture.owning.toMarkdown().utf8))
                let names = try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent("raw").path)
                #expect(Set(names) == ["2026-10-02.md", "2026-10-03.md"])
            }
            // This civil date skipped local midnight in Apia. Its Gregorian
            // file key must remain valid and addressable after a zone change.
            #expect(RawStorage.isValidDayString("2011-12-30"))
            let skippedDayURL = try #require(RawStorage.fileURL(forDayString: "2011-12-30", vaultRoot: fixture.root))
            #expect(skippedDayURL.lastPathComponent == "2011-12-30.md")
            let skippedRoute = try #require(MemoDetailRef(id: fixture.owning.id,
                dayString: "2011-12-30", source: .archive))
            #expect(skippedRoute.dayString == "2011-12-30")
        }
    }

    @Test func canonicalMutationDeleteRestoreConvergesAcrossBothZoneDirections() async throws {
        for (before, after) in [("America/Los_Angeles", "Pacific/Kiritimati"),
                                ("Pacific/Kiritimati", "America/Los_Angeles")] {
            try await withFixture(startingZone: before) { fixture in
                UserDefaults.standard.set(after, forKey: "preferredTimeZone")
                var unsignalledPrevious = fixture.previous
                unsignalledPrevious.body = "Oct2 independent disk revision"
                let preservedBytes = Data(unsignalledPrevious.toMarkdown().utf8)
                try preservedBytes.write(to: fixture.previousURL, options: .atomic)
                let keys = WriteKeys()
                let observer = NotificationCenter.default.addObserver(
                    forName: .rawStorageDidWrite, object: nil, queue: nil
                ) { note in
                    keys.record(note.userInfo?[RawStorage.writtenDayStringKey] as? String)
                }
                defer { NotificationCenter.default.removeObserver(observer) }
                let store = MemoRecordStore()
                let edited = try await store.updateBody(id: fixture.owning.id, dayString: "2026-10-03",
                    body: "Oct3 edited cache", vaultRoot: fixture.root)
                let updateKeys = keys.take()
                #expect(!updateKeys.isEmpty && updateKeys.allSatisfy { $0 == "2026-10-03" })
                await settleIndexes()
                try await assertOwningCache(id: edited.id, body: edited.body)
                try await assertPreviousCache(body: fixture.previous.body)
                #expect(try Data(contentsOf: fixture.previousURL) == preservedBytes)
                let deleted = try await store.delete(id: edited.id, dayString: "2026-10-03", vaultRoot: fixture.root)
                let deleteKeys = keys.take()
                #expect(!deleteKeys.isEmpty && deleteKeys.allSatisfy { $0 == "2026-10-03" })
                await settleIndexes()
                let documents = await SearchIndex.shared.documents()
                #expect(documents.allSatisfy { !$0.memos.contains { $0.id == deleted.id } })
                #expect(TimelineIndex.shared.entries().allSatisfy { $0.dateString != "2026-10-03" })
                try await assertPreviousCache(body: fixture.previous.body)
                #expect(try Data(contentsOf: fixture.previousURL) == preservedBytes)
                try await store.restore(deleted, dayString: "2026-10-03", vaultRoot: fixture.root)
                let restoreKeys = keys.take()
                #expect(!restoreKeys.isEmpty && restoreKeys.allSatisfy { $0 == "2026-10-03" })
                try await store.restore(deleted, dayString: "2026-10-03", vaultRoot: fixture.root)
                await settleIndexes()
                try await assertOwningCache(id: deleted.id, body: deleted.body)
                try await assertPreviousCache(body: fixture.previous.body)
                #expect(try Data(contentsOf: fixture.previousURL) == preservedBytes)
                let previousDocument = try #require((await SearchIndex.shared.documents())
                    .first { $0.dateString == "2026-10-02" })
                #expect(previousDocument.memos.map(\.id) == [fixture.previous.id])
                #expect(previousDocument.memos.map(\.body) == [fixture.previous.body])
            }
        }
    }

    @Test func canonicalKeyWinsOverContradictoryDateWithoutRebuildingOtherDays() async throws {
        try await withFixture(startingZone: "America/Los_Angeles") { fixture in
            UserDefaults.standard.set("Pacific/Kiritimati", forKey: "preferredTimeZone")
            var previousOnDisk = fixture.previous
            previousOnDisk.body = "Oct2 intentionally newer on disk"
            try previousOnDisk.toMarkdown().write(to: fixture.previousURL, atomically: true, encoding: .utf8)
            var edited = fixture.owning
            edited.body = "Oct3 canonical notification cache"
            try edited.toMarkdown().write(to: fixture.owningURL, atomically: true, encoding: .utf8)
            let incompatibleDate = try #require(ISO8601DateFormatter().date(from: "2000-01-01T12:00:00Z"))
            NotificationCenter.default.post(name: .rawStorageDidWrite, object: incompatibleDate,
                userInfo: [RawStorage.writtenDayStringKey: "2026-10-03"])
            await settleIndexes()
            try await assertOwningCache(id: edited.id, body: edited.body)
            // A full rebuild would expose the unsignalled Oct2 disk revision.
            // Its old cache proves the valid notification refreshed only Oct3.
            let previousDocument = try #require((await SearchIndex.shared.documents())
                .first { $0.dateString == "2026-10-02" })
            #expect(previousDocument.memos.map(\.body) == [fixture.previous.body])
            #expect(TimelineIndex.shared.entries().first { $0.dateString == "2026-10-02" }?.excerpt == fixture.previous.body)
            #expect(try Data(contentsOf: fixture.previousURL) == Data(previousOnDisk.toMarkdown().utf8))
        }
    }

    @Test func legacyAndInvalidNotificationsSafelyRefreshRealDayFiles() async throws {
        try await withFixture(startingZone: "America/Los_Angeles") { fixture in
            let outside = Memo(body: "Outside marker must never enter the cache")
            try outside.toMarkdown().write(to: fixture.root.appendingPathComponent("outside.md"),
                atomically: true, encoding: .utf8)
            for (index, key) in [nil, "../outside", "2026-02-30", "2026-10-03/../../outside"].enumerated() {
                var previous = fixture.previous
                previous.body = "Oct2 full refresh \(index)"
                let preservedBytes = Data(previous.toMarkdown().utf8)
                try preservedBytes.write(to: fixture.previousURL, options: .atomic)
                var edited = fixture.owning
                edited.body = "Oct3 safe refresh \(index)"
                try edited.toMarkdown().write(to: fixture.owningURL, atomically: true, encoding: .utf8)
                let info: [AnyHashable: Any]? = key.map { [RawStorage.writtenDayStringKey: $0] }
                NotificationCenter.default.post(name: .rawStorageDidWrite, object: Date.distantPast, userInfo: info)
                await settleIndexes()
                try await assertOwningCache(id: edited.id, body: edited.body)
                try await assertPreviousCache(body: previous.body)
                let documents = await SearchIndex.shared.documents()
                #expect(Set(documents.map(\.dateString)) == ["2026-10-02", "2026-10-03"])
                #expect(documents.allSatisfy { !$0.memos.contains { $0.id == outside.id } })
                #expect(try Data(contentsOf: fixture.previousURL) == preservedBytes)
            }
        }
    }
}
}
