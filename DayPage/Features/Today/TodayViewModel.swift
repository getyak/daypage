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
            let txStatus: Memo.TranscriptionStatus? = r.transcript != nil ? .done : .failed
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
final class TodayViewModel: ObservableObject, MemoDetailViewModel {

    // MARK: Published State

    /// Today's memos in reverse-chronological order (newest first).
    @Published var memos: [Memo] = []

    /// Number of signals (memos) captured today — drives the Day Orb readout.
    var signalCount: Int { memos.count }

    /// Total word count across all of today's memo bodies.
    var todayWordCount: Int {
        memos.reduce(0) { $0 + TodayViewModel.wordCount(in: $1.body) }
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

    /// Pending photo results (can accumulate before submission, cleared after).
    @Published var pendingPhotos: [PhotoPickerResult] = []

    /// Staged attachments (photo + voice) accumulated before the next submit.
    @Published var pendingAttachments: [PendingAttachment] = []

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

    // MARK: Private

    private var date: Date
    private let locationService = LocationService.shared
    private let weatherService = WeatherService.shared
    private let photoService = PhotoService.shared
    private let voiceService = VoiceService.shared
    private let compilationService = CompilationService.shared

    // MARK: Private Task Handles

    /// Cancellable handles for long-lived async operations; cancelled in deinit.
    private var loadTask: Task<Void, Never>?
    private var photoTask: Task<Void, Never>?
    private var cameraPhotoTask: Task<Void, Never>?
    private var submitTask: Task<Void, Never>?
    private var submitMemoTask: Task<Void, Never>?
    private var locationTask: Task<Void, Never>?
    private var compilationTask: Task<Void, Never>?
    private var deleteUndoTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    // MARK: Init

    init(date: Date = Date()) {
        self.date = date
        observeCompilationFailure()
        observeOnThisDay()
        observeConflictResolution()
        observeTimelineIndex()
    }

    deinit {
        loadTask?.cancel()
        photoTask?.cancel()
        cameraPhotoTask?.cancel()
        submitTask?.cancel()
        submitMemoTask?.cancel()
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
            }
            .store(in: &cancellables)
    }

    // MARK: - Delete / Pin Memo

    /// Removes a memo from today's file and refreshes the in-memory list.
    ///
    /// UI updates optimistically on the MainActor (so the delete animation
    /// stays snappy), then the rewrite is dispatched off-main through
    /// `RawStorage.rewrite` — which goes through `writeQueue.sync` and
    /// therefore cannot race with `append()`. If the write fails, the UI
    /// state is rolled back and an error is surfaced.
    func deleteMemo(_ memo: Memo) {
        let previous = memos
        let remaining = memos.filter { $0.id != memo.id }
        withAnimation(Motion.rise) {
            memos = remaining
        }
        Haptics.warn()
        persistMemos(remaining, capturedDate: date, previous: previous, failureMessagePrefix: NSLocalizedString("error.memo.delete_failed", comment: ""))

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
        deleteUndoTask?.cancel()
        deleteUndoTask = nil
        lastDeletedMemo = nil

        var restored = memos
        // Re-insert using the same sort order as the load path:
        // pinned memos float to top (by pinnedAt desc), then by created desc.
        if memo.pinnedAt != nil {
            let insertIdx = restored.firstIndex(where: { $0.pinnedAt == nil }) ?? restored.endIndex
            restored.insert(memo, at: insertIdx)
        } else {
            let insertIdx = restored.firstIndex(where: { m in
                m.pinnedAt == nil && m.created < memo.created
            }) ?? restored.endIndex
            restored.insert(memo, at: insertIdx)
        }
        let previous = memos
        withAnimation(Motion.rise) {
            memos = restored
        }
        Haptics.soft()
        persistMemos(restored, capturedDate: date, previous: previous, failureMessagePrefix: NSLocalizedString("error.memo.undo_failed", comment: ""))
    }

    /// Replaces the body text of an existing memo and writes through to disk.
    func update(memo: Memo, body: String) {
        guard let idx = memos.firstIndex(where: { $0.id == memo.id }) else { return }
        var updated = memos[idx]
        updated.body = body
        var newMemos = memos
        newMemos[idx] = updated
        let previous = memos
        withAnimation(Motion.rise) {
            memos = newMemos
        }
        Haptics.commit()
        persistMemos(newMemos, capturedDate: date, previous: previous, failureMessagePrefix: NSLocalizedString("error.memo.save_failed", comment: ""))
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
        let previous = memos
        // List reorder physically moves rows — wrap the same curve in
        // respectReduceMotion so Reduce-Motion users get an instant settle.
        withAnimation(Motion.respectReduceMotion(.easeInOut(duration: 0.25))) {
            memos = updated
        }
        persistMemos(updated, capturedDate: date, previous: previous, failureMessagePrefix: NSLocalizedString("error.memo.pin_failed", comment: ""))
    }

    /// Unpins a memo, restoring it to its natural position based on original `created` time.
    func unpinMemo(_ memo: Memo) {
        guard let idx = memos.firstIndex(where: { $0.id == memo.id }) else { return }
        var unpinned = memos[idx]
        unpinned.pinnedAt = nil
        var updated = memos
        updated.remove(at: idx)
        let insertIdx = updated.firstIndex(where: { $0.created < unpinned.created }) ?? updated.endIndex
        updated.insert(unpinned, at: insertIdx)
        let previous = memos
        // List reorder physically moves rows — wrap the same curve in
        // respectReduceMotion so Reduce-Motion users get an instant settle.
        withAnimation(Motion.respectReduceMotion(.easeInOut(duration: 0.25))) {
            memos = updated
        }
        persistMemos(updated, capturedDate: date, previous: previous, failureMessagePrefix: NSLocalizedString("error.memo.unpin_failed", comment: ""))
    }

    /// Dispatches a `RawStorage.rewrite` off the MainActor so disk I/O never
    /// blocks the UI thread, and so the rewrite is serialized with `append()`
    /// through `RawStorage.writeQueue`.
    ///
    /// On failure, restores `memos` to `previous` and surfaces an error
    /// banner via `submitError`. Memo arrays are value types, so capturing
    /// them across the actor boundary is safe.
    private func persistMemos(
        _ memosToWrite: [Memo],
        capturedDate: Date,
        previous: [Memo],
        failureMessagePrefix: String
    ) {
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try RawStorage.rewrite(memosToWrite, for: capturedDate)
            } catch {
                await MainActor.run {
                    guard let self = self else { return }
                    withAnimation(Motion.rise) {
                        self.memos = previous
                    }
                    self.submitError = String(format: failureMessagePrefix, error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Load Memos

    /// Drains the inflight-draft store left behind by a submit that never
    /// completed (kill-during-await, OS-memory-eviction, explicit cancel).
    /// Routes the most recent body into `lastFailedBody` so TodayView's
    /// existing restore-into-composer hook picks it up — no second UI path.
    ///
    /// Older inflights (>1) are discarded after breadcrumbing: in practice
    /// >1 inflight means the user submitted, was interrupted, relaunched,
    /// submitted again, and was interrupted *again* before recovering — a
    /// genuinely rare path where surfacing only the freshest body keeps the
    /// recovery UI simple. The discarded bodies are still on disk in
    /// `vault/raw/.inflight/` until clearAll() runs, so a future "view all
    /// drafts" screen can surface them.
    ///
    /// Idempotent: safe to call from every `onAppear`. A no-op when no
    /// inflight records exist.
    func recoverInflightDrafts() {
        let drafts = InflightDraftStore.pending()
        guard !drafts.isEmpty else { return }

        if drafts.count > 1 {
            SentryReporter.breadcrumb(
                category: "inflight",
                level: .warning,
                message: "recover: \(drafts.count) inflight drafts found, surfacing newest"
            )
        }

        // Restore the newest body. Only when the composer is empty (the
        // onChange-of-lastFailedBody hook guards that, so a fresh in-progress
        // draft is never clobbered).
        if let newest = drafts.first, !newest.body.isEmpty {
            lastFailedBody = newest.body
        }
        // Clear all on-disk records — the surfaced body is now in
        // lastFailedBody (which TodayView restores into draftText, which
        // SceneStorage will persist). The other bodies are intentionally
        // dropped per the Beta v1.0 scope above.
        InflightDraftStore.clearAll()
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
        let dailyURL = dailyPageURL(for: capturedDate)
        // Capture the on-this-day file path before going off-actor.
        let capturedOTDFilePath: String? = onThisDayEntry?.filePath

        loadTask?.cancel()
        loadTask = Task.detached(priority: .userInitiated) {
            // --- Off-main disk I/O ---
            let loadResult: Result<[Memo], Error>
            do {
                let loaded = try RawStorage.read(for: capturedDate)
                loadResult = .success(loaded)
            } catch {
                loadResult = .failure(error)
            }

            let dailyExists = FileManager.default.fileExists(atPath: dailyURL.path)
            var dailySummary: String? = nil
            if dailyExists {
                if let content = try? String(contentsOf: dailyURL, encoding: .utf8) {
                    dailySummary = FrontmatterParser.extractField("summary", from: content)
                }
            }

            // Load yesterday's compiled daily page for fallback
            let yesterdayDate = Calendar.current.date(byAdding: .day, value: -1, to: capturedDate) ?? capturedDate
            let yesterdayDailyURL: URL = {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = AppSettings.currentTimeZone()
                let s = f.string(from: yesterdayDate)
                return VaultInitializer.vaultURL
                    .appendingPathComponent("wiki/daily/\(s).md")
            }()
            var yesterdayPage: DailyPageModel? = nil
            let yesterdayDateString: String = {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = AppSettings.currentTimeZone()
                return f.string(from: yesterdayDate)
            }()
            if FileManager.default.fileExists(atPath: yesterdayDailyURL.path),
               let content = try? String(contentsOf: yesterdayDailyURL, encoding: .utf8) {
                yesterdayPage = DailyPageParser.parse(content: content, dateString: yesterdayDateString)
            }

            // Load on-this-day memos for fallback using the file path captured before going off-actor.
            var otdMemos: [Memo] = []
            if let filePath = capturedOTDFilePath {
                let rawURL = VaultInitializer.vaultURL.appendingPathComponent(filePath)
                if let content = try? String(contentsOf: rawURL, encoding: .utf8) {
                    otdMemos = RawStorage.parse(fileContent: content)
                }
            }

            // --- Back on MainActor: update published state ---
            await MainActor.run {
                switch loadResult {
                case .success(let loaded):
                    // Newest first; pinned memos float to the top
                    self.memos = loaded.sorted { lhs, rhs in
                        if lhs.pinnedAt != nil && rhs.pinnedAt == nil { return true }
                        if lhs.pinnedAt == nil && rhs.pinnedAt != nil { return false }
                        if let lp = lhs.pinnedAt, let rp = rhs.pinnedAt { return lp > rp }
                        return lhs.created > rhs.created
                    }
                    self.errorMessage = nil
                case .failure(let error):
                    self.errorMessage = String(format: NSLocalizedString("error.memo.load_failed", comment: ""), error.localizedDescription)
                    self.memos = []
                }

                self.isDailyPageCompiled = dailyExists
                self.dailyPageSummary = dailyExists ? dailySummary : nil
                self.weeklyRecap = WeeklyRecapService.shared.entries()
                // O(1) read from TimelineIndex (cached); the expensive scan now
                // happens only on index rebuild, off this hot path.
                self.timelineSections = TimelineService.sections(referenceDate: capturedDate)
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

    func dismissOnThisDay() {
        let today = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
        UserDefaults.standard.set(today, forKey: AppSettings.Keys.onThisDayDismissed)
        onThisDayEntry = nil
    }

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
        isProcessingPhoto = true
        submitError = nil

        photoTask = Task { @MainActor in
            defer { isProcessingPhoto = false }

            guard let result = await photoService.processPickerItem(item) else {
                submitError = NSLocalizedString("error.memo.photo_failed", comment: "")
                return
            }

            pendingAttachments.append(.photo(result))
        }
    }

    /// Removes a staged attachment by id.
    func removePendingAttachment(id: String) {
        pendingAttachments.removeAll { $0.id == id }
    }

    /// Clears all pending photos without submitting.
    func clearPendingPhotos() {
        pendingPhotos = []
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

    // MARK: - Retranscribe (US-014 / US-016)

    /// Re-runs transcription for a failed voice attachment and updates the memo on disk.
    func retranscribe(memo: Memo, attachment: Memo.Attachment) {
        let audioURL = VaultInitializer.vaultURL.appendingPathComponent(attachment.file)
        Task { @MainActor in
            guard let transcript = await voiceService.transcribeAudio(at: audioURL),
                  !transcript.isEmpty else { return }
            guard let memoIdx = memos.firstIndex(where: { $0.id == memo.id }) else { return }
            var updated = memos[memoIdx]
            var atts = updated.attachments
            if let attIdx = atts.firstIndex(where: { $0.file == attachment.file }) {
                atts[attIdx] = Memo.Attachment(
                    file: attachment.file,
                    kind: attachment.kind,
                    duration: attachment.duration,
                    transcript: transcript,
                    transcriptionStatus: .done
                )
            }
            updated.attachments = atts
            var newMemos = memos
            newMemos[memoIdx] = updated
            let previous = memos
            // Re-transcription only swaps text inside an existing card —
            // crossfade it. A bare `withAnimation` (default spring) would
            // re-spring the whole timeline layout for a transcript update.
            withAnimation(Motion.fade) { memos = newMemos }
            persistMemos(newMemos, capturedDate: date, previous: previous, failureMessagePrefix: NSLocalizedString("error.memo.retranscribe_failed", comment: ""))
        }
    }

    /// Re-runs transcription for a staged (pending, not-yet-submitted) voice attachment. US-016.
    func retranscribeVoiceAttachment(id: String) {
        guard let idx = pendingAttachments.firstIndex(where: { $0.id == id }),
              case .voice(let result) = pendingAttachments[idx] else { return }
        let audioURL = result.fileURL
        Task { @MainActor in
            let transcript = await voiceService.transcribeAudio(at: audioURL)
            guard let idx2 = pendingAttachments.firstIndex(where: { $0.id == id }),
                  case .voice(let r) = pendingAttachments[idx2] else { return }
            let updated = VoiceRecordingResult(
                filePath: r.filePath,
                fileURL: r.fileURL,
                duration: r.duration,
                transcript: transcript
            )
            pendingAttachments[idx2] = .voice(updated)
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
        let filesDir = VaultInitializer.vaultURL
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
        let result = FilePickerResult(filePath: relativePath, fileName: finalURL.lastPathComponent)
        pendingAttachments.append(.file(result))
    }

    /// Processes a UIImage captured from the camera and stages it as a pending attachment.
    func addCameraPhoto(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        isProcessingPhoto = true
        cameraPhotoTask = Task { @MainActor in
            defer { isProcessingPhoto = false }
            guard let result = await photoService.processImageDataAsync(data) else {
                submitError = NSLocalizedString("error.memo.photo_failed", comment: "")
                return
            }
            pendingAttachments.append(.photo(result))
        }
    }

    /// Processes a camera-captured UIImage and immediately submits it as a standalone memo.
    func addCameraPhotoAndSubmit(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        isProcessingPhoto = true
        cameraPhotoTask = Task { @MainActor in
            defer { isProcessingPhoto = false }
            guard let result = await photoService.processImageDataAsync(data) else {
                submitError = NSLocalizedString("error.memo.photo_failed", comment: "")
                return
            }
            pendingAttachments.append(.photo(result))
            submitCombinedMemo(body: "")
        }
    }

    /// Processes multiple PhotosPickerItems and immediately submits them as one memo.
    func addPhotosAndSubmit(items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        isProcessingPhoto = true
        // US-012: expose batch progress when > 3 photos
        batchPhotoTotal = items.count
        batchPhotoProgress = 0
        submitTask = Task { @MainActor in
            defer {
                isProcessingPhoto = false
                batchPhotoTotal = 0
                batchPhotoProgress = 0
            }
            var processed = false
            for (idx, item) in items.enumerated() {
                guard let result = await photoService.processPickerItem(item) else { continue }
                pendingAttachments.append(.photo(result))
                processed = true
                if batchPhotoTotal > 3 {
                    batchPhotoProgress = Double(idx + 1) / Double(batchPhotoTotal)
                }
            }
            if processed {
                submitCombinedMemo(body: "")
            }
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
    func submitCombinedMemo(body: String) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = !trimmed.isEmpty
        let attachments = pendingAttachments
        guard hasText || !attachments.isEmpty else { return }

        // B4: re-entrancy guard. Without this, a rapid double-tap on the send
        // arrow (or send + an auto-submit from photo batch processing) can
        // enqueue two parallel Tasks that both append the same memo and race
        // on the inflight-draft store. Drops the second call as a no-op.
        guard !isSubmitting else { return }

        isSubmitting = true
        submitError = nil

        let loc = pendingLocation
        let snapshotAttachments = attachments

        // Persist an inflight record BEFORE we await anything. If the user
        // kills the app (or the OS does) during the location/weather/append
        // await chain, this on-disk record lets the next launch restore the
        // body into the composer — without it, the synchronous `draftText
        // = ""` in TodayView's Send handler would have silently destroyed
        // the user's typed text. Issue #23.
        let inflightAttachmentPaths = snapshotAttachments.map { $0.attachment.file }
        let inflightURL = InflightDraftStore.enqueue(
            body: trimmed,
            attachmentPaths: inflightAttachmentPaths
        )

        submitMemoTask = Task { @MainActor in
            defer { isSubmitting = false }

            // Auto-fetch location for every memo when not already set by the user.
            // Falls back silently on denial or timeout — location is best-effort metadata.
            var memoLocation: Memo.Location? = loc
            if memoLocation == nil {
                memoLocation = try? await locationService.currentLocation(timeout: 3)
            }

            // Derive location from first photo EXIF when GPS is still missing
            if memoLocation == nil {
                for att in snapshotAttachments {
                    if case .photo(let r) = att,
                       let lat = r.exif?.gpsLat,
                       let lng = r.exif?.gpsLng {
                        memoLocation = Memo.Location(name: nil, lat: lat, lng: lng)
                        break
                    }
                }
            }

            let weatherString = await weatherService.currentWeather(at: memoLocation)

            // Determine created date: prefer first photo EXIF date when text is absent
            var created = Date()
            if !hasText, case .photo(let r) = snapshotAttachments.first,
               let exifDate = r.exif?.capturedAt {
                created = exifDate
            }

            // Build Memo.Attachment array
            let memoAttachments = snapshotAttachments.map { $0.attachment }

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
            let finalBody = trimmed

            let memo = Memo(
                type: memoType,
                created: created,
                location: memoLocation,
                weather: weatherString,
                device: deviceDescription(),
                attachments: memoAttachments,
                body: finalBody
            )

            do {
                try RawStorage.append(memo)
                InflightDraftStore.dequeue(inflightURL)
                // Issue #18 (2026-07-03): record the creation event with
                // the memo kind so the debug board can show a per-kind
                // stack for "what am I capturing this month?".
                AnalyticsService.shared.record(
                    AnalyticsService.Name.memoCreated,
                    props: ["kind": memo.type.rawValue]
                )
                withAnimation(Motion.spring) {
                    memos.insert(memo, at: 0)
                }
                Haptics.successNotification()
                pendingLocation = nil
                pendingAttachments = []
                // B4: clear any residual failed-body breadcrumb from a prior
                // attempt. Without this, after recovery + successful resubmit
                // the next onChange of `lastFailedBody` could re-fire and
                // restore stale text into the now-clean composer.
                lastFailedBody = nil
                // Track save count for sync banner (US-010)
                let count = UserDefaults.standard.integer(forKey: AppSettings.Keys.memoSaveCount)
                UserDefaults.standard.set(count + 1, forKey: AppSettings.Keys.memoSaveCount)
            } catch {
                // The inflight record stays on disk — next launch (or the
                // user retrying via lastFailedBody) gets the body back.
                submitError = String(format: NSLocalizedString("error.memo.save_failed", comment: ""), error.localizedDescription)
                if !finalBody.isEmpty {
                    lastFailedBody = finalBody
                }
            }
        }
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
        guard FileManager.default.fileExists(atPath: dailyURL.path) else {
            isDailyPageCompiled = false
            dailyPageSummary = nil
            return
        }

        isDailyPageCompiled = true

        // Extract summary from frontmatter if available
        do {
            let content = try String(contentsOf: dailyURL, encoding: .utf8)
            dailyPageSummary = FrontmatterParser.extractField("summary", from: content)
        } catch {
            DayPageLogger.shared.error("TodayViewModel: read daily: \(error)")
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
