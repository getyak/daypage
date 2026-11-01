import Foundation

public struct AIProviderEndpoint: Identifiable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let baseURL: String
  public let keyURL: URL?
  init(_ id: String, _ name: String, _ baseURL: String, _ keyURL: String) {
    self.id = id; self.name = name; self.baseURL = baseURL; self.keyURL = URL(string: keyURL)
  }
}

/// Official direct API endpoints. Regions are separate credential origins.
/// https://ai.google.dev/gemini-api/docs/openai
/// https://help.aliyun.com/zh/model-studio/compatibility-of-openai-with-dashscope
/// https://platform.kimi.com/docs/get-api-key
/// https://docs.z.ai/guides/develop/openai/python
public enum AIProvider: String, CaseIterable, Identifiable, Sendable {
  case openAI, anthropic, gemini, deepSeek, qwen, kimi, glm, openRouter, custom
  public var id: String { rawValue }
  public var name: String {
    switch self {
    case .openAI: return "OpenAI"
    case .anthropic: return "Claude"
    case .gemini: return "Gemini"
    case .deepSeek: return "DeepSeek"
    case .qwen: return "Qwen"
    case .kimi: return "Kimi"
    case .glm: return "GLM"
    case .openRouter: return "OpenRouter"
    case .custom: return "Custom"
    }
  }
  public var requiresAPIKey: Bool { self != .custom }
  public var supportsAutomaticModels: Bool { self != .glm && self != .custom }
  public var endpoints: [AIProviderEndpoint] {
    switch self {
    case .openAI:
      return [.init("default", "OpenAI", "https://api.openai.com/v1", "https://platform.openai.com/api-keys")]
    case .anthropic:
      return [.init("default", "Claude", "https://api.anthropic.com/v1", "https://platform.claude.com/settings/keys")]
    case .gemini:
      return [.init("default", "Gemini", "https://generativelanguage.googleapis.com/v1beta/openai", "https://aistudio.google.com/apikey")]
    case .deepSeek:
      return [.init("default", "DeepSeek", "https://api.deepseek.com/v1", "https://platform.deepseek.com/api_keys")]
    case .qwen:
      return [
        .init("china", "China (Beijing)", "https://dashscope.aliyuncs.com/compatible-mode/v1", "https://bailian.console.aliyun.com/?tab=model#/api-key"),
        .init("singapore", "Singapore", "https://dashscope-intl.aliyuncs.com/compatible-mode/v1", "https://bailian.console.aliyun.com/?tab=model#/api-key"),
      ]
    case .kimi:
      return [
        .init("china", "China", "https://api.moonshot.cn/v1", "https://platform.kimi.com/console/api-keys"),
        .init("international", "International", "https://api.moonshot.ai/v1", "https://platform.kimi.ai/console/api-keys"),
      ]
    case .glm:
      return [
        .init("china", "China", "https://open.bigmodel.cn/api/paas/v4", "https://bigmodel.cn/usercenter/proj-mgmt/apikeys"),
        .init("international", "International", "https://api.z.ai/api/paas/v4", "https://z.ai/manage-apikey/apikey-list"),
      ]
    case .openRouter:
      return [.init("default", "OpenRouter", "https://openrouter.ai/api/v1", "https://openrouter.ai/settings/keys")]
    case .custom: return []
    }
  }
  public var baseURL: String { endpoints.first?.baseURL ?? "" }
  public var keyURL: URL? { endpoints.first?.keyURL }
  public var configuration: AIConfiguration {
    // No verified GLM discovery API/rolling alias exists in its official API
    // contract. This is explicitly fixed, not a claim of automatic updates.
    // https://docs.z.ai/guides/overview/migrate-to-glm-new
    AIConfiguration(baseURL: baseURL,
      model: self == .custom ? "" : self == .glm ? "glm-5.3" : AIModelCatalog.automaticModel,
      usesAPIKey: requiresAPIKey)
  }

  public static func matching(configuration: AIConfiguration) -> AIProvider {
    guard let candidate = try? configuration.validatedComponents(checkTransport: false),
      candidate.scheme == "https" else { return .custom }
    func canonical(_ components: URLComponents) -> String? {
      var value = components
      if value.port == 443 { value.port = nil }
      let path = value.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      value.path = "/" + (path.isEmpty ? "v1" : path)
      return value.string
    }
    let address = canonical(candidate)
    for provider in allCases where provider != .custom {
      for endpoint in provider.endpoints {
        guard let components = URLComponents(string: endpoint.baseURL), let base = canonical(components) else { continue }
        let suffix = provider == .anthropic ? "/messages" : "/chat/completions"
        if address == base || address == base + suffix { return provider }
      }
    }
    return .custom
  }
}
