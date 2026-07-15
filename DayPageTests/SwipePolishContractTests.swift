import Testing
import Foundation
import DayPageStorage
import DayPageServices
@testable import DayPage

/// Regression contract for the 100-分 polish landed on 2026-07-02.
///
/// These tests do NOT simulate touches — they lock down the *tokens* and
/// public API surface the polish depends on. If someone silently reverts
/// the velocity-handoff springs / momentum projection to fixed thresholds,
/// or shrinks actionCommitDelay so the drawer swallows itself, or drops the
/// public init that unblocks the test target, the numbers here catch the
/// regression before a user does.
@Suite("SwipePolish")
struct SwipePolishContractTests {

    // MARK: - actionCommitDelay stays synced with Motion.panel response

    /// TimelineDayRow.actionCommitDelay (same value as
    /// SwipePhysics.actionCommitDelay) must cover the close spring's visual
    /// settle (response 0.35s, critically damped → ~99% flush at 0.36s) so
    /// the parent's action (share sheet / delete dialog) never animates in
    /// over an open drawer.
    ///
    /// SwipePhysics is internal since the full-swipe-commit work, so this
    /// asserts the real token instead of a mirrored literal.
    @Test("actionCommitDelay covers the close spring settle")
    func actionCommitDelayIsSynced() {
        #expect(SwipePhysics.actionCommitDelay == 0.36, "SwipePhysics.actionCommitDelay must stay ≥ closeSpring response(0.35) + settle margin")
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

    /// 小位移大速度的 flick 也能开——动量投射把 700pt/s 折算成 ~69pt 的
    /// 预期滑行距离,越过 openThreshold(40)。
    @Test("flick velocity opens with tiny translation")
    func flickOpens() {
        #expect(SwipeSnapLogic.resolve(revealed: nil, visualOffset: -10, dx: -10, velocity: -700)
                == .open(.trailing))
    }

    /// 已打开的抽屉：反向拖 > closeThreshold 或反向 flick 关闭；
    /// 原地小抖动保持打开。
    @Test("open drawer closes on reverse drag or flick, stays on jitter")
    func openDrawerCloseRules() {
        let closeT = SwipePhysics.closeThreshold
        #expect(SwipeSnapLogic.resolve(revealed: .trailing, visualOffset: -120, dx: closeT + 6, velocity: 0)
                == .close)
        // 10pt 反向拖 + 600pt/s 反向 flick:投射 ~69pt 的关闭意图。
        #expect(SwipeSnapLogic.resolve(revealed: .trailing, visualOffset: -140, dx: 10, velocity: 600)
                == .close)
        #expect(SwipeSnapLogic.resolve(revealed: .trailing, visualOffset: -150, dx: -5, velocity: 0)
                == .open(.trailing))
        #expect(SwipeSnapLogic.resolve(revealed: .leading, visualOffset: 120, dx: -(closeT + 6), velocity: 0)
                == .close)
    }

    /// 动量投射契约(WWDC Designing Fluid Interfaces 公式):
    /// project(v) = v/1000 · rate/(1−rate)。rate=0.99 → 600pt/s ≈ 59.4pt。
    /// 这是老 velocityOpen=600 悬崖的连续化——同样的 flick 依旧能开,
    /// 但中间速度也按比例参与判定,而不是全有或全无。
    @Test("momentum projection replaces the velocity cliffs")
    func momentumProjectionScale() {
        let p600 = SwipePhysics.project(velocity: 600)
        #expect(abs(p600 - 59.4) < 0.5)
        // 缓慢漂移也有贡献,只是小:100pt/s ≈ 9.9pt。
        #expect(abs(SwipePhysics.project(velocity: 100) - 9.9) < 0.2)
        // 奇函数:方向对称。
        #expect(SwipePhysics.project(velocity: -600) == -p600)
    }

    /// 边界橡皮筋契约:commit 线之后位移渐近封顶,卡片永远拖不出
    /// commitThreshold + terminalOvershoot;三段曲线连续且单调。
    @Test("damped offset rubber-bands to a hard asymptotic cap")
    func dampedOffsetIsCapped() {
        let w = SwipePhysics.panelWidth
        let cap = SwipePhysics.commitThreshold + SwipePhysics.terminalOvershoot
        // Stage 1 — 1:1 up to the panel.
        #expect(SwipePhysics.dampedOffset(w) == w)
        #expect(SwipePhysics.dampedOffset(-80) == -80)
        // Stage 2 — the 0.85 doorway keeps commit reachable.
        #expect(SwipePhysics.dampedOffset(260) > SwipePhysics.commitThreshold)
        // Stage 3 — even an absurd drag never exceeds the terminal cap.
        #expect(SwipePhysics.dampedOffset(10_000) < cap)
        #expect(SwipePhysics.dampedOffset(-10_000) > -cap)
        // Monotonic: more finger travel never moves the card backwards.
        var last: CGFloat = 0
        for raw in stride(from: CGFloat(0), through: 800, by: 10) {
            let v = SwipePhysics.dampedOffset(raw)
            #expect(v >= last)
            last = v
        }
    }

    /// commit 需要的真实手指行程（阻尼区按 overdragDamping 换算）落在
    /// 单手可达且不会误触的窗口内（240–270pt @ 402pt 屏）。
    @Test("commit requires deliberate finger travel")
    func commitTravelIsDeliberate() {
        let rawNeeded = SwipePhysics.panelWidth
            + (SwipePhysics.commitThreshold - SwipePhysics.panelWidth) / SwipePhysics.overdragDamping
        #expect(rawNeeded > 240 && rawNeeded < 270)
    }

    // MARK: - Direction lock (velocity gate)
    //
    // Issue #808: UIKit consults gestureRecognizerShouldBegin exactly ONCE
    // per touch, at the pan's own hysteresis where accumulated translation
    // is still ~1pt. The old `dx >= 6pt` translation gate therefore failed
    // the pan on its single query and swipe-to-reveal was dead. The gate
    // now judges VELOCITY, which is fully formed at that first query —
    // these tests lock in the velocity contract.

    @Test("slow horizontal drags pass the direction gate")
    func slowHorizontalDragPassesGate() {
        // ~60pt/s is a very deliberate, slow swipe — must still open.
        #expect(HorizontalPanGesture.isHorizontalDominant(vx: -60, vy: 0))
        #expect(HorizontalPanGesture.isHorizontalDominant(vx: 60, vy: 10))
    }

    @Test("vertical and steep-diagonal drags fail the gate (scroll wins)")
    func verticalDragFailsGate() {
        #expect(!HorizontalPanGesture.isHorizontalDominant(vx: 0, vy: -300))
        #expect(!HorizontalPanGesture.isHorizontalDominant(vx: 100, vy: 100))
        // Exactly at the dominance boundary the scroll keeps ownership.
        #expect(!HorizontalPanGesture.isHorizontalDominant(vx: 120, vy: 100))
    }

    @Test("shallow horizontal flick passes at the 1.2x dominance ratio")
    func shallowFlickPassesGate() {
        #expect(HorizontalPanGesture.isHorizontalDominant(vx: 121, vy: 100))
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
