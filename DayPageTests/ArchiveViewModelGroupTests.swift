import Testing
import Foundation
import DayPageServices
@testable import DayPage

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
}
