import Foundation

// MARK: - FeedbackError

enum FeedbackError: LocalizedError {
    case networkError(String)
    case authError
    case rateLimitError
    case unknownError(Int, String)

    var errorDescription: String? {
        switch self {
        case .networkError(let msg): return "Network error: \(msg)"
        case .authError: return "GitHub authentication failed. Please try again later."
        case .rateLimitError: return "GitHub API rate limit exceeded. Try again later."
        case .unknownError(let code, let body): return "GitHub API error \(code): \(body.prefix(200))"
        }
    }
}

// MARK: - GitHubIssue

struct GitHubIssue: Decodable {
    let number: Int
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case number
        case htmlURL = "html_url"
    }
}

// MARK: - GitHubLabel

struct GitHubLabel: Decodable {
    let name: String
    let color: String
}

// MARK: - FeedbackService

@MainActor
final class FeedbackService {

    static let shared = FeedbackService()
    private init() {}

    private let apiBase = "https://api.github.com"
    private static let botToken: String = Secrets.kubotGitHubToken
    private static let botOwner = "getyak"
    private static let botRepo  = "daypage"

    /// URLSession that waits for connectivity instead of failing fast when
    /// the device briefly drops off the network mid-submit. Combined with
    /// the longer `timeoutInterval` on each request this lets the issue
    /// creation survive lock-screen / app-switch / spotty-wifi moments.
    private static let resilientSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    // MARK: - Create Issue via Bot (zero-config)

    /// Posts a new issue using the embedded bot token to the hardcoded repo.
    /// No user-supplied credentials required.
    func createIssueViaBot(title: String, body: String, labels: [String]) async throws -> GitHubIssue {
        return try await createIssue(
            title: title,
            body: body,
            labels: labels,
            token: FeedbackService.botToken,
            owner: FeedbackService.botOwner,
            repo: FeedbackService.botRepo
        )
    }

    // MARK: - Create Issue

    /// Posts a new issue to the given GitHub repo.
    /// - Returns: The created `GitHubIssue` with number and HTML URL.
    func createIssue(
        title: String,
        body: String,
        labels: [String],
        token: String,
        owner: String,
        repo: String
    ) async throws -> GitHubIssue {
        guard NetworkMonitor.shared.isOnline else {
            throw FeedbackError.networkError("offline")
        }
        guard let url = repoURL(owner: owner, repo: repo, path: "issues") else {
            throw FeedbackError.networkError("Invalid repo URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120

        let payload: [String: Any] = [
            "title": title,
            "body": body,
            "labels": labels
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await FeedbackService.resilientSession.data(for: request)
        try validateGitHubResponse(data: data, response: response)

        return try JSONDecoder().decode(GitHubIssue.self, from: data)
    }

    // MARK: - Upload Feedback Image

    /// Uploads a JPEG (or any binary) to the bot repo via the GitHub Contents
    /// API and returns the public `download_url`. Path: `feedback-assets/<filename>`.
    /// On 422 (path collision) we retry once with a `_<6char>` suffix before giving up.
    func uploadFeedbackImage(data: Data, filename: String) async throws -> String {
        return try await uploadFeedbackImageOnce(
            data: data,
            filename: filename,
            allowRename: true
        )
    }

    private func uploadFeedbackImageOnce(
        data: Data,
        filename: String,
        allowRename: Bool
    ) async throws -> String {
        guard NetworkMonitor.shared.isOnline else {
            throw FeedbackError.networkError("offline")
        }

        let path = "feedback-assets/\(filename)"
        guard let url = repoURL(
            owner: FeedbackService.botOwner,
            repo: FeedbackService.botRepo,
            path: "contents/\(path)"
        ) else {
            throw FeedbackError.networkError("Invalid repo URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("token \(FeedbackService.botToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let payload: [String: Any] = [
            "message": "feedback: upload \(filename)",
            "content": data.base64EncodedString()
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FeedbackError.networkError("No HTTP response")
        }

        // 422 = path already exists. Retry once with a fresh suffix.
        if http.statusCode == 422 && allowRename {
            let renamed = renameWithSuffix(filename)
            return try await uploadFeedbackImageOnce(data: data, filename: renamed, allowRename: false)
        }
        guard http.statusCode == 200 || http.statusCode == 201 else {
            let body = String(data: respData, encoding: .utf8) ?? ""
            throw FeedbackError.unknownError(http.statusCode, body)
        }

        guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let content = json["content"] as? [String: Any],
              let downloadURL = content["download_url"] as? String else {
            throw FeedbackError.networkError("Upload response missing download_url")
        }
        return downloadURL
    }

    private func renameWithSuffix(_ filename: String) -> String {
        let suffix = UUID().uuidString.prefix(6)
        if let dot = filename.lastIndex(of: ".") {
            let stem = filename[..<dot]
            let ext = filename[dot...]
            return "\(stem)_\(suffix)\(ext)"
        }
        return "\(filename)_\(suffix)"
    }

    // MARK: - List Labels

    /// Returns all labels defined on the given repo.
    func listRepoLabels(token: String, owner: String, repo: String) async throws -> [GitHubLabel] {
        guard NetworkMonitor.shared.isOnline else {
            throw FeedbackError.networkError("offline")
        }
        guard let baseURL = repoURL(owner: owner, repo: repo, path: "labels") else {
            throw FeedbackError.networkError("Invalid repo URL")
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw FeedbackError.networkError("Invalid repo URL")
        }
        components.queryItems = [URLQueryItem(name: "per_page", value: "100")]
        guard let url = components.url else {
            throw FeedbackError.networkError("Invalid repo URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateGitHubResponse(data: data, response: response)

        return try JSONDecoder().decode([GitHubLabel].self, from: data)
    }

    // MARK: - URL Builder

    /// Builds a GitHub API URL with URLComponents so owner/repo are percent-encoded
    /// and cannot escape the intended path via traversal sequences.
    private func repoURL(owner: String, repo: String, path: String) -> URL? {
        guard var components = URLComponents(string: apiBase) else { return nil }
        let encoded = [owner, repo, path].map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0
        }
        components.path = "/repos/\(encoded[0])/\(encoded[1])/\(encoded[2])"
        return components.url
    }

    // MARK: - Response Validation

    private func validateGitHubResponse(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw FeedbackError.networkError("No HTTP response")
        }
        switch http.statusCode {
        case 200, 201:
            return
        case 401, 403:
            throw FeedbackError.authError
        case 429:
            throw FeedbackError.rateLimitError
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw FeedbackError.unknownError(http.statusCode, body)
        }
    }
}
