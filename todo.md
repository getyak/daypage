# DayPage 改进任务清单

> 生成日期：2026-06-16 ｜ 来源：iPhone 17 Pro 模拟器实机走查 + 源码交叉验证
> 每条任务都是**自包含**的，可单独分发给一个 AI 执行：含目标文件、上下文、验收标准。
> 完成约定：构建 `xcodebuild -scheme DayPage -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build` 通过 + iPhone 17 模拟器实机验证。

任务编号规则：`P{优先级}-{序号}`。优先级 P0(缺陷) > P1(体验断点) > P2(打磨) > P3(探索)。

---

## P0 · 真实缺陷

- [x] **P0-1｜补齐 en.lproj 缺失的 16 个本地化 key** ✅ 2026-06-16｜en/zh 各 381 key 对齐，plutil 通过，模拟器英文环境验证 "EARLIER" 正常显示
  - 文件：`DayPage/Resources/en.lproj/Localizable.strings`（参照 `DayPage/Resources/zh-Hans.lproj/Localizable.strings`）
  - 背景：英文系统下时间线"EARLIER"分隔符渲染成原始 key `today.section.earlier`，因为 en.lproj 缺这些 key 触发回退。
  - 需新增的 16 条（左 key，右为英文译文建议；zh 原值见括注）：
    - `"today.section.earlier" = "EARLIER";`（zh: EARLIER）
    - `"today.section.yesterday" = "YESTERDAY";`（zh: YESTERDAY）
    - `"today.banner.draft_restored" = "Restored your unsent draft";`（zh: 恢复了未发送的草稿）
    - `"today.banner.voice_queue" = "You have %d voice notes pending transcription";`（zh: 你有 %d 条语音待转写）
    - `"today.sync.banner" = "Sync your journal across devices →";`（zh: 跨设备同步你的日记 →）
    - `"today.compile_failed.retry" = "Retry";`（zh: 重试）
    - `"today.compile_failed.retry_a11y" = "Retry compilation";`（zh: 重试编译）
    - `"today.compile_failed.dismiss_a11y" = "Dismiss error";`（zh: 关闭错误提示）
    - `"today.location_draft.header" = "Location arrival detected";`（zh: 检测到位置到达）
    - `"today.location_draft.confirm_all" = "Confirm all";`（zh: 全部确认）
    - `"today.location_draft.ignore_all" = "Ignore all";`（zh: 全部忽略）
    - `"today.location_draft.still_here" = "Still here";`（zh: 仍在此处）
    - `"today.location_draft.unknown_place" = "Unknown place";`（zh: 未知地点）
    - `"today.location_draft.stayed_hours" = "Stayed %d hours";`（zh: 停留 %d 小时）
    - `"today.location_draft.stayed_hours_minutes" = "Stayed %d h %d min";`（zh: 停留 %d 小时 %d 分钟）
    - `"today.location_draft.stayed_minutes" = "Stayed %d min";`（zh: 停留 %d 分钟）
  - 注意：保留 `%d` 占位符顺序与数量，与 zh 一致。
  - 验收：模拟器系统语言设为英文，Today 时间线底部分隔符显示 "EARLIER" 而非 key 名。

- [x] **P0-2｜为 en/zh 本地化 key 对齐加 CI 校验脚本** ✅ 2026-06-16｜scripts/check_localization_parity.sh + ci.yml 新增 localization-parity job；正负向测试均通过
  - 新建：`scripts/check-localization-parity.sh`（或纳入现有 CI）
  - 逻辑：提取 en.lproj 与 zh-Hans.lproj 的 key 集合，diff；任一侧缺失则非零退出并打印缺失清单。
  - 验收：当前缺失被检出；补齐 P0-1 后脚本通过；故意删一个 key 能复现失败。

- [x] **P0-3｜SettingsView 整页中文硬编码抽取为本地化 key** ✅ 2026-06-16｜抽取 104 个新 key（settings.* 共 122），en/zh 各 485 对齐；Swift 编译 0 错误；模拟器英文环境实机启动通过；en settings.* 值无中文残留
  - 文件：`DayPage/Features/Settings/SettingsView.swift` + en/zh 两份 `Localizable.strings`
  - 背景：英文用户进设置页满屏中文。需抽取的字面量包括但不限于：`"设置"`、`"账号"`、`"未登录"`、`"点击登录"`、`"管理账号"`、`"API Keys"`、`"未配置"`、`"测试连接"`、`"权限"`、`"麦克风"`、`"定位"`、`"外观"`、`"深色模式"`、`"强调色"`、`"正文字号"`、`"卡片密度"`、`"时间与日期"`、`"偏好时区"`、`"恢复设备时区"`、`"iCloud 同步"`、`"数据"`、`"Vault 大小"`、`"计算中…"`、`"关于"`、`"版本"`、`"关闭"`、API Key editor 内全部文案、各类 banner/confirmationDialog 文案。
  - 约定：key 命名前缀统一 `settings.*`；占位符场景用 `%@`/`%d`。
  - 验收：英文系统下整个设置页（含 API Key 编辑 sheet、各确认弹窗）显示英文，无中文残留。

---

## P1 · 核心体验断点

- [x] **P1-1｜修复 Graph 冷启动死锁——区分"无数据"与"有数据未成网"空状态** ✅ 2026-06-16｜GraphViewModel 增加 hasCompiledDailies 检测；新增 graphNotConnected 空状态（en/zh 各 491 key 对齐）；模拟器两态验证通过
  - 文件：`DayPage/Features/Graph/GraphView.swift`、`GraphViewModel.swift`
  - 背景：图谱靠扫描 `wiki/daily/*.md` 里的 `[[wiki/type/slug|Name]]` wikilink 构建；现有 daily 文件无 wikilink、`wiki/{places,people,themes}` 为空，导致 Graph 恒为 "No knowledge graph yet."。
  - 任务：在 GraphViewModel 增加判定——若存在已编译 daily 但 nodes 为空，空状态文案改为"已有日记但还未生成连接"，CTA 改为"重新编译生成图谱"（触发 `CompilationService.compile`），而非 "WRITE SOMETHING"。
  - 验收：注入无 wikilink 的 daily 后，Graph 空状态显示"未成网"分支 + 编译入口；注入含 `[[wiki/places/xxx|名称]]` 的 daily 后图谱出现节点。

- [ ] **P1-2｜编译 prompt 强制产出 wikilink + entity pages（落实"编译成网"）**
  - 文件：`DayPage/Services/CompilationService.swift`（编译 prompt 与产物写盘逻辑）
  - 背景：当前编译产物不含 `[[wiki/...]]` 连接，是 Graph 死锁的根因。
  - 任务：调整 system/user prompt，要求 AI 在 daily 正文中以 `[[wiki/{places|people|themes}/slug|显示名]]` 标注实体，并生成/更新对应 `wiki/{type}/{slug}.md` entity page（含 frontmatter occurrence 计数）。
  - 验收：配置可用 AI key 后编译当日，daily 文件含 ≥1 个 wikilink，对应 entity page 被创建，Graph 出现节点与边。
  - 依赖：需要可用的 DashScope API key 做端到端验证。

- [x] **P1-3｜WriteSheet 弹出后键盘未自动弹出，需二次点击** ✅ 2026-06-16｜onAppear 延迟从 0.05s 调整为 350ms（Task.sleep），sheet-up 动画结束后 @FocusState 生效；模拟器验证文本框自动获焦
  - 文件：`DayPage/Features/Today/WriteSheetView.swift`（第 207-209 行）
  - 背景：点击输入栏 "Capture this moment" 弹出 WriteSheet 后，文本编辑区域未获焦，软键盘不弹出，用户需要再手动点一次 "What's on your mind?" 区域才能开始输入。
  - 根因：`onAppear` 中 `DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { isFocused = true }` 的 0.05s 延迟太短——sheet-up 动画 320ms 尚在进行中，SwiftUI 的 `@FocusState` 请求被动画吞掉。
  - 任务：将延迟从 0.05s 调整到 0.35s（sheet 动画结束后），或改用 `task { try? await Task.sleep(for: .milliseconds(350)); isFocused = true }` 确保在主线程动画结束后聚焦。
  - 验收：点击输入栏 → WriteSheet 弹出 → 键盘自动弹出，光标在文本区域闪烁，无需二次点击。

- [x] **P1-4｜AI 未配置时编译按钮改为引导态并深链跳转 Settings** ✅ 2026-06-16｜CompileFooterButton 新增 aiKeyMissing 引导态（⚙ 配置 AI 引擎）；TodayView 检测 key 为空时跳转 Settings sheet；en/zh 新增 compile.configure_ai key；模拟器验证按钮态 + 点击跳转均正常
  - 文件：`DayPage/Features/Today/TodayView.swift`、`CompileFooterButton.swift`、`CompileUnlockCard.swift`、`DayPage/App/AppNavigationModel.swift`
  - 背景：未配 key 时编译按钮仍可点，点了才失败；顶部红 banner 每次常驻。
  - 任务：(a) 检测 `Secrets.resolvedDeepSeekApiKey` 为空时，编译按钮显示"配置 AI 引擎"态，点击直接打开 Settings 并定位到 API Keys 区（可在 AppNavigationModel 加 pendingSettingsSection 或 deep link `daypage://settings/apikeys`）；(b) "DashScope API Key not configured" banner 支持 dismiss 后短期不再每次弹（复用现有 BannerCenter 抑制机制）。
  - 验收：清空 key 后，Today 编译按钮为引导态、一键跳 Settings；dismiss banner 后重进 Today 短期内不再弹。

---

## P2 · 界面打磨

- [x] **P2-0｜WriteSheet footer 计数器中文长文本时布局溢出换行** ✅ 2026-06-16｜计数器 HStack 添加 lineLimit(1)+minimumScaleFactor(0.75)；模拟器验证 100+ 字时 footer 保持单行
  - 文件：`DayPage/Features/Today/WriteSheetView.swift`（第 409-427 行，`footerRail`）
  - 背景：输入 52 个中文字时，底部 footer rail 的 "52 WORDS · 52 CHARS · ~1 MIN READ" 文本换行，排版混乱——数字和标签错位成多行。英文短文本无此问题。
  - 根因：footer rail 使用 `HStack(spacing: 2)`，计数文本区域没有 `lineLimit` 或 `minimumScaleFactor` 约束，当中文 CJK 字数较多（两位数以上）+ 阅读时间标签出现时，文本被左侧图标和右侧 Save 按钮挤压到换行。
  - 任务：给计数器 `HStack` 添加 `.lineLimit(1).minimumScaleFactor(0.75)` 防止换行，或调整间距/字号以适配最长计数文本（如 "999 WORDS · 999 CHARS · ~5 MIN READ"）。
  - 验收：输入 50+ 中文字时，footer rail 保持单行显示，计数文本完整可读；200+ 字时仍不换行。

- [x] **P2-1｜Today 有内容时保留迷你光球作为今日进度锚点** ✅ 2026-06-16｜sidebarSection 有 memo 时在 headerSublineView 前添加 28pt DayOrbView，复用 dayProgress/orbTint 驱动，点击触发 orbFocusToggle 聚焦输入框；模拟器验证光球显示+点击弹出 WriteSheet
  - 文件：`DayPage/Features/Today/TodayView.swift`（`orbHero` / `sidebarSection`）、`DayOrbView.swift`
  - 背景：空状态 140pt 光球很出彩，但有 memo 后整块消失，过渡突兀。
  - 任务：有 memo 时在 header 区放一个小尺寸（约 24–32pt）光球，复用 `dayProgress` 驱动，点击聚焦输入框。
  - 验收：有内容时 header 出现迷你光球，点击聚焦输入栏，reduceMotion 下不做呼吸动画。

- [x] **P2-2｜Archive 月度统计卡按用户实际维度动态显隐** ✅ 2026-06-16｜monthlySummary LazyVGrid 和 monthDigestStrip 中 voice/photos/locations 为 0 时隐藏对应卡片；TOTAL ENTRIES 始终保留；模拟器验证 VOICE DURATION 0 被隐藏
  - 文件：`DayPage/Features/Archive/ArchiveView.swift`、`MetadataGridView.swift`
  - 背景：纯文字用户的 "VOICE DURATION 0 MIN / PHOTOS CAPTURED 0" 恒为 0，显空。
  - 任务：当某维度当月为 0 时隐藏该卡（或灰显折叠），保证至少展示 TOTAL ENTRIES；维度全 0 时给占位文案。
  - 验收：仅文字记录的月份不再显示 0 值语音/照片卡；有语音/照片的月份正常显示。

- [x] **P2-3｜Graph 空状态隐藏顶部搜索框与筛选按钮** ✅ 2026-06-16｜nodes.isEmpty 时隐藏搜索栏+筛选+网络 pill+匹配结果+日期筛选面板；模拟器验证空图谱页面仅显示空状态主体
  - 文件：`DayPage/Features/Graph/GraphView.swift`
  - 背景：空图谱时 "Search nodes…" 与筛选按钮无可操作对象。
  - 任务：`nodes.isEmpty` 时隐藏搜索栏与筛选按钮，仅保留空状态主体。
  - 验收：空图谱时无搜索/筛选 chrome；有节点时恢复显示。

- [x] **P2-4｜统一并核对统计口径（侧边栏 PAGES vs Archive TOTAL ENTRIES）** ✅ 2026-06-16｜侧边栏 "PAGES/TOTAL" 改为 "DAILIES/COMPILED"（编译产物），Archive "TOTAL ENTRIES"（原始 memo 数）保持不变；两处口径定义清晰不矛盾；模拟器验证标签显示正确
  - 文件：`DayPage/App/SidebarViewModel.swift`、`SidebarView.swift`、`ArchiveView.swift`
  - 背景：侧边栏 "PAGES 4 TOTAL" 与 Archive "TOTAL ENTRIES" 口径需明确，避免两处数字打架。
  - 任务：统一定义（建议：PAGES=已编译 daily 数，ENTRIES=有 raw memo 的天数），在两处使用同一计算源；标签语义清晰。
  - 验收：两处数字定义一致、可解释；同一份数据下不矛盾。

- [x] **P2-5｜侧边栏未登录态用户卡文案明确化** ✅ 2026-06-16｜未登录时名称 "DayPage"→"本地账户"，副标题 "MEMBER"→"本地 · 点击同步"；en/zh 新增 sidebar.profile.* 两个 key；模拟器验证文案正确显示
  - 文件：`DayPage/App/SidebarView.swift`
  - 背景：未登录显示 "DayPage MEMBER" 语义模糊。
  - 任务：未登录时副标题改为"本地账户 · 点击同步"之类（走本地化 key），已登录显示邮箱/账号。
  - 验收：未登录与已登录两态文案清晰区分。

- [x] **P2-6｜API Key 区分"必需(AI)"与"可选(天气)"视觉** ✅ 2026-06-16｜apiKeyRow 新增 isRequired 参数；OpenWeatherMap 使用灰色"可选"badge 而非红色"未配置"；en/zh 新增 settings.apikey.optional key；模拟器验证三行 API Key badge 颜色和文案区分正确
  - 文件：`DayPage/Features/Settings/SettingsView.swift`（`apiKeyRow`）
  - 背景：三项未配置全标红"未配置"，造成焦虑。
  - 任务：天气（OpenWeatherMap）未配置时用中性"可选 · 未配置"灰标签；AI（DeepSeek）保留红色强提示。
  - 验收：天气未配不再红色告警，AI 未配仍醒目。

- [x] **P2-7｜Memo 卡片右滑手势无操作反馈** ✅ 2026-06-16｜功能已在此前开发中实现：右滑露出"置顶"+"更多"两个操作按钮（SwipeableMemoCard leadingActions），onPin/onMore 回调已在 TodayView 中接入；模拟器验证右滑手势+按钮显示正常
  - 文件：`DayPage/Features/Today/SwipeableMemoCard.swift`
  - 背景：左滑露出 Delete/Share 操作正常，但右滑没有任何反应。根据设计历史记录，右滑应有置顶/更多按钮。
  - 任务：确认设计意图——若右滑操作已移除则无需处理；若仍需要，在右滑方向添加 Pin/More 操作按钮。
  - 验收：确认设计方案并记录结论；若保留右滑，操作按钮功能正常。

- [ ] **P2-8｜实拍验证 Memo 详情页与 DailyPage 编译结果页排版**
  - 文件：`DayPage/Features/MemoDetail/`、`DayPage/Features/Daily/DailyPageView.swift`
  - 背景：本轮自动化点击被 SwipeableMemoCard 的 UIKit pan host 吞掉，未实拍详情页（真机手指可进，非 bug）。
  - 任务：真机或录屏走查 Memo 详情 + DailyPage 结果页 + 分享卡，记录排版/可读性问题并补充任务。
  - 验收：产出详情页/DailyPage 截图与问题清单。

---

## P3 · 增量探索

- [x] **P3-1｜统一空状态 CTA 文案动词** ✅ 2026-06-16｜Graph 空状态 CTA 从 "Write something"/"去写点什么" 统一为 "Add a memo"/"添加备忘"，与 Today 空状态一致；subtitle 和时段变体也统一动词；en/zh 492 key 对齐；模拟器验证 Graph 空状态 CTA 显示"添加备忘"
  - 文件：Graph/Today 空状态相关视图 + 本地化 strings
  - 任务：把 "WRITE SOMETHING" 与 "ADD A MEMO" 收敛为一致动词（如统一 "Add a memo"）。
  - 验收：各空状态 CTA 用词一致。

- [ ] **P3-2｜评估用 SF Symbols 替换 emoji 以保持视觉调性**
  - 文件：`SettingsView.swift`（☁️ iCloud）、侧边栏（🔥 streak）等
  - 任务：评估并替换通篇 emoji 为 SF Symbols，与衬线/mono 极简语言统一。先产出对照评估，再实施。
  - 验收：关键 emoji 替换为 symbol 且暗色/动态字号下表现正常。

- [ ] **P3-3｜为纯文本用户提供更轻的首页变体（设计探索）**
  - 文件：`DayPage/Features/Today/`（先出设计稿，不直接改代码）
  - 任务：探索弱化语音/照片/位置入口、突出"快速 dump 文字"的轻量首页，符合数字游民核心诉求。
  - 验收：产出设计方案 + GitHub issue 供讨论（按 CLAUDE.md：设计先开 issue 讨论）。

---

## 附：工程环境（非产品，建议先处理以便后续验证）

- [x] **ENV-1｜修复测试 framework 误嵌入主 App bundle** ✅ 2026-06-16｜验证 DayPage.app/Frameworks/ 仅含 Sentry.framework，无 XCTest 相关 framework 泄漏；simctl install 正常无报错；问题已在此前修复
  - 现象：`xcodebuild -scheme DayPage build` 在 Validate 阶段失败——`XCTest/Testing/XCUIAutomation/XCTestSupport/XCTestCore/XCTAutomationSupport.framework` 被嵌入 `DayPage.app/Frameworks/`，致 `simctl install` 报 "Info.plist missing"。
  - 任务：核查 DayPage target 的 Embed Frameworks 阶段与测试依赖链，移除测试框架向主 App 的泄漏（很可能是某依赖把 XCTest 作为链接库带入）。
  - 验收：`xcodebuild -scheme DayPage build` 直接产出可被 `simctl install` 安装的 .app，无需手动删 framework。

---

### 建议落地顺序
1. ENV-1（让构建可直接出安装包，扫清验证障碍）
2. P0-1 → P0-2 → P0-3（i18n 一次性收口）
3. P1-1 → P1-2 → P1-3（WriteSheet 键盘焦点）→ P1-4（打通 Today→编译→Graph 价值链）
4. P2-0（计数器溢出）→ P2 逐屏打磨（每条独立开 issue + 分支 + PR）
5. P3 探索类（设计先行，开 issue 讨论）
