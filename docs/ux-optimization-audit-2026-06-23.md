# DayPage 体验深度优化审计 — 2026-06-23

> 自动化定时任务产出（`daily-ui`）。目标：以极简为核心，优化 **输入体验 / 显示体验 / 操作体验 / 动效 / 细节 / 观感**。
>
> 本文是**设计讨论稿**，不是已合入的改动。按 `CLAUDE.md` 约定，设计类改动需先讨论 → 开 issue → 分支实现 → PR。本稿即为「先深度设计并讨论」的输入材料，附带可直接落地的优先级与 token 方案，便于后续逐条转为 issue。
>
> 审计基于当前源码（非设计稿），覆盖 `DesignSystem/*`、`Features/Today/*` 及 Archive / Graph / Daily / Entity / Root / Sidebar。所有条目均带具体文件与符号定位。

---

## 一、核心结论

设计系统已相当成熟：Motion / Haptics / Colors / Radius / Spacing 等 token 齐备，且 ~80% 的界面正确使用。**体验上的「不够极简、不够顺滑」并非缺少基础设施，而是三类系统性裂缝：**

1. **Token 渗漏（最高频问题）** — 圆角（硬编码 `0 / 6 / 8 / 12 / 14`）、阴影/蒙层不透明度、字号字距在各文件零散硬编码，绕过了已有 token。这是「观感不统一」的根因。
2. **动效与触感不对称** — 进入/退出曲线不一致；同类交互有的给 haptic、有的不给；个别 transition 退化为默认 `linear`。这是「不够顺滑、缺少高级感」的根因。
3. **缺少几个语义 token** — 不透明度（placeholder / scrim / shadow 分级）、几个专用动画（caretBlink / ringStroke），导致开发者「只能硬编码」。补齐后能从源头堵住裂缝。

**建议路线：先做一次「token 收口 + 动效统一」的低风险打磨（P0/P1），再做少量「质感升级」的有设计含量的改动（P2）。** P0/P1 几乎纯属一致性重构，风险低、收益直接体现在「极简、统一、顺滑」。

---

## 二、按主题的优化清单

### A. 极简与观感（视觉收口）

最影响「干不干净、统不统一」的一组。核心是**消灭硬编码圆角，统一到 `DSRadius`**：

- 锐角矩形（`cornerRadius(0)`）出现在 `EntityPageView` 类型徽章（L239-240）、metaChip（L274-277）、relatedMemo 背景（L359）与 `DailyPageView` 分段控件（L305）。在 v4 Liquid Glass 语言下，连续小圆角比锐角更高级；建议至少 `DSRadius.xs`。
- 散落圆角：`ArchiveView` 日历格 `6`（L1051）、`GraphView` 匹配导航按钮 `8`（L218）与 zeroMatch toast `14`（L1062）、`MemoCardView` 照片缩略图/位置卡 `12`（多处）、`DailyPageView` sourceSignals `18`（L376）。统一映射到 `DSRadius.xs/sm/md/lg`，并为照片缩略图新增 `DSRadius.photoThumbnail = 12`。
- 装饰渐变硬编码 hex：`SidebarView` 头像渐变 `#C9A677 → #5D3000`（L157）。抽成语义色 `DSColor.avatarGradient`。
- 蒙层不透明度不一致：`RootView` 侧栏 scrim `0.28`（L151）vs 反馈面板 scrim `0.42`（L175）。统一为 `DSColor.scrimOpacity`（建议单一值，或 `scrim.light/heavy` 两档）。
- 字距/字号硬编码：`EntityPageView` section `.kerning(3)`（L291）与 `ArchiveView` 的 `.tracking()` 不统一；`TimelineSectionView` nameplate 字号 `9.5/13`（L294-304）、`DailyPageView` source label `.tracking(1.6)`（L363）。统一走 `DSType` 语义样式（如 `DSType.sectionLabel` / 新增 `timelineWeekday`）。

### B. 输入体验

- **聚焦时序**：`InputBarV4` 在 `requestFocusToggle` 同一 tick 内触发 morph + focus（L354-356），键盘上升与 spring 易叠帧产生 jank。复用 `WriteSheetView` 已验证的「延迟 ~80ms 聚焦」模式（WriteSheetView L245-248），并把该模式注释化为团队约定。
- **行数限制硬编码**：`InputBarV4` `.lineLimit(1...8)`（L682）、`WriteSheetView` `.lineLimit(3...10)`（L451）。提为 `InputLimits` token，便于统一调参。
- **占位符可读性**：`InputBarV4` 斜体 serif 占位符在同字号下偏难读（L441）；占位符不透明度多处硬编码（WriteSheet L438-440 `0.6`）。新增 `DSOpacity.placeholder` 并统一。
- **极简取舍**：`InputBarV4` dock 垂直 padding 上 10 下 14（L256-261）不对称且意图不明，建议对称化或注明意图。

### C. 显示体验

- **数字滚动**：`UndoPillView` 倒计时环平滑滑动但秒数整跳（L111-134），节奏割裂。改用 `.contentTransition(.numericText())`（iOS 16+）让数字平滑过渡。
- **Orb 收起锚点**：`TodayView` orb 退出用 `.scale` 但锚点 `.top`（L449），小屏会「向上捏」而非均匀缩小；改 `.center`。
- **打字机节奏**：`AISummaryCard` TypewriterText 抖动速率硬编码（L238-240），且需确认 reduce-motion 下确实被 `animated:` 关闭（L42-48）。caret 闪烁动画硬编码 `easeInOut 0.5`（L213-215）→ 提为 `Motion.caretBlink`。
- **深度层级**：`MemoCardView` 顶部语音/照片行与底部 meta 行阴影不一致（L286），需统一 elevation 语义。

### D. 操作体验（反馈与触感）

- **缺触感的同类操作**：`TimelineSectionView` 「复制摘要」静默无反馈（L397）→ 补 `Haptics.soft()` + 1.5s「已复制」toast；`MemoCardView` 语音播放按钮在播放真正开始前无 haptic（L743 vs L909）；`CompileFooterButton` 按压 scale 0.96 但无 haptic（L129）。
- **缺按压态**：`TimelineSectionView` 行点击（L346-352）、`InputBarV4` 加号按钮（L420-426）按下时无 scale/opacity 反馈。统一走 `PressableCardModifier` / `scaleEffect(isPressed)`。
- **可发现性**：`SwipeableMemoCard` 滑动与长按 contextMenu 并存但长按难被发现（L268）；首次可给一次性轻提示。armed 与 fully-revealed 两态目前无视觉区分（L416 vs L433）。

### E. 动效统一（曲线一致性）

- **进/出不对称**：`TodayView` scroll-to-top 出现/消失同曲线、退出无滑出（L553）→ 退出改 `.move(edge: .bottom)` 非对称 transition；`SwipeableMemoCard` spring `0.28` vs reduced `0.22` 等多处「进 spring / 出 easeOut」时长不一，需统一或明确注明。
- **弹簧曲线不统一**：`GraphView` ClearFiltersPressStyle `response 0.3/damp 0.7`（L1243）vs 通用按钮 `0.25/0.85`；`InputBarV4` 录制面 `0.32/0.85`（L396）vs dock morph `0.3`。收敛到 `Motion.spring` 或少数命名曲线。
- **退化为 linear**：`UndoPillView` 环 stroke 动画未指定曲线（L47），环颜色 amber↔error 瞬切无过渡（L148-151）；`InputBarV4` too-short toast 用泛型 `easeInOut 0.2`（L311）→ 改 `Motion.fade`。
- **reduce-motion 覆盖不全**：`GraphView` zoomIndicator 用非标准 `.default.speed(0)` 兜底（L829）；`ArchiveView` filter chip 用 `Motion.spring` 而按压态走 `respectReduceMotion`（L1268）。统一经 `Motion.respectReduceMotion(_:)` / `dsAnimation`。
- **离场未取消**：`ArchiveView` `todayPulse` 呼吸动画切 tab 不停止（L699），应在 `onDisappear` 取消。

### F. 细节 / 杂项

- 多处硬编码字体 `.custom("Inter-Medium", size: …)`（UndoPill L50、SwipeAction L599、CompileFooter L64 等）→ 走 `DSType`。
- 硬编码中文串未本地化：`CompileFooterButton` 「编译今日 · N 条」（L108）。
- 魔法数命名化：swipe 阈值 `28`（UndoPill L82）、可见阈值 `0.02`（SwipeableMemoCard L521）、时段边界 `5..12/12..18`（CompileFooter L173）、spine 像素对齐 `-0.25`（TimelineSection L69）。

---

## 三、建议新增的设计 token（堵源头）

```
DSRadius.photoThumbnail = 12          // 照片/缩略图统一圆角
DSOpacity.placeholder                 // 占位符文本
DSOpacity.scrim (light / heavy)       // 模态/侧栏蒙层
DSOpacity.shadow (subtle / glow)      // 阴影分级，替代散落的 0.04 / 0.6
DSColor.scrimOpacity                  // 收口 RootView 两处 scrim
DSColor.avatarGradient                // 替代 Sidebar 内联 hex
Motion.caretBlink                     // AISummaryCard 光标
Motion.ringStroke                     // UndoPill 进度环 stroke/颜色
DSType.timelineWeekday / timelineMonthDay / swipeActionLabel
InputLimits.composerMaxLines / writeSheetMin/Max
```

补齐后，第二节大量「硬编码」条目可被机械替换，且新代码无处可硬编码。

---

## 四、优先级与落地建议

**P0 — 视觉收口（低风险、收益最直接，建议先做）**
统一所有硬编码圆角到 `DSRadius`；新增并替换圆角/不透明度 token；收口两处 scrim；头像渐变改语义色。纯一致性重构，无行为变更，最能体现「极简、统一」。

**P1 — 动效与触感统一（中低风险）**
统一弹簧曲线到 `Motion.spring`；补齐缺失 haptic 与按压态；修复退化为 linear 的 transition；reduce-motion 全覆盖；scroll-to-top / orb 等进出场打磨。直接体现「顺滑」。

**P2 — 质感升级（需设计含量，单独 issue 讨论）**
倒计时数字 `numericText` 平滑、打字机节奏、swipe armed/revealed 双态视觉、深度层级统一。每项单独开 issue 配视觉对比。

**建议拆分为 3 个 issue（P0 / P1 / P2）**，P0 与 P1 可各自一个 PR 批量推进；P2 逐项小 PR。每个 PR 按 `CLAUDE.md`：iPhone 17 模拟器构建 + 跑测 + 截图核验，并 link 对应 issue。

---

### 自动化运行说明
- 本次为无人值守定时任务，未对源码做任何写入；仅产出本审计稿（符合「设计改动需先讨论/开 issue」约定与 write-action 限制）。
- 所有定位行号基于本次读取的当前源码，后续若有改动需复核。
- 未自动创建 GitHub issue（属 write 操作且需你确认拆分粒度）；如需，我可据第四节直接生成 3 个 issue 草稿。
