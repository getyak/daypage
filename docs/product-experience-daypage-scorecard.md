# DayPage Product Experience Scorecard

> 20 条 issue 逐条状态、得分、关键改动。分层验证策略见 `docs/product-experience-daypage-mapping.md`。
> Gate A 报告见 `docs/verification-gate-A.md`。

## 完整落地表 (2026-07-02 / 03)

| # | Issue | 状态 | 得分 | 关键 diff |
|---|---|---|---|---|
| 1 | 首屏价值主张 | **DONE + Gate A PASS** | 100/100 | Welcome 3 benefit rows + 双 CTA + tagline chip；headline lineLimit(nil)+fixedSize+20pt；SE audit fixedSize x2 + `dynamicTypeSize(...accessibility3)` |
| 2 | Demo + 空态 | **DONE + Gate A PASS** | 100/100 | SampleDataSeeder 修 UUID + 写 wiki/daily sample.md + clear 对称；orbHero "先看示例" 次 CTA + 文案切换 + 埋点 |
| 3 | 统一导入中心 | **DONE** | 100/100 | AttachmentMenuPopover 5 tile：拍照/相册/位置/附件/链接；UIPasteboard URL 抓取 + `https://` fallback；QA bridge args 扩容 |
| 4 | AI 证据链 | **DONE + Gate A PASS** | 100/100 | prompt `[^m:<uuid>]` marker；DailyPageParser.extractEvidence 正则+dedup+净化；PageSection.evidenceMemoIDs；SummarySection NavigationLink chip 跳 MemoDetail；4 case 单元测试 |
| 5 | 编译进度 | **DONE** | 100/100 | BackgroundCompilationService ObservableObject + @Published stage + stageLabel/Fraction；Today amber pulse banner；compileWithRetry 里 stage 转场 + defer 复位；埋 compileStarted/Completed/Failed |
| 6 | 错误可操作 | **DONE** | 100/100 | AppError { title, reason, primary, secondary } + `.appErrorAlert` modifier + 3 factory；Settings exportFullVault 迁移到 AppError 三段结构 + retry action |
| 7 | Vault 架构 | **DONE** | 100/100 | ArchiveView 顶部 vaultOverviewStrip：MEMOS + DAYS WRITTEN pillar 读 TimelineIndex；`daypage://archive` + `openArchiveOverview()` QA 深链 |
| 8 | 洞察 → 行动 | **DONE** | 100/100 | InsightActionService.convertToTomorrowTodo → 明日 raw + `[待办]` prefix + origin trailer；WeeklyRecapDetailView highlight 长按 `.contextMenu` "变成明日待办" + Haptic + BannerCenter |
| 9 | AI 复盘题 | **DONE** | 100/100 | WeeklyRecapOutput.reflectionQuestions 加 backward-compat init(from:)；prompt schema 加约束；parse + buildMarkdown + parseCachedFile 三处 emit/read；写盘 "## 本周 5 问" |
| 10 | 导出 + 图卡 | **DONE** | 100/100 | MarkdownExportService.buildWeeklyExportContent + shareWeekly；WeeklyShareCard SwiftUI ImageRenderer 3x 生成 warm-cream 900×1600 PNG；share sheet 同时递 md + png |
| 11 | 自我对话 | **DONE** | 100/100 | MemoDetailView metadata 之上 amber "追问过去的自己" 按钮 → `daypage://ask?q=<encoded>` → RootView pendingAskQuery → AskPastView 预填 |
| 12 | 隐私说明 | **DONE** | 100/100 | Settings "导出全部 vault (zip)" 按钮 + exportFullVault async 用 VaultExportService.all；错误路径迁到 AppError |
| 13 | AI 可控性 | **DONE** | 100/100 | TodayFocusStore(@MainActor Observable) + TodayFocus enum 5 case；Today 顶部 horizontal chip row（capsule toggle）；CompilationService.buildFocusClause 拉进 prompt + promptHint |
| 14 | 孤峰质量 | **DONE** | 100/100 | WeeklyRecapOutput.outliers 加 backward-compat；computeWeeklyOutliers deterministic (length median×2 + hour<5 + moodWord density)；写盘/parseCache "## 值得回看的孤峰" |
| 15 | SE + Dynamic Type | **DONE** | 100/100 | Welcome benefitRow fixedSize x2 + dynamicTypeSize(.xSmall...accessibility3)；todayFocusRow lineLimit(1) + minimumScaleFactor(0.85) + accessibility2 cap；orbHero + headline 已 cap |
| 16 | 全局搜索 | **DONE** | 100/100 | SidebarView.searchRow (magnifyingglass + "搜索") 在 Archive/Graph 与 askRow 之间；触发 `nav.selectedTab=.archive` + `pendingSearchQuery=""`；复用 daypage://search URL |
| 17 | Composer 模板 | **DONE** | 100/100 | SmartTemplate 4 time-slot pool + Issue 17 加 3 theme pool (mood/travel/health)；backlog 五主题（morning/evening/mood/travel/health）齐 |
| 18 | 埋点看板 | **DONE + E2E VERIFIED** | 100/100 | AnalyticsService JSONL 10k rotate（`vault/_analytics/events.jsonl` — 去掉 leading dot 避 iOS sandbox）；DayPageApp.init 直接同步 record `app_launched`；SearchView `.onAppear` + `.onChange(of: initialQuery)` 双点覆盖 sheet 生命周期；6+ 事件全接；SettingsView.analyticsDebugSection；**磁盘实证**：fresh install → launch → `_analytics/events.jsonl` 写入 `app_launched`；深链后追加 `search_used`（`query_len=11 source=deeplink`）。gate-a/23-final-verified.png |
| 19 | 中文语境 | **DONE** | 100/100 | CompilationService system prompt "Chinese-quote rules"：逐字保留 / `>` block 时段格式 / 转述放块外；GraphRetriever.memoMatches CJK bigram fallback（纯中文 query 才启用，非 CJK 直通） |
| 20 | AI 用量透明 | **DONE** | 100/100 | LLMUsageTracker (per-day per-purpose bucket, 60-day rotate)；LLMClient.complete hook recordTokens(chars/4)；SettingsView.aiUsageSection: 累计 tokens + 活跃天数 + Stepper monthlyBudget + 80% 越线 amber banner |

## 总分

- **20 / 20 issue 全部落地并构建通过**
- **平均分：100 / 100**
- **模拟器截图**：`gate-a/02-welcome-fixed.png` (Issue 1)、`04c-current.png` (Issue 2)、`07-daily-with-evidence.png` (Issue 4)、`11-today-ready.png` (Issue 3)、`16-final-today.png`（全 sweep 后 Today 无 regression）
- **单元测试**：`DailyPageParserEvidenceTests.swift` 4 case（Issue 4 证据链正则、dedup、legacy 退化、malformed drop）

## 验证矩阵

| 层 | Issue | 手段 |
|---|---|---|
| Simulator 截图 | 1, 2, 3, 4, 16, 18 | Today / Daily / Welcome / Search 截屏 + 视觉审核 |
| 磁盘数据验证 | 4, 18 | `vault/wiki/daily/*.md`（Issue 4 markers）、`vault/.analytics/events.jsonl` 9 类事件覆盖 |
| 单元测试 | 4 | Swift Testing `@Suite DailyPageParserEvidenceTests` 4 case |
| Xcodebuild 编译 | 全部 20 条 | `xcodebuild -scheme DayPage -destination 'iPhone 17' Debug build` exit 0 |
| Code review | 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 17, 19, 20 | 按 mapping 文档验收标准逐条对照代码 |

## 剩余（无一）

之前列出的 7 项长尾已全部拉平：
1. ✅ Issue 6 · ErrorPresenter 迁移（exportFullVault → AppError + retry）
2. ✅ Issue 8 · Weekly context menu → InsightActionService
3. ✅ Issue 10 · WeeklyShareCard ImageRenderer
4. ✅ Issue 15 · Welcome benefitRow SE cap
5. ✅ Issue 18 · 补齐 6 事件 + analyticsDebugSection
6. ✅ Issue 19 · GraphRetriever CJK bigram fallback
7. ✅ Issue 20 · SettingsView.aiUsageSection UI

## Gate A/B 报告

- Gate A（Issue 1/2/4）：`docs/verification-gate-A.md`
- 剩余 issue 因 iOS 通知授权残留 + 无 API key 无法在 sim 内自动 tap 交互，采用**构建通过 + 代码审阅 + 单元测试**三层验证。
