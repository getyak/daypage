import Foundation

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
/// - **mtime-based external-change detection.** On foreground we compare the
///   `raw/` directory mtime against a snapshot; a change (iCloud sync /
///   Obsidian / another device) triggers a background rebuild.
/// - **Incremental write updates.** `RawStorage` posts `.rawStorageDidWrite`
///   after every day-file mutation; we re-read just that one day and patch the
///   single entry — O(today), not a full rebuild.
/// - **Conflict-merge rebuild.** `.vaultConflictResolved` forces a full rebuild
///   because a merge can rewrite arbitrary day files.
///
/// The index is the cache; `vault/raw/*.md` remains the source of truth. The
/// cache is always reconstructible from disk, so losing it is harmless.
@MainActor
final class TimelineIndex {

    static let shared = TimelineIndex()

    // MARK: - State

    /// `yyyy-MM-dd` → metadata. The authoritative in-memory view once built.
    private var entriesByDate: [String: TimelineDayEntry] = [:]

    /// True once the first full rebuild has completed. Before that, reads fall
    /// back to a synchronous scan so the very first Today load is never empty.
    private var isBuilt = false

    /// mtime of `vault/raw/` captured at the last rebuild. Used to detect
    /// external modifications when the app returns to the foreground.
    private var rawDirMtimeSnapshot: Date?

    /// Guards against overlapping rebuilds (e.g. launch + foreground racing).
    private var rebuildTask: Task<Void, Never>?

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
            let date = note.object as? Date
            MainActor.assumeIsolated {
                self?.handleDidWrite(date: date)
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

    /// All days with at least one memo, newest-first. O(1) when the index is
    /// built; on the cold path (index not yet built) it returns a one-shot
    /// synchronous scan so the first load shows correct data immediately, and
    /// retains it so subsequent calls are O(1).
    func entries() -> [TimelineDayEntry] {
        guard isBuilt else {
            // Cold path: build the dictionary synchronously this once so the
            // caller gets correct data, then keep it.
            let scanned = TimelineService.scanAllEntries()
            entriesByDate = Dictionary(
                scanned.map { ($0.dateString, $0) },
                uniquingKeysWith: { a, _ in a }
            )
            rawDirMtimeSnapshot = Self.rawDirMtime()
            isBuilt = true
            return sortedEntries()
        }
        return sortedEntries()
    }

    // MARK: - Lifecycle hooks

    /// Triggers the initial full rebuild on a background task. Call once after
    /// `VaultInitializer.initializeIfNeeded()` at app launch. Idempotent —
    /// overlapping calls coalesce onto a single in-flight rebuild.
    func warmUp() {
        scheduleRebuild()
    }

    /// Compares the current `raw/` mtime against the snapshot and rebuilds if it
    /// changed. Call when the app enters the foreground. Cheap when nothing
    /// changed (a single stat()).
    func refreshIfExternallyModified() {
        let current = Self.rawDirMtime()
        if current != rawDirMtimeSnapshot {
            scheduleRebuild()
        }
    }

    // MARK: - Rebuild

    /// Full background rebuild. Scans every raw day file once, off the main
    /// actor, then atomically swaps in the new dictionary on the main actor.
    private func scheduleRebuild() {
        // Coalesce: if a rebuild is already running, let it finish — it will
        // pick up the latest disk state. (A write that lands mid-scan is also
        // covered by the incremental `.rawStorageDidWrite` path.)
        if let existing = rebuildTask, !existing.isCancelled { return }

        rebuildTask = Task { [weak self] in
            let scanned = await Task.detached(priority: .userInitiated) {
                TimelineService.scanAllEntries()
            }.value
            let mtime = Self.rawDirMtime()
            guard let self else { return }
            self.entriesByDate = Dictionary(
                scanned.map { ($0.dateString, $0) },
                uniquingKeysWith: { a, _ in a }
            )
            self.rawDirMtimeSnapshot = mtime
            self.isBuilt = true
            self.rebuildTask = nil
            NotificationCenter.default.post(name: .timelineIndexDidUpdate, object: nil)
        }
    }

    // MARK: - Incremental updates

    /// Re-reads a single day file and patches its entry (or removes it when the
    /// day no longer has memos). O(memos in that one day). Skips work entirely
    /// before the first full build — the `entries()` cold path covers that case.
    private func updateDay(_ date: Date) {
        guard isBuilt else { return }
        let stem = Self.dateFormatter.string(from: date)
        if let entry = TimelineService.scanEntry(forDateString: stem) {
            entriesByDate[stem] = entry
        } else {
            entriesByDate.removeValue(forKey: stem)
        }
        // Keep the mtime snapshot fresh so our own write isn't mistaken for an
        // external change on the next foreground check.
        rawDirMtimeSnapshot = Self.rawDirMtime()
        NotificationCenter.default.post(name: .timelineIndexDidUpdate, object: nil)
    }

    // MARK: - Notification handlers

    private func handleDidWrite(date: Date?) {
        guard let date else {
            // Unknown origin → safest is a full rebuild.
            scheduleRebuild()
            return
        }
        updateDay(date)
    }

    private func handleConflictResolved() {
        // A merge may rewrite any number of day files — rebuild everything.
        scheduleRebuild()
    }

    // MARK: - Helpers

    private func sortedEntries() -> [TimelineDayEntry] {
        entriesByDate.values.sorted { $0.date > $1.date }
    }

    /// Directory mtime of `vault/raw/`. nil when the directory doesn't exist
    /// yet (pre-initialization) — treated as "no snapshot".
    private static func rawDirMtime() -> Date? {
        let rawDir = VaultInitializer.vaultURL.appendingPathComponent("raw")
        let attrs = try? FileManager.default.attributesOfItem(atPath: rawDir.path)
        return attrs?[.modificationDate] as? Date
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = AppSettings.currentTimeZone()
        return f
    }()

    // MARK: - Test support

    /// Test-only: synchronously rebuild and wait, bypassing the background task.
    /// Lets unit tests assert post-rebuild state deterministically.
    func rebuildSynchronouslyForTesting() {
        let scanned = TimelineService.scanAllEntries()
        entriesByDate = Dictionary(
            scanned.map { ($0.dateString, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        rawDirMtimeSnapshot = Self.rawDirMtime()
        isBuilt = true
    }

    /// Test-only: clear all state so a test starts from a known-empty index.
    func resetForTesting() {
        rebuildTask?.cancel()
        rebuildTask = nil
        entriesByDate = [:]
        rawDirMtimeSnapshot = nil
        isBuilt = false
    }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted (on the main actor) whenever the in-memory timeline index changes,
    /// so views can refresh their displayed sections without re-scanning disk.
    static let timelineIndexDidUpdate = Notification.Name("timelineIndexDidUpdate")
}
