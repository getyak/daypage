import Foundation
import DayPageModels
import DayPageStorage

// MARK: - SearchIndex

/// In-memory full-text search index over `vault/raw/*.md`, keyed by
/// `yyyy-MM-dd`. Companion to ``TimelineIndex`` (#827): where TimelineIndex
/// caches per-day *metadata*, this caches per-memo *searchable text* with the
/// expensive `folding(...)` normalization precomputed, so a keystroke's search
/// is a pure in-memory scan instead of a full-vault disk read + YAML parse.
///
/// ## Why this exists
/// `SearchService.search` re-read and re-parsed every raw day file on every
/// (debounced) keystroke. The same measurement that motivated TimelineIndex
/// applies: ~295 ms at 1 year of data, ~7 s at 5 years — per keystroke, on
/// battery. The index pays that scan once, off the main thread.
///
/// ## Design (deliberately identical to TimelineIndex)
/// - **Pure in-memory, rebuilt when Search is first used.** No persistence →
///   no snapshot/truth drift. `vault/raw/*.md` remains the source of truth.
/// - **Per-file metadata external-change detection** on foreground, including
///   edits to existing Markdown files that do not change the directory mtime.
/// - **Incremental write updates** via `.rawStorageDidWrite` — re-parse just
///   the one day that changed.
/// - **Conflict-merge rebuild** via `.vaultConflictResolved`.
/// - **No cold-path duplicate scan**: a cold search awaits the in-flight index
///   build asynchronously, then queries the completed memory snapshot.
///
/// `isDailyPageCompiled` is intentionally NOT cached here: daily compilation
/// writes `wiki/daily/` (never `raw/`), so no notification would invalidate
/// it. Query code stats the handful of matched days instead (≤100 by cap).
@MainActor
public final class SearchIndex {

    public static let shared = SearchIndex()

    // MARK: - Document model

    /// One memo, flattened to what search needs. `folded*` fields carry the
    /// `caseInsensitive + diacriticInsensitive + widthInsensitive` normalization
    /// precomputed at build time. Value type so query code can snapshot the
    /// whole index and match off the main actor.
    public struct MemoDocument: Equatable, Sendable {
        public let id: UUID
        public let type: Memo.MemoType
        public let body: String
        public let foldedBody: String
        public let entityMentions: [String]
        /// Attachment transcripts, raw + folded, in attachment order.
        public let transcripts: [TranscriptText]
        public let locationName: String?
        public let foldedLocationName: String?

        public struct TranscriptText: Equatable, Sendable {
            public let raw: String
            public let folded: String
        }
    }

    /// All searchable memos of one day, plus the day's pre-folded date string
    /// (date matches like "2026-04" fold the same way as body text).
    public struct DayDocument: Equatable, Sendable {
        public let dateString: String
        public let foldedDateString: String
        public let memos: [MemoDocument]
    }

    // MARK: - State

    /// `yyyy-MM-dd` → day document. Authoritative once built.
    private var docsByDate: [String: DayDocument] = [:]

    /// Newest-first snapshot handed to query code. Rebuilt lazily after any
    /// mutation (dictionary order is unstable; search results must be
    /// deterministic newest-first, same as the legacy file-name sort).
    private var sortedSnapshot: [DayDocument]?

    /// True once the first full rebuild has completed.
    private var isBuilt = false

    /// Per-file size + modification-date snapshot from the last rebuild.
    private var rawFileSnapshot = RawVaultFileSnapshot(files: [:])

    /// Guards against overlapping rebuilds.
    private var rebuildTask: Task<Void, Never>?

    /// Coalesces off-main foreground metadata checks.
    private var refreshTask: Task<Void, Never>?

    private var rebuildRequestedAfterCurrent = false
    private var pendingWriteDates: Set<String> = []
    private var dayUpdateTasks: [String: Task<Void, Never>] = [:]

    private var observerTokens: [NSObjectProtocol] = []

    // MARK: - Init

    private init() {
        // Same observer shape as TimelineIndex: `.rawStorageDidWrite` posts
        // from RawStorage's background writeQueue, so hop to the main actor
        // via queue: .main before touching @MainActor state.
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
                self?.scheduleRebuild(rebuildAgainIfRunning: true)
            }
        }
        observerTokens = [writeToken, conflictToken]
    }

    deinit {
        observerTokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Public read API

    /// Newest-first day documents, or nil while the first build is still in
    /// flight. Interactive search uses `documents()` so it awaits the same
    /// asynchronous build instead of starting a duplicate legacy disk scan.
    public func documentsIfBuilt() -> [DayDocument]? {
        guard isBuilt else { return nil }
        if let cached = sortedSnapshot { return cached }
        let sorted = docsByDate.values.sorted { $0.dateString > $1.dateString }
        sortedSnapshot = sorted
        return sorted
    }

    /// Returns a complete in-memory snapshot, waiting asynchronously for the
    /// first build when necessary. Search uses this instead of launching a
    /// second legacy full-vault scan while warm-up is already in flight.
    public func documents() async -> [DayDocument] {
        if !isBuilt { scheduleRebuild() }
        while let task = rebuildTask {
            await task.value
        }
        return documentsIfBuilt() ?? []
    }

    // MARK: - Lifecycle hooks

    /// Kick the initial background build. Idempotent; call when the search
    /// surface appears so launch I/O remains focused on Today.
    public func warmUp() {
        guard !isBuilt else { return }
        scheduleRebuild()
    }

    /// Rebuild if raw Markdown was modified externally (iCloud, Obsidian,
    /// another device). Metadata enumeration stays off the main actor.
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

    private func scheduleRebuild(rebuildAgainIfRunning: Bool = false) {
        if let existing = rebuildTask, !existing.isCancelled {
            if rebuildAgainIfRunning { rebuildRequestedAfterCurrent = true }
            return
        }

        refreshTask?.cancel()
        refreshTask = nil
        dayUpdateTasks.values.forEach { $0.cancel() }
        dayUpdateTasks.removeAll()

        rebuildTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                let before = RawVaultFileSnapshot.capture()
                let documents = Self.scanAllDocuments()
                let after = RawVaultFileSnapshot.capture()
                return (documents, before, after)
            }.value
            guard !Task.isCancelled else { return }
            guard let self else { return }

            if result.1 != result.2 || self.rebuildRequestedAfterCurrent {
                self.rebuildRequestedAfterCurrent = false
                self.pendingWriteDates.removeAll()
                self.rebuildTask = nil
                self.scheduleRebuild()
                return
            }

            self.docsByDate = result.0
            self.sortedSnapshot = nil
            self.rawFileSnapshot = result.2
            self.isBuilt = true
            self.rebuildTask = nil

            let pendingDates = self.pendingWriteDates
            self.pendingWriteDates.removeAll()
            for stem in pendingDates {
                self.scheduleDayUpdate(stem)
            }
        }
    }

    // MARK: - Incremental updates

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

    /// Parse changed Markdown away from the main actor. Cancelling the previous
    /// task for the same date ensures stale work can never overwrite a newer
    /// edit when writes arrive in a burst.
    private func scheduleDayUpdate(_ stem: String) {
        dayUpdateTasks[stem]?.cancel()
        dayUpdateTasks[stem] = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                let document = Self.scanDocument(dateString: stem)
                let signature = RawVaultFileSnapshot.signature(forDateString: stem)
                return (document, signature)
            }.value
            guard !Task.isCancelled, let self else { return }

            if let document = result.0 {
                self.docsByDate[stem] = document
            } else {
                self.docsByDate.removeValue(forKey: stem)
            }
            self.sortedSnapshot = nil
            self.rawFileSnapshot.update(dateString: stem, signature: result.1)
            self.dayUpdateTasks[stem] = nil
        }
    }

    // MARK: - Scanning (nonisolated — runs on detached tasks)

    /// Full-vault scan → day documents. Same file discovery rules as the
    /// legacy `SearchService.search` (raw/*.md, valid yyyy-MM-dd stems only).
    nonisolated private static func scanAllDocuments(root: URL? = nil) -> [String: DayDocument] {
        let fm = FileManager.default
        let rawDir = (root ?? VaultInitializer.vaultURL).appendingPathComponent("raw")
        guard let files = try? fm.contentsOfDirectory(
            at: rawDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [:] }

        var docs: [String: DayDocument] = [:]
        for url in files where url.pathExtension == "md" {
            let stem = url.deletingPathExtension().lastPathComponent
            guard isValidDateString(stem) else { continue }
            if let doc = scanDocument(dateString: stem, fileURL: url) {
                docs[stem] = doc
            }
        }
        return docs
    }

    /// Parse one day file into a document. nil when the file is missing,
    /// unreadable, or holds no memos (deleted-last-memo case — the entry
    /// must disappear from the index).
    nonisolated static func scanDocument(
        dateString: String, fileURL: URL? = nil
    ) -> DayDocument? {
        let url = fileURL ?? VaultInitializer.vaultURL
            .appendingPathComponent("raw")
            .appendingPathComponent("\(dateString).md")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let memos = RawStorage.parse(fileContent: content)
        guard !memos.isEmpty else { return nil }

        let memoDocs = memos.map { memo in
            MemoDocument(
                id: memo.id,
                type: memo.type,
                body: memo.body,
                foldedBody: SearchService.foldForSearch(memo.body),
                entityMentions: memo.entityMentions,
                transcripts: memo.attachments.compactMap { att in
                    guard let t = att.transcript, !t.isEmpty else { return nil }
                    return MemoDocument.TranscriptText(
                        raw: t, folded: SearchService.foldForSearch(t)
                    )
                },
                locationName: memo.location?.name,
                foldedLocationName: memo.location?.name.map(SearchService.foldForSearch)
            )
        }
        return DayDocument(
            dateString: dateString,
            foldedDateString: SearchService.foldForSearch(dateString),
            memos: memoDocs
        )
    }

    // MARK: - Helpers

    nonisolated private static func isValidDateString(_ s: String) -> Bool {
        RawStorage.isValidDayString(s)
    }

    // MARK: - Test support

    /// Test-only: synchronous full build so tests can assert deterministically.
    /// `root` pins the scan to a private temp vault so parallel suites can't
    /// race on the global vault override (#827).
    public func rebuildSynchronouslyForTesting(root: URL? = nil) {
        rebuildTask?.cancel()
        rebuildTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        dayUpdateTasks.values.forEach { $0.cancel() }
        dayUpdateTasks.removeAll()
        docsByDate = Self.scanAllDocuments(root: root)
        sortedSnapshot = nil
        rawFileSnapshot = RawVaultFileSnapshot.capture(root: root ?? VaultInitializer.vaultURL)
        isBuilt = true
        rebuildRequestedAfterCurrent = false
        pendingWriteDates.removeAll()
    }

    /// Test-only: await incremental updates as well as rebuild/refresh work.
    /// Call after notification delivery has registered the affected day task.
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

    /// Test-only: reset to the never-built state.
    public func resetForTesting() {
        rebuildTask?.cancel()
        rebuildTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        dayUpdateTasks.values.forEach { $0.cancel() }
        dayUpdateTasks.removeAll()
        docsByDate = [:]
        sortedSnapshot = nil
        rawFileSnapshot = RawVaultFileSnapshot(files: [:])
        isBuilt = false
        rebuildRequestedAfterCurrent = false
        pendingWriteDates.removeAll()
    }
}
