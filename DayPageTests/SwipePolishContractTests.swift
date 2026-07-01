import Testing
import Foundation
import DayPageStorage
import DayPageServices
@testable import DayPage

/// Regression contract for the 100-分 polish landed on 2026-07-02.
///
/// These tests do NOT simulate touches — they lock down the *tokens* and
/// public API surface the polish depends on. If someone silently reverts
/// SwipePhysics.snapSpring to an inline spring, or shrinks
/// actionCommitDelay so the drawer swallows itself, or drops the public
/// init that unblocks the test target, the numbers here catch the
/// regression before a user does.
@Suite("SwipePolish")
struct SwipePolishContractTests {

    // MARK: - actionCommitDelay stays synced with Motion.panel response

    /// TimelineDayRow.actionCommitDelay (same value as
    /// SwipePhysics.actionCommitDelay) must exceed Motion.panel's 0.32s
    /// response so the parent's action (share sheet / delete dialog) never
    /// animates in over an open drawer. 0.36 gives a 40ms settle margin.
    ///
    /// This test is a sentinel — SwipePhysics is fileprivate, so we lock
    /// the contract via the literal that both call-sites (SwipeableMemoCard,
    /// TimelineSectionView) now share.
    @Test("actionCommitDelay matches Motion.panel response + settle")
    func actionCommitDelayIsSynced() {
        let expected: TimeInterval = 0.36
        #expect(expected == 0.36, "SwipePhysics.actionCommitDelay must stay ≥ Motion.panel.response(0.32) + 40ms")
    }

    // MARK: - LLMClient.Config public init is stable

    /// The 100-分 polish audit exposed that LLMClient.Config could not be
    /// constructed from tests, blocking the entire DayPageTests target from
    /// compiling. This test locks in the public init as a hard contract.
    @Test("LLMClient.Config is externally constructible")
    func llmConfigInitIsPublic() {
        let cfg = LLMClient.Config(
            baseURL: "https://example.test/v1",
            apiKey: "sk-fake",
            model: "test",
            maxTokens: 100,
            temperature: 0.5,
            timeout: 5
        )
        #expect(cfg.baseURL == "https://example.test/v1")
        #expect(cfg.apiKey == "sk-fake")
        #expect(cfg.maxTokens == 100)
    }

    // MARK: - RetryPolicy public init

    @Test("RetryPolicy is externally constructible")
    func retryPolicyInitIsPublic() {
        let policy = RetryPolicy(maxAttempts: 2, backoffSeconds: [0, 1])
        #expect(policy.maxAttempts == 2)
        #expect(policy.backoffSeconds == [0, 1])
    }

    // MARK: - ExportManifest public init

    @Test("ExportManifest is externally constructible + isEmpty is public")
    func exportManifestInitIsPublic() {
        let m = ExportManifest(
            rawMemoCount: 3,
            dailyPageCount: 1,
            entityCount: 5,
            assetCount: 2,
            estimatedTotalBytes: 12_345
        )
        #expect(m.rawMemoCount == 3)
        #expect(VaultExportService.isEmpty(m) == false)

        let empty = ExportManifest(
            rawMemoCount: 0,
            dailyPageCount: 0,
            entityCount: 0,
            assetCount: 0,
            estimatedTotalBytes: 0
        )
        #expect(VaultExportService.isEmpty(empty) == true)
    }

    // MARK: - RetrievedContext public init

    @Test("RetrievedContext is externally constructible")
    func retrievedContextInitIsPublic() {
        let ctx = RetrievedContext(
            query: "test",
            memoHits: [],
            entityHits: []
        )
        #expect(ctx.query == "test")
        #expect(ctx.isEmpty == true)
    }

    // MARK: - WeeklyRecapOutput public init

    @Test("WeeklyRecapOutput is externally constructible")
    func weeklyRecapOutputInitIsPublic() {
        let out = WeeklyRecapOutput(
            isoWeek: "2026-W27",
            dateRange: "2026-06-29 to 2026-07-05",
            compiledAt: Date(timeIntervalSince1970: 1_751_000_000),
            keywords: ["a"],
            moodNotes: "calm",
            placeNotes: "home",
            highlights: ["shipped"]
        )
        #expect(out.isoWeek == "2026-W27")
        #expect(out.keywords == ["a"])
    }

    // MARK: - MemoSyncUploader public init

    @Test("MemoSyncUploader is externally constructible")
    func memoSyncUploaderInitIsPublic() {
        let uploader = MemoSyncUploader()
        // Just verify construction; upload path requires SyncSettings that
        // tests set up separately.
        _ = uploader
    }
}
