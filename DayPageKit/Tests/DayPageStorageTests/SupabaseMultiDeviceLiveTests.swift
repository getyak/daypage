import Foundation
import XCTest
import AVFoundation
import ImageIO
import DayPageModels
@testable import DayPageStorage

/// Opt-in staging acceptance test. It uses one real Supabase Auth session and
/// two independent local Vault directories. Uploads use the real v2 RPC and
/// Storage APIs; readback uses a fixture-scoped REST projection through the
/// native pull decoder/downloader. The unfiltered account pull RPC and physical
/// cross-device/version compatibility are separate acceptance gates.
///
/// Required environment variables:
/// - DAYPAGE_SYNC_E2E_URL
/// - DAYPAGE_SYNC_E2E_PUBLISHABLE_KEY
/// - DAYPAGE_SYNC_E2E_ACCESS_TOKEN, or
/// - DAYPAGE_SYNC_E2E_EMAIL + DAYPAGE_SYNC_E2E_PASSWORD
final class SupabaseMultiDeviceLiveTests: XCTestCase {
    func testTwoVaultsRoundTripCreateEditAndDelete() async throws {
        let configuration = try await SupabaseLiveTestConfiguration.load()
        let liveSession = try await makeLiveSession(configuration)
        let baseDirectory = ProcessInfo.processInfo.environment["DAYPAGE_TEST_VAULT_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let root = baseDirectory
            .appendingPathComponent("daypage-live-multidevice-\(UUID().uuidString)", isDirectory: true)
        let vaultA = root.appendingPathComponent("device-a", isDirectory: true)
        let vaultB = root.appendingPathComponent("device-b", isDirectory: true)
        try prepare(vaultA)
        try prepare(vaultB)
        defer {
            VaultInitializer.testOverrideURL = nil
            try? FileManager.default.removeItem(at: root)
        }

        let tokenProvider: @Sendable () async throws -> String = {
            configuration.accessToken
        }
        let fixtureMemoID = UUID()
        let uploader = SupabaseSyncUploader(
            session: liveSession,
            accessTokenProvider: tokenProvider
        )
        let puller = SupabaseSyncPuller(
            session: liveSession,
            transport: FixtureScopedPullTransport(
                memoID: fixtureMemoID, ownerID: configuration.userID,
                underlying: SupabaseSyncTransport.shared(for: liveSession.identity.origin)
            ),
            accessTokenProvider: tokenProvider
        )
        let created = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        try select(vaultA, session: liveSession)
        let sourceAttachments = try createMediaFixtures(in: vaultA)
        let memo = Memo(
            id: fixtureMemoID,
            type: .mixed,
            created: created,
            device: "staging-device-a",
            attachments: sourceAttachments,
            body: "DAYPAGE_MULTI_DEVICE_CREATE_\(UUID().uuidString)"
        )

        try RawStorage.append(memo)
        try await uploadOnlyOperation(for: memo.id, using: uploader)
        try await pullAll(using: puller, in: vaultA, session: liveSession)

        try select(vaultB, session: liveSession)
        try await pullAll(using: puller, in: vaultB, session: liveSession)
        let deviceBMemo = try XCTUnwrap(memoFromSelectedVault(memo.id, on: created))
        XCTAssertEqual(deviceBMemo.id, memo.id)
        XCTAssertEqual(deviceBMemo.created, memo.created)
        XCTAssertEqual(deviceBMemo.body, memo.body)
        XCTAssertEqual(deviceBMemo.attachments.map(\.kind), ["photo", "audio"])
        try assertMediaConverged(
            sourceMemo: memo,
            receivedMemo: deviceBMemo,
            sourceVault: vaultA,
            destinationVault: vaultB
        )

        var deviceBMemos = try RawStorage.read(for: created)
        let editedIndex = try XCTUnwrap(deviceBMemos.firstIndex(where: { $0.id == memo.id }))
        deviceBMemos[editedIndex].body = "DAYPAGE_MULTI_DEVICE_EDIT_\(UUID().uuidString)"
        let editedBody = deviceBMemos[editedIndex].body
        try RawStorage.rewrite(deviceBMemos, for: created)
        try await uploadOnlyOperation(for: memo.id, using: uploader)
        try await pullAll(using: puller, in: vaultB, session: liveSession)

        try select(vaultA, session: liveSession)
        try await pullAll(using: puller, in: vaultA, session: liveSession)
        XCTAssertEqual(try memoFromSelectedVault(memo.id, on: created)?.body, editedBody)

        let remaining = try RawStorage.read(for: created).filter { $0.id != memo.id }
        try RawStorage.rewrite(remaining, for: created)
        let deletion = try XCTUnwrap(
            try SyncOutboxStore.pendingOperations().first(where: { $0.memoID == memo.id })
        )
        XCTAssertEqual(deletion.kind, .delete)
        _ = try await uploader.upload(operation: deletion)
        try SyncOutboxStore.acknowledge(operationID: deletion.operationID)
        try await pullAll(using: puller, in: vaultA, session: liveSession)

        try select(vaultB, session: liveSession)
        try await pullAll(using: puller, in: vaultB, session: liveSession)
        XCTAssertNil(try memoFromSelectedVault(memo.id, on: created))
        XCTAssertTrue(try SyncOutboxStore.pendingOperations().isEmpty)

        // Restore during the 30-day grace period. The same immutable media
        // objects must become active again without byte re-upload or GC loss.
        try select(vaultA, session: liveSession)
        var restored = memo
        restored.body = "DAYPAGE_MULTI_DEVICE_RESTORE_\(UUID().uuidString)"
        try RawStorage.append(restored)
        try await uploadOnlyOperation(for: restored.id, using: uploader)
        try await pullAll(using: puller, in: vaultA, session: liveSession)

        try select(vaultB, session: liveSession)
        try await pullAll(using: puller, in: vaultB, session: liveSession)
        let restoredB = try XCTUnwrap(memoFromSelectedVault(restored.id, on: created))
        XCTAssertEqual(restoredB.body, restored.body)
        try assertMediaConverged(
            sourceMemo: restored,
            receivedMemo: restoredB,
            sourceVault: vaultA,
            destinationVault: vaultB
        )

        // Leave one final tombstone for the local verifier to force due and
        // hand to the private Storage-API GC worker.
        try select(vaultA, session: liveSession)
        try RawStorage.rewrite(
            try RawStorage.read(for: created).filter { $0.id != restored.id },
            for: created
        )
        try await uploadOnlyOperation(for: restored.id, using: uploader)
        try await pullAll(using: puller, in: vaultA, session: liveSession)

        if let path = ProcessInfo.processInfo.environment["DAYPAGE_ATTACHMENT_E2E_RECEIPT"] {
            guard testRun?.failureCount == 0,
                  deviceBMemo.id == memo.id, deviceBMemo.created == memo.created,
                  deviceBMemo.body == memo.body, restoredB.body == restored.body,
                  restored.attachments.count == restoredB.attachments.count else {
                throw MemoSyncError.invalidResponse
            }
            let hashes = try zip(restored.attachments, restoredB.attachments).map { source, received in
                let sourceProof = try AttachmentFileInspector.sha256AndSize(
                    of: vaultA.appendingPathComponent(source.file)
                )
                let receivedProof = try AttachmentFileInspector.sha256AndSize(
                    of: vaultB.appendingPathComponent(received.file)
                )
                guard sourceProof.hash == receivedProof.hash,
                      sourceProof.size == receivedProof.size else {
                    throw MemoSyncError.invalidResponse
                }
                return [
                    "kind": received.kind,
                    "source_sha256": sourceProof.hash,
                    "received_sha256": receivedProof.hash,
                    "source_bytes": sourceProof.size,
                    "received_bytes": receivedProof.size,
                    "metadata_equal": source.kind == received.kind
                        && source.duration == received.duration
                        && source.transcript == received.transcript
                        && source.transcriptionStatus == received.transcriptionStatus,
                ] as [String: Any]
            }
            let receipt: [String: Any] = [
                "result": "passed", "scope": "real-v2-upload-scoped-rest-native-download",
                "fixture_memo_id": memo.id.uuidString.lowercased(),
                "original_id_equal": deviceBMemo.id == memo.id,
                "original_created_equal": deviceBMemo.created == memo.created,
                "original_text_equal": deviceBMemo.body == memo.body,
                "restored_text_equal": restoredB.body == restored.body,
                "attachments": hashes,
            ]
            try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
                .write(to: URL(fileURLWithPath: path), options: [.atomic])
        }
    }

    func testInterruptedTUSResumesFromServerOffset() async throws {
        let configuration = try await SupabaseLiveTestConfiguration.load()
        let liveSession = try await makeLiveSession(configuration)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-live-tus-\(UUID().uuidString)", isDirectory: true)
        try prepare(root)
        defer {
            VaultInitializer.testOverrideURL = nil
            try? FileManager.default.removeItem(at: root)
        }
        try select(root, session: liveSession)

        let relativePath = "raw/assets/tus-resume.pdf"
        let fileURL = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var bytes = Data("%PDF-1.7\n".utf8)
        bytes.append(Data(repeating: 0x41, count: 7 * 1_024 * 1_024 - bytes.count))
        try bytes.write(to: fileURL, options: .atomic)
        let memo = Memo(
            type: .mixed,
            created: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)),
            attachments: [Memo.Attachment(file: relativePath, kind: "file")],
            body: "DAYPAGE_TUS_RESUME_\(UUID().uuidString)"
        )
        try RawStorage.append(memo)
        let operation = try XCTUnwrap(
            try SyncOutboxStore.pendingOperations().first(where: { $0.memoID == memo.id })
        )

        let probe = TUSInterruptionProbe()
        let transport = TUSInterruptingTransport(probe: probe)
        let tokenProvider: @Sendable () async throws -> String = { configuration.accessToken }
        let firstUploader = SupabaseSyncUploader(
            session: liveSession,
            transport: transport,
            accessTokenProvider: tokenProvider
        )
        do {
            _ = try await firstUploader.upload(operation: operation)
            XCTFail("the first TUS attempt must be interrupted after a real chunk")
        } catch is AttachmentSyncError {
            // Expected: the remote server accepted one chunk, but the client
            // intentionally lost the response before persisting its offset.
        }
        let first = await probe.snapshot()
        XCTAssertEqual(first.patchBytes, [6 * 1_024 * 1_024])

        let resumedUploader = SupabaseSyncUploader(
            session: liveSession,
            transport: transport,
            accessTokenProvider: tokenProvider
        )
        _ = try await resumedUploader.upload(operation: operation)
        let resumed = await probe.snapshot()
        XCTAssertGreaterThanOrEqual(resumed.headRequests, 1)
        XCTAssertEqual(resumed.patchBytes.reduce(0, +), bytes.count)
        XCTAssertEqual(resumed.patchBytes.count, 2)
        try SyncOutboxStore.acknowledge(operationID: operation.operationID)

        try RawStorage.rewrite([], for: memo.created)
        try await uploadOnlyOperation(for: memo.id, using: resumedUploader)
    }

    private func prepare(_ vault: URL) throws {
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("raw", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private func createMediaFixtures(in vault: URL) throws -> [Memo.Attachment] {
        let assets = vault.appendingPathComponent("raw/assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

        let jpegURL = assets.appendingPathComponent("sync-live-photo.jpg")
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let pixels: [UInt8] = [0x22, 0x88, 0xcc, 0xff]
        let provider = CGDataProvider(data: Data(pixels) as CFData)
        let image = try XCTUnwrap(CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: try XCTUnwrap(provider),
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let imageDestination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            jpegURL as CFURL,
            "public.jpeg" as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(imageDestination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(imageDestination))

        let audioURL = assets.appendingPathComponent("sync-live-audio.m4a")
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 44_100,
            channels: 1
        ))
        let output = try AVAudioFile(
            forWriting: audioURL,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ]
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 4_410
        ))
        buffer.frameLength = 4_410
        if let samples = buffer.floatChannelData?[0] {
            samples.initialize(repeating: 0, count: Int(buffer.frameLength))
        }
        try output.write(from: buffer)

        return [
            Memo.Attachment(file: "raw/assets/\(jpegURL.lastPathComponent)", kind: "photo"),
            Memo.Attachment(
                file: "raw/assets/\(audioURL.lastPathComponent)",
                kind: "audio",
                duration: 0.1,
                transcript: "synthetic silence",
                transcriptionStatus: .done
            ),
        ]
    }

    private func assertMediaConverged(
        sourceMemo: Memo,
        receivedMemo: Memo,
        sourceVault: URL,
        destinationVault: URL
    ) throws {
        XCTAssertEqual(sourceMemo.attachments.count, receivedMemo.attachments.count)
        for (source, received) in zip(sourceMemo.attachments, receivedMemo.attachments) {
            XCTAssertEqual(received.kind, source.kind)
            XCTAssertEqual(received.duration, source.duration)
            XCTAssertEqual(received.transcript, source.transcript)
            XCTAssertEqual(received.transcriptionStatus, source.transcriptionStatus)
            let sourceURL = sourceVault.appendingPathComponent(source.file)
            let destinationURL = destinationVault.appendingPathComponent(received.file)
            XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
            let sourceDigest = try AttachmentFileInspector.sha256AndSize(of: sourceURL)
            let destinationDigest = try AttachmentFileInspector.sha256AndSize(of: destinationURL)
            XCTAssertEqual(destinationDigest.hash, sourceDigest.hash)
            XCTAssertEqual(destinationDigest.size, sourceDigest.size)
            if received.kind == "photo" {
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(
                    destinationURL as CFURL,
                    nil
                ))
                XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
            } else if received.kind == "audio" {
                let audio = try AVAudioFile(forReading: destinationURL)
                XCTAssertGreaterThan(audio.length, 0)
            }
        }
    }

    /// Constructor/signature compatibility for the realm-isolated API: the
    /// live session is built through the real same-server token proof. Live
    /// tests stay opt-in and require explicit authorization for the target.
    private func makeLiveSession(
        _ configuration: SupabaseLiveTestConfiguration
    ) async throws -> SyncSession {
        try await SyncSessionVerifier.verifiedSession(
            configuration: try SyncBackendConfiguration(
                url: configuration.url,
                publishableKey: configuration.publishableKey
            ),
            accessToken: configuration.accessToken,
            transport: SupabaseSyncTransport.shared(
                for: try SyncRealmOrigin(validating: configuration.url)
            ),
            expectedUserID: configuration.userID
        )
    }

    private func select(_ vault: URL, session: SyncSession) throws {
        VaultInitializer.testOverrideURL = vault
        _ = try SyncAccountStateStore.bind(to: session.identity)
    }

    private func uploadOnlyOperation(
        for memoID: UUID,
        using uploader: SupabaseSyncUploader
    ) async throws {
        let operation = try XCTUnwrap(
            try SyncOutboxStore.pendingOperations().first(where: { $0.memoID == memoID })
        )
        _ = try await uploader.upload(operation: operation)
        try SyncOutboxStore.acknowledge(operationID: operation.operationID)
    }

    private func pullAll(
        using puller: SupabaseSyncPuller,
        in vault: URL,
        session: SyncSession
    ) async throws {
        try select(vault, session: session)
        for _ in 0..<10 {
            let cursor = try SyncAccountStateStore.pullCursor(for: session.identity)
            let page = try await puller.pull(after: cursor, limit: 100)
            XCTAssertGreaterThanOrEqual(page.nextCursor, cursor)
            _ = try RawStorage.applyRemoteChanges(page.changes)
            try SyncAccountStateStore.advancePullCursor(
                to: page.nextCursor,
                for: session.identity
            )
            if !page.hasMore { return }
            XCTAssertFalse(page.changes.isEmpty)
        }
        XCTFail("staging pull exceeded ten pages")
    }

    private func memoFromSelectedVault(_ id: UUID, on date: Date) throws -> Memo? {
        try RawStorage.read(for: date).first(where: { $0.id == id })
    }
}

/// Scope only the acceptance read: the production RPC is account-wide and a
/// cursor cannot prevent another device's concurrent notes being read. Fetch
/// this task's UUID + owner with real REST/RLS, then adapt the actual row and
/// manifest to the pull wire envelope. No memo content or bytes are fabricated.
/// Embedded aliases/filters: https://docs.postgrest.org/en/v13/references/api/resource_embedding.html
private struct FixtureScopedPullTransport: HTTPTransport {
    let memoID: UUID
    let ownerID: UUID
    let underlying: HTTPTransport

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url,
              url.path == "/rest/v1/rpc/daypage_pull_sync_changes" else {
            return try await underlying.data(for: request)
        }
        struct PullRequest: Decodable { let p_after_sequence: Int64 }
        let after = try JSONDecoder().decode(
            PullRequest.self, from: XCTUnwrap(request.httpBody)
        ).p_after_sequence
        var components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        components.path = "/rest/v1/memos"
        components.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(memoID.uuidString.lowercased())"),
            URLQueryItem(name: "user_id", value: "eq.\(ownerID.uuidString.lowercased())"),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "attachments.protocol_version", value: "eq.2"),
            URLQueryItem(name: "attachments.order", value: "position.asc"),
            URLQueryItem(name: "select", value: [
                "id,type,body,created_at,pinned_at,location,weather,device,source,vault_path",
                "source_modified_at,content_hash,sync_revision,last_sync_device_id,deleted_at",
                "change_sequence:sync_change_sequence,attachment_manifest_hash",
                "attachments:memo_attachments(position,kind,content_sha256,size_bytes,mime_type,object_key:storage_key,original_filename:filename,duration_ms,transcript,transcription_status)",
            ].joined(separator: ",")),
        ]
        var scoped = request
        scoped.url = try XCTUnwrap(components.url)
        scoped.httpMethod = "GET"
        scoped.httpBody = nil
        let (data, response) = try await underlying.data(for: scoped)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            return (data, response)
        }
        struct RowProof: Decodable {
            let id: UUID
            let change_sequence: Int64
            let deleted_at: String?
        }
        let proofs = try JSONDecoder().decode([RowProof].self, from: data)
        guard proofs.count == 1, let proof = proofs.first, proof.id == memoID,
              let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              var row = rows.first else {
            throw MemoSyncError.invalidResponse
        }
        if proof.deleted_at != nil {
            row["attachments"] = [] as [String]
            row["attachment_manifest_hash"] = NSNull()
        }
        let changed = proof.change_sequence > after
        let envelope: [String: Any] = [
            "changes": changed ? [row] : [],
            "next_cursor": changed ? proof.change_sequence : after,
            "has_more": false,
        ]
        return (try JSONSerialization.data(withJSONObject: envelope), response)
    }
}

final class FixtureScopedReadbackScopeTests: XCTestCase {
    func testNeverRequestsAccountFeedOrUnrelatedMemo() async throws {
        let memoID = UUID()
        let ownerID = UUID()
        let underlying = FixtureQueryScopeProbe(memoID: memoID, ownerID: ownerID)
        let transport = FixtureScopedPullTransport(
            memoID: memoID, ownerID: ownerID, underlying: underlying
        )
        var request = URLRequest(url: try XCTUnwrap(URL(
            string: "https://example.supabase.co/rest/v1/rpc/daypage_pull_sync_changes"
        )))
        request.httpMethod = "POST"
        request.httpBody = Data("{\"p_after_sequence\":0,\"p_limit\":100}".utf8)
        let (data, _) = try await transport.data(for: request)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let changes = try XCTUnwrap(envelope["changes"] as? [[String: Any]])
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?["id"] as? String, memoID.uuidString.lowercased())
        XCTAssertEqual(envelope["has_more"] as? Bool, false)
    }
}

private struct FixtureQueryScopeProbe: HTTPTransport {
    let memoID: UUID
    let ownerID: UUID

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(url.path, "/rest/v1/memos")
        XCTAssertNil(request.httpBody)
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "id" }?.value, "eq.\(memoID.uuidString.lowercased())")
        XCTAssertEqual(query.first { $0.name == "user_id" }?.value, "eq.\(ownerID.uuidString.lowercased())")
        XCTAssertEqual(query.first { $0.name == "limit" }?.value, "1")
        XCTAssertEqual(query.first { $0.name == "attachments.protocol_version" }?.value, "eq.2")
        let row: [String: Any] = [
            "id": memoID.uuidString.lowercased(), "change_sequence": 7, "deleted_at": NSNull(),
        ]
        return (
            try JSONSerialization.data(withJSONObject: [row]),
            try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        )
    }
}

private struct IntentionalTUSInterruption: Error {}

private actor TUSInterruptionProbe {
    private var shouldInterrupt = true
    private var recordedPatchBytes: [Int] = []
    private var recordedHeadRequests = 0

    func recordPatch(bytes: Int) -> Bool {
        recordedPatchBytes.append(bytes)
        if shouldInterrupt {
            shouldInterrupt = false
            return true
        }
        return false
    }

    func recordHead() {
        recordedHeadRequests += 1
    }

    func snapshot() -> (patchBytes: [Int], headRequests: Int) {
        (recordedPatchBytes, recordedHeadRequests)
    }
}

private struct TUSInterruptingTransport: HTTPTransport {
    let probe: TUSInterruptionProbe

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let result = try await URLSession.shared.data(for: request)
        if request.httpMethod == "HEAD" {
            await probe.recordHead()
        } else if request.httpMethod == "PATCH" {
            let shouldInterrupt = await probe.recordPatch(bytes: request.httpBody?.count ?? 0)
            if shouldInterrupt { throw IntentionalTUSInterruption() }
        }
        return result
    }
}
