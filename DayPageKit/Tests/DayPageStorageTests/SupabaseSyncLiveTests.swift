import Foundation
import XCTest
import DayPageModels
@testable import DayPageStorage

/// Opt-in staging proof for the same Vault -> outbox -> revisioned RPC path
/// used by the native apps. CI skips it unless all three public/session values
/// are explicitly supplied.
final class SupabaseSyncLiveTests: XCTestCase {
    func testLocalVaultCaptureUploadsAndReadsBackFromSupabase() async throws {
        let environment = ProcessInfo.processInfo.environment
        let configuration = try await SupabaseLiveTestConfiguration.load()
        let supabaseURL = configuration.url
        let publishableKey = configuration.publishableKey
        let accessToken = configuration.accessToken

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-mac-sync-live-\(UUID().uuidString)", isDirectory: true)
        VaultInitializer.testOverrideURL = root
        VaultInitializer.initializeIfNeeded()
        defer {
            VaultInitializer.testOverrideURL = nil
            try? FileManager.default.removeItem(at: root)
        }

        let marker = environment["DAYPAGE_SYNC_E2E_MARKER"]
            ?? "DAYPAGE_MAC_VAULT_SYNC_E2E_\(UUID().uuidString)"
        let memo = Memo(type: .text, created: Date(), body: marker)

        // This is the exact capture boundary used by MacTodayView.
        try RawStorage.append(memo)
        let operation = try XCTUnwrap(
            SyncOutboxStore.pendingOperations().first(where: { $0.memoID == memo.id })
        )
        #if os(macOS)
        XCTAssertEqual(operation.payload?.source, "macos")
        #endif

        // Constructor/signature compatibility for the realm-isolated API: the
        // live session is built through the real same-server token proof.
        // Live tests stay opt-in and are never executed by worker batches.
        let liveSession = try await SyncSessionVerifier.verifiedSession(
            configuration: try SyncBackendConfiguration(
                url: supabaseURL,
                publishableKey: publishableKey
            ),
            accessToken: accessToken,
            transport: SupabaseSyncTransport.shared(
                for: try SyncRealmOrigin(validating: supabaseURL)
            ),
            expectedUserID: configuration.userID
        )
        let uploader = SupabaseSyncUploader(
            session: liveSession,
            accessTokenProvider: { accessToken }
        )
        let uploadedBytes = try await uploader.upload(operation: operation)
        XCTAssertGreaterThan(uploadedBytes, 0)
        try SyncOutboxStore.acknowledge(operationID: operation.operationID)
        XCTAssertFalse(try SyncOutboxStore.pendingOperations().contains(where: { $0.memoID == memo.id }))

        var components = URLComponents(
            url: supabaseURL
                .appendingPathComponent("rest", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
                .appendingPathComponent("memos"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(memo.id.uuidString.lowercased())"),
            URLQueryItem(name: "select", value: "id,body,source"),
        ]
        let readURL = try XCTUnwrap(components?.url)
        var request = URLRequest(url: readURL)
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let records = try JSONDecoder().decode([RemoteMemo].self, from: data)
        XCTAssertEqual(records.first?.id, memo.id)
        XCTAssertEqual(records.first?.body, marker)
        XCTAssertEqual(records.first?.source, "macos")

        print("DAYPAGE_MAC_SYNC_E2E memo_id=\(memo.id.uuidString.lowercased()) marker=\(marker)")
    }
}

private struct RemoteMemo: Decodable {
    let id: UUID
    let body: String
    let source: String
}
