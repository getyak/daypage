import Foundation
import SwiftUI
import UIKit
import CoreLocation
import Photos
import PhotosUI
import Combine

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
            return Memo.Attachment(file: r.filePath, kind: "audio", duration: r.duration, transcript: r.transcript)
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
                self?.compilationFailedError = "后台编译失败，请检查网络或 API Key 后重试"
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
        persistMemos(remaining, capturedDate: date, previous: previous, failureMessagePrefix: "删除失败")

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
        persistMemos(restored, capturedDate: date, previous: previous, failureMessagePrefix: "撤销失败")
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
        persistMemos(newMemos, capturedDate: date, previous: previous, failureMessagePrefix: "保存失败")
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
        withAnimation(.easeInOut(duration: 0.25)) {
            memos = updated
        }
        persistMemos(updated, capturedDate: date, previous: previous, failureMessagePrefix: "置顶失败")
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
        withAnimation(.easeInOut(duration: 0.25)) {
            memos = updated
        }
        persistMemos(updated, capturedDate: date, previous: previous, failureMessagePrefix: "取消置顶失败")
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
                    self.submitError = "\(failureMessagePrefix)：\(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Load Memos

    /// Async entry point for pull-to-refresh: kicks off load() and suspends until
    /// the underlying loadTask finishes, so the system refresh spinner persists for
    /// exactly as long as the reload takes.
    func refresh() async {
        load()
        await loadTask?.value
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
                    self.errorMessage = "加载失败：\(error.localizedDescription)"
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

                // Auto-compile on load when today has uncompiled memos. The compile
                // button was removed in #213 — the user expects today's diary to be
                // ready whenever they open the app, no manual trigger required.
                if !self.isDailyPageCompiled && !self.memos.isEmpty && !self.isCompiling {
                    self.compile()
                }
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
                submitError = "照片处理失败，请重试"
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

    // MARK: - Retranscribe (US-014)

    /// Re-runs transcription for a failed voice attachment and updates the memo on disk.
    func retranscribe(memo: Memo, attachment: Memo.Attachment) {
        let audioURL = VaultInitializer.vaultURL.appendingPathComponent(attachment.file)
        Task { @MainActor in
            guard let transcript = await voiceService.transcribeAudio(at: audioURL),
                  !transcript.isEmpty else { return }
            // Update the attachment in memory and persist
            guard let memoIdx = memos.firstIndex(where: { $0.id == memo.id }) else { return }
            var updated = memos[memoIdx]
            var atts = updated.attachments
            if let attIdx = atts.firstIndex(where: { $0.file == attachment.file }) {
                atts[attIdx] = Memo.Attachment(
                    file: attachment.file,
                    kind: attachment.kind,
                    duration: attachment.duration,
                    transcript: transcript
                )
            }
            updated.attachments = atts
            var newMemos = memos
            newMemos[memoIdx] = updated
            let previous = memos
            withAnimation { memos = newMemos }
            persistMemos(newMemos, capturedDate: date, previous: previous, failureMessagePrefix: "重新转写失败")
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
            submitError = "文件复制失败：\(error.localizedDescription)"
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
                submitError = "照片处理失败，请重试"
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
                submitError = "照片处理失败，请重试"
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

        isSubmitting = true
        submitError = nil

        let loc = pendingLocation
        let snapshotAttachments = attachments

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
                withAnimation(Motion.spring) {
                    memos.insert(memo, at: 0)
                }
                Haptics.successNotification()
                pendingLocation = nil
                pendingAttachments = []
                // Track save count for sync banner (US-010)
                let count = UserDefaults.standard.integer(forKey: AppSettings.Keys.memoSaveCount)
                UserDefaults.standard.set(count + 1, forKey: AppSettings.Keys.memoSaveCount)
            } catch {
                submitError = "保存失败：\(error.localizedDescription)"
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
                // Even on timeout, LocationService may have returned coords-only
                if let loc = locationService.lastLocation {
                    pendingLocation = loc
                }
                // Don't show error for timeout — coords-only is acceptable
            } catch {
                submitError = "位置获取失败：\(error.localizedDescription)"
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

    /// Triggers manual AI compilation for today's memos.
    /// During compilation, the only on-screen indicator is `CompilePromptCard`'s compiling state
    /// (US-004). BannerCenter is reserved for terminal outcomes — success / offline / error.
    func compile() {
        guard !isCompiling else { return }
        isCompiling = true
        submitError = nil

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
                try await compilationService.compile(for: date, trigger: "manual") { _, _ in }
                checkDailyPage()
                await OnThisDayIndex.shared.rebuildIndex()
                HapticFeedback.success()
                BannerCenter.shared.show(AppBannerModel(
                    kind: .success,
                    title: "今日 Daily Page 已生成",
                    autoDismiss: true
                ))
            } catch CompilationError.offline {
                BannerCenter.shared.show(AppBannerModel(
                    kind: .info,
                    title: "当前离线，已加入队列",
                    autoDismiss: true
                ))
            } catch CompilationError.missingApiKey {
                HapticFeedback.error()
                BannerCenter.shared.show(AppBannerModel(
                    kind: .error,
                    title: "DeepSeek API Key 未配置",
                    primaryAction: BannerAction(label: "前往设置") { [weak self] in
                        self?.shouldShowSettings = true
                    }
                ))
            } catch CompilationError.apiError(let code, _) where code == 401 {
                HapticFeedback.error()
                BannerCenter.shared.show(AppBannerModel(
                    kind: .error,
                    title: "API Key 无效或已过期",
                    primaryAction: BannerAction(label: "前往设置") { [weak self] in
                        self?.shouldShowSettings = true
                    }
                ))
            } catch CompilationError.parseError {
                HapticFeedback.error()
                BannerCenter.shared.show(AppBannerModel(
                    kind: .error,
                    title: "AI 返回格式异常",
                    primaryAction: BannerAction(label: "查看日志") { }
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
