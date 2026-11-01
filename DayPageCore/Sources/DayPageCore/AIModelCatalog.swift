import Foundation

public struct AIModelOption: Identifiable, Equatable, Sendable {
  public let id: String
  public let name: String
  public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct AIModelCatalog: Sendable {
  /// Persisted in the existing model field; never sent as a provider model ID.
  public static let automaticModel = "__daypage_automatic_general_model__"
  private let transport: AITransport
  public init() { transport = AITransport() }
  init(transport: AITransport) { self.transport = transport }

  public func resolve(configuration: AIConfiguration, apiKey: String) async throws -> AIConfiguration {
    _ = try configuration.endpoint
    _ = try AITransport.key(apiKey, configuration: configuration)
    guard configuration.model.trimmingCharacters(in: .whitespacesAndNewlines) == Self.automaticModel else {
      return configuration
    }
    guard AIProvider.matching(configuration: configuration).supportsAutomaticModels else {
      throw AIError.modelDiscoveryUnavailable
    }
    guard let model = try await models(configuration: configuration, apiKey: apiKey).first else { throw AIError.noModels }
    var resolved = configuration
    resolved.model = model.id
    return resolved
  }

  public func models(configuration: AIConfiguration, apiKey: String) async throws -> [AIModelOption] {
    let provider = AIProvider.matching(configuration: configuration)
    _ = try AITransport.key(apiKey, configuration: configuration)
    var components = try configuration.validatedComponents(checkTransport: true)
    if provider == .glm { throw AIError.modelDiscoveryUnavailable }
    if provider == .qwen {
      // Documented production rolling aliases, not a claim of live account access.
      // https://help.aliyun.com/zh/model-studio/model-depreciation
      // https://help.aliyun.com/zh/dataphin/semimanaged-v4/user-guide/untitled-document-1753169796047
      return ["qwen-max-latest", "qwen-plus-latest", "qwen-turbo-latest"].map {
        AIModelOption(id: $0, name: $0)
      }
    }
    var path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    for suffix in ["/chat/completions", "/messages"] where path.hasSuffix(suffix) {
      path.removeLast(suffix.count)
    }
    // This authenticated catalog honors the user's routing/privacy guardrails.
    // https://openrouter.ai/docs/api/api-reference/models/list-models-filtered-by-user-provider-preferences-privacy-settings-and-guardrails
    components.path = "/" + (path.isEmpty ? "v1" : path) + (provider == .openRouter ? "/models/user" : "/models")
    if provider == .anthropic {
      // Official cursor API; never follow arbitrary model-provided origins.
      // https://platform.claude.com/docs/en/api/models/list
      components.queryItems = [URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "lifecycle", value: "active")]
    }
    guard let initialURL = components.url else { throw AIError.configuration }
    var url = initialURL
    var visited = Set<String>()
    var entries: [Entry] = []
    var totalBytes = 0
    for _ in 0..<4 {
      guard visited.insert(url.absoluteString).inserted else { throw AIError.invalidResponse }
      var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
      request.httpMethod = "GET"
      try AITransport.authorize(&request, configuration: configuration, apiKey: apiKey)
      let data = try await transport.data(for: request)
      totalBytes += data.count
      guard totalBytes <= 4 * 1024 * 1024 else { throw AIError.tooLarge }
      guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let models = payload["data"] as? [[String: Any]], models.count <= 2000,
        entries.count + models.count <= 2000 else { throw AIError.invalidResponse }
      entries += models.compactMap { entry($0, provider: provider) }
      var nextURL: URL?
      if let rawLinks = payload["links"], !(rawLinks is NSNull), !(rawLinks is [String: Any]) {
        throw AIError.invalidResponse
      }
      if let rawNext = (payload["links"] as? [String: Any])?["next"], !(rawNext is NSNull) {
        guard let next = rawNext as? String, !next.isEmpty,
          let parsed = URL(string: next, relativeTo: url)?.absoluteURL else { throw AIError.invalidResponse }
        nextURL = parsed
      } else if payload["has_more"] as? Bool == true {
        guard provider == .anthropic, let cursor = payload["last_id"] as? String,
          !cursor.isEmpty, cursor.count <= 256 else { throw AIError.invalidResponse }
        var next = components
        next.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "after_id", value: cursor)]
        nextURL = next.url
      }
      guard let next = nextURL else {
        let sorted = entries.sorted { precedes($0, $1, provider: provider) }
        var ids = Set<String>()
        let options = sorted.filter { ids.insert($0.option.id).inserted }.map(\.option)
        guard !options.isEmpty else { throw AIError.noModels }
        return options
      }
      guard let target = URLComponents(url: next, resolvingAgainstBaseURL: false),
        let origin = URLComponents(url: initialURL, resolvingAgainstBaseURL: false),
        target.scheme == origin.scheme, target.host == origin.host, target.port == origin.port,
        target.path == origin.path, target.user == nil, target.password == nil, target.fragment == nil else {
        throw AIError.invalidResponse
      }
      url = next
    }
    throw AIError.tooLarge
  }

  private struct Entry {
    let option: AIModelOption
    let created: TimeInterval
    let tier: Int
  }
  private func entry(_ item: [String: Any], provider: AIProvider) -> Entry? {
    guard var id = item["id"] as? String, !id.isEmpty, id.count <= 256,
      !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
    if provider == .gemini, id.hasPrefix("models/") { id.removeFirst(7) }
    let lower = id.lowercased()
    let excluded = ["preview", "experimental", "-exp", "deprecated", "retired", "embedding", "rerank",
      "moderation", "audio", "tts", "transcri", "whisper", "realtime", "image", "video", "ocr",
      "codex", "coder", "-code", "coding", "cyber", "rosalind"]
    guard !excluded.contains(where: lower.contains), item["deprecated"] as? Bool != true,
      item["lifecycle"] as? String == nil || item["lifecycle"] as? String == "active" else { return nil }
    if let output = item["output_modalities"] as? [String], !output.contains("text") { return nil }
    if let architecture = item["architecture"] as? [String: Any],
      let output = architecture["output_modalities"] as? [String], output != ["text"] { return nil }
    if provider == .openRouter {
      if let endpoints = item["endpoints"] as? [String], !endpoints.contains("/api/v1/chat/completions") { return nil }
      if let expiration = item["expiration_date"] as? String {
        let formatter = ISO8601DateFormatter()
        var date = formatter.date(from: expiration)
        if date == nil { formatter.formatOptions = [.withFullDate]; date = formatter.date(from: expiration) }
        guard let expiry = date, expiry > Date() else { return nil }
      }
    }
    switch provider {
    case .openAI:
      guard lower.range(of: "^gpt-[456](?:[.\\-]|$)", options: .regularExpression) != nil else { return nil }
    case .anthropic:
      guard lower.hasPrefix("claude-") else { return nil }
    case .gemini:
      guard lower.range(of: "^gemini-[0-9]", options: .regularExpression) != nil else { return nil }
    case .deepSeek:
      guard lower.hasPrefix("deepseek-") else { return nil }
    case .kimi:
      // Retired aliases are explicitly listed by Kimi; discovery remains live.
      // https://platform.kimi.ai/docs/models
      guard lower.range(of: "^kimi-k[23](?:[.\\-]|$)", options: .regularExpression) != nil,
        !["kimi-k2.5", "kimi-latest"].contains(lower) else { return nil }
    case .openRouter:
      let supported = ["openai/gpt-", "anthropic/claude-", "google/gemini-", "deepseek/deepseek-",
                       "qwen/qwen", "moonshotai/kimi-k", "z-ai/glm-"]
      guard supported.contains(where: lower.hasPrefix), !lower.contains(":") else { return nil }
    case .custom: break
    case .qwen, .glm: return nil
    }
    var tier = 2
    if ["mini", "nano", "luna", "lite", "haiku", "turbo", "highspeed"].contains(where: lower.contains) { tier = 1 }
    if provider == .openAI, lower.contains("astra") { tier = 3 }
    if provider == .gemini, lower.contains("pro") { tier = 3 }
    if provider == .deepSeek, lower == "deepseek-flash" { tier = 4 }
    if provider == .kimi, lower.contains("-pro"), !lower.contains("highspeed") { tier = 3 }
    let date = (item["created_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0)?.timeIntervalSince1970 }
    let created = date ?? (item["created"] as? NSNumber)?.doubleValue ?? 0
    let name = item["display_name"] as? String ?? item["name"] as? String ?? id
    return Entry(option: .init(id: id, name: String(name.prefix(200))), created: created, tier: tier)
  }
  private func precedes(_ a: Entry, _ b: Entry, provider: AIProvider) -> Bool {
    // Selection policy: full general-purpose lines before budget variants;
    // release time for Claude/OpenRouter, semantic model version elsewhere.
    // Sources provide availability/release metadata, not a universal quality score.
    if a.tier != b.tier { return a.tier > b.tier }
    if (provider == .anthropic || provider == .openRouter), a.created != b.created { return a.created > b.created }
    let comparison = a.option.id.compare(b.option.id, options: [.numeric, .caseInsensitive])
    if comparison != .orderedSame { return comparison == .orderedDescending }
    return a.created > b.created
  }
}
