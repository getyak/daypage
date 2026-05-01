import Foundation
import SwiftUI
import PhotosUI
import UIKit

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
    @Published var status: FeedbackStatus = .idle
    @Published var submittedIssues: [SubmittedIssue] = []

    /// Whether the half-screen VoiceRecordingView sheet is presented.
    /// A single tap on the mic flips this true; the sheet handles
    /// pause/resume/save and returns a transcript via `handleVoiceRecordingComplete`.
    @Published var isShowingVoiceRecorder: Bool = false

    /// Pending image attachments (uploaded only at submit time).
    @Published var pendingImages: [PendingFeedbackImage] = []
    @Published var isProcessingImage: Bool = false

    /// Voice recording mirror, exposed so the view can render an overlay.
    @Published var pressToTalkPhase: PressToTalkPhase = .idle

    private let submittedIssuesKey = "submittedIssues"

    // MARK: - Dependencies

    let voiceService = VoiceService.shared
    private var capturedContext: FeedbackContext?

    // MARK: - Computed

    var isIdle: Bool { status == .idle }
    var isSending: Bool {
        if case .sending = status { return true }
        return false
    }
    var submittedIssueURL: String? {
        if case .submitted(let url) = status { return url }
        return nil
    }
    var errorMessage: String? {
        if case .error(let msg) = status { return msg }
        return nil
    }

    // MARK: - Init

    init() {
        loadSubmittedIssues()
    }

    // MARK: - Send (instant — backend triage takes over)

    /// Submit flow: capture context → upload images → create GitHub issue
    /// labelled `triage`. The kubbot Feedback Triage Bot workflow picks it up
    /// server-side and rewrites title/body/labels via DeepSeek, so the user
    /// sees a confirmation in well under a second instead of waiting on AI.
    func send() async {
        let trimmed = rawFeedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !pendingImages.isEmpty else {
            status = .error("Please describe your feedback or attach a screenshot.")
            return
        }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        status = .sending
        let context = capturedContext ?? FeedbackContext.capture()
        capturedContext = context

        let rawText = trimmed.isEmpty ? "(no text — see attached screenshots)" : trimmed
        let title = Self.makeProvisionalTitle(from: rawText)

        // Upload images (best effort — image upload failure shouldn't block
        // the issue itself, but we surface a warning by appending a note).
        var imageMarkdown = ""
        var uploadedAll = true
        for image in pendingImages {
            do {
                let url = try await FeedbackService.shared.uploadFeedbackImage(
                    data: image.data,
                    filename: image.filename
                )
                imageMarkdown += "\n\n![\(image.filename)](\(url))"
            } catch {
                uploadedAll = false
                DayPageLogger.shared.error("feedback: image upload failed: \(error)")
            }
        }

        var body = "## Raw feedback\n\n\(rawText)"
        body += "\n\n---\n\n<details><summary>📱 Diagnostic context</summary>\n\n```\n\(context.promptDescription)\n```\n\n</details>"
        if !imageMarkdown.isEmpty {
            body += "\n\n## Screenshots" + imageMarkdown
        }
        if !pendingImages.isEmpty && !uploadedAll {
            body += "\n\n> ⚠️ Some screenshots failed to upload."
        }

        do {
            let issue = try await FeedbackService.shared.createIssueViaBot(
                title: title,
                body: body,
                labels: ["triage"]
            )
            let submitted = SubmittedIssue(
                number: issue.number,
                url: issue.htmlURL,
                title: title,
                date: Date()
            )
            submittedIssues.insert(submitted, at: 0)
            persistSubmittedIssues()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
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
        Task { await voiceService.startRecording() }
    }

    /// Long-press release in the default zone — transcribe via Whisper and
    /// fill the input field. We deliberately do NOT auto-submit; the user
    /// can still tweak the wording before sending.
    func voiceReleaseSendAsTranscript() {
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
        Task { await consumeRecordingAsTranscript() }
    }

    /// Short tap — open the half-screen voice recorder sheet. Mirrors the
    /// TodayView input bar so users get pause/resume/save instead of a
    /// press-to-talk gesture.
    func startVoiceRecording() {
        isShowingVoiceRecorder = true
    }

    /// Dismiss the recorder sheet without keeping any audio.
    func cancelVoiceRecording() {
        voiceService.cancelRecording()
        isShowingVoiceRecorder = false
    }

    /// Recorder sheet finished — append the transcript to the feedback draft.
    /// The audio file itself is discarded; feedback is text-only.
    func handleVoiceRecordingComplete(result: VoiceRecordingResult) {
        isShowingVoiceRecorder = false
        defer { voiceService.reset() }
        if let text = result.transcript?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            if rawFeedback.isEmpty {
                rawFeedback = text
            } else {
                rawFeedback += " " + text
            }
        } else {
            status = .error("Voice transcription failed. Check your network or OpenAI Whisper key.")
        }
    }

    private func consumeRecordingAsTranscript() async {
        guard let result = await voiceService.stopAndTranscribe() else { return }
        defer { voiceService.reset() }
        if let text = result.transcript, !text.isEmpty {
            if rawFeedback.isEmpty {
                rawFeedback = text
            } else {
                rawFeedback += " " + text
            }
        } else {
            status = .error("Voice transcription failed. Check your network or OpenAI Whisper key.")
        }
    }

    // MARK: - Image Attachments

    func addImage(from item: PhotosPickerItem) async {
        isProcessingImage = true
        defer { isProcessingImage = false }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let thumb = UIImage(data: data) else {
            status = .error("Could not load that image.")
            return
        }
        appendImage(data: data, thumbnail: thumb)
    }

    func addCameraImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            status = .error("Could not encode that photo.")
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
        rawFeedback = ""
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
