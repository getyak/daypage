import Foundation
import SwiftUI
import PhotosUI
import UIKit
import DayPageStorage
import DayPageServices

// MARK: - FeedbackStatus

enum FeedbackStatus: Equatable {
    case idle
    case sending
    case submitted(issueURL: String)
    case error(String)
}

// MARK: - SubmittedIssue

struct SubmittedIssue: Codable, Identifiable {
    let number: Int
    let url: String
    let title: String
    let date: Date

    var id: Int { number }
}

// MARK: - PendingFeedbackImage

struct PendingFeedbackImage: Identifiable {
    let id: String = UUID().uuidString
    let data: Data
    let thumbnail: UIImage
    /// Filename used when uploading to GitHub. Generated once at staging time
    /// so re-uploads (after retry) keep a stable path.
    let filename: String
}

// MARK: - FeedbackViewModel

@MainActor
final class FeedbackViewModel: ObservableObject {

    // MARK: - Published State

    @Published var rawFeedback: String = ""
    /// Explicit per-draft choice; technical context is omitted by default.
    @Published var includeDiagnostics: Bool = false
    @Published var status: FeedbackStatus = .idle
    @Published var submittedIssues: [SubmittedIssue] = []

    /// Whether the half-screen VoiceRecordingView sheet is presented.
    /// A single tap on the mic flips this true; the sheet handles
    /// pause/resume/save and returns a transcript via `handleVoiceRecordingComplete`.
    @Published var isShowingVoiceRecorder: Bool = false

    /// Pending image attachments (uploaded only at submit time).
    @Published var pendingImages: [PendingFeedbackImage] = []
    @Published private(set) var imageProcessingCount = 0
    @Published private(set) var sendInFlight = false
    private var draftGeneration = UUID()
    private(set) var voiceGeneration: UUID?
    var isProcessingImage: Bool { imageProcessingCount > 0 }

    /// Voice recording mirror, exposed so the view can render an overlay.
    @Published var pressToTalkPhase: PressToTalkPhase = .idle

    private let submittedIssuesKey = "submittedIssues"

    // MARK: - Dependencies

    let voiceService = VoiceService.shared
    private var capturedContext: FeedbackContext?
    private let createIssue: @MainActor (String, String, [String]) async throws -> GitHubIssue
    private let uploadImage: @MainActor (Data, String) async throws -> String

    var diagnosticsPreview: String {
        let context = capturedContext ?? FeedbackContext.capture()
        capturedContext = context
        return context.promptDescription
    }

    // MARK: - Computed

    var isSending: Bool {
        sendInFlight
    }
    var errorMessage: String? {
        if case .error(let msg) = status { return msg }
        return nil
    }

    // MARK: - Init

    init(
        createIssue: @escaping @MainActor (String, String, [String]) async throws -> GitHubIssue = {
            try await FeedbackService.shared.createIssueViaBot(title: $0, body: $1, labels: $2)
        },
        uploadImage: @escaping @MainActor (Data, String) async throws -> String = {
            try await FeedbackService.shared.uploadFeedbackImage(data: $0, filename: $1)
        }
    ) {
        self.createIssue = createIssue
        self.uploadImage = uploadImage
        loadSubmittedIssues()
    }

    // MARK: - Send (instant — backend triage takes over)

    /// Submit flow: capture context → upload images → create GitHub issue
    /// labelled `triage`. The kubbot Feedback Triage Bot workflow picks it up
    /// server-side and rewrites title/body/labels via DeepSeek, so the user
    /// sees a confirmation in well under a second instead of waiting on AI.
    func send() async {
        guard !isSending, !isProcessingImage else { return }
        let trimmed = rawFeedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !pendingImages.isEmpty else {
            status = .error(NSLocalizedString("feedback.error.empty", comment: ""))
            return
        }

        HapticFeedback.medium()

        sendInFlight = true
        defer { sendInFlight = false }
        status = .sending
        // Freeze the choice before suspension. A later toggle cannot change
        // the payload of an upload already in progress.
        let diagnosticPayload = includeDiagnostics ? diagnosticsPreview : nil
        let imagesToUpload = pendingImages

        let rawText = trimmed.isEmpty ? "(no text — see attached screenshots)" : trimmed
        let title = Self.makeProvisionalTitle(from: rawText)

        // Upload images (best effort — image upload failure shouldn't block
        // the issue itself, but we surface a warning by appending a note).
        var imageMarkdown = ""
        var uploadedAll = true
        for image in imagesToUpload {
            do {
                let url = try await uploadImage(image.data, image.filename)
                imageMarkdown += "\n\n![\(image.filename)](\(url))"
            } catch {
                uploadedAll = false
                DayPageLogger.shared.error("feedback: image upload failed: \(error)")
            }
        }

        var body = "## Raw feedback\n\n\(rawText)"
        if let diagnosticPayload {
            body += "\n\n---\n\n<details><summary>Diagnostic context</summary>\n\n```\n\(diagnosticPayload)\n```\n\n</details>"
        }
        if !imageMarkdown.isEmpty {
            body += "\n\n## Screenshots" + imageMarkdown
        }
        if !imagesToUpload.isEmpty && !uploadedAll {
            body += "\n\n> ⚠️ Some screenshots failed to upload."
        }

        do {
            let issue = try await createIssue(title, body, ["triage"])
            let submitted = SubmittedIssue(
                number: issue.number,
                url: issue.htmlURL,
                title: title,
                date: Date()
            )
            submittedIssues.insert(submitted, at: 0)
            persistSubmittedIssues()
            HapticFeedback.success()
            status = .submitted(issueURL: issue.htmlURL)
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    /// First non-empty line, truncated to 80 chars (with ellipsis when cut).
    /// The triage workflow rewrites this server-side, so it just has to be
    /// good enough for the user to recognize the issue in their list.
    private static func makeProvisionalTitle(from text: String) -> String {
        let firstLine = text
            .split(whereSeparator: { $0.isNewline })
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let source = firstLine.isEmpty
            ? text.trimmingCharacters(in: .whitespacesAndNewlines)
            : firstLine
        if source.count <= 80 { return source }
        let cutoff = source.index(source.startIndex, offsetBy: 79)
        return String(source[..<cutoff]) + "…"
    }

    // MARK: - Voice (Whisper press-to-talk)

    /// Called by PressToTalkButton when the user starts a long-press.
    func voicePressStart() {
        guard prepareVoiceStart() else { return }
        let generation = draftGeneration
        voiceGeneration = generation
        Task {
            guard !self.isSending, self.draftGeneration == generation,
                  self.voiceGeneration == generation,
                  self.voiceService.state == .idle else { return }
            await self.voiceService.startRecording(purpose: .feedback)
        }
    }

    /// A shared recording or pending transcription must finish before another
    /// feedback recording starts. Failed permission/ASR attempts remain retryable.
    private func prepareVoiceStart() -> Bool {
        guard !isSending, !isShowingVoiceRecorder else { return false }
        if case .failed = voiceService.state { voiceService.cancelRecording() }
        return voiceService.state == .idle
    }

    /// Long-press release in the default zone — transcribe via Whisper and
    /// fill the input field. We deliberately do NOT auto-submit; the user
    /// can still tweak the wording before sending.
    func voiceReleaseSendAsTranscript() {
        guard !isSending else { return }
        Task { await consumeRecordingAsTranscript() }
    }

    /// Long-press release after the user dragged into the cancel zone.
    func voiceReleaseCancel() {
        voiceService.cancelRecording()
    }

    /// Long-press release after the user dragged into the transcribe-armed
    /// zone — same behaviour as the default in this screen (fill draft, no
    /// submit).
    func voiceReleaseTranscribe() {
        guard !isSending else { return }
        Task { await consumeRecordingAsTranscript() }
    }

    /// Short tap — open the half-screen voice recorder sheet. Mirrors the
    /// TodayView input bar so users get pause/resume/save instead of a
    /// press-to-talk gesture.
    func startVoiceRecording() {
        guard prepareVoiceStart() else { return }
        voiceGeneration = draftGeneration
        isShowingVoiceRecorder = true
    }

    /// Dismiss the recorder sheet without keeping any audio.
    func cancelVoiceRecording() {
        voiceService.cancelRecording()
        isShowingVoiceRecorder = false
    }

    /// Recorder sheet finished — append the transcript to the feedback draft.
    /// Only the transcript is attached to feedback; VoiceService deletes its
    /// transient recording after transcription and never queues a diary retry.
    func handleVoiceRecordingComplete(result: VoiceRecordingResult, generation: UUID? = nil) {
        guard let generation = generation ?? voiceGeneration,
              generation == draftGeneration else { return }
        isShowingVoiceRecorder = false
        defer { if generation == draftGeneration { voiceService.reset() } }
        guard !isSending else { return }
        if let text = result.transcript?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            if rawFeedback.isEmpty {
                rawFeedback = text
            } else {
                rawFeedback += " " + text
            }
        } else {
            status = .error(NSLocalizedString("feedback.error.voice", comment: ""))
        }
    }

    private func consumeRecordingAsTranscript() async {
        guard !isSending, let generation = voiceGeneration,
              generation == draftGeneration else { return }
        guard let result = await voiceService.stopAndTranscribe() else { return }
        guard generation == draftGeneration else { return }
        defer { if generation == draftGeneration { voiceService.reset() } }
        guard !isSending else { return }
        if let text = result.transcript, !text.isEmpty {
            if rawFeedback.isEmpty {
                rawFeedback = text
            } else {
                rawFeedback += " " + text
            }
        } else {
            status = .error(NSLocalizedString("feedback.error.voice", comment: ""))
        }
    }

    // MARK: - Image Attachments

    func addImages(from items: [PhotosPickerItem]) async {
        guard !isSending else { return }
        let generation = draftGeneration
        imageProcessingCount += 1
        defer { if generation == draftGeneration { imageProcessingCount -= 1 } }
        for item in items {
            guard generation == draftGeneration else { return }
            await addImageData { try await item.loadTransferable(type: Data.self) }
        }
    }

    /// Shared importer keeps overlapping loads and reset lifetimes separate.
    func addImageData(load: () async throws -> Data?) async {
        guard !isSending else { return }
        let generation = draftGeneration
        imageProcessingCount += 1
        defer { if generation == draftGeneration { imageProcessingCount -= 1 } }
        let data = try? await load()
        guard generation == draftGeneration, !isSending else { return }
        guard let data, let thumb = UIImage(data: data) else {
            status = .error(NSLocalizedString("feedback.error.image.load", comment: ""))
            return
        }
        appendImage(data: data, thumbnail: thumb)
    }

    func addCameraImage(_ image: UIImage) {
        guard !isSending else { return }
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            status = .error(NSLocalizedString("feedback.error.image.encode", comment: ""))
            return
        }
        appendImage(data: data, thumbnail: image)
    }

    private func appendImage(data: Data, thumbnail: UIImage) {
        let stamp = DateFormatter.feedbackImageStamp.string(from: Date())
        let suffix = UUID().uuidString.prefix(6)
        let filename = "IMG_\(stamp)_\(suffix).jpg"
        pendingImages.append(
            PendingFeedbackImage(data: data, thumbnail: thumbnail, filename: String(filename))
        )
    }

    func removeImage(id: String) {
        guard !isSending else { return }
        pendingImages.removeAll { $0.id == id }
    }

    // MARK: - Submitted Issues Persistence

    func loadSubmittedIssues() {
        guard let data = UserDefaults.standard.data(forKey: submittedIssuesKey),
              let issues = try? JSONDecoder().decode([SubmittedIssue].self, from: data) else { return }
        submittedIssues = issues
    }

    private func persistSubmittedIssues() {
        guard let data = try? JSONEncoder().encode(submittedIssues) else { return }
        UserDefaults.standard.set(data, forKey: submittedIssuesKey)
    }

    // MARK: - Reset

    func reset() {
        guard !isSending else { return }
        draftGeneration = UUID()
        voiceGeneration = nil
        isShowingVoiceRecorder = false
        imageProcessingCount = 0
        rawFeedback = ""
        includeDiagnostics = false
        pendingImages = []
        capturedContext = nil
        status = .idle
    }

}

// MARK: - Date helper

private extension DateFormatter {
    static let feedbackImageStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()
}
