# DayPage — Claude Code Project Guidelines

## Overview

DayPage: a personal logging tool centered on daily raw data capture. Users dump, AI compiles into structured diary entries and a knowledge network each day. Target users: nomads / digital nomads.

## Tech Stack

### Client

| Layer | Choice | Notes |
|---|---|---|
| Platform | **iOS 16.0+**, Swift 5 | Single Xcode target `DayPage.app`; direct SPM deps: **Supabase** (supabase-swift), **Sentry** (sentry-cocoa); transitive: swift-clocks, swift-concurrency-extras, swift-http-types, xctest-dynamic-overlay |
| UI | **SwiftUI** (pure) | `UITabBarAppearance` is the primary UIKit touchpoint (`RootView.swift`). `UIViewControllerRepresentable` wrappers (`ShareSheet`, `CameraPickerView`, `DocumentPickerView`) are used where SwiftUI has no native equivalent (`UIActivityViewController`, `UIImagePickerController`, `UIDocumentPickerViewController`). |
| Navigation | **Sidebar** | Left drawer (280pt) — Today / Archive / Graph; no bottom TabBar |
| State | `ObservableObject` + `@Published` + `@StateObject`, `@MainActor` services | No `@Observable` macro (Swift 5 constraint) |
| Persistence | **File system** — YAML front-matter + Markdown | `vault/raw/YYYY-MM-DD.md`, multi-memo separated by `\n\n---\n\n`. Atomic writes via `FileManager.replaceItem`. No Core Data / SwiftData |
| YAML / Markdown | Hand-written parser in `Models/Memo.swift` | No external Markdown library |
| Voice recording | **AVFoundation** `AVAudioRecorder` → M4A | Stored under `vault/raw/assets/` |
| Speech-to-text | **OpenAI Whisper API** (`whisper-1`) | `VoiceService.swift`; transcript saved to `Attachment.transcript` |
| Camera / photos | **PhotosUI** + `PHPicker` | EXIF extraction (aperture, shutter, ISO, focal length, GPS, timestamp); originals saved, thumbnails for UI |
| Location | **CoreLocation** + reverse geocoding | `LocationService.swift` |
| Weather | **OpenWeatherMap API** (free tier) | 10-min cache, `zh_cn` locale (`WeatherService.swift`) |
| Fonts | Space Grotesk / Inter / JetBrains Mono (TTF in bundle) | Registered via `DSFonts.registerAll()` at app launch |

### AI Compilation Engine

| Feature | Choice | Notes |
|---|---|---|
| Provider | **Aliyun DashScope** (OpenAI-compatible) | `CompilationService.swift`, model `qwen3.5-plus`, base URL `https://dashscope.aliyuncs.com/compatible-mode/v1` |
| API key | `Config/GeneratedSecrets.swift` (auto-generated from env, not committed) | Never hardcode in source |
| Schedule | **BGTaskScheduler** (`BGAppRefreshTask`) | Identifier `com.daypage.daily-compilation`, 02:00 local daily, with backfill + local notification (`BackgroundCompilationService.swift`) |
| Input | Text only — no raw audio / image bytes sent | ~2k–5k tokens per day for 20 memos |

## Project Structure

```
DayPage/
  App/              RootView, DayPageApp, Fonts, Typography
  Features/
    Today/          TodayView + TodayViewModel (268 lines)
    Archive/        ArchiveView (655 lines, calendar + list)
    Graph/          GraphView + GraphViewModel (force-layout knowledge graph, node tap → EntityPage, search + date filter; ~594 lines)
  Models/           Memo, Attachment, YAML parser
  Services/         RawStorage, Location, Weather, Photo, Voice, Compilation, BackgroundCompilation
  Config/           GeneratedSecrets (gitignored)
```

**CODEX frontend**: lives in this repo's `web/` directory (Next.js) — the same app served at `localhost:3000`. Its env vars (e.g. `DASHSCOPE_API_KEY`) must be configured in `web/.env.local`, not in the iOS-side `Config/GeneratedSecrets.swift`.

**Pipeline**: Today (raw input) → AI compilation → Daily Page (structured diary) → Entity Pages → Graph (knowledge graph view).

## Architecture (Round 5-9 累计追加)

### 离线同步队列 (R5-R6, R8-R9 加固)
- `DayPage/Services/SyncQueueService.swift` — @MainActor singleton；@Published pendingMemoIDs/totalBytes/oldestPendingDate；UserDefaults 持久化；memoSizes dict 记录 enqueue size 用于 markSynced 正确递减；R9 加 estimateMemoSize fallback 扫 vault/raw 处理 legacy 数据
- `DayPage/Services/SyncQueueObserver.swift` — 监听 .syncQueueFlushRequested → RemoteUploader protocol（占位 NoopRemoteUploader sleep 300ms，5s 前置 debounce 让 banner 可见）；后续真实 Supabase 同步从此处注入
- `DayPage/Services/NetworkMonitor.swift` — realIsOnline + simulateOffline computed；Settings 实验功能 toggle 绑定 @AppStorage "debug.simulateOffline" 让 dogfood 用户能真实测试 banner
- TodayView 顶部 syncQueuePendingBanner（条件：FeatureFlag.offlineQueue && !isEmpty && bannerCount<3）；点击 sheet 显示前 50 条 pendingID，行 tap → post .openMemo

### 时光胶囊 OnThisDay (R6, R8-R9 调位)
- `DayPage/Services/OnThisDayIndex.swift` — 扫 vault/raw 按 MMDD 索引；candidate(for:) 优先 1 年前 → 180 天前 → 2 年前；@Published isReady；#if DEBUG resetForTesting() 用于测试隔离
- `DayPage/Services/OnThisDayScheduler.swift` — todayEntry @Published；refreshTodayEntry() 重新计算；markDismissedForToday() 持久化 dismiss
- `DayPage/Features/Today/OnThisDayCard.swift` — Card UI；i18n + a11y 完整
- TodayView 顶部独立 section（脱离 fallback，普通用户也能看到）；条件：FeatureFlag.onThisDay && viewModel.onThisDayEntry != nil && bannerCount<2；fallback 也保留（用 !shouldShowOnThisDayAtTop 互斥）
- DayPageApp 启动 priority .userInitiated（首次 1-2s 内卡片可见）

### 周回顾 WeeklyRecap (R7, R8-R9 自动化)
- `DayPage/Services/WeeklyCompilationService.swift` (~480 行) — 3 个公共方法 collectWeekMetadata / compileWeekly / loadCached；ISO-8601 周（firstWeekday=2, minDaysInFirstWeek=4）→ "YYYY-Www"；扫 vault/wiki/daily/ 解析 frontmatter；DeepSeek LLM 调用 + extractJSONBlock 解析；atomicWrite vault/wiki/weekly/{isoWeek}.md
- `DayPage/Features/Archive/WeeklyRecapDetailView.swift` — keywords chip + mood 卡 + places 列表 + highlights bullet；chip/place 改 Button → push EntityPageView；10 个 error case 各自文案；offline 自动监听 NetworkMonitor 重试
- BackgroundCompilationService.tryAutoCompileWeekly — 周一 + 上周 ≥3 daily 自动触发；post .weeklyRecapAvailable notification
- (#814) TodayView weeklyRecapPreview section 已移除 — ArchiveView 顶部入口卡（entries.count >= 3 才显示）是周回顾唯一 UI 入口

### 编译成本治理 (#814, 2026-07-05)
- **触发模型**：打开 App 不再自动编译当天（原 TodayViewModel.load() 的 compile(silent:true) 已删）；一天只在结束后编译一次 — 0 点 BGTask 编译昨天 + foregroundRetryIfNeeded（改为补编昨天）+ backfill 兜底；手动编译保留
- **source_hash 去重**：CompilationService.sourceHash(of:[Memo]) 只对 id+body+attachments(file/transcript) 做 SHA256，**刻意排除 mood/entityMentions**（applyMemoUpdates 编译后回写这两字段进 raw，纳入会造成编译完即"变脏"的无限重编环）；hash 注入 daily frontmatter `source_hash:`；compile(force:) 命中即跳过 LLM 并在 log.md 记 `skipped`；shouldCompile 升级 stale 检测（无 hash 的历史 daily 视为最新，防 backfill 重编全史）
- **WikiIndexService**（DayPageKit）— 每次编译后全量重建 vault/wiki/index.md（Daily/Weekly/Places/People/Themes 分区，每页一行 [[link]] + 摘要），纯本地零 LLM；与 EntityPageService.updateIndex 增量写入格式兼容且 rebuild 后覆盖其漂移（karpathy LLM-wiki 模式）
- **日页入口收敛**：Today timeline/fallback 历史日跳转统一走 DayDetailView（不再裸开 DailyPageView）

### FeatureFlag 框架 (R4 起点，R6-R8 加 case)
- `DayPage/Config/FeatureFlags.swift` — enum FeatureFlag: backlinks / compileNotification / widgetSystemMedium / aiKeyBanner / foregroundCompileRetry / offlineQueue / onThisDay / weeklyRecap（8 case，全部 default-on）
- FeatureFlagStore.shared @MainActor + UserDefaults 后端；Settings "实验功能" section 自动列出所有 case（CaseIterable + Toggle）
- Widget extension target 共享同一 FeatureFlags.swift 文件

### Notification.Name 中心化
集中声明位置：
- `.syncQueueFlushRequested` — SyncQueueService.swift
- `.openArchiveAt` — DayPageApp.swift（R3 backlinks + R6 OnThisDay tap 共用）
- `.compileSucceededForeground` — BackgroundCompilationService.swift（R4 前台编译重试成功）
- `.weeklyRecapAvailable` — BackgroundCompilationService.swift（R8 周一自动编译完成）
- `.simulateOfflineChanged` — NetworkMonitor.swift（R8 调试 toggle 联动）
- `.openMemo` / `.openEntityPage` — DayPageApp.swift（R8 跨页跳转规范）
- `.vaultConflictResolved` — ConflictMerger.swift（R4 iCloud 冲突 banner）
- `.rawStorageDidWrite` — RawStorage.swift
- `.memoCardDidBeginSwipe` — SwipeableMemoCard.swift（同屏仅一张卡开抽屉，Mail 语义）

### 测试覆盖矩阵 (9 个 suite, 55 个 case)
- MemoYAMLTests (R1) — yamlQuote 转义 round-trip 8 case
- RawStorageWriteFailedTests (R4) — replaceItemAt 错误传播
- LocationServiceLRUTests (R4) — geocoding cache 命中/淘汰/过期
- ArchiveViewModelGroupTests (R4) — 月度分组 + 跨月跨年
- SyncQueueServiceTests (R5+R9) — enqueue/markSynced + legacy migration 估算
- OnThisDayIntegrationTests (R6+R7) — candidate fallback + scheduler dismiss + FeatureFlag toggle
- WeeklyCompilationServiceTests (R7) — ISO 周 + frontmatter 聚合 + JSON parse + cache 读写
- NetworkMonitorTests (R8) — simulateOffline toggle 切换
- WeeklyRecapAutoTriggerTests (R8+R9) — 周一触发条件 + 真实 service path

## Coding Conventions

- SwiftUI views: value types; extract subviews when a `body` exceeds ~80 lines
- Services: `@MainActor final class`, singletons where shared state is required
- View models: `@MainActor final class: ObservableObject` with `@Published`
- `MARK: -` section comments for navigation
- No force-unwraps in production paths; prefer `guard let` / `throws`
- No external dependencies without discussion — prefer Apple frameworks
- For design-related issues, they should be deeply designed and discussed clearly with me. Then, submit a GitHub issue first. Use the appropriate branch to solve this issue. Finally, after testing and verification, create a PR. Remember to link this issue according to the PR guidelines.

## UI Design

Design assets have been removed. **Use the current source code as the authoritative reference for UI design** — read `DayPage/App/RootView.swift`, `DayPage/Features/Today/TodayView.swift`, etc. directly.

- Navigation: left sidebar drawer (`RootView.swift`), no bottom TabBar
- For new design decisions, discuss with the user first, then open a GitHub issue, implement on a branch, and PR

## Testing

A `DayPageTests` target exists using **Swift Testing** (iOS 16+ / Xcode 16+). Add new test files to that target.

**Default simulator**: use **iPhone 17** for all builds, runs, and UI verification (e.g. `xcodebuild -scheme DayPage -destination 'platform=iOS Simulator,name=iPhone 17'`).

**Simulator launch**: always start the Simulator in the background to avoid blocking the terminal session — use `open -a Simulator &` or run `xcodebuild` with `run_in_background: true`. Never let the Simulator occupy the foreground terminal.

Before marking any task complete:
1. Build the `DayPage` scheme (`xcodebuild -scheme DayPage build`)
2. Run any existing tests
3. For storage-related changes, inspect the actual `.md` file written under `vault/raw/` (use `get_app_container` to locate the sandbox) and verify YAML front-matter + Markdown structure
4. For UI changes, launch the app in Simulator (iPhone 17) and verify visually — SwiftUI preview alone is not sufficient

## Skill routing

When the user's request matches an available skill, ALWAYS invoke it using the Skill
tool as your FIRST action. Do NOT answer directly, do NOT use other tools first.
The skill has specialized workflows that produce better results than ad-hoc answers.

Key routing rules:
- Product ideas, "is this worth building", brainstorming → invoke office-hours
- Bugs, errors, "why is this broken", 500 errors → invoke investigate
- Ship, deploy, push, create PR → invoke ship
- QA, test the site, find bugs → invoke qa
- Code review, check my diff → invoke review
- Update docs after shipping → invoke document-release
- Weekly retro → invoke retro
- Design system, brand → invoke design-consultation
- Visual audit, design polish → invoke design-review
- Architecture review → invoke plan-eng-review
- Save progress, checkpoint, resume → invoke checkpoint
- Code quality, health check → invoke health
