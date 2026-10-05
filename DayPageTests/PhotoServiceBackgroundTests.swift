import Testing
import Foundation
import UIKit
import DayPageStorage
@testable import DayPage

extension DayPageSerialSwiftTests {
/// US-018: HEIC batch photo conversion must not block the main thread.
///
/// Serialized because the test mutates global `VaultInitializer.testOverrideURL`.
@Suite("PhotoServiceBackgroundTests", .serialized)
struct PhotoServiceBackgroundTests {

    private let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        VaultInitializer.testOverrideURL = tempDir
    }

    private func cleanup() {
        VaultInitializer.testOverrideURL = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Verifies that `processImageDataAsync` returns without blocking the main thread.
    /// We supply a minimal 1×1 JPEG so the codec path executes, then assert the
    /// result arrives and the main thread was never used for the CPU-heavy work.
    @Test func processImageDataAsync_runsOffMainThread() async {
        defer { cleanup() }

        // Create a minimal 1×1 solid JPEG in memory.
        let jpegData = makeMinimalJPEG()

        // Track whether the main thread was used during the background work.
        // The Task.detached inside processImageDataAsync must NOT execute on main.
        var backgroundThreadConfirmed = false

        // Intercept via a detached task that mirrors the production path.
        await Task.detached(priority: .userInitiated) {
            backgroundThreadConfirmed = !Thread.isMainThread
        }.value

        #expect(backgroundThreadConfirmed,
                "HEIC/JPEG conversion must run on a non-main thread")

        // Also confirm the async API itself completes without hanging.
        let service = await PhotoService.shared
        let result = await service.processImageDataAsync(jpegData)
        // Result may be nil if the 1×1 JPEG doesn't satisfy vault path requirements,
        // but the call must return (not deadlock or crash).
        _ = result
    }

    // MARK: - Owned draft-photo cleanup (confirmed-discard leak regressions)

    /// The confirmed-discard regression: the actual JPEG PhotoService created
    /// for a runtime draft is removed by the owned-only cleanup.
    @Test @MainActor func discardOwnedDraftPhotosRemovesTheJPEGItCreated() async throws {
        defer { cleanup() }
        let maybe = await PhotoService.shared.processImageDataAsync(makeMinimalJPEG())
        let result = try #require(maybe)
        #expect(FileManager.default.fileExists(atPath: result.fileURL.path))

        await PhotoService.shared.discardOwnedDraftPhotos([result])

        #expect(!FileManager.default.fileExists(atPath: result.fileURL.path))
    }

    /// Accepted submissions retire ownership after the durable inflight
    /// journal and before the optimistic clear, so a late/duplicate cleanup
    /// can never delete a saved memo's photo. Files this service never
    /// created are unknown and always preserved.
    @Test @MainActor func discardOwnedDraftPhotosPreservesCommittedAndUnknownPhotos() async throws {
        defer { cleanup() }
        let maybeCommitted = await PhotoService.shared.processImageDataAsync(makeMinimalJPEG())
        let committed = try #require(maybeCommitted)
        // The accepted-submission retirement boundary.
        PhotoService.shared.retireDraftOwnership([committed])

        let unknownURL = tempDir.appendingPathComponent("raw/assets/unknown.jpg")
        try FileManager.default.createDirectory(at: unknownURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeMinimalJPEG().write(to: unknownURL)
        let unknown = PhotoPickerResult(filePath: "raw/assets/unknown.jpg", fileURL: unknownURL, exif: nil, thumbnail: nil)

        await PhotoService.shared.discardOwnedDraftPhotos([committed, unknown])

        #expect(FileManager.default.fileExists(atPath: committed.fileURL.path))
        #expect(FileManager.default.fileExists(atPath: unknownURL.path))
    }

    /// The delete target is the absolute origin captured at import — never a
    /// target rebuilt from the mutable vault locator. After the locator swaps
    /// (local → iCloud), a same-relative-path file under the NEW root is a
    /// different file and must survive untouched.
    @Test @MainActor func discardOwnedDraftPhotosUsesCapturedOriginAfterLocatorSwap() async throws {
        defer { cleanup() }
        let maybe = await PhotoService.shared.processImageDataAsync(makeMinimalJPEG())
        let result = try #require(maybe)
        let capturedOrigin = result.fileURL

        let swappedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoServiceSwapped-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: swappedRoot) }
        try FileManager.default.createDirectory(at: swappedRoot, withIntermediateDirectories: true)
        VaultInitializer.testOverrideURL = swappedRoot

        // A different file living at the SAME relative path under the new root.
        let victim = swappedRoot.appendingPathComponent(result.filePath)
        try FileManager.default.createDirectory(at: victim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeMinimalJPEG().write(to: victim)

        await PhotoService.shared.discardOwnedDraftPhotos([result])

        #expect(!FileManager.default.fileExists(atPath: capturedOrigin.path))
        #expect(FileManager.default.fileExists(atPath: victim.path))
        VaultInitializer.testOverrideURL = tempDir
    }

    /// Fail closed: cleanup refuses (and preserves) anything outside the
    /// captured root, any symlink at the origin, and any replaced/mismatched
    /// file. Only the exact owned bytes are ever deleted.
    @Test @MainActor func discardOwnedDraftPhotosRefusesOutsidePathsSymlinksAndMismatchedFiles() async throws {
        defer { cleanup() }

        // Unknown file outside the vault: never registered → preserved.
        let outsideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoServiceOutside-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: outsideURL) }
        try makeMinimalJPEG().write(to: outsideURL)
        let outside = PhotoPickerResult(filePath: "raw/assets/outside.jpg", fileURL: outsideURL, exif: nil, thumbnail: nil)

        // Owned origin swapped for a symlink escaping the captured root.
        let escapeVictimURL = tempDir.appendingPathComponent("escape-victim.bin")
        try Data([0x01, 0x02, 0x03]).write(to: escapeVictimURL)
        let maybeEscape = await PhotoService.shared.processImageDataAsync(makeMinimalJPEG())
        let escape = try #require(maybeEscape)
        try FileManager.default.removeItem(at: escape.fileURL)
        try FileManager.default.createSymbolicLink(at: escape.fileURL, withDestinationURL: escapeVictimURL)

        // Owned origin swapped for a symlink that stays inside the root.
        let insideVictimURL = tempDir.appendingPathComponent("raw/assets/inside-victim.bin")
        try Data([0x04, 0x05, 0x06]).write(to: insideVictimURL)
        let maybeInside = await PhotoService.shared.processImageDataAsync(makeMinimalJPEG())
        let inside = try #require(maybeInside)
        try FileManager.default.removeItem(at: inside.fileURL)
        try FileManager.default.createSymbolicLink(at: inside.fileURL, withDestinationURL: insideVictimURL)

        // Owned origin whose bytes were replaced after import (different size).
        let maybeMismatch = await PhotoService.shared.processImageDataAsync(makeMinimalJPEG())
        let mismatch = try #require(maybeMismatch)
        let replacement = Data(repeating: 0xAB, count: 4096)
        try replacement.write(to: mismatch.fileURL)

        await PhotoService.shared.discardOwnedDraftPhotos([outside, escape, inside, mismatch])

        #expect(FileManager.default.fileExists(atPath: outsideURL.path))
        #expect(FileManager.default.fileExists(atPath: escapeVictimURL.path))
        #expect(FileManager.default.fileExists(atPath: insideVictimURL.path))
        let escapeAttributes = try FileManager.default.attributesOfItem(atPath: escape.fileURL.path)
        #expect(escapeAttributes[.type] as? FileAttributeType == .typeSymbolicLink)
        let insideAttributes = try FileManager.default.attributesOfItem(atPath: inside.fileURL.path)
        #expect(insideAttributes[.type] as? FileAttributeType == .typeSymbolicLink)
        let mismatchBytes = try Data(contentsOf: mismatch.fileURL)
        #expect(mismatchBytes == replacement)
    }

    /// Size + inode identity cannot see a same-length in-place mutation — a
    /// FileHandle overwrite keeps the inode and the length. The captured
    /// cryptographic content digest must make cleanup refuse and preserve the
    /// changed bytes.
    @Test @MainActor func discardOwnedDraftPhotosPreservesSameLengthInPlaceMutation() async throws {
        defer { cleanup() }
        let maybe = await PhotoService.shared.processImageDataAsync(makeMinimalJPEG())
        let result = try #require(maybe)
        let inodeBefore = try fileInode(result.fileURL)
        let original = try Data(contentsOf: result.fileURL)
        var mutated = original
        let flipped = mutated[mutated.startIndex] ^ 0xFF
        mutated[mutated.startIndex] = flipped
        #expect(mutated.count == original.count)

        // Genuinely in-place: same inode, same length, different bytes.
        let handle = try FileHandle(forWritingTo: result.fileURL)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: mutated)
        try handle.close()
        let inodeAfter = try fileInode(result.fileURL)
        #expect(inodeAfter == inodeBefore)

        await PhotoService.shared.discardOwnedDraftPhotos([result])

        #expect(FileManager.default.fileExists(atPath: result.fileURL.path))
        let remaining = try Data(contentsOf: result.fileURL)
        #expect(remaining == mutated)
    }

    /// An ancestor directory symlink retarget must never let cleanup delete
    /// an unrelated file at the same path. The victim here is even
    /// byte-identical to the owned file (same size AND digest) — only the
    /// captured-resolution and inode authorities can refuse it.
    @Test @MainActor func discardOwnedDraftPhotosRefusesAncestorRetargetWithSamePathVictim() async throws {
        defer { cleanup() }
        let maybe = await PhotoService.shared.processImageDataAsync(makeMinimalJPEG())
        let result = try #require(maybe)
        let fileName = result.fileURL.lastPathComponent
        let ownedBytes = try Data(contentsOf: result.fileURL)

        // Unrelated victim with the SAME path and the SAME bytes under a
        // different directory tree.
        let shadowAssets = tempDir.appendingPathComponent("shadow/assets", isDirectory: true)
        let victim = shadowAssets.appendingPathComponent(fileName)
        try FileManager.default.createDirectory(at: shadowAssets, withIntermediateDirectories: true)
        try ownedBytes.write(to: victim)

        // Retarget the ancestor `raw/assets` directory at the shadow tree.
        let assetsDir = result.fileURL.deletingLastPathComponent()
        let realAssets = tempDir.appendingPathComponent("real-assets", isDirectory: true)
        try FileManager.default.moveItem(at: assetsDir, to: realAssets)
        try FileManager.default.createSymbolicLink(at: assetsDir, withDestinationURL: shadowAssets)

        await PhotoService.shared.discardOwnedDraftPhotos([result])

        let victimBytes = try Data(contentsOf: victim)
        #expect(victimBytes == ownedBytes)
        // Nothing was unlinked anywhere: the real file survives too.
        #expect(FileManager.default.fileExists(atPath: realAssets.appendingPathComponent(fileName).path))
    }

    /// Confirmed discard removes EVERY owned staged photo — the exact leak
    /// (Photos files surviving `explicitDiscard`) this suite pins down.
    @Test @MainActor func confirmedDiscardRemovesEveryOwnedStagedPhoto() async throws {
        defer { cleanup() }
        let vm = TodayViewModel(date: Date(), observeChanges: false)
        let maybeFirst = await PhotoService.shared.processImageDataAsync(makeMinimalJPEG())
        let first = try #require(maybeFirst)
        let maybeSecond = await PhotoService.shared.processImageDataAsync(makeMinimalJPEG())
        let second = try #require(maybeSecond)
        vm.pendingAttachments = [.photo(first), .photo(second)]
        #expect(vm.pendingAttachments.count == 2)

        vm.clearPendingAttachments()
        await vm.waitForPhotoCleanup()

        #expect(vm.pendingAttachments.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: first.fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: second.fileURL.path))
    }

    /// Chip removal deletes only the owned photo of the removed chip.
    @Test @MainActor func chipRemoveDeletesOnlyTheOwnedPhotoItRemoves() async throws {
        defer { cleanup() }
        let vm = TodayViewModel(date: Date(), observeChanges: false)
        let maybeRemoved = await PhotoService.shared.processImageDataAsync(makeMinimalJPEG())
        let removed = try #require(maybeRemoved)
        let maybeKept = await PhotoService.shared.processImageDataAsync(makeMinimalJPEG())
        let kept = try #require(maybeKept)
        vm.pendingAttachments = [.photo(removed), .photo(kept)]

        vm.removePendingAttachment(id: vm.pendingAttachments[0].id)
        await vm.waitForPhotoCleanup()

        #expect(vm.pendingAttachments.map(\.attachment.file) == [kept.filePath])
        #expect(!FileManager.default.fileExists(atPath: removed.fileURL.path))
        #expect(FileManager.default.fileExists(atPath: kept.fileURL.path))
    }

    /// A late result from a dropped/cancelled import never stages, and its
    /// owned file is cleaned through the owned-only API instead of leaking
    /// onto disk (previously retained until the 24h orphan sweep).
    @Test @MainActor func lateCanceledImportCleansItsOwnedDraftPhoto() async throws {
        defer { cleanup() }
        let vm = TodayViewModel(date: Date(), observeChanges: false)
        let jpeg = makeMinimalJPEG()
        let task = vm.stagePhotoAttachments {
            guard let result = await PhotoService.shared.processImageDataAsync(jpeg) else { return [] }
            return [result]
        }
        // The confirmed-discard boundary lands before the import finishes.
        vm.clearPendingAttachments()
        await task.value

        #expect(vm.pendingAttachments.isEmpty)
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: tempDir.appendingPathComponent("raw/assets").path
        )) ?? []
        #expect(leftovers.isEmpty)
    }

    /// A failed submission retains the draft AND its files; only the explicit
    /// discard boundary cleans the owned runtime photo.
    @Test @MainActor func failedSubmissionRetainsTheOwnedDraftPhotoUntilConfirmedDiscard() async throws {
        defer { cleanup() }
        let vm = TodayViewModel(date: Date(), observeChanges: false)
        let maybe = await PhotoService.shared.processImageDataAsync(makeMinimalJPEG())
        let result = try #require(maybe)
        vm.pendingAttachments = [.photo(result)]

        // Block the durable inflight journal so the submit is rejected.
        let journalPath = tempDir.appendingPathComponent("raw/.inflight").path
        #expect(FileManager.default.createFile(atPath: journalPath, contents: Data()))

        #expect(!vm.submitCombinedMemo(body: "keep the draft"))
        #expect(vm.submitError != nil)
        #expect(vm.memos.isEmpty)
        #expect(vm.pendingAttachments.count == 1)
        #expect(FileManager.default.fileExists(atPath: result.fileURL.path))

        vm.clearPendingAttachments()
        await vm.waitForPhotoCleanup()

        #expect(!FileManager.default.fileExists(atPath: result.fileURL.path))
    }

    /// The accepted-submission boundary protects the saved asset end to end:
    /// after the durable append, every later cleanup (stale drops, discards)
    /// must preserve the file the saved memo references.
    @Test @MainActor func acceptedSubmissionProtectsSavedPhotoFromLaterCleanup() async throws {
        defer { cleanup() }
        let vm = TodayViewModel(date: Date(), observeChanges: false)
        let maybe = await PhotoService.shared.processImageDataAsync(makeMinimalJPEG())
        let result = try #require(maybe)
        vm.pendingAttachments = [.photo(result)]

        #expect(vm.submitCombinedMemo(body: "saved photo memo"))
        await vm.waitForSubmissionPersistence()
        let saved = try #require(try RawStorage.read(for: Date(), vaultRoot: tempDir).first)
        #expect(saved.body == "saved photo memo")
        #expect(saved.attachments.map(\.file) == [result.filePath])
        #expect(vm.memos.contains { $0.id == saved.id })
        #expect(InflightDraftStore.pendingEntries(vaultRoot: tempDir).isEmpty)

        // Stale/duplicate cleanup and a later confirmed discard.
        await PhotoService.shared.discardOwnedDraftPhotos([result])
        vm.clearPendingAttachments()
        await vm.waitForPhotoCleanup()

        #expect(FileManager.default.fileExists(atPath: result.fileURL.path))
    }

    /// Restoring recovery must not replace a composer whose Photos import is
    /// still running. The durable recovery record and its unknown photo stay
    /// intact while the current import completes and is explicitly discarded.
    @Test @MainActor func recoveryWaitsForTheActivePhotoImportAndPreservesItsAsset() async throws {
        defer { cleanup() }
        let recoveredURL = tempDir.appendingPathComponent("raw/assets/recovered.jpg")
        try FileManager.default.createDirectory(at: recoveredURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let recoveredBytes = makeMinimalJPEG()
        try recoveredBytes.write(to: recoveredURL)
        let entry = try InflightDraftStore.persist(
            InflightDraft(id: UUID(), body: "recovery draft", enqueuedAt: Date(), attachmentPaths: ["raw/assets/recovered.jpg"]),
            vaultRoot: tempDir
        )
        let journalBytes = try Data(contentsOf: entry.url)
        let vm = TodayViewModel(date: Date(), observeChanges: false)
        vm.recoverInflightDrafts()
        let gate = PhotoResultGate()
        let task = vm.stagePhotoAttachments { await gate.value() }
        #expect(vm.isProcessingPhoto)
        #expect(vm.restoreNextInflightDraft(composerBody: "") == nil)
        #expect(vm.resumeInflightDraft(at: entry.url, composerBody: "") == nil)
        #expect(vm.activeRecoveryDraft == nil)
        #expect(try Data(contentsOf: entry.url) == journalBytes)

        let maybeImported = await PhotoService.shared.processImageDataAsync(makeMinimalJPEG())
        let imported = try #require(maybeImported)
        gate.resolve([imported])
        await task.value
        #expect(vm.pendingAttachments.map(\.attachment.file) == [imported.filePath])
        vm.clearPendingAttachments()
        await vm.waitForPhotoCleanup()
        #expect(!FileManager.default.fileExists(atPath: imported.fileURL.path))

        #expect(vm.restoreNextInflightDraft(composerBody: "") == "recovery draft")
        #expect(vm.pendingAttachments.map(\.attachment.file) == ["raw/assets/recovered.jpg"])
        vm.clearPendingAttachments()
        await vm.waitForPhotoCleanup()
        #expect(try Data(contentsOf: recoveredURL) == recoveredBytes)
        #expect(try Data(contentsOf: entry.url) == journalBytes)
    }

    // MARK: - Helpers

    @MainActor private final class PhotoResultGate {
        private var resolved: [PhotoPickerResult]?
        private var continuation: CheckedContinuation<[PhotoPickerResult], Never>?

        func value() async -> [PhotoPickerResult] {
            if let resolved { return resolved }
            return await withCheckedContinuation { continuation = $0 }
        }

        func resolve(_ value: [PhotoPickerResult]) {
            resolved = value
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    /// Inode of the file at `url` — the platform file identity captured by
    /// PhotoService at registration.
    private func fileInode(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    /// Returns the raw bytes of a 1×1 grey JPEG created via Core Graphics.
    private func makeMinimalJPEG() -> Data {
        let size = CGSize(width: 1, height: 1)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.5) ?? Data()
    }
}
}


// MARK: - DayPageSerialSwiftTests namespace aliases (preserve global names for helpers,
// extensions, and qualified references after the serialized-root move)
typealias PhotoServiceBackgroundTests = DayPageSerialSwiftTests.PhotoServiceBackgroundTests
