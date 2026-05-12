# DayPage 三端深度测试 — 汇总报告

**测试日期**：2026-05-12
**分支**：`docs/feature-inventory` @ `e7ec178`
**测试范围**：iOS DayPage (iPhone 17 Simulator) + V5 Codex Web (Next.js 16, localhost:3000) + DayPageWatch
**方法**：并行 3 个 agent，端到端构建 + 模拟器/Playwright 跑通 + 截图 + 源码审计
**截图总数**：47 张（iOS 23 + Web 24）
**问题总数**：**60 个**（P0×8 + P1×14 + P2×17 + P3×21）

---

## TL;DR — 全局最严重 8 个 P0

| # | 端 | 问题 | 一句话影响 |
|---|---|---|---|
| 1 | iOS | **i18n 整套 key 裸露**（`empty.today.no_signals.title` 等直接显示给用户） | 首屏即 unshippable |
| 2 | iOS | **Fresh launch 偶发整屏空白**（5/23 张截图只有状态栏，~74KB） | 用户开 app 看不到内容 → 卸载 |
| 3 | iOS | **Memo parser 时序崩坏** — 4 条 memo 被合并成 1 条，YAML front-matter 当正文渲染 | 用户看到自己的存档变成乱码 → 信任崩溃 |
| 4 | Web | **写入主链路全断** — Inngest 401 Event key not found，`/add` 卡 "Adding..." | memo → compile → page 完全跑不通，MVP 主路径归零 |
| 5 | Web | **侧边栏 "New domain" 死链**（`/settings/domains` 不存在） | 用户无法创建 domain |
| 6 | Web | **`/domain/[slug]` 全空 → 404** — 无 seed 数据 | 所有 domain 入口打不开 |
| 7 | Web | **移动端 375px 完全断裂** — sidebar 强制 248px，无 drawer，横向滚动 1348 | 移动端不可用 |
| 8 | Watch | **Watch 录音 → 死文件**：文件落到 iPhone 后没有 consumer，`VoiceAttachmentQueue.enqueue` 没被调用 | Whisper/Memo/Today 全断，Watch 功能用户视角 = 0 |

---

## 一、按端分类问题

### 📱 iOS DayPage（21 个问题，3 P0 / 5 P1 / 6 P2 / 7 P3）

构建状态：✅ BUILD SUCCEEDED（Xcode iPhoneSimulator26.4）
（注：`CLAUDE.md` 称 "no SPM dependencies" 但项目实际引入 swift-clocks / Sentry / Supabase 等 6 个 SPM 依赖 — 文档与实现不一致）

#### P0
- **P0-1 / Fresh launch 空白屏** — `04/05/07/13/18-*.png` 5 张整屏只有 iOS 状态栏，`RootView.swift:34-78` 用 3 个 fullScreenCover + 多个 `@State` 同步从 UserDefaults 初始化，cover stacking 有概率把 mainContent 卡在透明态
- **P0-2 / Memo parser 崩坏** — `06/08-*.png` 4 条 memo 被识别为 1 条，第 2-4 条 YAML header 直接当 Markdown 渲染；磁盘上 `2026-05-12.md` 包含 3 个 `<!-- daypage-memo-separator -->` 标记是正确的 → 写入 OK，但 `RawStorage.swift` parse 在 reload 与 write 之间存在竞态
- **P0-3 / i18n 整套 key 裸露** — `empty.today.no_signals.title/subtitle`、`empty.compile_locked.title/subtitle` 在 6 张截图中以原文 key 字符串显示；en/zh-Hans `.strings` 文件齐全 → 根因是 `.lproj` 没注册或没加入 Copy Bundle Resources

#### P1
- **P1-1 / Dark mode 100% 失效** — `03/15/16/17-*.png` 系统+app 都设 dark 仍渲染浅米色，`DSColor` 缺 dark token
- **P1-2 / 启动到首屏内容完整 ≈ 60s** — `15-today-dark.png` 11:38 只显示 loading spinner，1 分钟后 `16` 才完整
- **P1-3 / Onboarding 中英混排** — `12-onboarding-fresh.png` 标题 "DayPage" + 英文 slogan "Dump today, let AI compile tomorrow" + 中文按钮 "开始"
- **P1-4 / 顶部双重 chrome** — `09/10-*.png` 顶部出现系统 "◀ Settings" 返回链，与 app 自己的 header 并存
- **P1-5 / 时区/时间戳不一致** — vault 是 `2026-05-12T05:30:00Z`（北京 13:30）但卡片显示 `TODAY · 11:30`

#### P2 / P3
- 双 "Tuesday" 标题冗余、输入栏 "滑音盘" 翻译怪异、详情页 metadata 中英混排（PLACE 中文 / CREATED 英文）、"Open in Apple Maps" 仍英文、详情地图占 1/3 屏、Settings 齿轮对比度低、测试残留临时截图（state.png 与 10 二进制相同）、CLAUDE.md SPM 描述错误

### 🌐 V5 Codex Web（17+ 个问题，4 P0 / 4 P1 / 5 P2 / 5 P3）

启动状态：dev server PID 96325 仍在 :3000；DCL 1.3s / FCP 1.45s / networkidle 5.6s

#### P0
- **P0-1 / Inngest 401** — `/add` 提交触发 `Inngest API Error: 401 Event key not found`，按钮卡 "Adding..." 永不返回；建议在 dev bypass 模式短路 Inngest 或 README 强调要并行 `pnpm dev:inngest`
- **P0-2 / "New domain" 死链** — `<a href="/settings/domains">` 但 `web/src/app` 下无此路由
- **P0-3 / `/domain/[slug]` 全空** — dev bypass 无 seed，`(app)/domain/[slug]/page.tsx` 在 slug 不存在时 `notFound()`
- **P0-4 / 移动 375px 完全断裂** — `<aside>` 仍 248px `position:sticky`，`scrollWidth=1348`，所有 inbox/wiki/chat 二级面板被裁

#### P1
- **P1-1 / `/login` Hydration mismatch** — `<input type="email">` 服务端有 `style={{caret-color:"transparent"}}` 客户端没有（疑似浏览器扩展 inject，但生产 SEO 仍受影响）
- **P1-2 / `/home` networkidle 5.6s** — streaming 长连接拖累
- **P1-3 / 404 不一致** — 全局 404 无 app shell、(app) 404 有 app shell，都是裸 "404 This page could not be found"，无回家链接
- **P1-4 / `/_design-demo` 404** — 下划线开头被 App Router 视为私有路由

#### P2 / P3
- ⌘N 被浏览器吞、`<nav>` 语义缺失（只有 `<main>` + `<aside>`）、Ask 按钮行为未知、secondary action 对比度低、dev 无 seed、heading 等级断层（只有 1 个 H1）、Chat 三栏在桌面就拥挤、3 个 woff2 / 103KB 预加载、Sign out 紧贴 viewport 底

### ⌚ DayPageWatch（22 个问题，1 P0 / 5 P1 / 6 P2 / 8 P3 + 1 致命构建阻塞）

构建状态：❌ **本机没装 watchOS 26.4 SDK，xcodebuild 直接报 ineligible destination**，模拟器列表为空 → 跑不动端到端，已做完 460 行 6 文件代码审计

#### P0
- **P0-1 / Watch 录音 → 死文件** — `WatchReceiveService.swift:65-78` 文件落到 iPhone 端 `vault/raw/assets/watch_*.m4a` OK，但 `lastReceivedFile @Published` **没有任何观察者**，**没调用 `VoiceAttachmentQueue.enqueue`** → Whisper 转录、Memo 创建、Today 显示全断

#### P1
- **P1-1 / Watch scheme 没共享** — 只有 `DayPage.xcscheme` 是 shared，`DayPageWatch` 和 `DayPageWatch (Notification)` 都在 user-only `xcuserdata/`，CI / `verify-daypage` / fresh clone 都跑不到
- **P1-2 / Complication 完全没生效** — `ComplicationProvider.swift` 同时定义 WidgetKit `TimelineProvider`（但没 `@main Widget` + widget extension target）和已 deprecated 的 ClockKit `CLKComplicationTemplate`（没 `CLKComplicationDataSource`），两条线都没注册到 watchOS
- **P1-3 / `StartRecordingIntent` 没注册** — 没 `AppShortcutsProvider`，Action Button / Siri / Spotlight 都看不到
- **P1-4 / `WKExtendedRuntimeSession` 用法错误** — 没设 delegate、没传 session type、`Task.sleep(30_000_000_000)` 硬编码 30s 无法取消、`try?` 吃错误
- **P1-5 / AppIcon 缺失** — `Assets.xcassets/` 是空的，build setting 期待 `AppIcon.appiconset` 但不存在，装机后是占位图

#### P2 / P3
- WCSession 冷启动竞态、`#if os(iOS)` 死代码（说明是 iOS 复制过来没清理）、录音文件命名只精确到秒、tmp 孤儿文件不清理、状态机不闭环（`.done` 后用户必须杀 app 才能重录）、缺触觉反馈 / Digital Crown / Always-On 优化 / accessibilityLabel、用 `print` 而非 `os.Logger`、麦克风被拒后无引导跳转设置

---

## 二、按维度分类（跨端通病）

### 🎨 视觉 / 样式
- **iOS**：dark mode 失效、双 Tuesday 标题、详情地图占屏过大
- **Web**：移动断裂、secondary action 对比度低、breadcrumb 拥挤
- **Watch**：AppIcon 缺失、缺 Always-On 优化

### 🖱️ 交互
- **iOS**：fresh launch 空白屏（cover stacking）、首帧 loading 不完整、双 chrome、"正在编辑 4 条 memo" pill 语义不清
- **Web**：Cmd+N 被浏览器吞、Ask 按钮行为未知、`/add` 卡死
- **Watch**：状态机不闭环、缺触觉反馈

### 🌐 国际化 / 语言（iOS 极严重，Web 未深测）
- **iOS P0-3**：i18n bundle 注册失败 → key 字符串裸露
- **iOS P1-3**：Onboarding 中英混排
- **iOS P2-4/P2-5**：详情页 metadata 中英混排，"Open in Apple Maps" 不本地化

### 🔌 功能链路
- **iOS P0-2**：Memo parser 崩坏 → 存档显示乱码
- **Web P0-1**：Inngest 401 → 写入链路全断
- **Watch P0-1**：录音 → enqueue 没调用 → 整条管线断
- 三端的"写入"链路在不同地方都有断点 — **MVP 主路径在三端都不能完整跑通**

### ⚡ 性能
- **iOS**：启动到完整 ≈ 60s、~74KB 空白截图说明渲染管线偶发 stall
- **Web**：networkidle 5.6s、dev 模式 JS 755KB（非生产指标）
- **Watch**：30s 硬编码 sleep、每秒 SwiftUI animation 在 Always-On 耗电

### ♿ 可访问性
- **iOS**：`accessibilityLabel("Open navigation")` 有 ✅；但 i18n 失败时 VoiceOver 读 raw key 是灾难
- **Web**：缺 `<nav>` 语义、1 个 input 无 label、heading 等级断层、login hydration mismatch
- **Watch**：所有按钮 SF Symbol 无 accessibilityLabel，VoiceOver 读 "stop circle fill"

### 📐 移动 / 响应式
- **Web P0-4**：375px 完全未做响应式 — 最严重
- **iOS**：以 iPhone 17 为基线，无横屏测试

### 🌗 深浅色模式
- **iOS P1-1**：dark 完全失效（DSColor 缺 dark variant）
- **Web**：未测（不确定是否有 dark mode）

### 🏗️ 工程 / CI
- **Watch P1-1**：scheme 没共享，CI 跑不到
- **CLAUDE.md** 声明 "no SPM dependencies" 与实际 6 个 SPM 依赖矛盾，需更新

### 🔐 安全
- ✅ 三端均无 hardcoded secrets
- ✅ WatchReceiveService 已防 path traversal
- ✅ Web 未鉴权 `/api/*` 正确返回 401

---

## 三、Dogfood 前必须修复（按"修复一项解多个问题"排序）

### 阶段 1 — 让主链路能跑通（必须）
1. **iOS P0-3** 修 i18n bundle 注册（验 `knownRegions`、Copy Bundle Resources、写 unit test 枚举所有 `LocalizedStringKey`）
2. **iOS P0-2** 修 Memo parser（加 4-memo + 3-separator fixture 的 unit test，排查 reload/write 竞态）
3. **iOS P0-1** 修 fresh launch 空白屏（cover binding 改单一 enum-driven state，log 三个 State 取值）
4. **Web P0-1** 修 Inngest event key（`.env.local` 加 `INNGEST_EVENT_KEY` 或 dev bypass 短路改 mock）
5. **Watch P0-1** `WatchReceiveService` 收到文件后调 `VoiceAttachmentQueue.shared.enqueue(audioPath:, memoDate:)`

### 阶段 2 — 让"宣传"特性真能用
6. **Web P0-4** Mobile responsive（`<aside>` 改 `hidden lg:flex` + Sheet drawer）
7. **Web P0-2/P0-3** 补 `/settings/domains` + dev bypass seed 一组样例 domain
8. **iOS P1-1** 恢复 dark mode（`DSColor` 补 dark token）
9. **Watch P1-2/P1-3/P1-4/P1-5** 删空壳 ComplicationProvider 或正确实现 + 补 AppShortcutsProvider + 修 WKExtendedRuntimeSession + 补 AppIcon

### 阶段 3 — 工程基线
10. **Watch P1-1** 共享 Watch scheme，commit `.xcscheme`
11. **iOS** 写 UI 截图 baseline + diff（Today/Archive/Graph × light/dark × empty/with-memos × en/zh = 24 张）
12. **Web** 写 `app/not-found.tsx` + `(app)/not-found.tsx` 品牌化 404

### 阶段 4 — Polish
13. 一致的 timestamp / 时区
14. Watch 状态机闭环（`.done` 2s 回 `.idle`）
15. Web 快捷键徽章与实际对齐（⌘N → ⌥N）
16. Web `<nav>` 语义、label、heading 等级
17. CLAUDE.md 文档同步

---

## 四、报告与证据文件路径

| 端 | 详细报告 | 截图 | 备注 |
|---|---|---|---|
| iOS | `/tmp/daypage-ios-test-report.md` | `/tmp/daypage-ios-screenshots/` (23 张) | Simulator UDID `0E035415-...`，已验证 vault sandbox |
| Web | `/tmp/daypage-web-test-report.md` | `/tmp/daypage-web-screenshots/` (24 张) | Dev server PID 96325 仍在 :3000，Playwright 原始数据 `/tmp/daypage-web-qa-findings.json` |
| Watch | `/tmp/daypage-watch-test-report.md` | (无 — SDK 未安装) | 代码审计 460 行 6 文件 |

---

## 五、未覆盖项（如要继续）

- **iOS**：横屏布局、动态字体、VoiceOver 完整路径、AI 编译完整 loop（DashScope key 状态未知）、`BGTaskScheduler` 凌晨 2 点定时验证
- **Web**：Wiki 详情页 / Chat 对话流 / 拖拽上传 / Voice 录音 / Bookmarklet、`pnpm build && pnpm start` 后跑 Lighthouse、真实 Apple OAuth、Dark mode（如有）
- **Watch**：所有 — 需先 `Xcode → Settings → Components` 安装 watchOS 26.4 SDK，然后用 `verify-daypage` skill 跑端到端
