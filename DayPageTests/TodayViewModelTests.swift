import Testing
import Foundation
import UIKit
import DayPageModels
import DayPageStorage
import DayPageServices
@testable import DayPage

extension DayPageSerialSwiftTests {
/// US-020: Unit tests for TodayViewModel core paths: addMemo, deleteMemo, toggleFavorite (pin/unpin).
///
/// TodayViewModel reads/writes via RawStorage which uses VaultInitializer.testOverrideURL.
/// Tests run synchronously by directly mutating `memos` and calling the view model methods,
/// bypassing the async submission path that requires live services (Location, Weather).
///
/// Serialized + @MainActor because TodayViewModel is @MainActor-isolated and tests
/// share the global `VaultInitializer.testOverrideURL`.
@MainActor
@Suite("TodayViewModelTests", .serialized)
struct TodayViewModelTests {

    private let tempDir: URL
    private let vm: TodayViewModel

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TodayVMTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        VaultInitializer.testOverrideURL = tempDir
        vm = TodayViewModel(date: Date(), observeChanges: false)
    }

    private func cleanup() {
        VaultInitializer.testOverrideURL = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - addMemo (via RawStorage.append + in-memory insert)

    @Test func addMemo_insertsIntoMemosArray() throws {
        defer { cleanup() }
        let memo = makeMemo(body: "test memo body")
        try RawStorage.append(memo)
        // Simulate the in-memory update that submitCombinedMemo performs
        vm.memos.insert(memo, at: 0)

        #expect(vm.memos.count == 1)
        #expect(vm.memos.first?.id == memo.id)
        #expect(vm.memos.first?.body == "test memo body")
    }

    @Test func addMemo_multipleMemosOrderedNewestFirst() throws {
        defer { cleanup() }
        let older = makeMemo(body: "older", created: Date(timeIntervalSinceNow: -120))
        let newer = makeMemo(body: "newer", created: Date(timeIntervalSinceNow: -60))
        try RawStorage.append(older)
        try RawStorage.append(newer)

        // Simulate load sort (newest first)
        vm.memos = [newer, older]

        #expect(vm.memos.first?.body == "newer")
        #expect(vm.memos.last?.body == "older")
    }

    // MARK: - deleteMemo

    @Test func deleteMemo_removesMemoFromMemosArray() async throws {
        defer { cleanup() }
        let m1 = makeMemo(body: "keep me")
        let m2 = makeMemo(body: "delete me")
        try RawStorage.append(m1)
        try RawStorage.append(m2)
        vm.memos = [m1, m2]

        vm.deleteMemo(m2)

        #expect(vm.memos.count == 1)
        #expect(vm.memos.first?.id == m1.id)
        await vm.waitForMemoPersistence()
        #expect(try RawStorage.read(for: m1.created, vaultRoot: tempDir).map(\.id) == [m1.id])
    }

    @Test func deleteMemo_setsLastDeletedMemo() async throws {
        defer { cleanup() }
        let memo = makeMemo(body: "will be deleted")
        try RawStorage.append(memo)
        vm.memos = [memo]

        vm.deleteMemo(memo)

        #expect(vm.lastDeletedMemo?.id == memo.id)
        await vm.waitForMemoPersistence()
    }

    @Test func undoDelete_restoresMemo() async throws {
        defer { cleanup() }
        let memo = makeMemo(body: "restore me")
        try RawStorage.append(memo)
        vm.memos = [memo]

        vm.deleteMemo(memo)
        #expect(vm.memos.count == 0)

        vm.undoDelete()
        #expect(vm.memos.count == 1)
        #expect(vm.memos.first?.id == memo.id)
        #expect(vm.lastDeletedMemo == nil)
        await vm.waitForMemoPersistence()
        #expect(try RawStorage.read(for: memo.created, vaultRoot: tempDir).map(\.id) == [memo.id])
    }

    // MARK: - toggleFavorite (pin / unpin)

    @Test func pinMemo_setsPinnedAtAndMovesToTop() async throws {
        defer { cleanup() }
        let m1 = makeMemo(body: "first", created: Date(timeIntervalSinceNow: -60))
        let m2 = makeMemo(body: "second", created: Date())
        try RawStorage.append(m1)
        try RawStorage.append(m2)
        vm.memos = [m2, m1] // newest first

        vm.pinMemo(m1)

        #expect(vm.memos.first?.pinnedAt != nil, "Pinned memo must have pinnedAt set")
        #expect(vm.memos.first?.id == m1.id, "Pinned memo must move to top")
        await vm.waitForMemoPersistence()
    }

    @Test func unpinMemo_clearsPinnedAtAndResortsByCreated() async throws {
        defer { cleanup() }
        var pinned = makeMemo(body: "pinned", created: Date(timeIntervalSinceNow: -60))
        pinned.pinnedAt = Date()
        let normal = makeMemo(body: "normal", created: Date())
        try RawStorage.append(pinned)
        try RawStorage.append(normal)
        vm.memos = [pinned, normal]

        vm.unpinMemo(pinned)

        #expect(vm.memos.first(where: { $0.id == pinned.id })?.pinnedAt == nil,
                "Unpinned memo must have nil pinnedAt")
        // After unpin, normal (newer) should be first
        #expect(vm.memos.first?.id == normal.id)
        await vm.waitForMemoPersistence()
    }

    @Test func pinMemo_onlyOneMemoInList() async throws {
        defer { cleanup() }
        let memo = makeMemo(body: "solo")
        try RawStorage.append(memo)
        vm.memos = [memo]

        vm.pinMemo(memo)

        #expect(vm.memos.count == 1)
        #expect(vm.memos.first?.pinnedAt != nil)
        await vm.waitForMemoPersistence()
    }

    // MARK: - submitCombinedMemo (optimistic commit + durable persist)

    /// 落盘先于加载：the memo must appear in `memos` on the SAME synchronous turn
    /// the user taps send — no awaiting location/weather first — and must still
    /// land on disk afterward via the background durable-write task.
    @Test func submitCombinedMemo_insertsOptimisticallyThenPersists() async throws {
        defer { cleanup() }
        #expect(vm.memos.isEmpty)

        vm.submitCombinedMemo(body: "optimistic hello")

        // Optimistic insert + composer reset happen synchronously — the user
        // perceives the memo immediately, before any GPS/weather await.
        #expect(vm.memos.count == 1)
        #expect(vm.memos.first?.body == "optimistic hello")
        #expect(vm.isSubmitting == false)
        #expect(vm.pendingAttachments.isEmpty)

        // The durable append runs off-main; await its explicit completion so
        // the next test cannot switch the global isolated-vault override while
        // this task is still writing.
        await vm.waitForSubmissionPersistence()
        let persisted = (try? RawStorage.read(for: Date(), vaultRoot: tempDir)) ?? []
        #expect(persisted.contains { $0.body == "optimistic hello" })
    }

    /// An empty submit with no attachments is a no-op — no ghost card, no write.
    @Test func submitCombinedMemo_emptyBodyNoAttachments_isNoOp() {
        defer { cleanup() }
        vm.submitCombinedMemo(body: "   \n  ")
        #expect(vm.memos.isEmpty)
        #expect(vm.isSubmitting == false)
    }

    @Test func undoLastSubmission_removesMemoAndRestoresDraftPayload() async throws {
        defer { cleanup() }

        vm.submitCombinedMemo(body: "bring this back")
        #expect(vm.memos.count == 1)

        let restoredBody = vm.undoLastSubmission()
        #expect(restoredBody == "bring this back")
        #expect(vm.memos.isEmpty, "Undo must remove the optimistic card, not merely copy its text")

        // The undo is ordered after the in-flight append, then removes the
        // exact memo id atomically. Await that storage pipeline before reading.
        await vm.waitForSubmissionUndo()
        let persisted = (try? RawStorage.read(for: Date(), vaultRoot: tempDir)) ?? []

        #expect(persisted.isEmpty, "Undo send must remove the committed memo from disk")
    }

    // MARK: - signalCount

    @Test func pinFromStaleListPreservesBackgroundMemoAndItsOutbox() async throws {
        defer { cleanup() }
        let original = makeMemo(body: "original")
        try RawStorage.append(original)
        vm.memos = [original]
        let background = makeMemo(body: "background")
        try RawStorage.append(background)
        vm.pinMemo(original)
        await vm.waitForMemoPersistence()
        let actual = try RawStorage.read(for: original.created, vaultRoot: tempDir)
        #expect(actual.count == 2)
        #expect(actual.first { $0.id == original.id }?.pinnedAt != nil)
        #expect(actual.contains { $0.id == background.id })
        #expect(try SyncOutboxStore.pendingOperation(for: background.id)?.kind != .delete)
    }

    @Test func immediateSubmitEditPinUnpinDeleteUndoIsOrdered() async throws {
        defer { cleanup() }
        vm.submitCombinedMemo(body: "initial")
        let memo = try #require(vm.memos.first)
        vm.update(memo: memo, body: "edited")
        vm.pinMemo(memo)
        vm.unpinMemo(memo)
        let edited = try #require(vm.memos.first)
        vm.deleteMemo(edited)
        vm.undoDelete()
        await vm.waitForMemoPersistence()
        await vm.waitForSubmissionPersistence()
        let actual = try RawStorage.read(for: memo.created, vaultRoot: tempDir)
        #expect(actual.count == 1)
        #expect(actual.first?.body == "edited")
        #expect(actual.first?.pinnedAt == nil)
        #expect(vm.submitError == nil)
    }

    @Test func rapidSubmissionsAndMutationKeepEveryRecord() async throws {
        defer { cleanup() }
        vm.submitCombinedMemo(body: "first")
        let first = try #require(vm.memos.first)
        vm.submitCombinedMemo(body: "second")
        vm.pinMemo(first)
        vm.submitCombinedMemo(body: "third")
        await vm.waitForMemoPersistence()
        await vm.waitForSubmissionPersistence()
        let actual = try RawStorage.read(for: first.created, vaultRoot: tempDir)
        #expect(Set(actual.map(\.body)) == ["first", "second", "third"])
        #expect(actual.first { $0.id == first.id }?.pinnedAt != nil)
    }

    @Test func queuedMutationRetainsVaultEvenIfLocatorChanges() async throws {
        defer { cleanup() }
        let memo = makeMemo(body: "captured root")
        try RawStorage.append(memo, vaultRoot: tempDir)
        vm.memos = [memo]
        vm.pinMemo(memo)
        let other = tempDir.appendingPathComponent("other-vault")
        VaultInitializer.testOverrideURL = other
        await vm.waitForMemoPersistence()
        #expect(try RawStorage.read(for: memo.created, vaultRoot: tempDir).first?.pinnedAt != nil)
        #expect(!FileManager.default.fileExists(atPath: RawStorage.fileURL(for: memo.created, vaultRoot: other).path))
    }

    @Test func completedTranscriptPreservesLatestBodyOtherAttachmentsAndBackgroundMemo() async throws {
        defer { cleanup() }
        var stale = makeMemo(body: "old body")
        stale.attachments = [.init(file: "raw/assets/voice.m4a", kind: "audio", duration: 2, transcriptionStatus: .failed)]
        try RawStorage.append(stale)
        vm.memos = [stale]
        try RawStorage.mutate(for: stale.created, vaultRoot: tempDir) { current in
            var updated = current
            updated[0].body = "concurrent body"
            updated[0].attachments[0].duration = 4
            updated[0].attachments.append(.init(file: "raw/assets/new.pdf", kind: "file"))
            return updated
        }
        let sibling = makeMemo(body: "concurrent append")
        try RawStorage.append(sibling)
        vm.updateTranscript("new transcript", memo: stale, attachmentFile: stale.attachments[0].file, vaultRoot: tempDir)
        await vm.waitForMemoPersistence()
        let actual = try RawStorage.read(for: stale.created, vaultRoot: tempDir)
        let updated = try #require(actual.first { $0.id == stale.id })
        #expect(actual.count == 2)
        #expect(updated.body == "concurrent body")
        #expect(updated.attachments.count == 2)
        #expect(updated.attachments[0].duration == 4)
        #expect(updated.attachments[0].transcript == "new transcript")
        #expect(updated.attachments[0].transcriptionStatus == .done)
    }

    @Test func failedOldMutationDoesNotRestoreStaleSnapshotOverNewSubmit() async throws {
        defer { cleanup() }
        // A deleted-elsewhere memo exists only in the stale UI snapshot.
        let missing = makeMemo(body: "deleted elsewhere")
        vm.memos = [missing]
        vm.pinMemo(missing)
        vm.submitCombinedMemo(body: "must survive failed pin")
        await vm.waitForMemoPersistence()
        await vm.waitForSubmissionPersistence()
        let actual = try RawStorage.read(for: missing.created, vaultRoot: tempDir)
        #expect(actual.map(\.body) == ["must survive failed pin"])
        #expect(vm.memos.contains { $0.body == "must survive failed pin" })
        #expect(!vm.memos.contains { $0.id == missing.id })
        #expect(vm.submitError != nil)
    }

    @Test func deleteUndoRestoresLatestPersistedRecordInsteadOfStaleCard() async throws {
        defer { cleanup() }
        let stale = makeMemo(body: "old card")
        try RawStorage.append(stale)
        vm.memos = [stale]
        try RawStorage.mutate(for: stale.created, vaultRoot: tempDir) { current in
            var updated = current
            updated[0].body = "new background edit"
            updated[0].attachments = [.init(file: "raw/assets/background.pdf", kind: "file")]
            return updated
        }
        vm.deleteMemo(stale)
        vm.undoDelete()
        await vm.waitForMemoPersistence()
        let restored = try #require(try RawStorage.read(for: stale.created, vaultRoot: tempDir).first)
        #expect(restored.body == "new background edit")
        #expect(restored.attachments.count == 1)
    }

    @Test func successfulNoOpMutationCompletesInterruptedLoad() async throws {
        defer { cleanup() }
        let missing = makeMemo(body: "already removed")
        vm.load()
        vm.updateTranscript("late transcript", memo: missing, attachmentFile: "raw/assets/removed.m4a", vaultRoot: tempDir)
        await vm.waitForMemoPersistence()
        #expect(vm.loadState == .ready)
        #expect(vm.memos.isEmpty)
    }

    @Test func deleteUndoAfterVaultSwitchDoesNotInsertOldVaultCardInCurrentList() async throws {
        defer { cleanup() }
        let memo = makeMemo(body: "old vault")
        try RawStorage.append(memo, vaultRoot: tempDir)
        vm.memos = [memo]
        vm.deleteMemo(memo)
        let other = tempDir.appendingPathComponent("new-vault")
        VaultInitializer.testOverrideURL = other
        vm.memos = []
        vm.undoDelete()
        #expect(vm.memos.isEmpty)
        await vm.waitForMemoPersistence()
        #expect(try RawStorage.read(for: memo.created, vaultRoot: tempDir).map(\.id) == [memo.id])
        #expect(vm.memos.isEmpty)
    }

    @Test func unpinKeepsRemainingPinnedMemoAheadOfNewerUnpinnedMemo() async throws {
        defer { cleanup() }
        var pinned = makeMemo(body: "still pinned", created: Date(timeIntervalSinceNow: -600))
        pinned.pinnedAt = Date(timeIntervalSinceNow: -30)
        var unpin = makeMemo(body: "unpin newest")
        unpin.pinnedAt = Date()
        try RawStorage.append(pinned)
        try RawStorage.append(unpin)
        vm.memos = [unpin, pinned]
        vm.unpinMemo(unpin)
        #expect(vm.memos.first?.id == pinned.id)
        await vm.waitForMemoPersistence()
    }

    @Test func signalCount_matchesMemoCount() {
        defer { cleanup() }
        vm.memos = [makeMemo(body: "a"), makeMemo(body: "b"), makeMemo(body: "c")]
        #expect(vm.signalCount == 3)
    }

    @Test func photoImportsBlockPartialSubmissionUntilEveryResultArrives() async throws {
        defer { cleanup() }
        let first = PhotoResultGate()
        let second = PhotoResultGate()
        let firstTask = vm.stagePhotoAttachments { await first.value() }
        let secondTask = vm.stagePhotoAttachments { await second.value() }
        #expect(vm.isProcessingPhoto)
        #expect(!vm.submitCombinedMemo(body: "Keep both photos"))
        second.resolve([try photoResult("second.jpg")])
        await secondTask.value
        #expect(vm.pendingAttachments.count == 1)
        #expect(vm.isProcessingPhoto)
        #expect(!vm.submitCombinedMemo(body: "Keep both photos"))
        #expect(vm.memos.isEmpty)
        first.resolve([try photoResult("first.jpg")])
        await firstTask.value
        #expect(!vm.isProcessingPhoto)
        #expect(vm.submitCombinedMemo(body: "Keep both photos"))
        await vm.waitForSubmissionPersistence()
        let saved = try #require(try RawStorage.read(for: Date(), vaultRoot: tempDir).first)
        #expect(saved.body == "Keep both photos")
        #expect(Set(saved.attachments.map(\.file)) == ["raw/assets/first.jpg", "raw/assets/second.jpg"])
    }

    @Test func discardedPhotoCannotEnterANewDraftOrClearItsLoadingState() async throws {
        defer { cleanup() }
        let old = PhotoResultGate()
        let oldTask = vm.stagePhotoAttachments(autoSubmit: true) { await old.value() }
        vm.clearPendingAttachments()
        let current = PhotoResultGate()
        let currentTask = vm.stagePhotoAttachments { await current.value() }
        old.resolve([try photoResult("discarded.jpg")])
        await oldTask.value
        #expect(vm.isProcessingPhoto)
        #expect(vm.pendingAttachments.isEmpty)
        #expect(vm.memos.isEmpty)
        #expect(vm.submitError == nil)
        current.resolve([try photoResult("current.jpg")])
        await currentTask.value
        #expect(!vm.isProcessingPhoto)
        #expect(vm.pendingAttachments.map(\.attachment.file) == ["raw/assets/current.jpg"])
    }

    @Test func failedPhotoImportRetiresLoadingAndCanBeRetried() async throws {
        defer { cleanup() }
        let failed = vm.stagePhotoAttachments { [] }
        await failed.value
        #expect(!vm.isProcessingPhoto)
        #expect(vm.submitError != nil)
        let result = try photoResult("retry.jpg")
        let retry = vm.stagePhotoAttachments { [result] }
        await retry.value
        #expect(!vm.isProcessingPhoto)
        #expect(vm.submitError == nil)
        #expect(vm.pendingAttachments.count == 1)
    }

    @Test func automaticPhotoSubmitRetiresItsOwnImportBeforeSaving() async throws {
        defer { cleanup() }
        let result = try photoResult("camera.jpg")
        let task = vm.stagePhotoAttachments(autoSubmit: true) { [result] }
        await task.value
        #expect(!vm.isProcessingPhoto)
        #expect(vm.memos.count == 1)
        await vm.waitForSubmissionPersistence()
        let saved = try #require(try RawStorage.read(for: Date(), vaultRoot: tempDir).first)
        #expect(saved.attachments.map(\.file) == ["raw/assets/camera.jpg"])
    }

    @Test(arguments: [true, false])
    func automaticPhotoSubmitDoesNotCommitAnotherImportPartially(cameraFinishesFirst: Bool) async throws {
        defer { cleanup() }
        let camera = PhotoResultGate()
        let picker = PhotoResultGate()
        let cameraTask = vm.stagePhotoAttachments(autoSubmit: true) { await camera.value() }
        let pickerTask = vm.stagePhotoAttachments { await picker.value() }
        if cameraFinishesFirst {
            camera.resolve([try photoResult("camera-pending.jpg")])
            await cameraTask.value
            #expect(vm.memos.isEmpty)
            #expect(vm.isProcessingPhoto)
            picker.resolve([try photoResult("picked.jpg")])
            await pickerTask.value
        } else {
            picker.resolve([try photoResult("picked.jpg")])
            await pickerTask.value
            #expect(vm.memos.isEmpty)
            #expect(vm.isProcessingPhoto)
            camera.resolve([try photoResult("camera-pending.jpg")])
            await cameraTask.value
        }
        await vm.waitForSubmissionPersistence()
        #expect(!vm.isProcessingPhoto)
        #expect(vm.memos.isEmpty)
        #expect(vm.pendingAttachments.count == 2)
    }

    @Test func automaticPhotoSubmitLeavesExistingAttachmentsForConfirmation() async throws {
        defer { cleanup() }
        vm.pendingAttachments = [.photo(try photoResult("existing-draft.jpg"))]
        let camera = try photoResult("camera-with-draft.jpg")
        let task = vm.stagePhotoAttachments(autoSubmit: true) { [camera] }
        await task.value
        await vm.waitForSubmissionPersistence()
        #expect(vm.memos.isEmpty)
        #expect(vm.pendingAttachments.count == 2)
    }

    // MARK: - Composer generation (late press-to-talk voice results)

    @Test func lateVoiceResultsAfterConfirmedDiscardCannotWriteANewDraft() throws {
        defer { cleanup() }
        let token = vm.composerToken(for: .writeSheet)
        // TodayView.onDiscard's exact VM sequence — the draft is destroyed.
        vm.discardActiveInflightDraft()
        vm.clearPendingAttachments()
        // The ASR/save results return only after the discard: the transcript
        // must not write the fresh composer and the send must not stage in it.
        #expect(vm.draftByAppendingTranscript("late transcript", to: "", token: token) == nil)
        let dropped = try voiceResult("discarded-late.m4a")
        #expect(!vm.stageVoiceResult(dropped, token: token))
        #expect(vm.pendingAttachments.isEmpty)
        #expect(vm.memos.isEmpty)
        // A rejected result is dropped untouched — the saved audio stays on
        // disk and the shared VoiceService is neither reset nor cancelled.
        #expect(FileManager.default.fileExists(atPath: dropped.fileURL.path))
    }

    @Test func lateVoiceResultsAfterSuccessSubmitCannotPolluteTheNextDraft() async throws {
        defer { cleanup() }
        let token = vm.composerToken(for: .dock)
        #expect(vm.submitCombinedMemo(body: "sent from the dock"))
        // The successful submit cleared the composer: results belonging to
        // the submitted draft must not write or stage into the next one.
        #expect(vm.draftByAppendingTranscript("late transcript", to: "", token: token) == nil)
        let dropped = try voiceResult("after-submit.m4a")
        #expect(!vm.stageVoiceResult(dropped, token: token))
        #expect(vm.pendingAttachments.isEmpty)
        await vm.waitForSubmissionPersistence()
        #expect(vm.memos.count == 1)
        #expect(vm.memos.first?.body == "sent from the dock")
    }

    @Test func currentVoiceResultsStillLandInTheLiveDraft() throws {
        defer { cleanup() }
        let dock = vm.composerToken(for: .dock)
        let sheet = vm.composerToken(for: .writeSheet)
        // Typing never rotates the generation: current results from either
        // surface complete into the same live draft (empty and append forms).
        #expect(vm.draftByAppendingTranscript("voice words", to: "", token: dock) == "voice words")
        #expect(vm.draftByAppendingTranscript("voice words", to: "typed ", token: sheet) == "typed voice words")
        let staged = try voiceResult("live.m4a")
        #expect(vm.stageVoiceResult(staged, token: dock))
        #expect(vm.pendingAttachments.map(\.attachment.file) == ["raw/assets/live.m4a"])
        #expect(vm.memos.isEmpty)
    }

    @Test func failedSubmitKeepsTheComposerGenerationForInFlightVoiceResults() throws {
        defer { cleanup() }
        let token = vm.composerToken(for: .writeSheet)
        // A staged asset from outside the active vault fails the submit with
        // the whole draft preserved (vault-changed guard).
        vm.pendingAttachments = [.photo(PhotoPickerResult(
            filePath: "raw/assets/foreign.jpg",
            fileURL: URL(fileURLWithPath: "/outside-the-vault/foreign.jpg"),
            exif: nil,
            thumbnail: nil
        ))]
        #expect(!vm.submitCombinedMemo(body: "keep editing"))
        #expect(vm.memos.isEmpty)
        // A failed submit is not a draft boundary: the in-flight results still
        // belong to this composer and may complete into it.
        #expect(vm.draftByAppendingTranscript("still welcome", to: "keep editing ", token: token) == "keep editing still welcome")
        let late = try voiceResult("after-failed-submit.m4a")
        #expect(vm.stageVoiceResult(late, token: token))
        #expect(vm.pendingAttachments.count == 2)
    }

    @Test func softKeepAndOrdinaryEditsPreserveTheComposerGeneration() throws {
        defer { cleanup() }
        let dock = vm.composerToken(for: .dock)
        let sheet = vm.composerToken(for: .writeSheet)
        // Soft close / swipe dismissal / Keep editing never touch the VM's
        // draft lifecycle; neither do ordinary composer edits (staging,
        // removing, location).
        vm.pendingAttachments = [.photo(try photoResult("kept.jpg"))]
        vm.removePendingAttachment(id: vm.pendingAttachments[0].id)
        vm.setPendingLocation(Memo.Location(name: "here", lat: 1, lng: 2))
        vm.clearPendingLocation()
        // The original draft's own late results stay legitimate.
        #expect(vm.draftByAppendingTranscript("after soft close", to: "kept typing ", token: sheet) == "kept typing after soft close")
        let staged = try voiceResult("kept.m4a")
        #expect(vm.stageVoiceResult(staged, token: dock))
        #expect(vm.pendingAttachments.map(\.attachment.file) == ["raw/assets/kept.m4a"])
        #expect(vm.memos.isEmpty)
    }

    @Test func restoringAnotherDraftRetiresThePreviousGeneration() throws {
        defer { cleanup() }
        let token = vm.composerToken(for: .dock)
        _ = try InflightDraftStore.persist(
            InflightDraft(id: UUID(), body: "restored draft", enqueuedAt: Date(), attachmentPaths: []),
            vaultRoot: tempDir
        )
        vm.recoverInflightDrafts()
        #expect(vm.restoreNextInflightDraft(composerBody: "") == "restored draft")
        // Restoring another draft replaces the composer content: results
        // captured for the replaced draft must not land in the restored one.
        #expect(vm.draftByAppendingTranscript("late transcript", to: "restored draft ", token: token) == nil)
        let dropped = try voiceResult("after-restore.m4a")
        #expect(!vm.stageVoiceResult(dropped, token: token))
        #expect(vm.pendingAttachments.isEmpty)
    }

    // MARK: - Cold-start draft reconciliation (once per Today instance/scene)

    /// Isolated UserDefaults suite for the draft journal. The keys are written
    /// LITERALLY in these tests on purpose: `today.draftText.backup.<sceneID>`
    /// and `today.draftDate` are a frozen persistence contract with shipping
    /// builds, and the reconciliation must keep reading exactly these keys.
    private func draftDefaults() throws -> (defaults: UserDefaults, suite: String) {
        let suite = "TodayDraftRecovery-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (defaults, suite)
    }

    @Test func staleSceneSnapshotLosesToTheNewerSceneMirrorOnColdStart() throws {
        defer { cleanup() }
        // Regression for the verified cold-recovery failure: after a force
        // stop/launch, SceneStorage restored an OLD R1 snapshot while the
        // per-scene mirror journal held the current R2. The journal wins.
        let (defaults, suite) = try draftDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let sceneID = UUID().uuidString
        defaults.set("QA draft4 R2 - Keep draft.", forKey: "today.draftText.backup.\(sceneID)")
        defaults.set(Date().timeIntervalSince1970 - 60, forKey: "today.draftDate")

        let coldLaunch = TodayViewModel(date: Date(), observeChanges: false)
        #expect(coldLaunch.reconcileInitialDraft(
            sceneID: sceneID,
            sceneText: "QA draft4 R1 - stale snapshot",
            defaults: defaults
        ) == "QA draft4 R2 - Keep draft.")
    }

    @Test func emptySceneStorageRestoresTheSceneMirrorJournal() throws {
        defer { cleanup() }
        // Classic R4-B2 case: SceneStorage came back empty after a process
        // kill and only the journal knows the in-flight draft.
        let (defaults, suite) = try draftDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let sceneID = UUID().uuidString
        defaults.set("restored from the scene journal", forKey: "today.draftText.backup.\(sceneID)")
        defaults.set(Date().timeIntervalSince1970 - 60, forKey: "today.draftDate")

        #expect(vm.reconcileInitialDraft(sceneID: sceneID, sceneText: "", defaults: defaults)
                == "restored from the scene journal")
    }

    @Test func missingMirrorClearsTheStaleSceneSnapshot() throws {
        defer { cleanup() }
        // The mirror is the journal: send and confirmed discard clear it
        // synchronously. Its absence must drop the stale snapshot — never
        // resurrect a draft the user already destroyed.
        let (defaults, suite) = try draftDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let sceneID = UUID().uuidString

        #expect(vm.reconcileInitialDraft(
            sceneID: sceneID,
            sceneText: "already sent or discarded",
            defaults: defaults
        ) == "")
    }

    @Test func emptyMirrorAlsoClearsTheStaleSceneSnapshot() throws {
        defer { cleanup() }
        // An explicitly emptied journal is the same clear decision.
        let (defaults, suite) = try draftDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let sceneID = UUID().uuidString
        defaults.set("", forKey: "today.draftText.backup.\(sceneID)")

        #expect(vm.reconcileInitialDraft(
            sceneID: sceneID,
            sceneText: "stale snapshot",
            defaults: defaults
        ) == "")
    }

    @Test func laterPresentationsKeepLiveTypingInsteadOfReplayingTheMirror() throws {
        defer { cleanup() }
        // Only the FIRST presentation reconciles. Returning from a detail
        // page must not overwrite what the user typed since — the mirror is
        // debounced and can still hold the older text.
        let (defaults, suite) = try draftDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let sceneID = UUID().uuidString
        defaults.set("QA draft4 R2", forKey: "today.draftText.backup.\(sceneID)")
        defaults.set(Date().timeIntervalSince1970 - 60, forKey: "today.draftDate")

        #expect(vm.reconcileInitialDraft(sceneID: sceneID, sceneText: "QA draft4 R1", defaults: defaults) == "QA draft4 R2")
        #expect(vm.hasReconciledInitialDraft)
        // Typing happened; the debounce has not flushed the mirror yet.
        #expect(vm.reconcileInitialDraft(sceneID: sceneID, sceneText: "QA draft4 R2 - typing right now", defaults: defaults) == nil)
        #expect(vm.reconcileInitialDraft(sceneID: sceneID, sceneText: "QA draft4 R2 - typing right now", defaults: defaults) == nil)
    }

    @Test func reconciliationNeverReadsAnotherScenesMirror() throws {
        defer { cleanup() }
        // Multi-window safety: exactly this scene's key is consulted, never
        // any other scene's journal entry.
        let (defaults, suite) = try draftDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let sceneID = UUID().uuidString
        let otherSceneID = UUID().uuidString
        defaults.set("another window's draft", forKey: "today.draftText.backup.\(otherSceneID)")
        defaults.set(Date().timeIntervalSince1970 - 60, forKey: "today.draftDate")

        // No journal for THIS scene: the other scene's draft must not leak in.
        #expect(vm.reconcileInitialDraft(
            sceneID: sceneID,
            sceneText: "stale snapshot",
            defaults: defaults
        ) == "")
        // With a journal of its own, this scene recovers its own draft.
        defaults.set("my scene's draft", forKey: "today.draftText.backup.\(sceneID)")
        let coldLaunch = TodayViewModel(date: Date(), observeChanges: false)
        #expect(coldLaunch.reconcileInitialDraft(sceneID: sceneID, sceneText: "", defaults: defaults) == "my scene's draft")
    }

    @Test func expiredBackupIsNotResurrectedWhenSceneStorageComesBackEmpty() throws {
        defer { cleanup() }
        // US-006 judged on the recovery result: an expired backup must not be
        // resurrected just because SceneStorage came back empty. The discard
        // is durable — the stale journal entry is removed so no later launch
        // can revive it either.
        let (defaults, suite) = try draftDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let sceneID = UUID().uuidString
        let mirrorKey = "today.draftText.backup.\(sceneID)"
        defaults.set("31-day-old unsent draft", forKey: mirrorKey)
        defaults.set(Date().timeIntervalSince1970 - (30 * 24 * 3600 + 3600), forKey: "\(mirrorKey).modifiedAt")

        #expect(vm.reconcileInitialDraft(sceneID: sceneID, sceneText: "", defaults: defaults) == "")
        #expect(defaults.string(forKey: mirrorKey) == nil)
        let relaunch = TodayViewModel(date: Date(), observeChanges: false)
        #expect(relaunch.reconcileInitialDraft(sceneID: sceneID, sceneText: "", defaults: defaults) == nil)
    }

    @Test func backupJustInsideThirtyDaysStillRestores() throws {
        defer { cleanup() }
        // Boundary: the 30-day limit is strictly-greater, exactly like
        // DraftStorage.clearIfExpired — just inside it the draft survives.
        let (defaults, suite) = try draftDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let sceneID = UUID().uuidString
        defaults.set("just-inside-the-limit draft", forKey: "today.draftText.backup.\(sceneID)")
        defaults.set(Date().timeIntervalSince1970 - (30 * 24 * 3600 - 60), forKey: "today.draftText.backup.\(sceneID).modifiedAt")

        #expect(vm.reconcileInitialDraft(sceneID: sceneID, sceneText: "", defaults: defaults) == "just-inside-the-limit draft")
    }

    @Test func unstampedLegacyJournalPreservesUnknownAgeAcrossLaunches() throws {
        defer { cleanup() }
        let (defaults, suite) = try draftDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("keep the unknown-age draft", forKey: "today.draftText.backup.scene-A")
        // Another window may clear the global date; absence proves no age.
        #expect(vm.reconcileInitialDraft(sceneID: "scene-A", sceneText: "old", defaults: defaults) == "keep the unknown-age draft")
        #expect(defaults.string(forKey: "today.draftText.backup.scene-A") == "keep the unknown-age draft")
        let relaunched = TodayViewModel(date: Date(), observeChanges: false)
        #expect(relaunched.reconcileInitialDraft(sceneID: "scene-A", sceneText: "", defaults: defaults) == "keep the unknown-age draft")
    }

    @Test func anotherEmptyWindowCannotExpireThisScenesJournal() throws {
        defer { cleanup() }
        let (defaults, suite) = try draftDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        defaults.set("window A live draft", forKey: "today.draftText.backup.A")
        defaults.set(now.timeIntervalSince1970 - 60, forKey: "today.draftText.backup.A.modifiedAt")
        defaults.set(0, forKey: "today.draftDate")
        #expect(vm.reconcileInitialDraft(sceneID: "A", sceneText: "old", defaults: defaults, now: now) == "window A live draft")
        #expect(defaults.double(forKey: "today.draftText.backup.A.modifiedAt") == now.timeIntervalSince1970 - 60)
    }

    @Test func exactThirtyDayBoundaryPreservesDraftAndItsOriginalAge() throws {
        defer { cleanup() }
        let (defaults, suite) = try draftDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let savedAt = now.timeIntervalSince1970 - 30 * 24 * 3600
        defaults.set("boundary draft", forKey: "today.draftText.backup.A")
        defaults.set(savedAt, forKey: "today.draftText.backup.A.modifiedAt")
        #expect(vm.reconcileInitialDraft(sceneID: "A", sceneText: "", defaults: defaults, now: now) == "boundary draft")
        #expect(defaults.double(forKey: "today.draftText.backup.A.modifiedAt") == savedAt)
    }

    @Test func freshGlobalDateCannotResurrectExpiredSceneOrDeleteOtherScene() throws {
        defer { cleanup() }
        let (defaults, suite) = try draftDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        defaults.set("expired A", forKey: "today.draftText.backup.A")
        defaults.set(now.timeIntervalSince1970 - 30 * 24 * 3600 - 1, forKey: "today.draftText.backup.A.modifiedAt")
        defaults.set("live B", forKey: "today.draftText.backup.B")
        defaults.set(now.timeIntervalSince1970, forKey: "today.draftText.backup.B.modifiedAt")
        defaults.set(now.timeIntervalSince1970, forKey: "today.draftDate")
        #expect(vm.reconcileInitialDraft(sceneID: "A", sceneText: "expired A", defaults: defaults, now: now) == "")
        #expect(defaults.object(forKey: "today.draftText.backup.A") == nil)
        #expect(defaults.object(forKey: "today.draftText.backup.A.modifiedAt") == nil)
        #expect(defaults.string(forKey: "today.draftText.backup.B") == "live B")
        #expect(defaults.double(forKey: "today.draftText.backup.B.modifiedAt") == now.timeIntervalSince1970)
    }

    @Test func coldReplacementRetiresVoiceButLaterAppearanceKeepsNewGeneration() throws {
        defer { cleanup() }
        let (defaults, suite) = try draftDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("new journal draft", forKey: "today.draftText.backup.A")
        let oldDock = vm.composerToken(for: .dock)
        let oldSheet = vm.composerToken(for: .writeSheet)
        #expect(vm.reconcileInitialDraft(sceneID: "A", sceneText: "old", defaults: defaults) == "new journal draft")
        #expect(!vm.isComposerTokenCurrent(oldDock))
        #expect(!vm.isComposerTokenCurrent(oldSheet))
        let live = vm.composerToken(for: .writeSheet)
        #expect(vm.reconcileInitialDraft(sceneID: "A", sceneText: "new typing", defaults: defaults) == nil)
        #expect(vm.isComposerTokenCurrent(live))
    }

    @Test func expiredGlobalLegacyDateAloneCannotDeleteAnUnstampedJournal() throws {
        defer { cleanup() }
        let (defaults, suite) = try draftDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("legacy journal", forKey: "today.draftText.backup.A")
        defaults.set(1, forKey: "today.draftDate")
        #expect(vm.reconcileInitialDraft(sceneID: "A", sceneText: "old", defaults: defaults) == "legacy journal")
        #expect(defaults.string(forKey: "today.draftText.backup.A") == "legacy journal")
    }

    @Test func explicitSendClearIsNotResurrectedByTheNextLaunch() throws {
        defer { cleanup() }
        // Lifecycle: the draft is journaled, then the user sends it and the
        // clear runs synchronously (TodayView.submitComposer removes the
        // journal key in the same turn). A relaunch over a stale snapshot
        // must show nothing — the sent draft stays gone.
        let (defaults, suite) = try draftDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let sceneID = UUID().uuidString
        let mirrorKey = "today.draftText.backup.\(sceneID)"
        defaults.set("QA draft4 R2 - sent", forKey: mirrorKey)
        defaults.set(Date().timeIntervalSince1970 - 60, forKey: "today.draftDate")
        #expect(vm.reconcileInitialDraft(sceneID: sceneID, sceneText: "", defaults: defaults) == "QA draft4 R2 - sent")
        // ...the user sends it (explicit synchronous clear of the journal):
        defaults.removeObject(forKey: mirrorKey)

        let relaunch = TodayViewModel(date: Date(), observeChanges: false)
        #expect(relaunch.reconcileInitialDraft(
            sceneID: sceneID,
            sceneText: "QA draft4 R2 - sent",
            defaults: defaults
        ) == "")
        #expect(defaults.string(forKey: mirrorKey) == nil)
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

    private func photoResult(_ name: String) throws -> PhotoPickerResult {
        let relative = "raw/assets/\(name)"
        let url = tempDir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        try #require(image.jpegData(compressionQuality: 0.8)).write(to: url)
        return PhotoPickerResult(filePath: relative, fileURL: url, exif: nil, thumbnail: nil)
    }

    private func voiceResult(_ name: String, transcript: String? = nil) throws -> VoiceRecordingResult {
        let relative = "raw/assets/\(name)"
        let url = tempDir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x00, 0x01, 0x02]).write(to: url)
        return VoiceRecordingResult(filePath: relative, fileURL: url, duration: 3, transcript: transcript)
    }

    private func makeMemo(body: String, created: Date = Date()) -> Memo {
        Memo(
            id: UUID(),
            type: .text,
            created: created,
            body: body
        )
    }
}
}

typealias TodayViewModelTests = DayPageSerialSwiftTests.TodayViewModelTests
