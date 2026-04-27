import Foundation

// MARK: - FeedbackStatus

enum FeedbackStatus: Equatable {
    case idle
    case summarizing
    case ready
    case submitting
    case submitted(issueURL: String)
    case error(String)
}

// MARK: - FeedbackViewModel

@MainActor
final class FeedbackViewModel: ObservableObject {

    // MARK: - Published State

    @Published var rawFeedback: String = ""
    @Published var aiTitle: String = ""
    @Published var aiBody: String = ""
    @Published var aiLabels: [String] = []
    @Published var status: FeedbackStatus = .idle

    // MARK: - Repo Config (UserDefaults)

    var repoOwner: String {
        get { UserDefaults.standard.string(forKey: AppSettings.githubRepoOwnerKey) ?? "cubxxw" }
        set { UserDefaults.standard.set(newValue, forKey: AppSettings.githubRepoOwnerKey) }
    }

    var repoName: String {
        get { UserDefaults.standard.string(forKey: AppSettings.githubRepoNameKey) ?? "daypage" }
        set { UserDefaults.standard.set(newValue, forKey: AppSettings.githubRepoNameKey) }
    }

    // MARK: - Token (Keychain)

    var githubToken: String {
        get { KeychainHelper.get(forKey: "githubToken") ?? "" }
        set { KeychainHelper.set(newValue, forKey: "githubToken") }
    }

    // MARK: - Computed

    var isIdle: Bool { status == .idle }
    var isSummarizing: Bool { status == .summarizing }
    var isReady: Bool { status == .ready }
    var isSubmitting: Bool { status == .submitting }

    var submittedIssueURL: String? {
        if case .submitted(let url) = status { return url }
        return nil
    }

    var errorMessage: String? {
        if case .error(let msg) = status { return msg }
        return nil
    }

    // MARK: - AI Summarize

    func summarizeWithAI() async {
        guard !rawFeedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = .error("Please enter some feedback before summarizing.")
            return
        }

        status = .summarizing

        let apiKey = Secrets.resolvedDeepSeekApiKey
        guard !apiKey.isEmpty else {
            status = .error("DeepSeek API key is not configured. Set it in Settings.")
            return
        }

        do {
            let result = try await callDeepSeekForSummary(feedback: rawFeedback, apiKey: apiKey)
            aiTitle = result.title
            aiBody = result.body
            aiLabels = result.labels
            status = .ready
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    // MARK: - Submit to GitHub

    func submitToGitHub() async {
        let token = githubToken
        guard !token.isEmpty else {
            status = .error("GitHub token is not set. Add it below.")
            return
        }
        guard !repoOwner.isEmpty, !repoName.isEmpty else {
            status = .error("GitHub repo owner and name must be set.")
            return
        }
        guard !aiTitle.isEmpty else {
            status = .error("Issue title is empty. Run AI Summarize first.")
            return
        }

        status = .submitting

        do {
            let issue = try await FeedbackService.shared.createIssue(
                title: aiTitle,
                body: aiBody,
                labels: aiLabels,
                token: token,
                owner: repoOwner,
                repo: repoName
            )
            status = .submitted(issueURL: issue.htmlURL)
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    // MARK: - Reset

    func reset() {
        rawFeedback = ""
        aiTitle = ""
        aiBody = ""
        aiLabels = []
        status = .idle
    }

    // MARK: - Private: DeepSeek Call

    private struct AIIssueSummary {
        let title: String
        let body: String
        let labels: [String]
    }

    private func callDeepSeekForSummary(feedback: String, apiKey: String) async throws -> AIIssueSummary {
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
        You are DayPage's feedback assistant. Convert the user's raw feedback into a well-structured GitHub issue.
        Output ONLY a JSON object with exactly these fields:
        {
          "title": "<concise issue title, max 80 chars>",
          "body": "<markdown body with ## Description, ## Steps to Reproduce (if bug), ## Expected Behavior, ## Actual Behavior sections>",
          "labels": ["bug" or "enhancement" or "improvement" — pick one or two that fit best]
        }
        No extra text outside the JSON.
        """

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": feedback]
            ],
            "max_tokens": 1024,
            "temperature": 0.5
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

        // Extract JSON from possible markdown fences
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
