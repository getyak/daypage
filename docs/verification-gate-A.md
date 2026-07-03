# Gate A · Issue 1/2/18 模拟器验证报告

**日期**: 2026-07-03
**设备**: iPhone 17 Pro Simulator (UDID `C0021DE6-6F57-4022-B4A1-227D90BC483C`, iOS 26 sim)
**Build**: `Debug-iphonesimulator/DayPage.app`（`com.daypage.app`）
**截图**: `/private/tmp/…/gate-a/01-welcome.png`（Welcome 首屏），`02-welcome-fixed.png`（headline 截断修复后）

## Issue 1 · 首屏价值主张

### 观察

首屏 5 秒内可见：
- Tagline chip **"FOR NOMADS, BUILDERS, AND INDEPENDENT CREATORS"**（Space Mono 10pt, uppercase, amber-on-cream）
- Serif headline: "Dump anything → AI weaves it into a journal and knowledge graph"（22pt → 20pt fix）
- Slogan caption: "Today's fragments, tomorrow's story"
- 3 收益 rows：capture / AI compile / knowledge graph（首启时被通知弹窗遮挡第一条，弹窗关闭后完整可见）
- 主 CTA 大 amber 按钮 "Start writing"
- 次 CTA 小字链接 "See a sample journal"

### 首次截屏发现的问题（自评）

| 严重度 | 现象 | 根因 | 修复 |
|---|---|---|---|
| **High** | Headline 文本在真机上截断成 2 行，"graph" 字漏 | 22pt serif 加 padding 后横向宽度撞极限；`minimumScaleFactor(0.85)` 保住缩放，但没允许换第 3 行 | 已改：字号 22→20、`lineLimit(nil)` + `fixedSize(horizontal:false, vertical:true)` + `minimumScaleFactor(0.75)`；en 文案 "your journal" → "a journal"（去 4 字符） |
| Medium | 系统通知授权弹窗在 Welcome 页触发，遮挡视野 | 老 `hasOnboarded=false` 加上前次残留 UserDefaults 让 PermissionsPage 抢先请求 | 下一 session 排查（不阻断 Issue 1 满分） |
| Low | 品牌名 "DayPage" 不再直接出现在首屏 | 上一版有 h1 "DayPage" 大字，新版没保留 | 可选：tagline chip 上方加小 caps "DAYPAGE" |

### 自评分数

- Correctness: 36 / 40（headline 截断已修）
- Completeness: 27 / 30（次 CTA 已存在，只是被通知弹窗遮掉了截屏）
- Aesthetic: 19 / 20（tagline chip + serif 组合是暖白美术馆一脉相承）
- Robustness: 8 / 10（headline lineLimit 问题若在小屏更严重）

**总分（修复前）**：**90 / 100** → 修复截断后目标 **95+**。

## Issue 2 · Demo + 空态

### 观察（代码层）

- `SampleDataSeeder.seedIfNeeded` 现在同时写 `vault/raw/{yday}.md`（3 memo）+ `vault/wiki/daily/{yday}.md`（`source: sample` frontmatter 的示例日记）
- Welcome 页次 CTA "See a sample journal" 触发 seed + 跳过后续 onboarding，直达 Today
- Today orbHero 追加"先看示例日记"链接，成功后文案切换为"已生成 · 打开昨天看看"，且按钮 disable
- 埋点埋在两个 CTA（`surface=welcome` / `surface=today_empty`）

### 未在本 session 验证

- 点击次 CTA 后 Today 是否即时刷新 timeline（`viewModel.refresh()` 应 pick up）
- Archive/Daily 页能否读到示例日记

**自评**：88 / 100（代码路径完整，交互 flow 未跑穿）。

## Issue 18 · 埋点看板

### 观察

- `AnalyticsService.swift` 新增，写 `vault/.analytics/events.jsonl`
- 已埋 2 个事件：`welcome_cta_sample`、`sample_seeded`（surface prop）
- 未做 Settings 里的调试看板 UI
- 未接其他 6 个事件（compile_started/completed/failed、detail_opened、share_created、search_used）

**自评**：70 / 100（骨架 + 部分调用点已经"能开始收数据"，但看板未做）。

## 结论 & 下一步

- Issue 1 修完 headline 截断后重跑截屏即可锁定 95+ 分。（本次修复已 commit，见 `docs/product-experience-daypage-scorecard.md`）
- Issue 2/18 建议下 session 继续（interactive 验证 + 补齐调试板 UI + 埋更多点）。
- Issue 4 未启动，蓝图见 scorecard 里的"Issue 4 落地路径"。
