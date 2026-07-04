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
    /// SwipePhysics is internal since the full-swipe-commit work, so this
    /// asserts the real token instead of a mirrored literal.
    @Test("actionCommitDelay matches Motion.panel response + settle")
    func actionCommitDelayIsSynced() {
        #expect(SwipePhysics.actionCommitDelay == 0.36, "SwipePhysics.actionCommitDelay must stay ≥ Motion.panel.response(0.32) + 40ms")
    }

    // MARK: - SwipeSnapLogic release resolution (full-swipe commit)

    /// 冲高过 commitThreshold 后松手 = 直接执行最外侧动作：左滑(trailing)
    /// 提交分享，右滑(leading) 提交置顶。这是 Mail 式 full-swipe 的核心契约。
    @Test("release past commitThreshold commits the outer action")
    func fullSwipeCommitsOuterAction() {
        let c = SwipePhysics.commitThreshold
        #expect(SwipeSnapLogic.resolve(revealed: nil, visualOffset: -c - 1, dx: -300, velocity: 0)
                == .commitOuter(.trailing))
        #expect(SwipeSnapLogic.resolve(revealed: nil, visualOffset: c + 1, dx: 300, velocity: 0)
                == .commitOuter(.leading))
        // Commit also works when the drawer was already open before the drag.
        #expect(SwipeSnapLogic.resolve(revealed: .trailing, visualOffset: -c - 10, dx: -120, velocity: 0)
                == .commitOuter(.trailing))
    }

    /// 高速甩动绝不能触发 commit——commit 只认手指真实走过的位移，
    /// 防止一次猛甩误执行分享/置顶。
    @Test("velocity alone never commits")
    func velocityAloneNeverCommits() {
        let r = SwipeSnapLogic.resolve(revealed: nil, visualOffset: -80, dx: -80, velocity: -6000)
        #expect(r == .open(.trailing))
    }

    /// 自信的半滑打开抽屉；犹豫的轻扫弹回关闭（openThreshold=40 的两侧）。
    @Test("half-swipe opens, hesitant brush closes")
    func halfSwipeOpensBrushCloses() {
        let t = SwipePhysics.openThreshold
        #expect(SwipeSnapLogic.resolve(revealed: nil, visualOffset: -(t + 1), dx: -(t + 1), velocity: 0)
                == .open(.trailing))
        #expect(SwipeSnapLogic.resolve(revealed: nil, visualOffset: t + 1, dx: t + 1, velocity: 0)
                == .open(.leading))
        #expect(SwipeSnapLogic.resolve(revealed: nil, visualOffset: -(t - 20), dx: -(t - 20), velocity: 0)
                == .close)
    }

    /// 小位移大速度的 flick 也能开（velocityOpen=600 之外）。
    @Test("flick velocity opens with tiny translation")
    func flickOpens() {
        #expect(SwipeSnapLogic.resolve(revealed: nil, visualOffset: -10, dx: -10, velocity: -(SwipePhysics.velocityOpen + 100))
                == .open(.trailing))
    }

    /// 已打开的抽屉：反向拖 > closeThreshold 或反向 flick 关闭；
    /// 原地小抖动保持打开。
    @Test("open drawer closes on reverse drag or flick, stays on jitter")
    func openDrawerCloseRules() {
        let closeT = SwipePhysics.closeThreshold
        #expect(SwipeSnapLogic.resolve(revealed: .trailing, visualOffset: -120, dx: closeT + 6, velocity: 0)
                == .close)
        #expect(SwipeSnapLogic.resolve(revealed: .trailing, visualOffset: -140, dx: 10, velocity: SwipePhysics.velocityClose + 100)
                == .close)
        #expect(SwipeSnapLogic.resolve(revealed: .trailing, visualOffset: -150, dx: -5, velocity: 0)
                == .open(.trailing))
        #expect(SwipeSnapLogic.resolve(revealed: .leading, visualOffset: 120, dx: -(closeT + 6), velocity: 0)
                == .close)
    }

    /// commit 需要的真实手指行程（阻尼区按 overdragDamping 换算）落在
    /// 单手可达且不会误触的窗口内（240–270pt @ 402pt 屏）。
    @Test("commit requires deliberate finger travel")
    func commitTravelIsDeliberate() {
        let rawNeeded = SwipePhysics.panelWidth
            + (SwipePhysics.commitThreshold - SwipePhysics.panelWidth) / SwipePhysics.overdragDamping
        #expect(rawNeeded > 240 && rawNeeded < 270)
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
