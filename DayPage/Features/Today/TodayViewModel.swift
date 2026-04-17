import Foundation
import SwiftUI
import UIKit
import CoreLocation
import PhotosUI

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

// MARK: - TodayViewModel

/// Manages state for TodayView: loading today's memos, tracking compiled state.
@MainActor
final class TodayViewModel: ObservableObject {

    // MARK: Published State

    /// Today's memos in reverse-chronological order (newest first).
    @Published var memos: [Memo] = []

    /// Whether the Daily Page for today has been compiled.
    @Published var isDailyPageCompiled: Bool = false

    /// A brief excerpt from the compiled Daily Page (if compiled).
    @Published var dailyPageSummary: String? = nil

    /// Whether the view is currently loading memos.
    @Published var isLoading: Bool = false

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

    /// Whether any API key is missing (triggers banner in TodayView).
    var hasApiKeysMissing: Bool {
        Secrets.dashScopeApiKey.isEmpty
            || Secrets.openAIWhisperApiKey.isEmpty
            || Secrets.openWeatherApiKey.isEmpty
    }

    // MARK: Private

    private let date: Date
    private let locationService = LocationService.shared
    private let weatherService = WeatherService.shared
    private let photoService = PhotoService.shared
    private let voiceService = VoiceService.shared
    private let compilationService = CompilationService.shared

    // MARK: Init

    init(date: Date = Date()) {
        self.date = date
        observeCompilationFailure()
    }

    private func observeCompilationFailure() {
        NotificationCenter.default.addObserver(
            forName: .compilationDidFail,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.compilationFailedError = "后台编译失败，请检查网络或 API Key 后重试"
            }
        }
        NotificationCenter.default.addObserver(
            forName: .compilationDidStart,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isBackgroundCompiling = true
            }
        }
        NotificationCenter.default.addObserver(
            forName: .compilationDidEnd,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isBackgroundCompiling = false
            }
        }
    }

    // MARK: - Load Memos

    /// Loads today's memos from the raw storage file and checks compiled status.
    func load() {
        isLoading = true
        errorMessage = nil

        do {
            let loaded = try RawStorage.read(for: date)
            // Newest first
            memos = loaded.sorted { $0.created > $1.created }
        } catch {
            errorMessage = "加载失败：\(error.localizedDescription)"
            memos = []
        }

        checkDailyPage()
        isLoading = false
    }

    // MARK: - Add Photo Attachment (staged, not yet submitted)

    /// Processes a selected PhotosPickerItem and stages it in pendingAttachments.
    /// Does NOT submit a memo — user must tap the submit button.
    func addPhotoAttachment(item: PhotosPickerItem) {
        isProcessingPhoto = true
        submitError = nil

        Task {
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

    /// Opens the voice recording sheet.
    func startVoiceRecording() {
        isShowingVoiceRecorder = true
    }

    /// Opens the camera capture sheet.
    func startCameraCapture() {
        isShowingCamera = true
    }

    /// Whether the document picker sheet is presented.
    @Published var isShowingDocumentPicker: Bool = false

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
        Task {
            defer { isProcessingPhoto = false }
            guard let result = photoService.processImageData(data) else {
                submitError = "照片处理失败，请重试"
                return
            }
            pendingAttachments.append(.photo(result))
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

        Task {
            defer { isSubmitting = false }

            let weatherString = await weatherService.currentWeather(at: loc)

            // Derive location from first photo EXIF if no pending location
            var memoLocation: Memo.Location? = loc
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
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    memos.insert(memo, at: 0)
                }
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                pendingLocation = nil
                pendingAttachments = []
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

        Task {
            defer { isLocating = false }
            do {
                let loc = try await locationService.currentLocation(timeout: 3)
                pendingLocation = loc
            } catch LocationError.denied {
                submitError = locationService.authorizationStatus == .denied
                    ? "定位权限被拒绝，请在「设置 → 隐私 → 定位服务」中授权"
                    : "无法获取位置权限"
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

    /// Clears any pending location so it won't be attached to the next memo.
    func clearPendingLocation() {
        pendingLocation = nil
    }

    // MARK: - Compile Trigger

    private var compilationTask: Task<Void, Never>?

    /// Triggers manual AI compilation for today's memos.
    /// Shows BannerCenter progress/retry/success/failure banners.
    func compile() {
        guard !isCompiling else { return }
        isCompiling = true
        submitError = nil

        BannerCenter.shared.show(AppBannerModel(kind: .progress, title: "正在编译你的今天..."))

        compilationTask = Task {
            defer {
                isCompiling = false
                compilationTask = nil
            }

            // Slow-network subtitle upgrade after 5 seconds
            let slowTask = Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if !Task.isCancelled {
                    let current = BannerCenter.shared.currentBanner
                    if current?.kind == .progress {
                        BannerCenter.shared.show(AppBannerModel(
                            kind: .progress,
                            title: "正在编译你的今天...",
                            subtitle: "网络较慢，请稍候..."
                        ))
                    }
                }
            }

            // Cancel button after 15 seconds
            let cancelTask = Task {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if !Task.isCancelled {
                    let current = BannerCenter.shared.currentBanner
                    if current?.kind == .progress {
                        let self_ = self
                        BannerCenter.shared.show(AppBannerModel(
                            kind: .progress,
                            title: "正在编译你的今天...",
                            subtitle: "请稍候，或取消后稍后重试",
                            secondaryAction: BannerAction(label: "取消") {
                                self_.compilationTask?.cancel()
                            }
                        ))
                    }
                }
            }

            do {
                try await compilationService.compile(for: date, trigger: "manual") { attempt, maxAttempts in
                    BannerCenter.shared.show(AppBannerModel(
                        kind: .progress,
                        title: "正在编译你的今天...",
                        subtitle: "正在重试（\(attempt)/\(maxAttempts)）..."
                    ))
                }
                slowTask.cancel()
                cancelTask.cancel()
                checkDailyPage()
                await OnThisDayIndex.shared.rebuildIndex()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                BannerCenter.shared.show(AppBannerModel(
                    kind: .success,
                    title: "今日 Daily Page 已生成",
                    autoDismiss: true
                ))
            } catch CompilationError.offline {
                slowTask.cancel()
                cancelTask.cancel()
                BannerCenter.shared.show(AppBannerModel(
                    kind: .info,
                    title: "当前离线，已加入队列",
                    autoDismiss: true
                ))
            } catch CompilationError.missingApiKey {
                slowTask.cancel()
                cancelTask.cancel()
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                BannerCenter.shared.show(AppBannerModel(
                    kind: .error,
                    title: "DashScope API Key 未配置",
                    primaryAction: BannerAction(label: "前往设置") { }
                ))
            } catch CompilationError.apiError(let code, _) where code == 401 {
                slowTask.cancel()
                cancelTask.cancel()
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                BannerCenter.shared.show(AppBannerModel(
                    kind: .error,
                    title: "API Key 无效或已过期",
                    primaryAction: BannerAction(label: "前往设置") { }
                ))
            } catch CompilationError.parseError {
                slowTask.cancel()
                cancelTask.cancel()
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                BannerCenter.shared.show(AppBannerModel(
                    kind: .error,
                    title: "AI 返回格式异常",
                    primaryAction: BannerAction(label: "查看日志") { }
                ))
            } catch {
                slowTask.cancel()
                cancelTask.cancel()
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                let self_ = self
                BannerCenter.shared.show(AppBannerModel(
                    kind: .error,
                    title: "编译失败：网络不稳定",
                    primaryAction: BannerAction(label: "立即重试") {
                        self_.compile()
                    },
                    secondaryAction: BannerAction(label: "稍后自动重试") {
                        BannerCenter.shared.dismiss()
                    }
                ))
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
            dailyPageSummary = extractSummary(from: content)
        } catch {
            DayPageLogger.shared.error("TodayViewModel: read daily: \(error)")
        }
    }

    private func dailyPageURL(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let dateStr = formatter.string(from: date)
        return VaultInitializer.vaultURL
            .appendingPathComponent("wiki")
            .appendingPathComponent("daily")
            .appendingPathComponent("\(dateStr).md")
    }

    /// Parses the `summary:` frontmatter field from a Daily Page file.
    private func extractSummary(from content: String) -> String? {
        let lines = content.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("summary:") {
                let value = String(trimmed.dropFirst("summary:".count))
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}
