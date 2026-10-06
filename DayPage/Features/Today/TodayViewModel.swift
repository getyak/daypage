import Foundation
import SwiftUI
import UIKit
import CoreLocation
import Photos
import PhotosUI
import Combine
import DayPageModels
import DayPageStorage
import DayPageServices

// MARK: - Pending Attachment

// MARK: - FilePickerResult

struct FilePickerResult {
    let filePath: String   // relative path under vault
    let fileName: String
    let fileURL: URL

    init(filePath: String, fileName: String, vaultRoot: URL = VaultInitializer.vaultURL) {
        self.filePath = filePath
        self.fileName = fileName
        self.fileURL = vaultRoot.appendingPathComponent(filePath)
    }
}

/// Represents a staged attachment waiting to be included in the next submit.
enum PendingAttachment: Identifiable {
    case photo(PhotoPickerResult)
    case voice(VoiceRecordingResult)
    case file(FilePickerResult)

    var id: String {
        switch self {
        case .photo(let r): return "photo-\(r.filePath)"
        case .voice(let r): return "voice-\(r.filePath)"
        case .file(let r): return "file-\(r.filePath)"
        }
    }

    var fileURL: URL {
        switch self {
        case .photo(let result): return result.fileURL
        case .voice(let result): return result.fileURL
        case .file(let result): return result.fileURL
        }
    }

    var attachment: Memo.Attachment {
        switch self {
        case .photo(let r):
            var exifParts: [String] = []
            if let ap = r.exif?.aperture { exifParts.append("aperture=\(ap)") }
            if let ss = r.exif?.shutterSpeed { exifParts.append("shutter=\(ss)") }
            if let iso = r.exif?.iso { exifParts.append(iso) }
            if let fl = r.exif?.focalLength { exifParts.append(fl) }
            let exifSummary = exifParts.isEmpty ? nil : exifParts.joined(separator: " ")
            return Memo.Attachment(file: r.filePath, kind: "photo", duration: nil, transcript: exifSummary)
        case .voice(let r):
            // #821: a voice result without a transcript is PENDING, not
            // failed — stopAndSaveAudio() enqueues the transcription into
            // VoiceAttachmentQueue at save time, and the queue writes back
            // .done / .failed when it resolves. Marking it .failed here made
            // the on-disk state lie about an in-flight transcription.
            let txStatus: Memo.TranscriptionStatus? = r.transcript != nil ? .done : .pending
            return Memo.Attachment(file: r.filePath, kind: "audio", duration: r.duration, transcript: r.transcript, transcriptionStatus: txStatus)
        case .file(let r):
            return Memo.Attachment(file: r.filePath, kind: "file", duration: nil, transcript: r.fileName)
        }
    }
}

// MARK: - TodayFallback

typealias DailyPage = DailyPageModel
typealias WeekStats = [WeeklyRecapEntry]

/// Priority-ordered fallback content shown on Today when 0 memos exist.
/// Priority: yesterdayDailyPage > onThisDay > weekRecap > pureEmpty
enum TodayFallback {
    case yesterdayDailyPage(DailyPage)
    case onThisDay([Memo])
    case weekRecap(WeekStats)
    case pureEmpty
}

// MARK: - LoadState

/// Unified loading state for TodayView, replacing multiple independent boolean flags.
/// Drives skeleton vs. content rendering so all three async sources (vault, compiled
/// daily page, On This Day) present as a single coordinated load rather than popping
/// in separately.
enum LoadState: Equatable {
    case loading
    case ready
}

// MARK: - TodayViewModel

/// Manages state for TodayView: loading today's memos, tracking compiled state.
@MainActor
final class TodayViewModel: ObservableObject {

    // MARK: Published State

    /// Today's memos in reverse-chronological order (newest first).
    /// `didSet` refreshes the cached `todayWordCount` so the O(total-characters)
    /// CJK scan runs once per memo-list mutation instead of once per read.
    /// `todayWordCount` used to be a computed var read from TodayView's body via
    /// `.onChange`; because the main scroll re-evaluates the body every frame
    /// (ScrollOffsetPreferenceKey), that full scan ran on every scroll frame AND
    /// every keystroke — worst exactly when a heavy-writing user is most active.
    @Published var memos: [Memo] = [] {
        didSet { recomputeWordCount() }
    }

    /// Number of signals (memos) captured today — drives the Day Orb readout.
    var signalCount: Int { memos.count }

    /// Total word count across all of today's memo bodies. Cached; recomputed
    /// only when `memos` changes (see `memos.didSet` / `recomputeWordCount`).
    @Published private(set) var todayWordCount: Int = 0

    private func recomputeWordCount() {
        todayWordCount = memos.reduce(0) { $0 + TodayViewModel.wordCount(in: $1.body) }
    }

    /// CJK-aware word counter: each CJK ideograph = 1 word; runs of non-CJK
    /// non-whitespace characters = 1 word each.
    static func wordCount(in text: String) -> Int {
        var count = 0
        var inLatinRun = false
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let isCJK = (v >= 0x4E00 && v <= 0x9FFF)
                     || (v >= 0x3400 && v <= 0x4DBF)
                     || (v >= 0x20000 && v <= 0x2A6DF)
                     || (v >= 0xF900 && v <= 0xFAFF)
                     || (v >= 0x2E80 && v <= 0x2EFF)
                     || (v >= 0x3000 && v <= 0x303F)
            let isWhitespace = CharacterSet.whitespacesAndNewlines.contains(scalar)
            if isCJK {
                if inLatinRun { inLatinRun = false }
                count += 1
            } else if isWhitespace {
                inLatinRun = false
            } else {
                if !inLatinRun {
                    inLatinRun = true
                    count += 1
                }
            }
        }
        return count
    }

    /// Whether the Daily Page for today has been compiled.
    @Published var isDailyPageCompiled: Bool = false

    /// A brief excerpt from the compiled Daily Page (if compiled).
    @Published var dailyPageSummary: String? = nil

    /// Compiled day-pages from this week (Monday → yesterday), newest first.
    /// Populated in `load()` and refreshed whenever today's data reloads.
    /// Used only by the empty-today `fallbackContent` path now that the full
    /// historical timeline (`timelineSections`) renders beneath today's memos.
    @Published var weeklyRecap: [WeeklyRecapEntry] = []

    /// Full historical timeline grouped into bands (this-week-others, last
    /// week, week-before-last, then by month). Drives the scrollable history
    /// list under today's raw memos. Excludes today — today renders above.
    @Published var timelineSections: [TimelineSection] = []

    /// Distinguishes a genuinely empty history from the asynchronous index's
    /// first warm-up. Prevents empty-state/weekly-recap content from flashing
    /// briefly before an existing multi-year timeline arrives.
    @Published private(set) var isTimelineReady: Bool = false

    /// Unified load state — drives skeleton vs. content in TodayView.
    @Published var loadState: LoadState = .loading

    /// Error message to display if loading fails.
    @Published var errorMessage: String? = nil

    /// Whether a memo submission is in progress.
    @Published var isSubmitting: Bool = false

    /// Transient submit error shown as a toast/alert.
    @Published var submitError: String? = nil

    /// Body text of the most recently failed submission; non-nil until the view consumes it.
    @Published var lastFailedBody: String? = nil

    /// Durable records awaiting an explicit restore/save or confirmed discard.
    @Published private(set) var recoverableDrafts: [InflightDraftEntry] = []
    @Published private(set) var activeRecoveryDraft: InflightDraftEntry?
    private var recoveryVaultRoots = Set<URL>()
    private var submittedInflightURLs = Set<URL>()

    /// Whether location fetch is in progress.
    @Published var isLocating: Bool = false

    /// The pending location to attach to the next submitted memo.
    @Published var pendingLocation: Memo.Location? = nil

    /// Whether a photo picker selection is being processed.
    @Published var isProcessingPhoto: Bool = false

    /// Whether AI compilation is in progress.
    @Published var isCompiling: Bool = false

    // US-012: batch photo progress (0...1), only meaningful when isProcessingPhoto + batchTotal > 3
    @Published var batchPhotoProgress: Double = 0
    @Published var batchPhotoTotal: Int = 0

    /// Whether background (auto/backfill) compilation is in progress.
    @Published var isBackgroundCompiling: Bool = false

    /// Set when background compilation fails after all retries (triggers error banner).
    @Published var compilationFailedError: String? = nil

    /// Staged attachments (photo + voice) accumulated before the next submit.
    @Published var pendingAttachments: [PendingAttachment] = [] {
        didSet { autoSubmitPhotoImportID = nil }
    }

    /// Whether the voice recording sheet is presented.
    @Published var isShowingVoiceRecorder: Bool = false

    /// Whether the camera capture sheet is presented.
    @Published var isShowingCamera: Bool = false

    /// Whether the document picker sheet is presented.
    @Published var isShowingDocumentPicker: Bool = false

    /// On This Day entry to show at the top of Today (nil if dismissed or no history).
    @Published var onThisDayEntry: OnThisDayEntry? = nil

    /// Controls presentation of the Settings sheet from banner actions.
    @Published var shouldShowSettings: Bool = false

    /// Yesterday's compiled Daily Page model; nil if not yet compiled.
    @Published var yesterdayDailyPageModel: DailyPageModel? = nil

    /// Memos from the on-this-day historical date; empty if no entry or file missing.
    @Published var onThisDayMemos: [Memo] = []

    /// Fallback content for Today when no memos exist, selected by priority.
    var fallbackContent: TodayFallback {
        if let page = yesterdayDailyPageModel {
            return .yesterdayDailyPage(page)
        }
        if !onThisDayMemos.isEmpty {
            return .onThisDay(onThisDayMemos)
        }
        if !weeklyRecap.isEmpty {
            return .weekRecap(weeklyRecap)
        }
        return .pureEmpty
    }

    /// The most recently deleted memo; non-nil while the undo pill is visible.
    @Published var lastDeletedMemo: Memo? = nil

    /// Everything required to reverse the latest optimistic submission. Keep
    /// this private so the UI cannot accidentally remove a card without also
    /// restoring its staged location and attachments.
    private struct SubmissionUndoPayload {
        let memo: Memo
        let attachments: [PendingAttachment]
        let location: Memo.Location?
        let vaultRoot: URL
    }
    private var submissionUndoPayload: SubmissionUndoPayload?

    // MARK: Private

    private var date: Date

    /// Canonical owning raw day key of the file `memos` were loaded from,
    /// captured at load time. Detail routing and today's list mutations use
    /// THIS key so a preferred-time-zone change after load can never retarget
    /// the operation to a neighbouring day file. Refreshed (invalidated) by
    /// the next `load()`.
    private(set) var loadedDayString: String
    private let locationService = LocationService.shared
    private let weatherService = WeatherService.shared
    private let photoService = PhotoService.shared
    private let voiceService = VoiceService.shared
    private let compilationService = CompilationService.shared

    // MARK: Private Task Handles

    /// Cancellable handles for long-lived async operations; cancelled in deinit.
    private var loadTask: Task<Void, Never>?
    private var photoImportTasks: [UUID: Task<Void, Never>] = [:]
    private var photoImportGeneration = UUID()
    private var autoSubmitPhotoImportID: UUID?
    /// Chained owned-photo cleanups from explicit discard / chip-remove;
    /// awaited by `waitForPhotoCleanup` to keep regressions deterministic.
    private var photoCleanupTask: Task<Void, Never>?
    private var submitMemoTask: Task<Void, Never>?
    private var submissionUndoTask: Task<Void, Never>?
    private var locationTask: Task<Void, Never>?
    private var compilationTask: Task<Void, Never>?
    private var deleteUndoTask: Task<Void, Never>?
    private var memoPersistenceTask: Task<String?, Never>?
    private var memoMutationFeedbackTask: Task<Void, Never>?
    private var loadGeneration: UInt = 0
    @MainActor private final class DeletionContext {
        let vaultRoot: URL
        let dayString: String
        var deletedMemo: Memo?
        init(vaultRoot: URL, dayString: String) {
            self.vaultRoot = vaultRoot
            self.dayString = dayString
        }
    }
    private var deletionContext: DeletionContext?
    private var cancellables = Set<AnyCancellable>()

    // MARK: Init

    init(date: Date = Date(), observeChanges: Bool = true) {
        self.date = date
        self.loadedDayString = RawStorage.dayString(for: date)
        self.isTimelineReady = TimelineIndex.shared.isReady
        if observeChanges {
            observeCompilationFailure()
            observeOnThisDay()
            observeConflictResolution()
            observeRawStorageWrites()
            observeTimelineIndex()
        }
    }

    deinit {
        loadTask?.cancel()
        for task in photoImportTasks.values { task.cancel() }
        submitMemoTask?.cancel()
        submissionUndoTask?.cancel()
        locationTask?.cancel()
        compilationTask?.cancel()
        deleteUndoTask?.cancel()
    }

    private func observeCompilationFailure() {
        NotificationCenter.default
            .publisher(for: .compilationDidFail)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.compilationFailedError = NSLocalizedString("today.compile.background.failed", comment: "")
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .compilationDidStart)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.isBackgroundCompiling = true
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .compilationDidEnd)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.isBackgroundCompiling = false
            }
            .store(in: &cancellables)
    }

    private func observeOnThisDay() {
        NotificationCenter.default
            .publisher(for: .onThisDayShouldShow)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.onThisDayEntry = notification.object as? OnThisDayEntry
            }
            .store(in: &cancellables)
    }

    /// Reloads memos whenever iCloud conflict resolution rewrites today's raw file.
    /// Without this observer the UI shows stale in-memory memos after a merge.
    private func observeConflictResolution() {
        NotificationCenter.default
            .publisher(for: .vaultConflictResolved)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.load()
            }
            .store(in: &cancellables)
    }

    /// Detail mutations are record-oriented and intentionally independent of
    /// this list model. Re-read only when today's authoritative raw file was
    /// written so the feed converges after edit/delete without shared object
    /// ownership between a pushed destination and its source list.
    private func observeRawStorageWrites() {
        NotificationCenter.default
            .publisher(for: .rawStorageDidWrite)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self else { return }
                // Known keys refresh only their loaded day. Unknown events
                // conservatively refresh instead of guessing with device TZ.
                if let writtenDay = notification.userInfo?[RawStorage.writtenDayStringKey] as? String,
                   RawStorage.isValidDayString(writtenDay) {
                    guard writtenDay == self.loadedDayString else { return }
                }
                self.load()
            }
            .store(in: &cancellables)
    }

    /// Refreshes the displayed timeline sections whenever the index changes —
    /// after a background rebuild completes (cold launch) or any incremental
    /// write updates a day. Reads are O(1) from the in-memory index, so this is
    /// cheap to run on every update (issue #345).
    private func observeTimelineIndex() {
        NotificationCenter.default
            .publisher(for: .timelineIndexDidUpdate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.timelineSections = TimelineService.sections(referenceDate: self.date)
                self.isTimelineReady = TimelineIndex.shared.isReady
            }
            .store(in: &cancellables)
    }

    // MARK: - Delete / Pin Memo

    /// Changes only this record on disk. The list may be older than a
    /// background append, so it must never be used as a replacement day file.
    func deleteMemo(_ memo: Memo) {
        guard memos.contains(where: { $0.id == memo.id }) else { return }
        if submissionUndoPayload?.memo.id == memo.id {
            submissionUndoPayload = nil
        }
        let remaining = memos.filter { $0.id != memo.id }
        withAnimation(Motion.rise) {
            memos = remaining
        }
        Haptics.warn()
        let vaultRoot = VaultInitializer.vaultURL
        let owningDayString = loadedDayString
        let context = DeletionContext(vaultRoot: vaultRoot, dayString: owningDayString)
        deletionContext = context
        persistMemoChange(failureMessagePrefix: NSLocalizedString("error.memo.delete_failed", comment: "")) {
            let deleted = try await MemoRecordStore.shared.delete(
                id: memo.id,
                dayString: owningDayString,
                vaultRoot: vaultRoot
            )
            await MainActor.run { context.deletedMemo = deleted }
        }

        // Start 5-second undo window
        deleteUndoTask?.cancel()
        lastDeletedMemo = memo
        deleteUndoTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            lastDeletedMemo = nil
        }
    }

    /// Restores the last deleted memo to its original sort position and rewrites the file.
    func undoDelete() {
        guard let memo = lastDeletedMemo else { return }
        guard let context = deletionContext else { return }
        deletionContext = nil
        deleteUndoTask?.cancel()
        deleteUndoTask = nil
        lastDeletedMemo = nil

        withAnimation(Motion.rise) {
            if context.vaultRoot == VaultInitializer.vaultURL,
               context.dayString == loadedDayString,
               !memos.contains(where: { $0.id == memo.id }) {
                memos = Self.sortedMemos(memos + [context.deletedMemo ?? memo])
            }
        }
        Haptics.soft()
        let restoreDayString = context.dayString
        persistMemoChange(failureMessagePrefix: NSLocalizedString("error.memo.undo_failed", comment: "")) {
            guard let actual = await context.deletedMemo else { return }
            // Restore into the exact owning day file the delete targeted —
            // captured at delete time, never re-derived from `created`.
            try await MemoRecordStore.shared.restore(
                actual,
                dayString: restoreDayString,
                vaultRoot: context.vaultRoot
            )
        }
    }

    /// Replaces the body text of an existing memo and writes through to disk.
    func update(memo: Memo, body: String) {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let idx = memos.firstIndex(where: { $0.id == memo.id }) else { return }
        var updated = memos[idx]
        updated.body = body
        var newMemos = memos
        newMemos[idx] = updated
        withAnimation(Motion.rise) {
            memos = newMemos
        }
        Haptics.commit()
        let vaultRoot = VaultInitializer.vaultURL
        let owningDayString = loadedDayString
        persistMemoChange(failureMessagePrefix: NSLocalizedString("error.memo.save_failed", comment: "")) {
            _ = try await MemoRecordStore.shared.updateBody(
                id: memo.id,
                dayString: owningDayString,
                body: body,
                vaultRoot: vaultRoot
            )
        }
    }

    /// Pins a memo to the top of today's list without changing its original timestamp.
    /// Uses a separate `pinnedAt` field for sort order; `created` remains untouched.
    func pinMemo(_ memo: Memo) {
        guard let idx = memos.firstIndex(where: { $0.id == memo.id }) else { return }
        var pinned = memos[idx]
        pinned.pinnedAt = Date()
        var updated = memos
        updated.remove(at: idx)
        updated.insert(pinned, at: 0)
        // List reorder physically moves rows — wrap the same curve in
        // respectReduceMotion so Reduce-Motion users get an instant settle.
        withAnimation(Motion.respectReduceMotion(.easeInOut(duration: 0.25))) {
            memos = updated
        }
        let vaultRoot = VaultInitializer.vaultURL
        let pinnedAt = pinned.pinnedAt
        let owningDayString = loadedDayString
        persistMemoChange(failureMessagePrefix: NSLocalizedString("error.memo.pin_failed", comment: "")) {
            _ = try await MemoRecordStore.shared.setPinnedAt(
                id: memo.id,
                dayString: owningDayString,
                pinnedAt: pinnedAt,
                vaultRoot: vaultRoot
            )
        }
    }

    /// Unpins a memo, restoring it to its natural position based on original `created` time.
    func unpinMemo(_ memo: Memo) {
        guard let idx = memos.firstIndex(where: { $0.id == memo.id }) else { return }
        var unpinned = memos[idx]
        unpinned.pinnedAt = nil
        var updated = memos
        updated.remove(at: idx)
        updated.append(unpinned)
        // List reorder physically moves rows — wrap the same curve in
        // respectReduceMotion so Reduce-Motion users get an instant settle.
        withAnimation(Motion.respectReduceMotion(.easeInOut(duration: 0.25))) {
            memos = Self.sortedMemos(updated)
        }
        let vaultRoot = VaultInitializer.vaultURL
        let owningDayString = loadedDayString
        persistMemoChange(failureMessagePrefix: NSLocalizedString("error.memo.unpin_failed", comment: "")) {
            _ = try await MemoRecordStore.shared.setPinnedAt(
                id: memo.id,
                dayString: owningDayString,
                pinnedAt: nil,
                vaultRoot: vaultRoot
            )
        }
    }

    /// Tasks are explicitly chained: actor isolation alone doesn't promise
    /// FIFO execution. Accepted writes survive view dismissal and retain the
    /// vault captured by their caller.
    func enqueueMemoPersistence(_ operation: @escaping @Sendable () async throws -> Void) -> Task<String?, Never> {
        loadGeneration &+= 1
        let generation = loadGeneration
        loadTask?.cancel()
        let previous = memoPersistenceTask
        let task = Task.detached(priority: .userInitiated) { [weak self] () -> String? in
            _ = await previous?.value
            let failure: String?
            do { try await operation(); failure = nil }
            catch { failure = error.localizedDescription }
            await self?.reloadAfterPersistence(generation: generation)
            return failure
        }
        memoPersistenceTask = task
        return task
    }

    private func reloadAfterPersistence(generation: UInt) {
        // Successful no-ops do not post a storage notification. They still
        // need to finish a load invalidated by this operation.
        guard loadGeneration == generation else { return }
        load()
    }

    private func persistMemoChange(
        failureMessagePrefix: String,
        operation: @escaping @Sendable () async throws -> Void
    ) {
        let persistence = enqueueMemoPersistence(operation)
        let previousFeedback = memoMutationFeedbackTask
        memoMutationFeedbackTask = Task { @MainActor [weak self] in
            await previousFeedback?.value
            guard let failure = await persistence.value, let self else { return }
            self.submitError = String(format: failureMessagePrefix, failure)
            // Reload the authoritative state after ALL queued writes; never
            // roll the whole list back over a newer edit or submission.
            self.load()
        }
    }

    func waitForMemoPersistence() async {
        _ = await memoPersistenceTask?.value
        await memoMutationFeedbackTask?.value
        await loadTask?.value
    }

    private static func sortedMemos(_ memos: [Memo]) -> [Memo] {
        memos.sorted { lhs, rhs in
            if lhs.pinnedAt != nil && rhs.pinnedAt == nil { return true }
            if lhs.pinnedAt == nil && rhs.pinnedAt != nil { return false }
            if let lp = lhs.pinnedAt, let rp = rhs.pinnedAt, lp != rp { return lp > rp }
            return lhs.created > rhs.created
        }
    }

    // MARK: - Load Memos

    /// Lists every durable record without handing it to an occupied composer.
    /// Only a matching memo already on disk acknowledges an interrupted save.
    func recoverInflightDrafts() {
        recoveryVaultRoots.insert(VaultInitializer.vaultURL)
        recoverableDrafts = recoveryVaultRoots.flatMap { root in
            InflightDraftStore.pendingEntries(vaultRoot: root)
        }.filter { entry in
            guard !submittedInflightURLs.contains(entry.url) else { return false }
            if (try? InflightDraftStore.isCommitted(entry)) == true {
                InflightDraftStore.acknowledge(entry)
                return false
            }
            return true
        }.sorted { $0.draft.enqueuedAt > $1.draft.enqueuedAt }
    }

    /// Returns a body only when the complete composer is free. The record is
    /// retained while editing; taking it from the queue is not an acknowledgement.
    func restoreNextInflightDraft(composerBody: String) -> String? {
        guard !isProcessingPhoto, composerBody.isEmpty, pendingAttachments.isEmpty,
              pendingLocation == nil, activeRecoveryDraft == nil else { return nil }
        // A damaged or conflicting entry stays durable without starving the
        // other drafts. If none can be restored, the last error stays visible.
        for entry in recoverableDrafts {
            if let body = stageRecovery(entry, composerBody: entry.draft.body) { return body }
        }
        return nil
    }

    /// The view persists this exact URL alongside its scene-specific draft
    /// backup, so a restart can reconnect edited text to the same durable ID.
    func resumeInflightDraft(at url: URL, composerBody: String) -> String? {
        guard !isProcessingPhoto, activeRecoveryDraft == nil, pendingAttachments.isEmpty,
              let entry = recoverableDrafts.first(where: { $0.url == url }) else { return nil }
        return stageRecovery(entry, composerBody: composerBody.isEmpty ? entry.draft.body : composerBody)
    }

    private func stageRecovery(_ entry: InflightDraftEntry, composerBody: String) -> String? {
        do {
            try InflightDraftStore.validateForRestoration(entry)
            let attachments = try entry.draft.attachmentPaths.map { path -> PendingAttachment in
                guard let relative = MemoPresentationSafety.relativeAttachmentPath(path),
                      relative.hasPrefix("raw/assets/") else {
                    throw InflightDraftRecoveryError.invalidAttachment
                }
                let fileURL = entry.vaultRoot.appendingPathComponent(relative)
                let assetRoot = entry.vaultRoot.appendingPathComponent("raw/assets", isDirectory: true)
                    .resolvingSymlinksInPath().standardizedFileURL.path + "/"
                guard fileURL.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(assetRoot) else {
                    throw InflightDraftRecoveryError.invalidAttachment
                }
                switch fileURL.pathExtension.lowercased() {
                case "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff":
                    return .photo(PhotoPickerResult(filePath: relative, fileURL: fileURL, exif: nil, thumbnail: nil))
                case "m4a", "wav", "mp3", "aac", "caf", "aiff", "ogg":
                    return .voice(VoiceRecordingResult(filePath: relative, fileURL: fileURL, duration: 0, transcript: nil))
                default:
                    return .file(FilePickerResult(filePath: relative, fileName: fileURL.lastPathComponent, vaultRoot: entry.vaultRoot))
                }
            }
            activeRecoveryDraft = entry
            pendingAttachments = attachments
            lastFailedBody = nil
            // Restoring another draft replaces the composer content: results
            // bound to the replaced draft must not land in the restored one.
            rotateComposerGenerations()
            return composerBody
        } catch {
            submitError = error.localizedDescription
            return nil
        }
    }

    /// Called only by the WriteSheet's existing confirmed-discard action.
    func discardActiveInflightDraft() {
        // Explicit discard destroys the draft: retire the composer
        // generations so late press-to-talk results cannot write the next one.
        rotateComposerGenerations()
        guard let entry = activeRecoveryDraft else { return }
        InflightDraftStore.acknowledge(entry)
        activeRecoveryDraft = nil
        lastFailedBody = nil
        recoverInflightDrafts()
    }

    // MARK: - Cold-start draft reconciliation

    /// Keep the shipping body key; additive metadata belongs to the same scene.
    static func draftBackupKey(forSceneID sceneID: String) -> String {
        "today.draftText.backup.\(sceneID)"
    }

    static func draftDateBackupKey(forSceneID sceneID: String) -> String {
        "\(draftBackupKey(forSceneID: sceneID)).modifiedAt"
    }

    private(set) var hasReconciledInitialDraft = false

    /// The mirror wins over a stale SceneStorage snapshot on first appearance.
    /// Later appearances must leave live typing untouched. Global legacy dates
    /// cannot prove the age of any one window's draft: preserve unknown ages.
    func reconcileInitialDraft(
        sceneID: String,
        sceneText: String,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) -> String? {
        guard !hasReconciledInitialDraft else { return nil }
        hasReconciledInitialDraft = true
        let mirrorKey = Self.draftBackupKey(forSceneID: sceneID)
        let dateKey = Self.draftDateBackupKey(forSceneID: sceneID)
        let recovered: String
        if let mirror = defaults.string(forKey: mirrorKey), !mirror.isEmpty {
            let savedAt = defaults.double(forKey: dateKey)
            if savedAt > 0, now.timeIntervalSince1970 - savedAt > 30 * 24 * 3600 {
                defaults.removeObject(forKey: mirrorKey)
                defaults.removeObject(forKey: dateKey)
                recovered = ""
            } else {
                recovered = mirror
            }
        } else {
            // Send/discard clear the mirror synchronously. Do not resurrect
            // their older SceneStorage snapshot or retain orphaned metadata.
            defaults.removeObject(forKey: dateKey)
            guard !sceneText.isEmpty else { return nil }
            recovered = ""
        }
        if recovered != sceneText { rotateComposerGenerations() }
        return recovered
    }

    /// Loads today's memos from the raw storage file and checks compiled status.
    /// Signature is intentionally synchronous so call sites (TodayView.onAppear) need
    /// no changes. Disk I/O is offloaded to a background task to avoid blocking the
    /// main thread on cold launch.
    func load() {
        // Refresh to today in case the app has been backgrounded overnight.
        date = Date()
        loadState = .loading
        errorMessage = nil

        // Capture value types before leaving the MainActor.
        let capturedDate = date
        // The canonical raw day key actually being loaded. Everything that
        // later mutates these memos targets THIS key, never a day re-derived
        // from `memo.created` under a possibly-changed preferred zone.
        let capturedDayString = RawStorage.dayString(for: capturedDate)
        let capturedVaultRoot = VaultInitializer.vaultURL
        let dailyURL = dailyPageURL(for: capturedDate)
        // Capture the on-this-day file path before going off-actor.
        let capturedOTDFilePath: String? = onThisDayEntry?.filePath

        loadTask?.cancel()
        loadGeneration &+= 1
        let generation = loadGeneration
        let pendingPersistence = memoPersistenceTask
        loadTask = Task.detached(priority: .userInitiated) {
            _ = await pendingPersistence?.value
            guard !Task.isCancelled else { return }
            // --- Off-main disk I/O ---
            let loadResult = Result {
                try RawStorage.read(dayString: capturedDayString, vaultRoot: capturedVaultRoot)
            }

            let dailyExists = FileManager.default.fileExists(atPath: dailyURL.path)
            let dailySummary: String? = {
                guard dailyExists,
                      let content = try? String(contentsOf: dailyURL, encoding: .utf8) else {
                    return nil
                }
                return FrontmatterParser.extractField("summary", from: content)
            }()

            // Load yesterday's compiled daily page for fallback
            let yesterdayDate = Calendar.current.date(byAdding: .day, value: -1, to: capturedDate) ?? capturedDate
            let yesterdayDailyURL: URL = {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = AppSettings.currentTimeZone()
                let s = f.string(from: yesterdayDate)
                return capturedVaultRoot
                    .appendingPathComponent("wiki/daily/\(s).md")
            }()
            let yesterdayDateString: String = {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = AppSettings.currentTimeZone()
                return f.string(from: yesterdayDate)
            }()
            let yesterdayPage: DailyPageModel? = {
                guard FileManager.default.fileExists(atPath: yesterdayDailyURL.path),
                      let content = try? String(contentsOf: yesterdayDailyURL, encoding: .utf8) else {
                    return nil
                }
                return DailyPageParser.parse(content: content, dateString: yesterdayDateString)
            }()

            // Load on-this-day memos for fallback using the file path captured before going off-actor.
            let otdMemos: [Memo] = {
                guard let filePath = capturedOTDFilePath else { return [] }
                let rawURL = capturedVaultRoot.appendingPathComponent(filePath)
                guard let content = try? String(contentsOf: rawURL, encoding: .utf8) else { return [] }
                return RawStorage.parse(fileContent: content)
            }()

            // Weekly recap is also disk-backed. It previously ran from the
            // MainActor commit block below, synchronously reading up to a week
            // of compiled Markdown immediately before Today became interactive.
            let weeklyRecap = WeeklyRecapService.scanEntries(referenceDate: capturedDate, vaultRoot: capturedVaultRoot)

            // --- Back on MainActor: update published state ---
            await MainActor.run {
                guard self.loadGeneration == generation,
                      capturedVaultRoot == VaultInitializer.vaultURL else { return }
                self.loadedDayString = capturedDayString
                switch loadResult {
                case .success(let loaded):
                    // Newest first; pinned memos float to the top
                    self.memos = Self.sortedMemos(loaded)
                    self.errorMessage = nil
                case .failure(let error):
                    self.errorMessage = String(format: NSLocalizedString("error.memo.load_failed", comment: ""), error.localizedDescription)
                    self.memos = []
                }

                self.isDailyPageCompiled = dailyExists
                self.dailyPageSummary = dailyExists ? dailySummary : nil
                self.weeklyRecap = weeklyRecap
                // O(1) read from TimelineIndex (cached); the expensive scan now
                // happens only on index rebuild, off this hot path.
                self.timelineSections = TimelineService.sections(referenceDate: capturedDate)
                self.isTimelineReady = TimelineIndex.shared.isReady
                self.yesterdayDailyPageModel = yesterdayPage
                self.onThisDayMemos = otdMemos
                self.loadState = .ready
                self.checkOnThisDay()

                // Issue #814: the auto-compile-on-load path was removed. It
                // compiled a half-day snapshot on every first open (a full
                // 8-10K-token LLM call) that went stale as soon as the next
                // memo landed. Today is now a pure raw-capture surface; the
                // day compiles ONCE after it ends — midnight BGTask compiles
                // yesterday, with foreground-retry + backfill as fallbacks.
                // Manual compile stays available for users who want today's
                // draft diary early.
            }
        }
    }

    // MARK: - Pull-to-Refresh

    /// Called by SwiftUI's .refreshable modifier. Fires a haptic, kicks off
    /// load(), then suspends until the detached disk-load Task completes so
    /// the system spinner stays visible for the actual I/O duration.
    func refresh() async {
        Haptics.soft()
        load()
        await loadTask?.value
    }

    // MARK: - On This Day

    private func checkOnThisDay() {
        let today = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
        let dismissed = UserDefaults.standard.string(forKey: AppSettings.Keys.onThisDayDismissed)
        guard dismissed != today else { return }
        onThisDayEntry = OnThisDayIndex.shared.candidate(for: Date())
    }

    // MARK: - Add Photo Attachment (staged, not yet submitted)

    /// Processes a selected PhotosPickerItem and stages it in pendingAttachments.
    /// Does NOT submit a memo — user must tap the submit button.
    func addPhotoAttachment(item: PhotosPickerItem) {
        stagePhotoAttachments { [photoService] in
            guard let result = await photoService.processPickerItem(item) else { return [] }
            return [result]
        }
    }

    /// Own each import until it completes. Cancellation alone cannot discard a
    /// result from Photos/iCloud or detached image processing, so a generation
    /// also binds the result to the draft that requested it.
    @discardableResult
    func stagePhotoAttachments(
        autoSubmit: Bool = false,
        processing: @escaping @MainActor () async -> [PhotoPickerResult]
    ) -> Task<Void, Never> {
        let operationID = UUID()
        let generation = photoImportGeneration
        // Automatic camera/batch save is only for an exclusive, empty draft.
        // Starting any other import revokes that shortcut, in either finish order.
        autoSubmitPhotoImportID = autoSubmit && photoImportTasks.isEmpty && pendingAttachments.isEmpty
            ? operationID : nil
        isProcessingPhoto = true
        submitError = nil
        let task = Task { @MainActor [weak self] in
            let results = await processing()
            guard let self,
                  self.photoImportGeneration == generation,
                  self.photoImportTasks[operationID] != nil else {
                // The import's draft was destroyed or replaced before its
                // results arrived. They never stage: clean exactly the owned
                // runtime files behind them and leave every unowned file
                // (rejected/restored/unknown/committed) untouched.
                await PhotoService.shared.discardOwnedDraftPhotos(results)
                return
            }
            self.photoImportTasks.removeValue(forKey: operationID)
            self.isProcessingPhoto = !self.photoImportTasks.isEmpty
            guard !Task.isCancelled else {
                await self.photoService.discardOwnedDraftPhotos(results)
                return
            }
            guard !results.isEmpty else {
                self.submitError = NSLocalizedString("error.memo.photo_failed", comment: "")
                return
            }
            let mayAutoSubmit = self.autoSubmitPhotoImportID == operationID
                && self.pendingAttachments.isEmpty
            self.pendingAttachments.append(contentsOf: results.map(PendingAttachment.photo))
            // Retire our own loading state before auto-submit. If another
            // import is still running, leave all results for explicit review.
            if mayAutoSubmit && !self.isProcessingPhoto {
                self.submitCombinedMemo(body: "")
            }
        }
        // This MainActor task cannot run until the synchronous registration ends.
        photoImportTasks[operationID] = task
        return task
    }

    /// Removes a staged attachment by id. Removing a chip is an explicit
    /// discard of that one attachment: its owned runtime draft photo is
    /// deleted with it, while anything unowned (rejected/restored/unknown/
    /// committed, audio, files) stays on disk.
    func removePendingAttachment(id: String) {
        let removed = pendingAttachments.filter { $0.id == id }
        pendingAttachments.removeAll { $0.id == id }
        discardOwnedStagedPhotos(removed)
    }

    /// Drops every staged attachment — the WriteSheet's confirmed-discard
    /// path — and cleans up the owned runtime draft photos it destroyed.
    func clearPendingAttachments() {
        // The confirmed-discard path empties the composer's staged content:
        // retire in-flight press-to-talk results bound to the discarded draft.
        rotateComposerGenerations()
        let tasks = Array(photoImportTasks.values)
        photoImportGeneration = UUID()
        autoSubmitPhotoImportID = nil
        photoImportTasks.removeAll()
        isProcessingPhoto = false
        batchPhotoTotal = 0
        batchPhotoProgress = 0
        for task in tasks { task.cancel() }
        let discarded = pendingAttachments
        pendingAttachments.removeAll()
        // Explicit discard is a cleanup boundary: the owned runtime draft
        // photos staged for this draft are deleted now (the startup orphan
        // sweep stays only as a crash backstop). The owned-only gate preserves
        // rejected/restored/unknown/committed files and inflight/retry/undo/
        // recovery files, and never touches audio or file attachments.
        discardOwnedStagedPhotos(discarded)
    }

    /// Queues deletion of the owned runtime draft photos behind exactly these
    /// staged attachments through PhotoService's owned-only cleanup. Capture
    /// happens at import, so a swapped vault locator or relative path can
    /// never retarget the delete; everything unowned is preserved. Cleanup
    /// runs off the main actor and is chained so `waitForPhotoCleanup` is
    /// deterministic.
    private func discardOwnedStagedPhotos(_ attachments: [PendingAttachment]) {
        let photos = attachments.compactMap { attachment -> PhotoPickerResult? in
            if case .photo(let result) = attachment { return result }
            return nil
        }
        guard !photos.isEmpty else { return }
        let previous = photoCleanupTask
        photoCleanupTask = Task { @MainActor [photoService] in
            await previous?.value
            await photoService.discardOwnedDraftPhotos(photos)
        }
    }

    /// Await every queued owned-draft-photo cleanup. Primarily useful to make
    /// photo-discard regressions deterministic; normal UI stays fire-and-forget.
    func waitForPhotoCleanup() async {
        await photoCleanupTask?.value
    }

    // MARK: - Add Voice Attachment (staged)

    /// Stages a completed voice recording result into pendingAttachments and resets the recorder.
    func addVoiceAttachment(result: VoiceRecordingResult) {
        pendingAttachments.append(.voice(result))
        voiceService.reset()
    }

    /// Stages a voice recording and immediately submits it as a standalone memo.
    func addVoiceAndSubmit(result: VoiceRecordingResult) {
        pendingAttachments.append(.voice(result))
        voiceService.reset()
        submitCombinedMemo(body: "")
    }

    // MARK: - Composer Generation (late press-to-talk results)

    /// A composer surface. The dock (InputBarV4) and the WriteSheet bind the
    /// same `draftText`, but each surface owns an independent generation
    /// token so one surface's callback snapshot is never confused with the
    /// other's.
    enum ComposerSurface: CaseIterable {
        case dock
        case writeSheet
    }

    /// Snapshot captured when the View creates a surface's press-to-talk
    /// callbacks. `id` names the draft generation that was live at capture
    /// time. A result that arrives later is dropped once its generation has
    /// been retired (confirmed discard, clearPendingAttachments, successful
    /// submit, draft restore/replacement). Typing and soft dismissal never
    /// retire a generation, so the original draft's own results still land.
    struct ComposerToken: Equatable {
        let surface: ComposerSurface
        let id: UUID
    }

    /// Live generation per composer surface. Rotated only at the explicit
    /// draft destroy/replace boundaries listed on `rotateComposerGenerations`.
    /// Both surfaces share one draft, so every boundary retires both.
    private var composerGenerations: [ComposerSurface: UUID] =
        Dictionary(uniqueKeysWithValues: ComposerSurface.allCases.map { ($0, UUID()) })

    /// Snapshot token for `surface`, taken when its InputBarV4/WriteSheet
    /// callbacks are created.
    func composerToken(for surface: ComposerSurface) -> ComposerToken {
        ComposerToken(surface: surface, id: composerGenerations[surface] ?? UUID())
    }

    /// Whether `token` still names the live generation of its surface. The
    /// press-to-talk callbacks check this on arrival before touching the
    /// draft text or the staging area.
    func isComposerTokenCurrent(_ token: ComposerToken) -> Bool {
        composerGenerations[token.surface] == token.id
    }

    /// The draft body after a press-to-talk transcribe result lands, or nil
    /// when the callback is stale and the draft must stay untouched. A stale
    /// transcript is dropped silently — nothing is re-transcribed, deleted,
    /// or sent anywhere.
    func draftByAppendingTranscript(_ transcript: String, to draft: String, token: ComposerToken) -> String? {
        guard isComposerTokenCurrent(token), !transcript.isEmpty else { return nil }
        if draft.isEmpty { return transcript }
        return draft + (draft.hasSuffix(" ") ? "" : " ") + transcript
    }

    /// Stages a press-to-talk send result for its still-live draft. A stale
    /// result is dropped WITHOUT resetting or cancelling the shared
    /// VoiceService (a newer recording may own it) and without touching the
    /// already-saved audio file.
    @discardableResult
    func stageVoiceResult(_ result: VoiceRecordingResult, token: ComposerToken) -> Bool {
        guard isComposerTokenCurrent(token) else { return false }
        addVoiceAttachment(result: result)
        return true
    }

    /// Retires both composer generations, invalidating every press-to-talk
    /// callback snapshot taken so far. Call ONLY from explicit boundaries
    /// that destroy or replace the draft: confirmed Discard,
    /// clearPendingAttachments, a successful submitCombinedMemo, draft
    /// restoration, and view-side explicit draft replacement. Never call for
    /// typing, soft close/swipe/Keep, or a failed submit — those keep the
    /// draft alive along with its legitimate in-flight results.
    func rotateComposerGenerations() {
        for surface in ComposerSurface.allCases {
            composerGenerations[surface] = UUID()
        }
    }

    // MARK: - Retranscribe (US-014 / US-016)

    /// Re-runs transcription for a failed voice attachment and updates the memo on disk.
    func retranscribe(memo: Memo, attachment: Memo.Attachment) {
        let vaultRoot = VaultInitializer.vaultURL
        let audioURL = vaultRoot.appendingPathComponent(attachment.file)
        Task { @MainActor in
            guard let transcript = await voiceService.transcribeAudio(at: audioURL),
                  !transcript.isEmpty else { return }
            updateTranscript(transcript, memo: memo, attachmentFile: attachment.file, vaultRoot: vaultRoot)
        }
    }

    func updateTranscript(_ transcript: String, memo: Memo, attachmentFile: String, vaultRoot: URL) {
        guard !transcript.isEmpty else { return }
        if vaultRoot == VaultInitializer.vaultURL,
           let memoIndex = memos.firstIndex(where: { $0.id == memo.id }),
           let attachmentIndex = memos[memoIndex].attachments.firstIndex(where: { $0.file == attachmentFile }) {
            withAnimation(Motion.fade) {
                memos[memoIndex].attachments[attachmentIndex].transcript = transcript
                memos[memoIndex].attachments[attachmentIndex].transcriptionStatus = .done
            }
        }
        persistMemoChange(failureMessagePrefix: NSLocalizedString("error.memo.retranscribe_failed", comment: "")) {
            try RawStorage.mutate(for: memo.created, vaultRoot: vaultRoot) { current in
                guard let memoIndex = current.firstIndex(where: { $0.id == memo.id }),
                      let attachmentIndex = current[memoIndex].attachments.firstIndex(where: { $0.file == attachmentFile }) else { return nil }
                var updated = current
                updated[memoIndex].attachments[attachmentIndex].transcript = transcript
                updated[memoIndex].attachments[attachmentIndex].transcriptionStatus = .done
                return updated
            }
        }
    }

    /// Opens the voice recording sheet.
    func startVoiceRecording() {
        isShowingVoiceRecorder = true
    }

    /// Opens the camera capture sheet.
    func startCameraCapture() {
        isShowingCamera = true
    }


    /// Opens the document picker sheet.
    func startFilePicker() {
        isShowingDocumentPicker = true
    }

    /// Copies a picked file into vault/raw/assets/files/ and stages it as a pending attachment.
    func addFileAttachment(url: URL) {
        isShowingDocumentPicker = false
        let vaultRoot = VaultInitializer.vaultURL
        let filesDir = vaultRoot
            .appendingPathComponent("raw/assets/files", isDirectory: true)
        let fm = FileManager.default
        do { try fm.createDirectory(at: filesDir, withIntermediateDirectories: true) }
        catch { DayPageLogger.shared.error("addFileAttachment: createDirectory: \(error)") }

        let fileName = url.lastPathComponent
        let destURL = filesDir.appendingPathComponent(fileName)
        // If a file with the same name exists, append a timestamp suffix
        let finalURL: URL
        if fm.fileExists(atPath: destURL.path) {
            let ts = Int(Date().timeIntervalSince1970)
            let ext = url.pathExtension
            let base = url.deletingPathExtension().lastPathComponent
            let newName = ext.isEmpty ? "\(base)_\(ts)" : "\(base)_\(ts).\(ext)"
            finalURL = filesDir.appendingPathComponent(newName)
        } else {
            finalURL = destURL
        }

        do {
            try fm.copyItem(at: url, to: finalURL)
        } catch {
            submitError = String(format: NSLocalizedString("error.memo.file_copy_failed", comment: ""), error.localizedDescription)
            return
        }

        let relativePath = "raw/assets/files/\(finalURL.lastPathComponent)"
        let result = FilePickerResult(filePath: relativePath, fileName: finalURL.lastPathComponent, vaultRoot: vaultRoot)
        pendingAttachments.append(.file(result))
    }

    /// Processes a camera-captured UIImage and immediately submits it as a standalone memo.
    func addCameraPhotoAndSubmit(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        stagePhotoAttachments(autoSubmit: true) { [photoService] in
            guard let result = await photoService.processImageDataAsync(data) else { return [] }
            return [result]
        }
    }

    /// Processes multiple PhotosPickerItems and immediately submits them as one memo.
    func addPhotosAndSubmit(items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        // US-012: expose batch progress when > 3 photos
        batchPhotoTotal = items.count
        batchPhotoProgress = 0
        let generation = photoImportGeneration
        stagePhotoAttachments(autoSubmit: true) { [weak self, photoService] in
            defer {
                if self?.photoImportGeneration == generation {
                    self?.batchPhotoTotal = 0
                    self?.batchPhotoProgress = 0
                }
            }
            var results: [PhotoPickerResult] = []
            for (idx, item) in items.enumerated() {
                let result = await photoService.processPickerItem(item)
                if let result { results.append(result) }
                guard !Task.isCancelled, self?.photoImportGeneration == generation else {
                    // Dropped late/cancelled batch results — including the one
                    // just created — clean through the owned-only API instead
                    // of leaking onto disk.
                    await photoService.discardOwnedDraftPhotos(results)
                    return []
                }
                if items.count > 3 {
                    self?.batchPhotoProgress = Double(idx + 1) / Double(items.count)
                }
            }
            return results
        }
    }

    /// Dismisses the voice recording sheet without saving.
    func cancelVoiceRecording() {
        voiceService.cancelRecording()
        isShowingVoiceRecorder = false
    }

    // MARK: - Submit Combined Memo

    /// Submits a memo combining the draft text with all staged pendingAttachments.
    /// Determines type automatically: text | voice | photo | mixed.
    ///
    /// **落盘先于加载 (persist-then-enrich).** The memo is built from data we
    /// already hold — body, attachments, EXIF timestamp/GPS, device — with **no
    /// awaits**, then committed in three synchronous steps the user feels this
    /// frame: it flies into the list, the composer clears, and a haptic fires.
    /// Only after the card is on screen do we (a) durably append it to disk and
    /// (b) chase the two slow, optional signals — GPS + weather — which are
    /// patched in afterward by `enrichMetadata`. The old flow awaited a 3-second
    /// location lookup + a weather network call *before* the card ever appeared,
    /// so a send read as a multi-second stall for metadata the Today card does
    /// not even render.
    @discardableResult
    func submitCombinedMemo(body: String) -> Bool {
        // Do not commit a partial attachment snapshot or let a late photo land
        // in the next draft. All callers, including voice/camera, share this gate.
        guard !isProcessingPhoto else { return false }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = !trimmed.isEmpty
        let snapshotAttachments = pendingAttachments
        guard hasText || !snapshotAttachments.isEmpty else { return false }

        // B4: re-entrancy guard. The commit below is fully synchronous on the
        // MainActor, so this only ever trips on a genuine second invocation
        // (e.g. a photo-batch auto-submit racing a manual send) — and by then
        // the composer state is already cleared, so no memo can be duplicated.
        guard !isSubmitting else { return false }
        let currentVaultRoot = VaultInitializer.vaultURL
        let recoveryEntry = activeRecoveryDraft
        if let recoveryEntry,
           recoveryEntry.vaultRoot.standardizedFileURL.resolvingSymlinksInPath()
               != currentVaultRoot.standardizedFileURL.resolvingSymlinksInPath() {
            // Newly staged assets follow the current locator. Do not commit a
            // recovered memo into its captured vault with another vault's paths.
            submitError = InflightDraftRecoveryError.vaultChanged.localizedDescription
            return false
        }
        let submissionVaultRoot = recoveryEntry?.vaultRoot ?? currentVaultRoot
        if snapshotAttachments.contains(where: { staged in
            staged.fileURL.standardizedFileURL.resolvingSymlinksInPath()
                != submissionVaultRoot.appendingPathComponent(staged.attachment.file)
                    .standardizedFileURL.resolvingSymlinksInPath()
        }) {
            // Switching back does not move assets staged while another vault
            // was active. Keep their absolute origin until explicitly removed.
            submitError = InflightDraftRecoveryError.vaultChanged.localizedDescription
            return false
        }
        isSubmitting = true
        submitError = nil

        let userSetLocation = pendingLocation
        // Capture the authoritative Vault for the whole submission. The
        // locator can legitimately hot-swap from local to iCloud while the
        // detached append is running; one memo must never straddle roots.
        // --- Build the memo synchronously, from data already in hand ---

        // created: photo-only memos inherit the shot's EXIF capture time.
        var created = recoveryEntry?.draft.enqueuedAt ?? Date()
        if !hasText, case .photo(let r) = snapshotAttachments.first,
           let exifDate = r.exif?.capturedAt {
            created = exifDate
        }

        // location: prefer the user's explicit pin, else a photo's EXIF GPS.
        // If neither is present the field stays nil and `enrichMetadata` fills
        // it in from a live GPS fix after the card is already on screen.
        var initialLocation: Memo.Location? = userSetLocation
        if initialLocation == nil {
            for att in snapshotAttachments {
                if case .photo(let r) = att,
                   let lat = r.exif?.gpsLat,
                   let lng = r.exif?.gpsLng {
                    initialLocation = Memo.Location(name: nil, lat: lat, lng: lng)
                    break
                }
            }
        }

        let recoveredPaths = Set(recoveryEntry?.draft.attachmentPaths ?? [])
        let memoAttachments = snapshotAttachments.map { staged -> Memo.Attachment in
            let attachment = staged.attachment
            // The legacy journal stores paths only. Preserve the audio kind,
            // but do not invent a duration or claim an ASR job is in flight.
            if recoveredPaths.contains(attachment.file), attachment.kind == "audio" {
                return Memo.Attachment(file: attachment.file, kind: "audio")
            }
            return attachment
        }

        // Determine type
        let hasPhotos = snapshotAttachments.contains { if case .photo = $0 { return true }; return false }
        let hasVoice  = snapshotAttachments.contains { if case .voice = $0 { return true }; return false }
        let hasFiles  = snapshotAttachments.contains { if case .file = $0 { return true }; return false }
        let memoType: Memo.MemoType
        let typeCount = (hasText ? 1 : 0) + (hasPhotos ? 1 : 0) + (hasVoice ? 1 : 0) + (hasFiles ? 1 : 0)
        if typeCount > 1 {
            memoType = .mixed
        } else if hasPhotos {
            memoType = .photo
        } else if hasVoice {
            memoType = .voice
        } else if hasFiles {
            memoType = .mixed
        } else {
            memoType = .text
        }

        // Body is always the user-typed text (trimmed). For voice-only memos this
        // is empty — the transcript lives exclusively in attachment.transcript and
        // is rendered by VoiceMemoPlayerRow, preventing duplicate display.
        let memo = Memo(
            id: recoveryEntry?.draft.id ?? UUID(),
            type: memoType,
            created: created,
            location: initialLocation,
            weather: nil,               // enriched after the card lands (see enrichMetadata)
            device: deviceDescription(),
            attachments: memoAttachments,
            body: trimmed
        )

        // Journal the complete retry payload before accepting the submit. A
        // retry updates its existing record instead of leaving a second copy.
        let inflightEntry: InflightDraftEntry
        do {
            inflightEntry = try InflightDraftStore.persist(
                InflightDraft(id: memo.id, body: trimmed, enqueuedAt: memo.created,
                              attachmentPaths: memoAttachments.map(\.file)),
                vaultRoot: submissionVaultRoot
            )
        } catch {
            isSubmitting = false
            submitError = String(format: NSLocalizedString("error.memo.save_failed", comment: ""), error.localizedDescription)
            return false
        }
        recoveryVaultRoots.insert(submissionVaultRoot)
        submittedInflightURLs.insert(inflightEntry.url)
        activeRecoveryDraft = nil
        recoverableDrafts.removeAll { $0.url == inflightEntry.url }

        // Ownership retires only here — AFTER the durable inflight journal now
        // references these exact files and BEFORE the optimistic clear. From
        // this point on no later cleanup may delete them: saved memos, retries,
        // undo-restored drafts and recovery keep their photos. A failed submit
        // returns above and retains the draft's ownership (and its files).
        photoService.retireDraftOwnership(snapshotAttachments.compactMap { staged -> PhotoPickerResult? in
            if case .photo(let result) = staged { return result }
            return nil
        })

        // Capture the exact pre-submit state before the optimistic clear. The
        // five-second confirmation pill can now perform a real undo instead of
        // merely copying the text back while leaving a duplicate memo behind.
        submissionUndoPayload = SubmissionUndoPayload(
            memo: memo,
            attachments: snapshotAttachments,
            location: userSetLocation,
            vaultRoot: submissionVaultRoot
        )

        // --- 1. Optimistic insert: the memo is on screen THIS frame. ---
        withAnimation(Motion.spring) {
            memos.insert(memo, at: 0)
        }
        // Single authoritative "committed" haptic, now firing on the same frame
        // as the visual — the composers no longer fire a redundant tap-time
        // haptic to paper over the old multi-second landing delay.
        Haptics.successNotification()

        // --- 2. Clear composer state synchronously. ---
        pendingLocation = nil
        pendingAttachments = []
        // The submitted draft is gone: retire its press-to-talk callback
        // snapshots so a late send/transcribe cannot write the next draft.
        // Every failed-submit path above returns before this point and keeps
        // the generations — and the draft's in-flight results — valid.
        rotateComposerGenerations()
        // B4: clear any residual failed-body breadcrumb from a prior attempt so
        // a later onChange of `lastFailedBody` can't restore stale text.
        lastFailedBody = nil

        // The perceived work is done — re-enable the send affordance now so a
        // heavy-capturing user can fire the next memo without waiting on disk.
        isSubmitting = false

        // Issue #18: record the creation event with the memo kind, and bump the
        // save count (US-010). The memo is committed to the UI, so these are
        // true now regardless of how the background enrichment resolves.
        AnalyticsService.shared.record(
            AnalyticsService.Name.memoCreated,
            props: ["kind": memo.type.rawValue]
        )
        let count = UserDefaults.standard.integer(forKey: AppSettings.Keys.memoSaveCount)
        UserDefaults.standard.set(count + 1, forKey: AppSettings.Keys.memoSaveCount)

        // --- 3. Durable write (落盘), then 4. progressive enrichment. ---
        let isRecovery = recoveryEntry != nil
        let persistence = enqueueMemoPersistence {
            try InflightDraftStore.persistMemo(memo, vaultRoot: submissionVaultRoot, isRecovery: isRecovery)
        }
        let previousSubmission = submitMemoTask
        submitMemoTask = Task { @MainActor in
            // Drain older acknowledgements and failure feedback as well as
            // the ordered writes before the latest wait handle completes.
            await previousSubmission?.value
            // Persist first. Disk I/O is offloaded so the append + atomic
            // rename never blocks the main thread (CLAUDE.md convention). The
            // failure is surfaced as a plain String so no Error existential
            // crosses the actor boundary.
            let writeErrorMessage = await persistence.value
            self.submittedInflightURLs.remove(inflightEntry.url)

            if let writeErrorMessage {
                // Durable write failed — roll the optimistic card back out and
                // hand the body back to the composer. The inflight record stays
                // on disk for next-launch recovery.
                withAnimation(Motion.rise) {
                    self.memos.removeAll { $0.id == memo.id }
                }
                self.submitError = String(format: NSLocalizedString("error.memo.save_failed", comment: ""), writeErrorMessage)
                if !trimmed.isEmpty { self.lastFailedBody = trimmed }
                if self.submissionUndoPayload?.memo.id == memo.id {
                    self.submissionUndoPayload = nil
                }
                self.recoverInflightDrafts()
                self.load()
                Haptics.warn()
                return
            }

            InflightDraftStore.acknowledge(inflightEntry)
            self.recoverInflightDrafts()
            // Durability is complete. Start slow, optional enrichment as a
            // separate best-effort task so a user pressing Undo never waits on
            // GPS or weather before the exact memo can be removed from disk.
            Task { @MainActor [weak self] in
                await self?.enrichMetadata(for: memo, vaultRoot: submissionVaultRoot)
            }
        }
        return true
    }

    /// Reverses the latest submit as one product action: remove its optimistic
    /// card now, restore staged metadata, then atomically remove the exact memo
    /// from disk after its in-flight append/enrichment finishes. `mutate` is
    /// keyed by id, so later memos can never be clobbered by this undo.
    @discardableResult
    func undoLastSubmission() -> String? {
        guard let payload = submissionUndoPayload else { return nil }
        submissionUndoPayload = nil

        withAnimation(Motion.rise) {
            memos.removeAll { $0.id == payload.memo.id }
        }

        let restoredIDs = Set(payload.attachments.map(\.id))
        let newerAttachments = pendingAttachments.filter { !restoredIDs.contains($0.id) }
        pendingAttachments = payload.attachments + newerAttachments
        if pendingLocation == nil {
            pendingLocation = payload.location
        }

        let memoID = payload.memo.id
        let memoDate = payload.memo.created
        let memoVaultRoot = payload.vaultRoot
        // Enqueue immediately after the append, before another user action
        // can reserve the next position in the shared persistence sequence.
        let persistence = enqueueMemoPersistence {
            try RawStorage.mutate(for: memoDate, vaultRoot: memoVaultRoot) { current in
                current.filter { $0.id != memoID }
            }
        }
        submissionUndoTask = Task { @MainActor [weak self] in
            let failure = await persistence.value
            if let failure, let self {
                self.submitError = String(
                    format: NSLocalizedString("error.memo.undo_failed", comment: ""),
                    failure
                )
                Haptics.warn()
            }
        }

        return payload.memo.body
    }

    /// Await the latest disk-side submission undo. Primarily useful to make
    /// integration tests deterministic; normal UI remains optimistic.
    func waitForSubmissionUndo() async {
        await submissionUndoTask?.value
        await waitForMemoPersistence()
    }

    /// Await the latest durable append without waiting for optional location
    /// or weather enrichment. Keeps storage integration tests isolated from
    /// the next test's temporary vault.
    func waitForSubmissionPersistence() async {
        await submitMemoTask?.value
        await waitForMemoPersistence()
    }

    /// Ends the five-second submit-undo window without changing persisted data.
    func clearLastSubmissionUndo() {
        submissionUndoPayload = nil
    }

    /// Fills in the slow, optional GPS + weather signals AFTER a memo is already
    /// on screen and on disk. Reverse of the old submit order: the user never
    /// waits on these. Best-effort — any signal that can't be resolved is simply
    /// left off. The raw file is patched in place via `RawStorage.mutate` (which
    /// runs on the write queue, so it can't clobber a concurrent append/rewrite)
    /// and the resolved values crossfade into the on-screen card.
    private func enrichMetadata(for memo: Memo, vaultRoot: URL) async {
        // 1. Resolve a live GPS fix only when we don't already have coordinates
        //    (user pin / photo EXIF already supplied them at commit time).
        let needsLocation = memo.location?.lat == nil
        var resolvedLocation = memo.location
        // Saving text is not a request for location access. Only enrich with
        // an already authorized location; the explicit location action owns
        // the permission prompt.
        let locationAuthorized = locationService.authorizationStatus == .authorizedWhenInUse
            || locationService.authorizationStatus == .authorizedAlways
        if needsLocation && locationAuthorized {
            resolvedLocation = try? await locationService.currentLocation(timeout: 3)
        }
        let locationChanged = needsLocation && resolvedLocation?.lat != nil

        // 2. Weather needs coordinates; fetch once location has settled.
        let resolvedWeather = await weatherService.currentWeather(at: resolvedLocation)

        // Nothing new to write — leave the memo as committed.
        guard locationChanged || resolvedWeather != nil else { return }

        // 3. Patch the raw file in place, keyed by memo id. Returning nil (memo
        //    no longer present — e.g. deleted mid-enrichment) aborts the write.
        let memoID = memo.id
        let createdDate = memo.created
        let locationToWrite = locationChanged ? resolvedLocation : nil
        Task.detached(priority: .utility) {
            try? RawStorage.mutate(for: createdDate, vaultRoot: vaultRoot) { current in
                guard let idx = current.firstIndex(where: { $0.id == memoID }) else { return nil }
                var updated = current
                if let loc = locationToWrite { updated[idx].location = loc }
                if let w = resolvedWeather { updated[idx].weather = w }
                return updated
            }
        }

        // 4. Reflect the enriched metadata in the on-screen card (gentle
        //    crossfade — the row is unchanged except for these quiet fields).
        guard let idx = memos.firstIndex(where: { $0.id == memoID }) else { return }
        var patched = memos[idx]
        if let loc = locationToWrite { patched.location = loc }
        if let w = resolvedWeather { patched.weather = w }
        var newMemos = memos
        newMemos[idx] = patched
        withAnimation(Motion.fade) { memos = newMemos }
    }

    // MARK: - Fetch Location

    /// Requests location permission if needed, then fetches current GPS + reverse geocode.
    /// Sets `pendingLocation` for the next memo submission.
    /// Provides graceful degradation: timeout falls back to coordinates-only.
    func fetchLocation() {
        guard !isLocating else { return }
        isLocating = true
        submitError = nil

        locationTask = Task { @MainActor in
            defer { isLocating = false }
            do {
                let loc = try await locationService.currentLocation(timeout: 3)
                pendingLocation = loc
            } catch LocationError.denied {
                SentryReporter.breadcrumb(
                    category: "location",
                    level: .error,
                    message: "location.denied"
                )
                GlassErrorBannerStack.shared.push(
                    GlassErrorBannerItem(
                        icon: Image(systemName: "location.slash"),
                        title: "error.location_denied.title",
                        subtitle: "error.location_denied.subtitle",
                        retryLabel: NSLocalizedString("error.location_denied.cta", comment: ""),
                        retryAction: {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            UIApplication.shared.open(url)
                        }
                    )
                )
            } catch LocationError.timeout {
                SentryReporter.breadcrumb(
                    category: "location",
                    level: .warning,
                    message: "location.timeout — falling back to lastLocation if available"
                )
                // Even on timeout, LocationService may have returned coords-only
                if let loc = locationService.lastLocation {
                    pendingLocation = loc
                }
                // Don't show error for timeout — coords-only is acceptable
            } catch LocationError.busy {
                SentryReporter.breadcrumb(
                    category: "location",
                    level: .info,
                    message: "location.busy concurrent request"
                )
                // Another location request is in-flight; don't reset the pending
                // attachment, don't block the memo submission flow — just surface
                // a soft error message so the user can retry shortly.
                submitError = NSLocalizedString(
                    "error.location.busy",
                    value: "位置请求进行中，请稍后再试",
                    comment: "Shown when fetchLocation is called while a previous request is still in flight"
                )
            } catch {
                SentryReporter.breadcrumb(
                    category: "location",
                    level: .error,
                    message: "location.\(error)"
                )
                submitError = String(format: NSLocalizedString("error.memo.location_failed", comment: ""), error.localizedDescription)
            }
        }
    }

    /// Sets a specific location as the pending location (used by spotlight chip).
    func setPendingLocation(_ location: Memo.Location) {
        pendingLocation = location
    }

    /// Clears any pending location so it won't be attached to the next memo.
    func clearPendingLocation() {
        pendingLocation = nil
    }

    // MARK: - Compile Trigger

    /// Triggers AI compilation for today's memos.
    /// During compilation, the only on-screen indicator is `CompilePromptCard`'s compiling state
    /// (US-004). BannerCenter is reserved for terminal outcomes — success / offline / error.
    /// - Parameter silent: When true, suppresses BannerCenter notifications for
    ///   recoverable error paths (missing/invalid key, offline). Used by the
    ///   auto-compile-on-load entry point so the first screen reads as the
    ///   intended museum-aesthetic surface even when the user hasn't entered
    ///   a key yet — the calmer "钥匙就绪后" status row already covers this
    ///   state. Manual taps stay loud so the user sees the consequence of
    ///   their own action.
    func compile(silent: Bool = false) {
        guard !isCompiling else { return }
        isCompiling = true
        submitError = nil
        let silentMode = silent

        compilationTask?.cancel()
        compilationTask = Task { @MainActor in
            defer {
                isCompiling = false
                compilationTask = nil
            }

            do {
                // Retry attempts no longer push progress banners — CompilePromptCard owns the
                // single in-flight indicator. The callback is intentionally a no-op here; if
                // future telemetry needs retry counts, route them through a @Published field
                // so CompilePromptCard can render the attempt inline.
                let outcome = try await compilationService.compile(for: date, trigger: "manual") { _, _ in }
                checkDailyPage()
                // Issue #814: hash guard short-circuited the LLM call because
                // nothing substantive changed since the last compile. Tell the
                // user why the diary looks identical instead of pretending a
                // fresh compile happened.
                if outcome == .skippedUnchanged {
                    HapticFeedback.light()
                    if !silentMode {
                        BannerCenter.shared.show(AppBannerModel(
                            kind: .info,
                            title: NSLocalizedString(
                                "today.compile.skipped_unchanged",
                                value: "内容没有变化，已跳过重新编译",
                                comment: "Banner when compile is skipped because memos are unchanged"
                            ),
                            autoDismiss: true
                        ))
                    }
                    return
                }
                await OnThisDayIndex.shared.rebuildIndex()
                SignatureHaptics.compileSuccess()
                BannerCenter.shared.show(AppBannerModel(
                    kind: .success,
                    title: NSLocalizedString("today.compile.success", comment: ""),
                    autoDismiss: true
                ))
            } catch CompilationError.offline {
                if !silentMode {
                    BannerCenter.shared.show(AppBannerModel(
                        kind: .info,
                        title: NSLocalizedString("today.compile.offline", comment: ""),
                        autoDismiss: true
                    ))
                }
            } catch CompilationError.missingApiKey {
                if !silentMode {
                    HapticFeedback.error()
                    BannerCenter.shared.show(AppBannerModel(
                        kind: .error,
                        title: NSLocalizedString("today.compile.missingKey", comment: ""),
                        primaryAction: BannerAction(label: NSLocalizedString("today.compile.action.settings", comment: "")) { [weak self] in
                            self?.shouldShowSettings = true
                        }
                    ))
                }
            } catch CompilationError.apiError(let code, _) where code == 401 {
                if !silentMode {
                    HapticFeedback.error()
                    BannerCenter.shared.show(AppBannerModel(
                        kind: .error,
                        title: NSLocalizedString("today.compile.invalidKey", comment: ""),
                        primaryAction: BannerAction(label: NSLocalizedString("today.compile.action.settings", comment: "")) { [weak self] in
                            self?.shouldShowSettings = true
                        }
                    ))
                }
            } catch CompilationError.parseError {
                HapticFeedback.error()
                BannerCenter.shared.show(AppBannerModel(
                    kind: .error,
                    title: NSLocalizedString("today.compile.parseError", comment: ""),
                    primaryAction: BannerAction(label: NSLocalizedString("today.compile.action.viewLog", comment: "")) { }
                ))
            } catch {
                HapticFeedback.error()
                GlassErrorBannerStack.shared.push(
                    GlassErrorBannerItem(
                        icon: Image(systemName: "wifi.slash"),
                        title: "error.compile.title",
                        subtitle: "error.compile.subtitle",
                        retryLabel: NSLocalizedString("error.compile.retry", comment: ""),
                        retryAction: { [weak self] in self?.compile() }
                    )
                )
            }
        }
    }

    // MARK: - Private Helpers

    // MARK: - Device Info

    /// Returns a human-readable device description string for the frontmatter.
    private func deviceDescription() -> String {
        let device = UIDevice.current
        return "\(device.model) (\(device.systemName) \(device.systemVersion))"
    }

    // MARK: - Private Helpers

    private func checkDailyPage() {
        let dailyURL = dailyPageURL(for: date)
        Task.detached { [weak self] in
            let exists = FileManager.default.fileExists(atPath: dailyURL.path)
            var summary: String?
            if exists {
                do {
                    let content = try String(contentsOf: dailyURL, encoding: .utf8)
                    summary = FrontmatterParser.extractField("summary", from: content)
                } catch {
                    await DayPageLogger.shared.error("TodayViewModel: read daily: \(error)")
                }
            }
            await MainActor.run {
                self?.isDailyPageCompiled = exists
                self?.dailyPageSummary = summary
            }
        }
    }

    private func dailyPageURL(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = AppSettings.currentTimeZone()
        let dateStr = formatter.string(from: date)
        return VaultInitializer.vaultURL
            .appendingPathComponent("wiki")
            .appendingPathComponent("daily")
            .appendingPathComponent("\(dateStr).md")
    }

}
