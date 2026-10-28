import Foundation
import XCTest
import DayPageModels
@testable import DayPageStorage

private actor FlakyAttachmentDownloadTransport: AttachmentFileTransport {
    private let sourceURL: URL
    private var downloadAttempts = 0

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    func uploadFile(
        for request: URLRequest,
        from fileURL: URL
    ) async throws -> (Data, URLResponse) {
        throw AttachmentSyncError.network
    }

    func downloadFile(for request: URLRequest) async throws -> (URL, URLResponse) {
        downloadAttempts += 1
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: downloadAttempts == 1 ? 503 : 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (sourceURL, response)
    }

    func attempts() -> Int { downloadAttempts }
}

private struct PathSwappingAttachmentDownloadTransport: AttachmentFileTransport {
    let sourceURL: URL
    let linkURL: URL
    let outsideURL: URL

    func uploadFile(for request: URLRequest, from fileURL: URL) async throws -> (Data, URLResponse) {
        throw AttachmentSyncError.network
    }

    func downloadFile(for request: URLRequest) async throws -> (URL, URLResponse) {
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outsideURL)
        return (sourceURL, try XCTUnwrap(HTTPURLResponse(
            url: XCTUnwrap(request.url), statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
        )))
    }
}

// MARK: - Imported media (AAC / QuickTime) synthetic byte helpers

private func adtsFrame(
    frameLength: Int,
    profile: UInt8 = 1,
    sampleIndex: UInt8 = 4,
    channelConfig: UInt8 = 2
) -> Data {
    var frame = Data([0xff, 0xf1, 0, 0, 0, 0, 0])
    frame[2] = (profile << 6) | (sampleIndex << 2) | ((channelConfig >> 2) & 0x01)
    frame[3] = ((channelConfig & 0x03) << 6) | UInt8((frameLength >> 11) & 0x03)
    frame[4] = UInt8((frameLength >> 3) & 0xff)
    frame[5] = UInt8((frameLength & 0x07) << 5) | 0x1f
    frame[6] = 0xfc
    frame.append(Data(repeating: 0x42, count: max(0, frameLength - 7)))
    return frame
}

private func quickTimeFile(
    brand: String = "qt  ",
    declaredBoxSize: Int? = nil,
    compatibleBrands: [String] = ["qt  "]
) -> Data {
    let boxLength = 16 + 4 * compatibleBrands.count
    var box = Data()
    var size = UInt32(declaredBoxSize ?? boxLength).bigEndian
    box.append(Data(bytes: &size, count: 4))
    box.append(Data("ftyp".utf8))
    box.append(Data(brand.utf8))
    var minorVersion = UInt32(0).bigEndian
    box.append(Data(bytes: &minorVersion, count: 4))
    for compatible in compatibleBrands {
        box.append(Data(compatible.utf8))
    }
    return box
}

private func quickTimeMovie(brand: String = "qt  ") -> Data {
    var movie = quickTimeFile(brand: brand)
    let payload = Data(repeating: 0x11, count: 24)
    var mediaSize = UInt32(8 + payload.count).bigEndian
    movie.append(Data(bytes: &mediaSize, count: 4))
    movie.append(Data("mdat".utf8))
    movie.append(payload)
    return movie
}

private func quickTimeLargesizeFile(
    brand: String = "qt  ",
    largeSize: UInt64,
    compatibleBrands: [String] = ["qt  "],
    trailingByte: UInt8? = nil
) -> Data {
    var box = Data()
    var size = UInt32(1).bigEndian
    box.append(Data(bytes: &size, count: 4))
    box.append(Data("ftyp".utf8))
    var large = largeSize.bigEndian
    box.append(Data(bytes: &large, count: 8))
    box.append(Data(brand.utf8))
    var minorVersion = UInt32(0).bigEndian
    box.append(Data(bytes: &minorVersion, count: 4))
    for compatible in compatibleBrands {
        box.append(Data(compatible.utf8))
    }
    if let trailingByte {
        box.append(Data([trailingByte]))
    }
    return box
}

private func importedDescriptor(
    kind: String,
    mimeType: String,
    extension fileExtension: String,
    digest: String,
    sizeBytes: Int64
) -> SyncAttachmentDescriptor {
    SyncAttachmentDescriptor(
        position: 0,
        kind: kind,
        contentSHA256: digest,
        sizeBytes: sizeBytes,
        mimeType: mimeType,
        objectKey: "\(UUID().uuidString.lowercased())/\(UUID().uuidString.lowercased())/\(digest).\(fileExtension)",
        originalFilename: "sample.\(fileExtension)"
    )
}

final class AttachmentSyncTests: XCTestCase {
    private var vault: URL!

    override func setUpWithError() throws {
        vault = SyncRealmTestSupport.fixtureRoot
            .appendingPathComponent("daypage-attachment-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("raw/assets", isDirectory: true),
            withIntermediateDirectories: true
        )
        VaultInitializer.testOverrideURL = vault
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = nil
        if let vault { try? FileManager.default.removeItem(at: vault) }
    }

    func testStreamingInspectionAndStableRetrySidecar() throws {
        let relativePath = "raw/assets/capture.png"
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4])
        try bytes.write(to: vault.appendingPathComponent(relativePath))
        let memo = Memo(
            type: .photo,
            attachments: [Memo.Attachment(file: relativePath, kind: "photo")],
            body: "photo"
        )
        let operation = SyncOutboxOperation(
            operationID: UUID(),
            memoID: memo.id,
            kind: .upsert,
            revision: 1,
            modifiedAt: Date(),
            contentHash: SyncOutboxStore.contentHash(for: memo),
            deviceID: UUID().uuidString.lowercased(),
            payload: nil,
            sizeBytes: memo.toMarkdown().utf8.count
        )
        let userID = UUID()
        let realm = try SyncRealmTestSupport.realm(user: userID)

        let first = try AttachmentTransferStore.prepareUploads(
            operation: operation,
            memo: memo,
            realm: realm
        )
        let retry = try AttachmentTransferStore.prepareUploads(
            operation: operation,
            memo: memo,
            realm: realm
        )
        try FileManager.default.removeItem(at: AttachmentTransferStore.stateURL)
        let rebuilt = try AttachmentTransferStore.prepareUploads(
            operation: operation,
            memo: memo,
            realm: realm
        )

        XCTAssertEqual(first, retry)
        XCTAssertEqual(first, rebuilt)
        XCTAssertEqual(first.first?.descriptor.sizeBytes, Int64(bytes.count))
        XCTAssertEqual(first.first?.descriptor.mimeType, "image/png")
        XCTAssertTrue(first.first?.descriptor.objectKey.hasPrefix(
            "\(userID.uuidString.lowercased())/\(memo.id.uuidString.lowercased())/"
        ) == true)
        let sameDevicePull = try AttachmentTransferStore.recordPendingDownloads(
            memoID: memo.id,
            descriptors: rebuilt.map(\.descriptor),
            realm: realm
        )
        XCTAssertEqual(sameDevicePull.first?.relativePath, relativePath)
        let state = try String(contentsOf: AttachmentTransferStore.stateURL)
        XCTAssertFalse(state.contains("Bearer"))
        XCTAssertFalse(state.contains("access_token"))
        XCTAssertFalse(state.contains(bytes.base64EncodedString()))
    }

    func testUnsupportedAttachmentPersistsHonestVisibleState() throws {
        let realm = try SyncRealmTestSupport.realm()
        let relativePath = "raw/assets/archive.zip"
        try Data([0x50, 0x4b, 0x03, 0x04]).write(
            to: vault.appendingPathComponent(relativePath)
        )
        let memo = Memo(
            type: .text,
            attachments: [Memo.Attachment(file: relativePath, kind: "file")],
            body: "unsupported"
        )
        let operation = SyncOutboxOperation(
            operationID: UUID(),
            memoID: memo.id,
            kind: .upsert,
            revision: 1,
            modifiedAt: Date(),
            contentHash: SyncOutboxStore.contentHash(for: memo),
            deviceID: UUID().uuidString.lowercased(),
            payload: nil,
            sizeBytes: memo.toMarkdown().utf8.count
        )

        XCTAssertThrowsError(
            try AttachmentTransferStore.prepareUploads(
                operation: operation,
                memo: memo,
                realm: realm
            )
        ) { error in
            guard case AttachmentSyncError.unsupportedType("zip") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let summary = AttachmentTransferStore.summary(
            memoIDs: [memo.id.uuidString]
        )
        XCTAssertTrue(summary.hasMedia)
        XCTAssertEqual(summary.unsupported, 1)
        let state = try String(contentsOf: AttachmentTransferStore.stateURL)
        XCTAssertTrue(state.contains("unsupported_type"))
        XCTAssertFalse(state.contains(Data([0x50, 0x4b, 0x03, 0x04]).base64EncodedString()))

        try AttachmentTransferStore.discardTransfers(
            memoIDs: [memo.id],
            realm: realm
        )
        XCTAssertFalse(AttachmentTransferStore.actionableSummary().hasMedia)
    }

    func testRejectsTraversalSymlinkEscapeAndMimeMismatch() throws {
        XCTAssertThrowsError(
            try AttachmentFileInspector.inspect(relativePath: "raw/assets/../secret.png", kind: "photo")
        )

        let outside = vault.deletingLastPathComponent().appendingPathComponent("outside.png")
        try Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = vault.appendingPathComponent("raw/assets/link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(
            try AttachmentFileInspector.inspect(relativePath: "raw/assets/link.png", kind: "photo")
        )

        try Data("not a png".utf8).write(
            to: vault.appendingPathComponent("raw/assets/wrong.png")
        )
        XCTAssertThrowsError(
            try AttachmentFileInspector.inspect(relativePath: "raw/assets/wrong.png", kind: "photo")
        ) { error in
            guard case AttachmentSyncError.mimeMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let wrongURL = vault.appendingPathComponent("raw/assets/wrong.png")
        let digest = try AttachmentFileInspector.sha256AndSize(of: wrongURL)
        let memoID = UUID()
        let userID = UUID()
        let remoteDescriptor = SyncAttachmentDescriptor(
            position: 0,
            kind: "photo",
            contentSHA256: digest.hash,
            sizeBytes: digest.size,
            mimeType: "image/png",
            objectKey: "\(userID.uuidString.lowercased())/\(memoID.uuidString.lowercased())/\(digest.hash).png",
            originalFilename: "wrong.png"
        )
        XCTAssertTrue(AttachmentManifest.isStructurallyValid([remoteDescriptor]))
        XCTAssertThrowsError(
            try AttachmentFileInspector.verify(url: wrongURL, descriptor: remoteDescriptor)
        ) { error in
            guard case AttachmentSyncError.mimeMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        let wrongKey = SyncAttachmentDescriptor(
            position: 0,
            kind: "photo",
            contentSHA256: digest.hash,
            sizeBytes: digest.size,
            mimeType: "image/png",
            objectKey: "\(userID.uuidString.lowercased())/\(memoID.uuidString.lowercased())/other.png",
            originalFilename: "wrong.png"
        )
        XCTAssertFalse(AttachmentManifest.isStructurallyValid([wrongKey]))
    }

    func testRemoteManifestUsesDurableDeterministicLocalPath() throws {
        let memoID = UUID()
        let realm = try SyncRealmTestSupport.realm()
        let descriptor = SyncAttachmentDescriptor(
            position: 0,
            kind: "audio",
            contentSHA256: String(repeating: "a", count: 64),
            sizeBytes: 8,
            mimeType: "audio/m4a",
            objectKey: "\(realm.userID.uuidString.lowercased())/\(memoID.uuidString.lowercased())/\(String(repeating: "a", count: 64)).m4a",
            originalFilename: "voice.m4a",
            durationMilliseconds: 1_250,
            transcript: "hello",
            transcriptionStatus: "done"
        )
        let items = try AttachmentTransferStore.recordPendingDownloads(
            memoID: memoID,
            descriptors: [descriptor],
            realm: realm
        )
        let change = SyncRemoteChange(
            id: memoID,
            type: "voice",
            body: "voice",
            createdAt: Date(),
            pinnedAt: nil,
            location: nil,
            weather: nil,
            device: nil,
            source: "ios",
            vaultPath: nil,
            sourceModifiedAt: nil,
            contentHash: nil,
            syncRevision: 1,
            lastSyncDeviceId: nil,
            deletedAt: nil,
            changeSequence: 1,
            attachmentManifestHash: AttachmentManifest.hash([descriptor]),
            attachments: [descriptor]
        )

        let attachment = try XCTUnwrap(change.makeMemo().attachments.first)
        XCTAssertEqual(attachment.file, items[0].relativePath)
        XCTAssertEqual(attachment.duration, 1.25)
        XCTAssertEqual(attachment.transcriptionStatus, .done)
        XCTAssertTrue(FileManager.default.fileExists(atPath: AttachmentTransferStore.stateURL.path))
    }

    func testManifestRejectsUnboundedDeclaredSizesWithoutOverflow() throws {
        let realm = try SyncRealmTestSupport.realm()
        let memoID = UUID()
        let descriptors = (0..<2).map { position in
            let hash = String(repeating: position == 0 ? "a" : "b", count: 64)
            return SyncAttachmentDescriptor(
                position: position,
                kind: "photo",
                contentSHA256: hash,
                sizeBytes: Int64.max,
                mimeType: "image/png",
                objectKey: "\(realm.userID.uuidString.lowercased())/\(memoID.uuidString.lowercased())/\(hash).png",
                originalFilename: "fixture-\(position).png"
            )
        }

        XCTAssertFalse(AttachmentManifest.isStructurallyValid(descriptors))
    }

    func testFailedDownloadRetriesOnLaterEmptyPullAndTombstoneDiscardsState() async throws {
        let realm = try SyncRealmTestSupport.realm()
        let relativePath = "raw/assets/remote-source.png"
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4])
        let sourceURL = vault.appendingPathComponent(relativePath)
        try bytes.write(to: sourceURL)
        let inspected = try AttachmentFileInspector.inspect(
            relativePath: relativePath,
            kind: "photo"
        )
        let memoID = UUID()
        let descriptor = SyncAttachmentDescriptor(
            position: 0,
            kind: "photo",
            contentSHA256: inspected.sha256,
            sizeBytes: inspected.sizeBytes,
            mimeType: inspected.mimeType,
            objectKey: "\(realm.userID.uuidString.lowercased())/\(memoID.uuidString.lowercased())/\(inspected.sha256).png",
            originalFilename: "remote.png"
        )
        let manifestHash = AttachmentManifest.hash([descriptor])
        let remote = SyncRemoteChange(
            id: memoID,
            type: "photo",
            body: "remote photo",
            createdAt: Date(),
            pinnedAt: nil,
            location: nil,
            weather: nil,
            device: nil,
            source: "ios",
            vaultPath: nil,
            sourceModifiedAt: nil,
            contentHash: nil,
            syncRevision: 1,
            lastSyncDeviceId: nil,
            deletedAt: nil,
            changeSequence: 1,
            attachmentManifestHash: manifestHash,
            attachments: [descriptor]
        )
        let transport = FlakyAttachmentDownloadTransport(sourceURL: sourceURL)
        let downloader = SupabaseAttachmentDownloader(
            session: try SyncRealmTestSupport.session(realm: realm),
            fileTransport: transport
        )

        try await downloader.persistAndAttempt(changes: [remote], token: try SyncRealmTestSupport.verifiedToken("session", realm: realm))
        XCTAssertEqual(
            AttachmentTransferStore.summary(memoIDs: [memoID.uuidString]).failed,
            1
        )
        XCTAssertEqual(AttachmentTransferStore.actionableSummary().failed, 1)

        try await downloader.persistAndAttempt(changes: [], token: try SyncRealmTestSupport.verifiedToken("session", realm: realm))
        let attemptCount = await transport.attempts()
        XCTAssertEqual(attemptCount, 2)
        XCTAssertEqual(
            AttachmentTransferStore.summary(memoIDs: [memoID.uuidString]).transferred,
            1
        )
        XCTAssertFalse(AttachmentTransferStore.actionableSummary().hasMedia)
        let installed = vault.appendingPathComponent(
            "raw/assets/sync/\(inspected.sha256)-remote.png"
        )
        XCTAssertEqual(try Data(contentsOf: installed), bytes)

        let tombstone = SyncRemoteChange(
            id: memoID,
            type: "photo",
            body: "",
            createdAt: remote.createdAt,
            pinnedAt: nil,
            location: nil,
            weather: nil,
            device: nil,
            source: "ios",
            vaultPath: nil,
            sourceModifiedAt: nil,
            contentHash: nil,
            syncRevision: 2,
            lastSyncDeviceId: nil,
            deletedAt: Date(),
            changeSequence: 2,
            attachmentManifestHash: nil,
            attachments: nil
        )
        try await downloader.persistAndAttempt(changes: [tombstone], token: try SyncRealmTestSupport.verifiedToken("session", realm: realm))
        XCTAssertFalse(
            AttachmentTransferStore.summary(memoIDs: [memoID.uuidString]).hasMedia
        )
        XCTAssertEqual(try Data(contentsOf: installed), bytes)
    }

    func testVerifiedDownloadStagingReplaysWithoutNetwork() async throws {
        let realm = try SyncRealmTestSupport.realm()
        let relativePath = "raw/assets/staging-source.png"
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 9, 8, 7, 6])
        let sourceURL = vault.appendingPathComponent(relativePath)
        try bytes.write(to: sourceURL)
        let inspected = try AttachmentFileInspector.inspect(
            relativePath: relativePath,
            kind: "photo"
        )
        let memoID = UUID()
        let descriptor = SyncAttachmentDescriptor(
            position: 0,
            kind: "photo",
            contentSHA256: inspected.sha256,
            sizeBytes: inspected.sizeBytes,
            mimeType: inspected.mimeType,
            objectKey: "\(realm.userID.uuidString.lowercased())/\(memoID.uuidString.lowercased())/\(inspected.sha256).png",
            originalFilename: "staged.png"
        )
        let item = try XCTUnwrap(
            AttachmentTransferStore.recordPendingDownloads(
                memoID: memoID,
                descriptors: [descriptor],
                realm: realm
            ).first
        )
        let stagingURL = SupabaseAttachmentDownloader.stagingURL(recordID: item.recordID)
        try FileManager.default.createDirectory(
            at: stagingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: stagingURL)
        let transport = FlakyAttachmentDownloadTransport(sourceURL: sourceURL)
        let downloader = SupabaseAttachmentDownloader(
            session: try SyncRealmTestSupport.session(realm: realm),
            fileTransport: transport
        )

        try await downloader.persistAndAttempt(changes: [], token: try SyncRealmTestSupport.verifiedToken("session", realm: realm))

        let attemptCount = await transport.attempts()
        XCTAssertEqual(attemptCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
        XCTAssertEqual(
            try Data(contentsOf: vault.appendingPathComponent(item.relativePath)),
            bytes
        )
        XCTAssertFalse(AttachmentTransferStore.actionableSummary().hasMedia)
    }

    func testDownloadRefusesSymlinkedAssetDirectoryAndPreservesForeignBytes() async throws {
        try await assertDownloadRefusesSymlink(at: "raw/assets/sync")
    }

    func testDownloadRefusesSymlinkedRawAncestorAndPreservesForeignBytes() async throws {
        try await assertDownloadRefusesSymlink(at: "raw")
    }

    func testDownloadRefusesSymlinkedStagingFileAndPreservesForeignBytes() async throws {
        try await assertDownloadRefusesSymlink(at: "staging-file")
    }

    func testTransferSidecarRefusesSymlinkedAncestorWithoutReadingOrRewritingIt() throws {
        let realm = try SyncRealmTestSupport.realm()
        let memoID = UUID()
        let hash = String(repeating: "a", count: 64)
        let descriptor = SyncAttachmentDescriptor(
            position: 0, kind: "photo", contentSHA256: hash, sizeBytes: 12,
            mimeType: "image/png",
            objectKey: "\(realm.userID.uuidString.lowercased())/\(memoID.uuidString.lowercased())/\(hash).png",
            originalFilename: "received.png"
        )
        _ = try AttachmentTransferStore.recordPendingDownloads(
            memoID: memoID, descriptors: [descriptor], realm: realm
        )
        let outside = SyncRealmTestSupport.fixtureRoot
            .appendingPathComponent("daypage-sidecar-foreign-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let sync = vault.appendingPathComponent("_agent/sync")
        let foreignSync = outside.appendingPathComponent("sync")
        try FileManager.default.moveItem(at: sync, to: foreignSync)
        try FileManager.default.createSymbolicLink(at: sync, withDestinationURL: foreignSync)
        let foreignState = foreignSync.appendingPathComponent(AttachmentTransferStore.stateURL.lastPathComponent)
        let previousBytes = try Data(contentsOf: foreignState)

        XCTAssertThrowsError(try AttachmentTransferStore.progress(realm: realm))
        XCTAssertThrowsError(try AttachmentTransferStore.recordPendingDownloads(
            memoID: memoID, descriptors: [descriptor], realm: realm
        ))
        XCTAssertEqual(try Data(contentsOf: foreignState), previousBytes)
    }

    func testDownloadRechecksDestinationAfterNetworkWait() async throws {
        let realm = try SyncRealmTestSupport.realm()
        let sourceURL = vault.appendingPathComponent("raw/assets/source.png")
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 2, 4, 6, 8])
        try bytes.write(to: sourceURL)
        let digest = try AttachmentFileInspector.sha256AndSize(of: sourceURL)
        let memoID = UUID()
        let descriptor = SyncAttachmentDescriptor(
            position: 0, kind: "photo", contentSHA256: digest.hash, sizeBytes: digest.size,
            mimeType: "image/png",
            objectKey: "\(realm.userID.uuidString.lowercased())/\(memoID.uuidString.lowercased())/\(digest.hash).png",
            originalFilename: "received.png"
        )
        _ = try AttachmentTransferStore.recordPendingDownloads(
            memoID: memoID, descriptors: [descriptor], realm: realm
        )
        let outside = SyncRealmTestSupport.fixtureRoot
            .appendingPathComponent("daypage-download-foreign-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let sentinel = outside.appendingPathComponent("keep.png")
        try bytes.write(to: sentinel)
        let downloader = SupabaseAttachmentDownloader(
            session: try SyncRealmTestSupport.session(realm: realm),
            fileTransport: PathSwappingAttachmentDownloadTransport(
                sourceURL: sourceURL,
                linkURL: vault.appendingPathComponent("raw/assets/sync"), outsideURL: outside
            )
        )

        try await downloader.persistAndAttempt(
            changes: [], token: try SyncRealmTestSupport.verifiedToken("session", realm: realm)
        )

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["keep.png"])
        XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
        XCTAssertTrue(try AttachmentTransferStore.progress(realm: realm).hasIncomplete)
        XCTAssertEqual(AttachmentTransferStore.summary(memoIDs: [memoID.uuidString]).transferred, 0)
    }

    private func assertDownloadRefusesSymlink(at relativeLink: String) async throws {
        let realm = try SyncRealmTestSupport.realm()
        let sourceURL = vault.appendingPathComponent("raw/assets/source.png")
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 6, 5, 4, 3])
        try bytes.write(to: sourceURL)
        let digest = try AttachmentFileInspector.sha256AndSize(of: sourceURL)
        let memoID = UUID()
        let descriptor = SyncAttachmentDescriptor(
            position: 0,
            kind: "photo",
            contentSHA256: digest.hash,
            sizeBytes: digest.size,
            mimeType: "image/png",
            objectKey: "\(realm.userID.uuidString.lowercased())/\(memoID.uuidString.lowercased())/\(digest.hash).png",
            originalFilename: "received.png"
        )
        let item = try XCTUnwrap(AttachmentTransferStore.recordPendingDownloads(
            memoID: memoID, descriptors: [descriptor], realm: realm
        ).first)
        let stagingURL = SupabaseAttachmentDownloader.stagingURL(recordID: item.recordID)
        try FileManager.default.createDirectory(
            at: stagingURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try bytes.write(to: stagingURL)

        let outside = SyncRealmTestSupport.fixtureRoot
            .appendingPathComponent("daypage-download-foreign-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let sentinel = outside.appendingPathComponent("keep.png")
        try bytes.write(to: sentinel)
        let link = relativeLink == "staging-file"
            ? stagingURL : vault.appendingPathComponent(relativeLink)
        if FileManager.default.fileExists(atPath: link.path) {
            try FileManager.default.removeItem(at: link)
        }
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: relativeLink == "staging-file" ? sentinel : outside
        )
        let foreignBefore = try FileManager.default.contentsOfDirectory(atPath: outside.path).sorted()
        let transport = FlakyAttachmentDownloadTransport(sourceURL: sentinel)
        let downloader = SupabaseAttachmentDownloader(
            session: try SyncRealmTestSupport.session(realm: realm), fileTransport: transport
        )

        try await downloader.persistAndAttempt(
            changes: [], token: try SyncRealmTestSupport.verifiedToken("session", realm: realm)
        )

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path).sorted(), foreignBefore)
        XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
        XCTAssertTrue(try AttachmentTransferStore.progress(realm: realm).hasIncomplete)
        XCTAssertEqual(AttachmentTransferStore.summary(memoIDs: [memoID.uuidString]).transferred, 0)
        let attempts = await transport.attempts()
        XCTAssertEqual(attempts, 0)
    }

    // MARK: - T18 safe media paths (explicit own-Vault local opening only)

    /// Only existing own-Vault local files may be opened; traversal, absolute
    /// paths, outside-Vault symlinks and missing files are refused — and
    /// there is no remote/signed URL surface in this path at all.
    func testSafeMediaPathsAllowOnlyExistingOwnVaultLocals() throws {
        let fm = FileManager.default
        let assets = vault.appendingPathComponent("raw/assets", isDirectory: true)
        for name in ["photo.png", "audio.aac", "movie.MOV", "doc.pdf"] {
            try Data([0x00]).write(to: assets.appendingPathComponent(name))
        }

        // Fixture set: photo / audio / movie / file all resolve inside the
        // Vault when they exist.
        for relative in [
            "raw/assets/photo.png",
            "raw/assets/audio.aac",
            "raw/assets/movie.MOV",
            "raw/assets/doc.pdf"
        ] {
            let url = try AttachmentFileInspector.safeLocalURL(relativePath: relative)
            XCTAssertTrue(
                url.standardizedFileURL.path.hasPrefix(
                    assets.resolvingSymlinksInPath().standardizedFileURL.path
                )
            )
        }

        // Traversal and absolute paths are refused.
        XCTAssertThrowsError(
            try AttachmentFileInspector.safeLocalURL(relativePath: "raw/assets/../../outside")
        )
        XCTAssertThrowsError(
            try AttachmentFileInspector.safeLocalURL(relativePath: "/absolute")
        )

        // A symlink escaping the Vault is refused.
        let outside = SyncRealmTestSupport.fixtureRoot
            .appendingPathComponent("daypage-media-outside-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }
        try fm.createSymbolicLink(
            at: assets.appendingPathComponent("link-outside"),
            withDestinationURL: outside
        )
        XCTAssertThrowsError(
            try AttachmentFileInspector.safeLocalURL(relativePath: "raw/assets/link-outside")
        )

        // Missing local files are a distinct typed failure ("待下载", never an
        // invented remote URL).
        XCTAssertThrowsError(
            try AttachmentFileInspector.safeLocalURL(relativePath: "raw/assets/missing.png")
        ) { error in
            XCTAssertEqual(
                error as? AttachmentSyncError,
                .missingFile("raw/assets/missing.png")
            )
        }
    }

    /// Review item 2: safeLocalURL is anchored to the canonical selected
    /// Vault. A symlinked `raw`/`assets` can never re-root the trust boundary
    /// outside the Vault; foreign, chained (multihop) and dangling links are
    /// refused; a single-hop in-Vault link to in-Vault media keeps working.
    func testSafeLocalURLRejectsSymlinkAttacksAndPreservesValidVaultMedia() throws {
        let fm = FileManager.default
        let assets = vault.appendingPathComponent("raw/assets", isDirectory: true)
        try Data([0x00]).write(to: assets.appendingPathComponent("photo.png"))

        let outside = SyncRealmTestSupport.fixtureRoot
            .appendingPathComponent("daypage-assets-outside-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }
        let sentinel = outside.appendingPathComponent("x.txt")
        try Data("outside-sentinel".utf8).write(to: sentinel)

        // The review repro: raw/assets (or raw) symlinked to a foreign dir
        // used to pass the prefix guard. Both must be refused now.
        let foreignAssets = vault.appendingPathComponent("_foreign_assets")
        try fm.createSymbolicLink(at: foreignAssets, withDestinationURL: outside)
        try fm.moveItem(at: assets, to: vault.appendingPathComponent("_real_assets"))
        try fm.createSymbolicLink(
            at: assets,
            withDestinationURL: outside.appendingPathComponent("x.txt").deletingLastPathComponent()
        )
        XCTAssertThrowsError(
            try AttachmentFileInspector.safeLocalURL(relativePath: "raw/assets/x.txt")
        ) { error in
            XCTAssertEqual(error as? AttachmentSyncError, .invalidPath("raw/assets/x.txt"))
        }
        XCTAssertThrowsError(
            try AttachmentFileInspector.safeLocalURL(relativePath: "raw/assets/photo.png")
        )

        // Chained (multihop) final-file link: link1 -> link2 -> outside.
        try fm.removeItem(at: assets)
        try fm.moveItem(at: vault.appendingPathComponent("_real_assets"), to: assets)
        try fm.createSymbolicLink(
            at: assets.appendingPathComponent("link2"),
            withDestinationURL: sentinel
        )
        try fm.createSymbolicLink(
            at: assets.appendingPathComponent("link1"),
            withDestinationURL: assets.appendingPathComponent("link2")
        )
        XCTAssertThrowsError(
            try AttachmentFileInspector.safeLocalURL(relativePath: "raw/assets/link1")
        ) { error in
            XCTAssertEqual(error as? AttachmentSyncError, .invalidPath("raw/assets/link1"))
        }

        // Dangling final-file link.
        try fm.createSymbolicLink(
            atPath: assets.appendingPathComponent("dangling").path,
            withDestinationPath: vault.appendingPathComponent("raw/assets/never-there.png").path
        )
        XCTAssertThrowsError(
            try AttachmentFileInspector.safeLocalURL(relativePath: "raw/assets/dangling")
        )

        // Foreign final-file link.
        try fm.createSymbolicLink(
            at: assets.appendingPathComponent("escape"),
            withDestinationURL: sentinel
        )
        XCTAssertThrowsError(
            try AttachmentFileInspector.safeLocalURL(relativePath: "raw/assets/escape")
        )

        // A single-hop in-Vault link to in-Vault media stays valid.
        try fm.createSymbolicLink(
            at: assets.appendingPathComponent("inside"),
            withDestinationURL: assets.appendingPathComponent("photo.png")
        )
        let inside = try AttachmentFileInspector.safeLocalURL(relativePath: "raw/assets/inside")
        XCTAssertTrue(
            inside.standardizedFileURL.path.hasSuffix("/raw/assets/photo.png"),
            "valid in-Vault local media keeps working"
        )

        // Nothing outside the Vault was adopted or written.
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("outside-sentinel".utf8))
        XCTAssertFalse(fm.fileExists(atPath: outside.appendingPathComponent("photo.png").path))
    }

    func testQuickTimeAndAACInspectAcceptStructurallyConsistentHeaders() throws {
        let aacPath = "raw/assets/voice-note.aac"
        let aacBytes = adtsFrame(frameLength: 32) + adtsFrame(frameLength: 48)
        try aacBytes.write(to: vault.appendingPathComponent(aacPath))
        let aac = try AttachmentFileInspector.inspect(relativePath: aacPath, kind: "audio")
        XCTAssertEqual(aac.mimeType, "audio/aac")
        XCTAssertEqual(aac.canonicalExtension, "aac")
        XCTAssertEqual(aac.sizeBytes, Int64(aacBytes.count))

        let movPath = "raw/assets/clip.mov"
        let movBytes = quickTimeMovie()
        try movBytes.write(to: vault.appendingPathComponent(movPath))
        let mov = try AttachmentFileInspector.inspect(relativePath: movPath, kind: "file")
        XCTAssertEqual(mov.mimeType, "video/quicktime")
        XCTAssertEqual(mov.canonicalExtension, "mov")
        XCTAssertEqual(mov.sizeBytes, Int64(movBytes.count))

        let aacDescriptor = importedDescriptor(
            kind: "audio",
            mimeType: "audio/aac",
            extension: "aac",
            digest: aac.sha256,
            sizeBytes: aac.sizeBytes
        )
        let movDescriptor = importedDescriptor(
            kind: "file",
            mimeType: "video/quicktime",
            extension: "mov",
            digest: mov.sha256,
            sizeBytes: mov.sizeBytes
        )
        XCTAssertTrue(AttachmentManifest.isStructurallyValid([aacDescriptor]))
        XCTAssertTrue(AttachmentManifest.isStructurallyValid([movDescriptor]))
        XCTAssertNoThrow(try AttachmentFileInspector.verify(url: aac.url, descriptor: aacDescriptor))
        XCTAssertNoThrow(try AttachmentFileInspector.verify(url: mov.url, descriptor: movDescriptor))
    }

    func testImportedMediaRejectsSpoofedRenamedAndTruncatedBytes() throws {
        try Data("definitely not aac".utf8).write(
            to: vault.appendingPathComponent("raw/assets/spoofed.aac")
        )
        XCTAssertThrowsError(
            try AttachmentFileInspector.inspect(relativePath: "raw/assets/spoofed.aac", kind: "audio")
        ) { error in
            guard case AttachmentSyncError.mimeMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        try Data("definitely not mov".utf8).write(
            to: vault.appendingPathComponent("raw/assets/spoofed.mov")
        )
        XCTAssertThrowsError(
            try AttachmentFileInspector.inspect(relativePath: "raw/assets/spoofed.mov", kind: "file")
        ) { error in
            guard case AttachmentSyncError.mimeMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        // Renamed: valid ADTS bytes behind an m4a name fail the ISO-BMFF check.
        try adtsFrame(frameLength: 32).write(
            to: vault.appendingPathComponent("raw/assets/renamed.m4a")
        )
        XCTAssertThrowsError(
            try AttachmentFileInspector.inspect(relativePath: "raw/assets/renamed.m4a", kind: "audio")
        ) { error in
            guard case AttachmentSyncError.mimeMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        // Renamed: QuickTime bytes behind a pdf name fail the PDF check.
        try quickTimeMovie().write(
            to: vault.appendingPathComponent("raw/assets/renamed.pdf")
        )
        XCTAssertThrowsError(
            try AttachmentFileInspector.inspect(relativePath: "raw/assets/renamed.pdf", kind: "file")
        ) { error in
            guard case AttachmentSyncError.mimeMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        // Truncated: the declared ADTS frame length runs past EOF.
        let truncatedAAC = Data(adtsFrame(frameLength: 64).prefix(20))
        try truncatedAAC.write(
            to: vault.appendingPathComponent("raw/assets/truncated.aac")
        )
        XCTAssertThrowsError(
            try AttachmentFileInspector.inspect(relativePath: "raw/assets/truncated.aac", kind: "audio")
        ) { error in
            guard case AttachmentSyncError.mimeMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        // Truncated: the ftyp box length runs past EOF.
        try quickTimeFile(declaredBoxSize: 4096).write(
            to: vault.appendingPathComponent("raw/assets/truncated.mov")
        )
        XCTAssertThrowsError(
            try AttachmentFileInspector.inspect(relativePath: "raw/assets/truncated.mov", kind: "file")
        ) { error in
            guard case AttachmentSyncError.mimeMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        // Inconsistent ADTS headers: the sampling-frequency index changes mid-stream.
        let inconsistentAAC = adtsFrame(frameLength: 32) + adtsFrame(frameLength: 32, sampleIndex: 3)
        try inconsistentAAC.write(
            to: vault.appendingPathComponent("raw/assets/inconsistent.aac")
        )
        XCTAssertThrowsError(
            try AttachmentFileInspector.inspect(relativePath: "raw/assets/inconsistent.aac", kind: "audio")
        ) { error in
            guard case AttachmentSyncError.mimeMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        // Spoofed near-miss ADTS sync with a non-zero layer.
        var badLayer = adtsFrame(frameLength: 32)
        badLayer[1] = 0xf3
        try badLayer.write(to: vault.appendingPathComponent("raw/assets/bad-layer.aac"))
        XCTAssertThrowsError(
            try AttachmentFileInspector.inspect(relativePath: "raw/assets/bad-layer.aac", kind: "audio")
        ) { error in
            guard case AttachmentSyncError.mimeMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testADTSRejectsReservedSamplingFrequencyIndexes() throws {
        // ADTS sampling-frequency indexes 13 and 14 are reserved and 15 is the
        // escape value; all must fail closed instead of being treated as audio.
        for sampleIndex in [UInt8(13), 14, 15] {
            let relativePath = "raw/assets/reserved-index-\(sampleIndex).aac"
            try adtsFrame(frameLength: 32, sampleIndex: sampleIndex).write(
                to: vault.appendingPathComponent(relativePath)
            )
            XCTAssertThrowsError(
                try AttachmentFileInspector.inspect(relativePath: relativePath, kind: "audio")
            ) { error in
                guard case AttachmentSyncError.mimeMismatch = error else {
                    return XCTFail("unexpected error for index \(sampleIndex): \(error)")
                }
            }
        }

        // The valid range boundary (index 12) still inspects cleanly.
        let validPath = "raw/assets/valid-index-12.aac"
        try adtsFrame(frameLength: 32, sampleIndex: 12).write(
            to: vault.appendingPathComponent(validPath)
        )
        let valid = try AttachmentFileInspector.inspect(relativePath: validPath, kind: "audio")
        XCTAssertEqual(valid.mimeType, "audio/aac")
    }

    func testQuickTimeSpecialSizeFormsRequireAlignedAtomLengths() throws {
        // size = 0 (box extends to end of file): a 20-byte ftyp box with one
        // compatible brand is structurally consistent.
        let eofPath = "raw/assets/eof-box.mov"
        let eofBytes = quickTimeFile(declaredBoxSize: 0)
        try eofBytes.write(to: vault.appendingPathComponent(eofPath))
        let eof = try AttachmentFileInspector.inspect(relativePath: eofPath, kind: "file")
        XCTAssertEqual(eof.mimeType, "video/quicktime")
        XCTAssertEqual(eof.sizeBytes, Int64(eofBytes.count))

        // size = 1 (64-bit largesize): a 28-byte ftyp box with one compatible
        // brand is structurally consistent.
        let largePath = "raw/assets/largesize-box.mov"
        let largeBytes = quickTimeLargesizeFile(largeSize: 28)
        try largeBytes.write(to: vault.appendingPathComponent(largePath))
        let large = try AttachmentFileInspector.inspect(relativePath: largePath, kind: "file")
        XCTAssertEqual(large.mimeType, "video/quicktime")
        XCTAssertEqual(large.sizeBytes, Int64(largeBytes.count))

        // Misaligned size = 0 repro: 16 fixed bytes plus one trailing byte.
        var misalignedEOF = quickTimeFile(declaredBoxSize: 0, compatibleBrands: [])
        misalignedEOF.append(Data([0x78]))
        try misalignedEOF.write(
            to: vault.appendingPathComponent("raw/assets/misaligned-eof.mov")
        )
        XCTAssertThrowsError(
            try AttachmentFileInspector.inspect(
                relativePath: "raw/assets/misaligned-eof.mov",
                kind: "file"
            )
        ) { error in
            guard case AttachmentSyncError.mimeMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        // Misaligned size = 1 repro: largesize 25 = 24 fixed bytes + 1 byte.
        let misalignedLarge = quickTimeLargesizeFile(
            largeSize: 25,
            compatibleBrands: [],
            trailingByte: 0x78
        )
        try misalignedLarge.write(
            to: vault.appendingPathComponent("raw/assets/misaligned-largesize.mov")
        )
        XCTAssertThrowsError(
            try AttachmentFileInspector.inspect(
                relativePath: "raw/assets/misaligned-largesize.mov",
                kind: "file"
            )
        ) { error in
            guard case AttachmentSyncError.mimeMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        // Truncated largesize header: the size = 1 form needs 24 header bytes
        // (size + type + largesize + major brand + minor version) before any
        // compatible brand; this 18-byte cut must fail closed.
        let truncatedHeader = Data([0x00, 0x00, 0x00, 0x01]) + Data("ftyp".utf8)
            + Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1c, 0x71, 0x74])
        try truncatedHeader.write(
            to: vault.appendingPathComponent("raw/assets/truncated-largesize.mov")
        )
        XCTAssertThrowsError(
            try AttachmentFileInspector.inspect(
                relativePath: "raw/assets/truncated-largesize.mov",
                kind: "file"
            )
        ) { error in
            guard case AttachmentSyncError.mimeMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        // Largesize that runs past end of file.
        let pastEOF = quickTimeLargesizeFile(largeSize: 64)
        try pastEOF.write(
            to: vault.appendingPathComponent("raw/assets/largesize-past-eof.mov")
        )
        XCTAssertThrowsError(
            try AttachmentFileInspector.inspect(
                relativePath: "raw/assets/largesize-past-eof.mov",
                kind: "file"
            )
        ) { error in
            guard case AttachmentSyncError.mimeMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testQuickTimeRequiresExplicitCompatibleBrand() throws {
        let invalidFiles = [
            quickTimeFile(compatibleBrands: ["isom"]),
            quickTimeFile(compatibleBrands: []),
            quickTimeFile(declaredBoxSize: 0, compatibleBrands: ["isom"]),
            quickTimeLargesizeFile(largeSize: 28, compatibleBrands: ["isom"]),
        ]
        for (index, bytes) in invalidFiles.enumerated() {
            let path = "raw/assets/no-quicktime-compatibility-\(index).mov"
            try bytes.write(to: vault.appendingPathComponent(path))
            XCTAssertThrowsError(try AttachmentFileInspector.inspect(relativePath: path, kind: "file")) {
                guard case AttachmentSyncError.mimeMismatch = $0 else {
                    return XCTFail("unexpected error: \($0)")
                }
            }
        }
        let path = "raw/assets/explicit-quicktime-compatible.mov"
        try quickTimeFile(compatibleBrands: ["isom", "qt  "]).write(to: vault.appendingPathComponent(path))
        XCTAssertNoThrow(try AttachmentFileInspector.inspect(relativePath: path, kind: "file"))
    }

    func testImportedMediaRejectsWrongKindAndUnsupportedBrand() throws {
        try quickTimeMovie().write(to: vault.appendingPathComponent("raw/assets/clip.mov"))
        for kind in ["photo", "audio"] {
            XCTAssertThrowsError(
                try AttachmentFileInspector.inspect(relativePath: "raw/assets/clip.mov", kind: kind)
            ) { error in
                guard case AttachmentSyncError.unsupportedType = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }

        try adtsFrame(frameLength: 32).write(
            to: vault.appendingPathComponent("raw/assets/voice.aac")
        )
        for kind in ["file", "photo"] {
            XCTAssertThrowsError(
                try AttachmentFileInspector.inspect(relativePath: "raw/assets/voice.aac", kind: kind)
            ) { error in
                guard case AttachmentSyncError.unsupportedType = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }

        // Unsupported brand: an ISO-BMFF ftyp box is not a QuickTime MOV.
        try quickTimeMovie(brand: "isom").write(
            to: vault.appendingPathComponent("raw/assets/isom.mov")
        )
        XCTAssertThrowsError(
            try AttachmentFileInspector.inspect(relativePath: "raw/assets/isom.mov", kind: "file")
        ) { error in
            guard case AttachmentSyncError.mimeMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let digest = String(repeating: "e", count: 64)
        let movAsPhoto = importedDescriptor(
            kind: "photo",
            mimeType: "video/quicktime",
            extension: "mov",
            digest: digest,
            sizeBytes: 8_192
        )
        let aacAsFile = importedDescriptor(
            kind: "file",
            mimeType: "audio/aac",
            extension: "aac",
            digest: digest,
            sizeBytes: 4_096
        )
        let movAsAudio = importedDescriptor(
            kind: "audio",
            mimeType: "video/quicktime",
            extension: "mov",
            digest: digest,
            sizeBytes: 8_192
        )
        XCTAssertFalse(AttachmentManifest.isStructurallyValid([movAsPhoto]))
        XCTAssertFalse(AttachmentManifest.isStructurallyValid([aacAsFile]))
        XCTAssertFalse(AttachmentManifest.isStructurallyValid([movAsAudio]))
    }
}

/// Transfer sidecar realm binding: unknown legacy state is held and preserved,
/// foreign realms never rebind, genuine first claims bind exactly once, and
/// hostile saved/new TUS URLs or redirects are refused before any bearer is
/// forwarded.
final class AttachmentTransferRealmTests: XCTestCase {
    private var vault: URL!

    override func setUpWithError() throws {
        vault = SyncRealmTestSupport.fixtureRoot
            .appendingPathComponent("daypage-transfer-realm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("raw/assets", isDirectory: true),
            withIntermediateDirectories: true
        )
        VaultInitializer.testOverrideURL = vault
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = nil
        if let vault { try? FileManager.default.removeItem(at: vault) }
    }

    private var sidecarURL: URL { AttachmentTransferStore.stateURL }

    private func writeSidecar(_ json: String) throws {
        try FileManager.default.createDirectory(
            at: sidecarURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(json.utf8).write(to: sidecarURL)
    }

    private func makeOperation(memo: Memo) -> SyncOutboxOperation {
        SyncOutboxOperation(
            operationID: UUID(),
            memoID: memo.id,
            kind: .upsert,
            revision: 1,
            modifiedAt: Date(),
            contentHash: SyncOutboxStore.contentHash(for: memo),
            deviceID: UUID().uuidString.lowercased(),
            payload: nil,
            sizeBytes: memo.toMarkdown().utf8.count
        )
    }

    func testUnknownLegacyTransferStateIsHeldAndPreserved() throws {
        let legacy = """
        {"records":[{"id":"upload:legacy","status":"pending"}],"schema_version":1}
        """
        try writeSidecar(legacy)
        let realm = try SyncRealmTestSupport.realm()
        let memo = Memo(body: "held note")
        let operation = makeOperation(memo: memo)

        XCTAssertThrowsError(
            try AttachmentTransferStore.prepareUploads(operation: operation, memo: memo, realm: realm)
        ) { error in
            XCTAssertEqual(error as? SyncRealmError, .legacyRealmUnverified)
        }
        XCTAssertThrowsError(
            try AttachmentTransferStore.pendingDownloads(realm: realm)
        )
        XCTAssertThrowsError(
            try AttachmentTransferStore.discardTransfers(memoIDs: [memo.id], realm: realm)
        )
        // Held state is never cleared, rewritten or guessed into the realm.
        XCTAssertEqual(try Data(contentsOf: sidecarURL), Data(legacy.utf8))
    }

    func testForeignRealmHeaderHoldsAndNeverRebinds() throws {
        let foreign = try SyncRealmTestSupport.realm(origin: "https://foreign.example")
        let foreignState = """
        {"realm_origin":"https://foreign.example","realm_user_id":"\(foreign.userID.uuidString.lowercased())","records":[{"direction":"upload","id":"upload:foreign","local_path":"raw/assets/foreign.png","memo_id":"\(UUID().uuidString.lowercased())","descriptor":{"content_sha256":"\(String(repeating: "c", count: 64))","kind":"photo","mime_type":"image/png","object_key":"\(foreign.userID.uuidString.lowercased())/\(UUID().uuidString.lowercased())/\(String(repeating: "c", count: 64)).png","original_filename":"foreign.png","position":0,"size_bytes":8},"status":"pending","upload_offset":0,"updated_at":"2026-10-01T00:00:00Z"}],"schema_version":1}
        """
        try writeSidecar(foreignState)

        let mine = try SyncRealmTestSupport.realm(origin: "https://foreign.example")
        XCTAssertThrowsError(
            try AttachmentTransferStore.pendingDownloads(realm: mine)
        ) { error in
            XCTAssertEqual(error as? SyncRealmError, .realmMismatch)
        }
        XCTAssertEqual(try Data(contentsOf: sidecarURL), Data(foreignState.utf8))

        // The proven owner keeps working without any header rewrite.
        let items = try AttachmentTransferStore.pendingDownloads(realm: foreign)
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: - T14 complete, capped-free media progress

    /// `progress(realm:)` counts EVERY obligation (no 50/200 cap), groups
    /// upload/download by status, counts blocked upload-preparation records,
    /// and THROWS (never zero) on foreign/unproven/corrupt sidecars.
    func testTransferProgressCountsEveryObligationWithoutCapsAndFailsClosed() throws {
        let realm = try SyncRealmTestSupport.realm()

        // Claimable empty state is a VERIFIED zero.
        let zero = try AttachmentTransferStore.progress(realm: realm)
        XCTAssertEqual(zero, AttachmentTransferStore.TransferProgress())
        XCTAssertFalse(zero.hasIncomplete)

        // 250 download obligations (249 pending + 1 failed), 1 paused upload,
        // 1 transferred upload (finished), 1 blocked preparation record.
        var records: [String] = []
        for index in 0..<250 {
            let status = index == 0 ? "failed" : "pending"
            records.append(progressRecordJSON(
                id: "download:\(index)",
                memoID: UUID().uuidString.lowercased(),
                direction: "download",
                status: status,
                realm: realm
            ))
        }
        records.append(progressRecordJSON(
            id: "upload:paused",
            memoID: UUID().uuidString.lowercased(),
            direction: "upload",
            status: "paused",
            realm: realm
        ))
        records.append(progressRecordJSON(
            id: "upload:done",
            memoID: UUID().uuidString.lowercased(),
            direction: "upload",
            status: "transferred",
            realm: realm
        ))
        let blockedMemo = UUID().uuidString.lowercased()
        try writeSidecar("""
        {"schema_version":1,"realm_origin":"\(realm.normalizedOrigin)","realm_user_id":"\(realm.userID.uuidString.lowercased())","records":[\(records.joined(separator: ","))],"blocked_records":[{"operation_id":"\(UUID().uuidString.lowercased())","memo_id":"\(blockedMemo)","local_path":"raw/assets/blocked.png","status":"failed","error_code":"local_validation","updated_at":"2026-10-01T00:00:00Z"}]}
        """)

        let progress = try AttachmentTransferStore.progress(realm: realm)
        XCTAssertEqual(progress.download.pending, 249)
        XCTAssertEqual(progress.download.failed, 1)
        XCTAssertEqual(progress.download.transferred, 0)
        XCTAssertEqual(progress.upload.paused, 1)
        XCTAssertEqual(progress.upload.transferred, 1)
        XCTAssertEqual(progress.upload.unfinished, 1)
        XCTAssertEqual(progress.blocked, 1)
        // Far beyond the pendingDownloads 200 cap — every row counts.
        XCTAssertGreaterThan(progress.download.pending + progress.download.failed, 200)
        XCTAssertTrue(progress.hasIncomplete)
        XCTAssertEqual(progress.unfinishedTotal, 252)

        // Only an all-transferred state with zero blocked is complete.
        try AttachmentTransferStore.discardTransfers(
            memoIDs: [],
            realm: realm
        )
    }

    /// Foreign, unproven and corrupt sidecars THROW for progress — health
    /// stays "unknown" instead of a fake verified zero.
    func testTransferProgressFailsClosedOnForeignUnprovenAndCorruptState() throws {
        let foreign = try SyncRealmTestSupport.realm(origin: "https://foreign.example")
        let record = progressRecordJSON(
            id: "download:1",
            memoID: UUID().uuidString.lowercased(),
            direction: "download",
            status: "pending",
            realm: foreign
        )
        try writeSidecar("""
        {"schema_version":1,"realm_origin":"https://foreign.example","realm_user_id":"\(foreign.userID.uuidString.lowercased())","records":[\(record)]}
        """)
        let mine = try SyncRealmTestSupport.realm(origin: "https://foreign.example")
        XCTAssertThrowsError(try AttachmentTransferStore.progress(realm: mine)) { error in
            XCTAssertEqual(error as? SyncRealmError, .realmMismatch)
        }

        // Unproven legacy header-less state is held, never counted as zero.
        try writeSidecar("""
        {"schema_version":1,"records":[\(record)]}
        """)
        XCTAssertThrowsError(try AttachmentTransferStore.progress(realm: mine)) { error in
            XCTAssertEqual(error as? SyncRealmError, .legacyRealmUnverified)
        }

        // Corrupt bytes are unknown, never zero.
        try Data("{corrupt".utf8).write(to: sidecarURL)
        XCTAssertThrowsError(try AttachmentTransferStore.progress(realm: mine))
    }

    private func progressRecordJSON(
        id: String,
        memoID: String,
        direction: String,
        status: String,
        realm: SyncRealmIdentity
    ) -> String {
        let sha = String(repeating: "d", count: 64)
        return """
        {"id":"\(id)","memo_id":"\(memoID)","local_path":"raw/assets/sync/\(sha)-sample.png","descriptor":{"position":0,"kind":"photo","content_sha256":"\(sha)","size_bytes":8,"mime_type":"image/png","object_key":"\(realm.userID.uuidString.lowercased())/\(memoID)/\(sha).png","original_filename":"sample.png"},"direction":"\(direction)","status":"\(status)","upload_offset":0,"updated_at":"2026-10-01T00:00:00Z"}
        """
    }

    func testFirstClaimBindsSidecarHeaderOnce() throws {
        let realm = try SyncRealmTestSupport.realm()
        let memo = Memo(
            type: .photo,
            attachments: [Memo.Attachment(file: "raw/assets/claim.png", kind: "photo")],
            body: "claim"
        )
        try Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2]).write(
            to: vault.appendingPathComponent("raw/assets/claim.png")
        )

        let operation = makeOperation(memo: memo)
        let first = try AttachmentTransferStore.prepareUploads(
            operation: operation,
            memo: memo,
            realm: realm
        )
        let stateBytes = try Data(contentsOf: sidecarURL)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: stateBytes) as? [String: Any])
        XCTAssertEqual(state["realm_origin"] as? String, realm.normalizedOrigin)
        XCTAssertEqual(state["realm_user_id"] as? String, realm.userID.uuidString.lowercased())

        // Restart under the same realm reuses the same records (no rebuild of
        // operation IDs or revisions); a different realm is held.
        let retry = try AttachmentTransferStore.prepareUploads(
            operation: operation,
            memo: memo,
            realm: realm
        )
        XCTAssertEqual(retry.count, 1)
        XCTAssertEqual(retry.map(\.recordID), first.map(\.recordID))
        XCTAssertEqual(try Data(contentsOf: sidecarURL), stateBytes)
        XCTAssertThrowsError(
            try AttachmentTransferStore.pendingDownloads(
                realm: SyncRealmTestSupport.realm(origin: "https://other.example")
            )
        )
    }

    func testObjectKeyUserOrMemoMismatchIsRejected() throws {
        let realm = try SyncRealmTestSupport.realm()
        let memoID = UUID()
        let digest = String(repeating: "b", count: 64)
        let foreignKey = SyncAttachmentDescriptor(
            position: 0,
            kind: "photo",
            contentSHA256: digest,
            sizeBytes: 8,
            mimeType: "image/png",
            objectKey: "\(UUID().uuidString.lowercased())/\(memoID.uuidString.lowercased())/\(digest).png",
            originalFilename: "x.png"
        )
        let wrongMemoKey = SyncAttachmentDescriptor(
            position: 0,
            kind: "photo",
            contentSHA256: digest,
            sizeBytes: 8,
            mimeType: "image/png",
            objectKey: "\(realm.userID.uuidString.lowercased())/\(UUID().uuidString.lowercased())/\(digest).png",
            originalFilename: "x.png"
        )
        for descriptor in [foreignKey, wrongMemoKey] {
            XCTAssertThrowsError(
                try AttachmentTransferStore.recordPendingDownloads(
                    memoID: memoID,
                    descriptors: [descriptor],
                    realm: realm
                )
            ) { error in
                XCTAssertEqual(error as? AttachmentSyncError, .objectKeyMismatch)
            }
        }
    }

    func testSavedForeignResumableURLIsRefusedBeforeAnyHead() async throws {
        let realm = try SyncRealmTestSupport.realm()
        let session = try SyncRealmTestSupport.session(realm: realm)
        let relativePath = "raw/assets/large-upload.png"
        var bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        bytes.append(Data(repeating: 0x42, count: 6 * 1_024 * 1_024))
        try bytes.write(to: vault.appendingPathComponent(relativePath))
        let inspected = try AttachmentFileInspector.inspect(relativePath: relativePath, kind: "photo")
        let memo = Memo(
            type: .photo,
            attachments: [Memo.Attachment(file: relativePath, kind: "photo")],
            body: "large media"
        )
        try RawStorage.append(memo)
        let memoID = memo.id
        let descriptor = SyncAttachmentDescriptor(
            position: 0,
            kind: "photo",
            contentSHA256: inspected.sha256,
            sizeBytes: inspected.sizeBytes,
            mimeType: inspected.mimeType,
            objectKey: "\(realm.userID.uuidString.lowercased())/\(memoID.uuidString.lowercased())/\(inspected.sha256).png",
            originalFilename: "large.png"
        )
        let operation = SyncOutboxOperation(
            operationID: UUID(),
            memoID: memoID,
            kind: .upsert,
            revision: 1,
            modifiedAt: Date(),
            contentHash: SyncOutboxStore.contentHash(for: memo),
            deviceID: UUID().uuidString.lowercased(),
            payload: SyncMemoPayload(
                type: "photo",
                body: "large media",
                createdAt: memo.created,
                pinnedAt: nil,
                location: nil,
                weather: nil,
                device: nil,
                source: "ios",
                vaultPath: "raw/large.md"
            ),
            sizeBytes: memo.toMarkdown().utf8.count
        )
        _ = try AttachmentTransferStore.prepareUploads(
            operation: operation,
            memo: memo,
            realm: realm
        )
        // Tampered legacy-style sidecar: proven header but a hostile saved
        // TUS URL. It must be refused BEFORE any HEAD/PATCH or bearer.
        let recordID = "upload:\(operation.operationID.uuidString.lowercased()):0"
        let savedURL = "\(realm.normalizedOrigin)/storage/v1/upload/resumable/pending0"
        try AttachmentTransferStore.update(
            recordID: recordID,
            status: .transferring,
            realm: realm,
            resumableURL: XCTUnwrap(URL(string: savedURL)),
            uploadOffset: 7
        )
        var sidecar = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: sidecarURL)) as? [String: Any]
        )
        var records = try XCTUnwrap(sidecar["records"] as? [[String: Any]])
        let index = try XCTUnwrap(records.firstIndex { $0["id"] as? String == recordID })
        XCTAssertEqual(records[index]["resumable_url"] as? String, savedURL)
        records[index]["resumable_url"] = "https://evil.example/storage/v1/upload/resumable/stolen"
        sidecar["records"] = records
        try JSONSerialization.data(withJSONObject: sidecar, options: [.sortedKeys]).write(to: sidecarURL)

        let recorder = RequestRecordingTransport(prepareKey: descriptor.objectKey)
        let uploader = SupabaseSyncUploader(
            session: session,
            transport: recorder,
            fileTransport: recorder,
            accessTokenProvider: { try SyncRealmTestSupport.token(realm: realm) }
        )
        do {
            _ = try await uploader.upload(operation: operation)
            XCTFail("hostile saved TUS URL must be refused")
        } catch {
            XCTAssertEqual(error as? SyncRealmError, .invalidResumableURL)
        }
        // Zero cross-domain requests: only the same-origin prepare RPC ran.
        let calls = recorder.calls
        XCTAssertTrue(calls.allSatisfy { $0.hasPrefix(realm.normalizedOrigin) })
        XCTAssertFalse(calls.contains { $0.contains("evil.example") })
        XCTAssertEqual(calls.count, 1)
    }

    func testForeignTUSLocationIsRefusedBeforeAnyPatch() async throws {
        let realm = try SyncRealmTestSupport.realm()
        let session = try SyncRealmTestSupport.session(realm: realm)
        let relativePath = "raw/assets/large-location.png"
        var bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        bytes.append(Data(repeating: 0x43, count: 6 * 1_024 * 1_024))
        try bytes.write(to: vault.appendingPathComponent(relativePath))
        let inspected = try AttachmentFileInspector.inspect(relativePath: relativePath, kind: "photo")
        let memo = Memo(
            type: .photo,
            attachments: [Memo.Attachment(file: relativePath, kind: "photo")],
            body: "large media"
        )
        try RawStorage.append(memo)
        let memoID = memo.id
        let descriptor = SyncAttachmentDescriptor(
            position: 0,
            kind: "photo",
            contentSHA256: inspected.sha256,
            sizeBytes: inspected.sizeBytes,
            mimeType: inspected.mimeType,
            objectKey: "\(realm.userID.uuidString.lowercased())/\(memoID.uuidString.lowercased())/\(inspected.sha256).png",
            originalFilename: "large.png"
        )
        let operation = SyncOutboxOperation(
            operationID: UUID(),
            memoID: memoID,
            kind: .upsert,
            revision: 1,
            modifiedAt: Date(),
            contentHash: SyncOutboxStore.contentHash(for: memo),
            deviceID: UUID().uuidString.lowercased(),
            payload: SyncMemoPayload(
                type: "photo",
                body: "large media",
                createdAt: memo.created,
                pinnedAt: nil,
                location: nil,
                weather: nil,
                device: nil,
                source: "ios",
                vaultPath: "raw/large.md"
            ),
            sizeBytes: memo.toMarkdown().utf8.count
        )
        _ = try AttachmentTransferStore.prepareUploads(
            operation: operation,
            memo: memo,
            realm: realm
        )
        // The fresh Location points at another authority: refused before PATCH.
        let recorder = RequestRecordingTransport(
            prepareKey: descriptor.objectKey,
            location: "https://evil.example/storage/v1/upload/resumable/stolen"
        )
        let uploader = SupabaseSyncUploader(
            session: session,
            transport: recorder,
            fileTransport: recorder,
            accessTokenProvider: { try SyncRealmTestSupport.token(realm: realm) }
        )
        do {
            _ = try await uploader.upload(operation: operation)
            XCTFail("foreign TUS Location must be refused")
        } catch {
            XCTAssertEqual(error as? SyncRealmError, .invalidResumableURL)
        }
        let calls = recorder.calls
        XCTAssertFalse(calls.contains { $0.contains("evil.example") })
        XCTAssertEqual(calls.count, 2) // prepare RPC + same-origin TUS create
    }

    func testResumableEndpointAcceptsOnlyCanonicalSameOriginURLs() throws {
        let origin = try SyncRealmOrigin(validating: "https://a.example")
        XCTAssertNoThrow(try SyncResumableEndpoint.validated(
            URL(string: "https://a.example/storage/v1/upload/resumable/9f8e-77")!,
            origin: origin
        ))
        let rejected = [
            "https://evil.example/storage/v1/upload/resumable/9f8e-77",
            "https://a.example.evil.example/storage/v1/upload/resumable/9f8e-77",
            "https://a.example/storage/v1/upload/resumable/9f8e-77?x=1",
            "https://a.example/storage/v1/upload/resumable/9f8e-77#x",
            "https://a.example/storage/v1/upload/resumable/../object/x",
            "https://a.example/storage/v1/upload/resumable/%2e%2e",
            "https://a.example/storage/v1/upload/resumable/",
            "https://a.example/storage/v1/upload/resumable",
            "https://a.example/storage/v1/object/memo-attachments/x",
            "https://user:pass@a.example/storage/v1/upload/resumable/9f8e-77",
            "https://a.example:8443/storage/v1/upload/resumable/9f8e-77",
            "http://a.example/storage/v1/upload/resumable/9f8e-77",
        ]
        for raw in rejected {
            XCTAssertThrowsError(
                try SyncResumableEndpoint.validated(URL(string: raw)!, origin: origin),
                "expected rejection for \(raw)"
            ) { error in
                XCTAssertEqual(error as? SyncRealmError, .invalidResumableURL)
            }
        }
    }
    /// Retryable HEAD failures (auth refresh, rate limits, server errors,
    /// malformed responses) must preserve saved resumable progress; only a
    /// documented expired/not-found upload (404/410) resets it. Same-realm
    /// retry then reuses the valid saved URL/offset.
    func testResumableHeadFailuresPreserveSavedProgressAndOnlyExpiryResets() async throws {
        let realm = try SyncRealmTestSupport.realm()
        let session = try SyncRealmTestSupport.session(realm: realm)
        let relativePath = "raw/assets/head-progress.png"
        var bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        bytes.append(Data(repeating: 0x44, count: 6 * 1_024 * 1_024))
        try bytes.write(to: vault.appendingPathComponent(relativePath))
        let inspected = try AttachmentFileInspector.inspect(relativePath: relativePath, kind: "photo")
        let memo = Memo(
            type: .photo,
            attachments: [Memo.Attachment(file: relativePath, kind: "photo")],
            body: "head progress"
        )
        try RawStorage.append(memo)
        let memoID = memo.id
        let descriptor = SyncAttachmentDescriptor(
            position: 0,
            kind: "photo",
            contentSHA256: inspected.sha256,
            sizeBytes: inspected.sizeBytes,
            mimeType: inspected.mimeType,
            objectKey: "\(realm.userID.uuidString.lowercased())/\(memoID.uuidString.lowercased())/\(inspected.sha256).png",
            originalFilename: "head.png"
        )
        let operation = SyncOutboxOperation(
            operationID: UUID(),
            memoID: memoID,
            kind: .upsert,
            revision: 1,
            modifiedAt: Date(),
            contentHash: SyncOutboxStore.contentHash(for: memo),
            deviceID: UUID().uuidString.lowercased(),
            payload: SyncMemoPayload(
                type: "photo",
                body: "head progress",
                createdAt: memo.created,
                pinnedAt: nil,
                location: nil,
                weather: nil,
                device: nil,
                source: "ios",
                vaultPath: "raw/head.md"
            ),
            sizeBytes: memo.toMarkdown().utf8.count
        )
        _ = try AttachmentTransferStore.prepareUploads(
            operation: operation,
            memo: memo,
            realm: realm
        )
        let recordID = "upload:\(operation.operationID.uuidString.lowercased()):0"
        let savedURL = "\(realm.normalizedOrigin)/storage/v1/upload/resumable/pending0"

        func seedProgress() throws {
            try AttachmentTransferStore.update(
                recordID: recordID,
                status: .transferring,
                realm: realm,
                resumableURL: XCTUnwrap(URL(string: savedURL)),
                uploadOffset: 7
            )
        }
        func savedState() throws -> (url: URL?, offset: Int64) {
            try AttachmentTransferStore.resumableState(recordID: recordID, realm: realm)
        }

        let preservationCases: [(Int, String?, (Error) -> Bool)] = [
            (401, nil, { if case MemoSyncError.unauthorized = $0 { return true }; return false }),
            (429, nil, { if case MemoSyncError.rateLimited = $0 { return true }; return false }),
            (503, nil, { if case MemoSyncError.serverError(let status) = $0 { return status == 503 }; return false }),
            (200, nil, { if case MemoSyncError.invalidResponse = $0 { return true }; return false }),
            (200, "999999999", { if case MemoSyncError.invalidResponse = $0 { return true }; return false }),
        ]
        for (status, offsetHeader, matches) in preservationCases {
            try seedProgress()
            let recorder = RequestRecordingTransport(
                prepareKey: descriptor.objectKey,
                headStatus: status,
                headOffsetHeader: offsetHeader
            )
            let uploader = SupabaseSyncUploader(
                session: session,
                transport: recorder,
                fileTransport: recorder,
                accessTokenProvider: { try SyncRealmTestSupport.token(realm: realm) }
            )
            do {
                _ = try await uploader.upload(operation: operation)
                XCTFail("HEAD \(status) must not silently continue")
            } catch {
                XCTAssertTrue(matches(error), "HEAD \(status) produced \(error)")
            }
            let state = try savedState()
            XCTAssertEqual(state.url?.absoluteString, savedURL, "HEAD \(status) must keep the saved URL")
            XCTAssertEqual(state.offset, 7, "HEAD \(status) must keep the saved offset")
            // prepare RPC + HEAD only: no PATCH ever reused a stale offset.
            XCTAssertEqual(recorder.calls.count, 2)
        }

        // Only a documented expired upload (404) resets the saved URL/offset;
        // the same-realm create handshake then starts fresh.
        try seedProgress()
        let expiryRecorder = RequestRecordingTransport(
            prepareKey: descriptor.objectKey,
            location: "\(realm.normalizedOrigin)/storage/v1/upload/resumable/fresh0",
            headStatus: 404
        )
        let uploader = SupabaseSyncUploader(
            session: session,
            transport: expiryRecorder,
            fileTransport: expiryRecorder,
            accessTokenProvider: { try SyncRealmTestSupport.token(realm: realm) }
        )
        do {
            _ = try await uploader.upload(operation: operation)
            XCTFail("expected the stubbed fresh upload to fail after the legal reset")
        } catch {
            // Ordinary retryable failure AFTER the documented reset.
        }
        let resetState = try savedState()
        XCTAssertEqual(resetState.url?.absoluteString, "\(realm.normalizedOrigin)/storage/v1/upload/resumable/fresh0")
        XCTAssertEqual(resetState.offset, 0)
        // One HEAD is required to discover404. That expired URL must never
        // be reused for PATCH or a second HEAD after the legal restart.
        XCTAssertEqual(expiryRecorder.calls.filter { $0.contains("pending0") }.count, 1)
        XCTAssertTrue(expiryRecorder.calls.contains { $0.hasSuffix("/storage/v1/upload/resumable") })
    }
}

/// Records every request the sync transport actually forwards; serves the
/// prepare RPC, canned HEAD responses and the resumable create handshake.
private final class RequestRecordingTransport: HTTPTransport, AttachmentFileTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private let prepareKey: String
    private let location: String?
    var headStatus: Int
    var headOffsetHeader: String?

    init(
        prepareKey: String,
        location: String? = nil,
        headStatus: Int = 200,
        headOffsetHeader: String? = nil
    ) {
        self.prepareKey = prepareKey
        self.location = location
        self.headStatus = headStatus
        self.headOffsetHeader = headOffsetHeader
    }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        lock.lock()
        recorded.append(url.absoluteString)
        let headStatus = self.headStatus
        let headOffsetHeader = self.headOffsetHeader
        lock.unlock()
        if url.absoluteString.contains("daypage_prepare_attachment_upload") {
            let body = try JSONSerialization.data(withJSONObject: [
                "reservation_id": UUID().uuidString.lowercased(),
                "object_key": prepareKey,
                "expires_at": "2026-10-16T00:00:00Z",
                "already_exists": false,
            ])
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (body, response)
        }
        if request.httpMethod == "HEAD" {
            var headers: [String: String] = [:]
            if let headOffsetHeader { headers["Upload-Offset"] = headOffsetHeader }
            let response = HTTPURLResponse(
                url: url,
                statusCode: headStatus,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            return (Data(), response)
        }
        if request.httpMethod == "POST",
           url.absoluteString.hasSuffix("/storage/v1/upload/resumable"),
           let location {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 201,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": location]
            )!
            return (Data(), response)
        }
        throw AttachmentSyncError.network
    }

    func uploadFile(for request: URLRequest, from fileURL: URL) async throws -> (Data, URLResponse) {
        lock.lock()
        recorded.append(request.url?.absoluteString ?? "")
        lock.unlock()
        throw AttachmentSyncError.network
    }

    func downloadFile(for request: URLRequest) async throws -> (URL, URLResponse) {
        lock.lock()
        recorded.append(request.url?.absoluteString ?? "")
        lock.unlock()
        throw AttachmentSyncError.network
    }
}
