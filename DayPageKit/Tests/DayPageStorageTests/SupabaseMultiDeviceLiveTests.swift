import Foundation
import XCTest
import AVFoundation
import ImageIO
import DayPageModels
@testable import DayPageStorage

/// Opt-in staging acceptance test. It uses one real Supabase Auth session and
/// two independent local Vault directories to exercise the same HTTP push and
/// pull implementations installed by the iOS and macOS apps.
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
        let uploader = SupabaseSyncUploader(
            session: liveSession,
            accessTokenProvider: tokenProvider
        )
        let puller = SupabaseSyncPuller(
            session: liveSession,
            accessTokenProvider: tokenProvider
        )
        let created = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        try select(vaultA, session: liveSession)
        let sourceAttachments = try createMediaFixtures(in: vaultA)
        let memo = Memo(
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
    /// tests stay opt-in and are never executed by worker batches.
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
