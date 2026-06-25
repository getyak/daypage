// MemoSyncUploaderTests.swift — iOS → Web 同步映射 + 上传逻辑测试 (issue #785)
//
// 三层覆盖:
//   1. MemoSyncMapper 纯函数:Memo → web bulk JSON 的字段映射（类型折叠、
//      weather 包装、空 body 回退、附件元数据、location 映射）。
//   2. assertAccepted 响应解析:accepted / skipped / 未确认 三种服务器响应。
//   3. SyncSettings 配置状态机:baseURL 归一化 + bulkEndpoint 拼接。
//
// 完整 upload() 的端到端走真机/模拟器联调（见 PR 描述），这里聚焦不依赖网络与
// 全局状态的纯逻辑,保证映射正确性可回归。

import Testing
import Foundation
@testable import DayPage

@Suite
struct MemoSyncMapperTests {

    /// Helper: a fully-populated text memo with a fixed UUID/date so assertions
    /// are deterministic.
    private func makeMemo(
        type: Memo.MemoType = .text,
        body: String = "Hello from iOS",
        weather: String? = nil,
        device: String? = nil,
        mood: String? = nil,
        location: Memo.Location? = nil,
        attachments: [Memo.Attachment] = []
    ) -> Memo {
        Memo(
            id: UUID(uuidString: "550E8400-E29B-41D4-A716-446655440001")!,
            type: type,
            created: Date(timeIntervalSince1970: 1_750_000_000), // fixed
            pinnedAt: nil,
            location: location,
            weather: weather,
            device: device,
            attachments: attachments,
            mood: mood,
            entityMentions: [],
            body: body
        )
    }

    @Test func mapsBasicTextMemo() {
        let item = MemoSyncMapper.bulkItem(from: makeMemo(), vaultPath: "raw/2025-06-15.md")
        #expect(item["id"] as? String == "550e8400-e29b-41d4-a716-446655440001")
        #expect(item["type"] as? String == "text")
        #expect(item["body"] as? String == "Hello from iOS")
        #expect(item["origin"] as? String == "ios")
        #expect(item["vault_path"] as? String == "raw/2025-06-15.md")
        #expect(item["idempotency_key"] as? String == "550e8400-e29b-41d4-a716-446655440001")
        // created_at must be ISO8601 with fractional seconds.
        let created = item["created_at"] as? String
        #expect(created?.contains("T") == true)
        #expect(created?.hasSuffix("Z") == true)
    }

    @Test func foldsIOSOnlyTypesToText() {
        #expect(MemoSyncMapper.webType(for: .text) == "text")
        #expect(MemoSyncMapper.webType(for: .voice) == "voice")
        #expect(MemoSyncMapper.webType(for: .photo) == "photo")
        // web schema has no location / mixed — both collapse to text.
        #expect(MemoSyncMapper.webType(for: .location) == "text")
        #expect(MemoSyncMapper.webType(for: .mixed) == "text")
    }

    @Test func wrapsWeatherStringIntoObject() {
        let item = MemoSyncMapper.bulkItem(from: makeMemo(weather: "Sunny ☀️"), vaultPath: nil)
        let weather = item["weather"] as? [String: Any]
        #expect(weather?["condition"] as? String == "Sunny ☀️")
    }

    @Test func omitsEmptyOptionalFields() {
        let item = MemoSyncMapper.bulkItem(from: makeMemo(weather: "", device: "", mood: ""), vaultPath: nil)
        // Empty strings must not be emitted (they'd fail / pollute the server).
        #expect(item["weather"] == nil)
        #expect(item["device"] == nil)
        #expect(item["mood"] == nil)
        #expect(item["location"] == nil)
        #expect(item["attachments"] == nil)
    }

    @Test func mapsLocation() {
        let loc = Memo.Location(name: "Paris", lat: 48.8566, lng: 2.3522)
        let item = MemoSyncMapper.bulkItem(from: makeMemo(location: loc), vaultPath: nil)
        let mapped = item["location"] as? [String: Any]
        #expect(mapped?["lat"] as? Double == 48.8566)
        #expect(mapped?["lng"] as? Double == 2.3522)
        #expect(mapped?["address"] as? String == "Paris")
    }

    @Test func emptyBodyFallsBackToTranscript() {
        let att = Memo.Attachment(
            file: "raw/assets/voice_x.m4a",
            kind: "audio",
            duration: 12.5,
            transcript: "spoken words here",
            transcriptionStatus: .done
        )
        let item = MemoSyncMapper.bulkItem(
            from: makeMemo(type: .voice, body: "   ", attachments: [att]),
            vaultPath: nil
        )
        // Web requires min(1) body; empty text falls back to the transcript.
        #expect(item["body"] as? String == "spoken words here")
    }

    @Test func emptyBodyNoTranscriptUsesPlaceholder() {
        let att = Memo.Attachment(
            file: "raw/assets/img.jpg", kind: "photo",
            duration: nil, transcript: nil, transcriptionStatus: nil
        )
        let item = MemoSyncMapper.bulkItem(
            from: makeMemo(type: .photo, body: "", attachments: [att]),
            vaultPath: nil
        )
        #expect(item["body"] as? String == "(无文字)")
    }

    @Test func mapsAttachmentMetadataOnly() {
        let audio = Memo.Attachment(
            file: "raw/assets/v.m4a", kind: "audio",
            duration: 8.0, transcript: "hi", transcriptionStatus: .done
        )
        let item = MemoSyncMapper.bulkItem(from: makeMemo(attachments: [audio]), vaultPath: nil)
        let atts = item["attachments"] as? [[String: Any]]
        #expect(atts?.count == 1)
        #expect(atts?.first?["kind"] as? String == "audio")
        #expect(atts?.first?["storage_key"] as? String == "raw/assets/v.m4a")
        #expect(atts?.first?["duration_sec"] as? Double == 8.0)
        #expect(atts?.first?["transcript"] as? String == "hi")
    }

    @Test func payloadIsValidJSON() throws {
        // The mapped dict must round-trip through JSONSerialization (no NaN,
        // no non-serializable values) so the POST body never fails to encode.
        let loc = Memo.Location(name: "Tokyo", lat: 35.0, lng: 139.0)
        let att = Memo.Attachment(file: "a.m4a", kind: "audio", duration: 1.0, transcript: "t", transcriptionStatus: .done)
        let item = MemoSyncMapper.bulkItem(
            from: makeMemo(weather: "Rain", device: "iPhone", mood: "calm", location: loc, attachments: [att]),
            vaultPath: "raw/x.md"
        )
        let payload: [String: Any] = ["memos": [item]]
        #expect(JSONSerialization.isValidJSONObject(payload))
        let data = try JSONSerialization.data(withJSONObject: payload)
        #expect(data.count > 0)
    }
}

// MARK: - Response parsing

@Suite
struct MemoSyncResponseTests {
    let id = "550e8400-e29b-41d4-a716-446655440001"

    private func data(_ obj: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: obj)
    }

    @Test func acceptedDoesNotThrow() throws {
        let d = data(["accepted": [id], "skipped": []])
        // Should not throw.
        try MemoSyncUploader.assertAccepted(memoID: id, responseData: d)
    }

    @Test func acceptedIsCaseInsensitive() throws {
        let d = data(["accepted": [id.uppercased()], "skipped": []])
        try MemoSyncUploader.assertAccepted(memoID: id, responseData: d)
    }

    @Test func skippedThrowsWithReason() {
        let d = data(["accepted": [], "skipped": [["id": id, "reason": "DB error"]]])
        #expect(throws: MemoSyncError.self) {
            try MemoSyncUploader.assertAccepted(memoID: id, responseData: d)
        }
    }

    @Test func notAcknowledgedThrows() {
        let d = data(["accepted": [], "skipped": []])
        #expect(throws: MemoSyncError.self) {
            try MemoSyncUploader.assertAccepted(memoID: id, responseData: d)
        }
    }

    @Test func malformedResponseThrows() {
        #expect(throws: MemoSyncError.self) {
            try MemoSyncUploader.assertAccepted(memoID: id, responseData: Data("not json".utf8))
        }
    }
}

// MARK: - SyncSettings

@Suite(.serialized)
struct SyncSettingsTests {

    /// Snapshot + restore the base URL so tests can't poison the host app or
    /// each other.
    private func withCleanBaseURL(_ body: () throws -> Void) rethrows {
        let prior = SyncSettings.baseURLString
        defer { SyncSettings.baseURLString = prior }
        SyncSettings.baseURLString = nil
        try body()
    }

    @Test func normalizesBaseURL() {
        #expect(SyncSettings.normalizeBaseURL("daypage.app") == "https://daypage.app")
        #expect(SyncSettings.normalizeBaseURL("https://daypage.app/") == "https://daypage.app")
        #expect(SyncSettings.normalizeBaseURL("http://192.168.1.5:3000") == "http://192.168.1.5:3000")
        #expect(SyncSettings.normalizeBaseURL("https://a.com///") == "https://a.com")
    }

    @Test func bulkEndpointAppendsPath() {
        withCleanBaseURL {
            SyncSettings.baseURLString = "https://daypage.app"
            #expect(SyncSettings.bulkEndpoint?.absoluteString == "https://daypage.app/api/memos/bulk")
        }
    }

    @Test func bulkEndpointNilWhenUnset() {
        withCleanBaseURL {
            SyncSettings.baseURLString = nil
            #expect(SyncSettings.bulkEndpoint == nil)
        }
    }
}
