# PRD: DayPage v6 — 全端深度体验改进（Input / Output / Pages / System）

> Status: Draft · Owner: Xinwei · Created: 2026-05-17
> Scope: iOS App 端（不含 web/CODEX）
> Branch convention: `feat/v6-<area>-<short>` / `fix/v6-<area>-<short>`
> 一个 User Story = 一个 issue = 一个分支 = 一个 PR

---

## 1. Introduction / Overview

DayPage iOS 端在 v3–v5 几轮迭代后，核心采集 + 编译链路已稳定，新近合并的 #281/#282 又补齐了系统级入口（AppIntent / URL Scheme / Widget / 锁屏 / 控制中心）。本 PRD 聚焦"**质感与可信度**"的最后一公里：

- **输入端**消除录音/拍照/草稿的歧义与丢失风险
- **输出端**让编译过程透明、错误可恢复、daily page / entity 可读
- **导航/检索**让 Archive 与 Search 可被真实回访
- **系统集成**让 Widget / Watch / iCloud / Shortcut 端到端可信
- **全局质感**统一触觉、动态字号、深色模式、性能 budget

本 PRD 共 **5 大主题 / 22 个 User Story（US-001 ~ US-022）**，全部带可验证验收标准；外加 **5 组 28 条深度体验测试用例（T-A1 ~ T-E5）**。

## 2. Goals

- 录音首次成功率（无误触/取消）≥ 95%
- 草稿因后台/崩溃丢失率 = 0
- 编译错误对用户"可解释 + 可恢复"率 = 100%（不再有静默失败）
- Today 100 memo 滚动维持 ≥ 58fps
- vault 累计 5000 memo 时冷启动 < 2s
- 全 App AX5 动态字号下无截断、无重叠
- 22 个 US 全部以 1 issue / 1 PR 形式落地（便于回滚 + review）

## 3. User Stories

> 命名约定：`US-XXX` 直接对应 GitHub issue title 前缀。Story 颗粒度遵守 CLAUDE.md "一次专注 session 可完成"。

---

### 主题 A — 输入路径（P0）

#### US-001: 输入栏交互去歧义 + 首次使用引导
**Description:** 作为新用户，我希望第一次看到输入栏时就知道"短按 / 长按 / 拖动取消 / 拖动转文字"的差异，不需要试错。

**Acceptance Criteria:**
- [ ] 首次启动（或升级到 v6）显示 3 步浮层引导，依次演示：短按打开录音页 / 长按 0.25s 开始录音 / 上滑取消 / 左滑转文字
- [ ] 引导仅出现一次（`@AppStorage("v6.inputBarTutorialShown")`）
- [ ] 长按阈值从 0.35s 调整为 0.25s，源码处 `InputBarV4.swift` 内的 `minimumDuration` 同步更新
- [ ] 长按触发时触觉反馈强度提升为 `.heavy`，并叠加 `UIImpactFeedbackGenerator` 单次
- [ ] 录音中拖动出现"↑ 取消 / ← 转文字"双向箭头 + 文字，箭头颜色随距离阈值变红
- [ ] 录音结束 5s 内 Today 顶部浮"撤销"胶囊按钮，点击撤销则删除刚写入的 memo + 附件文件
- [ ] 单元测试覆盖：撤销操作能正确回滚 `RawStorage` 中的 memo 与磁盘 attachment
- [ ] iPhone 17 Simulator 实测：录音 5 次（短/长/取消/转文字/撤销）全部按预期工作

---

#### US-002: 草稿持久化与崩溃恢复
**Description:** 作为重度使用者，我不希望切到后台或被系统杀掉后丢失正在输入的草稿。

**Acceptance Criteria:**
- [ ] `TodayView.draftText` 从 `@State` 改为 `@SceneStorage("today.draftText")`
- [ ] 切换 Sidebar / Settings sheet / DailyPage sheet 时 draftText 不被重置
- [ ] App 启动时若 draftText 非空，Today 顶部展示 banner："恢复了未发送的草稿"，带 dismiss 按钮
- [ ] 提交成功后 draftText 被清空，banner 不再出现
- [ ] 草稿超过 30 天未提交自动清理
- [ ] 单元测试：模拟 sceneDidEnterBackground + 重新初始化 View，验证草稿仍在
- [ ] iPhone 17 Simulator 实测：输入 200 字中文 → 杀进程 → 重启 → 草稿仍在

---

#### US-003: 附件 Chip 视觉与错误反馈
**Description:** 作为用户，我想清楚地看到每个附件的类型、状态和错误，并能在出错后重试。

**Acceptance Criteria:**
- [ ] 每个 `PendingAttachment` chip 包含：缩略图（photo）/波形（voice）/文件图标（file）+ 类型角标 + 上传进度环
- [ ] 录音 chip 显示时长（"0:23"）并可点击试听（用 `AVAudioPlayer`）
- [ ] 长按 chip 弹出"删除 / 重命名（仅 file）/ 查看大图（仅 photo）"操作菜单
- [ ] 上传/转写失败的 chip 边框变红 + 右上角红色重试图标，点击重试
- [ ] 失败原因写入 `attachment.transcript` 字段以便排查
- [ ] iPhone 17 Simulator 实测：模拟 Whisper 失败（断网）→ chip 红化 → 联网点重试 → 成功转写

---

#### US-004: 拍照 / 相册批量与 HEIC 异步化
**Description:** 作为用户，我选择 5 张大图（含 HEIC + Live Photo）时不希望卡住主线程。

**Acceptance Criteria:**
- [ ] `PhotoService` 处理移到 background `Task.detached(priority: .userInitiated)`
- [ ] 多选 > 3 张时输入栏上方显示批量进度条（已处理/总数）
- [ ] HEIC → JPEG 转换异步，UI 立即返回缩略图占位
- [ ] EXIF 提取失败不阻断流程，仅记录 log
- [ ] Live Photo 仅取静态图，不丢失主图
- [ ] 单元测试：5 张 4K HEIC 全流程 < 3s，主线程无 > 16ms 卡顿（用 Instruments Time Profiler 抽样）
- [ ] iPhone 17 Simulator 实测：相册多选 5 张 → 输入栏不冻结，可继续打字

---

#### US-005: 语音离线兜底 + 增量转写
**Description:** 作为用户，飞行模式下我也希望能录音并得到（粗略）转写。

**Acceptance Criteria:**
- [ ] `VoiceService` 检测 `NetworkMonitor.shared.isReachable == false` 时自动切换 `SFSpeechRecognizer` 本地引擎
- [ ] 转写结果前缀标注 `[离线·精度较低]`
- [ ] Whisper 路径支持 partial result：每 1s 拉一次中间转写显示在录音页面顶部
- [ ] 转写失败时保留音频 + 红角标提示 "未转写，点击重试"
- [ ] 用户后续联网后可在 chip 上点"重新转写"用 Whisper 重跑
- [ ] iPhone 17 Simulator 实测：飞行模式录 10s → 出现离线转写；切回联网 → 重新转写覆盖

---

### 主题 B — 输出路径（P1）

#### US-006: 编译进度可视化 + 错误归因
**Description:** 作为用户，我希望编译过程透明，失败时知道原因并能采取行动。

**Acceptance Criteria:**
- [ ] `CompilationService` 暴露 4 阶段进度：`fetchingMemos` / `callingLLM` / `parsing` / `writing`，通过 `@Published var stage: CompileStage`
- [ ] `CompileFooterButton` 显示当前阶段文案 + 进度条
- [ ] 失败分类为：`network` / `tokenLimitExceeded` / `apiKeyInvalid` / `parseError` / `unknown`，UI 给出对应文案与按钮（重试 / 打开 API key 设置 / 反馈）
- [ ] 错误进 `DayPageLogger.error` 并附带 traceId
- [ ] 编译失败的 daily page 不写盘，避免污染
- [ ] 单元测试：mock 5 种错误，UI 文案与按钮符合预期
- [ ] iPhone 17 Simulator 实测：断网编译 → 出现网络错误 + 重试按钮

---

#### US-007: DailyPageView 拆分与重渲染优化
**Description:** 作为开发者，我希望 1813 行的 `DailyPageView.swift` 被拆解，便于维护与性能优化。

**Acceptance Criteria:**
- [ ] 拆为：`DailyPageHeader.swift` / `DailyPageSummarySection.swift` / `DailyPageEntitiesSection.swift` / `DailyPageActionsBar.swift` / `DailyPageView.swift`（主入口 ≤ 400 行）
- [ ] 折叠状态由独立 `DailyPageSectionsModel: ObservableObject` 持有
- [ ] 改动一处 section 时其他 section 不重渲染（用 `Instruments → SwiftUI` 验证 BodyCount）
- [ ] 现有功能 100% 等价（人工对比所有交互）
- [ ] Snapshot 测试覆盖三种状态：未编译 / 编译中 / 已编译

---

#### US-008: 重编译确认与差异提示
**Description:** 作为用户，重编译时我希望知道会覆盖什么。

**Acceptance Criteria:**
- [ ] 点"重新编译"弹 confirmation dialog："将覆盖现有 daily page（最后编译于 HH:mm），是否继续？"
- [ ] 编译完成后顶部 banner 显示 "新增 N 条 memo 被纳入编译"
- [ ] 编译完成的 daily page 头部显示 last-compiled-at 时间戳
- [ ] iPhone 17 Simulator 实测：编译 → 加 1 memo → 重编译 → banner 显示 "+1"

---

#### US-009: Entity 详情时间线视图
**Description:** 作为用户，我想看到某个人/地点/项目在过去所有 memo 中的出现情况。

**Acceptance Criteria:**
- [ ] `EntityPageView` 新增"时间线"tab，按时间倒序列出所有包含该 entity 的 memo 摘要
- [ ] 每条 memo 点击 → 跳 `MemoDetailView`
- [ ] 支持按月分组折叠
- [ ] 空状态文案："这是它第一次出现"
- [ ] 性能：≥ 500 条引用时滚动 60fps（用 `LazyVStack`）
- [ ] iPhone 17 Simulator 实测：选一个高频 entity，时间线渲染正常

---

#### US-010: Entity 同名合并
**Description:** 作为用户，"杭州" 和 "Hangzhou" 应该可以被识别并合并为同一 entity。

**Acceptance Criteria:**
- [ ] `EntityPageService` 检测可能的同名 entity（编辑距离 ≤ 2 或拼音/罗马音匹配）
- [ ] Entity 列表顶部出现 banner："发现 N 组可能重复的 entity，点击合并"
- [ ] 合并 UI：两侧对照 + "合并到 A / 合并到 B / 忽略" 三选项
- [ ] 合并后所有 memo 的 entity 引用统一更新（vault 文件原子写）
- [ ] 合并操作可在 7 天内撤销（保留 backup）
- [ ] 单元测试：合并后 vault 文件内容与引用一致

---

### 主题 C — 导航 / Archive / Search（P1）

#### US-011: Sidebar 边缘手势 + 自适应宽度
**Description:** 作为用户，我希望从屏幕左缘滑动就能打开 Sidebar。

**Acceptance Criteria:**
- [ ] 屏幕左缘 12pt 范围支持向右滑动手势打开 Sidebar
- [ ] 手势速率 > 500pt/s 时直接打开，否则随手指移动
- [ ] iPhone Mini 宽度 320pt 时 Sidebar 宽度自动调整为屏幕 80%
- [ ] iPad 上 Sidebar 改为常驻列（NavigationSplitView 风格）
- [ ] iPhone 17 Simulator + iPad Air 实测

---

#### US-012: Sidebar 嵌入最近 7 天日历缩略
**Description:** 作为用户，我在 Sidebar 里就想快速看到最近 7 天哪几天有 memo。

**Acceptance Criteria:**
- [ ] Sidebar Today 入口下方新增 7 列小日历，每列：日期 + 圆点（按 memo 数密度填充）
- [ ] 点击某天直接跳 `DayDetailView`
- [ ] 数据来自现有 `TimelineService`，仅查询元数据，不读 body
- [ ] iPhone 17 Simulator 实测

---

#### US-013: Archive 月历热力图 + 长按预览
**Description:** 作为用户，我希望在 Archive 月历上一眼看出活跃日。

**Acceptance Criteria:**
- [ ] 月历每个单元格根据当日 memo 数（0/1-3/4-7/8+）渲染 4 档热力色
- [ ] 长按单元格 0.5s 弹出预览卡（前 3 条 memo 摘要 + 跳转按钮）
- [ ] 预览卡为 `.popover` 风格，松手或点外部关闭
- [ ] 顶部新增筛选条：情绪 / 标签 / 地点（多选）
- [ ] 筛选与月份切换 URL/state 一致，重入恢复
- [ ] iPhone 17 Simulator 实测

---

#### US-014: Search debounce + 分组 + 高亮
**Description:** 作为用户，我希望搜索结果分组清晰、关键词高亮、不卡顿。

**Acceptance Criteria:**
- [ ] 输入 debounce 200ms 后才触发 `SearchService` 查询
- [ ] 结果按时间分组：今天 / 本周 / 本月 / 更早
- [ ] 关键词在结果摘要中黄底加粗高亮
- [ ] 中文/英文/混合/emoji 关键词都可正常分词命中
- [ ] 历史搜索保留最近 10 条，Search 顶部展示
- [ ] 推荐搜索：展示最近 5 个高频 entity
- [ ] iPhone 17 Simulator 实测以上场景

---

### 主题 D — 系统集成（P1）

#### US-015: Widget 状态同步与计数刷新
**Description:** 作为用户，刚加完 memo，主屏/锁屏 Widget 上的计数应该立即刷新。

**Acceptance Criteria:**
- [ ] `RawStorage` 写盘成功后调用 `WidgetCenter.shared.reloadTimelines(ofKind: "QuickCaptureWidget")`
- [ ] Widget Timeline 提供当日 memo 数 + 最近一条摘要
- [ ] 锁屏 Widget 点击 → 拉起录音 → 录完写回当天 vault → Widget 自动刷新
- [ ] App 处于被杀状态下点击 Widget，按 #281 URL Scheme 可正常拉起到录音页
- [ ] iPhone 17 Simulator 实测主屏 / 锁屏 / 控制中心三种 Widget

---

#### US-016: AppIntent / URL Scheme 端到端验证
**Description:** 作为用户，"Hey Siri, 用 DayPage 记一条" 和外部 App 跳 `daypage://record` 都应正常工作。

**Acceptance Criteria:**
- [ ] `StartRecordingIntent` 在 Shortcuts.app 中可被发现并运行
- [ ] Siri 调用后 App 直接进入录音状态（不需要二次确认）
- [ ] `daypage://record` 在 Mobile Safari 跳转后弹出 App 并进入录音
- [ ] `daypage://memo/new?text=hello` 直接预填草稿
- [ ] 失败路径（未登录）显示登录引导，不崩溃
- [ ] iPhone 17 Simulator + 真机 Siri 实测

---

#### US-017: iCloud 冲突 diff UI
**Description:** 作为多设备用户，发生冲突时我希望看到差异并自主选择。

**Acceptance Criteria:**
- [ ] `iCloudConflictMonitor` 检测到冲突时入栈 `BannerCenter.shared`（持久化 banner，不自动消失）
- [ ] 点击 banner 弹 `ConflictResolutionSheet`，左右展示两版本 markdown diff（用 `swift-diff` 或手写 LCS）
- [ ] 三选项：保留本地 / 保留云端 / 手动合并（进入文本编辑器）
- [ ] 合并结果写回 vault + iCloud
- [ ] 冲突解决后 banner 自动消失
- [ ] 单元测试：构造冲突文件，验证 diff 与合并写回

---

#### US-018: Watch 录音接收提示
**Description:** 作为 Watch 用户，从手表录的音应在 iPhone 端有明确反馈。

**Acceptance Criteria:**
- [ ] `WatchReceiveService` 收到新录音时 BannerCenter 浮提示："从 Apple Watch 接收 1 条语音"
- [ ] Banner 点击 → 跳 Today 并滚到该条 memo
- [ ] 多条合并显示 "N 条语音"
- [ ] iPhone 17 + Watch Simulator 实测

---

### 主题 E — Settings / Auth / Feedback / 全局质感（P2）

#### US-019: Settings 944 行拆分为 7 子页
**Description:** 作为开发者，单文件 944 行难以维护，拆为 7 个 NavigationLink 子页。

**Acceptance Criteria:**
- [ ] 拆分为：账户 / 同步 / AI / 通知 / 隐私 / 高级 / 关于，各自独立文件 ≤ 250 行
- [ ] `SettingsView.swift` 仅作为入口列表 ≤ 200 行
- [ ] 每个子页可单独导航返回，标题正确
- [ ] 现有所有开关 / 输入项 100% 等价
- [ ] iPhone 17 Simulator 逐页验证

---

#### US-020: OTP 输入 6 位框 + autofill
**Description:** 作为用户，OTP 输入应该自动跳格 + 接收短信自动填充。

**Acceptance Criteria:**
- [ ] OTP 输入改为 6 个独立 box，输入后自动跳下一格，删除回上一格
- [ ] 设置 `.textContentType(.oneTimeCode)` 启用系统短信 autofill
- [ ] 粘贴 6 位数字自动分发到 6 个 box
- [ ] 输入完成后自动提交，无需点按钮
- [ ] iPhone 17 Simulator + 真机短信实测

---

#### US-021: 全局触觉反馈与字号统一
**Description:** 作为用户，全 App 的触觉反馈应一致，动态字号 AX5 下不破版。

**Acceptance Criteria:**
- [ ] 建立 `HapticFeedback.swift` 统一封装：`.light()` / `.medium()` / `.heavy()` / `.success()` / `.warning()` / `.error()`
- [ ] 全 App 替换所有直接 `UIImpactFeedbackGenerator` / `UINotificationFeedbackGenerator` 调用
- [ ] 所有 `DSType.serifDisplayXX` 固定字号补充 `.dynamicTypeSize(...DynamicTypeSize.accessibility5)` 与 `.minimumScaleFactor(0.6)`
- [ ] AX5 下逐页人工检查：Today / Archive / DailyPage / Settings / Auth / Entity / MemoDetail 无截断
- [ ] 深色模式逐页检查，对比度 ≥ WCAG AA

---

#### US-022: 性能 budget 守护
**Description:** 作为用户与开发者，关键指标必须可测、可守护。

**Acceptance Criteria:**
- [ ] 启动时 `DSFonts.registerAll()` 移到后台线程（`Task.detached(priority: .utility)`），主线程 < 50ms
- [ ] `TodayView` 顶层 `@StateObject` 由 5 降到 3（合并 `bannerCenter` / `voiceQueue` / `migrationService` 到 `TodayServicesBundle`）
- [ ] Today 滚动 100 memo 在 iPhone 17 Simulator Instruments → SwiftUI BodyCount 增长 < 200/s
- [ ] vault 内构造 5000 memo，冷启动到 Today 可交互 < 2s
- [ ] 加 GitHub Action：build + 启动时间基线对比，回退 > 20% 阻断 PR

---

## 4. Functional Requirements

| # | 要求 |
|---|---|
| FR-1 | 输入栏长按阈值统一 0.25s，触觉强度 `.heavy` |
| FR-2 | 草稿用 `@SceneStorage` 跨 scene 持久化 |
| FR-3 | 附件 chip 支持试听 / 重试 / 删除 / 预览 |
| FR-4 | 图片处理全异步，不阻塞主线程 |
| FR-5 | 离线录音自动切 `SFSpeechRecognizer`，结果标注 `[离线]` |
| FR-6 | `CompilationService` 暴露 4 阶段进度与 5 类错误 |
| FR-7 | `DailyPageView` 拆为 ≥ 4 个子视图文件 |
| FR-8 | 重编译需 confirmation；编译后显示 last-compiled-at |
| FR-9 | Entity 详情提供时间线 tab + 同名合并 UI |
| FR-10 | Sidebar 支持边缘手势 + iPad NavigationSplitView |
| FR-11 | Archive 月历热力 + 长按预览 + 多维筛选 |
| FR-12 | Search debounce 200ms + 分组 + 高亮 + 历史 |
| FR-13 | RawStorage 写盘后必须刷 Widget Timeline |
| FR-14 | AppIntent / URL Scheme 路径在未登录时显示登录引导 |
| FR-15 | iCloud 冲突走持久化 banner + diff sheet |
| FR-16 | Watch 录音到达 → BannerCenter 提示并可跳转 |
| FR-17 | Settings 拆 7 子页，主文件 ≤ 200 行 |
| FR-18 | OTP 6 box + `oneTimeCode` autofill |
| FR-19 | 全 App 触觉走统一 `HapticFeedback` 封装 |
| FR-20 | 所有 fixed 字号补 dynamicType 上限与 scale factor |
| FR-21 | 字体注册移后台线程 |
| FR-22 | CI 引入启动时间基线 |

## 5. Non-Goals（Out of Scope）

- Graph 完整实现（仍 Post-MVP，本 PRD 只在 Entity 内做小型关系图）
- 跨平台（Android / macOS Catalyst / Web App）
- 多账号切换
- 主题市场 / 自定义配色
- 任何破坏现有 vault YAML 格式的迁移
- 多人协作 / 分享他人 daily page
- AI 模型更换或 prompt 大调（属 v7）
- Pricing / 订阅墙

## 6. Design Considerations

- 继续沿用 v4/v5 的 Liquid Glass + 暖色 ambient
- 引导 / banner / sheet 全部使用现有 `BannerCenter` + `AppBanner` 组件
- 字体仅使用已注册的 Space Grotesk / Inter / JetBrains Mono，不引入新字
- 配色严格走 `DSColor`，不允许硬编码 `Color(hex:)`
- 所有新增子页面优先复用 `DSType` typography token

## 7. Technical Considerations

- 不引入新的 SPM 依赖（除非有人评审通过）
- 所有写盘走 `FileManager.replaceItem` 保证原子性
- 性能基线在 iPhone 17 Simulator 上测，Instruments Time Profiler / SwiftUI BodyCount 抓证据
- 单元测试用 Swift Testing 框架（DayPageTests target）
- 触发 BGTask 用 `_simulateLaunchForTaskWithIdentifier:` 调试
- 任何涉及 vault 结构的改动需先在 `tasks/design-*.md` 中写设计稿（参考 design-icloud-sync.md 风格）

## 8. Success Metrics

| 指标 | 当前（推测） | 目标 |
|---|---|---|
| 录音首次成功率 | ~70% | ≥ 95% |
| 草稿丢失率 | 偶发 | 0 |
| 编译失败"用户可恢复"率 | < 30% | 100% |
| Today 100 memo FPS | 未测 | ≥ 58 |
| vault 5000 memo 冷启动 | 未测 | < 2s |
| AX5 全页通过率 | 未测 | 100% |
| Settings 文件行数 | 944 | ≤ 200（主入口） |
| DailyPageView 文件行数 | 1813 | ≤ 400（主入口） |
| 单 PR 行数中位数 | > 800 | < 400 |

---

## 9. 深度体验测试用例（必须随 PR 跑过）

### A. 输入路径
- [ ] **T-A1** Today → 相册多选 5 张大图（含 HEIC + Live Photo）→ chip 区不阻塞，缩略图齐全
- [ ] **T-A2** 拍照 → 返回 chip + EXIF 落 `transcript`
- [ ] **T-A3** 长按 mic 4 种边界：0.2s（太短 toast）/ 1s 松开（发送）/ 上拖（取消）/ 左拖（转文字进 draft）
- [ ] **T-A4** 输入 200 字中文 → 切后台 → 杀进程 → 重启 → 草稿仍在
- [ ] **T-A5** 飞行模式录 10s → 出现 `[离线]` 转写；联网点重试 → Whisper 覆盖
- [ ] **T-A6** 录音中接电话 / Siri 打断 → 优雅恢复且不丢音
- [ ] **T-A7** 同时 5 个 pending attachments → 删除中间 → ID 不串

### B. 输出路径
- [ ] **T-B1** 攒 10 条 memo → 手动编译 → 杀进程 → 重开有重试入口
- [ ] **T-B2** 断网编译 → 报"网络错误"而非"key 失效"
- [ ] **T-B3** 编译后再加 1 memo → 重编译 confirmation → 顶部 banner "+1"
- [ ] **T-B4** BGTask 模拟启动：`_simulateLaunchForTaskWithIdentifier:` → 通知 + vault 落盘
- [ ] **T-B5** Entity 时间线 ≥ 500 条引用 → 滚动 60fps
- [ ] **T-B6** 合并同名 entity → vault 中所有引用统一

### C. 导航 / Archive / Search
- [ ] **T-C1** 屏幕左缘滑动 → Sidebar 打开
- [ ] **T-C2** Archive 月历滑动 6 个月 → 内存不暴涨
- [ ] **T-C3** Archive 长按某天 → 预览卡正确
- [ ] **T-C4** Search 中文/英文/混合/emoji 关键词均能命中高亮
- [ ] **T-C5** Search 清空 → 历史与推荐展示

### D. 系统集成
- [ ] **T-D1** 主屏 Widget 录音 → Today 出现
- [ ] **T-D2** 锁屏 Widget 录音 → Today 出现
- [ ] **T-D3** 控制中心快捷录音 + App 完全杀掉 → 拉起成功
- [ ] **T-D4** Siri "用 DayPage 记一条" → 进入录音状态
- [ ] **T-D5** `daypage://record` 与 `daypage://memo/new?text=hi` 跳转正确
- [ ] **T-D6** Watch 录音 → iPhone banner 提示并跳转
- [ ] **T-D7** A/B 设备同秒写同一文件 → 冲突 banner + diff sheet 出现

### E. 极端 / 全局
- [ ] **T-E1** 单日 100 memo → Today 滚动 ≥ 58fps
- [ ] **T-E2** vault 5000 memo → 冷启动 < 2s
- [ ] **T-E3** 系统语言切德语 / 日语 → 文案与排版完好
- [ ] **T-E4** 动态字号 AX5 → 全页面无截断
- [ ] **T-E5** iPad 横屏 → Sidebar / Today / DailyPage 自适应

---

## 10. 执行节奏建议

| 周 | 范围 | 产出 |
|---|---|---|
| W1 | US-001 ~ US-005（输入 P0） | 5 issue + 5 PR |
| W2 | US-006 ~ US-010（输出 P1） | 5 issue + 5 PR |
| W3 | US-011 ~ US-014（导航 P1） | 4 issue + 4 PR |
| W4 | US-015 ~ US-018（系统集成 P1） | 4 issue + 4 PR |
| W5 | US-019 ~ US-022（质感 P2） | 4 issue + 4 PR |
| W6 | T-A ~ T-E 全量回归 + 修 bug | 测试报告 + 收尾 PR |

每个 US 完成时必须：
1. 在 PR 描述里引用对应 US 编号 + 验收清单逐条勾选
2. 跑过 T-A ~ T-E 中相关用例并附截图
3. `xcodebuild -scheme DayPage -destination 'platform=iOS Simulator,name=iPhone 17' build` 通过
4. `DayPageTests` 全绿

---

## 11. Open Questions

1. US-005 离线转写是否同时支持中英文？`SFSpeechRecognizer` 单 locale 实例，要决定主 locale
2. US-010 entity 合并撤销窗口是 7 天还是 30 天？涉及 backup 存储成本
3. US-017 冲突 diff 是否引入 `swift-diff` 第三方库？还是手写 LCS（CLAUDE.md "no external deps without discussion"）
4. US-022 CI 启动时间基线托管在 GitHub Actions 还是接 Sentry Performance？
5. 是否需要在本 PRD 范围内补一个 `vault 5000 memo seeder` 脚本（属于测试基础设施）

---

## 12. Checklist（PRD 自检）

- [x] 5 个主题覆盖 input / output / pages / system / global
- [x] 22 个 User Story 全部带可验证验收标准
- [x] 22 个 Functional Requirements 编号
- [x] Non-Goals 明确
- [x] 28 条深度体验测试用例
- [x] 成功指标可量化
- [x] 执行节奏 6 周可落地
