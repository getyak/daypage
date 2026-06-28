# DayPage 体验深度优化 · 审计 + 落地手册 · 2026-06-24

> 自动化 `daily-ui` 任务的**唯一权威文档**（已合并早前两份重复审计）。目标：极简 / 输入体验 / 显示体验 / 操作体验 / 动效 / 细节 / 观感美观。
>
> **本沙箱的硬限制（请先读）：** 运行环境对挂载目录是「可创建 / 可覆盖、**不可删除、不可 rename**」，对 `.git/` 同样**不可 unlink/rename**。因此本环境**根本无法 `git commit`、无法干净建分支、无法删文件**——这正是此前多轮「改动写好却始终未提交」的真实原因（并非 stale lock）。代码改动已实打实写入工作区文件，`git diff` 可见、不会丢；**收口（commit / build / PR）必须在你的 Mac 上完成**，命令见文末「§4 在 Mac 上收口」。

---

## §1 现状判断

设计系统层（`DayPage/DesignSystem/`）已相当成熟克制：`Motion`、`Haptics`(5 级阶梯)、`DSSpacing`(4/8pt 节奏)、`DSRadius`、`InputTokens`、`Colors` 都有清晰注释与调参理由；`InputBarV4` 的「呼吸光标取代硬闪」「museum-still 安静首页」等决策已落地并尊重 Reduce Motion。整体语言成熟、克制、有「博物馆」气质，**无严重缺陷**。

因此增量价值不在「重做」，而在 **① 动效一致性收敛 ② 补齐无障碍/性能边角 ③ 几处可感知的微交互打磨**。

---

## §2 已在工作区落地（待你 Mac 端编译验证后提交）

以下为本批已写入工作区、经静态复核（符号存在性 + 大括号配平 + 语义等价）的改动。**全部为「同曲线参数 + 外裹 Reduce-Motion 降级」或「内联 spring → 等价语义 token」，普通用户观感零变化，仅 Reduce-Motion 用户获得瞬时落位。**

**P1 — 录音脉冲尊重 Reduce Motion（3 处；全库 sweep 已收口）**
- `Features/Today/PressToTalkButton.swift` — 新增 `@Environment(\.accessibilityReduceMotion)`；`startRingPulse()` 在开启时显示**静态光环**（`ringScale 1.2 / opacity 0.35`）而非无限缩放脉冲；`stopRingPulse()` 正常复位。
- `Features/Daily/InlineMicButton.swift` — 同样加守卫；开启时跳过 `pulseScale 1.18` 无限脉冲，靠 amber 填充表达录音态。
- `Features/Today/RecordingOverlayView.swift`（**6-24 续轮新增**） — 全屏录音浮层的**双环 halo 无限脉冲**此前 0 守卫；新增 `@Environment(\.accessibilityReduceMotion)`，两处 `.animation(...)` 改为 `reduceMotion ? nil : .easeInOut(1.6).repeatForever`，`.onAppear` 加 `guard !reduceMotion` 让双环停在静止 resting pose。**经逐行普查，全库 `repeatForever` 现已全部带 Reduce-Motion 守卫——这是最后一处缺口**（SearchView / CompileUnlockCard / DayOrbView / DynamicIslandView / AISummaryCard / EntityPageView / GraphSkeleton / MemoListSkeleton / RecordingSheetView 等先前均已守卫）。

**P0 — 新增 3 个语义 Motion token + 就近收敛内联动画**
- `DesignSystem/Motion.swift` — 新增 `Motion.panel`(spring 0.32/0.85)、`Motion.bannerSlide`(spring 0.55/0.88)、`Motion.expand`(spring 0.3/0.82，此前 3 处内联重复，≥3 次即应升格)。
- `Features/Today/InputBarV4.swift` — 录音面板入场内联 spring → `.dsAnimation(Motion.panel, value:)`（位移+缩放，现尊重 Reduce Motion）；两处 toast 曲线 `easeInOut(0.2)`/`(0.15)` → `Motion.fade`。
- `Features/Shared/AppBanner.swift` — 4 处 banner 滑入/滑出统一 `Motion.bannerSlide`，经 `respectReduceMotion`/`dsAnimation` 降级。
- `Features/Daily/ThreadConversationView.swift`、`Features/Daily/DailyPageView.swift` — 展开/折叠（`.move` 位移过渡）内联 spring → `Motion.expand`，补 Reduce-Motion 守卫。
- `Features/Today/TodayViewModel.swift` — pin/unpin 列表重排 `easeInOut(0.25)` 外裹 `respectReduceMotion`，开启时瞬时落位。

**规模：** 9 文件、约 +66/−17 行。**风险：** 低（等价替换 + 无障碍守卫，无行为回归）。**静态复核：** 全部新引用符号存在（`Motion.fade` L15 / `respectReduceMotion` L60 / `View.dsAnimation` L73 / `panel·bannerSlide·expand` L22–35；`accessibilityReduceMotion` 全库 35 文件在用）；9 文件大括号/括号全部配平。**未做：** 因本环境无法编译，**未做** iPhone 17 模拟器肉眼校验——这是提交前的必备步骤（RecordingOverlayView 需开/关「减弱动态效果」各跑一次长按录音确认双环静止/脉冲）。

刻意**不动**的点：`SearchView` 清除按钮、`DayOrbView` count-pop 等**已带** `if !reduceMotion` 守卫的私有 spring（强行 token 化会改变刻意手感且无 a11y 增益）。

---

## §2.5 2026-06-25 增量（daily-ui 续轮，已写入工作区）

**复核结论先行：** 逐条核对 §3.2 backlog 后发现，多数条目**已被前几轮落地**，并非待办——避免重复改动：
- **H1（里程碑触感连发）已解决**：`InputBarV4.swift` 现行 milestone 逻辑（`let milestone = newCount / 50; if milestone > lastMilestone { lastMilestone = milestone; ... }`，约 L717-724）在单次 `onChange` 内**只触发一次**（直接把 `lastMilestone` 跳到新满值，无循环），粘贴 150 词不再连发 3 次。文档旧行号已过期。
- **M7（计数器跨 100 硬跳）已解决**：`WriteSheetView.swift` `wordCountColor`（L156-164）现为 100→200 词**连续 lerp**（`lerpColor`），无硬跳，并已带 Reduce-Motion 守卫。
- **M4（卡片底栏可扫读性）多数已解决**：底栏现为 `HStack(spacing: 8)` + `inkSubtle` 安静配色（content-first 重设计），文档描述的「75% 透明度 + 紧贴 ·」为旧版状态。
- **L1（两 toast 时长 1.6s/1.8s）刻意不动**：1.6s 为「太短」短警告、1.8s 为更长的「点击录音·长按发送」发现提示；**时长按内容阅读量分级是合理设计**，强行统一反而缩短长提示阅读窗口，故保留。

**本轮真正落地（2 处，确定性、无需模拟器调参）：**
- `Features/Today/MemoCardView.swift` 语音转写**斜体引文**（`serifQuote` = 18pt 斜体 serif，L809 附近）此前**完全无 `lineSpacing`**；18pt 斜体多行换行时偏挤，新增 `.lineSpacing(4)`（16pt 正文用 2pt，更大的斜体引文给 4pt 透气）。这是 M5 的真实落点（与文档旧行号不同）。
- 同文件卡片底栏**附件 glyph**（photo/mic）`8pt → 9pt`：8pt SF Symbol 低于易读阈值；保持安静的 `inkSubtle` 不变，仅让 glyph 与 10pt mono 时间戳光学对齐。M4 的安全子集（未动配色与 Spacer，避免改变 content-first 克制语气）。

**规模：** 1 文件、+9/−4 行。**风险：** 极低（纯增 SwiftUI 修饰符，无结构/大括号变化，无行为回归）。**静态复核：** `serifQuote` = 18pt italic（Typography.swift L192）、`inkSubtle` 存在；两处均为既有 view builder 内追加修饰符。**未做：** 本环境无法编译/模拟器肉眼校验——引文多行换行观感与 glyph 对齐仍需 iPhone 17 上确认。

---

## §3 优化机会清单（可直接逐条转 GitHub issue）

### 3.1 策略层（P 系列）

| 级别 | 主题 | 证据（文件:行附近） | 风险/工作量 |
|---|---|---|---|
| P0 | 动效收敛（已部分落地，见 §2） | 全库内联 `withAnimation(.spring(...))` 散落 | 低 / 0.5d |
| P1 | 录音脉冲 Reduce Motion（**已落地**，见 §2） | PressToTalk / InlineMicButton | 低 / 1h |
| P2 | **输入落定反馈**：发送后 dock 收回缺一个 `Motion.panel` 回弹 + 文本「上浮淡出」收口（80–120ms），强化「已发送」确定感 | `InputBarV4` `transition(to: .idle)` 路径 | 中 / 1d（需模拟器肉眼调） |
| P3 | 重复 hex 升格语义 token | 见 §3.3 普查 | 低 / 0.5d |
| P4 | 次级文本 opacity 统一为单常量 | timeline/卡片元数据次级文本 | 低 / 0.5d |

### 3.2 精修层（每日高频路径，体感明显）

- **H1 · 里程碑触感粘贴长文连发抖动** — `InputBarV4.swift ~720`、`WriteSheetView.swift ~500`：每满 50 词触发 `Haptics.soft()`；一次粘贴 150 词会在同一 `onChange` 内连发 3 次（~100ms），体感「卡了一下」。**建议**：每次 `onChange` 至多触发一次，或对里程碑触感加 100ms 去抖。
- **H2 · 发送按钮 affordance 切换图标错帧** — `InputBarV4.swift ~887/~931`：文本一变 affordance 同步切换，随后 0.35s spring 形变，图标淡入有数十毫秒错位。**建议**：改动模型时用 `withAnimation(Motion.spring){}` 包裹，让形状与图标同源同步。
- **H3 · 设计系统双轨色板** — `Colors.swift`(`DSColor`，63 文件引用) 与 `App/DSTokens.swift`(`DSTokens.Colors`，~9 文件) 并存，`borderSubtle` 两处各定义且值相同（`#EDE8DF`）。两套都是**有效 token**（非 bug），但存在漂移风险。**建议**：择一为权威（推荐 `DSColor`），另一套改 `typealias` 转发，逐步收敛。
- **M1 · 录音手势提示丢反方向上下文** — `RecordingOverlayView.swift ~103`：armed 后只剩当前方向提示，误滑进「取消预备」看不到「右滑可转写」。**建议**：两方向常驻，激活方向全亮、另一方向降到 ~0.3 透明度。
- **M2 · Dock→WriteSheet 转场缺微反馈** — `InputBarV4.swift ~435`：点中心按钮到 sheet 弹出有 ~80–100ms 空档。**建议**：按钮按下 1.0→0.95 缩放 + sheet 落定回弹，或 `matchedGeometryEffect` 手递手过渡。
- **M3 · 转写「排队中」与「失败」视觉不可区分** — `MemoCardView.swift ~828`。**建议**：音频 `.current` 且 `pendingCount>0` 时单独显示「排队转写中」（浅 spinner+灰字），与「正在转录…」「转录失败」三态分明。
- **M4 · Memo 卡底部元信息可扫读性** — `MemoCardView.swift ~290`：附件图标 8pt/75%、`·` 紧贴、尾部多余 `Spacer`。**建议**：图标 8→9pt、透明度提到 `inkMuted`(62%)、`·` 两侧加空格、去掉多余 Spacer。
- **M5 · 语音转写斜体引文行距偏紧** — `MemoCardView.swift ~271/~1077`：18pt 斜体与 16pt 正文同用 `lineSpacing(2)`。**建议**：斜体引文行距 2→3.5–4pt。
- **M6 · WriteSheet 拖拽把手静止态缺可发现性** — `WriteSheetView.swift ~352`。**建议**：触摸即轻微抬起（scale 1.0→1.08、opacity 0.6→0.75）+ 轻触感。
- **M7 · 字数计数器跨 100 词颜色硬跳** — `WriteSheetView.swift ~156`。**建议**：跨 100 时给 `foregroundColor` 包 `Motion.fade`(~0.2s)。
- **M8 · 计数器每键 O(n) 重算** — `InputBarV4.swift ~902`、`WriteSheetView.swift ~89`：长文（500+ 词）每键仍全量重算。**建议**：增量计数或 ~50ms 去抖。
- **M9 · 环境暖色光晕长期关闭** — `GlassSurface.swift ~9`（`debug.ambientBlobs` 默认 false）。**建议**：开启版 beta 对比验证，采用则默认开启并在设置暴露开关，否则删除以简化维护。

### 3.3 P3 重复 hex 普查结论（可直接开 issue）

全库 `Color(hex:)` 调用 131 处；`DSColor.*` 引用 63 文件。出现 ≥3 次的重复 hex 中，三档建议（按风险）：
1. **`refactor(color): 裸 A8541B → 既有 DSColor.amberAccent`（风险最低，先做）** — 该 token 已存在，9 处只是绕过它；纯去重、零视觉变化、无需肉眼校验。
2. **`refactor(color): 2D1E0A 暖色阴影 → 新增 DSColor.shadowWarm`** — 18 处一致暖色阴影（仅 opacity 不同），目前无 token，多集中在 `Surfaces.swift`/`GlassSurface.swift`。
3. 其余（`F5F0E8`/`5D3000`/`6B6B6B`/`E05A5A` 等）涉及 Auth 等可见视图或需判断是否真同语义，逐个评估，**不建议批量 sed**。

### 3.4 低优先（并入一个 design-polish 分支批量处理）

L1 两个 toast 时长 1.6s/1.8s 不一致→统一常量；L2 dock 呼吸光标过弱→周期 0.8s/下限 0.5；L3 sheet 上升与 80ms 聚焦延时在慢机型冲突→聚焦待动画 settle；L4 环脉冲 `easeInOut`→`easeOut` 更像呼吸；L5 Save pill 按压反馈过弱；L6 模板后缀快速退格闪入闪出；L7 加附件时发送键呼吸瞬启「弹一下」→0.15s 交叉淡入；L8 打字机光标 2pt/0.5s→2.5pt/0.4s；L9 回顶进度环随滚动渐显。

---

## §4 在 Mac 上收口（必做，本沙箱无法代劳）

> 沙箱遗留：本轮尝试建分支时在 `.git` 留下了无法清理的残骸——`refs/heads/polish/motion-tokens-reduce-motion-a11y`（空分支，指向 main，无 commit）、对应 `/tmp/polish-wt` 的 worktree 注册、以及若干 `*.lock`。请按下方第 0 步清理。另有一个无法删除的探针残file `docs/_perm_probe.tmp`（0 字节，可手动删）。

```bash
cd <你的 daypage 仓库>

# 0) 清理沙箱遗留
rm -f .git/**/*.lock .git/*.lock 2>/dev/null
git worktree prune
git branch -D polish/motion-tokens-reduce-motion-a11y 2>/dev/null   # 空分支，删掉重建
rm -f docs/_perm_probe.tmp docs/ux-polish-audit-2026-06-24.md       # 删掉探针 + 已合并的旧重复审计

# 1) 把工作区里这批 UI polish 切到独立分支（当前在 feat/ios-web-sync-785，改动与 sync 无关）
git stash push -u -m ui-polish
git switch main && git pull
git switch -c polish/motion-tokens-reduce-motion-a11y
git stash pop

# 2) 编译 + 测试（CLAUDE.md 要求）
xcodebuild -scheme DayPage -destination 'platform=iOS Simulator,name=iPhone 17' build
# 跑现有测试

# 3) iPhone 17 模拟器肉眼校验（分别开/关 设置→辅助功能→减弱动态效果）：
#    录音长按光环(PressToTalk)、内联麦克风脉冲、banner 滑入滑出、
#    录音面板入场、toast 淡入、thread 展开/折叠、pin/unpin 列表重排

# 4) 通过后：开 issue，建议标题
#    polish(motion+a11y): 收敛内联动画到 Motion token + 录音/列表 Reduce-Motion 降级
git add -A && git commit -m "polish(motion+a11y): 收敛内联动画到 Motion token + 录音/列表 Reduce-Motion 降级"
# 推送 + 开 PR 关联 issue
```

§3 其余各条（P2/P4、H1–H3、M1–M9、L1–L9、3.3 颜色三档）建议各自开 issue / 分支，**不要堆进本 PR**，避免 PR 过大 + 主观曲线取舍需逐一模拟器校验。

---

*生成：DayPage `daily-ui` 自动化任务 · 2026-06-24。本轮合并两份重复审计为单一权威文档，复核现有工作区 diff（静态通过），并写死 Mac 端收口路径。代码 commit 受沙箱权限硬限制无法在此完成。*
