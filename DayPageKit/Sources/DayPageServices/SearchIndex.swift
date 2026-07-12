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
/// - **Pure in-memory, rebuilt on launch.** No persistence → no snapshot/truth
///   drift. `vault/raw/*.md` remains the source of truth.
/// - **mtime-based external-change detection** on foreground.
/// - **Incremental write updates** via `.rawStorageDidWrite` — re-parse just
///   the one day that changed.
/// - **Conflict-merge rebuild** via `.vaultConflictResolved`.
/// - **No cold-path sync scan**: before the first build completes,
///   `documentsIfBuilt()` returns nil and callers fall back to the legacy
///   disk-scanning `SearchService.search` — search stays correct on a cold
///   start, it's just not indexed yet.
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
        public let type: Memo.MemoType
        public let body: String
        public let foldedBody: String
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

    /// mtime of `vault/raw/` captured at the last rebuild.
    private var rawDirMtimeSnapshot: Date?

    /// Guards against overlapping rebuilds.
    private var rebuildTask: Task<Void, Never>?

    private var observerTokens: [NSObjectProtocol] = []

    // MARK: - Init

    private init() {
        // Same observer shape as TimelineIndex: `.rawStorageDidWrite` posts
        // from RawStorage's background writeQueue, so hop to the main actor
        // via queue: .main before touching @MainActor state.
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
                self?.scheduleRebuild()
            }
        }
        observerTokens = [writeToken, conflictToken]
    }

    deinit {
        observerTokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Public read API

    /// Newest-first day documents, or nil while the first build is still in
    /// flight. Callers fall back to the legacy disk scan on nil — never block
    /// the main actor on a cold synchronous vault scan here.
    public func documentsIfBuilt() -> [DayDocument]? {
        guard isBuilt else { return nil }
        if let cached = sortedSnapshot { return cached }
        let sorted = docsByDate.values.sorted { $0.dateString > $1.dateString }
        sortedSnapshot = sorted
        return sorted
    }

    // MARK: - Lifecycle hooks

    /// Kick the initial background build. Idempotent; call at app launch
    /// (alongside `TimelineIndex.warmUp()`) and on search-surface appear.
    public func warmUp() {
        guard !isBuilt else { return }
        scheduleRebuild()
    }

    /// Rebuild if `vault/raw/` was modified externally (iCloud sync, another
    /// device) since the last build. One stat() when nothing changed.
    public func refreshIfExternallyModified() {
        let current = Self.rawDirMtime()
        if current != rawDirMtimeSnapshot {
            scheduleRebuild()
        }
    }

    // MARK: - Rebuild

    private func scheduleRebuild() {
        if let existing = rebuildTask, !existing.isCancelled { return }

        rebuildTask = Task { [weak self] in
            let scanned = await Task.detached(priority: .utility) {
                Self.scanAllDocuments()
            }.value
            let mtime = Self.rawDirMtime()
            guard let self else { return }
            self.docsByDate = scanned
            self.sortedSnapshot = nil
            self.rawDirMtimeSnapshot = mtime
            self.isBuilt = true
            self.rebuildTask = nil
        }
    }

    // MARK: - Incremental updates

    private func handleDidWrite(date: Date?) {
        guard isBuilt else { return }
        guard let date else {
            scheduleRebuild()
            return
        }
        let stem = Self.dateFormatter.string(from: date)
        if let doc = Self.scanDocument(dateString: stem) {
            docsByDate[stem] = doc
        } else {
            docsByDate.removeValue(forKey: stem)
        }
        sortedSnapshot = nil
        rawDirMtimeSnapshot = Self.rawDirMtime()
    }

    // MARK: - Scanning (nonisolated — runs on detached tasks)

    /// Full-vault scan → day documents. Same file discovery rules as the
    /// legacy `SearchService.search` (raw/*.md, valid yyyy-MM-dd stems only).
    nonisolated private static func scanAllDocuments() -> [String: DayDocument] {
        let fm = FileManager.default
        let rawDir = VaultInitializer.vaultURL.appendingPathComponent("raw")
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
                type: memo.type,
                body: memo.body,
                foldedBody: SearchService.foldForSearch(memo.body),
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
        dateFormatter.date(from: s) != nil
    }

    nonisolated private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func rawDirMtime() -> Date? {
        let rawDir = VaultInitializer.vaultURL.appendingPathComponent("raw")
        let attrs = try? FileManager.default.attributesOfItem(atPath: rawDir.path)
        return attrs?[.modificationDate] as? Date
    }

    // MARK: - Test support

    /// Test-only: synchronous full build so tests can assert deterministically.
    public func rebuildSynchronouslyForTesting() {
        docsByDate = Self.scanAllDocuments()
        sortedSnapshot = nil
        rawDirMtimeSnapshot = Self.rawDirMtime()
        isBuilt = true
    }

    /// Test-only: reset to the never-built state.
    public func resetForTesting() {
        rebuildTask?.cancel()
        rebuildTask = nil
        docsByDate = [:]
        sortedSnapshot = nil
        rawDirMtimeSnapshot = nil
        isBuilt = false
    }
}
