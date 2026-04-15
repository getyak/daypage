import Foundation
import SwiftUI
import UIKit
import CoreLocation
import PhotosUI

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

    /// Pending photo results (can accumulate before submission, cleared after).
    @Published var pendingPhotos: [PhotoPickerResult] = []

    /// Whether the voice recording sheet is presented.
    @Published var isShowingVoiceRecorder: Bool = false

    // MARK: Private

    private let date: Date
    private let locationService = LocationService.shared
    private let weatherService = WeatherService.shared
    private let photoService = PhotoService.shared
    private let voiceService = VoiceService.shared

    // MARK: Init

    init(date: Date = Date()) {
        self.date = date
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

    // MARK: - Submit Text Memo

    /// Creates and persists a text memo from the given body string.
    /// Automatically attaches timestamp, device info, pending location, and weather if available.
    func submitTextMemo(body: String) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSubmitting = true
        submitError = nil

        let loc = pendingLocation

        Task {
            defer { isSubmitting = false }

            // Fetch weather asynchronously; non-blocking — nil if unavailable
            let weatherString = await weatherService.currentWeather(at: loc)

            let memo = Memo(
                type: .text,
                created: Date(),
                location: loc,
                weather: weatherString,   // US-006: auto-attached weather
                device: deviceDescription(),
                attachments: [],
                body: trimmed
            )

            do {
                try RawStorage.append(memo)
                // Insert at front (newest first)
                memos.insert(memo, at: 0)
                // Clear pending location after use
                pendingLocation = nil
            } catch {
                submitError = "保存失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - Submit Photo Memo

    /// Processes a selected PhotosPickerItem, saves to vault/raw/assets/, and submits a photo memo.
    /// The optional caption becomes the memo body.
    func submitPhotoMemo(item: PhotosPickerItem, caption: String = "") {
        isProcessingPhoto = true
        submitError = nil

        let loc = pendingLocation

        Task {
            defer { isProcessingPhoto = false }

            guard let result = await photoService.processPickerItem(item) else {
                submitError = "照片处理失败，请重试"
                return
            }

            // Build attachment from EXIF
            let attachment = buildPhotoAttachment(from: result)

            // Fetch weather non-blocking
            let weatherString = await weatherService.currentWeather(at: loc)

            // Derive location from EXIF GPS if no pending location
            var memoLocation: Memo.Location? = loc
            if memoLocation == nil, let lat = result.exif?.gpsLat, let lng = result.exif?.gpsLng {
                memoLocation = Memo.Location(name: nil, lat: lat, lng: lng)
            }

            let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
            let memo = Memo(
                type: .photo,
                created: result.exif?.capturedAt ?? Date(),
                location: memoLocation,
                weather: weatherString,
                device: deviceDescription(),
                attachments: [attachment],
                body: trimmedCaption
            )

            do {
                try RawStorage.append(memo)
                memos.insert(memo, at: 0)
                pendingLocation = nil
            } catch {
                submitError = "照片 memo 保存失败：\(error.localizedDescription)"
            }
        }
    }

    /// Clears all pending photos without submitting.
    func clearPendingPhotos() {
        pendingPhotos = []
    }

    // MARK: - Submit Voice Memo

    /// Called after VoiceRecordingView finishes recording and transcription.
    /// Attaches the audio file as an attachment, weather + location as metadata,
    /// and the transcript as the memo body.
    func submitVoiceMemo(result: VoiceRecordingResult, caption: String = "") {
        isSubmitting = true
        submitError = nil

        let loc = pendingLocation

        Task {
            defer {
                isSubmitting = false
                voiceService.reset()
            }

            let weatherString = await weatherService.currentWeather(at: loc)

            let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = trimmedCaption.isEmpty ? (result.transcript ?? "") : trimmedCaption

            let attachment = Memo.Attachment(
                file: result.filePath,
                kind: "audio",
                duration: result.duration,
                transcript: result.transcript
            )

            let memo = Memo(
                type: .voice,
                created: Date(),
                location: loc,
                weather: weatherString,
                device: deviceDescription(),
                attachments: [attachment],
                body: body
            )

            do {
                try RawStorage.append(memo)
                memos.insert(memo, at: 0)
                pendingLocation = nil
            } catch {
                submitError = "语音 memo 保存失败：\(error.localizedDescription)"
            }
        }
    }

    /// Opens the voice recording sheet.
    func startVoiceRecording() {
        isShowingVoiceRecorder = true
    }

    /// Dismisses the voice recording sheet without saving.
    func cancelVoiceRecording() {
        voiceService.cancelRecording()
        isShowingVoiceRecorder = false
    }

    // MARK: - Private Photo Helpers

    private func buildPhotoAttachment(from result: PhotoPickerResult) -> Memo.Attachment {
        var exifParts: [String] = []
        if let ap = result.exif?.aperture { exifParts.append("aperture=\(ap)") }
        if let ss = result.exif?.shutterSpeed { exifParts.append("shutter=\(ss)") }
        if let iso = result.exif?.iso { exifParts.append(iso) }
        if let fl = result.exif?.focalLength { exifParts.append(fl) }
        // Encode EXIF summary as transcript field (reused for photo metadata in this schema)
        let exifSummary = exifParts.isEmpty ? nil : exifParts.joined(separator: " ")
        return Memo.Attachment(
            file: result.filePath,
            kind: "photo",
            duration: nil,
            transcript: exifSummary
        )
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

    // MARK: - Compile Trigger (placeholder)

    /// Triggers manual compilation (placeholder until US-014 is implemented).
    func compile() {
        // Implemented in US-014 / US-010.
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
        if let content = try? String(contentsOf: dailyURL, encoding: .utf8) {
            dailyPageSummary = extractSummary(from: content)
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
