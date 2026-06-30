import Foundation
import SwiftUI
import DayPageStorage
import DayPageServices

// MARK: - ThreadConversationViewModel

/// Drives a single question-and-answer thread embedded in a Daily Page.
/// Handles streaming AI replies and persists conversations to vault/threads/YYYY-MM-DD.md.
@MainActor
final class ThreadConversationViewModel: ObservableObject, Identifiable {

    // MARK: - Public identity

    let id: String
    let question: String?          // nil for freeform entries
    let compiledPageText: String
    let date: Date

    // MARK: - Message model

    struct Message: Identifiable {
        let id = UUID()
        let role: String           // "user" | "assistant"
        var text: String
    }

    // MARK: - Published state

    @Published var messages: [Message] = []
    @Published var streamingText: String = ""
    @Published var isStreaming: Bool = false
    @Published var error: String? = nil
    @Published var isExpanded: Bool = false

    // MARK: - Private formatters

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    private let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Init

    init(question: String?, compiledPageText: String, date: Date) {
        self.question = question
        self.compiledPageText = compiledPageText
        self.date = date
        // Stable ID: use question text for preset threads, UUID for freeform.
        self.id = question ?? UUID().uuidString
    }

    // MARK: - Load history

    /// Reads vault/threads/YYYY-MM-DD.md and restores the matching conversation block.
    func loadHistory() async {
        let fileURL = threadsFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }

        let questionKey = question ?? "(freeform)"
        let blocks = content
            .components(separatedBy: "\n\n---\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        for block in blocks {
            let blockQuestion = extractFrontmatterValue(key: "question", from: block)
            guard blockQuestion == questionKey else { continue }
            let parsed = parseMessages(from: block)
            if !parsed.isEmpty { messages = parsed }
            return
        }
    }

    // MARK: - Send

    /// Appends a user message and streams the AI reply.
    func send(userMessage: String) async {
        let trimmed = userMessage.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isStreaming else { return }

        messages.append(Message(role: "user", text: trimmed))
        error = nil

        let apiMessages = buildAPIMessages()
        do {
            try await streamReply(apiMessages: apiMessages)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Streaming reply

    private func streamReply(apiMessages: [[String: String]]) async throws {
        let apiKey = Secrets.resolvedDeepSeekApiKey
        guard !apiKey.isEmpty else { throw ThreadError.missingApiKey }

        let baseURL = Secrets.deepSeekBaseURL.isEmpty ? "https://api.deepseek.com/v1" : Secrets.deepSeekBaseURL
        let model = Secrets.deepSeekModel.isEmpty ? "deepseek-chat" : Secrets.deepSeekModel

        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw ThreadError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        var allMessages: [[String: String]] = [["role": "system", "content": buildSystemPrompt()]]
        allMessages.append(contentsOf: apiMessages)

        let body: [String: Any] = [
            "model": model,
            "messages": allMessages,
            "max_tokens": 512,
            "temperature": 0.8,
            "stream": true
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        isStreaming = true
        streamingText = ""
        // Guarantee cleanup on every exit path — success, throw, or cancellation.
        defer {
            isStreaming = false
            streamingText = ""
        }

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ThreadError.apiError(statusCode: http.statusCode)
        }

        for try await line in asyncBytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }

            guard let jsonData = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let chunk = delta["content"] as? String else { continue }

            streamingText += chunk
        }

        // Capture before defer clears it.
        let finalText = streamingText

        if !finalText.isEmpty {
            messages.append(Message(role: "assistant", text: finalText))
        }
        persist()
    }

    // MARK: - Persist

    /// Writes this thread's block into vault/threads/YYYY-MM-DD.md,
    /// replacing a previous block with the same question if one exists.
    private func persist() {
        guard !messages.isEmpty else { return }

        let fileURL = threadsFileURL()
        let dir = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let questionKey = question ?? "(freeform)"
        let newBlock = serializeBlock()

        var blocks = (try? String(contentsOf: fileURL, encoding: .utf8))?
            .components(separatedBy: "\n\n---\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ?? []

        var replaced = false
        for i in blocks.indices {
            if extractFrontmatterValue(key: "question", from: blocks[i]) == questionKey {
                blocks[i] = newBlock
                replaced = true
                break
            }
        }
        if !replaced { blocks.append(newBlock) }

        let combined = blocks.joined(separator: "\n\n---\n\n")
        try? RawStorage.atomicWrite(string: combined, to: fileURL)
    }

    // MARK: - File URL

    private func threadsFileURL() -> URL {
        let dateString = dateFormatter.string(from: date)
        return VaultInitializer.vaultURL
            .appendingPathComponent("threads")
            .appendingPathComponent("\(dateString).md")
    }

    // MARK: - Serialisation / parsing

    private func serializeBlock() -> String {
        let questionKey = question ?? "(freeform)"
        let timestamp = iso8601Formatter.string(from: Date())
        var lines = ["---", "question: \(questionKey)", "timestamp: \(timestamp)", "---"]
        for msg in messages {
            let roleLabel = msg.role == "assistant" ? "ai" : "user"
            lines.append("\(roleLabel): \(msg.text)")
        }
        return lines.joined(separator: "\n")
    }

    private func parseMessages(from block: String) -> [Message] {
        var result: [Message] = []
        var closingDelimiters = 0

        for line in block.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "---" { closingDelimiters += 1; continue }
            guard closingDelimiters >= 2 else { continue }

            if t.hasPrefix("user: ") {
                result.append(Message(role: "user", text: String(t.dropFirst(6))))
            } else if t.hasPrefix("ai: ") {
                result.append(Message(role: "assistant", text: String(t.dropFirst(4))))
            }
        }
        return result
    }

    private func extractFrontmatterValue(key: String, from block: String) -> String? {
        let prefix = "\(key): "
        for line in block.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(prefix) { return String(t.dropFirst(prefix.count)) }
        }
        return nil
    }

    // MARK: - API helpers

    private func buildAPIMessages() -> [[String: String]] {
        messages.map { msg in
            ["role": msg.role == "assistant" ? "assistant" : "user", "content": msg.text]
        }
    }

    private func buildSystemPrompt() -> String {
        let dateString = dateFormatter.string(from: date)
        let maxChars = 3_000
        let pageText = compiledPageText.count > maxChars
            ? String(compiledPageText.prefix(maxChars)) + "..."
            : compiledPageText

        return """
        你是用户的个人反思助手。以下是用户今天（\(dateString)）的日记内容：

        \(pageText)

        请基于日记内容回答用户的追问。回答简洁、有温度，100字以内。用第二人称（"你"）。不要重复问题本身。
        """
    }
}

// MARK: - ThreadError

private enum ThreadError: LocalizedError {
    case missingApiKey
    case invalidURL
    case apiError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .missingApiKey:      return "AI Key 未配置"
        case .invalidURL:         return "API URL 无效"
        case .apiError(let code): return "API 错误 \(code)"
        }
    }
}
