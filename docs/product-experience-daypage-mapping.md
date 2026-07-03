# DayPage 版 Product Experience Backlog 映射

> 输入：docs/product-experience-issue-backlog.md（面向 Telepace/Nexus Web 产品）
> 输出：将 20 条通用体验 issue 映射到 DayPage（iOS 16+ SwiftUI，vault/raw/**/*.md 存储，Aliyun DashScope 编译）的具体 View/Service + 验收标准 + iPhone 17 模拟器验证脚本。
> 用途：Task #56-#75 每一轮 "改码 → 构建 → 模拟器截屏 → gan-evaluator 打分 → 修补 → 满分" 的 SoT。

## 通用打分标准（所有 issue 复用）

每条 issue 打分满分 100，分四个维度：

| 维度 | 权重 | 满分判据 |
|---|---|---|
| 正确性 Correctness | 40 | 功能按验收标准 100% 可用；错误路径也被覆盖 |
| 完成度 Completeness | 30 | 验收标准每一条都在模拟器截图可验证 |
| 审美 Aesthetic | 20 | 符合 CLAUDE 审美（warm-cream #F5F1EA / Space Grotesk / 呼吸留白 / 无 AI slop） |
| 健壮性 Robustness | 10 | 空态/断网/超长输入/最小字号+最大字号+SE 屏都不崩 |

验收阈值：≥ 95/100 视为满分通过。< 95 按 gan-evaluator 建议改，重新打分。

## 20 条映射

### Issue 1 · 首屏价值主张
- 映射：`DayPage/Features/Onboarding/OnboardingView.swift` + `WelcomeScreen.swift` + Today 空态 hero
- 改造：3 屏文案（结果导向 + 目标用户 + 3 收益点）；Today 0 memo 时顶部 hero + 双 CTA（试用示例 / 写第一条）
- 验收：全新 container 首启 5 秒内看到 hero + 3 收益点 + 双 CTA
- 验证：`xcrun simctl erase → boot → install → launch → screenshot after 5s`

### Issue 2 · Demo + 空态引导
- 映射：`DayPageKit/Sources/DayPageServices/SampleDataSeeder.swift`（已存在）+ Today 空态 CTA
- 改造：审计 SampleDataSeeder 覆盖 3 条 memo（文本+照片+语音转写）+ 1 份 daily + 1 个 entity；空态"试用示例"按钮 → 一键 seed + 3 秒淡入
- 验收：新用户点 CTA → Timeline 3 条 demo + Daily 可查看
- 验证：erase → 启动 → 点试用示例 → 3 秒内 3 条 memo 上屏 → 开 Daily

### Issue 3 · 统一导入中心（Composer 多入口）
- 映射：`DayPage/Features/Today/InputBarV4.swift` + `AttachmentMenuPopover.swift`
- 改造：确认 6 入口全部可用：文本、语音、照片、位置、PDF/文件、URL
- 验收：每个入口都能产出正确附件
- 验证：逐个点击 attachment menu，观察 memo yaml 附件字段

### Issue 4 · AI 输出证据链
- 映射：`DayPageKit/Sources/DayPageServices/CompilationService.swift` + `WeeklyCompilationService.swift` + `MemoDetailView.swift` 跳转
- 改造：输出结构升级，每条 highlight/insight 附 `sources: [memoID]`；Daily/Weekly 洞察卡加"引用 N 条" chip → 展开 → 跳转
- 验收：Daily 打开洞察 → 显示引用 memo → 点击跳转到对应 memo
- 验证：给 sample day 触发编译 → 随机洞察点跳转 → 目标 memo 匹配

### Issue 5 · 编译进度反馈
- 映射：`DayPage/Services/BackgroundCompilationService.swift` + Today 顶部 banner
- 改造：加 `@Published var stage: CompileStage`（collect/clean/cluster/generate/link）+ Today 顶部动画进度 banner
- 验收：编译时 banner 分阶段推进；后台运行不丢失；完成本地通知
- 验证：手动触发编译 → 录屏观察阶段 → 切后台 → 通知到达

### Issue 6 · 错误提示可操作化
- 映射：新建 `DayPage/Features/Shared/ErrorPresenter.swift` + 审计所有 alert
- 改造：统一 `AppError { title, reason, primary, secondary }`
- 验收：断网触发编译失败 → 三段结构 + 重试按钮
- 验证：`NetworkMonitor.simulateOffline = true` 触发 compile → 截屏

### Issue 7 · Vault 信息架构
- 映射：`DayPage/Features/Archive/ArchiveView.swift` 顶部加 stat 卡
- 改造：显示总 memo 数 / 总日数 / Top 5 实体 chips
- 验收：Archive 一屏内可看全景
- 验证：sample 数据下 archive 头部截图

### Issue 8 · 洞察到行动闭环
- 映射：Daily / Weekly / EntityPage 洞察卡加 context menu：变成待办 / 加到明日重点 / 生成复盘题
- 改造：新建 `DayPage/Services/InsightActionService.swift`，落回 `vault/raw/YYYY-MM-DD.md`（明日日期）为待办 memo
- 验收：Weekly 洞察 → 变待办 → 明日 Today 出现 todo memo
- 验证：Weekly → 长按洞察 → 变待办 → 切明日 → 可见

### Issue 9 · AI 复盘题（周问卷）
- 映射：`WeeklyCompilationService.swift` 输出 `reflectionQuestions: [String]`；`WeeklyRecapDetailView` 加"本周 5 问"
- 验收：Weekly 显示 3-5 题；点题目进入回答 sheet；提交生成 memo
- 验证：跑周编译 → 答一题 → Today 出现回答 memo

### Issue 10 · 报告导出（Markdown + 图卡）
- 映射：`DayPage/Services/MarkdownExportService.swift`（已存在）+ Daily/Weekly 右上分享
- 改造：审计现状；加 SwiftUI ImageRenderer 生成 warm-cream 分享图卡
- 验收：分享 → Markdown 走 share sheet；图片选项生成并可存相册
- 验证：Daily → 分享 → 生成图 → 存相册 → 验证

### Issue 11 · 自我对话（追问过去）
- 映射：`DayPageKit/Sources/DayPageServices/MemoryChatService.swift`（已存在）+ `AskPastView.swift`（已存在）+ `MemoDetailView.swift` 底部加追问入口
- 验收：打开老 memo → 追问 → 得回答 → 回答存为新 memo 并双向链接
- 验证：打开 memo → 追问 → 观察回答 + 新 memo 生成

### Issue 12 · 隐私与数据说明
- 映射：Onboarding 加隐私屏 + `SettingsView.swift` 数据与隐私 section
- 改造：Onboarding 第 2 屏"你的数据只属于你"；Settings 加"导出全部 vault (zip)"（复用 `VaultExportService.swift`）
- 验收：首启看到；Settings 一键导出
- 验证：首启截图；Settings → 导出 → 得到 zip

### Issue 13 · AI 可控性（今日焦点）
- 映射：`ComposerContextProvider.swift` + Today 顶部 focus chip + `CompilationService.swift` prompt 注入
- 改造：Today 顶部 chips：工作/情绪/健康/关系/学习；写入日 md frontmatter 的 focus 字段；CompilationService 读取
- 验收：选情绪 → 触发编译 → daily.md 偏情绪
- 验证：设 focus → 编译 → 开 Daily → 关键词偏情绪

### Issue 14 · 孤峰质量校验
- 映射：`WeeklyCompilationService.swift` 输出 `outliers: [MemoRef]`；`WeeklyRecapDetailView` 加"值得回看的孤峰"
- 改造：加打分（长度 > median × 2 或 深夜或 情绪词密度高）
- 验收：Weekly 看到 outliers 且非最高频
- 验证：多样 sample → 跑周编译 → Weekly 有 outliers

### Issue 15 · 小屏 + Dynamic Type
- 映射：审计 TodayView / ArchiveView / MemoDetailView / GraphView 在 iPhone SE (3rd) 375pt + `.dynamicTypeSize(.accessibility3)`
- 改造：修所有溢出 / 截断 / 按钮遮挡
- 验收：SE + AX3 无遮挡；主 CTA 可点
- 验证：模拟器切 SE + environment override dynamicTypeSize → 逐页截屏

### Issue 16 · 全局搜索
- 映射：`DayPageKit/Sources/DayPageServices/SearchService.swift`（已存在，审计）+ 侧边栏 / Today 顶部 search field
- 改造：确认覆盖 memo/entity/daily/weekly；按类别分组；GraphRetriever 语义
- 验收：搜"付费" → 命中并按类别分组显示
- 验证：sample 中含关键词 → 搜 → 截图

### Issue 17 · Composer 模板
- 映射：`DayPage/Features/Today/SmartTemplateRow.swift`（已存在）扩充 5 模板：晨间/晚间/情绪/旅行/健康
- 验收：点模板 → Composer 出现引导句 → 填完存 memo
- 验证：点模板 → 截屏 → 保存

### Issue 18 · 埋点看板
- 映射：新建 `DayPageKit/Sources/DayPageServices/AnalyticsService.swift`（本地 JSONL）+ Settings 加调试看板页
- 改造：核心事件 memo_created / compile_started / compile_completed / detail_opened / share_created / search_used；看板显示今日 + 最近 100 条
- 验收：跑主流程 → 看板事件齐全
- 验证：触发主流程 → 打开看板 → 截图

### Issue 19 · 中文语境
- 映射：`CompilationService.swift` prompt + `CJKTextPolish.swift` + `GraphRetriever` 分词
- 改造：system prompt 加"引用原文时保留原句"；GraphRetriever 加中文分词兜底
- 验收：中英混合 memo 编译输出中文原句准确
- 验证：中文 sample memo → 编译 → daily.md 原句匹配

### Issue 20 · AI 用量透明
- 映射：`LLMClient.swift` 加 usage 统计；Settings 加 AI 用量页
- 改造：LLMClient 每次记录 tokenIn/tokenOut 到 UserDefaults；Settings 页日/月累计 + 上限；到 80% Banner
- 验收：多次编译 → 数字增长；设 100 上限触发 80 提醒
- 验证：跑几次编译 → Settings 看数字；调低上限 → 触发 banner

## 打分工具链（分层验证策略）

**每个 issue 都做**（轻量层）：
1. 单元测试或 SwiftUI Preview 测通
2. `xcodebuild -scheme DayPage build` 保持绿
3. 我 review 打分对照验收标准 → 若 < 95 立即改

**每完成 5 个 issue + 最后 1 个（共 4 次）**（重量层）：
1. `xcodebuild -scheme DayPage -destination 'platform=iOS Simulator,name=iPhone 17' build`
2. `xcrun simctl install booted <app.app>` + `xcrun simctl launch booted com.daypage.app`
3. 按 5 条 issue 验证脚本跑主流程
4. `xcrun simctl io booted screenshot` 关键节点截屏
5. gan-evaluator agent 打分（截图 + 验收 + diff），输出 `{score, blockers, suggestions}`
6. 任何一条 < 95 → 按 blockers/suggestions 改码 → 回步骤 1
7. 满分记入 `docs/product-experience-daypage-scorecard.md`
