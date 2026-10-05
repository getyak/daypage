import Foundation
import DayPageStorage

// MARK: - TimelineIndex

/// In-memory cache of per-day timeline metadata (`TimelineDayEntry`), keyed by
/// `yyyy-MM-dd`. Eliminates the full-vault scan + YAML parse that
/// `TimelineService.entries()` used to run on every Today-page load.
///
/// ## Why this exists
/// Measured: a full scan of `vault/raw/*.md` grows superlinearly — ~295 ms at
/// 1 year, ~2.7 s at 3 years, ~7 s at 5 years (issue #345). That scan ran on
/// every Today open. This cache turns it into an O(1) dictionary read.
///
/// ## Design (per issue #345, owner-aligned)
/// - **Pure in-memory, rebuilt on launch.** No persistence → no snapshot/truth
///   drift, no iCloud-sync conflicts on an index file. Cold start pays one
///   background scan (off the main thread, never blocking UI).
/// - **Metadata-based external-change detection.** On foreground we compare
///   each raw file's size + modification date. Unlike the directory mtime,
///   this also catches edits to an existing file.
/// - **Incremental write updates.** `RawStorage` posts `.rawStorageDidWrite`
///   after every day-file mutation; we re-read just that one day and patch the
///   single entry — O(today), not a full rebuild.
/// - **Conflict-merge rebuild.** `.vaultConflictResolved` forces a full rebuild
///   because a merge can rewrite arbitrary day files.
///
/// The index is the cache; `vault/raw/*.md` remains the source of truth. The
/// cache is always reconstructible from disk, so losing it is harmless.
@MainActor
public final class TimelineIndex {

    public static let shared = TimelineIndex()

    // MARK: - State

    /// `yyyy-MM-dd` → metadata. The authoritative in-memory view once built.
    private var entriesByDate: [String: TimelineDayEntry] = [:]

    /// Newest-first immutable snapshot handed to readers. Maintaining this at
    /// mutation time keeps `entries()` a constant-time copy-on-write return
    /// instead of sorting the whole dictionary during a SwiftUI update.
    private var orderedEntries: [TimelineDayEntry] = []

    /// True once the first full rebuild has completed. Before that, reads return
    /// the last available snapshot (empty on a first launch) and ensure a
    /// background rebuild is running. The UI observes `.timelineIndexDidUpdate`
    /// and replaces its skeleton when the snapshot becomes ready.
    private var isBuilt = false

    /// Per-file metadata captured at the last rebuild. Foreground validation
    /// compares this lightweight snapshot without parsing Markdown.
    private var rawFileSnapshot = RawVaultFileSnapshot(files: [:])

    /// Guards against overlapping rebuilds (e.g. launch + foreground racing).
    private var rebuildTask: Task<Void, Never>?

    /// Coalesces foreground metadata checks, which enumerate files off-main.
    private var refreshTask: Task<Void, Never>?

    /// A conflict/unknown write that arrives during a rebuild needs a second
    /// pass after the in-flight snapshot commits. A plain coalescing guard would
    /// otherwise silently lose that invalidation.
    private var rebuildRequestedAfterCurrent = false

    /// Specific writes that land while the initial rebuild is scanning. They
    /// are replayed as single-day refreshes after the snapshot swap, closing the
    /// scan-vs-write race without paying another full-vault pass.
    private var pendingWriteDates: Set<String> = []

    /// Latest single-day refresh per date. Rapid edits cancel stale results so
    /// an older parse can never overwrite a newer file revision.
    private var dayUpdateTasks: [String: Task<Void, Never>] = [:]

    /// Block-based observer tokens, removed on deinit.
    private var observerTokens: [NSObjectProtocol] = []

    // MARK: - Init

    private init() {
        // Block-based observers delivered on the main queue. `RawStorage` posts
        // `.rawStorageDidWrite` from inside `writeQueue` (a background thread),
        // so we must hop to the main actor before touching `@MainActor` state —
        // selector-based observers would run synchronously on the posting
        // thread and violate isolation.
        let writeToken = NotificationCenter.default.addObserver(
            forName: .rawStorageDidWrite, object: nil, queue: .main
        ) { [weak self] note in
            let dayString = note.userInfo?[RawStorage.writtenDayStringKey] as? String
            MainActor.assumeIsolated {
                self?.handleDidWrite(dayString: dayString)
            }
        }
        let conflictToken = NotificationCenter.default.addObserver(
            forName: .vaultConflictResolved, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleConflictResolved()
            }
        }
        observerTokens = [writeToken, conflictToken]
    }

    deinit {
        observerTokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Public read API

    /// All days with at least one memo, newest-first. Always nonblocking: on a
    /// cold read this starts/coalesces a background rebuild and returns the last
    /// available snapshot. This method never performs file I/O or parsing on
    /// the main actor.
    public func entries() -> [TimelineDayEntry] {
        if !isBuilt { scheduleRebuild() }
        return orderedEntries
    }

    /// Lets UI surfaces distinguish a genuinely empty Vault from an index that
    /// is still warming without reaching into implementation state.
    public var isReady: Bool { isBuilt }

    // MARK: - Lifecycle hooks

    /// Triggers the initial full rebuild on a background task. Call once after
    /// `VaultInitializer.initializeIfNeeded()` at app launch. Idempotent —
    /// overlapping calls coalesce onto a single in-flight rebuild.
    public func warmUp() {
        guard !isBuilt else { return }
        scheduleRebuild()
    }

    /// Ensures the first consistent snapshot is ready without blocking the
    /// caller's executor. Startup maintenance uses this as an I/O priority
    /// barrier so orphan scans begin only after the visible timeline scan.
    public func warmUpAndWait() async {
        if !isBuilt { scheduleRebuild() }
        while let task = rebuildTask {
            await task.value
        }
    }

    /// Compares lightweight raw-file metadata against the last committed
    /// snapshot. This catches additions, removals, and edits to existing files
    /// without parsing content on every foreground transition.
    public func refreshIfExternallyModified() {
        guard rebuildTask == nil, refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            let current = await Task.detached(priority: .utility) {
                RawVaultFileSnapshot.capture()
            }.value
            guard !Task.isCancelled, let self else { return }
            self.refreshTask = nil
            if current != self.rawFileSnapshot {
                self.scheduleRebuild()
            }
        }
    }

    // MARK: - Rebuild

    /// Full background rebuild. Scans every raw day file once, off the main
    /// actor, then atomically swaps in the new dictionary on the main actor.
    private func scheduleRebuild(rebuildAgainIfRunning: Bool = false) {
        // Coalesce: if a rebuild is already running, let it finish — it will
        // pick up the latest disk state. (A write that lands mid-scan is also
        // covered by the incremental `.rawStorageDidWrite` path.)
        if let existing = rebuildTask, !existing.isCancelled {
            if rebuildAgainIfRunning { rebuildRequestedAfterCurrent = true }
            return
        }

        refreshTask?.cancel()
        refreshTask = nil
        dayUpdateTasks.values.forEach { $0.cancel() }
        dayUpdateTasks.removeAll()

        rebuildTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                let before = RawVaultFileSnapshot.capture()
                let entries = TimelineService.scanAllEntries()
                let after = RawVaultFileSnapshot.capture()
                return (entries, before, after)
            }.value
            guard !Task.isCancelled else { return }
            guard let self else { return }

            // Never publish a snapshot assembled across two disk revisions.
            // Unknown/conflict invalidations take this conservative path too.
            if result.1 != result.2 || self.rebuildRequestedAfterCurrent {
                self.rebuildRequestedAfterCurrent = false
                self.pendingWriteDates.removeAll()
                self.rebuildTask = nil
                self.scheduleRebuild()
                return
            }

            self.applySnapshot(result.0)
            self.rawFileSnapshot = result.2
            self.isBuilt = true
            self.rebuildTask = nil
            NotificationCenter.default.post(name: .timelineIndexDidUpdate, object: nil)

            let pendingDates = self.pendingWriteDates
            self.pendingWriteDates.removeAll()
            for stem in pendingDates {
                self.scheduleDayUpdate(stem)
            }
        }
    }

    // MARK: - Incremental updates

    /// Re-reads a single day off-main and patches its entry (or removes it when
    /// the file disappeared/emptied). Rapid writes to one date coalesce to the
    /// latest task; parsing never runs on the main actor.
    private func scheduleDayUpdate(_ stem: String) {
        dayUpdateTasks[stem]?.cancel()
        dayUpdateTasks[stem] = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                let entry = TimelineService.scanEntry(forDateString: stem)
                let signature = RawVaultFileSnapshot.signature(forDateString: stem)
                return (entry, signature)
            }.value
            guard !Task.isCancelled, let self else { return }

            if let entry = result.0 {
                self.entriesByDate[stem] = entry
            } else {
                self.entriesByDate.removeValue(forKey: stem)
            }
            self.orderedEntries = self.entriesByDate.values.sorted { $0.date > $1.date }
            self.rawFileSnapshot.update(dateString: stem, signature: result.1)
            self.dayUpdateTasks[stem] = nil
            NotificationCenter.default.post(name: .timelineIndexDidUpdate, object: nil)
        }
    }

    // MARK: - Notification handlers

    private func handleDidWrite(dayString: String?) {
        // The writer captured this key from the actual raw file URL. A Date
        // can mean a different stored day after the preferred zone changes.
        // Legacy or malformed notifications conservatively refresh all files.
        guard let stem = dayString, RawStorage.isValidDayString(stem) else {
            scheduleRebuild(rebuildAgainIfRunning: true)
            return
        }
        guard isBuilt, rebuildTask == nil else {
            pendingWriteDates.insert(stem)
            if rebuildTask == nil { scheduleRebuild() }
            return
        }
        scheduleDayUpdate(stem)
    }

    private func handleConflictResolved() {
        // A merge may rewrite any number of day files — rebuild everything.
        scheduleRebuild(rebuildAgainIfRunning: true)
    }

    // MARK: - Helpers

    private func applySnapshot(_ entries: [TimelineDayEntry]) {
        entriesByDate = Dictionary(
            entries.map { ($0.dateString, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        orderedEntries = entries.sorted { $0.date > $1.date }
    }

    // MARK: - Test support

    /// Test-only: synchronously rebuild and wait, bypassing the background task.
    /// Lets unit tests assert post-rebuild state deterministically.
    public func rebuildSynchronouslyForTesting() {
        rebuildTask?.cancel()
        rebuildTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        dayUpdateTasks.values.forEach { $0.cancel() }
        dayUpdateTasks.removeAll()
        let scanned = TimelineService.scanAllEntries()
        applySnapshot(scanned)
        rawFileSnapshot = RawVaultFileSnapshot.capture()
        isBuilt = true
        rebuildRequestedAfterCurrent = false
        pendingWriteDates.removeAll()
    }

    /// Test-only: await the actual asynchronous work instead of relying on a
    /// short wall-clock timeout. The loop also follows work chained by a
    /// refresh (for example, metadata capture scheduling a full rebuild).
    public func waitUntilIdleForTesting() async {
        while true {
            let tasks = [rebuildTask, refreshTask].compactMap { $0 }
                + Array(dayUpdateTasks.values)
            guard !tasks.isEmpty else { return }
            for task in tasks {
                await task.value
            }
        }
    }

    /// Test-only: clear all state so a test starts from a known-empty index.
    public func resetForTesting() {
        rebuildTask?.cancel()
        rebuildTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        dayUpdateTasks.values.forEach { $0.cancel() }
        dayUpdateTasks.removeAll()
        entriesByDate = [:]
        orderedEntries = []
        rawFileSnapshot = RawVaultFileSnapshot(files: [:])
        isBuilt = false
        rebuildRequestedAfterCurrent = false
        pendingWriteDates = []
    }
}

// MARK: - Notification

public extension Notification.Name {
    /// Posted by TimelineIndex whenever the in-memory timeline index changes
    /// (raw-storage write merged in or full rebuild).
    /// Observed by: TodayViewModel (.publisher — drives sectioned timeline refresh
    /// without re-scanning disk).
    public static let timelineIndexDidUpdate = Notification.Name("timelineIndexDidUpdate")
}
