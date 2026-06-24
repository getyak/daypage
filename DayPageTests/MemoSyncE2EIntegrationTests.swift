// MemoSyncE2EIntegrationTests.swift — iOS → Web 真实端到端集成测试 (issue #785)
//
// 与 MemoSyncUploaderTests 的纯函数测试不同,这里跑**真实的网络往返**:
// 配置 SyncSettings 指向本地 web,在临时 vault 写一条真实 memo,然后用真实的
// URLSession transport 调 MemoSyncUploader.upload(),验证 web 回 accepted。
//
// 默认 skip——只有设置环境变量后才运行,避免在没有本地 web 的环境（CI、其他
// 开发者机器）误失败:
//   SYNC_E2E_URL=http://127.0.0.1:3100
//   SYNC_E2E_KEY=<web 生成的 write scope key>
//
// 跑法:在 scheme 的 Test 环境变量里设上述两项,或:
//   SYNC_E2E_URL=... SYNC_E2E_KEY=... xcodebuild test \
//     -only-testing:DayPageTests/MemoSyncE2EIntegrationTests
//
// 模拟器与 Mac 共享网络栈,127.0.0.1 在模拟器内即指向 Mac 本机,可直接访问本地
// web dev server。

import Testing
import Foundation
@testable import DayPage

@Suite(.serialized)
struct MemoSyncE2EIntegrationTests {

    private var envURL: String? { ProcessInfo.processInfo.environment["SYNC_E2E_URL"] }
    private var envKey: String? { ProcessInfo.processInfo.environment["SYNC_E2E_KEY"] }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SYNC_E2E_KEY"] != nil))
    func uploadsRealMemoToLocalWeb() async throws {
        let baseURL = try #require(envURL, "set SYNC_E2E_URL")
        let key = try #require(envKey, "set SYNC_E2E_KEY")

        // Isolate a throwaway vault so we don't touch the real one.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-e2e-\(UUID().uuidString)", isDirectory: true)
        let rawDir = tmp.appendingPathComponent("raw", isDirectory: true)
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        VaultInitializer.testOverrideURL = tmp
        defer {
            VaultInitializer.testOverrideURL = nil
            try? FileManager.default.removeItem(at: tmp)
        }

        // Write a real memo into the vault via the same serializer the app uses.
        let memo = Memo(
            id: UUID(),
            type: .text,
            created: Date(),
            body: "iOS→web E2E integration \(UUID().uuidString.prefix(8))"
        )
        let fileURL = rawDir.appendingPathComponent("2026-06-24.md")
        try memo.toMarkdown().write(to: fileURL, atomically: true, encoding: .utf8)

        // Snapshot + restore the real sync config so this test can't poison it.
        let priorURL = SyncSettings.baseURLString
        let priorKey = SyncSettings.apiKey
        defer {
            SyncSettings.baseURLString = priorURL
            SyncSettings.apiKey = priorKey
        }
        SyncSettings.baseURLString = baseURL
        SyncSettings.apiKey = key

        // Real uploader, real URLSession transport.
        let uploader = MemoSyncUploader()
        let bytes = try await uploader.upload(memoID: memo.id.uuidString)

        // A successful upload returns the payload byte size (>0) and the server
        // acknowledged the memo (no throw from assertAccepted).
        #expect(bytes > 0)
    }
}
