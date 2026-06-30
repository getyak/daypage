// MemoSyncUploader.swift — 真实 iOS → Web memo 上传器 (issue #785)
//
// 接通此前空转的同步链路: SyncQueueObserver 持有一个 RemoteUploader,过去只有
// NoopRemoteUploader（假上传）。本文件提供真实实现:
//
//   memoID → 扫 vault/raw/*.md 找到对应 Memo → 映射成 web bulk JSON →
//   POST {baseURL}/api/memos/bulk（Authorization: Bearer <apiKey>）
//
// 鉴权: web 端的 /api/memos/bulk 接受用户在 web Settings 生成的 `write` scope
// API key（详见 docs/ios-web-sync-design.md）。key 的 user_id 决定 memo 落到
// 哪个 web 账号,无需 Supabase↔NextAuth 桥接。
//
// 附件: 第一期只同步元数据（transcript / duration / kind / 路径引用），不传
// 文件字节。
//
// 映射逻辑拆成纯函数 `MemoSyncMapper.bulkItem(from:vaultPath:)` 以便单测,不依赖
// 网络或文件系统。

import Foundation
import DayPageModels

// MARK: - Errors

public enum MemoSyncError: LocalizedError {
    case notConfigured
    case insecureScheme
    case memoNotFound(String)
    case invalidResponse
    case unauthorized          // 401 — key 无效/过期
    case forbidden             // 403 — key 缺 write scope
    case rateLimited(retryAfter: Int)
    case serverError(status: Int)
    case rejected(reason: String)   // server skipped this memo

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "同步未配置"
        case .insecureScheme: return "同步地址必须使用 https"
        case .memoNotFound(let id): return "找不到 memo \(id)"
        case .invalidResponse: return "服务器响应无法解析"
        case .unauthorized: return "API Key 无效或已过期"
        case .forbidden: return "API Key 缺少 write 权限"
        case .rateLimited(let s): return "请求过于频繁,请 \(s) 秒后再试"
        case .serverError(let code): return "服务器错误 (\(code))"
        case .rejected(let reason): return "memo 被服务器拒绝: \(reason)"
        }
    }
}

// MARK: - Mapper (pure, testable)

/// Pure transformations from the iOS `Memo` model to the web bulk-sync JSON
/// shape. No I/O — every input is passed in, so this is trivially unit-testable.
public enum MemoSyncMapper {

    /// Map an iOS `MemoType` to the web schema's enum. The web schema only
    /// knows text/url/voice/photo/file, so iOS-only cases collapse to `text`.
    public static func webType(for type: Memo.MemoType) -> String {
        switch type {
        case .text: return "text"
        case .voice: return "voice"
        case .photo: return "photo"
        case .location: return "text"   // web has no location type
        case .mixed: return "text"       // web has no mixed type
        }
    }

    /// Build the `attachments` array for the bulk payload. Metadata only —
    /// `storage_key` carries the iOS relative path as a reference; the bytes
    /// are not uploaded in this phase.
    public static func attachments(from memo: Memo) -> [[String: Any]] {
        memo.attachments.map { att in
            var dict: [String: Any] = [
                // web schema enum: audio|photo|file. iOS uses audio|photo.
                "kind": att.kind,
                "storage_key": att.file,
            ]
            if let duration = att.duration {
                dict["duration_sec"] = duration
            }
            if let transcript = att.transcript, !transcript.isEmpty {
                dict["transcript"] = transcript
            }
            return dict
        }
    }

    /// Build one bulk JSON item from a memo. `vaultPath` is the relative path of
    /// the .md file the memo lives in (for `vault_path` traceability); pass nil
    /// when unknown.
    ///
    /// `body` is forced non-empty because the web schema requires `min(1)`:
    /// a pure voice/photo memo with no text falls back to its first transcript,
    /// then to a localized placeholder.
    public static func bulkItem(from memo: Memo, vaultPath: String?) -> [String: Any] {
        let iso = ISO8601DateFormatter.memo
        let createdISO = iso.string(from: memo.created)
        // updated_at drives the server's last-write-wins; a pinned memo's pin
        // time is the most recent meaningful mutation we track, else created.
        let updatedISO = iso.string(from: memo.pinnedAt ?? memo.created)

        var item: [String: Any] = [
            "id": memo.id.uuidString.lowercased(),
            "type": webType(for: memo.type),
            "body": nonEmptyBody(for: memo),
            "created_at": createdISO,
            "updated_at": updatedISO,
            "origin": "ios",
            "idempotency_key": memo.id.uuidString.lowercased(),
        ]

        if let vaultPath, !vaultPath.isEmpty {
            item["vault_path"] = vaultPath
        }
        if let device = memo.device, !device.isEmpty {
            item["device"] = device
        }
        if let mood = memo.mood, !mood.isEmpty {
            item["mood"] = mood
        }
        // iOS weather is a free-form string; web schema is an object — wrap it.
        if let weather = memo.weather, !weather.isEmpty {
            item["weather"] = ["condition": weather]
        }
        if let loc = memo.location {
            var locDict: [String: Any] = [:]
            if let lat = loc.lat { locDict["lat"] = lat }
            if let lng = loc.lng { locDict["lng"] = lng }
            if let name = loc.name, !name.isEmpty { locDict["address"] = name }
            if !locDict.isEmpty { item["location"] = locDict }
        }
        let atts = attachments(from: memo)
        if !atts.isEmpty {
            item["attachments"] = atts
        }
        return item
    }

    /// Web requires a non-empty body. Prefer the memo's own text; for media-only
    /// memos fall back to the first non-empty transcript, then a placeholder.
    public static func nonEmptyBody(for memo: Memo) -> String {
        let trimmed = memo.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return memo.body }
        if let transcript = memo.attachments
            .compactMap({ $0.transcript })
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return transcript
        }
        return "(无文字)"
    }
}

// MARK: - Uploader

/// Production `RemoteUploader`. Resolves config from `SyncSettings` at call
/// time (so the user can configure sync without an app restart), looks the memo
/// up in the vault, maps it, and POSTs it. Returns the uploaded byte size for
/// the queue's telemetry.
public struct MemoSyncUploader: RemoteUploader {

    /// Injectable transport so tests can supply canned responses.
    public let transport: HTTPTransport

    init(transport: HTTPTransport = HTTPTransports.shared) {
        self.transport = transport
    }

    public func upload(memoID: String) async throws -> Int {
        guard let endpoint = SyncSettings.bulkEndpoint,
              let apiKey = SyncSettings.apiKey, !apiKey.isEmpty else {
            throw MemoSyncError.notConfigured
        }

        // Only allow plaintext http in DEBUG (dogfood on a LAN). Release builds
        // must use https so the bearer key never crosses the wire in the clear.
        #if !DEBUG
        if endpoint.scheme?.lowercased() != "https" {
            throw MemoSyncError.insecureScheme
        }
        #endif

        guard let (memo, vaultPath) = Self.findMemo(byID: memoID) else {
            // The memo no longer exists in the vault (e.g. user deleted it
            // before it synced). Don't wedge the queue on a ghost — surface a
            // typed error and let the caller decide to drop it.
            throw MemoSyncError.memoNotFound(memoID)
        }

        let item = MemoSyncMapper.bulkItem(from: memo, vaultPath: vaultPath)
        let payload: [String: Any] = ["memos": [item]]

        let request = try HTTPClientHelper.bearerJSON(
            url: endpoint,
            apiKey: apiKey,
            timeout: 30,
            body: payload
        )

        let (data, response) = try await transport.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw MemoSyncError.invalidResponse
        }

        switch http.statusCode {
        case 200...299:
            try Self.assertAccepted(memoID: memoID, responseData: data)
            // Report the payload byte size for the queue's running tally.
            return (try? JSONSerialization.data(withJSONObject: payload).count) ?? 0
        case 401:
            throw MemoSyncError.unauthorized
        case 403:
            throw MemoSyncError.forbidden
        case 429:
            let retry = Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            throw MemoSyncError.rateLimited(retryAfter: retry)
        default:
            throw MemoSyncError.serverError(status: http.statusCode)
        }
    }

    // MARK: Response parsing

    /// The bulk endpoint returns `{ accepted: [...], skipped: [{id, reason}] }`.
    /// Treat a memo that landed in `skipped` (or in neither list) as a failure
    /// so the queue retries rather than silently dropping it.
    public static func assertAccepted(memoID: String, responseData: Data) throws {
        let lowerID = memoID.lowercased()
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw MemoSyncError.invalidResponse
        }
        let accepted = (json["accepted"] as? [String])?.map { $0.lowercased() } ?? []
        if accepted.contains(lowerID) { return }

        if let skipped = json["skipped"] as? [[String: Any]],
           let mine = skipped.first(where: { ($0["id"] as? String)?.lowercased() == lowerID }) {
            let reason = (mine["reason"] as? String) ?? "unknown"
            throw MemoSyncError.rejected(reason: reason)
        }
        // Not in accepted and not in skipped — server didn't process it.
        throw MemoSyncError.rejected(reason: "not acknowledged by server")
    }

    // MARK: Vault lookup

    /// Find the memo whose frontmatter `id` matches `memoID` by scanning
    /// vault/raw/*.md. Returns the memo plus its vault-relative path. O(N files)
    /// but only runs once per memo upload (and the queue is small); mirrors the
    /// existing `SyncQueueService.estimateMemoSize` scan.
    public static func findMemo(byID memoID: String) -> (Memo, String)? {
        let rawDir = VaultInitializer.vaultURL.appendingPathComponent("raw", isDirectory: true)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: rawDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let target = memoID.lowercased()
        // Fast-path filter: only fully parse files whose text mentions the id.
        for file in files where file.pathExtension == "md" {
            guard let content = try? String(contentsOf: file, encoding: .utf8),
                  content.lowercased().contains(target) else { continue }
            let memos = RawStorage.parse(fileContent: content, sourceFile: file)
            if let memo = memos.first(where: { $0.id.uuidString.lowercased() == target }) {
                let relPath = "raw/" + file.lastPathComponent
                return (memo, relPath)
            }
        }
        return nil
    }
}
