import Foundation
import SwiftUI
import PhotosUI
import UIKit

// MARK: - FeedbackStatus

enum FeedbackStatus: Equatable {
    case idle
    /// Single combined "AI summarize + GitHub submit" loading state — the
    /// user sees one spinner instead of two stages.
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

    /// Toast: "Hold to record" — shown on a short tap of the mic.
    @Published var showHoldToRecordToast: Bool = false

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

    // MARK: - Send (AI Summary + Submit, single step)

    /// Combined flow: capture context → ask AI to compose issue → upload images
    /// → create GitHub issue. The UI sees one `.sending` state for the whole
    /// chain so the user isn't asked to confirm AI output.
    func send() async {
        let trimmed = rawFeedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !pendingImages.isEmpty else {
            status = .error("Please describe your feedback or attach a screenshot.")
            return
        }

        status = .sending
        let context = capturedContext ?? FeedbackContext.capture()
        capturedContext = context

        // 1. AI summarize
        let summary: AIIssueSummary
        do {
            summary = try await callDeepSeekForSummary(
                feedback: trimmed.isEmpty ? "(no text — see attached screenshots)" : trimmed,
                context: context
            )
        } catch {
            status = .error(error.localizedDescription)
            return
        }

        // 2. Upload images (best effort — image upload failure shouldn't block
        //    the issue itself, but we surface a warning by appending a note).
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

        // 3. Compose final body: AI body + context block + screenshots
        var body = summary.body
        body += "\n\n---\n\n<details><summary>📱 Diagnostic context</summary>\n\n```\n\(context.promptDescription)\n```\n\n</details>"
        if !imageMarkdown.isEmpty {
            body += "\n\n## Screenshots" + imageMarkdown
        }
        if !pendingImages.isEmpty && !uploadedAll {
            body += "\n\n> ⚠️ Some screenshots failed to upload."
        }

        // 4. Create issue
        do {
            let issue = try await FeedbackService.shared.createIssueViaBot(
                title: summary.title,
                body: body,
                labels: summary.labels
            )
            let submitted = SubmittedIssue(
                number: issue.number,
                url: issue.htmlURL,
                title: summary.title,
                date: Date()
            )
            submittedIssues.insert(submitted, at: 0)
            persistSubmittedIssues()
            status = .submitted(issueURL: issue.htmlURL)
        } catch {
            status = .error(error.localizedDescription)
        }
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

    /// Short tap — show "Hold to record" hint.
    func voiceShortTap() {
        showHoldToRecordToast = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            self.showHoldToRecordToast = false
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

    // MARK: - DeepSeek Call

    fileprivate struct AIIssueSummary {
        let title: String
        let body: String
        let labels: [String]
    }

    private func callDeepSeekForSummary(
        feedback: String,
        context: FeedbackContext
    ) async throws -> AIIssueSummary {
        let apiKey = Secrets.resolvedDeepSeekApiKey
        guard !apiKey.isEmpty else {
            throw FeedbackError.networkError("DeepSeek API key is not configured.")
        }

        let baseURL = Secrets.deepSeekBaseURL.isEmpty
            ? "https://api.deepseek.com/v1"
            : Secrets.deepSeekBaseURL
        let model = Secrets.deepSeekModel.isEmpty ? "deepseek-v4-pro" : Secrets.deepSeekModel

        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw FeedbackError.networkError("Invalid API URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let systemPrompt = """
        You are DayPage's feedback triage assistant. The user is reporting a bug or
        requesting an improvement. You are given the raw feedback text AND a block
        of diagnostic context (app version, OS, device, user id, etc.). Your job:

        1. Decide whether this is a bug, feature request, or improvement.
        2. Write a short, specific issue title (≤ 80 chars). Do NOT include the
           version number in the title — it goes in the body.
        3. Compose a Markdown body using the appropriate sections:
             - Bug:         ## Description, ## Steps to Reproduce, ## Expected, ## Actual, ## Environment
             - Feature:     ## Problem, ## Proposed Solution, ## Why
             - Improvement: ## Current behaviour, ## Suggested change, ## Why
           Always include an "## Environment" section that lists the relevant
           subset of the diagnostic context (app version, OS, device — user id
           only if it helps reproduce). Don't dump the whole context block — the
           app appends a verbatim copy below your output.
        4. Pick 1–2 labels from: ["bug", "enhancement", "improvement"].

        Output ONLY a JSON object:
        {
          "title": "...",
          "body":  "...",
          "labels": ["bug"]
        }
        No prose outside the JSON. No markdown fences around the JSON.
        """

        let userMessage = """
        --- USER FEEDBACK ---
        \(feedback)

        --- DIAGNOSTIC CONTEXT ---
        \(context.promptDescription)
        """

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage]
            ],
            "max_tokens": 1024,
            "temperature": 0.4
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw FeedbackError.networkError("No HTTP response")
        }
        guard http.statusCode == 200 else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw FeedbackError.unknownError(http.statusCode, bodyStr)
        }

        return try parseAISummary(from: data)
    }

    private func parseAISummary(from data: Data) throws -> AIIssueSummary {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw FeedbackError.networkError("Unexpected API response structure")
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Tolerate models that wrap JSON in ```json fences.
        let jsonString: String
        if let fenceStart = trimmed.range(of: "```json\n"),
           let fenceEnd = trimmed.range(of: "\n```", range: fenceStart.upperBound ..< trimmed.endIndex) {
            jsonString = String(trimmed[fenceStart.upperBound ..< fenceEnd.lowerBound])
        } else if let braceStart = trimmed.firstIndex(of: "{"),
                  let braceEnd = trimmed.lastIndex(of: "}") {
            jsonString = String(trimmed[braceStart ... braceEnd])
        } else {
            throw FeedbackError.networkError("AI response did not contain valid JSON")
        }

        guard let jsonData = jsonString.data(using: .utf8),
              let parsed = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw FeedbackError.networkError("Failed to parse AI JSON response")
        }

        let title = (parsed["title"] as? String) ?? ""
        let bodyText = (parsed["body"] as? String) ?? ""
        let labels = (parsed["labels"] as? [String]) ?? []

        guard !title.isEmpty else {
            throw FeedbackError.networkError("AI returned empty issue title")
        }

        return AIIssueSummary(title: title, body: bodyText, labels: labels)
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
