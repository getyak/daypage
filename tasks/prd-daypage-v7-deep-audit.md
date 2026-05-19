# PRD: DayPage v7 — 深度审计与优化路线图

> Status: Draft · Created: 2026-05-19
> Based on: Agent Team 三角度深度分析 (UI/UX + Architecture + Features)
> Codebase snapshot: 118 Swift files, ~31K lines, iOS 16+, SwiftUI
> Branch convention: `fix/v7-<area>-<short>` / `feat/v7-<area>-<short>`

---

## 1. 综合评分

| 维度 | 分数 | 评价 |
|---|---|---|
| UI/UX | 71/100 | 设计系统骨架扎实（Liquid Glass token 体系完整），但一致性执行断层明显：InputBarV4 和交互组件中 20+ 处硬编码字体/颜色；动效 token 被大量绕过；Accessibility 覆盖残缺（Dynamic Type 只覆盖 body 文本，关键按钮无 a11y label）。 |
| 架构/代码质量 | 62/100 | MVVM 分层清晰，原子写入有 NSFileCoordinator 保护；但 **P0 安全漏洞**（多个生产 API key 硬编码提交）直接拉低评分；TodayView/ArchiveView 超千行、Task 体缺 @MainActor 注解、NotificationCenter 观察者无 deinit 清理，测试覆盖率 <10%。 |
| 产品/功能 | 68/100 | 核心五路径（文字/语音/图片/位置/AI 编译）均有实现；Archive + Search 功能完整；Onboarding 和 Settings 覆盖到位。但知识图谱（Graph Tab）UI 有骨架却**未接入真实数据**（P0）；Entity 双向链接缺失；AI 模型被换成 DeepSeek 却未向用户披露；Voice 流式转写未实现（v6 PRD 承诺）。 |
| **综合** | **67/100** | 可用的 MVP+，但三个领域各有一个 P0 问题需要在 v7.0 清零：API key 泄露 → 立即轮换 + Keychain 迁移；Graph 数据断链；API key 硬编码安全漏洞。 |

---

## 2. 辩论摘要（Phase 1 — 三角交叉审查）

### 2.1 🔥 Critical 项（两个以上角色同评 P0）

#### CRIT-01: API Key 硬编码提交
**Agent Cross-Reference: AR（P0）+ PR（P0）**

- ⚙️ **Architecture Advocate**：`Config/GeneratedSecrets.swift` 中存有 DeepSeek、OpenAI Whisper、OpenWeather、Supabase Anon Key、GitHub PAT 共 5 个生产 key，注释写着「DO NOT COMMIT」但实际已入库。GitHub 秘密扫描机器人通常在 push 后数分钟内发现 `sk-proj-` 前缀 key。**后果：OpenAI key 被滥用、账单暴增；GitHub PAT 可读取私有仓库。这是零延迟修复项。**
- 📊 **Product Advocate**：用户数据（语音音频）通过被泄露的 Whisper key 上传 OpenAI；如果攻击者更换 key 指向恶意端点，用户日记内容将完全暴露。这不是技术债，是**信任危机**。
- 🎨 **UI/UX Advocate**（让步）：虽然这不是 UI 问题，但如果用户得知日记内容通过泄露 key 传输，这比任何视觉问题都更直接损害产品可用意愿。我支持 P0。

**裁决**：🔥 Critical，v7.0 第一优先级，必须在任何新功能开发前修复。

---

#### CRIT-02: Graph Tab 数据断链
**Agent Cross-Reference: PR（P0）+ AR（P2，分歧！）**

- 📊 **Product Advocate**：Graph Tab 在所有 PRD（v3、v5、v6）中都是核心差异化功能，是「知识网络」叙事的视觉锚点。当前 UI 骨架完整（380+ 行力导向图）但 GraphViewModel 使用 stub 数据，与 vault wiki/ 目录完全断开。用户看到的是空图或硬编码样例——这是**功能欺骗**。
- ⚙️ **Architecture Advocate**（分歧）：GraphView 已标注 Post-MVP，CLAUDE.md 明确说「keep the placeholder」。EntityPageService 的 CRUD 已完成，接线不复杂（1-2天），但不应升为 P0 —— 它不会造成数据丢失或安全风险，顶多 P1。
- 🎨 **UI/UX Advocate**（调解）：空 Graph Tab 的问题不在于它「不好看」，而在于它打破用户的心理模型。用户在 Archive 精心积累 6 个月数据，点开 Graph 看到空白 —— 期待被摔碎。我支持 Product 的评级：P0 或至少 Must。但 Architecture 说得对，它**不需要完美**——只要接上真实数据，哪怕渲染简陋。

**裁决**：🔥 Critical，但范围收窄为「接通 GraphViewModel 与 EntityPageService 数据」，不要求交互完美。

---

#### CRIT-03: NotificationCenter 观察者泄漏（内存 + 行为 Bug）
**Agent Cross-Reference: AR（P0）**

- ⚙️ **Architecture Advocate**：`TodayViewModel` 中 4 个 `NotificationCenter.addObserver` 在 deinit 中无对应 `removeObserver`。每次重建 ViewModel（NavigationStack push/pop）都会累积新观察者。10 次导航后，单个通知触发 10 次回调，导致「提交重复」幻象 bug。
- 📊 **Product Advocate**：用户报告「刚才明明只提交了一次，为什么显示两条？」是留存杀手级 bug。支持 P0。
- 🎨 **UI/UX Advocate**：如果动画回调也被重复触发，会看到 UI 抖动。支持 P1+。

**裁决**：🔥 Critical，属于行为正确性问题，非单纯内存问题。

---

### 2.2 重大分歧与裁决

#### 分歧 A: TodayView 1170 行拆分优先级
- ⚙️ **Architecture Advocate**：P1，大文件使 PR 审查和 AI 辅助编码极其困难，也是测试盲区的根源。
- 🎨 **UI/UX Advocate**：P2，这是重构而非 UX 问题，不影响用户体验。
- 📊 **Product Advocate**：P2，用户不感知，但对功能迭代速度有间接影响。
- **裁决**：**P1（Should）**。理由：TodayViewModel 测试覆盖率为零，而它是核心路径；拆分是测试工作的前提条件。

#### 分歧 B: Dynamic Type 支持
- 🎨 **UI/UX Advocate**：P1，苹果 App Store 无障碍审查项，拒绝上架风险。
- ⚙️ **Architecture Advocate**：P2，技术上不复杂（添加 `.dynamicTypeSize` modifier），但工作量不小（25个 type token 均需处理）。
- 📊 **Product Advocate**：P2，数字游民用户群体对文字大小需求差异大，但不是核心留存因素。
- **裁决**：**P1（Should）**，但分阶段执行：先覆盖 heading 和 body（高频），再覆盖 mono/serif display（低频）。

#### 分歧 C: DeepSeek vs Qwen 模型切换
- 📊 **Product Advocate**：P0，MVP 承诺 DashScope + Qwen3.5-plus，实际用 DeepSeek，prompt 格式不一致、输出质量差异未知、用户感知差异。
- ⚙️ **Architecture Advocate**：P1，模型切换是 1 行配置改动，但需要全面测试编译输出质量；当前 DeepSeek 实现并非「破坏性的」，而是「不同的」。
- 🎨 **UI/UX Advocate**：P2，UI 层无感，但设置页应向用户显示当前使用的模型。
- **裁决**：**P1（Should）**。不强制切回 Qwen，但必须：① 在 Settings 中披露当前 AI 引擎；② 进行 A/B 输出质量对比测试；③ 更新 PRD 中的技术规格声明。

#### 分歧 D: 硬编码字体/动效 token 绕过
- 🎨 **UI/UX Advocate**：P1，这是维护定时炸弹；下次设计迭代时，所有 hardcoded `system(size: 11)` 必须逐文件手动搜索替换。
- ⚙️ **Architecture Advocate**：同意 P1，但优先级低于并发安全修复。
- 📊 **Product Advocate**：P2，不影响当前用户感知。
- **裁决**：**P2（Could）** 整体评级，但 InputBarV4 的字体对齐是 P1，因为输入区是用户每次打开 App 的第一接触点。

---

### 2.3 三方共识

下列问题三角色无争议：

| 问题 | 共识等级 |
|---|---|
| API key 轮换 + Keychain 迁移 | 🔥 Critical |
| NotificationCenter 观察者 deinit 清理 | 🔥 Critical |
| Graph Tab 接通真实数据 | 🔥 Critical |
| Task 体补 @MainActor | P1 |
| 语音附件 retry UX 完善 | P1 |
| Archive 月份同步加载性能 | P1 |
| Entity 双向链接 | P1 |
| 错误状态覆盖（Location draft、photo） | P1 |
| Backup 文件 .trash 无限积累 | P2 |

---

## 3. 优先级矩阵

| ID | 问题 | 优先级 | Agent 来源 | 工作量 | 用户影响 | 风险 |
|---|---|---|---|---|---|---|
| P-001 | API key 泄露 → 轮换 + Keychain 迁移 | **M** 🔥 | AR+PR | M | ⭐⭐⭐⭐⭐ | ★★★★★ |
| P-002 | NotificationCenter 观察者 deinit 泄漏 | **M** 🔥 | AR+UIUX | S | ⭐⭐⭐⭐ | ★★★★ |
| P-003 | Graph Tab 接通 EntityPageService 数据 | **M** 🔥 | PR+AR | M | ⭐⭐⭐⭐⭐ | ★★★ |
| P-004 | Task 体补 @MainActor（6处并发安全） | **M** | AR | S | ⭐⭐⭐ | ★★★★ |
| P-005 | atomicWrite 临时文件孤儿清理 | **M** | AR | S | ⭐⭐⭐ | ★★★ |
| P-006 | InputBarV4 硬编码字体 → DSType token | **S** | UIUX+AR | M | ⭐⭐⭐ | ★★ |
| P-007 | Dynamic Type 覆盖（heading+body 优先） | **S** | UIUX | M | ⭐⭐⭐⭐ | ★★ |
| P-008 | A11y：关键按钮 label + 44pt tap target | **S** | UIUX | S | ⭐⭐⭐⭐ | ★★ |
| P-009 | 语音 retry UX 闭环（附件 chip 红边→retry） | **S** | PR+UIUX | S | ⭐⭐⭐ | ★★ |
| P-010 | Archive 月份异步加载/分页 | **S** | PR+AR | M | ⭐⭐⭐ | ★★★ |
| P-011 | Entity 双向链接（Memo → Entity 反向索引） | **S** | PR+AR | M | ⭐⭐⭐⭐ | ★★ |
| P-012 | DeepSeek 模型披露 + Settings 展示当前引擎 | **S** | PR+UIUX | S | ⭐⭐ | ★★ |
| P-013 | TodayViewModel 核心路径单元测试 | **S** | AR | L | ⭐⭐ | ★★★ |
| P-014 | 编译/语音/照片处理 Loading 指示器 | **S** | UIUX | S | ⭐⭐⭐ | ★ |
| P-015 | Memo 结构补 mood + entity mentions 字段 | **S** | PR | M | ⭐⭐⭐ | ★★ |
| P-016 | 批量 HEIC 转换移离主线程 | **S** | PR+AR | S | ⭐⭐ | ★★★ |
| P-017 | TodayView 拆分子视图（<300行/文件） | **C** | AR+UIUX | L | ⭐⭐ | ★ |
| P-018 | ArchiveView 拆分子视图 | **C** | AR | L | ⭐⭐ | ★ |
| P-019 | 动效 token 补全（InputBar spring、swipe snap、breathing） | **C** | UIUX | S | ⭐⭐ | ★ |
| P-020 | .trash 备份定期清理（7天 TTL） | **C** | AR | S | ⭐ | ★★ |
| P-021 | LocationDraftCard 错误 UI | **C** | UIUX+PR | S | ⭐⭐ | ★ |
| P-022 | 硬编码中英文字符串 → L10n key | **C** | UIUX | M | ⭐⭐ | ★ |
| P-023 | UserDefaults API key → Keychain（Runtime key） | **C** | AR | S | ⭐⭐ | ★★ |
| P-024 | Entity slug 去重 / 模糊匹配 | **C** | PR | M | ⭐⭐ | ★ |
| P-025 | Markdown export（Obsidian 兼容） | **C** | PR | M | ⭐⭐⭐ | ★ |
| P-026 | Tag 系统（Memo struct + Archive 过滤） | **W** | PR | XL | ⭐⭐ | ★ |
| P-027 | 骨架屏（Calendar、Daily Page、Timeline） | **W** | UIUX | L | ⭐ | ★ |
| P-028 | CompilationService.compile() 函数拆分 | **W** | AR | M | ⭐ | ★ |

---

## 4. User Stories（按主题分组）

---

### Theme A — 安全与可靠性 🔥

#### US-001: 立即轮换全部泄露的 API Key

**Description:** 作为产品负责人，我需要立即撤销并重新生成 `GeneratedSecrets.swift` 中的所有 5 个生产密钥（DeepSeek sk-、OpenAI sk-proj-、OpenWeather、Supabase anon、GitHub PAT），防止恶意使用。

**Cross-Referenced By:** AR + PR

**Acceptance Criteria:**
- [ ] 在所有相关平台撤销现有密钥：DeepSeek、OpenAI Dashboard、OpenWeatherMap、Supabase、GitHub Settings
- [ ] 生成新密钥，**不**写入任何 Swift 文件或 git 跟踪目录
- [ ] 验证 `GeneratedSecrets.swift` 已被 `.gitignore` 正确排除（`git ls-files --error-unmatch DayPage/Config/GeneratedSecrets.swift` 应报错）
- [ ] CI/CD（Fastlane）从环境变量或加密 secrets 注入密钥，生成该文件

**Priority:** Must  
**Effort:** S  
**User Impact:** ⭐⭐⭐⭐⭐

---

#### US-002: 将 API Key 从 UserDefaults 迁移到 Keychain

**Description:** 作为用户，我的 AI API key 应存储在 iOS Keychain 中而非明文 UserDefaults，防止 iCloud UserDefaults 备份泄露。

**Cross-Referenced By:** AR  
**File refs:** `DayPage/Config/SecretsRuntime.swift`, `DayPage/Services/AuthService.swift`

**Acceptance Criteria:**
- [ ] 在 `KeychainHelper.swift` 中新增 `setAPIKey(_:for:)` / `getAPIKey(for:)` 方法，使用 `kSecClassGenericPassword`
- [ ] `SecretsRuntime.resolvedDeepSeekApiKey` 等所有运行时 key 读取路径改为从 Keychain 读取
- [ ] Settings 中「保存 API Key」按钮写入 Keychain 而非 `UserDefaults`
- [ ] 首次启动迁移：若 UserDefaults 中存有旧 key，静默迁移至 Keychain 并删除 UserDefaults 条目
- [ ] 构建通过，iPhone 17 Simulator 手动测试：输入 key → force-quit → 重启 → key 保留

**Priority:** Must  
**Effort:** M  
**User Impact:** ⭐⭐⭐⭐

---

#### US-003: 修复 NotificationCenter 观察者累积泄漏

**Description:** 作为用户，我在一次 session 中多次进出 Today 视图时，不应看到重复的 memo 提交或重复触发的编译动画。

**Cross-Referenced By:** AR + UIUX  
**File refs:** `DayPage/Features/Today/TodayViewModel.swift` L209, L218, L227, L236（4 个观察者注册）

**Acceptance Criteria:**
- [ ] 在 `TodayViewModel` 中添加 `private var cancellables = Set<AnyCancellable>()`（或手动存储 token）
- [ ] 将 4 个 `NotificationCenter.addObserver` 改为 `.publisher(for:).sink { }.store(in: &cancellables)`，Combine 自动在 deinit 清理
- [ ] 或：在 `deinit { NotificationCenter.default.removeObserver(self) }` 中统一移除
- [ ] 测试：模拟 10 次 push/pop TodayView，发送 1 次 `compilationSucceeded` 通知，验证回调只触发 1 次（不是 10 次）
- [ ] 构建通过

**Priority:** Must  
**Effort:** S  
**User Impact:** ⭐⭐⭐⭐

---

#### US-004: Task 体补 @MainActor 注解（并发安全）

**Description:** 作为开发者，我需要 TodayViewModel 中所有 Task 闭包体明确标注 `@MainActor`，防止 @Published 属性在非主线程被修改导致 UI 状态撕裂。

**Cross-Referenced By:** AR  
**File refs:** `DayPage/Features/Today/TodayViewModel.swift` L500, L620, L634, L652, L695, L789

**Acceptance Criteria:**
- [ ] 将上述 6 处 `Task {` 改为 `Task { @MainActor in`
- [ ] `CompilationService` 中 `@Published compilationProgress` 的写入路径包裹 `await MainActor.run { }`（`CompilationService.swift` L113）
- [ ] 替换 `TodayView.swift` L371 的 `DispatchQueue.main.asyncAfter` 为 `Task { try? await Task.sleep(for: .seconds(3)); ... }`
- [ ] Swift 编译器无 Sendable / data race 警告（启用 `-strict-concurrency=complete` 检查）
- [ ] 构建通过，现有测试通过

**Priority:** Must  
**Effort:** S  
**User Impact:** ⭐⭐⭐

---

#### US-005: 修复 atomicWrite 临时文件孤儿问题

**Description:** 作为用户，App crash 或写入失败后重启时，vault 目录下不应残留 `.tmp.UUID` 孤儿文件占用 iCloud 存储配额。

**Cross-Referenced By:** AR  
**File refs:** `DayPage/Services/RawStorage.swift` L147-180（atomicWrite）

**Acceptance Criteria:**
- [ ] 在 `atomicWrite` 的 `catch` 块中，`replaceItemAt` 失败后执行 `try? FileManager.default.removeItem(at: tempURL)` 清理临时文件
- [ ] 在 App 启动（`VaultInitializer` 或 `RawStorage.init`）时扫描 vault 目录，删除所有匹配 `*.tmp.*` 的孤儿文件
- [ ] 添加单元测试：模拟 `replaceItemAt` 抛出，验证 tempURL 文件被清理
- [ ] 构建通过

**Priority:** Must  
**Effort:** S  
**User Impact:** ⭐⭐⭐

---

### Theme B — UI/UX 一致性

#### US-006: InputBarV4 硬编码字体 → DSType token 对齐

**Description:** 作为设计系统维护者，InputBarV4 中 20+ 处 `.font(.system(size: N, weight: W))` 应全部替换为对应 DSType token，确保下次字体迭代只改 1 个文件。

**Cross-Referenced By:** UIUX + AR  
**File refs:** `DayPage/Features/Today/InputBarV4.swift` （全文件，重点 L91, L99, L173, L265, L565, L584, L738, L749）

**Acceptance Criteria:**
- [ ] 建立映射表：`system(size: 11, weight: .semibold)` → `DSType.label`；`system(size: 18)` → `DSType.bodyMD`；`system(size: 19, weight: .light)` → `DSType.serifBody18`（按最近匹配）；映射表作为 PR 描述附录
- [ ] `GlassErrorBanner.swift`、`GlassTabBar.swift` 中硬编码字体同步替换
- [ ] 替换后视觉截图对比（before/after）附 PR
- [ ] 构建通过，iPhone 17 Simulator 目视验证

**Priority:** Should  
**Effort:** M  
**User Impact:** ⭐⭐⭐

---

#### US-007: 全局 Dynamic Type 支持（heading + body 优先）

**Description:** 作为使用大字号的用户，我希望 DayPage 所有主要文本在「更大字号」辅助功能设置下都能正确缩放，而不仅限于正文。

**Cross-Referenced By:** UIUX  
**File refs:** `DayPage/DesignSystem/Typography.swift` L182-330（所有 Modifier struct）

**Acceptance Criteria:**
- [ ] 为 `H1Modifier`、`H2Modifier`、`HeadlineMDModifier`、`BodyMDModifier`、`BodySMModifier`、`CaptionModifier` 添加 `.dynamicTypeSize(.xSmall ... .xxxLarge)` 和 `.minimumScaleFactor(0.8)` 
- [ ] `SerifBody16/18/20Modifier` 同样处理（重要：日记正文使用这组 token）
- [ ] `MonoModifier` 系列（mono9/10/11）使用 `.dynamicTypeSize(.xSmall ... .accessibility1)` 限制最大放大（monospace 过大破坏对齐）
- [ ] iPhone 17 Simulator 开启「辅助功能 > 更大字体 > 最大」，验证 TodayView、ArchiveView、DailyPageView 文字可读无截断
- [ ] 构建通过

**Priority:** Should  
**Effort:** M  
**User Impact:** ⭐⭐⭐⭐

---

#### US-008: Accessibility — 关键按钮 label + 44pt tap target

**Description:** 作为使用 VoiceOver 的用户，我需要所有交互元素都有语义化 accessibilityLabel，且 tap target 不小于 44pt。

**Cross-Referenced By:** UIUX  
**File refs:** `DayPage/Features/Today/TodayView.swift` L126（Settings 28pt）, L1039, L1042, L1108-L1130（LocationDraftRow 30pt buttons）

**Acceptance Criteria:**
- [ ] Settings gear button 从 `frame(28, 28)` 改为 `frame(44, 44)`（或加 `.contentShape(Rectangle())`），添加 `.accessibilityLabel(L10n.a11y.settingsButton)`
- [ ] LocationDraftRow 的「全部忽略」「全部确认」「单条确认」「单条忽略」按钮 frame 改为 `min(44, 44)` 并添加语义 label
- [ ] `TodayView.swift` L93「Open navigation」改为 `L10n.a11y.openNavigation`（移入 Localizable.strings en/zh-Hans）
- [ ] 新增 `L10n.a11y.*` 枚举分支，覆盖以上所有新 label
- [ ] iPhone 17 Simulator 开启 VoiceOver 手动验证：逐一聚焦上述按钮，描述正确
- [ ] 构建通过

**Priority:** Should  
**Effort:** S  
**User Impact:** ⭐⭐⭐⭐

---

#### US-009: 编译 / 语音转写 / 照片处理 Loading 指示器

**Description:** 作为用户，当 AI 编译、Whisper 转写或批量照片处理正在进行时，我应该看到明确的 Loading 状态，而不是静默等待。

**Cross-Referenced By:** UIUX + PR  
**File refs:** `DayPage/Features/Today/InputBarV4.swift` L643；`DayPage/Features/Today/CompileFooterButton.swift` L37；`DayPage/Services/VoiceService.swift` L194

**Acceptance Criteria:**
- [ ] 语音录制停止到转写完成期间，InputBarV4 的附件 chip 显示 `ProgressView()` 旋转器（替换静态图标）
- [ ] CompileFooterButton 在 `isCompiling == true` 时显示 `ProgressView()` + 阶段文字（「分析中…」「生成中…」），使用 `CompilationService.compilationProgress` 驱动
- [ ] 批量照片处理期间（`isProcessingPhoto == true`），Today 输入区顶部显示细进度条（`LinearProgressView`），处理完成后淡出
- [ ] 所有 loading 组件使用 `DSColor.onSurfaceVariant` tint，与 v4 视觉语言一致
- [ ] 构建通过，iPhone 17 Simulator 目视验证三种 loading 场景

**Priority:** Should  
**Effort:** S  
**User Impact:** ⭐⭐⭐

---

#### US-010: 动效 Token 补全（InputBar / Swipe / Breathing）

**Description:** 作为设计系统维护者，`Motion.swift` 应补充 3 个当前被大量硬编码绕过的动效 token，消除分散的魔法数值。

**Cross-Referenced By:** UIUX  
**File refs:** `DayPage/DesignSystem/Motion.swift`；`DayPage/Features/Today/InputBarV4.swift` L91, L173；`DayPage/Features/Today/SwipeableMemoCard.swift` L178

**Acceptance Criteria:**
- [ ] 新增 `Motion.inputDock = Animation.spring(response: 0.42, dampingFraction: 0.78)` — 用于输入栏形态切换
- [ ] 新增 `Motion.swipeSnap = Animation.spring(response: 0.28, dampingFraction: 0.86)` — 用于卡片侧滑回弹
- [ ] 新增 `Motion.breathing = Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true)` — 用于 ambient 脉冲动画
- [ ] InputBarV4 L91 `composerSpring` 改用 `Motion.inputDock`；L173 匿名 spring 改用 `Motion.inputDock`
- [ ] SwipeableMemoCard L178 改用 `Motion.swipeSnap`
- [ ] RecordingOverlayView / DayOrbView breathing 动画改用 `Motion.breathing`
- [ ] 构建通过

**Priority:** Could  
**Effort:** S  
**User Impact:** ⭐⭐

---

#### US-011: 硬编码字符串 → L10n key（TodayView）

**Description:** 作为多语言用户，TodayView 中的硬编码中英文字符串（notes count、位置到达、全部忽略等）应通过 L10n 系统输出，支持语言切换。

**Cross-Referenced By:** UIUX  
**File refs:** `DayPage/Features/Today/TodayView.swift` L933, L935, L965, L1035, L1039, L1042

**Acceptance Criteria:**
- [ ] L933/935：`"\(dateStr) · 1 note"` → `L10n.Archive.noteCount(1)`；复数形式 `L10n.Archive.noteCountPlural(count)`
- [ ] L965：`Button("重试")` → `Button(L10n.Error.retry)`
- [ ] L1035：`Text("检测到位置到达")` → `Text(L10n.Location.arrivalDetected)`
- [ ] L1039/1042：`"全部忽略"` / `"全部确认"` → `L10n.Location.ignoreAll` / `L10n.Location.confirmAll`
- [ ] 在 `en.lproj/Localizable.strings` 和 `zh-Hans.lproj/Localizable.strings` 中添加对应键值
- [ ] 构建通过

**Priority:** Could  
**Effort:** M  
**User Impact:** ⭐⭐

---

### Theme C — 功能补全

#### US-012: Graph Tab 接通 EntityPageService 真实数据 🔥

**Description:** 作为用户，我在 Graph Tab 中应该看到基于我实际日记数据生成的知识图谱节点（人物、地点、主题），而不是空白或样例数据。

**Cross-Referenced By:** PR + AR  
**File refs:** `DayPage/Features/Graph/GraphView.swift`；`DayPage/Features/Graph/GraphViewModel.swift`；`DayPage/Services/EntityPageService.swift`

**Acceptance Criteria:**
- [ ] `GraphViewModel` 实现 `loadGraph()` 方法：读取 `wiki/places/`、`wiki/people/`、`wiki/themes/` 目录下所有 entity 页面，解析 YAML frontmatter 提取 `name`、`type`、`occurrence_count`、`first_seen`
- [ ] 每个 entity 转换为图节点；若两个 entity 在同一 Daily Page 中同时出现，则生成连边（co-occurrence）
- [ ] GraphView 保持现有力导向布局，仅替换数据源为 `GraphViewModel.nodes` / `.edges`
- [ ] 空状态：vault 无 entity 时显示 `EmptyStateView`（「先积累一些日记，知识图谱会在这里生长」）
- [ ] Graph Tab 在 vault 有至少 3 个 entity 时展示可交互图谱
- [ ] 构建通过，iPhone 17 Simulator 有数据时验证图谱节点非空

**Priority:** Must  
**Effort:** M  
**User Impact:** ⭐⭐⭐⭐⭐

---

#### US-013: Entity 双向链接（Entity Page → Related Memos）

**Description:** 作为用户，打开一个 Entity 页面（例如「#咖啡馆」）时，我应该看到所有提到过它的原始 Memo 列表，形成从知识网络回溯到原始记录的路径。

**Cross-Referenced By:** PR + AR  
**File refs:** `DayPage/Features/Entity/EntityPageView.swift` L43-45（stub `relatedMemos()`）；`DayPage/Services/EntityPageService.swift` `apply()` 方法

**Acceptance Criteria:**
- [ ] `EntityPageService.apply(instruction:)` 在创建或更新 entity 时，将当前日期的 daily page 文件名追加到 entity YAML frontmatter 的 `related_dates: []` 数组
- [ ] `EntityPageView` 实现 `relatedMemos()` —— 读取 `related_dates`，对每个日期调用 `RawStorage.read(for:)`，返回包含该 entity slug 的 memo 列表
- [ ] Entity 页面底部新增「来源记录」Section，以 MemoCardView（精简版，无操作手势）展示 related memos，按日期降序排列，最多显示 20 条
- [ ] 单元测试：构造包含 entity mention 的 memo → 运行 `apply()` → 验证 `related_dates` 包含该日期
- [ ] 构建通过

**Priority:** Should  
**Effort:** M  
**User Impact:** ⭐⭐⭐⭐

---

#### US-014: AI 引擎透明化 — Settings 展示当前模型

**Description:** 作为用户，我有权知道当前处理我日记的 AI 模型是什么，并理解模型变更对编译风格的潜在影响。

**Cross-Referenced By:** PR + UIUX  
**File refs:** `DayPage/Features/Settings/SettingsView.swift`；`DayPage/Services/CompilationService.swift` L17

**Acceptance Criteria:**
- [ ] Settings「AI 编译引擎」Section 显示：当前模型名称（`CompilationService.modelName`）、API provider、上次编译时间
- [ ] `CompilationService` 暴露 `static let modelName: String` 和 `static let apiProvider: String` 常量
- [ ] 如果用户使用 DeepSeek 而非 Qwen（MVP 默认），Settings 中注明「⚠️ 当前使用非默认引擎」
- [ ] 构建通过

**Priority:** Should  
**Effort:** S  
**User Impact:** ⭐⭐

---

#### US-015: Archive 月份数据异步加载

**Description:** 作为拥有 6 个月以上数据的用户，打开 Archive 时不应有明显卡顿，calendar grid 应先渲染骨架再填入数据。

**Cross-Referenced By:** PR + AR  
**File refs:** `DayPage/Features/Archive/ArchiveView.swift` L141-150；`DayPage/Features/Archive/ArchiveViewModel.swift`

**Acceptance Criteria:**
- [ ] `ArchiveViewModel.loadMonth()` 改为 `async` 方法，在 `Task { await loadMonth() }` 中调用，不阻塞主线程
- [ ] 加载期间 calendar grid 的每个 day cell 显示 `ProgressView()` 占位（小圆圈）或灰色矩形
- [ ] 月份切换（← /→）时立即显示新月份的 loading 骨架，旧月份数据立即清除
- [ ] 有真实数据时（3+ 个月历史），Archive 打开到渲染完成 < 500ms（iPhone 17 Simulator 测量）
- [ ] 构建通过

**Priority:** Should  
**Effort:** M  
**User Impact:** ⭐⭐⭐

---

#### US-016: 语音附件 Retry 闭环

**Description:** 作为用户，当 Whisper 转写失败后，我应该能在 Today 页面的语音附件 chip 上直接点击「重试」重新发起转写，而不是丢弃录音。

**Cross-Referenced By:** PR + UIUX  
**File refs:** `DayPage/Features/Today/TodayViewModel.swift`；`DayPage/Services/VoiceAttachmentQueue.swift`；`DayPage/Features/Today/InputBarV4.swift`（附件 chip 渲染区）

**Acceptance Criteria:**
- [ ] 语音附件转写失败时，`Attachment` 标记 `transcriptionStatus: .failed`（新增枚举 case）
- [ ] InputBarV4 附件 chip 在 `transcriptionStatus == .failed` 时显示红色边框 + 「↺」重试图标（之前只有红边）
- [ ] 点击重试图标调用 `TodayViewModel.retranscribeVoiceAttachment(id:)`，触发 `VoiceService.transcribeAudio(at:)` 重试
- [ ] 重试中显示 chip 内 `ProgressView()`；成功后 chip 切回正常态 + transcript 显示前 20 字
- [ ] 构建通过，手动测试：断网录音 → 失败红边 → 联网点重试 → 成功

**Priority:** Should  
**Effort:** S  
**User Impact:** ⭐⭐⭐

---

#### US-017: Memo 数据模型补 mood + entity mentions 字段

**Description:** 作为开发者，Memo struct 应内置 `mood` 和 `entityMentions` 字段，为知识图谱的精确双向链接和情绪时间线提供结构化数据基础，而不依赖 AI 编译后的事后提取。

**Cross-Referenced By:** PR  
**File refs:** `DayPage/Models/Memo.swift`；`DayPage/Services/RawStorage.swift`（YAML 解析）

**Acceptance Criteria:**
- [ ] `Memo` struct 新增 `var mood: MoodLevel? = nil`（枚举：.positive/.neutral/.negative/.intense）
- [ ] `Memo` struct 新增 `var entityMentions: [String] = []`（从 body 中 `[[EntitySlug]]` 语法提取的 slug 数组）
- [ ] `RawStorage` YAML 解析器新增 `mood:` 和 `entities:` frontmatter 键支持
- [ ] `TodayViewModel.submitCombinedMemo()` 在写入前从 body 文本提取 `[[...]]` 模式填充 `entityMentions`
- [ ] 向后兼容：旧文件无这两个字段时，解析为 nil/[]，不报错
- [ ] 单元测试：构造含 `[[Tokyo]]` 的 memo body → 验证 `entityMentions == ["Tokyo"]`
- [ ] 构建通过

**Priority:** Should  
**Effort:** M  
**User Impact:** ⭐⭐⭐

---

#### US-018: 批量 HEIC 照片转换移离主线程

**Description:** 作为用户，选择 5 张以上 HEIC 格式照片时，Today 页面不应出现明显卡顿或 UI 冻结。

**Cross-Referenced By:** PR + AR  
**File refs:** `DayPage/Services/PhotoService.swift` L69（`processImageDataAsync` 仍在 MainActor）

**Acceptance Criteria:**
- [ ] `PhotoService.processPickerItem()` 中 HEIC → JPEG 转换移入 `Task.detached(priority: .userInitiated) { }`（脱离 MainActor）
- [ ] 转换完成后通过 `await MainActor.run { }` 回主线程更新 UI 状态
- [ ] 测试：选择 5 张 12MP HEIC 图片，今天 Timeline 动画帧率 ≥ 55fps（Instruments Time Profiler 验证无主线程卡顿 >16ms）
- [ ] 构建通过

**Priority:** Should  
**Effort:** S  
**User Impact:** ⭐⭐

---

#### US-019: Markdown Export（Obsidian 兼容）

**Description:** 作为数字游民用户，我希望能将 DayPage 的 vault 内容一键导出为标准 Markdown 格式（.md 文件打包），兼容 Obsidian 导入。

**Cross-Referenced By:** PR  
**File refs:** `DayPage/Features/Settings/SettingsView.swift`（Data Section）

**Acceptance Criteria:**
- [ ] Settings「数据」Section 新增「导出 Vault」按钮
- [ ] 点击后生成 `daypage-export-YYYY-MM-DD.zip`，包含 `raw/` 和 `daily/` 所有 `.md` 文件，保持目录结构
- [ ] 导出进行中显示 `ProgressView()` + 「正在打包...」文字
- [ ] 完成后弹出系统 Share Sheet（`UIActivityViewController`），允许保存到 Files / AirDrop / 第三方
- [ ] 导出文件中的 YAML frontmatter 格式与 Obsidian 兼容（无自定义语法）
- [ ] 构建通过，iPhone 17 手动验证：导出 → 文件 App 可预览 .md 内容

**Priority:** Could  
**Effort:** M  
**User Impact:** ⭐⭐⭐

---

### Theme D — 技术债务

#### US-020: TodayViewModel 核心路径单元测试

**Description:** 作为开发者，TodayViewModel 的 `submitCombinedMemo()`、`load()`、`compile()` 三条核心路径应有单元测试覆盖，以便重构时有安全网。

**Cross-Referenced By:** AR  
**File refs:** `DayPage/Features/Today/TodayViewModel.swift`；`DayPageTests/`（目前无 ViewModel 测试）

**Acceptance Criteria:**
- [ ] 新建 `DayPageTests/TodayViewModelTests.swift`（Swift Testing）
- [ ] 测试 `submitCombinedMemo()`：纯文字 memo → 验证 RawStorage 写入；语音 memo（mock VoiceService）→ 验证附件字段；location memo → 验证 location frontmatter
- [ ] 测试 `load()`：空 vault → 验证 memos 为空；有 3 条 memo 的文件 → 验证解析正确
- [ ] 测试 `compile()`：mock CompilationService 返回成功 → 验证 `dailyPageModel` 更新；返回失败 → 验证 `compilationFailedError` 设置
- [ ] 至少 12 个 test case，覆盖 happy path + error path
- [ ] 全部测试通过 (`xcodebuild test -scheme DayPage`)

**Priority:** Should  
**Effort:** L  
**User Impact:** ⭐⭐

---

#### US-021: TodayView 拆分子视图

**Description:** 作为开发者，1170 行的 TodayView 应拆分为独立子视图组件，每个文件不超过 300 行，减少 PR 冲突和 AI 辅助编码的上下文窗口压力。

**Cross-Referenced By:** AR + UIUX  
**File refs:** `DayPage/Features/Today/TodayView.swift`（1170 lines）

**Acceptance Criteria:**
- [ ] 提取 `TodayOrbHeaderView`（Day Orb + 日期标题区，约 120 行）到独立文件
- [ ] 提取 `TodayMemoListView`（memo 列表 + SwipeableMemoCard，约 200 行）到独立文件
- [ ] 提取 `LocationDraftCard` + `LocationDraftRow` 到 `DayPage/Features/Today/LocationDraft/` 子目录
- [ ] TodayView.swift 主文件压缩到 ≤ 350 行（只保留布局骨架和 ViewModel 绑定）
- [ ] 无功能改变：拆分前后 iPhone 17 Simulator 截图目视一致
- [ ] 构建通过，现有测试通过

**Priority:** Could  
**Effort:** L  
**User Impact:** ⭐⭐

---

#### US-022: CompilationService.compile() 函数分解

**Description:** 作为开发者，`compile()` 的 152 行单体函数应分解为 5 个职责单一的私有方法，提高可测试性。

**Cross-Referenced By:** AR  
**File refs:** `DayPage/Services/CompilationService.swift` L50-202

**Acceptance Criteria:**
- [ ] 提取 `prepareMemoContext() async throws -> CompilationContext`（读取 raw + hot.md）
- [ ] 提取 `buildPrompt(context:) -> [ChatMessage]`（构建 LLM 消息数组）
- [ ] 提取 `callLLM(messages:) async throws -> String`（API 调用 + 重试）
- [ ] 提取 `parseCompilationOutput(_:) throws -> DailyPageModel`（YAML/Markdown 解析）
- [ ] 提取 `persistResults(_:for:) async throws`（写文件 + entity apply + cache + log）
- [ ] 所有方法有 `// throws: CompilationError.X` 注释
- [ ] 构建通过，编译功能端到端手动测试正常

**Priority:** Could  
**Effort:** M  
**User Impact:** ⭐

---

#### US-023: .trash 备份文件 7 天 TTL 自动清理

**Description:** 作为用户，iCloud Drive 中的 DayPage vault 不应随时间无限增长，每日编译备份应在 7 天后自动删除。

**Cross-Referenced By:** AR  
**File refs:** `DayPage/Services/CompilationService.swift` L201-214（backupIfExists）

**Acceptance Criteria:**
- [ ] 在 `BackgroundCompilationService` 的 `performDailyMaintenance()` 方法中（或新增），扫描 `vault/.trash/` 目录
- [ ] 删除修改时间早于 7 天前的所有 `.md` 备份文件
- [ ] 清理操作在后台 Task 中执行，不阻塞编译主流程
- [ ] 首次运行时若 `.trash/` 超过 50 个文件，记录 warning 日志并触发全量清理
- [ ] 构建通过

**Priority:** Could  
**Effort:** S  
**User Impact:** ⭐

---

### Theme E — AI 能力升级

#### US-024: 编译输出结构化增强 — mood + 日期感知

**Description:** 作为用户，AI 编译的 Daily Page 应包含当天的情绪评估（mood），并在节假日/特殊日期时自动调整叙事语气。

**Cross-Referenced By:** PR  
**File refs:** `DayPage/Services/CompilationService.swift`（`buildPrompt()`）；`DayPage/Models/DailyPageModel.swift`

**Acceptance Criteria:**
- [ ] System prompt 增加：输出 YAML frontmatter 中必须包含 `mood: positive|neutral|negative|intense`
- [ ] `DailyPageModel` 新增 `var mood: MoodLevel?` 字段（与 US-017 共用枚举）
- [ ] `DailyPageView` 在标题下方显示 mood 情绪指示器（小彩色圆点，4 种颜色对应 4 种 mood）
- [ ] 编译 prompt 注入当天日期（包括星期）：`今天是 {weekday}，{date}`，让 LLM 感知是否周末/工作日
- [ ] 单元测试：mock LLM 返回含 `mood: positive` 的输出 → 验证 `DailyPageModel.mood == .positive`
- [ ] 构建通过

**Priority:** Could  
**Effort:** M  
**User Impact:** ⭐⭐⭐

---

#### US-025: Entity Slug 去重与模糊匹配

**Description:** 作为用户，当 AI 先后生成 `joma-coffee` 和 `joma_coffee` 两个变体时，知识图谱不应产生重复节点，而应合并到同一 entity 页面。

**Cross-Referenced By:** PR  
**File refs:** `DayPage/Services/EntityPageService.swift` L50-76

**Acceptance Criteria:**
- [ ] `EntityPageService` 在 `apply()` 前执行 slug 归一化：小写、`_` → `-`、移除特殊字符
- [ ] 归一化后若目标文件已存在，执行 update 而非 create（现有逻辑需调整）
- [ ] 可选：实现编辑距离 ≤ 2 的模糊匹配（Levenshtein），自动合并近似 slug（作为增强项，可分拆 PR）
- [ ] 单元测试：`apply(slug: "joma_coffee")` + `apply(slug: "joma-coffee")` → wiki 目录中只有 1 个文件
- [ ] 构建通过

**Priority:** Could  
**Effort:** M  
**User Impact:** ⭐⭐

---

## 5. 发布计划

### v7.0 — Critical Fix（目标：2 周内）

**Theme A 全部 + P0 核心**

| US | 标题 | 负责方向 | 工期 |
|---|---|---|---|
| US-001 | 立即轮换全部 API Key | 安全 | 1天 |
| US-002 | API Key → Keychain | 安全 | 2天 |
| US-003 | NotificationCenter 观察者修复 | 并发 | 0.5天 |
| US-004 | Task 体补 @MainActor | 并发 | 0.5天 |
| US-005 | atomicWrite 临时文件清理 | 存储 | 0.5天 |
| US-012 | Graph Tab 接通真实数据 | 功能 | 2天 |

**交付物：** 安全问题清零；Graph Tab 有真实数据可用；并发 bug 修复。

---

### v7.1 — Polish（目标：v7.0 后 2 周）

**Theme B + C 高优先级**

| US | 标题 |
|---|---|
| US-006 | InputBarV4 字体 token 对齐 |
| US-007 | Dynamic Type 全局支持 |
| US-008 | A11y 按钮 label + tap target |
| US-009 | Loading 指示器（3场景） |
| US-013 | Entity 双向链接 |
| US-014 | AI 引擎透明化 |
| US-015 | Archive 异步加载 |
| US-016 | 语音 Retry 闭环 |

**交付物：** UI 一致性显著提升；Accessibility 基线达标；Archive 流畅；Entity 双向链接上线。

---

### v7.2 — Feature（目标：v7.1 后 3 周）

**Theme C 全部 + Theme D 测试**

| US | 标题 |
|---|---|
| US-017 | Memo 数据模型补字段 |
| US-018 | 批量 HEIC 异步转换 |
| US-019 | Markdown Export |
| US-020 | TodayViewModel 单元测试 |
| US-010 | 动效 Token 补全 |
| US-011 | 硬编码字符串 → L10n |

**交付物：** 数据模型增强；Obsidian 导出；测试覆盖率提升。

---

### v7.3 — Deepen（目标：v7.2 后 4 周）

**Theme D 重构 + Theme E AI 升级**

| US | 标题 |
|---|---|
| US-021 | TodayView 拆分子视图 |
| US-022 | CompilationService 函数分解 |
| US-023 | .trash 备份 TTL 清理 |
| US-024 | 编译输出 mood + 日期感知 |
| US-025 | Entity Slug 去重 |
| US-023 | UserDefaults runtime key → Keychain |
| US-021 | LocationDraftCard 错误 UI |

**交付物：** 代码库健康度显著提升；AI 输出质量增强；Entity 数据质量保障。

---

## 附录 A — 被标记为 Won't Do（v7 范围外）

| US | 原因 |
|---|---|
| Tag 系统（Memo struct + Archive 过滤） | 工作量 XL，需要数据模型迁移 + UI 重设计，列入 v8 |
| 骨架屏（Calendar / Daily Page / Timeline） | 与 Archive 异步加载（US-015）有重叠，待 US-015 完成后评估必要性 |
| ArchiveView 拆分子视图 | 需要在 TodayView 拆分（US-021）完成后复用经验，避免返工 |

---

## 附录 B — 文件路径速查

| 文件 | 功能 | 主要涉及 US |
|---|---|---|
| `DayPage/Config/GeneratedSecrets.swift` | API Key 存储（⚠️已泄露） | US-001, US-002 |
| `DayPage/Config/SecretsRuntime.swift` | 运行时 Key 读取 | US-002 |
| `DayPage/Features/Today/TodayViewModel.swift` | 核心 ViewModel（963行） | US-003, US-004, US-016, US-020 |
| `DayPage/Features/Today/TodayView.swift` | 主视图（1170行） | US-004, US-008, US-011, US-021 |
| `DayPage/Features/Today/InputBarV4.swift` | 输入栏（1052行） | US-006, US-009, US-010 |
| `DayPage/Features/Today/SwipeableMemoCard.swift` | 卡片滑动组件 | US-010 |
| `DayPage/Features/Graph/GraphView.swift` | 力导向图（380行） | US-012 |
| `DayPage/Features/Graph/GraphViewModel.swift` | 图谱 ViewModel | US-012 |
| `DayPage/Features/Archive/ArchiveView.swift` | 归档视图（1264行） | US-015, US-018 |
| `DayPage/Features/Entity/EntityPageView.swift` | Entity 详情页 | US-013 |
| `DayPage/Services/CompilationService.swift` | AI 编译（693行） | US-004, US-014, US-022, US-024 |
| `DayPage/Services/EntityPageService.swift` | Entity CRUD | US-012, US-013, US-025 |
| `DayPage/Services/VoiceService.swift` | 语音录制+转写 | US-016 |
| `DayPage/Services/PhotoService.swift` | 照片处理 | US-018 |
| `DayPage/Services/RawStorage.swift` | 文件读写 | US-005, US-017 |
| `DayPage/Models/Memo.swift` | 核心数据模型 | US-017 |
| `DayPage/DesignSystem/Typography.swift` | 字体 Token | US-006, US-007 |
| `DayPage/DesignSystem/Motion.swift` | 动效 Token | US-010 |
| `DayPage/Services/BackgroundCompilationService.swift` | 后台编译 | US-023 |
| `DayPage/Services/KeychainHelper.swift` | Keychain 工具 | US-002 |
