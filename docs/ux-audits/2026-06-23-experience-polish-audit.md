# DayPage 体验深度优化审计 — 2026-06-23

> 自动化「daily-ui」任务产物。目标：以极简为原则，优化 **输入体验 / 显示体验 / 操作体验**，打磨动效、细节、观感与美观。
>
> 本文档为**讨论与 Issue 草案**，不直接改码。按 `CLAUDE.md` 约定，设计改动须先讨论 → 开 Issue → 分支实现 → 测试 → PR。每条均给出文件位置、现状、具体优化（含数值）、影响与工作量。
>
> 审计范围：`DayPage/Features/Today/*`、`DayPage/DesignSystem/*`、`DayPage/Features/Archive/*`、`DayPage/App/*`。

---

## 一、本轮最高优先级（建议优先开 Issue）

这五项要么是无障碍合规、要么是「低成本高观感」收益，且与本次「极简 + 输入体验」主题最契合。

### P0-1 · 集中化弹簧/时长 token，消除全局动效不一致 〔影响 高 / 工作量 低〕
现状：全代码库散落 **15 种 spring `response`（0.18–0.55）**、**12 种 `dampingFraction`（0.5–0.9）**，以及多个 ad-hoc `.easeOut(0.25/0.5)`。同一类交互（如按钮按压）在不同文件取不同值；`DSPicker` 的展开 `0.35/0.85` 与收起 `0.3/0.9` 甚至不对称。

优化：在 `DesignSystem/Motion.swift` 增设语义化 token 并全量替换调用点：
- `Motion.buttonPress = .spring(response: 0.25, dampingFraction: 0.82)`（统一 0.8/0.85 两派）
- `Motion.panelToggle = .spring(response: 0.32, dampingFraction: 0.85)`（picker/面板开合同一曲线）
- `Motion.pulseCapture = .spring(response: 0.20, dampingFraction: 0.60)`（计数/pop 等高频反馈）
- `Motion.swipeSnap = .spring(response: 0.28, dampingFraction: 0.86)`（导出 `SwipePhysics` 现值）
- 合并 `fade(0.18)` 与 `dismiss(0.22)` → 统一 `dismiss = 0.20`；为 `CompileUnlockCard` 的 pop 增设 `Motion.popConfirm = .spring(response: 0.18, dampingFraction: 0.60)`。

收益：观感统一、未来调参一处改全局。约 20 行新增 + 30 处替换。

### P0-2 · 补齐 Reduce Motion 无障碍覆盖 〔影响 高 / 工作量 中〕
现状（合规缺口）：
- `Interactions.swift` `PressableCardModifier`：`scaleEffect(0.98)` **始终应用**，关掉动效仍有跳变。
- `RecordingOverlayView.swift`：双环 `.easeInOut(1.6).repeatForever()` **未判断** `reduceMotion`，前庭敏感用户会持续看到运动——属违规。
- `DayOrbView.swift`：`capturePulse` 的 `scaleEffect(1.10)` 无 guard。

优化：
- `PressableCardModifier`：`if !reduceMotion { scaleEffect(0.98) }`，关掉时整体跳过而非瞬时缩放。
- `RecordingOverlayView`：`onAppear` 脉冲前加 `guard !reduceMotion else { return }`。
- `DayOrbView`：缩放包进 `if !reduceMotion`。
- 在 `Motion.swift` 提供 `animatedScale(_:to:when:)` 复用 helper。
建议在开启 Reduce Motion 的真机上验收。

### P0-3 · 写入页键盘聚焦的两段式延迟 〔影响 高 / 工作量 中〕
现状：`WriteSheetView.swift` L209–215 在 `onAppear` 后 `Task.sleep(80ms)` 再 set focus。Sheet 已升起但光标晚 ~100ms 出现，产生「升起→再聚焦」的两段感，直接拖慢「快速记一笔」。

优化：降到 50ms 并改用 `@FocusState` + `.focused($isFocused)`，在同步 `onAppear` 内 `isFocused = true`，让聚焦在首帧布局前入队；保留 sleep 仅作兜底。这是输入体验的核心路径。

### P0-4 · 录音脉冲过慢、双环冗余 〔影响 中 / 工作量 低〕
现状：`RecordingOverlayView.swift` L33–56 双环 `.easeInOut(1.6).repeatForever()`，相位差 0.3s。1.6s 在录音场景里读起来像「卡住/思考」，而非「正在录」（系统级录音指示通常 0.8–1.0s）。双环还增加认知负担。

优化：脉冲降到 **1.0s**；**删除内环**只留单外环（更干净）。若设计坚持双环：外 1.0s / 内 1.2s，相位差降到 0.15s。（与 P0-2 的 reduceMotion guard 一并做。）

### P0-5 · 长按说话：0–250ms「死区」无视觉反馈 〔影响 中 / 工作量 中〕
现状：`PressToTalkButton.swift` L106–155。触摸后需按住 0.25s 才出现环动画（且环 0.8s 时长 > 0.25s 阈值，几乎只闪一下，见 I 区）。这违反「视觉先于触觉」原则——用户不确定按压是否被识别。

优化：触摸即给即时视觉确认——`primaryContainer` 背景轻移 或 `scale(1.08)`，在 haptic 触发前可见；并把 `preRecording` 环动画从 0.8s 降到 0.45s（或直接去掉，因 0.25s 即转录音态）。

---

## 二、输入体验（Input）

| # | 文件 · 位置 | 现状 | 优化（含数值） | 影响 / 工作量 |
|---|---|---|---|---|
| I-1 | `WriteSheetView.swift` 升起动画 L~99 | `timingCurve(0.2,0.8,0.2,1, 0.32)`，控制点造成轻微 overshoot，320ms 略钝 | 收紧为 280ms + `cubic-bezier(0.25,0.46,0.45,0.94)`；可试 240ms | 中 / 低 |
| I-2 | `WriteSheetView.swift` 计数 L372–385 | 字数瞬时更新、阅读时长 chip 却带 `Motion.countTick` 过渡——半动画，观感犹豫 | 二选一统一：要么计数也加 0.15s scale+opacity tick，要么阅读时长也改瞬时（**推荐瞬时，更极简**） | 中 / 低 |
| I-3 | `WriteSheetView.swift` SavePillPressStyle L38–44 | 按压 `scale 0.96` + `easeInOut 0.12s`，0.12s 偏慢 | 降到 0.08s（贴近系统按压手感），缩放保持 0.96 | 低 / 低 |
| I-4 | `AttachmentMenuPopover.swift` L48–61 | 四宫格 `HStack(spacing: 0)`，图标 22pt，略挤 | 改 `spacing: 4`，图标 22→20pt，给「克制留白」 | 低 / 低 |
| I-5 | `InputBarV4.swift` BreathingCaret L6–23 | 呼吸光标 `easeInOut(1.1).repeatForever`，周期 2.2s（非整数） | 取整 1.0s（周期 2.0s，对齐 60fps 帧倍数） | 低 / 低 |
| I-6 | `InputBarV4.swift` dock 阴影 L654–655 | 主阴影 r10/0.45 + 次阴影 r1/0.18（次阴影几乎不可见，徒增渲染） | 删次阴影；主阴影 opacity 0.45→0.35、r10→8 | 低 / 低 |
| I-7 | `InputBarV4.swift` `composingCardMorph` L398+ | 旧「composing card」死代码留存，增加阅读负担 | 单独 PR 清理（非 UX，属维护） | 低 / 低 |
| I-8 | `InputBarV4.swift` 缺附件/位置 haptic | 加附件、设/清位置、清草稿均无触觉确认 | 照片/位置写入 → `Haptics.commit()`；清位置 → `Haptics.light()` | 中 / 中 |

---

## 三、动效与设计系统（Motion / Design System）

| # | 文件 · 位置 | 现状 | 优化（含数值） | 影响 / 工作量 |
|---|---|---|---|---|
| M-1 | `DSButton.swift` / `Interactions.swift` 按压缩放 | 缩放值不一：按钮 0.97、卡片 0.98、归档 0.93、对话框 0.96 | 主点击面统一 **0.96**；0.93 仅留给破坏性操作（删除）；写进注释 | 中 / 低 |
| M-2 | `Elevation.swift` / `Surfaces.swift` / `LiquidGlassEngine.swift` | 玻璃阴影配方 5 套各异；`LiquidGlassCard` 内联硬编码阴影未走 `DSElevation` 枚举 | `LiquidGlassCard` 改用 `.elevation(.glass)`；新增 `DSElevation.subtle`（0.03/0.06）给 `GlassDisc`；统一近/远 radius·offset 对 | 高 / 中 |
| M-3 | `Surfaces.swift` / `Colors.swift` glassEdge | 顶部「湿边」高光只在 `LiquidGlassCard` 用，`GlassDisc`/`Pill`/`Chip` 漏掉，且 `TodayView` 内重复手写 | 抽 `glassHighlight(_ shape:)` helper，默认应用所有玻璃面；少数冲突处用参数关掉 | 中 / 低 |
| M-4 | `Haptics.swift` 等 | 触觉只在「提交」时触发，不引导手势；滑动越阈、删除/撤销缺触觉 | `SwipeableMemoCard` 越阈 → `Haptics.rigid(0.3)`；`DayOrbView` 计数减少 → `Haptics.light()`；在 `Haptics.swift` 注明「越阈=rigid0.3 / 提交=medium / 移除=light」 | 中 / 中 |
| M-5 | `LiquidGlassEngine.swift` 全文 | 为 iOS 26 原生玻璃做双轨桥接（~80 行），native/legacy 两路 reduce-transparency 兜底几乎重复，tint 三岔逻辑费解 | 若原生玻璃仍属推测：删 engine 仅留 legacy 暖玻璃并直接命名 `dpGlass`；若已确认：用 `#if ENABLE_NATIVE_GLASS` 编译开关 + `tint ?? amberSoft` 统一 | 低（对 UX）/ 中 |

---

## 四、显示体验（Display）

| # | 文件 · 位置 | 现状 | 优化（含数值） | 影响 / 工作量 |
|---|---|---|---|---|
| D-1 | `TodayView.swift` 横幅区 L320–414 | AI key / 同步队列 / iCloud 冲突 / 位置草稿 四条横幅 0 间距堆叠；小屏（SE / 12 mini）150–180pt 把输入框挤出屏外 | 每条 `.padding(.bottom, 4)`；`bannerCount ≥ 3` 时隐藏最低优先级（位置草稿）保住输入框 | 高（小屏）/ 低 |
| D-2 | `MemoCardView.swift` 附件 L158–226 | 语音/照片/文件线性 VStack 堆叠，无分组，混合附件卡可达 +60–100pt | 收进可折叠「附件托盘」，横向 badge 计数 + 「+2 more」 | 高 / 中 |
| D-3 | `AISummaryCard.swift` 打字机 L42–52 | 0.38s 前导 + 36–66ms/字，150 字需 5–10s；点按跳过但不易发现 | 前导降 180ms、速度 24–36ms/字（典型 3–4s）；或整段 200ms 淡入 + 设置里随 Reduce Motion 关闭 | 中 / 低 |
| D-4 | `TimelineRow.swift` L312–321 | 标题→lede 10pt、lede→meta 14pt，密集日节奏杂乱 | 统一 8pt 区间 token；标题→lede 收到 6pt | 中 / 低 |
| D-5 | `ArchiveView.swift` 月度卡 L1304–1330 | 四项统计同字号同权重，主指标「总条数」不突出；四块玻璃面成噪声 | 「总条数」serif 38pt + `amberDeep`，其余 28pt + `inkPrimary`；去玻璃背景改纯白面 + 0.5pt 边 | 中 / 中 |

---

## 五、操作体验（Operation）

| # | 文件 · 位置 | 现状 | 优化（含数值） | 影响 / 工作量 |
|---|---|---|---|---|
| O-1 | `SwipeableMemoCard.swift` L86–470 | 左右双向共 6 个滑动动作（pin/more + share/delete），两套手势路径达同类操作，过度设计 | 收敛为**单向左滑**主操作（分享/删除）；pin/more 移入长按菜单（对齐 Apple Notes/Reminders） | 高 / 中 |
| O-2 | `TimelineRow.swift` 菜单 L369–417 | 长按菜单与滑动动作完全重复，菜单冗长且不教用户滑动 | 菜单精简为「打开当日页 + 删除」，分享/pin 交给滑动，菜单作无障碍兜底 | 中 / 低 |
| O-3 | `DayDetailView.swift` 翻页手势 L138–149 | 横向翻页阈值 24pt + 1.5:1，小屏自然滑动易判定模糊需重滑 | `minimumDistance` 20pt、比例 2.0:1；或仅在滚动到顶部（offset≈0）时启用翻页 | 中 / 低 |
| O-4 | `AISummaryCard.swift` 点按 L68–79 | 同一 tap：动画中=加速、动画完=跳转，切换无提示，易误跳 | 完成后才显「→」chevron 暗示；或完成后改双击跳转、单击仅加速 | 中 / 低–中 |
| O-5 | `ArchiveView.swift` 日历空格 L1013–1093 | 空日 50% 透明仍可点进详情，"看着空却像按钮" | 空格去透明保持实底 + 0.5pt borderSubtle 描边表「可点但空」；有内容格用实底无描边 | 中 / 低 |
| O-6 | `UndoPillView.swift` L42–54 / L155 | 倒计时环 `easeInOut(0.4)` 与底层线性 5s 倒计时不同步、视觉跳；VoiceOver 仅在剩 3s 播报（反应时间偏短） | 环改 `.linear` 或去掉单独 easing；播报移到剩 4s 并含「Undo available for 4 more seconds」 | 中 / 低 |

---

## 六、极简与美观（Aesthetics）

| # | 文件 · 位置 | 现状 | 优化 | 影响 / 工作量 |
|---|---|---|---|---|
| A-1 | `AISummaryCard.swift` 头部 L91–112 | sparkle + 「AI·今日一句」+ 「TODAY」+ chevron 四元素拥挤，窄屏换行 | 删冗余「TODAY」（卡片永在 Today 页），仅留 sparkle+标签（左）/ chevron（右） | 低 / 低 |
| A-2 | `MemoCardView.swift` meta 行 L290–315 | 无附件时 meta 行读作空 padding，glyph 8pt 低对比 | 无附件时整行隐藏并把底 padding 14→8pt；有则 glyph 提到 12pt | 低–中 / 低 |
| A-3 | `TimelineRow.swift` 标记 L666–727 | 日/周/月/年标记均实心 accent，暗背景下定义感弱 | 周/月/年改 1.2pt 描边无填充，日保持实心点，增强层级与暗色对比 | 低–中 / 中 |
| A-4 | `TodayView.swift` 多选工具条 L457–463 | padding 上 8 下 4 不对称、无分隔，浮空感 | 上下统一 12pt + 底部 0.5pt borderSubtle 分隔线落地 | 低 / 低 |

---

## 七、建议落地顺序

1. **P0-2 Reduce Motion 合规** + **P0-4 录音脉冲**（同一文件，合并一个无障碍 PR）。
2. **P0-1 Motion token 集中化**（低成本、全局观感提升的基础设施，先做能让后续调参收敛）。
3. **P0-3 键盘聚焦** + **P0-5 长按反馈**（输入主路径手感）。
4. **D-1 横幅密度**（小屏关键回归）。
5. **M-2 Elevation 统一** + **M-3 玻璃高光**（视觉语言基础）。
6. **O-1 滑动收敛**（需设计评审，操作模型变更，单独 Issue 深入讨论）。
7. 其余细节项可打包成「polish sweep」批量 PR。

> 注：O-1 / D-2 / M-5 涉及交互或架构取舍，建议先各开一个设计 Issue 讨论，不要直接进 polish sweep。
