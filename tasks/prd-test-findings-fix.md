# PRD: DayPage 三端测试发现修复

**版本**：1.0
**作者**：Claude (基于 2026-05-12 三端深度测试)
**对应测试报告**：
- `/tmp/daypage-final-test-report.md`（汇总）
- `/tmp/daypage-ios-test-report.md`（23 张截图）
- `/tmp/daypage-web-test-report.md`(24 张截图）
- `/tmp/daypage-watch-test-report.md`（460 行 6 文件审计）

---

## 1. Introduction / Overview

2026-05-12 的三端深度测试（iOS + V5 Codex Web + DayPageWatch）共发现 **60 个问题**（P0×8 / P1×14 / P2×17 / P3×21）。其中 **8 个 P0 直接阻塞 dogfood**：iOS i18n key 裸露、fresh launch 空白屏、Memo parser 崩坏、Web 写入链路 Inngest 401、移动端布局断裂、`/domain` 路由全 404、Watch 录音 → 死文件。

本 PRD 把全部 60 个问题转成可验收的 User Story，按优先级分阶段交付，确保 dogfood 前主链路在三端都能跑通。

---

## 2. Goals

- **G1 [阻塞]** 三端写入主链路（memo → 持久化 → 显示）全部跑通，0 个 P0 问题残留
- **G2 [严重]** 消除 i18n 失效、dark mode 失效、移动端布局断裂三大用户感知最强问题
- **G3 [工程]** Watch 端构建可在 CI 跑通，三端均有 UI 截图 baseline diff
- **G4 [可访问性]** 三端均符合 WCAG AA 基线（语义化、对比度、VoiceOver 不读 raw key）
- **G5 [文档]** CLAUDE.md 与实际工程一致（SPM 依赖、scheme 列表）

---

## 3. User Stories

> 60 个 User Story，按端 + 优先级排列。每个 Story 包含：标题 / 描述 / 验收准则 / 简短技术建议。
> 所有涉及 UI 的 Story 均要求"在模拟器 / 浏览器中视觉验证"。

---

### 📱 iOS — P0（3 个）

#### US-001: [iOS P0-1] 修复 fresh launch 偶发整屏空白
**Description:** As a 新用户, I want app 第一次启动稳定显示首屏内容, so that 不会因看到纯黑/纯白屏而卸载。

**Acceptance Criteria:**
- [ ] 连续 20 次 fresh launch（每次先 `xcrun simctl uninstall && install`）均显示完整 Today 视图
- [ ] 同一 simulator 上清数据 / deeplink 后回 Today，5 次内 0 次空白
- [ ] Today 视图首帧截图体积稳定在 >800KB（非 74KB 空白截图）
- [ ] `RootView.swift` 内 cover binding 改为单一 enum-driven state（替换三个独立 `@State` bool）
- [ ] Build 通过 + 在 iPhone 17 模拟器视觉验证

**Technical:** `RootView.swift:34-78` 把 `hasOnboarded` / `showAuthSheet` / `hasSeenWelcome` 三个 `@State` 合并为 `enum AppPhase { onboarding, auth, ready }`，避免三层 `fullScreenCover` 互相竞态。

---

#### US-002: [iOS P0-2] 修复 Memo parser 在多 memo 文件下的崩坏
**Description:** As a 用户, I want 多条 memo 正确拆分显示, so that 我的存档不会显示成 YAML 乱码。

**Acceptance Criteria:**
- [ ] 加 unit test：4-memo + 3-separator fixture，断言 `RawStorage.parse(fileContent:)` 返回 4 条 Memo
- [ ] 加 unit test：写入 → 立刻读取的并发场景（模拟 ViewModel reload 时的 race），断言 count 一致
- [ ] 在 simulator 跑 4-memo 真实场景，Today 视图显示 4 张 memo 卡片（非合并成 1 张）
- [ ] YAML front-matter 字段（id/type/created/device/attachments）永不出现在 Markdown 正文渲染
- [ ] Build + 视觉验证

**Technical:** `DayPage/Storage/RawStorage.swift:115-131` `splitAndParse` 在文件包含 `<!-- daypage-memo-separator -->` 时强制走多 memo 分支；排查 reload 与 write 之间的 file watcher 是否抢先触发读了写到一半的文件。

---

#### US-003: [iOS P0-3] 修复 i18n bundle 注册导致所有 key 裸露
**Description:** As a 用户, I want 看到本地化文案而非 `empty.today.no_signals.title` 这样的代码 key, so that app 不像未完工的 debug 版本。

**Acceptance Criteria:**
- [ ] `project.pbxproj` `knownRegions` 包含 `["en", "zh-Hans", "Base"]`
- [ ] `en.lproj/Localizable.strings` 和 `zh-Hans.lproj/Localizable.strings` 均在 Copy Bundle Resources phase
- [ ] `xcrun simctl get_app_container booted com.daypage.DayPage app` 进 `.app` 能看到两个 `.lproj` 目录
- [ ] 空状态屏（0 memo / compile_locked）显示正确本地化文案，无任何 `*.title` / `*.subtitle` key 暴露
- [ ] 加 unit test：枚举所有 `LocalizedStringKey`，缺 key 时 test fail
- [ ] zh-Hans 和 en 两种系统语言下视觉验证

**Technical:** 优先用 SwiftGen 等编译期生成的强类型 key 替代字符串，永久消除"key 暴露"类问题。

---

### 📱 iOS — P1（5 个）

#### US-004: [iOS P1-1] 恢复深色模式
**Description:** As a 暗色偏好用户, I want app 跟随系统/设置在 dark 模式下渲染暗色, so that 视觉一致、夜间不刺眼。

**Acceptance Criteria:**
- [ ] 系统 dark + app `themeMode = .auto` → 渲染暗色
- [ ] 系统 light + app `themeMode = .dark` → 渲染暗色
- [ ] `DSColor.inkPrimary` / `glassStd` / `glassRim` / `ambient*` 全部提供 dark variant
- [ ] Today / Archive / Memo 详情 / Onboarding 四个主屏 light/dark 截图对比无渲染错误
- [ ] 视觉验证

**Technical:** `DayPage/App/DSColor.swift` 用 `Color(light:dark:)` 初始化或 Asset Catalog 的 `.colorset` 双色配置。

---

#### US-005: [iOS P1-2] 修复启动到内容完整 60s 慢加载
**Description:** As a 用户, I want app 启动后 3 秒内看到完整 Today 内容, so that 不会以为 app 卡死或无数据。

**Acceptance Criteria:**
- [ ] 冷启动到 Today 完整内容（header + memo 列表 + Today's Page Compiled 卡片）≤ 3s（P95）
- [ ] 三个并行加载源（vault、AI 编译卡片、On This Day）合并为一个统一 loading state，而非分次渲染
- [ ] Loading state 显示 skeleton（非孤立 spinner）
- [ ] 在 iPhone 17 模拟器测 5 次，所有用时 ≤ 3s

**Technical:** `TodayViewModel` 把三个 `@Published` 加载状态聚合到一个 `enum LoadState { loading, partial, ready }`，UI 在 `ready` 前显示骨架。

---

#### US-006: [iOS P1-3] Onboarding 文案中英不混排
**Description:** As a 用户, I want Onboarding 全中文或全英文（按系统语言）, so that 不会看到 "Dump today, let AI compile tomorrow" 配 "开始" 按钮的混排。

**Acceptance Criteria:**
- [ ] zh-Hans 系统下 Onboarding 所有文案为中文
- [ ] en 系统下 Onboarding 所有文案为英文
- [ ] Slogan / 按钮 / 标题三类元素均走 i18n
- [ ] 视觉验证

**Technical:** 排查 Onboarding 视图里硬编码的英文字符串字面量，改成 `Text(LocalizedStringKey(...))`。

---

#### US-007: [iOS P1-4] 移除顶部双 chrome（系统返回链 + app header）
**Description:** As a 用户, I want 看到唯一一套顶部 header, so that 不会被两个返回按钮搞混。

**Acceptance Criteria:**
- [ ] Today 视图顶部不再出现 "◀ Settings" 系统返回链
- [ ] deeplink 进入详情后返回 Today，顶部仅 app 自己的 header
- [ ] 视觉验证：`09-today-newsep.png` / `10-after-deeplink.png` 同场景重测无残留

**Technical:** 排查 `NavigationStack` / `NavigationView` 是否嵌套，或 `.navigationBarHidden(true)` 是否覆盖完整路径。

---

#### US-008: [iOS P1-5] 统一 timestamp 时区处理
**Description:** As a 用户, I want memo 卡片和详情显示的时间都基于我的本地时区, so that 不会出现 UTC 13:30 显示为 11:30 的错乱。

**Acceptance Criteria:**
- [ ] vault 中 `created` 字段保留 ISO 8601 UTC
- [ ] UI 渲染时统一通过 `DateFormatter.shortTime`（用户当前 locale）转换
- [ ] 同一 memo 在卡片右上角与详情底部显示时间一致
- [ ] 跨时区测试：模拟器切到 New York / Tokyo / Beijing 三个时区，验证显示

**Technical:** 抽 `DayPageDateFormatter` 单例，所有 timestamp 渲染必须经过它。

---

### 📱 iOS — P2（6 个）

#### US-009: [iOS P2-1] 消除双 "Tuesday" 标题冗余
**Description:** As a 用户, I want Today 视图顶部只有一个日期标题, so that 不会因 serif "Tuesday" + 大字 "Tuesday" 视觉重复。

**Acceptance Criteria:**
- [ ] 顶部 chrome 与 hero 标题不再同时出现 "Tuesday"
- [ ] 二选一保留：保留 hero 大字 + 顶部改为时间或品牌
- [ ] 视觉验证

**Technical:** `TodayView.swift` 删除一处冗余 `Text`。

---

#### US-010: [iOS P2-2] 修正输入栏底部 copy 翻译
**Description:** As a 中文用户, I want 看到"轻触切换键盘 · 长按发送语音"等通顺中文, so that 不会读到 "滑音盘" 这种怪翻译。

**Acceptance Criteria:**
- [ ] 输入栏底部提示 zh-Hans 文案重审，无生硬直译
- [ ] en 版本平行重审
- [ ] 视觉验证

**Technical:** 检查 `Localizable.strings` 中输入栏相关 key 的翻译。

---

#### US-011: [iOS P2-3] Header subline 时间制信息明确
**Description:** As a 用户, I want 时间显示明确为 24h 或 12h+AM/PM, so that 不会看到 "MAY 12 · 11:05" 这种含糊格式。

**Acceptance Criteria:**
- [ ] 按系统区域设置自动选择 12h / 24h
- [ ] 视觉验证：US-en 显示 "11:05 AM"，zh-CN 显示 "11:05"（24h）

**Technical:** `DateFormatter.timeStyle = .short` + 用户 locale。

---

#### US-012: [iOS P2-4] Memo 详情页 metadata 字段统一语言
**Description:** As a 用户, I want 详情页 CREATED / KIND / PLACE / WEATHER 四个字段标签语言一致, so that 不会出现一半英文一半中文。

**Acceptance Criteria:**
- [ ] zh-Hans 下四个 label 均为中文（创建于 / 类型 / 位置 / 天气）
- [ ] en 下四个 label 均为英文
- [ ] 视觉验证

---

#### US-013: [iOS P2-5] "Open in Apple Maps" 本地化
**Description:** As a 中文用户, I want 详情页按钮显示"在 Apple 地图打开", so that 不再裸露英文。

**Acceptance Criteria:**
- [ ] zh-Hans 下按钮显示中文
- [ ] en 下保持英文
- [ ] 视觉验证

---

#### US-014: [iOS P2-6] "正在编辑 4 条 memo" pill 语义重做
**Description:** As a 用户, I want 看到清晰的状态说明（如"今日 4 条 NOTE"或"3 条待编译"）, so that 不会以为所有 memo 都在编辑模式。

**Acceptance Criteria:**
- [ ] 底部 pill 文案改为状态摘要而非"编辑中"
- [ ] 视觉验证

**Technical:** 排查 pill 的 binding，确认是否真的在编辑模式触发，重命名 + 重写文案。

---

### 📱 iOS — P3（7 个）

#### US-015: [iOS P3-1] 0-memo 空状态视觉重做
**Description:** As a 新用户, I want 空状态显示友好引导而非 "0 SIGNALS" 大字, so that 不会感到冷淡。

**Acceptance Criteria:**
- [ ] 0 memo 时 hero orb 替换为 empty illustration + CTA
- [ ] 视觉验证

---

#### US-016: [iOS P3-2] 清理测试截图重复采集
**Description:** As a 工程团队, I want 自动化测试不产生重复二进制截图, so that 节约存储和审阅时间。

**Acceptance Criteria:**
- [ ] `verify-daypage` skill 或测试脚本在采集前对比上一帧 hash，相同则不写盘
- [ ] 单次跑结束 `find /tmp/daypage-ios-screenshots -size +0c | md5 | sort -u | wc -l` ≈ 文件数

---

#### US-017: [iOS P3-3] 详情页地图默认折叠
**Description:** As a 用户, I want 地图默认占详情页 ≤ 1/4 高度, so that 文字内容优先可见。

**Acceptance Criteria:**
- [ ] 详情页默认地图高度 ≤ 25% 屏幕
- [ ] 点击地图区域展开到 1/2 或全屏
- [ ] 视觉验证

---

#### US-018: [iOS P3-4] 删除 state.png 等测试残留
**Description:** As a 工程团队, I want `verify-daypage` 不留 `state.png` 之类无意义临时文件, so that 截图目录干净。

**Acceptance Criteria:**
- [ ] 测试脚本最后 `rm /tmp/daypage-ios-screenshots/state.png`
- [ ] 或重命名为带序号的稳定名

---

#### US-019: [iOS P3-5] 输入条按钮 hover/pressed 反馈
**Description:** As a 用户, I want 触摸 +/🎙/Aa 时看到按下态, so that 知道点击生效。

**Acceptance Criteria:**
- [ ] 三个按钮均有 pressed scale / opacity 反馈
- [ ] 视觉验证

**Technical:** SwiftUI `.buttonStyle(PressableButtonStyle())` 自定义按下态。

---

#### US-020: [iOS P3-6] Settings 齿轮提高对比度
**Description:** As a 用户, I want 在浅色背景下也能看清 Settings 入口, so that 不会找不到设置。

**Acceptance Criteria:**
- [ ] Settings 齿轮在浅米色背景下对比度 ≥ 3:1（icon 标准）
- [ ] 视觉验证

**Technical:** 加深 stroke 颜色或加阴影 / circular tint。

---

#### US-021: [iOS P3-7] 更新 CLAUDE.md SPM 依赖描述
**Description:** As a 新加入的开发者, I want CLAUDE.md 准确描述项目依赖, so that 不会被"no SPM dependencies"误导。

**Acceptance Criteria:**
- [ ] CLAUDE.md "Tech Stack" 表移除 "no SPM dependencies" 表述
- [ ] 列出当前 SPM 依赖：swift-clocks, swift-concurrency-extras, swift-http-types, xctest-dynamic-overlay, Sentry, Supabase
- [ ] PR 通过 Review

---

### 🌐 Web — P0（4 个）

#### US-022: [Web P0-1] 修复 `/add` 写入因 Inngest 401 卡死
**Description:** As a 用户, I want 提交 memo 后看到成功状态并出现在 inbox, so that 写入链路完整可用。

**Acceptance Criteria:**
- [ ] `.env.local` 模板加 `INNGEST_EVENT_KEY=<dev-key>` 并在 `.env.example` 注释来源
- [ ] `web/README.md` 加章节"启动 dev 必须并行跑 `pnpm dev:inngest`"
- [ ] 或：dev bypass 模式短路 Inngest，改本地同步 mock compile（≤ 5s 完成）
- [ ] 跑通：`/add` 输入 "test" → 点击 Add → 按钮回到默认态 → `/inbox` 出现该 memo
- [ ] 控制台 0 个 `Inngest API Error: 401`
- [ ] Playwright E2E 测试用例覆盖该流程
- [ ] 浏览器视觉验证

**Technical:** `web/src/lib/inngest-client.ts`（或类似）加 `if (!env.INNGEST_EVENT_KEY && env.DEV_AUTH_BYPASS) { return mockInngest; }`。

---

#### US-023: [Web P0-2] 修复侧边栏 "+ New domain" 死链
**Description:** As a 用户, I want 点击 "+ New domain" 能创建新 domain, so that 产品故事"domain → 实体页"有入口。

**Acceptance Criteria:**
- [ ] 二选一：(a) 新建 `web/src/app/(app)/settings/domains/page.tsx` 含创建表单；(b) 把 `<a>` 改成 `<button>` 触发 inline modal
- [ ] 点击 "+ New domain" 后能输入 domain 名并提交
- [ ] 创建后 sidebar 立刻刷新显示新 domain
- [ ] 浏览器视觉验证

**Technical:** 推荐 (b)，避免新增半成品路由。

---

#### US-024: [Web P0-3] 修复 `/domain/[slug]` 空态裸 404
**Description:** As a 用户, I want 访问不存在的 domain slug 时看到引导而非裸 404, so that dev bypass 演示链路连贯。

**Acceptance Criteria:**
- [ ] dev bypass 登录时 seed 至少 3 个示例 domain（含 entity 数据）
- [ ] `(app)/domain/[slug]/page.tsx` slug 不存在时显示"domain 不存在 + 跳到创建页"而非 `notFound()`
- [ ] 浏览器视觉验证：`/domain/anything` 都能落到合理页面

**Technical:** seed 脚本放 `web/scripts/seed-dev.ts`，dev bypass 登录中间件触发一次。

---

#### US-025: [Web P0-4] 修复移动端 375px 布局完全断裂
**Description:** As a 移动端用户, I want 在 iPhone 标准宽度浏览所有页面, so that 不需要横向滚动。

**Acceptance Criteria:**
- [ ] 375px 视口下 `document.scrollWidth === document.clientWidth`（无水平滚动）
- [ ] `<aside>` 在 `< lg` 断点 `hidden`，通过 hamburger 触发 `Sheet` drawer overlay
- [ ] 主内容 `< lg` 时 100vw
- [ ] Inbox / Wiki / Chat 二级面板 mobile 改为单栏 + tab 切换
- [ ] Playwright 在 375 / 768 / 1024 / 1440 四档跑通主路径
- [ ] 浏览器视觉验证

**Technical:** `(app)/layout.tsx` 加 Tailwind `hidden lg:flex`；引入 shadcn `Sheet` 组件做 drawer。

---

### 🌐 Web — P1（4 个）

#### US-026: [Web P1-1] 消除 `/login` Hydration mismatch
**Description:** As a 开发者, I want 控制台无 hydration warning, so that 生产构建不被 SEO 抓取感知到差异。

**Acceptance Criteria:**
- [ ] `/login` 加载后控制台 0 个 hydration error
- [ ] 定位 `caret-color: transparent` 来源（浏览器扩展 vs 组件自身）
- [ ] 若浏览器扩展所致：input 加 `suppressHydrationWarning`
- [ ] Playwright headless（无扩展）跑 `/login` 仍无 warning

**Technical:** 检查 `app/login/page.tsx` 是否有 `useEffect` 改 input style；若无，加 prop。

---

#### US-027: [Web P1-2] `/home` networkidle ≤ 2s
**Description:** As a 用户, I want `/home` 在 2s 内可交互, so that 4G/3G 下不焦虑。

**Acceptance Criteria:**
- [ ] DCL ≤ 1.5s、FCP ≤ 1.8s、networkidle ≤ 2s（P95，Fast 3G throttle）
- [ ] streaming 端点空数据时尽快关闭连接（不挂活 ≥ 1s）
- [ ] Playwright 跑 5 次取 P95 验证

**Technical:** 把 streaming 改用 `EventSource` + auto-close after empty events。

---

#### US-028: [Web P1-3] 统一 404 页（品牌化 + 回家链接）
**Description:** As a 用户, I want 误入不存在的页面时看到品牌化 404, so that 知道如何回到主路径。

**Acceptance Criteria:**
- [ ] `app/not-found.tsx`（全局）+ `(app)/not-found.tsx`（app shell 内）两份
- [ ] 均含品牌 logo + "回到 Home" 按钮 + "搜索" 入口
- [ ] `/this-route-does-not-exist` 与 `/settings/domains`（修复前）落到对应 404
- [ ] 浏览器视觉验证

---

#### US-029: [Web P1-4] 处理 `/_design-demo` 私有路由 404
**Description:** As a 团队成员, I want 访问内部设计 demo, so that 能验证设计 token。

**Acceptance Criteria:**
- [ ] 二选一：(a) 重命名 `_design-demo` → `design-demo`（公开）；(b) 移到 `(internal)/design-demo` 并加 admin guard
- [ ] 推荐 (a)，因为目前是内部 demo 无敏感数据
- [ ] 浏览器视觉验证：`/design-demo` 200

**Technical:** Next 16 App Router 把 `_` 开头视为私有，重命名即可。

---

### 🌐 Web — P2（5 个）

#### US-030: [Web P2-1] 修复或移除 `⌘N` 快捷键
**Description:** As a 用户, I want 看到的快捷键徽章真的能用, so that 不会按了无反应。

**Acceptance Criteria:**
- [ ] `⌘N` 改为 `⌥N` 或 `g a`（不与浏览器冲突）
- [ ] `⌘W` / `⌘K` / `⌘1` 同样核验
- [ ] 按对应组合后 URL 切到 `/add` / 等预期目标
- [ ] 浏览器视觉验证

**Technical:** 用 `kbd` 库或自写 hook 监听非冲突组合。

---

#### US-031: [Web P2-2] 补 `<nav>` 主导航语义
**Description:** As a 屏幕阅读器用户, I want 找到 navigation landmark, so that 能跳转主菜单。

**Acceptance Criteria:**
- [ ] `<aside>` 内 sidebar 部分包 `<nav aria-label="Main navigation">`
- [ ] Lighthouse a11y 分 ≥ 95
- [ ] axe-core 测试无 critical 项

---

#### US-032: [Web P2-3] 核验顶栏 "Ask" 按钮行为
**Description:** As a 用户, I want 点 "Ask" 触发明确的功能（chat overlay 或跳 /chat）, so that 不是装饰按钮。

**Acceptance Criteria:**
- [ ] 点击 "Ask" 触发 chat overlay 或路由跳转
- [ ] 浏览器视觉验证

---

#### US-033: [Web P2-4] Secondary action 对比度达 WCAG AA
**Description:** As a 视觉敏感用户, I want "OPEN IN INBOX / KEEP THINKING" 等次级按钮可读, so that 不会因米色字+米色底看不清。

**Acceptance Criteria:**
- [ ] 文本对比度 ≥ 4.5:1（normal）或 ≥ 3:1（large bold）
- [ ] Stark / axe-core 验证
- [ ] 浏览器视觉验证

**Technical:** 加 outline border 或加深文字颜色到 `#5a4a3a` 级别。

---

#### US-034: [Web P2-5] dev bypass 登录 seed 一组示例数据
**Description:** As a 演示者, I want dev bypass 登录后 inbox / chat / wiki / domain 都有示例内容, so that 不是 5 个空态拼起来的"演示"。

**Acceptance Criteria:**
- [ ] dev bypass 登录中间件自动 seed：10 个 memo / 3 个 domain / 2 个 chat 对话 / 5 个 wiki entity
- [ ] 仅在 `NODE_ENV !== 'production'` 生效
- [ ] 浏览器视觉验证：跑过一遍主路径全部有内容

**Technical:** 与 US-024 共用 seed 脚本。

---

### 🌐 Web — P3（5 个）

#### US-035: [Web P3-1] 补 input `aria-label`
**Description:** As a 屏幕阅读器用户, I want 所有 input 有 label, so that 知道在填什么。

**Acceptance Criteria:**
- [ ] `/home` 所有 input 有 `<label>` 或 `aria-label`
- [ ] axe-core 0 个 "input missing label" 警告

---

#### US-036: [Web P3-2] 修复 heading 等级断层
**Description:** As a 屏幕阅读器/SEO 用户, I want 看到合理 H1→H2→H3 层级, so that 文档结构清晰。

**Acceptance Criteria:**
- [ ] 每页只有 1 个 H1
- [ ] "WHAT THE SYSTEM NOTICED" / "RECENT ACTIVITY" / "DOMAINS AT A GLANCE" 改为 H2
- [ ] 卡片内子标题 H3
- [ ] axe-core 通过

---

#### US-037: [Web P3-3] Chat 桌面布局右栏更宽
**Description:** As a 用户, I want chat 右侧介绍区可读, so that 不会因 280px 强制断行难看。

**Acceptance Criteria:**
- [ ] 右侧介绍区 ≥ 400px，或在窄屏隐藏
- [ ] 浏览器视觉验证（1440×900）

---

#### US-038: [Web P3-4] 字体 subset 优化
**Description:** As a 移动用户, I want 字体加载更轻, so that 首屏更快。

**Acceptance Criteria:**
- [ ] 3 个 woff2 通过 subset 工具裁剪到仅含使用字符
- [ ] 总字体大小 ≤ 60KB（当前 103KB）
- [ ] Lighthouse 性能分 ≥ 90

**Technical:** `next/font/local` + `glyphs:` 或 `fonttools subset`。

---

#### US-039: [Web P3-5] Sidebar `Sign out` 加底部 padding
**Description:** As a 用户, I want `Sign out` 离 viewport 底部有间距, so that 不像被裁掉。

**Acceptance Criteria:**
- [ ] `Sign out` 与 viewport 底间距 ≥ 16px
- [ ] 浏览器视觉验证

---

### ⌚ Watch — P0（1 个）

#### US-040: [Watch P0-1] 修复 Watch 录音 → 死文件链路断裂
**Description:** As a 用户, I want 在 Watch 上录的语音出现在 iPhone Today 视图, so that Watch 录音功能真正可用。

**Acceptance Criteria:**
- [ ] `DayPage/Services/WatchReceiveService.swift:65-78` 文件移动成功后调用 `VoiceAttachmentQueue.shared.enqueue(audioPath: destURL.path, memoDate: Date())`
- [ ] 端到端测试：Watch 录 5s 语音 → iPhone 端 `vault/raw/<today>.md` 出现新 memo（type: voice）+ Whisper 转录 + Today 视图显示
- [ ] 即便 iPhone app 在后台，Watch 传输完成后通知出现并可点开
- [ ] 在 watchOS 26.x SDK 装好后实机/模拟器验证

**Technical:** 当前 `lastReceivedFile @Published` 无观察者；需要主动 push 到 queue。

---

### ⌚ Watch — P1（5 个）

#### US-041: [Watch P1-1] 共享 Watch scheme
**Description:** As a CI / 新开发者, I want clone 后能直接 build watch app, so that CI 跑得到。

**Acceptance Criteria:**
- [ ] `DayPageWatch.xcscheme` 和 `DayPageWatch (Notification).xcscheme` commit 到 `DayPage.xcodeproj/xcshareddata/xcschemes/`
- [ ] `xcodebuild -list` 在 fresh clone 后能看到这两个 scheme
- [ ] `verify-daypage` skill 可触发 Watch build

---

#### US-042: [Watch P1-2] Complication 真正生效或彻底删除
**Description:** As a 用户, I want 表盘 complication 真的能出现, 或没有这个文件让我误以为有。

**Acceptance Criteria:**
- [ ] 二选一：(a) 用 WidgetKit 重写 + 独立 widget extension target + `@main WidgetBundle`；(b) 删除 `ComplicationProvider.swift`
- [ ] 推荐 (b)，因为 ClockKit 已 deprecated 且当前两条线都没注册成功
- [ ] 如选 (a)：在 watchOS 26.x 模拟器表盘上能添加并显示 complication

---

#### US-043: [Watch P1-3] `StartRecordingIntent` 注册到 AppShortcuts
**Description:** As a 用户, I want Action Button / Siri 能触发 Watch 录音, so that 不用解锁屏幕。

**Acceptance Criteria:**
- [ ] 新增 `struct DayPageWatchShortcuts: AppShortcutsProvider` 并列出 `StartRecordingIntent`
- [ ] watchOS 设置 Action Button → DayPage → Start Recording 能看到
- [ ] 按 Action Button 触发录音

---

#### US-044: [Watch P1-4] `WKExtendedRuntimeSession` 正确使用
**Description:** As a 用户, I want Watch 录音不会无故 30s 后强停, so that 能完整录下我想说的话。

**Acceptance Criteria:**
- [ ] `WKExtendedRuntimeSession` 在 init 时传正确 reason（如 `.automatic` for audio recording）
- [ ] 设置 `delegate` 接收 `extendedRuntimeSession(_:didInvalidateWith:error:)`
- [ ] 录音上限改为可配置（默认 60s，UI 可见倒计时），用户可手动停止
- [ ] 错误路径不被 `try?` 吃掉，至少 log 到 `os.Logger`

---

#### US-045: [Watch P1-5] 补 Watch AppIcon
**Description:** As a 用户, I want Watch app 在 Home Screen 显示真实 logo, so that 不是占位灰图。

**Acceptance Criteria:**
- [ ] `DayPageWatch/Resources/Assets.xcassets/AppIcon.appiconset/` 含所有 watchOS 必需尺寸（24/27.5/29/33/40/44/50/51/86/98/108 等）
- [ ] `Contents.json` 合法
- [ ] actool 无 warning
- [ ] 模拟器/真机 Home Screen 显示真实 logo

---

### ⌚ Watch — P2（6 个）

#### US-046: [Watch P2-1] 修复 WCSession 冷启动竞态
**Description:** As a 用户, I want app 冷启动后立刻按录音键也能成功传输, so that 不需要"再试一次"。

**Acceptance Criteria:**
- [ ] `WatchTransferService.transferAudioFile` 改 `async`，内部 await session activation
- [ ] 测试：冷启动 0.5s 后立即触发录音并停止，传输不失败
- [ ] failed 路径不删除源文件（保留以便 retry）

---

#### US-047: [Watch P2-2] 录音 Timer 健壮性
**Description:** As a 用户, I want timer 在 `.failed` 状态也正确停止, so that 不会显示错误 elapsed。

**Acceptance Criteria:**
- [ ] `.failed` 状态进入时 `stopTimer()` 被调用
- [ ] Unit test 覆盖 start 失败路径

---

#### US-048: [Watch P2-3] AVAudioSession deactivate 传 `notifyOthersOnDeactivation`
**Description:** As a 用户, I want 录音结束后其他音频 app（音乐 / Siri）能继续, so that 不破坏系统音频体验。

**Acceptance Criteria:**
- [ ] `setActive(false, options: .notifyOthersOnDeactivation)` 替代裸 `setActive(false)`
- [ ] 不再 `try?` 吃错误，log 到 `os.Logger`

---

#### US-049: [Watch P2-4] 删除 `#if os(iOS)` 死代码
**Description:** As a 开发者, I want Watch 文件不含 iOS-only 分支, so that 代码意图清晰。

**Acceptance Criteria:**
- [ ] `WatchApp.swift:53-58` 删除整个 `#if os(iOS)` 块
- [ ] Build 通过

---

#### US-050: [Watch P2-5] 录音文件名加 UUID
**Description:** As a 用户, I want 同一秒触发两次录音也不会覆盖, so that 数据不丢失。

**Acceptance Criteria:**
- [ ] `watchFileStamp` 加 UUID 后缀：`watch_<stamp>_<uuid>.m4a`
- [ ] Unit test：两次连续创建文件名不冲突

---

#### US-051: [Watch P2-6] 启动时清理 tmp 孤儿文件
**Description:** As a 用户, I want Watch 不积累几天前的失败 transfer 文件, so that 存储不浪费。

**Acceptance Criteria:**
- [ ] app 启动时扫 `tmp/com.daypage.watch/`，清理 ≥ 24h 的文件
- [ ] 日志记录清理数量

---

### ⌚ Watch — P3（8 个）

#### US-052: [Watch P3-1] 用 `os.Logger` 替代 `print`
**Description:** As a 工程团队, I want Watch 日志可在 Console.app 过滤, so that 调试方便。

**Acceptance Criteria:**
- [ ] `WatchApp.swift` / `WatchTransferService.swift` 中所有 `print(...)` 替换为 `Logger(subsystem:category:).log(...)`
- [ ] Console.app 能按 subsystem 过滤

---

#### US-053: [Watch P3-2] RecordingView 适配 Digital Crown
**Description:** As a 用户, I want 用旋钮调整录音音量阈值（或类似）, so that 符合 watchOS 习惯。

**Acceptance Criteria:**
- [ ] 至少一个可旋转参数（如录音上限或灵敏度）通过 `.focusable() + .digitalCrownRotation(...)` 可调
- [ ] 模拟器视觉验证

---

#### US-054: [Watch P3-3] Always-On Display 优化
**Description:** As a 用户, I want Always-On 模式下录音 UI 不耗电过多, so that 续航不受影响。

**Acceptance Criteria:**
- [ ] 录音 elapsed 在 Always-On 模式 1Hz 刷新（非每秒动画）
- [ ] `.privacySensitive(true)` 或 `.isLuminanceReduced` 适配
- [ ] WidgetKit Smart Stack 简化版本（可选）

---

#### US-055: [Watch P3-4] 录音触觉反馈
**Description:** As a 用户, I want 开始/停止录音时手腕有震动反馈, so that 不看屏幕也知道状态。

**Acceptance Criteria:**
- [ ] `.recording` 进入时触发 `WKInterfaceDevice.current().play(.start)`
- [ ] `.processing` 进入时触发 `.stop`
- [ ] `.failed` 触发 `.failure`

---

#### US-056: [Watch P3-5] 录音状态机闭环
**Description:** As a 用户, I want 录完一条后能立刻再录, so that 不需要杀 app。

**Acceptance Criteria:**
- [ ] `.done` 状态 2s 后自动回 `.idle`
- [ ] `.failed` 状态点击任意位置回 `.idle`
- [ ] Unit test 覆盖完整状态转换

---

#### US-057: [Watch P3-6] 录音 stop 显式确认
**Description:** As a 用户, I want 误触不会立刻丢失录音, so that 数据更安全。

**Acceptance Criteria:**
- [ ] `.recording → .processing` 之间触发轻确认（如二次点击或长按）
- [ ] 或者：`.processing` 显示 2s 取消窗口

---

#### US-058: [Watch P3-7] 麦克风权限被拒后引导
**Description:** As a 拒绝过权限的用户, I want 看到清晰提示如何启用, so that 知道去 iPhone Watch app 设置。

**Acceptance Criteria:**
- [ ] RecordingView 检测 `AVAudioApplication.shared.recordPermission == .denied` 显示文案"请在 iPhone 上 Watch app → DayPage → 隐私 → 启用麦克风"
- [ ] 视觉验证

---

#### US-059: [Watch P3-8] 补 accessibilityLabel
**Description:** As a VoiceOver 用户, I want 听到 "Start recording" 而非 "waveform", so that 知道按钮功能。

**Acceptance Criteria:**
- [ ] RecordingView 所有按钮加 `.accessibilityLabel(...)`
- [ ] VoiceOver 测试通过

---

### 🏗️ 工程基线（1 个，跨端）

#### US-060: 三端 UI 截图 baseline diff
**Description:** As a 工程团队, I want 每个 PR 自动产出 UI 截图 diff, so that 视觉回归能在 review 时发现。

**Acceptance Criteria:**
- [ ] iOS：Today/Archive/Graph × light/dark × empty/with-memos × en/zh = 24 张 baseline，纳入 `verify-daypage`
- [ ] Web：主路径 6 页 × desktop/mobile × light（dark 如有则 ×2）= 12+ 张 baseline，Playwright 跑
- [ ] Watch：等 SDK 装好后 RecordingView × idle/recording/done/failed = 4 张 baseline
- [ ] PR CI 出 diff 评论（图片对比）
- [ ] 文档化在 `docs/qa/visual-regression.md`

**Technical:** Playwright `toHaveScreenshot()` / `xcrun simctl io booted screenshot` + image-diff action。

---

## 4. Functional Requirements

按"组件 / 模块"汇总功能要求（与 User Story 1:1 对应，便于跨 story 查阅）。

### iOS
- **FR-iOS-1**：`RootView` 必须用单一 enum-driven state 控制 onboarding / auth / ready 三种阶段（US-001）
- **FR-iOS-2**：`RawStorage.parse` 必须正确识别多 memo 文件，并提供 unit test（US-002）
- **FR-iOS-3**：所有 UI 文案必须经过 i18n bundle，永不显示 key 字符串（US-003, US-006, US-010, US-012, US-013）
- **FR-iOS-4**：`DSColor` 必须为所有 token 提供 light/dark variant（US-004）
- **FR-iOS-5**：Today 视图首屏加载必须聚合到单一 loading state，3s 内可见完整内容（US-005）
- **FR-iOS-6**：顶部 chrome 必须单一来源，禁止 NavigationView/Stack 嵌套（US-007）
- **FR-iOS-7**：所有 timestamp 渲染必须通过 `DayPageDateFormatter` 单例（US-008）
- **FR-iOS-8**：CLAUDE.md 必须与实际依赖一致（US-021）

### Web
- **FR-Web-1**：写入链路在 dev 必须可跑通（要么 Inngest 配置正确，要么 dev mock）（US-022）
- **FR-Web-2**：所有侧边栏入口必须指向真实路由或触发真实交互（US-023）
- **FR-Web-3**：`/domain/[slug]` 必须为不存在 slug 提供引导而非裸 404（US-024）
- **FR-Web-4**：所有页面在 375px 宽度必须无水平滚动（US-025）
- **FR-Web-5**：所有自定义快捷键必须不与浏览器 / OS 冲突（US-030）
- **FR-Web-6**：所有非装饰图片 / icon button 必须有 a11y label（US-031, US-035）
- **FR-Web-7**：dev bypass 登录必须 seed 一组演示数据（US-024, US-034）
- **FR-Web-8**：所有交互文本对比度 ≥ WCAG AA（US-033）

### Watch
- **FR-Watch-1**：所有录音文件落地后必须进入 `VoiceAttachmentQueue`（US-040）
- **FR-Watch-2**：所有 Xcode scheme 必须 shared，可在 CI 跑（US-041）
- **FR-Watch-3**：声明的 Complication / AppIntent 必须真正注册到 watchOS，否则删除（US-042, US-043）
- **FR-Watch-4**：所有 `WKExtendedRuntimeSession` 必须设 delegate、传 reason、错误不静默（US-044）
- **FR-Watch-5**：所有 `print` 必须替换为 `os.Logger`（US-052）
- **FR-Watch-6**：所有按钮必须有 `accessibilityLabel`（US-059）

### 跨端
- **FR-Cross-1**：每个 PR 触发 UI 截图 baseline diff（US-060）

---

## 5. Non-Goals (Out of Scope)

本 PRD **不**包括以下内容：

- **新功能开发**：不引入新页面、新 API、新数据模型；仅修复已有功能
- **架构重构**：不重写 SwiftUI 导航体系、不切换状态管理库、不换 Web framework
- **性能基线建立**：不引入 Lighthouse CI / 实时 RUM；只在 story 内做点状性能验证
- **真机测试**：除 Watch P0 需要真机/模拟器验证外，其余在 Simulator + headless browser 即可
- **新增 i18n 语言**：本 PRD 只修 en + zh-Hans 已有翻译失效；不新增日 / 法 / 西
- **Dark mode 设计**：本 PRD 只恢复 dark mode 渲染逻辑；不重新设计配色方案
- **WatchOS SDK 安装**：本 PRD 假定开发者自行安装 watchOS 26.4 SDK 后再跑 Watch story
- **PRD 文档同步**：本 PRD 只跟测试发现的问题对齐，不更新 prd-daypage-v5-codex.md 等其他 PRD

---

## 6. Design Considerations

- **iOS**：以现有 RootView / TodayView / DSColor / DSFonts 为准，CLAUDE.md 明确"源码是设计权威"
- **Web**：保持 V5 Codex 视觉风格（米色 + 像素艺术 + 棕红强调），仅修移动断点与对比度
- **Watch**：遵循 watchOS HIG（触觉反馈、Crown、Always-On）

---

## 7. Technical Considerations

### 依赖与版本
- iOS：Xcode 16.x / iOS 16+ / Swift 5；项目当前使用 SPM（修正 CLAUDE.md 描述）
- Web：Next.js 16.2.6 / Turbopack / Inngest / Supabase / Tailwind
- Watch：watchOS 9+ / WCSession / WidgetKit（替代 deprecated ClockKit）

### 测试基础设施
- **iOS**：`verify-daypage` skill + Swift Testing / XCTest（按需新建 `DayPageTests` target）
- **Web**：Playwright + axe-core + Lighthouse CI
- **Watch**：需先 `Xcode → Settings → Components` 安装 watchOS 26.4 SDK

### 风险
- **R1**：iOS P0-2 parser race 可能与 file system event 调度有关，修复需深挖 `RawStorage` reload 路径
- **R2**：Web P0-1 短路 Inngest 后，真实编译流水（compile loop）能否被 dev 触发需另测
- **R3**：Watch P0-1 修复后 `VoiceAttachmentQueue` 在 iPhone app 后台时能否被唤醒需验证

---

## 8. Success Metrics

### 阶段 1（P0 全修，dogfood 必达）
- **M1.1**：iOS fresh launch 空白率 ≤ 1%（20 次中 ≤ 1 次）
- **M1.2**：iOS i18n key 暴露数 = 0（全屏正则搜索 `[a-z]+\.[a-z_]+\.(title|subtitle)` 应无匹配）
- **M1.3**：iOS multi-memo 解析正确率 = 100%（unit test 全过）
- **M1.4**：Web `/add` → memo 出现在 inbox 端到端通过率 = 100%
- **M1.5**：Web 移动 375px 水平滚动 = 0px
- **M1.6**：Watch 录音 → Today 显示端到端通过率 = 100%
- **M1.7**：剩余 P0 数量 = 0

### 阶段 2（P1 全修，体验合格）
- **M2.1**：iOS dark mode 渲染正确率 = 100%
- **M2.2**：iOS 启动到完整 P95 ≤ 3s
- **M2.3**：Web `/home` networkidle P95 ≤ 2s
- **M2.4**：Web `/login` hydration error 数 = 0
- **M2.5**：Watch CI build 通过率 = 100%
- **M2.6**：剩余 P1 数量 = 0

### 阶段 3（P2 + P3，polish 完成）
- **M3.1**：Lighthouse a11y 分 ≥ 95（Web 主路径所有页面）
- **M3.2**：axe-core critical issues = 0
- **M3.3**：iOS / Web UI 截图 baseline 覆盖率 ≥ 90%
- **M3.4**：剩余 P2 + P3 数量 ≤ 5（允许 5 个低优 polish 延后）

### 整体
- **M-Overall-1**：bug 总数下降 ≥ 90%（60 → ≤ 6）
- **M-Overall-2**：测试套件总耗时 ≤ 30 分钟（iOS + Web）
- **M-Overall-3**：CI green 率 ≥ 95%

---

## 9. Open Questions

- **Q1**：iOS P0-2 parser race 是真的并发问题还是写入逻辑 bug？需要先 reproduce 才知道修复方向。
- **Q2**：Web P0-1 在 dev 是短路 Inngest 改 mock，还是强制要求用户启动 `pnpm dev:inngest`？推荐前者，但需要团队确认是否影响真实编译路径开发。
- **Q3**：Web P0-4 移动端 drawer 用 shadcn Sheet 还是自写？涉及 bundle 大小。
- **Q4**：Watch P1-2 complication 删还是补？补的话需要新建 widget extension target，工作量较大。
- **Q5**：US-060 baseline diff 用 GitHub Action 跑还是本地 pre-commit hook？建议 GH Action，但需要配 storage。
- **Q6**：本 PRD 与 `prd-daypage-v5-codex.md` 的进度关系如何？是否阻塞 V5 后续 story？
- **Q7**：阶段 1（8 个 P0）需要多少 sprint？建议 1 个 sprint（5 工作日）但需要团队评估。

---

## 10. 附录：完整问题映射表

| Story ID | 优先级 | 端 | 问题简述 | 测试报告参考 |
|---|---|---|---|---|
| US-001 | P0 | iOS | Fresh launch 空白屏 | iOS P0-1 |
| US-002 | P0 | iOS | Memo parser 崩坏 | iOS P0-2 |
| US-003 | P0 | iOS | i18n key 裸露 | iOS P0-3 |
| US-004 | P1 | iOS | Dark mode 失效 | iOS P1-1 |
| US-005 | P1 | iOS | 60s 慢加载 | iOS P1-2 |
| US-006 | P1 | iOS | Onboarding 中英混排 | iOS P1-3 |
| US-007 | P1 | iOS | 顶部双 chrome | iOS P1-4 |
| US-008 | P1 | iOS | Timestamp 时区不一致 | iOS P1-5 |
| US-009 | P2 | iOS | 双 Tuesday 标题 | iOS P2-1 |
| US-010 | P2 | iOS | 输入栏怪翻译 | iOS P2-2 |
| US-011 | P2 | iOS | 时间制不明 | iOS P2-3 |
| US-012 | P2 | iOS | 详情 metadata 混排 | iOS P2-4 |
| US-013 | P2 | iOS | Open in Apple Maps 不本地化 | iOS P2-5 |
| US-014 | P2 | iOS | 编辑 pill 语义不清 | iOS P2-6 |
| US-015 | P3 | iOS | 0 memo 空状态 | iOS P3-1 |
| US-016 | P3 | iOS | 截图重复采集 | iOS P3-2 |
| US-017 | P3 | iOS | 详情地图占屏过大 | iOS P3-3 |
| US-018 | P3 | iOS | state.png 残留 | iOS P3-4 |
| US-019 | P3 | iOS | 输入按钮无反馈 | iOS P3-5 |
| US-020 | P3 | iOS | Settings 齿轮对比度 | iOS P3-6 |
| US-021 | P3 | iOS | CLAUDE.md SPM 描述错 | iOS P3-7 |
| US-022 | P0 | Web | Inngest 401 写入断 | Web P0-1 |
| US-023 | P0 | Web | New domain 死链 | Web P0-2 |
| US-024 | P0 | Web | /domain/[slug] 404 | Web P0-3 |
| US-025 | P0 | Web | 移动 375px 断裂 | Web P0-4 |
| US-026 | P1 | Web | Login hydration mismatch | Web P1-1 |
| US-027 | P1 | Web | /home networkidle 5.6s | Web P1-2 |
| US-028 | P1 | Web | 404 不一致 | Web P1-3 |
| US-029 | P1 | Web | /_design-demo 私有路由 | Web P1-4 |
| US-030 | P2 | Web | ⌘N 被吞 | Web P2-1 |
| US-031 | P2 | Web | 无 nav 语义 | Web P2-2 |
| US-032 | P2 | Web | Ask 按钮未知 | Web P2-3 |
| US-033 | P2 | Web | Secondary 对比度低 | Web P2-4 |
| US-034 | P2 | Web | dev 无 seed | Web P2-5 |
| US-035 | P3 | Web | input 无 label | Web P3-1 |
| US-036 | P3 | Web | heading 等级断层 | Web P3-2 |
| US-037 | P3 | Web | Chat 右栏窄 | Web P3-3 |
| US-038 | P3 | Web | 字体未 subset | Web P3-4 |
| US-039 | P3 | Web | Sign out 紧贴底 | Web P3-5 |
| US-040 | P0 | Watch | 录音 → 死文件 | Watch P0-1 |
| US-041 | P1 | Watch | Scheme 没共享 | Watch P1-1 |
| US-042 | P1 | Watch | Complication 不生效 | Watch P1-2 |
| US-043 | P1 | Watch | AppIntent 没注册 | Watch P1-3 |
| US-044 | P1 | Watch | WKExtendedRuntimeSession 错 | Watch P1-4 |
| US-045 | P1 | Watch | AppIcon 缺失 | Watch P1-5 |
| US-046 | P2 | Watch | WCSession 冷启动竞态 | Watch P2-1 |
| US-047 | P2 | Watch | Timer 不停 | Watch P2-2 |
| US-048 | P2 | Watch | AVAudioSession 释放不当 | Watch P2-3 |
| US-049 | P2 | Watch | #if os(iOS) 死代码 | Watch P2-4 |
| US-050 | P2 | Watch | 录音文件秒级冲突 | Watch P2-5 |
| US-051 | P2 | Watch | tmp 孤儿文件 | Watch P2-6 |
| US-052 | P3 | Watch | print 而非 os.Logger | Watch P3-1 |
| US-053 | P3 | Watch | 无 Digital Crown | Watch P3-2 |
| US-054 | P3 | Watch | 无 Always-On 优化 | Watch P3-3 |
| US-055 | P3 | Watch | 无触觉反馈 | Watch P3-4 |
| US-056 | P3 | Watch | 状态机不闭环 | Watch P3-5 |
| US-057 | P3 | Watch | 录音无 stop 确认 | Watch P3-6 |
| US-058 | P3 | Watch | 麦克风被拒无引导 | Watch P3-7 |
| US-059 | P3 | Watch | 缺 accessibilityLabel | Watch P3-8 |
| US-060 | — | Cross | UI 截图 baseline diff | 工程基线 |

**总计 60 个 User Story**（P0×8 / P1×14 / P2×17 / P3×20 / 工程×1）。
