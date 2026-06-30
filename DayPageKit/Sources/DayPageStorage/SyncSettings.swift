// SyncSettings.swift — iOS → Web 同步配置 (issue #785)
//
// 持有 iOS 把 memo 推送到 web 端所需的两项配置:
//   - baseURL: web 服务地址（如 https://daypage.app 或 dogfood 的局域网地址）
//   - apiKey:  用户在 web Settings → API Keys 生成的 `write` scope key
//
// 设计要点:
//   - apiKey 是凭证,存 Keychain（复用 KeychainHelper.setAPIKey/getAPIKey），
//     绝不落 UserDefaults / 日志 / Sentry。
//   - baseURL 非敏感,存 UserDefaults。
//   - 两者任一为空 → `isConfigured == false`,上传层降级为 noop（不报错、不卡队列）。
//   - 这是 web 端 API Key Bearer 鉴权方案的客户端侧（详见 docs/ios-web-sync-design.md）。

import Foundation

/// Process-wide accessor for the iOS→web sync configuration. Pure value reads
/// so it can be used from any actor; writes go through UserDefaults / Keychain
/// which are themselves thread-safe.
public enum SyncSettings {

    // MARK: - Keys

    /// Keychain identifier for the sync API key. Distinct from the AI-provider
    /// keys managed elsewhere so revoking one never touches the other.
    public static let apiKeyIdentifier = "memoSyncApiKey"

    /// UserDefaults key for the web base URL.
    private static let baseURLKey = "sync.web.baseURL"

    // MARK: - Base URL

    /// The configured web base URL string, or nil/empty when unset. Trailing
    /// slashes are trimmed so callers can always append `/api/...` cleanly.
    public static var baseURLString: String? {
        get {
            let raw = UserDefaults.standard.string(forKey: baseURLKey) ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : normalizeBaseURL(trimmed)
        }
        set {
            let trimmed = (newValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: baseURLKey)
            } else {
                UserDefaults.standard.set(normalizeBaseURL(trimmed), forKey: baseURLKey)
            }
        }
    }

    /// The resolved bulk-sync endpoint URL, or nil when no/invalid base URL is
    /// configured. Centralised here so the uploader and any future puller agree
    /// on the path.
    public static var bulkEndpoint: URL? {
        guard let base = baseURLString, let url = URL(string: base + "/api/memos/bulk") else {
            return nil
        }
        return url
    }

    // MARK: - API Key

    /// The configured API key, or nil when unset/empty.
    public static var apiKey: String? {
        get { KeychainHelper.getAPIKey(for: apiKeyIdentifier) }
        set {
            let trimmed = (newValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                KeychainHelper.deleteAPIKey(for: apiKeyIdentifier)
            } else {
                KeychainHelper.setAPIKey(trimmed, for: apiKeyIdentifier)
            }
        }
    }

    // MARK: - State

    /// True only when both an endpoint and a key are present. The sync layer
    /// uses this to decide whether to install a real uploader or stay on the
    /// noop double.
    public static var isConfigured: Bool {
        bulkEndpoint != nil && (apiKey?.isEmpty == false)
    }

    // MARK: - Helpers

    /// Strip a trailing slash and, when no scheme is present, default to https.
    /// Dogfood users on a LAN can paste `192.168.x.x:3000` and get a usable
    /// `https://…`; to use plain http they must type the scheme explicitly,
    /// which the uploader gates behind a DEBUG check.
    public static func normalizeBaseURL(_ input: String) -> String {
        var s = input
        while s.hasSuffix("/") { s.removeLast() }
        if !s.contains("://") {
            s = "https://" + s
        }
        return s
    }
}
