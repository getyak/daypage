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
        case .authError: return "Invalid GitHub token. Check your token in Settings."
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
        request.timeoutInterval = 30

        let payload: [String: Any] = [
            "title": title,
            "body": body,
            "labels": labels
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateGitHubResponse(data: data, response: response)

        return try JSONDecoder().decode(GitHubIssue.self, from: data)
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
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
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
