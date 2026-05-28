# PRD: DayPage v8 — 美术馆美学 · 体验改版（生产级）

> **Status**: Draft · **Created**: 2026-05-28 · **Author**: Claude (代笔，与 Eric 共同设计)
> **Source of truth**: `/tmp/daypage-design/daypageapp/` (Claude Design handoff bundle, 2026-05-28)
> **Target platforms**: iOS Native（主线）+ Web/Next.js（跟进，仅换 UI，数据层不动）
> **Version**: 1.0 (生产级 · 单文件 · 覆盖 Wave A-F)

---

## 目录

0. [TL;DR](#0-tldr)
1. [Introduction / Overview](#1-introduction--overview)
2. [Goals & Non-Goals](#2-goals)
3. [Personas & User Stories](#3-personas--user-stories)
   - Wave A · 设计系统底座 (US-001 ~ US-004)
   - Wave B · Today 屏重做 (US-005 ~ US-011)
   - Wave C · Memo Detail 屏 (US-012 ~ US-018)
   - Wave D · Drawer + 热力图 (US-019 ~ US-025)
   - Wave E · Composer / Recording / 灵动岛 (US-026 ~ US-030)
   - Wave F · Share Card (US-031 ~ US-033)
4. [Functional Requirements](#4-functional-requirements)
5. [Non-Goals](#5-non-goals)
6. [Design Considerations](#6-design-considerations)
7. [Technical Considerations](#7-technical-considerations)
8. [API Contracts & Schema](#8-api-contracts--schema)
9. [Security & Privacy](#9-security--privacy)
10. [Performance Budget & Telemetry](#10-performance-budget--telemetry)
11. [Accessibility (a11y)](#11-accessibility-a11y)
12. [Error States & Edge Cases](#12-error-states--edge-cases)
13. [Internationalization](#13-internationalization)
14. [Analytics & Observability](#14-analytics--observability)
15. [Test Matrix](#15-test-matrix)
16. [Rollout Plan](#16-rollout-plan)
17. [Risk Register](#17-risk-register)
18. [Success Metrics](#18-success-metrics)
19. [Sprint Plan](#19-sprint-plan)
20. [Open Questions](#20-open-questions)
21. [Glossary](#21-glossary)
22. [Appendix A · 代码片段参考](#22-appendix-a--代码片段参考)
23. [Appendix B · 设计 token 完整 JSON](#23-appendix-b--设计-token-完整-json)
24. [Appendix C · API 响应 fixtures](#24-appendix-c--api-响应-fixtures)
25. [References](#25-references)
26. [Checklist before kickoff](#26-checklist-before-kickoff)

---

## 0. TL;DR

把 DayPage 当前"功能完整但视觉朴素"的形态，重做为**「日式美术馆 + iOS 26 灵动岛」气质**的记录工具。设计原则只有三条：

1. **内容优先**（Content-first） — 卡面只剩时间 + 正文 + 照片；其余元数据全部进详情或隐藏在左滑动作里
2. **留白为骨**（Ma / 間） — hairline 取代粗边框、间距取代分隔块、垂直 spine 串信息流
3. **仪式感反馈**（Ritual feedback） — 长按即录、实时波形、灵动岛 Live Activity、AI 一句话的打字机入场

最终衡量标准：用户打开 app 应该有「这是一个**值得每天放进去 5 分钟**的工具」的克制感，不是 dashboard。

**范围**：33 个 user story，6 个 Wave，8 个 Sprint，30-40 工作日（约 6-8 周单人节奏）。
**血脉**：iOS Native 是设计源头，Web 跟进只换 UI 层，数据 / 路由 / auth 一律不动。

---

## 1. Introduction / Overview

### 1.1 现状（What we have）

| 维度 | 现状 | 痛点 |
|---|---|---|
| 视觉 | Tailwind utility + amber-brown 暖色 token，已搭出"暖白 + accent"骨架 | 卡片太朴素，缺现代质感；列表样式陈旧；侧边栏丑 |
| 交互 | tap-only 路径长，所有元数据都堆在卡面上 | 录音/输入不丝滑、操作步骤多、缺少反馈 |
| 信息 | Home + Memos + Wiki + Inbox 各自一屏 | Today 没有时间轴感、本周 wiki 折叠卡难看 |
| 录音 | 在 `/add` 路由里走 Web Speech API | 没有波形 / 没有灵动岛感 / 没有 sheet 模态 |
| 分享 | 一个简单的截图 | 没有模板化 / 没有竖图比例 / 不适合小红书 |

### 1.2 目标（What we want）

- 重做 **6 个核心屏**（Today / Memo Detail / Drawer with 热力图 / Composer Pill / Recording Sheet + 灵动岛 / Share Card）
- 沉淀一套 **可复用的设计 token + 组件库**（颜色、字体、动画、卡片、按钮、sheet、手势）
- iOS 端用原生 SwiftUI gesture + spring 动画做到 "pixel-perfect"；Web 端用 CSS transition + pointer events 还原同款体验
- 保持 web/ 现有 **路由 / drizzle schema / API / auth / proxy 不动**，只换 UI 层

### 1.3 Out of scope（明确不做）

- 不动数据库 schema（`pages` / `memos` / `domains` / `inbox_items` 等结构保持，仅新增 §8 列举的字段）
- 不动 auth、proxy、API 路由
- 不重写 AI compilation pipeline（DashScope / Inngest 流程沿用）
- 不替换 Drizzle ORM 或迁移到别的栈
- 不引入新的状态管理库（iOS 沿用 `ObservableObject`，Web 沿用 React Query）
- iOS Watch / iPad 适配延后

### 1.4 关键决策摘要

| 决策 | 选择 | 备注 |
|---|---|---|
| 平台优先级 | iOS Native 优先，Web 跟进 | 设计稿是 iPhone 原型 |
| 范围 | 全量重构（设计系统 + 6 屏） | 不分阶段拆 PR，但分 8 个 sprint |
| 数据层 | 保留 | 仅 +1 endpoint +1 setting 字段 |
| 手势库 | 不引入 | pointer events + spring `cubic-bezier(.2,.8,.2,1)` |
| 视觉验证 | 截图 + dev-browser skill | 每个 PR 必附 before/after |

---

## 2. Goals

### 2.1 体验目标（可观测）

- **G-1**：用户在 Today 屏首屏 **0 滑动** 即可看见：今日 hero 标题 + AI 一句话 + 至少 1 条 memo + composer pill
- **G-2**：录音从 "意图录音" → "首字进屏幕" 中间不超过 **350ms**（长按 220ms 触发 + 录音 sheet 入场动画 320ms 中点）
- **G-3**：Memo 卡面 **不显示** 天气 / 地点 / kind 标签 / 分享按钮 — 这些通过「左滑」「点进详情」「右上 ⋯ 菜单」三条路径出现
- **G-4**：本周 wiki 在 Today 屏向下滚动时是 **垂直连续信息流**（不是横向轮播、不是折叠卡），每条信息间至少 30pt ma 间距
- **G-5**：录音中，**灵动岛胶囊** 持续显示 elapsed 时间 + mini 波形；松手即停 + 自动转写

### 2.2 设计语言目标（token 级）

- **G-6**：建立单一来源的 `design-tokens`（颜色 / 字号 / 圆角 / 阴影 / 动画曲线），iOS 与 Web 都从这一份派生
- **G-7**：圆角阶梯固定为 `8 / 14 / 18 / 22 / 999`（small / card / hero-card / week-card / pill）
- **G-8**：阴影只有一档 `0 1px 2px rgba(0,0,0,0.04)`（`--shadow-card`） — 拒绝 elevation 滥用
- **G-9**：动画曲线只有两条：`cubic-bezier(.2,.8,.2,1)`（spring-like）和 `ease-out`（线性收尾）；时长 220 / 280 / 320 / 360 ms 四档

### 2.3 工程目标

- **G-10**：iOS / Web 双端的 6 个核心屏组件 **可以被设计稿截图独立 diff**（即视觉回归测试 baseline）
- **G-11**：Web 端不引入额外手势库（不上 framer-motion / use-gesture），用 pointer events + CSS 还原
- **G-12**：iOS 端不引入额外动画库，用 `withAnimation(.spring(response:0.32, dampingFraction:0.78))` 还原

### 2.4 业务目标

- **G-13**：dogfood 用户（Eric 自己 + 10 内测）每日打开次数从基线 1.8 提升到 ≥ 3
- **G-14**：每用户每日 memo 数中位数从基线 1.2 提升到 ≥ 2
- **G-15**：分享卡片导出（首月）≥ 50 次

---

## 3. Personas & User Stories

### 3.1 Persona 摘要

**Eric（主用户原型）**
- 数字游民，常驻东南亚
- 每天 1-3 条短 memo（文本/语音/混合 + 照片）
- 期望"打开就记，10 秒走人" + "晚上 02:00 AI 自动编译成日页"
- 对"克制美学"敏感（提到 Bear / Notion Calendar / Apple Notes / Apple Journal）
- 主设备 iPhone 17，副设备 MacBook（Web 偶尔用）

**Secondary persona — 设计敏感的内测用户（10 人）**
- 关注分享卡片美学 / 小红书发图
- 对 Live Activity / 灵动岛体验有期待
- 多语言（中文为主，部分双语）

### 3.2 User Stories

每条 story 设计为 **可在单个 Ralph iteration / 单个 PR 内完成**。
所有 story 共享的隐含 acceptance criteria：
- 引用 `design-tokens`，**0 个 hardcode 颜色 / 字号**
- a11y：触控目标 ≥ 44×44pt（iOS HIG）/ 44×44px（WCAG 2.5.5）
- prefers-reduced-motion 支持（见 §11）
- 错误态显式处理（见 §12）

---

#### **🏛️ Wave A · 设计系统底座**

##### **US-001：建立统一 design-tokens 文件**
**Description**: 作为开发者，我需要把现有散落在 `globals.css` / `tokens.css` / SwiftUI `Typography.swift` 里的颜色/字号/圆角合并为单一来源。

**Acceptance Criteria**:
- [ ] 新建 `design-tokens/tokens.json` 作为 source of truth（完整 schema 见 §23 Appendix B）
- [ ] 生成器脚本：`design-tokens/generators/to-css.ts`（→ `web/src/app/globals.css` 的 `:root` 段）+ `design-tokens/generators/to-swift.ts`（→ `DayPage/App/DSTokens.swift` 的 enum）
- [ ] 生成器作为 `npm run tokens:build` + `make tokens-build` 暴露
- [ ] 颜色 token 名字必须与设计稿一致（详见 §6.2 colors 全表）
- [ ] 字体 token：`font-display`（Space Grotesk）、`font-serif`（Fraunces 新增）、`font-body`（Inter）、`font-mono`（JetBrains Mono）
- [ ] Fraunces 字体文件加入 iOS bundle（`DayPage/App/Resources/Fonts/Fraunces.ttf`）与 Web `next/font` 配置
- [ ] 圆角 token：`radius-small=8`、`radius-card=14`、`radius-hero=18`、`radius-week=22`、`radius-pill=999`
- [ ] 动画 token：`motion-spring='cubic-bezier(.2,.8,.2,1)'`、`motion-ease-out='ease-out'`、`motion-fast=220ms`、`motion-medium=280ms`、`motion-slow=320ms`、`motion-island=360ms`
- [ ] CI 加 `tokens:check` step：跑生成器 → 比对结果 → 若 diff 则 fail
- [ ] Typecheck passes
- [ ] 双端构建通过（`xcodebuild -scheme DayPage build` + `cd web && npm run build`）

---

##### **US-002：扩展全局动画 keyframes 库**
**Description**: 作为开发者，我需要把设计稿里用到的 6 个 keyframes 注册到全局 CSS（已部分存在），并把 iOS 端对应的 SwiftUI animation 工具函数封装好。

**Acceptance Criteria**:
- [ ] Web `globals.css` 注册：`@keyframes pulse-dot`、`@keyframes breathe`、`@keyframes shimmer-bar`、`@keyframes sheet-up`、`@keyframes sheet-left`、`@keyframes fade-in`、`@keyframes caret`、`@keyframes scale-in`（已存在的不重复）
- [ ] Web 暴露 `.fade-in` / `.scale-in` / `.shimmer` utility class
- [ ] 所有 keyframes 都 wrap `@media (prefers-reduced-motion: reduce)` block：在 reduce 偏好下退化为 `animation-duration: 0.01ms` + `animation-iteration-count: 1`
- [ ] iOS 新建 `DayPage/App/DSMotion.swift`，提供：
  - `Animation.dsSpring` (`.spring(response: 0.32, dampingFraction: 0.78)`)
  - `Animation.dsEaseOut` (`.easeOut(duration: 0.22)`)
  - `Animation.dsSheet` (`.spring(response: 0.40, dampingFraction: 0.82)`)
  - `@Environment(\.accessibilityReduceMotion)` 检查 → 退化为 `.linear(duration: 0.01)`
- [ ] Typecheck passes
- [ ] 双端构建通过

---

##### **US-003：Glass Pill Button 组件**
**Description**: 作为开发者，我需要一个 glassmorphism 圆形/胶囊按钮的 reusable 组件，因为顶栏返回 / 搜索 / 设置 / 分享都用它。

**Acceptance Criteria**:
- [ ] Web: `web/src/components/ui/GlassPillBtn.tsx`，props: `dark?: boolean`、`size?: 'sm' \| 'md'`、`onClick`、`children`、`aria-label`（必填）、`disabled?: boolean`
- [ ] iOS: `DayPage/App/Components/DSGlassPill.swift`，对应 `dark`、`size` 参数 + `accessibilityLabel`
- [ ] 视觉规格：`height=40`、`min-width=40`、`padding=0 12`、`radius=999`、`background=rgba(255,255,255,0.78)`（dark 时 `rgba(30,28,24,0.62)`）、`backdrop-filter=blur(20px) saturate(160%)`、`box-shadow='0 1px 2px rgba(0,0,0,0.05), inset 0 0.5px 0 rgba(255,255,255,0.6)'`
- [ ] `size=sm`: height=36 / 触控扩展到 44 用 `::before` pseudo (Web) / `.contentShape(.rect)` 扩展 hit area (iOS)
- [ ] Tap 反馈：scale 0.96 + opacity 0.85，220ms；prefers-reduced-motion 时仅改 opacity
- [ ] focus-visible 态：`outline: 2px solid var(--accent) / outline-offset: 2px`
- [ ] disabled 态：`opacity: 0.4 / cursor: not-allowed / pointer-events: none`
- [ ] Storybook（Web）/ Preview（iOS）覆盖 4 个变体（默认/dark/sm/disabled）
- [ ] Typecheck passes
- [ ] Verify in browser using dev-browser skill

---

##### **US-004：Section Label 与 Dot 原子组件**
**Description**: 提取设计稿中重复使用的 mono caps 区段标签 + 分隔小圆点。

**Acceptance Criteria**:
- [ ] Web: `<SectionLabel right?>` 渲染 `font-size:11`、`letter-spacing:1.6`、`text-transform:uppercase`、`font-weight:700`、`color:var(--fg-muted)`
- [ ] Web: `<Dot opacity?>` 渲染 3×3 圆点，默认 opacity 0.45
- [ ] iOS 对应的 `DSSectionLabel` / `DSDot` View
- [ ] `<SectionLabel>` 使用 `<h2 role="heading" aria-level="2">` 但视觉是 mono caps（screen reader 朗读为常规标题，去掉装饰 letter-spacing）
- [ ] `<Dot>` 在 a11y tree 隐藏（`aria-hidden="true"` / `.accessibilityHidden(true)`）
- [ ] Typecheck passes

---

#### **🌅 Wave B · Today 屏重做**

##### **US-005：Today 顶部 utility bar（glass scroll-aware）**
**Description**: 作为用户，进入 Today 屏看见的最上方是 [左] hamburger + [右] 搜索 + 设置，三个都是 GlassPillBtn；向下滚动时背景从透明渐变为 frosted glass。

**Acceptance Criteria**:
- [ ] 容器 `position:absolute / top:0 / paddingTop:60(iOS safe-area) / paddingLeft:14 / paddingRight:14 / paddingBottom:10`
- [ ] `scrollTop > 8` 时：`background=rgba(250,248,246,0.78)` + `backdrop-filter=blur(20px) saturate(150%)` + 底部 `0.5px solid var(--border-subtle)`；`scrollTop ≤ 8` 时背景透明、无边框
- [ ] 切换过渡 `transition:background 200ms ease-out, backdrop-filter 200ms ease-out`
- [ ] Hamburger 点击触发 `onOpenDrawer`；搜索/设置 button 暂留空 handler（后续 sprint 接）
- [ ] Hamburger `aria-label="打开侧边栏"`、搜索 `aria-label="搜索"`、设置 `aria-label="设置"`
- [ ] scrollY 监听使用 `passive: true`，60Hz throttle（rAF）
- [ ] Typecheck passes
- [ ] Verify in browser using dev-browser skill

---

##### **US-006：Today Hero 标题块**
**Description**: 用户向下看到一个 56px 大字 hero（周几），下方一行 mono caps 元信息：`MAY 28 · 2 NOTES · 28° · VIENTIANE`。

**Acceptance Criteria**:
- [ ] H1 大字：`font-size:56 / line-height:1 / letter-spacing:-0.8 / font-family:var(--font-serif) / font-weight:600`
- [ ] H1 渲染当前周几本地化字符串：`new Intl.DateTimeFormat('zh-CN', { weekday: 'long' })`（iOS 用 `Date.FormatStyle.dateTime.weekday(.wide)`）；星期日特殊：周日→「星期日」
- [ ] Meta 行：`font-family:var(--font-mono) / font-size:11 / letter-spacing:1.2 / text-transform:uppercase / color:var(--fg-muted) / margin-top:12 / gap:8`
- [ ] 用 `<Dot/>` 分隔；NOTES 计数着 `var(--accent)` 色
- [ ] 28° 前内联 sun SVG icon（11×11）
- [ ] 数据来源：iOS 从 `CompilationService` / `WeatherService` 取；Web 走 `GET /api/today/header`（响应见 §24 fixture-1）
- [ ] 加载态：skeleton placeholder（mono caps `LOADING…`）；错误态：fallback 到 `MAY 28 · — · — · —`（用 `var(--fg-subtle)`）
- [ ] H1 用 `<h1>` 语义；meta 行用 `<dl>` semantic（dt=label, dd=value）但视觉是 inline
- [ ] Typecheck passes
- [ ] Verify in browser using dev-browser skill

---

##### **US-007：Today Segmented Control（今日/成稿/档案）**
**Description**: Hero 下方一个 pill segmented control，3 段切换。

**Acceptance Criteria**:
- [ ] 容器：`inline-flex / padding:3 / radius:999 / background:var(--surface-sunken) / border:0.5px solid var(--border-subtle)`
- [ ] 选中 segment：`background:var(--surface-white) / color:var(--accent) / font-weight:600 / box-shadow:'0 1px 2px rgba(0,0,0,0.06)'`
- [ ] 未选中：`background:transparent / color:var(--fg-muted) / font-weight:500`
- [ ] 切换走 client state，URL 同步 `?tab=today|page|archive`（用 `useSearchParams` + `router.replace`，避免历史栈污染）
- [ ] 键盘可达：`role="tablist"` + 子 `role="tab"` + `aria-selected` + Arrow Left/Right 切换
- [ ] 切换动画：选中 indicator 用 `transform: translateX(...)` 280ms spring 滑动（layoutId-like）
- [ ] Typecheck passes
- [ ] Verify in browser using dev-browser skill

---

##### **US-008：AI Summary 卡（克制版）**
**Description**: 用户在 segmented control 下方看到一张白卡，左边一道 2px accent 竖条 rail，顶部 `AI · 今日一句`，中间一行 serif italic 的 AI 摘要（带打字机入场）。

**Acceptance Criteria**:
- [ ] 容器：`radius:18 / padding:18 20 20 22 / background:var(--surface-white) / border:0.5px solid var(--border-subtle) / box-shadow:var(--shadow-card)`
- [ ] 左侧 rail：`position:absolute / left:0 / top:14 / bottom:14 / width:2 / radius:999 / background:var(--accent) / opacity:0.85`
- [ ] 顶部 row：sparkle SVG 11×11 (`var(--accent)` fill) + `AI · 今日一句` mono caps + 右侧 `15:32` 时间戳（小圆点 + mono）
- [ ] 摘要正文：`font-family:var(--font-serif) / font-size:19 / font-style:italic / line-height:1.45 / min-height:54`
- [ ] 入场：380ms 延迟后打字机逐字（每字 36-66ms 随机），caret 用 `@keyframes caret` 1s steps(1) 闪
- [ ] **prefers-reduced-motion** 时跳过打字机，直接显示全文（无 caret）
- [ ] 数据：`GET /api/today/ai-summary`（fixture-2，§24）；返回 `{summary: string, generated_at: ISO8601, is_stale: boolean}`
- [ ] 无摘要时 placeholder：`今天还没攒够话，再记一条试试`（去掉打字机和 caret）
- [ ] `is_stale=true` 时摘要右侧加 `重新生成` 小链接（mono 9 caps，accent 色）
- [ ] a11y：用 `<blockquote>` 语义，`aria-live="polite"` 让打字机过程被屏读器读出全文（不读字符流）
- [ ] Typecheck passes
- [ ] Verify in browser using dev-browser skill

---

##### **US-009：Memo Card（内容优先 + 左滑揭示动作）**
**Description**: 卡面只渲染时间 + 正文 + 照片三件事；左滑 132px 揭示 MORE / SHARE 两个 action drawer；点击进详情；滑动手势中不触发点击。

**Acceptance Criteria**:
- [ ] 卡面规格：`radius:18 / background:var(--surface-white) / border:0.5px solid var(--border-subtle) / box-shadow:var(--shadow-card) / overflow:hidden`
- [ ] 卡面内容：照片占满宽度（aspect-ratio 4:5、`radius:0`）+ body block（padding `16/18 20 18/20`）
- [ ] body block 顶部：mono 时间 `15·23` + （mixed 时）3×3 圆点 + 相机 icon — **不显示** 地点/天气/kind 标签/分享按钮
- [ ] body 正文：`font-size:16 / line-height:1.62 / text-wrap:pretty / letter-spacing:0.1`；正文超过 5 行用 `-webkit-line-clamp:5` + 渐变蒙版底部
- [ ] **左滑手势规格**：
  - `REVEAL_WIDTH = 132`
  - pointer events 实现，translate-x 跟手
  - 超过 `-REVEAL/2 = -66` 自动 snap 到 `-132`，否则回 0
  - 右滑（tx>0）rubber-band：`tx_effective = tx * 0.18`
  - 左滑超过 `-REVEAL-32 = -164` rubber-band：`tx_effective = -164 + (tx + 164) * 0.18`
  - 完整公式：见 §22 Appendix A 代码片段
- [ ] 松手后 transition `transform 280ms cubic-bezier(.2,.8,.2,1)`；拖动中 transition `none`
- [ ] 点击行为：`drag.moved > 6px` 时不触发；卡片已经滑开时（tx !== 0）第一次点击是关闭，第二次才进详情
- [ ] Action drawer：`position:absolute / right:0 / width:132 / opacity` 由 tx 决定（tx < -8 显示）；MORE 是 sunken 灰按钮，SHARE 是 accent 暖色按钮
- [ ] **iOS 端**：用 `DragGesture(minimumDistance: 4)` + `withAnimation(.spring(response:0.32, dampingFraction:0.78))`；rubber-band 阻尼系数 0.18 一致；触觉反馈 `UIImpactFeedbackGenerator(.light).impactOccurred()` 当 snap 到 `-132` 时
- [ ] **键盘可达**（Web）：卡片本身可 focus（`tabIndex=0`）；Enter 触发详情；Shift+Enter 不动作；视障用户用 right-click context menu 暴露 MORE / SHARE（`<menu>` 原生）
- [ ] **swipe back close**：滑开状态下从任意位置点击卡面本身 → 关闭抽屉
- [ ] Unit tests：rubber-band 公式 5 个测试用例（边界值 0 / -66 / -132 / -164 / -200）
- [ ] Typecheck passes
- [ ] Tests pass
- [ ] Verify in browser using dev-browser skill

---

##### **US-010：「再记一条解锁今日成稿」placeholder 卡**
**Description**: 当日 memo 数 < 解锁阈值（默认 3）时，在 memo 列表末尾显示一张虚线 dashed 卡。

**Acceptance Criteria**:
- [ ] 容器：`padding:18 / radius:18 / background:transparent / border:1.5px dashed var(--accent-border)`
- [ ] 左侧 36×36 圆形 sparkle icon（背景 `var(--accent-soft)`，icon `var(--accent)`）
- [ ] 文案：mono caps `再记一条解锁今日成稿` + 副标 `AI 将把今天的碎片连缀成一篇日页`
- [ ] 阈值从 `users.settings.unlock_threshold` 取，默认 3（schema 见 §8.3）
- [ ] 满足阈值后此卡片淡出（fade-out 280ms），代之为 `今日已解锁` 小 banner（mono accent 色）
- [ ] 点击占位卡 → focus 到 composer pill mic 按钮（Web `scrollIntoView` + `focus()`；iOS 触发 keyboard 弹起）
- [ ] Typecheck passes
- [ ] Verify in browser using dev-browser skill

---

##### **US-011：本周 Wiki 垂直 Spine Feed**
**Description**: SectionLabel `本周` 下方是一个垂直信息流，每个条目挂在一根贯穿到底的 hairline spine 上 — 美术馆解说牌式版面。

**Acceptance Criteria**:
- [ ] 容器 padding `12 22 14`；spine：`position:absolute / left:86 / top:18 / bottom:18 / width:0.5 / background:var(--border-subtle)`
- [ ] 每条 entry：`grid-template-columns:'52px 1fr' / column-gap:24 / padding 30 上下` (首条 paddingTop:0、末条 paddingBottom:6)
- [ ] 左列日期 tag：右对齐，mono `WED` (9.5/700/1.8 letter-spacing) + display `05·27` (14/600)
- [ ] Spine dot：accent 7×7 圆点，外圈 4px `var(--bg-warm)` halo（用 box-shadow 实现），定位在 entry 顶部 10pt
- [ ] 右列内容：serif h3 `font-size:21 / line-height:1.26 / letter-spacing:-0.4` + lede 段 `font-size:14.5 / line-height:1.7 / opacity:0.86` + footer 标签行
- [ ] Footer 行：mono caps tags 用 `·` 分隔 + 右对齐 `412 WORDS`
- [ ] 末尾 terminus：spine 底部一个 7×7 hollow 圆点（`border:0.5px solid var(--border-default) / background:var(--bg-warm)`）
- [ ] **不要** 卡片外壳、不要圆角 box、不要按钮 — 内容直接坐在 bg-warm 上
- [ ] 整条 entry clickable，点击进 `/wiki/[date-slug]`
- [ ] 数据：`GET /api/today/week-feed?limit=7`（fixture-3，§24）
- [ ] 空态：本周无 page 时显示 mono caps 占位 `本周还未成稿 — 多记几条今日会自动生成`
- [ ] 长内容截断：lede 用 `-webkit-line-clamp:3`
- [ ] a11y：每条 entry 用 `<article>` 语义；spine + dot 加 `aria-hidden`
- [ ] Typecheck passes
- [ ] Verify in browser using dev-browser skill

---

#### **📝 Wave C · Memo Detail 屏**

##### **US-012：Memo Detail 顶栏（sticky glass + 时间锚点）**
**Description**: 详情页顶栏：左 GlassPillBtn ← `今日` 返回；中 mono `THU · MAY 28 · 15:30`；右 GlassPillBtn 分享 + 三点菜单。

**Acceptance Criteria**:
- [ ] `position:sticky / top:0 / padding:62 14 12`（iOS safe-area）
- [ ] `background:rgba(250,248,246,0.82) / backdrop-filter:blur(20px) saturate(150%) / border-bottom:0.5px solid var(--border-subtle)`
- [ ] 左按钮回退到 Today；右第一个按钮触发 share screen / 第二个 ⋯ 暂留空（弹出 popover 菜单见 US-018+）
- [ ] 中间时间：`font-family:mono / font-size:10 / letter-spacing:1.5 / color:var(--fg-subtle)`
- [ ] iOS 端：左滑返回手势（屏幕边缘 20pt 触发）走标准 navigation pop
- [ ] Typecheck passes
- [ ] Verify in browser using dev-browser skill

---

##### **US-013：Memo Detail 标题块（serif 大字 + 元信息）**
**Description**: 标题块大 serif 字显示地点名（`Saoban Café`），下方 mono `MIXED ENTRY · VIENTIANE`；无 place 时显示 italic `未命名片刻`。

**Acceptance Criteria**:
- [ ] 标题：`font-family:serif / font-size:34 / line-height:1.05 / letter-spacing:-0.7 / font-weight:600`
- [ ] 无 place fallback：`font-size:30 / line-height:1.15 / font-style:italic`
- [ ] 副标：mono 10 / 1.4 letter-spacing / 600 / `var(--fg-subtle)`，`{KIND ENTRY} · {LOCATION_UPPER}`
- [ ] kind 翻译表：`text → TEXT`、`voice → VOICE`、`photo → PHOTO`、`mixed → MIXED`
- [ ] 数据：iOS 从 `memo.place` / `memo.location` 取；Web 从 `memos.place` / `memos.location` 字段取
- [ ] 长 place name（> 30 char）截断 `text-overflow: ellipsis` + 单行
- [ ] Typecheck passes
- [ ] Verify in browser using dev-browser skill

---

##### **US-014：Memo Detail Metadata Tile Row（4 列白卡）**
**Description**: 标题下方一张白卡，水平分 4 列：WEATHER / HUMIDITY / LIGHT / KIND，hairline 分隔。

**Acceptance Criteria**:
- [ ] 容器：`grid-template-columns:'1.05fr 1fr 1fr 0.85fr' / radius:14 / overflow:hidden / background:var(--surface-white) / border:0.5px solid var(--border-subtle) / shadow:var(--shadow-card)`
- [ ] 每个 tile：`padding:12 8 11 / text-align:center / border-left:0.5px solid var(--border-subtle)`（首个不带 left border）
- [ ] tile 三行：mono caps label (`8.5/700/1.4`) + display value (`18/600`) + mono caps sub (`8/600/1.2`)
- [ ] 数据来源：天气从 `memos.weather` 取（如果为空，从 `WeatherService` 实时补充）；湿度从 `memos.humidity`；LIGHT 由时间计算（早晨 5-9 / 上午 9-12 / 中午 12-14 / 下午 14-17 / 傍晚 17-19 / 夜间 19-5）；KIND 从 `memo.kind` 翻译
- [ ] 缺失字段显示 `—`（em dash，`var(--fg-subtle)`）
- [ ] a11y：每个 tile 包成 `<dl>` semantic
- [ ] Typecheck passes
- [ ] Verify in browser using dev-browser skill

---

##### **US-015：Memo Detail Hero Photo + caption**
**Description**: 混合类型 memo 有照片时，在 metadata 下方显示一张大图，下方一行 mono caption + `TAP TO EXPAND` 按钮。

**Acceptance Criteria**:
- [ ] 图片：aspect-ratio 4:5，`radius:18`，fade-in 入场（cross-fade 280ms）
- [ ] caption 左：mono `{IMG_filename} · {width} × {height}` (9.5 / 1.2 letter-spacing / 600 / `--fg-subtle`)
- [ ] caption 右：accent 色 mono `TAP TO EXPAND` + corner-out icon
- [ ] 点击进入全屏 lightbox（iOS 用 `.fullScreenCover` + 双指缩放 + 双击重置；Web 用 `<dialog>` + `transform: scale` 缩放）
- [ ] lightbox 关闭手势：iOS 下滑 ≥ 80pt + rubber-band 关闭；Web 用 ESC 或点遮罩
- [ ] 加载态：`background: var(--surface-sunken)` + 中心 spinner
- [ ] 加载失败：占位 `图片加载失败` + 重试 link
- [ ] `loading="lazy"`（Web）+ `prefersDecodingAsync` (iOS)
- [ ] a11y：`alt={memo.body || '相片'}`
- [ ] Typecheck passes
- [ ] Verify in browser using dev-browser skill

---

##### **US-016：Memo Detail Body 段落**
**Description**: 正文段落用 body 字号，`white-space:pre-line` 保留换行。

**Acceptance Criteria**:
- [ ] `padding:0 24 30 / font-size:16.5 / line-height:1.72 / letter-spacing:0.1 / text-wrap:pretty / white-space:pre-line / color:var(--fg-primary)`
- [ ] 长按选中文本（iOS 原生，Web `user-select: text`）
- [ ] 链接自动检测：URL 渲染为 `<a class="memo-link">` accent 色下划线（Web 用 `linkifyjs`，iOS 用 `NSDataDetector`）
- [ ] hashtag `#xxx` 渲染为 accent 色（不带下划线），点击跳到 `/wiki/tag/{tag}`
- [ ] mention `@xxx` 渲染同 hashtag，点击跳到对应 entity
- [ ] Typecheck passes
- [ ] Verify in browser using dev-browser skill

---

##### **US-017：Memo Detail Location Card（map thumbnail + Apple Maps 跳转）**
**Description**: SectionLabel `LOCATION`（右侧 `17.96°N · 102.63°E`），下方一张 mini map 缩略图，左下角浮 glass chip 显示地点；底部一行 `在 Apple 地图中打开` accent 按钮。

**Acceptance Criteria**:
- [ ] 容器：`radius:18 / overflow:hidden / border:0.5px solid var(--border-subtle) / background:var(--surface-white) / shadow:var(--shadow-card)`
- [ ] Map 区：iOS 用 `MapKit` 静态 snapshot（`MKMapSnapshotter`）；Web 用 Apple MapKit JS（已在 `web/.env.local` 有 token，否则用 OpenStreetMap tile 占位）
- [ ] Place chip：`position:absolute / left:14 / bottom:14 / padding:7 11 / radius:10 / background:rgba(250,248,246,0.92) / backdrop-filter:blur(10px) / border:0.5px solid var(--border-subtle)`
- [ ] Chip 内容：pin SVG (`var(--accent)`) + 地点名（body 12.5/600）+ mono caps `{LOCATION} · {COUNTRY}`
- [ ] 底部按钮：横向 row，paper-plane icon + `在 Apple 地图中打开` + 右侧 arrow-corner-out icon
- [ ] 点击跳转：iOS 用 `MKMapItem.openInMaps(launchOptions:)`；Web 用 `https://maps.apple.com/?ll={lat},{lng}&q={place}` 新窗口
- [ ] 无 location 时整个卡片不渲染
- [ ] map 加载失败：fallback 静态 amber-tinted 图（`#F5EDE3` 背景 + pin icon 居中）
- [ ] Typecheck passes
- [ ] Verify in browser using dev-browser skill

---

##### **US-018：Memo Detail File Metadata Card + 三点菜单**
**Description**: 最底部 SectionLabel `FILE`，下方一张白卡，3 行键值：CREATED / PATH / HASH，全 mono 字体；同时实现顶栏右侧 ⋯ 菜单。

**Acceptance Criteria**:
- [ ] 容器：`padding:14 16 / radius:14 / border:0.5px solid var(--border-subtle) / background:var(--surface-white) / shadow:var(--shadow-card)`
- [ ] grid-template: `80px 1fr / row-gap:11 / column-gap:14`，font-family mono / 11.5 / 0.2 letter-spacing
- [ ] 字段：CREATED（ISO 时间戳 `2026-05-28 15:30:09`）、PATH（`vault/raw/{date}.md`）、HASH（前 6 位 + ` · ` + 后 5 位）
- [ ] 数据：iOS 从 `RawStorage` 取；Web 从 `memos.content_hash` + `memos.path`
- [ ] **顶栏 ⋯ 菜单内容**（iOS 用 `Menu`，Web 用 popover）：转移到其他日期 / 复制纯文本 / 标记重要 / 导出为 PDF / 删除（红色，需二次确认）
- [ ] 删除二次确认：弹 alert `确认删除这条 memo？此操作不可撤销` + [取消] [删除]
- [ ] 点击 HASH 整行 → 复制 hash 到剪贴板 + toast `已复制 hash`
- [ ] Typecheck passes
- [ ] Verify in browser using dev-browser skill

---

#### **🚪 Wave D · Drawer 与热力图**

##### **US-019：Drawer 容器与入场动画**
**Description**: 点击 Today 顶栏 hamburger 弹出左侧抽屉，宽度 86%，frosted glass 背景，从左滑入。

**Acceptance Criteria**:
- [ ] Backdrop：`position:absolute / inset:0 / background:rgba(20,16,12,0.32) / backdrop-filter:blur(2px) / z-index:80 / animation:fade-in 220ms ease-out`
- [ ] Drawer：`width:86% / z-index:85 / background:rgba(252,250,247,0.96) / backdrop-filter:blur(28px) saturate(160%) / border-right:0.5px solid var(--border-subtle) / box-shadow:'10px 0 40px -12px rgba(60,40,15,0.22)'`
- [ ] 入场：`@keyframes sheet-left { from { transform:translateX(-100%) } to { transform:translateX(0) } }`、280ms `cubic-bezier(.2,.8,.2,1)`
- [ ] Backdrop 点击关闭；ESC 关闭（Web）；右滑边界关闭（iOS DragGesture，阈值 50% width，rubber-band）
- [ ] 打开时 focus trap：Tab 在 drawer 内循环，Shift+Tab 反向
- [ ] 打开时 body `overflow:hidden`（Web）防滚动穿透
- [ ] `aria-modal="true"` + `role="dialog"` + `aria-labelledby` 指向 `DAYPAGE · 2026` mono 标签
- [ ] Typecheck passes
- [ ] Verify in browser using dev-browser skill

---

##### **US-020：Drawer 顶部 utility bar + Profile row**
**Description**: 顶部一行：左关闭按钮 + 右 mono `DAYPAGE · 2026`；下方一行：渐变 amber avatar + 名字 + `MEMBER · SINCE 2024` + chevron。

**Acceptance Criteria**:
- [ ] 关闭按钮：36×36 圆，`background:var(--surface-sunken)` + X icon，`aria-label="关闭侧边栏"`
- [ ] mono 标签：`font-size:10 / letter-spacing:2 / font-weight:700 / color:var(--fg-muted)`
- [ ] Avatar：46×46 圆，`background:linear-gradient(135deg, #C9A677 0%, #5D3000 100%)`，serif 大写首字母（20/600）
- [ ] 用户有 avatar URL 时优先用 img，否则 fallback 首字母
- [ ] 名字：serif 19/600 / line-height:1.15 / letter-spacing:-0.2
- [ ] 副标：mono 10 / 1.2 letter-spacing / color:var(--fg-subtle)，格式 `MEMBER · SINCE {year}`
- [ ] 点击整行进 `/settings`
- [ ] 数据：iOS 从 `UserService.current` 取；Web 从 `auth().user` + `users.created_at` 取年份
- [ ] Typecheck passes
- [ ] Verify in browser using dev-browser skill

---

##### **US-021：Drawer 热力图（真实数据，16 周 × 7 天）**
**Description**: Drawer 视觉主角 — 16 周 × 7 天的 memo 热力图，月份标签 + 周标签 + less▢▢▢▢▢more 图例 + N 天连续胶囊。

**Acceptance Criteria**:
- [ ] 容器：白卡，`radius:14 / border:0.5px solid var(--border-subtle) / background:var(--surface-white) / shadow:var(--shadow-card) / padding:14`
- [ ] 16 列 × 7 行 grid，每格 10×10 / radius:2 / gap:3
- [ ] 等级映射：`memo_count == 0 → heatmap-empty`、`1-2 → low`、`3-5 → mid`、`>=6 → high`；未来日期渲染为 dashed hairline 占位（`border:0.5px dashed var(--border-default) / background:transparent`）
- [ ] 顶部 5 个月份标签（mono 9 caps）+ 左侧 Mon/Wed/Fri 标签（mono 8 caps）
- [ ] 底部 row：左侧 `LESS ▢▢▢▢▢ MORE` 图例（5 档），右侧 accent 胶囊 `🔥 {streak} DAYS`
- [ ] Streak 计算：从 today 倒推、连续有 memo 的天数（详细公式见 §22 Appendix A）
- [ ] **数据来源**：iOS 走 `RawStorage.listDays()` + 每天 memo 数；Web 走 `GET /api/stats/heatmap?weeks=16`（schema 见 §8.2）
- [ ] 单格 tap 弹小 tooltip：`{date} · {count} memos`（mono caps）
- [ ] 触控目标：每格 hit area 扩展到 16×16（透明 padding）满足触控规范
- [ ] 加载态：所有格子显示 `--heatmap-empty`
- [ ] Performance：iOS 用 `LazyVGrid` 渲染；Web 用 `<svg>` 单次绘制（不 React-render 每个 cell）
- [ ] Typecheck passes
- [ ] Verify in browser using dev-browser skill

---

##### **US-022：Drawer Stats 三联卡（STREAK / PAGES / WORDS）**
**Description**: 热力图下一张白卡，3 列等宽：STREAK 23 DAYS / PAGES 142 TOTAL / WORDS 58k 2026。

**Acceptance Criteria**:
- [ ] 容器：`grid-cols-3 / radius:14 / overflow:hidden / border / shadow:var(--shadow-card)`
- [ ] 每列：`padding:14 6 12 / text-align:center / border-left:0.5px solid var(--border-subtle)`（首列无）
- [ ] 三行：mono caps label (9/600/1.4) + display value (22/600/-0.5 letter-spacing) + mono caps unit (8/1.2)
- [ ] 数据：streak 同 US-021 计算；PAGES 从 `pages` count；WORDS 用本年 page.summary 字数累加（中文按字符数，英文按词数）
- [ ] 大数字格式化：≥ 1000 显示 `k`（58000 → 58k）；≥ 1,000,000 显示 `M`（1500000 → 1.5M）
- [ ] 数据来源：`GET /api/stats/drawer`（fixture-4，§24）
- [ ] Typecheck passes
- [ ] Verify in browser using dev-browser skill

---

##### **US-023：Drawer Navigate 卡（今日/成稿/档案/关系图谱）**
**Description**: SectionLabel `NAVIGATE`，下方一张白卡分 4 行：每行 sunken icon tile + 中文主标 + mono caps 副标 + count + chevron。

**Acceptance Criteria**:
- [ ] 卡片容器：`radius:14 / border / overflow:hidden / shadow:var(--shadow-card)`
- [ ] 每行 `padding:12 14 / gap:14`，行间 0.5px hairline
- [ ] Icon tile：30×30 / radius:9 / `var(--surface-sunken)` / border 0.5
- [ ] 当前选中行：`background:var(--accent-soft)` + icon tile 改 white + label/count 改 accent / 600 weight
- [ ] 关系图谱行解锁：iOS 实际已有 `/graph` route，移除 `muted` 状态
- [ ] 4 行：今日 → `/today` (count = 今日 memo)、成稿 → `/wiki` (count = pages 总数)、档案 → `/archive`、关系图谱 → `/graph`
- [ ] 点击行后 drawer 自动关闭（先 navigate 后 close 280ms）
- [ ] Typecheck passes
- [ ] Verify in browser using dev-browser skill

---

##### **US-024：Drawer Recent 列表（hairline 分行）**
**Description**: SectionLabel `RECENT`（右侧 `VIEW ALL ›`），下方 7 条最近的 page，每行 mono 日期 + 中文标题（单行截断）+ ×N memo count。

**Acceptance Criteria**:
- [ ] 每行：`padding:13 0 / gap:14 / border-top:0.5px solid var(--border-subtle)`（首行无）
- [ ] 左日期 col：min-width:52，mono day (9/1.4) + display date (16/600)
- [ ] 中标题：body 14 / 1.4 line-height / 单行 ellipsis
- [ ] 右计数：mono 10 / 0.6 letter-spacing / color:var(--fg-subtle)
- [ ] active 状态：date 改 accent / title 改 primary / count 改 accent
- [ ] 数据：`GET /api/stats/recent?limit=7`（fixture-5，§24）
- [ ] `VIEW ALL ›` 点击 → `/archive`
- [ ] 空态：`还没有成稿的日页`（mono caps，居中）
- [ ] Typecheck passes
- [ ] Verify in browser using dev-browser skill

---

##### **US-025：Drawer Footer**
**Description**: 最底部一行 Settings / Feedback 链接 + 右侧版本号。

**Acceptance Criteria**:
- [ ] 容器：`margin-top:30 / padding:18 4 4 / border-top:0.5px solid var(--border-subtle)`
- [ ] 链接：body 13 / 500 / color:var(--fg-muted)
- [ ] 版本号：mono 9 / 1.2 letter-spacing / color:var(--fg-subtle)，格式 `v{version} · {build_date}`
- [ ] iOS 版本号从 `CFBundleShortVersionString` + `CFBundleVersion` 取；Web 从构建时注入的 `process.env.NEXT_PUBLIC_VERSION` 取
- [ ] Settings → `/settings`；Feedback → `mailto:feedback@daypage.app?subject=DayPage Feedback`
- [ ] Typecheck passes
- [ ] Verify in browser using dev-browser skill

---

#### **🎙️ Wave E · Composer / Recording / 灵动岛**

##### **US-026：Composer Pill（底部浮动 + glass）**
**Description**: Today 屏底部居中浮一颗胶囊：[ + ] [ 🎙️ accent ] [ Aa ]，glassmorphism。

**Acceptance Criteria**:
- [ ] 容器：`position:absolute / bottom:26 / display:flex / justify-content:center / safe-area-inset-bottom`
- [ ] Pill：`padding:6 / radius:999 / background:rgba(255,253,250,0.82) / backdrop-filter:blur(28px) saturate(160%) / border:0.5px solid rgba(214,206,192,0.5)`，多层 shadow（inset highlight + 外 drop shadow）
- [ ] 左 [ + ] 按钮：48×48 圆透明，点击打开 Attach sheet，`aria-label="添加附件"`
- [ ] 中 [ 🎙️ ] 按钮：64×56 / radius:999 / `background:linear-gradient(180deg, #7a3f00 0%, #5D3000 100%)` + 多层 shadow + 外圈 `animation:breathe 1.6s ease-in-out infinite` halo
- [ ] 右 [ Aa ] 按钮：48×48 圆透明，点击进入键盘输入模式，`aria-label="键盘输入"`
- [ ] Pill 下方一行 mono caps 提示：`长按录音 · 轻点切换`
- [ ] 录音中（`recording=true`）pill 整体 `pointer-events:none / opacity:0`，让位给 RecordingSheet
- [ ] 入场：`@keyframes scale-in` 240ms ease-out
- [ ] Desktop（Web breakpoint ≥ 768px）：pill 改为左下角固定（不居中），保留 glass 风
- [ ] Typecheck passes
- [ ] Verify in browser using dev-browser skill

---

##### **US-027：Composer Pill 长按录音手势**
**Description**: 麦克风按钮 pointerdown 220ms 后触发录音；早松手则视为 tap 切换到键盘输入；移动设备触觉反馈。

**Acceptance Criteria**:
- [ ] **Web**：`onPointerDown` 启动 220ms timer；`onPointerUp / onPointerLeave / onPointerCancel` 清 timer 并标 `pressed=false`；timer 触发时 if `pressed` 才 `onMicLongPressStart()`
- [ ] **iOS**：用 `DragGesture(minimumDistance:0)` + 220ms `Task.sleep`，配合 `UIImpactFeedbackGenerator(.medium).impactOccurred()` 触发录音；Tap < 220ms 触发 `UISelectionFeedbackGenerator().selectionChanged()`
- [ ] Tap（< 220ms 松手）：触发 `onMic()` → 切换到键盘输入
- [ ] LongPress（≥ 220ms 持续）：触发 `onMicLongPressStart()` → 进入录音
- [ ] 拖出按钮范围（pointerleave）取消录音意图
- [ ] 权限检查：首次长按时若 mic 权限未授予，弹系统授权请求；拒绝后 fallback toast `需要麦克风权限才能录音 · 去设置`
- [ ] Typecheck passes
- [ ] Verify in browser using dev-browser skill

---

##### **US-028：Attach Sheet（4 件套 bottom-up modal）**
**Description**: Composer 左 [+] 按钮触发：底部弹出 sheet，4 列 grid：拍照 / 相册 / 位置 / 附件。

**Acceptance Criteria**:
- [ ] Backdrop：`position:absolute / inset:0 / background:rgba(30,24,18,0.32) / backdrop-filter:blur(2px) / z-index:60 / animation:fade-in 200ms ease-out`
- [ ] Sheet：`left:14 / right:14 / bottom:110 / z-index:65 / radius:28 / padding:20 18 22 / background:rgba(255,253,250,0.92) / backdrop-filter:blur(28px) saturate(160%) / border:0.5px solid rgba(214,206,192,0.6) / shadow:'0 24px 60px -20px rgba(60,40,15,0.35)'`
- [ ] 入场：`@keyframes sheet-up` 280ms cubic-bezier(.2,.8,.2,1)
- [ ] 顶部 36×4 handle bar (`#D6CEC0`)
- [ ] 4 个 button：56×56 圆角 18 sunken tile + 12 body 字 label
- [ ] 拍照 / 相册：iOS 调 `PHPicker` / `UIImagePicker`，Web 触发 `<input type=file accept="image/*" capture="environment">` (拍照) 或 `multiple` (相册)
- [ ] 位置：iOS 取当前 `LocationService.lastFix`，Web 用 `navigator.geolocation.getCurrentPosition(opts={enableHighAccuracy:true,timeout:6000})`
- [ ] 附件：调起原生 doc picker / Web file input (不限 accept)
- [ ] **下滑关闭手势**：drag handle 向下拖 ≥ 80px 关闭，rubber-band 阻尼 0.18，spring 返弹
- [ ] backdrop tap 关闭；ESC 关闭（Web）
- [ ] focus trap + `role="dialog"`
- [ ] Typecheck passes
- [ ] Verify in browser using dev-browser skill

---

##### **US-029：Recording Sheet（深色 + 实时波形 + 计时器）**
**Description**: 长按麦克风后弹出底部深色 sheet：红点 + `录音中` mono / 计时器 + 实时波形条 + 实时转写预览 + [取消] [停止并转写] 双按钮。

**Acceptance Criteria**:
- [ ] 容器：`bottom:0 / paddingBottom:34(safe-area) / z-index:55 / margin:0 14 / radius:34 / padding:22 22 24 / background:rgba(45,30,12,0.92) / backdrop-filter:blur(28px) saturate(160%) / shadow:'0 24px 60px -16px rgba(40,25,5,0.55)' / color:#FAF8F6`
- [ ] 入场：sheet-up 320ms cubic-bezier(.2,.8,.2,1)
- [ ] Header row：左 `🔴 录音中`（10×10 圆，`background:#E36B4A`，`animation:pulse-dot 1.2s` + `box-shadow:0 0 0 4px rgba(227,107,74,0.18)`）、右 mono 28px 计时 `MM:SS`
- [ ] Waveform strip：64 bars，跑 60fps `requestAnimationFrame`，公式见 §22 Appendix A；每 bar `width:2 / gap:2 / height:max(2, h)` 平滑 80ms 过渡
- [ ] 实时转写预览：body 13 / `color:rgba(245,237,227,0.65)` / 末尾 caret 闪
- [ ] 双按钮：取消（flex:1，`background:rgba(255,255,255,0.1)` / `#F5EDE3` 文字）+ 停止并转写（flex:1.6，`background:#F5EDE3` / `#2B2822` 文字 + 勾 icon）
- [ ] 取消：discard buffer，关闭 sheet，**不**保存草稿；停止并转写：触发 `VoiceService.transcribe()` → 把转写文本作为新 memo 草稿，弹 Today 屏底部 banner `已添加 1 条 memo`
- [ ] iOS 用 `AVAudioRecorder` + `AVAudioEngine` installTap 实时取 RMS 喂波形；Web 用 `AudioContext.createAnalyser()` + `getByteFrequencyData` 喂波形
- [ ] 录音时长 > 5 分钟自动停止 + alert `录音已达上限`
- [ ] 失去焦点（iOS background / Web tab switch）保持录音 30s，超时自动停止并保存
- [ ] 实时转写：iOS 用 `SFSpeechRecognizer` (zh-CN)，Web 用 Whisper API streaming
- [ ] Typecheck passes
- [ ] Verify in browser using dev-browser skill

---

##### **US-030：灵动岛 Live Activity（iOS 原生 + Web 装饰）**
**Description**: 录音时，灵动岛胶囊展开为 248×37：左侧 `🔴 MM:SS`，右侧 mini waveform。

**Acceptance Criteria**:
- [ ] **iOS 端**：用 `ActivityKit` 实现真 Live Activity
  - ActivityAttributes：`elapsed: TimeInterval` / `isRecording: Bool` / `currentDB: Double`（音量）
  - Island compact 状态：左红点 + 右波形 3-bar
  - Island expanded 状态：左 `🔴 MM:SS` + 右 18-bar waveform + 底部 "停止" 按钮
  - Island minimal 状态：单红点
  - 后台用 `BackgroundTasks` 每 1s update Live Activity 状态
  - 录音 5min 上限后自动 end Live Activity
- [ ] **Web 端**：在原 iPhone frame 顶部画一个 248×37 / radius:24 / black 胶囊（装饰用，仅 mock 演示）
- [ ] 展开宽度：248 / 收起宽度 126，过渡 `width 360ms cubic-bezier(.2,.8,.2,1)`
- [ ] 内容左：8×8 red dot `pulse-dot 1.2s` + mono 11 计时
- [ ] 内容右：18 高 mini waveform（18 bars），`width:1.6 / gap:1.5`
- [ ] 点击灵动岛 deep link 回到 Today 屏 + RecordingSheet（iOS `widgetURL`）
- [ ] `Info.plist` 加 `NSSupportsLiveActivities=YES`
- [ ] Deployment target bump to iOS 16.1（前置 Open Question 1）
- [ ] Typecheck passes
- [ ] iOS 端在真机 iPhone 17 验证 Live Activity 注册成功
- [ ] Web 端 Verify in browser using dev-browser skill

---

#### **🖼️ Wave F · Share Card**

##### **US-031：Share Card 主屏 + 模板切换器**
**Description**: 从 memo 卡左滑 SHARE 进入分享屏：顶部 utility bar + 中央卡片预览（竖图 4:5）+ 底部模板切换 chip row。

**Acceptance Criteria**:
- [ ] 顶栏：左 GlassPillBtn 关闭（`aria-label="关闭"`）+ 中 mono `SHARE` + 右 GlassPillBtn 下载（`aria-label="下载图片"`）
- [ ] 5 个模板 id：`minimal / film / polaroid / journal / postcard`
- [ ] 模板切换 chip：水平 scroll，选中态 accent 背景 + white 文字；chip `padding:8 14 / radius:999 / mono caps`
- [ ] 预览卡片：竖图 4:5 比例（实际 1080×1350 / 显示 ~300×375 web）
- [ ] 切换模板：fade-in 280ms 过渡
- [ ] iOS 端：从 memo detail 进入用 sheet presentation；Web 端用 modal page
- [ ] 选中模板持久化到 `localStorage.daypage.shareTemplate`（Web）/ `UserDefaults`（iOS）
- [ ] Typecheck passes
- [ ] Verify in browser using dev-browser skill

---

##### **US-032：Share Card 5 个模板视觉**
**Description**: 每个模板独立一个组件，规格不同但都基于同一份 memo 数据渲染。

**Acceptance Criteria**:
- [ ] **minimal**：白底 + serif 大字标题 + 正文 + 小 mono 落款（日期 + 地点）
- [ ] **film**：黑边白卡夹相片，底部胶卷孔装饰（用 SVG `<rect>` 重复）+ 帧号 mono `28 / 36A`
- [ ] **polaroid**：白边大相片 + 底部手写体 caption（用 `Caveat` Google font，新增）
- [ ] **journal**：暖米色纸纹背景 + 图钉 / 胶带装饰（SVG decorative elements）+ 手写感 serif 标题
- [ ] **postcard**：左右二分 — 左相片 + 右纵向 mono 邮戳样式 + serif 中段感言
- [ ] 所有模板支持切换字体（serif / sans）与配色（暖 / 冷）— 配色 toggle 状态持久化
- [ ] 长正文自动 truncate：minimal 8 行、film 6 行、polaroid 2 行（caption）、journal 10 行、postcard 5 行
- [ ] 模板组件位于 `web/src/components/share/{templateId}.tsx` + `DayPage/Features/Share/Templates/{templateId}.swift`
- [ ] Typecheck passes
- [ ] Verify in browser using dev-browser skill

---

##### **US-033：Share Card 导出 PNG**
**Description**: 点击右上角下载按钮，把当前模板渲染为 PNG（2x 分辨率）下载到本地或拉起系统分享。

**Acceptance Criteria**:
- [ ] **iOS**：用 `ImageRenderer` API（iOS 16+）渲染 SwiftUI 视图为 `UIImage`，存 Photos（需 `NSPhotoLibraryAddUsageDescription` 权限）或调 `UIActivityViewController`
- [ ] **Web**：用 `html-to-image` (npm `html-to-image@^1.11`)，导出 1080×1350 PNG（小红书竖图标准），用 `<a download>` 触发下载
- [ ] 导出过程中按钮显示 spinner，完成 toast `已保存到 {Photos / Downloads}`
- [ ] 字体需在导出前确保 Web 字体已加载（用 `document.fonts.ready`）
- [ ] 图片需 CORS-safe：所有 memo 照片走 same-origin proxy `/api/img/{memo_id}`（如果 src 跨域）
- [ ] 错误态：导出失败 → toast `导出失败，请重试`
- [ ] 性能预算：导出耗时 ≤ 1.5s（Web）/ ≤ 0.8s（iOS）
- [ ] 上报 analytics：`share_card_exported` event with `{template, kind, has_photo}`
- [ ] Typecheck passes
- [ ] Verify in browser using dev-browser skill

---

## 4. Functional Requirements

> 给实现者快速对照用，每条对应一个 user story。

| FR | 描述 | US |
|---|---|---|
| FR-1 | 设计 token 单一来源 | US-001 |
| FR-2 | 全局动画 keyframes 注册 + reduce-motion 退化 | US-002 |
| FR-3 | GlassPillBtn 组件统一规格 | US-003 |
| FR-4 | SectionLabel / Dot 原子组件 | US-004 |
| FR-5 | Today 顶栏滚动渐变 + glass | US-005 |
| FR-6 | Today Hero 标题 + 元信息 | US-006 |
| FR-7 | Today Segmented control + URL 同步 | US-007 |
| FR-8 | AI Summary 卡 + 打字机入场 | US-008 |
| FR-9 | Memo Card 左滑揭示 + spring + rubber-band | US-009 |
| FR-10 | 解锁占位卡 | US-010 |
| FR-11 | 本周 Wiki 垂直 spine feed | US-011 |
| FR-12 | Memo Detail 顶栏 sticky glass | US-012 |
| FR-13 | Memo Detail 标题块 serif + 元信息 | US-013 |
| FR-14 | Memo Detail Metadata 4 列白卡 | US-014 |
| FR-15 | Memo Detail Hero Photo + lightbox | US-015 |
| FR-16 | Memo Detail Body 段落 + 链接 / hashtag / mention | US-016 |
| FR-17 | Memo Detail Location card + Apple Maps | US-017 |
| FR-18 | Memo Detail File metadata + 三点菜单 | US-018 |
| FR-19 | Drawer 容器 + 入场动画 + focus trap | US-019 |
| FR-20 | Drawer Profile 行 | US-020 |
| FR-21 | Drawer 热力图（真实数据） | US-021 |
| FR-22 | Drawer Stats 三联卡 | US-022 |
| FR-23 | Drawer Navigate 卡 | US-023 |
| FR-24 | Drawer Recent 列表 | US-024 |
| FR-25 | Drawer Footer | US-025 |
| FR-26 | Composer Pill | US-026 |
| FR-27 | 长按录音手势 + 权限处理 | US-027 |
| FR-28 | Attach Sheet | US-028 |
| FR-29 | Recording Sheet + 实时波形 + 转写 | US-029 |
| FR-30 | 灵动岛 Live Activity | US-030 |
| FR-31 | Share Card 主屏 + 模板切换 | US-031 |
| FR-32 | Share Card 5 个模板 | US-032 |
| FR-33 | Share Card 导出 PNG | US-033 |

---

## 5. Non-Goals

- ❌ 不重写 drizzle schema（仅 §8 列举的新增字段 / endpoint）
- ❌ 不替换 auth.js / proxy.ts
- ❌ 不动 AI compilation pipeline（DashScope / Inngest）
- ❌ 不引入手势库（framer-motion / use-gesture / react-spring 都不上）
- ❌ 不引入新设计系统（不 Radix、不 shadcn、不 Material）
- ❌ 不做 iPad 横屏适配（v8 范围）
- ❌ 不做 Watch app（已有 `design-watch-recording.md` 单独 PRD）
- ❌ 不做 onboarding 引导流（v8 范围）
- ❌ 不做 i18n / 多语言切换（v8 沿用中文为主 + 部分 mono caps 英文装饰；策略见 §13）
- ❌ 不做暗色模式（v8 只做暖白主题；暗色 v9 再来）
- ❌ 不做服务端推送通知 / Live Activity 远程 update（仅本地）
- ❌ 不做协作 / 多端实时同步（沿用现有 iCloud sync 状态）

---

## 6. Design Considerations

### 6.1 设计语言三原则

1. **Content-first** — 卡面只渲染主信息；元信息隐藏到左滑 / 详情 / ⋯ 菜单
2. **Hairline as separator** — 0.5px `var(--border-subtle)` 取代 1px 边框；空间取代盒子
3. **Mono caps for utility, Serif for soul** — mono 用于日期/标签/计数/工具感；serif 用于标题/AI 摘要的情感锚点

### 6.2 颜色 token 全表

| Token | Value | 用途 | Contrast vs `--bg-warm` (#FAF8F6) |
|---|---|---|---|
| `--bg-warm` | `#FAF8F6` | 主背景（暖白） | — |
| `--surface-white` | `#FFFFFF` | 卡片背景 | 1.04:1 |
| `--surface-sunken` | `#F3F0EB` | icon tile / segmented 未选中 | 1.04:1 |
| `--fg-primary` | `#2B2822` | 正文 | **15.5:1** ✅ AAA |
| `--fg-muted` | `#6B6560` | 副标 / label | **5.4:1** ✅ AA |
| `--fg-subtle` | `#A39F99` | mono caption / hint | **2.5:1** ⚠️ 仅 large-text |
| `--accent` | `#5D3000` | 重点（amber-brown） | **10.9:1** ✅ AAA |
| `--accent-hover` | `#7A3F00` | hover | 8.0:1 ✅ AAA |
| `--accent-soft` | `#F5EDE3` | accent 背景 | 1.06:1 (decorative) |
| `--accent-border` | `#E8DCCA` | accent 虚线 / 边框 | (decorative) |
| `--border-subtle` | `#EDE8DF` | hairline | (decorative) |
| `--border-default` | `#D6CEC0` | 实线边框 | (decorative) |
| `--heatmap-empty` | `#F0EBE3` | 热力图 lvl 0 | (decorative) |
| `--heatmap-low` | `#E6D9C3` | 热力图 lvl 1 | (decorative) |
| `--heatmap-mid` | `#C9A677` | 热力图 lvl 2 | (decorative) |
| `--heatmap-high` | `#5D3000` | 热力图 lvl 3 / 今天 | 10.9:1 ✅ |

**注意**：`--fg-subtle` 仅用于 ≥ 18.66px (14pt) bold 或 ≥ 24px (18pt) regular 文字 — 详见 §11 a11y。

### 6.3 字体

| Token | Family | 用途 | Fallback | Web subset |
|---|---|---|---|---|
| `--font-display` | Space Grotesk 500/600/700 | 大数字 / sans 标题 | system-ui | Latin |
| `--font-serif` | **Fraunces 400/600/700**（新增） | 文学标题 / AI 摘要 | Georgia, serif | Latin + CN-Pinyin |
| `--font-body` | Inter 400/500/600/700 | 正文 | system-ui | Latin + CJK Common |
| `--font-mono` | JetBrains Mono 400/500/700 | 时间 / 标签 / hash | ui-monospace | Latin |
| `--font-handwrite` | **Caveat 400/700**（仅 Share Card） | polaroid caption | cursive | Latin |

**中文字体策略**：Web 用系统中文（`PingFang SC` / `HarmonyOS Sans` fallback）；iOS bundle 中文用 `PingFang SC` 系统字体。

**字号阶梯**：

| Class | Size | line-height | Letter-spacing | 用途 |
|---|---|---|---|---|
| `hero` | 56 | 1.0 | -0.8 | Today Hero h1 |
| `title-xl` | 34 | 1.05 | -0.7 | Memo Detail 标题 |
| `title-lg` | 30 | 1.15 | -0.5 | Italic 无标题 fallback |
| `title-md` | 22 | 1.1 | -0.5 | Stats 大数字 |
| `title-sm` | 21 | 1.26 | -0.4 | Spine feed entry 标题 |
| `subhead` | 19 | 1.45 | 0.1 | AI Summary 摘要 |
| `body-lg` | 16.5 | 1.72 | 0.1 | Memo Detail 正文 |
| `body` | 16 | 1.62 | 0.1 | Memo Card 正文 |
| `body-sm` | 14.5 | 1.7 | 0.1 | Spine feed lede |
| `body-xs` | 13.5 | 1.4 | 0.1 | Drawer / 顶栏按钮文本 |
| `mono-md` | 13 | 1.4 | 0.2 | Recording sheet 转写预览 |
| `mono-sm` | 11.5 | 1.4 | 0.2 | File card |
| `mono-xs` | 11 | 1.4 | 1.2 | Today meta caps |
| `mono-2xs` | 10 | 1.4 | 1.5-1.8 | 副标 / mono caps |
| `mono-3xs` | 9 / 8.5 | 1.4 | 1.4-1.6 | 热力图 / 极小 label |

### 6.4 圆角阶梯

| Token | Value | 用途 |
|---|---|---|
| `--radius-small` | 8px | 小 chip / 小 tile |
| `--radius-card` | 14px | 标准卡片（metadata tile / stats / file） |
| `--radius-hero` | 18px | hero 卡 / memo card / AI summary |
| `--radius-week` | 22px | 已废弃，spine feed 不用 |
| `--radius-sheet` | 28px | Attach sheet |
| `--radius-recording` | 34px | Recording sheet |
| `--radius-island` | 24px | 灵动岛 |
| `--radius-pill` | 999px | 胶囊按钮 / segmented |

### 6.5 动画系统

| Token | Curve | 用途 |
|---|---|---|
| `motion-spring` | `cubic-bezier(.2,.8,.2,1)` | sheet 入场 / 卡片 snap / drawer |
| `motion-ease-out` | `ease-out` | fade / scale-in |
| `motion-fast` | 220ms | tap 反馈 / glass bar 渐变 / long-press 阈值 |
| `motion-medium` | 280ms | sheet / drawer 入场 |
| `motion-slow` | 320ms | recording sheet |
| `motion-island` | 360ms | 灵动岛 width 切换 |

### 6.6 手势规格（重点）

| 手势 | 阻尼 / 阈值 | 触发条件 | 反馈 |
|---|---|---|---|
| Memo 卡左滑揭示 | 阈值 -66px / 过界 -164px / 阻尼 0.18 | translateX | snap 时 light haptic |
| Sheet 下滑关闭 | 阈值 80px / 阻尼 0.18 | drag handle | medium haptic |
| Drawer 右滑边界关闭 | 阈值 50% width / 阻尼 0.18 | 屏幕边缘 20pt 起 | — |
| 长按录音 | 220ms | 麦克风 pointerdown | medium haptic at trigger |
| Tap 短按 | < 220ms 松手 | — | selection haptic |
| 拖动 vs 点击 | moved > 6px → drag | — | — |

### 6.7 阴影系统

| Token | Value | 用途 |
|---|---|---|
| `--shadow-card` | `0 1px 2px rgba(0,0,0,0.04)` | 标准卡片唯一阴影 |
| `--shadow-pill-inset` | `inset 0 0.5px 0 rgba(255,255,255,0.6)` | GlassPill 顶部高光 |
| `--shadow-pill-drop` | `0 1px 2px rgba(0,0,0,0.05)` | GlassPill 投影 |
| `--shadow-composer` | `0 2px 6px rgba(60,40,15,0.08), 0 18px 32px -12px rgba(60,40,15,0.22)` | Composer Pill |
| `--shadow-attach` | `0 24px 60px -20px rgba(60,40,15,0.35)` | Attach Sheet |
| `--shadow-recording` | `0 24px 60px -16px rgba(40,25,5,0.55)` | Recording Sheet |
| `--shadow-drawer` | `10px 0 40px -12px rgba(60,40,15,0.22)` | Drawer right edge |

---

## 7. Technical Considerations

### 7.1 Repo 布局

```
/
├── design-tokens/              # 新建，token 单一来源
│   ├── tokens.json
│   ├── generators/
│   │   ├── to-css.ts           # → web/src/app/globals.css :root 段
│   │   └── to-swift.ts         # → DayPage/App/DSTokens.swift
│   └── README.md
├── DayPage/                    # iOS（已有）
│   ├── App/
│   │   ├── DSTokens.swift      # 新生成
│   │   ├── DSMotion.swift      # 新增
│   │   ├── Resources/Fonts/    # 新增 Fraunces.ttf + Caveat.ttf
│   │   └── Components/         # 新增 DSGlassPill / DSSectionLabel / DSDot / DSHeatmap / DSWeekSpine
│   ├── Features/               # 改写 Today / Detail / Drawer / Composer
│   └── LiveActivity/           # 新增 RecordingActivityAttributes + LiveActivityView
└── web/                        # Web（已有）
    ├── src/app/(app)/today/    # 新增（不删 /home，redirect 后再删）
    ├── src/app/(app)/memos/[id]/  # 改写
    ├── src/app/api/today/      # 新增 header / ai-summary / week-feed endpoints
    ├── src/app/api/stats/      # 新增 heatmap / drawer / recent
    ├── src/components/ui/      # 新增 GlassPillBtn / SectionLabel / Dot / Heatmap / WeekSpine / MemoCard
    ├── src/components/share/   # 新增 ShareCardModal + 5 个模板组件
    └── src/lib/gestures/       # 新增 useSwipeReveal hook
```

### 7.2 Web 端依赖增量

| 包 | 版本 | 用途 | 大小 (gzip) |
|---|---|---|---|
| `html-to-image` | ^1.11 | Share Card 导出 | ~9KB |
| `next/font` 内置 | — | Fraunces + Caveat 字体 | — |
| `linkifyjs` | ^4.1 | Memo body 链接检测 | ~5KB |

**不引入**：framer-motion / use-gesture / react-spring / dnd-kit（共节省 ~50KB gzip）

### 7.3 iOS 端依赖增量

- 新增字体文件：`Fraunces.ttf` (subset latin+CN-Pinyin)、`Caveat.ttf` (latin only)
- `Info.plist` 注册字体 + `NSSupportsLiveActivities=YES` + `NSPhotoLibraryAddUsageDescription`
- 新增 ActivityKit framework（系统自带）
- Deployment target bump：16.0 → 16.1（Live Activity 要求）

### 7.4 数据增量

详见 §8 API Contracts & Schema。

### 7.5 兼容性策略

- `/today` 与 `/home` 并存一段时间（Wave B 完成后 1 周）；之后 `/home` redirect 301 到 `/today`；下一个版本删 `/home` 路由
- web 端旧 `/memos/[id]` page 直接替换；旧组件文件归档到 `/_legacy`，2 个 sprint 后删除
- iOS 端旧 `TodayView` 重命名为 `TodayViewLegacy`，feature flag 切换；validated 后删除

### 7.6 性能预算

| 指标 | 预算 | 说明 |
|---|---|---|
| Today 首屏 LCP | ≤ 1.2s | Web Vitals 标准 |
| Today TTI | ≤ 2.0s | |
| 卡片滑动 FPS | ≥ 55fps | 60fps 目标 |
| Drawer 入场动画 | ≥ 55fps | 280ms 全程不掉帧 |
| Web bundle 增量 | ≤ +30KB gzip | 不含字体 |
| 字体加载 | FCP 阶段不阻塞 | 用 `font-display: swap` |
| API 响应 p95 | ≤ 200ms | 所有 §8 endpoints |
| Share Card 导出 | ≤ 1.5s | Web；iOS ≤ 0.8s |

### 7.7 测试与验证

见 §15 Test Matrix。

---

## 8. API Contracts & Schema

### 8.1 现有 schema 字段（仅引用，不改动）

| Table | Field | Type | 用途 |
|---|---|---|---|
| `users` | `id` | uuid | 主键 |
| `users` | `email` | text | NextAuth |
| `users` | `name` | text | Drawer profile |
| `users` | `avatar_url` | text | 可选 |
| `users` | `created_at` | timestamp | Drawer SINCE 年份 |
| `users` | `settings` | jsonb | 见 §8.3 |
| `memos` | `id` | uuid | 主键 |
| `memos` | `user_id` | uuid | FK |
| `memos` | `body` | text | 正文 |
| `memos` | `kind` | enum | text / voice / photo / mixed |
| `memos` | `location` | text | |
| `memos` | `place` | text | |
| `memos` | `weather` | text | |
| `memos` | `humidity` | int | |
| `memos` | `photo_url` | text | |
| `memos` | `path` | text | vault path |
| `memos` | `content_hash` | text | sha256 |
| `memos` | `created_at` | timestamp | |
| `pages` | `id` | uuid | |
| `pages` | `user_id` | uuid | |
| `pages` | `date_slug` | text | YYYY-MM-DD |
| `pages` | `title` | text | |
| `pages` | `summary` | text | AI lede |
| `pages` | `body` | text | |
| `pages` | `tags` | text[] | |
| `pages` | `memo_count` | int | |
| `pages` | `word_count` | int | |
| `pages` | `created_at` | timestamp | |

### 8.2 新增 endpoints

#### 8.2.1 `GET /api/today/header`

返回 Today Hero 区域所需数据。

**Request**: no params (auth required)

**Response 200**:
```json
{
  "weekday": "Thursday",
  "weekday_zh": "周四",
  "date_iso": "2026-05-28",
  "date_display": "MAY 28",
  "memo_count": 2,
  "weather": {
    "temp": 28,
    "condition": "多云",
    "icon": "cloud-sun"
  },
  "location": "VIENTIANE"
}
```

**Response 401/500**: standard error.

**Cache**: 5 min (weather invalidation key)

---

#### 8.2.2 `GET /api/today/ai-summary`

返回当天的 AI 一句话总结。

**Request**: no params (auth required)

**Response 200**:
```json
{
  "summary": "热得动不了 — 咖啡馆是今天唯一能躲下午的地方。",
  "generated_at": "2026-05-28T15:32:14Z",
  "is_stale": false,
  "memo_count_at_generation": 2
}
```

**Response 404** (无 memo): `{"summary": null, "memo_count": 0}`

**Cache**: invalidate on new memo

---

#### 8.2.3 `GET /api/today/week-feed?limit=7`

返回本周 spine feed 数据。

**Response 200**:
```json
{
  "items": [
    {
      "id": "uuid",
      "date_slug": "2026-05-27",
      "day": "WED",
      "date_display": "05·27",
      "title": "重访市区青旅旁精品咖啡馆",
      "lede": "一个十平米不到的小店，却装下了本地人下班后全部的轻松。",
      "tags": ["VIENTIANE", "CAFE"],
      "word_count": 412,
      "memo_count": 1
    }
  ]
}
```

---

#### 8.2.4 `GET /api/stats/heatmap?weeks=16`

返回热力图数据。

**Response 200**:
```json
{
  "weeks": 16,
  "from": "2026-02-05",
  "to": "2026-05-28",
  "cells": [
    {"day": "2026-02-05", "count": 0},
    {"day": "2026-02-06", "count": 3},
    {"day": "2026-05-28", "count": 2}
  ],
  "streak": 23
}
```

**SQL**:
```sql
SELECT date_trunc('day', created_at)::date AS day, count(*)::int AS count
FROM memos
WHERE user_id = $1 AND created_at >= now() - interval '16 weeks'
GROUP BY day
ORDER BY day;
```

**Cache**: 1 hour，invalidate on new memo（用户级）

**Performance optimization**：若用户 memo 总数 > 5000，回退到读 `users.heatmap_cache_json` 列（cron 每 6h 预计算）。

---

#### 8.2.5 `GET /api/stats/drawer`

返回 Drawer 三联卡数据。

**Response 200**:
```json
{
  "streak_days": 23,
  "pages_total": 142,
  "words_this_year": 58234,
  "words_this_year_display": "58k"
}
```

---

#### 8.2.6 `GET /api/stats/recent?limit=7`

返回 Drawer Recent 列表。

**Response 200**:
```json
{
  "items": [
    {
      "date_slug": "2026-05-28",
      "day": "THU",
      "date_display": "05·28",
      "title": "Today",
      "memo_count": 2,
      "is_today": true
    }
  ]
}
```

---

#### 8.2.7 `GET /api/img/{memo_id}` (proxy)

Same-origin proxy for cross-origin photos，用于 Share Card 导出 CORS-safe。

**Auth**: user must own the memo

**Response**: image bytes with `Cache-Control: public, max-age=86400`

### 8.3 Schema 新增字段

**`users.settings`** (jsonb) 新增 key：

```typescript
type UserSettings = {
  // existing keys preserved...
  unlock_threshold?: number;       // 默认 3，今日成稿解锁阈值
  share_template_default?: 'minimal' | 'film' | 'polaroid' | 'journal' | 'postcard';
  title_font_pref?: 'serif' | 'sans';
  heatmap_cache_json?: {           // optional, 仅 power user
    generated_at: string;
    cells: Array<{day: string; count: number}>;
  };
}
```

无 migration —— jsonb 字段直接读写。

### 8.4 Live Activity Payload (iOS only)

```swift
struct RecordingActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    var elapsed: TimeInterval      // 0...300
    var isRecording: Bool
    var currentDB: Double          // -60...0
  }
  // static attributes (set once)
  var startTime: Date
}
```

---

## 9. Security & Privacy

### 9.1 数据隐私

- **录音音频**：仅本地存储在 `vault/raw/assets/`，转写完成后用户可选删除；不上传服务器
- **位置数据**：精度限定为城市级（市/区），不存经纬度 6 位小数（最多 2 位）
- **照片**：本地存储 + iCloud Drive 同步（用户授权）；上传到 web 时走端到端加密（v9 范围；v8 沿用现状）
- **AI 转写**：iOS 优先 `SFSpeechRecognizer` 本地；fallback 走 Whisper API（合规：发送前剥离 EXIF / 位置元数据）
- **AI Summary**：发给 DashScope 的 prompt 仅含 memo body（不含 location / photo），不含用户邮箱 / id

### 9.2 权限请求

| 权限 | 何时请求 | Fallback |
|---|---|---|
| 麦克风（iOS） | 首次长按录音 | 拒绝 → toast `需要麦克风权限 · 去设置` |
| 位置（iOS） | 首次发 memo / Attach sheet 选位置 | 拒绝 → 跳过位置字段 |
| 相册写入（iOS） | 首次 Share Card 导出 | 拒绝 → 仅调起系统分享菜单 |
| 通知（iOS） | 首次 Live Activity 录音结束 | 拒绝 → 沿用屏幕内 banner |
| 麦克风（Web） | 首次长按录音 | 同上 |
| 地理位置（Web） | 首次选位置 | 同上 |

### 9.3 输入消毒

- Memo body：渲染前用 `sanitize-html`（Web）/ `AttributedString` safe init（iOS）防 XSS
- AI Summary：DashScope 返回值同样消毒
- URL 链接检测：仅识别 `http://` / `https://` 协议，剥离 `javascript:` / `data:`

### 9.4 速率限制（沿用现有）

- `/api/today/ai-summary` 每用户每小时 60 次
- `/api/stats/*` 每用户每分钟 30 次
- 录音转写每用户每天 200 分钟上限

---

## 10. Performance Budget & Telemetry

### 10.1 Bundle 预算（Web）

| Chunk | 预算 | 当前 | Δ |
|---|---|---|---|
| App shell | ≤ 95KB gzip | ~78KB | +17KB |
| Today page | ≤ 45KB gzip | ~28KB | +17KB |
| Memo Detail | ≤ 40KB gzip | new | +40KB |
| Share modal | ≤ 50KB gzip (lazy) | new | +50KB |
| Fonts (Fraunces) | ≤ 35KB subset | new | +35KB |
| Fonts (Caveat) | ≤ 12KB subset | new | +12KB |

### 10.2 Runtime 预算

- 卡片滑动：每帧 < 18ms（55fps 底线，60fps 目标）
- Drawer 入场：280ms 全程不掉帧
- Heatmap render：< 50ms（一次性 SVG draw）
- AI Summary 打字机：每 tick < 5ms

### 10.3 关键 telemetry events

| Event | 何时 | Properties |
|---|---|---|
| `today_screen_view` | Today 屏加载 | `memo_count`, `has_ai_summary`, `device_class` |
| `memo_card_swipe` | 卡片左滑揭示 | `memo_id`, `final_state: opened/closed` |
| `memo_card_tap` | 卡片点击 | `memo_id` |
| `recording_start` | 长按触发 | `source: composer/island` |
| `recording_end` | 停止录音 | `duration_ms`, `action: cancel/save`, `transcript_length` |
| `share_card_view` | 进分享屏 | `template`, `memo_id` |
| `share_card_exported` | 导出 PNG | `template`, `kind`, `has_photo`, `duration_ms` |
| `drawer_open` | 打开侧边 | `source: hamburger/island` |
| `heatmap_cell_tap` | 点格子 | `date`, `count` |
| `unlock_threshold_met` | 达到解锁 | `memos_today` |

### 10.4 错误 telemetry

- 所有 API 失败上报 Sentry（已接入），含 `endpoint` / `status` / `user_id`(hashed)
- 客户端 JS error 上报 Sentry
- iOS crash 上报 Sentry-cocoa（已接入）

---

## 11. Accessibility (a11y)

### 11.1 WCAG 2.1 AA 合规

- **Contrast**：
  - `--fg-primary` on `--bg-warm` = 15.5:1 ✅ AAA
  - `--fg-muted` on `--bg-warm` = 5.4:1 ✅ AA
  - `--fg-subtle` on `--bg-warm` = 2.5:1 ⚠️ 仅用于 large text (≥ 18.66px bold 或 ≥ 24px regular)
  - `--accent` on `--bg-warm` = 10.9:1 ✅ AAA
- **触控目标**：所有 interactive 元素 ≥ 44×44pt (iOS) / 44×44px (Web)
- **键盘可达**：所有交互可 Tab 到达，Enter/Space 激活
- **focus-visible**：所有按钮 `outline: 2px solid var(--accent) / outline-offset: 2px`
- **focus trap**：Drawer / Attach sheet / Recording sheet / lightbox / Share modal

### 11.2 prefers-reduced-motion

- 全局动画退化：duration 0.01ms / 不循环
- 打字机入场 → 直接显示全文
- pulse / breathe / shimmer → 静态
- spring 弹性 → 替换为 ease-out 短动画

### 11.3 ARIA

- Today H1 用 `<h1>` 真语义
- SectionLabel 用 `<h2 role="heading" aria-level="2">`
- Drawer `role="dialog" aria-modal="true"`
- AI Summary `<blockquote aria-live="polite">`
- Memo Card 内部用 `<article>`
- Composer 麦克风按钮 `aria-pressed` 反映 recording 态
- 装饰元素（Dot / spine line / halo）一律 `aria-hidden="true"`

### 11.4 屏幕阅读器

- iOS：VoiceOver 测试所有 6 个核心屏 + 4 个 sheet/modal
- Web：NVDA / JAWS 测试关键路径

### 11.5 字体缩放

- iOS 支持 Dynamic Type（最大 `.accessibility5`）
- Web 支持 `font-size: clamp(...)` 跟随用户 zoom

---

## 12. Error States & Edge Cases

### 12.1 网络错误

| 场景 | 行为 |
|---|---|
| Today API 超时 | 显示骨架，5s 后 fallback 到本地 cache |
| AI Summary 失败 | 占位 `今天还没攒够话` |
| Heatmap 失败 | 全 empty 格子 + 重试按钮 |
| 图片加载失败 | `var(--surface-sunken)` 背景 + `图片加载失败` mono 文字 + 重试 link |
| Share 导出失败 | toast `导出失败，请重试` |

### 12.2 空态

| 屏 | 空态文案 |
|---|---|
| Today 无 memo | `今天还没记 — 长按 🎙️ 开始` |
| 本周 wiki 无 page | `本周还未成稿 — 多记几条今日会自动生成` |
| Drawer Recent 无 page | `还没有成稿的日页` |
| Memo Detail 无 location | 不渲染 Location 卡 |
| Memo Detail 无 photo | 不渲染 Hero photo 区 |

### 12.3 边界数据

- 极长 memo body（> 10k 字符）：列表卡截断到 200 字 + 渐变蒙版；详情页正常显示
- 极长 place name（> 50 char）：单行 ellipsis；详情标题最多 2 行后 ellipsis
- 极多 memo（一天 > 50 条）：列表虚拟滚动（Web 用 react-window，iOS 用 LazyVStack）
- 极多 page tag（> 20）：footer 行最多 5 个 + `+15` 折叠

### 12.4 权限拒绝

- 麦克风：长按时 toast，引导到 Settings
- 位置：跳过位置字段，memo 仍可保存
- 相册：fallback 系统分享菜单（不保存到相册）

### 12.5 时区与日期

- 所有日期按 **用户本地时区** 计算（不是 UTC）
- 跨日界 memo：基于 `created_at` 在用户时区下的日期归类
- 时区切换（用户漫游）：保留 memo 原时区 metadata（`memos.tz`），显示按当前时区

---

## 13. Internationalization

### 13.1 v8 策略

**只支持简体中文 (zh-CN)**。

- 所有 user-facing 字符串走 i18n key（`web/src/i18n/zh-CN.json` + iOS `Localizable.strings`），不 hardcode
- Mono caps 装饰文字（`DAYPAGE · 2026` / `WEATHER` / `MORE` 等）保持英文 — 视觉风格的一部分
- 日期格式用 `Intl.DateTimeFormat('zh-CN', ...)` / `Date.FormatStyle.locale("zh-CN")`
- 天气描述（`多云` / `晴`）走 OpenWeatherMap `lang=zh_cn`

### 13.2 后续扩展（v9 范围）

- en-US / ja-JP / ko-KR 三语
- 字体按 locale 切换（ja 用 Noto Serif JP）

---

## 14. Analytics & Observability

### 14.1 接入

- **Web**：PostHog（已接入），event 直接 fire；
- **iOS**：Sentry-cocoa + PostHog iOS SDK；
- **AI Summary / 录音转写**：Inngest run 失败上报 Sentry

### 14.2 关键 dashboard

- Today 屏漏斗：屏加载 → 看到 AI summary → 至少看到 1 条 memo → 触发 composer
- 录音漏斗：长按 → 录音中 → 停止并转写 → 保存
- Share Card 漏斗：进分享屏 → 切模板 → 导出
- 性能：Today LCP / Memo Detail TTI / Heatmap render time（p50/p95）

### 14.3 告警

- Sentry 错误率 > 1% (1h 窗口) → Slack `#daypage-alerts`
- API p95 > 500ms (15min 窗口) → 同上
- Web Vitals LCP > 2s (用户 > 100) → 同上

---

## 15. Test Matrix

### 15.1 单元测试

| 模块 | 覆盖 |
|---|---|
| Rubber-band 公式 | 边界值 0 / -66 / -132 / -164 / -200 |
| 长按 timer | 219ms (fail) / 220ms (trigger) / 释放后取消 |
| Streak 计算 | 0 / 1 / 连续 / 中断 / 含未来日 |
| 大数字格式化 | 999 / 1000 / 1500 / 58234 / 1500000 |
| LIGHT 时间分类 | 04:59 / 05:00 / 11:59 / 12:00 / 18:59 / 19:00 |
| Date slug 格式 | 2026-01-01 / 跨时区 |

### 15.2 集成测试

| API | 测试 |
|---|---|
| `/api/today/header` | 有 memo / 无 memo / 无 weather / unauthorized |
| `/api/today/ai-summary` | 已生成 / stale / 无 memo / DashScope 失败 |
| `/api/today/week-feed` | limit=7 / limit=0 / 无 page |
| `/api/stats/heatmap` | 16w / streak 计算 / 大数据量 (>10k memo) |
| `/api/stats/drawer` | 默认 / 0 page / 0 memo |
| `/api/img/{id}` | 跨域 / 同源 / 无权限 |

### 15.3 视觉回归测试

每个 PR 必须附 6 个 baseline 截图 before/after：

1. Today 屏（默认 / 未滚动）
2. Today 屏（滚动后 glass 顶栏）
3. Memo Detail 屏（混合类型，有照片有地点）
4. Drawer 打开（含热力图 + 三联卡）
5. Recording sheet 录音中
6. Share Card minimal 模板

**工具**：Web 用 Playwright + Percy；iOS 用 Xcode 内置 snapshot test。

### 15.4 端到端 E2E

| 场景 | 路径 |
|---|---|
| 录音保存 | Today → 长按 🎙️ → 说话 5s → 停止并转写 → 出现新 memo |
| 卡片左滑分享 | 卡片左滑 → 点 SHARE → Share screen → 切模板 → 导出 |
| 详情页跳转 | Today 卡片 tap → Memo Detail → 顶栏 ← → Today |
| 抽屉导航 | Today hamburger → Drawer → 点 Navigate 成稿 → /wiki |
| 解锁占位 | 记 3 条 memo → 占位卡淡出 |

**工具**：Web 用 Playwright；iOS 用 XCUITest。

### 15.5 性能测试

- Lighthouse CI（Web）每 PR 跑一遍，阈值见 §10.1-10.2
- iOS Instruments：Time Profiler 验证卡片滑动 60fps；Allocations 验证 Drawer 入场无内存峰值

### 15.6 a11y 测试

- axe DevTools（Web）每 PR 跑，0 critical/serious 违规
- Accessibility Inspector（iOS）手动跑核心 6 屏

---

## 16. Rollout Plan

### 16.1 阶段

1. **S1-S8**：开发（30-40 工作日，见 §19）
2. **Alpha 内测**（1 周）：仅 Eric + 10 内测用户，feature flag `v8_enabled` 控制
3. **Beta 公测**（1 周）：iOS TestFlight + web staging.daypage.app，50 用户
4. **Production GA**：全量开启

### 16.2 Feature flag

- **iOS**：用 `UserDefaults` 本地 flag `daypage.v8.enabled`，TestFlight 配置默认 true
- **Web**：用 GrowthBook（已接入）控制；按用户 ID hash 灰度（10% → 50% → 100%）
- 紧急 kill switch：远程 disable flag，回退到旧 UI

### 16.3 数据迁移

无 schema 变更，无需迁移。

### 16.4 回滚方案

- iOS：保留 `TodayViewLegacy` / `MemoDetailLegacy` / `DrawerLegacy` 2 个 sprint；flag flip 回旧
- Web：feature flag 立即关闭 → 走旧 `/home` 路由（保留 1 个 sprint 后删）

### 16.5 公告

- iOS Release Notes 中英文双语
- Web 站内 banner（首次登录）
- README.md / CHANGELOG.md 更新

---

## 17. Risk Register

| ID | 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|---|
| R-1 | Live Activity API 在某些 iOS 设备表现不一致 | 中 | 中 | TestFlight 多设备测试；fallback 本地 banner |
| R-2 | Fraunces 字体加载慢导致 FOIT | 中 | 低 | `font-display: swap` + system serif fallback |
| R-3 | html-to-image 在跨域照片上失败 | 高 | 中 | `/api/img/{id}` proxy（§8.2.7） |
| R-4 | Heatmap SQL 在大数据量下慢 | 中 | 中 | `heatmap_cache_json` 预计算（cron 6h） |
| R-5 | 长按手势在 desktop 鼠标不直观 | 中 | 低 | Desktop fallback 改为 hover-then-click，移动端 only 长按 |
| R-6 | 旧 `/home` redirect 影响 SEO / 老链接 | 低 | 低 | 301 permanent redirect 至少保留 6 月 |
| R-7 | Drawer 热力图渲染 16×7 = 112 cells，每次 React 更新成本高 | 中 | 中 | 用单次 SVG draw，不 React-render 每个 cell |
| R-8 | 录音时切到后台 30s 超时，用户期望可以更长 | 中 | 中 | 用 `AVAudioSession` 后台 mode 延长至 5min；记录用户偏好 |
| R-9 | Share Card 字体在某些设备未加载完毕就导出 | 中 | 中 | `await document.fonts.ready` 必须 |
| R-10 | 触觉反馈在低端 Android 设备（Web）不存在 | 低 | 低 | feature-detect `navigator.vibrate`，缺省静默 |
| R-11 | 视觉回归测试基线在 OS 升级后失效 | 中 | 低 | snapshot test 容忍 5px diff；季度 review baseline |
| R-12 | 中文字体渲染（PingFang）和设计稿 latin 字体度量不匹配 | 中 | 中 | 中英混排时单独定义 line-height（中文用 1.7，英文 1.5） |

---

## 18. Success Metrics

### 18.1 体验指标

- **录音首字 ≤ 350ms**（长按 220ms + sheet 入场动画 320ms 中点的 50%）
- **Today 首屏 LCP ≤ 1.2s**
- **卡片滑动 ≥ 55fps**
- **Share Card 导出 ≤ 1.5s**

### 18.2 设计一致性

- 设计稿 → 实现的视觉 diff 在 hero / card / button 三类元素上 **像素差异 < 4px**
- 所有 6 个核心屏的 SwiftUI / React 实现都引用 `design-tokens`，**0 个 hardcode 颜色**
- a11y 测试 0 critical/serious 违规

### 18.3 产品指标

- 用户每日 memo 数中位数：基线 1.2 → ≥ 2
- "再记一条解锁今日成稿"占位卡的转化率（看到 → 当日补记 1+ 条）≥ 35%
- 分享卡片导出次数（首月）：≥ 50 次
- DAU/MAU 比例：基线 0.42 → ≥ 0.55
- 录音 memo 占比：基线 18% → ≥ 35%

### 18.4 工程指标

- v8 上线后 30 天内 Sentry 错误率 ≤ 0.5%
- API p95 ≤ 200ms
- Web bundle 增量 ≤ +30KB gzip（不含字体）
- 单 PR 平均周转时间 ≤ 2 天

---

## 19. Sprint Plan

| Sprint | Wave | 故事 | 工期 | 交付 |
|---|---|---|---|---|
| **S1** | Wave A · 设计系统底座 | US-001 ~ US-004 | 3-4 天 | tokens.json + GlassPill + SectionLabel 可在 storybook / SwiftUI preview 看见 |
| **S2** | Wave B-1 · Today 骨架 | US-005 ~ US-008 | 3 天 | Today 顶栏 + Hero + Segmented + AI Summary 上线 |
| **S3** | Wave B-2 · Today 内容 | US-009 ~ US-011 | 4-5 天 | Memo Card 左滑 + 解锁占位 + 本周 Spine Feed |
| **S4** | Wave C · Memo Detail | US-012 ~ US-018 | 5-6 天 | 详情页 7 个组件全部上线 + ⋯ 菜单 |
| **S5** | Wave D · Drawer + 热力图 | US-019 ~ US-025 | 4-5 天 | Drawer 7 个组件 + `/api/stats/heatmap` |
| **S6** | Wave E · 录音体验 | US-026 ~ US-030 | 5-6 天 | Composer + Recording + 灵动岛（含 iOS Live Activity） |
| **S7** | Wave F · Share Card | US-031 ~ US-033 | 3-4 天 | 5 个模板 + PNG 导出 |
| **S8** | 收尾 / Polish | 视觉回归 + 性能优化 + bug fix + a11y 审查 | 3-5 天 | v8 GA |

**总工期估算**：30-40 个工作日（约 6-8 周，单人节奏）。

**关键里程碑**：
- S2 end：内部可看见 Today 新骨架，提交第一次设计审查
- S5 end：核心 4 屏完成，开 Alpha 内测
- S7 end：所有 wave 完成，进 Beta 公测
- S8 end：GA

---

## 20. Open Questions

1. **Live Activity 需要 iOS 16.1+，当前 deployment target 是 iOS 16.0** — 是否同意 bump 到 16.1？影响约 0.5% 老设备用户。
2. **Fraunces 字体许可** — Google Fonts SIL OFL，无障碍，但 web bundle 会大 ~35KB subset。是否接受？
3. **Share Card 导出在 web 上需要 CORS-safe 图片** — 已设计 `/api/img/{memo_id}` proxy（§8.2.7）。是否同意？
4. **`/api/stats/heatmap` 性能** — 已设计 `heatmap_cache_json` 预计算 fallback（§8.2.4）。是否同意 cron 6h？
5. **解锁阈值** — `unlock_threshold` 默认 3 太严格还是太松？是否做成 personalized adaptive？
6. **Composer Pill 在桌面 web** — 已决定 < 768px 浮，≥ 768px 左下角固定。是否 OK？
7. **iOS ⋯ 菜单 内容确认** — 已列出 5 项（转移 / 复制 / 标记 / 导出 PDF / 删除）。删除需要二次确认。是否同意？
8. **Verifier baseline 截图** — 用 `/tmp/daypage-design/daypageapp/project/screenshots/` 作为 source of truth？需先复制到 `docs/design-handoffs/2026-05-28-v8/`。
9. **AI Summary 速率限制** — 是否允许用户手动 `重新生成`？若是，速率限制 5次/天/用户？
10. **录音上限 5min** — 是否合理？还是需要 10min？涉及到本地存储压力。

---

## 21. Glossary

| 术语 | 含义 |
|---|---|
| Memo | 单条原始记录（文本/语音/照片/混合） |
| Page | AI 编译后的日页 / wiki entry |
| Domain | 由 page_links 聚合的主题域 |
| Wave | 一组同主题的 user story 集合（A-F） |
| Sprint | 一个时间盒，对应一个 Wave |
| Rubber-band | iOS 风格的过界阻尼回弹 |
| Spine feed | 美术馆挂轴式垂直信息流 |
| Hairline | 0.5px 极细分隔线 |
| Live Activity | iOS 16.1+ 灵动岛后台活动 |
| Ma (間) | 日式设计中的负空间 / 留白 |
| Glass / Frosted glass | backdrop-filter blur 玻璃效果 |
| Snap | 拖动后自动归位到固定位置 |

---

## 22. Appendix A · 代码片段参考

### A.1 Rubber-band 公式（Memo Card 左滑）

```typescript
// web/src/lib/gestures/rubberBand.ts
const REVEAL = 132;
const OVERSHOOT = 32;
const DAMP = 0.18;

export function applyRubberBand(rawTx: number): number {
  if (rawTx > 0) return rawTx * DAMP;
  if (rawTx < -REVEAL - OVERSHOOT) {
    return -REVEAL - OVERSHOOT + (rawTx + REVEAL + OVERSHOOT) * DAMP;
  }
  return rawTx;
}

export function snapTarget(committedTx: number): 0 | -132 {
  return committedTx < -REVEAL / 2 ? -REVEAL : 0;
}
```

### A.2 Waveform hook（Recording Sheet）

```typescript
// web/src/lib/audio/useWaveform.ts
export function useWaveform(active: boolean, count = 56) {
  const [bars, setBars] = useState<number[]>(() => Array(count).fill(2));
  const rafRef = useRef(0);
  const tickRef = useRef(0);

  useEffect(() => {
    if (!active) { setBars(Array(count).fill(2)); return; }
    const loop = () => {
      tickRef.current += 1;
      setBars(prev => {
        const next = prev.slice(1);
        const phase = tickRef.current * 0.18;
        const env = 0.55 + 0.45 * Math.sin(phase * 0.4);
        const v = 4 + Math.abs(
          Math.sin(phase) * 14 +
          Math.cos(phase * 2.7) * 8 +
          (Math.random() - 0.5) * 6
        ) * env;
        next.push(Math.max(2, Math.min(28, v)));
        return next;
      });
      rafRef.current = requestAnimationFrame(loop);
    };
    rafRef.current = requestAnimationFrame(loop);
    return () => cancelAnimationFrame(rafRef.current);
  }, [active, count]);

  return bars;
}
```

### A.3 Streak 计算

```typescript
// shared 算法
export function computeStreak(
  cells: Array<{day: string; count: number}>
): number {
  // sort desc by day
  const sorted = [...cells].sort((a, b) => b.day.localeCompare(a.day));
  let streak = 0;
  const today = new Date().toISOString().slice(0, 10);
  let cursor = today;
  for (const cell of sorted) {
    if (cell.day > cursor) continue;       // future, skip
    if (cell.day < cursor) break;          // gap, stop
    if (cell.count > 0) {
      streak += 1;
      // step back one day
      const d = new Date(cursor);
      d.setDate(d.getDate() - 1);
      cursor = d.toISOString().slice(0, 10);
    } else {
      break;
    }
  }
  return streak;
}
```

### A.4 SwiftUI 长按手势

```swift
// DayPage/App/Components/DSMicButton.swift
struct DSMicButton: View {
  @State private var pressTask: Task<Void, Never>?
  let onTap: () -> Void
  let onLongPress: () -> Void

  var body: some View {
    Image(systemName: "mic.fill")
      .frame(width: 64, height: 56)
      .background(LinearGradient(...))
      .clipShape(Capsule())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in
            if pressTask == nil {
              pressTask = Task {
                try? await Task.sleep(nanoseconds: 220_000_000)
                if !Task.isCancelled {
                  UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                  await MainActor.run { onLongPress() }
                }
              }
            }
          }
          .onEnded { _ in
            let isLongPress = pressTask?.isCancelled == false
            pressTask?.cancel()
            pressTask = nil
            if !isLongPress { onTap() }
          }
      )
  }
}
```

---

## 23. Appendix B · 设计 token 完整 JSON

```json
{
  "$schema": "./tokens.schema.json",
  "version": "8.0.0",
  "colors": {
    "bg-warm": "#FAF8F6",
    "surface-white": "#FFFFFF",
    "surface-sunken": "#F3F0EB",
    "fg-primary": "#2B2822",
    "fg-muted": "#6B6560",
    "fg-subtle": "#A39F99",
    "accent": "#5D3000",
    "accent-hover": "#7A3F00",
    "accent-soft": "#F5EDE3",
    "accent-border": "#E8DCCA",
    "border-subtle": "#EDE8DF",
    "border-default": "#D6CEC0",
    "heatmap-empty": "#F0EBE3",
    "heatmap-low": "#E6D9C3",
    "heatmap-mid": "#C9A677",
    "heatmap-high": "#5D3000",
    "recording-red": "#E36B4A",
    "recording-bg": "#2D1E0C"
  },
  "fonts": {
    "display": "Space Grotesk",
    "serif": "Fraunces",
    "body": "Inter",
    "mono": "JetBrains Mono",
    "handwrite": "Caveat"
  },
  "fontSize": {
    "hero": 56,
    "title-xl": 34,
    "title-lg": 30,
    "title-md": 22,
    "title-sm": 21,
    "subhead": 19,
    "body-lg": 16.5,
    "body": 16,
    "body-sm": 14.5,
    "body-xs": 13.5,
    "mono-md": 13,
    "mono-sm": 11.5,
    "mono-xs": 11,
    "mono-2xs": 10,
    "mono-3xs": 9
  },
  "radii": {
    "small": 8,
    "card": 14,
    "hero": 18,
    "week": 22,
    "sheet": 28,
    "recording": 34,
    "island": 24,
    "pill": 999
  },
  "shadows": {
    "card": "0 1px 2px rgba(0,0,0,0.04)",
    "pill-inset": "inset 0 0.5px 0 rgba(255,255,255,0.6)",
    "pill-drop": "0 1px 2px rgba(0,0,0,0.05)",
    "composer": "0 2px 6px rgba(60,40,15,0.08), 0 18px 32px -12px rgba(60,40,15,0.22)",
    "attach": "0 24px 60px -20px rgba(60,40,15,0.35)",
    "recording": "0 24px 60px -16px rgba(40,25,5,0.55)",
    "drawer": "10px 0 40px -12px rgba(60,40,15,0.22)"
  },
  "spacing": {
    "card-inner": 20,
    "card-gap": 16,
    "section-gap": 24,
    "ma-week-feed": 30
  },
  "motion": {
    "spring": "cubic-bezier(.2,.8,.2,1)",
    "ease-out": "ease-out",
    "fast": 220,
    "medium": 280,
    "slow": 320,
    "island": 360
  },
  "gestures": {
    "swipe-reveal-width": 132,
    "swipe-overshoot": 32,
    "swipe-damp": 0.18,
    "long-press-ms": 220,
    "drag-vs-tap-threshold": 6,
    "sheet-close-threshold": 80
  }
}
```

---

## 24. Appendix C · API 响应 fixtures

### Fixture-1：`GET /api/today/header`

```json
{
  "weekday": "Thursday",
  "weekday_zh": "周四",
  "date_iso": "2026-05-28",
  "date_display": "MAY 28",
  "memo_count": 2,
  "weather": { "temp": 28, "condition": "多云", "icon": "cloud-sun" },
  "location": "VIENTIANE"
}
```

### Fixture-2：`GET /api/today/ai-summary`

```json
{
  "summary": "热得动不了 — 咖啡馆是今天唯一能躲下午的地方。",
  "generated_at": "2026-05-28T15:32:14Z",
  "is_stale": false,
  "memo_count_at_generation": 2
}
```

### Fixture-3：`GET /api/today/week-feed?limit=7`

```json
{
  "items": [
    {
      "id": "01H8...",
      "date_slug": "2026-05-27",
      "day": "WED",
      "date_display": "05·27",
      "title": "重访市区青旅旁精品咖啡馆",
      "lede": "一个十平米不到的小店，却装下了本地人下班后全部的轻松。门口的猫和老板娘都认人。",
      "tags": ["VIENTIANE", "CAFE"],
      "word_count": 412,
      "memo_count": 1
    }
  ]
}
```

### Fixture-4：`GET /api/stats/heatmap?weeks=16`

```json
{
  "weeks": 16,
  "from": "2026-02-05",
  "to": "2026-05-28",
  "cells": [
    { "day": "2026-02-05", "count": 0 },
    { "day": "2026-02-06", "count": 3 },
    { "day": "2026-05-27", "count": 1 },
    { "day": "2026-05-28", "count": 2 }
  ],
  "streak": 23
}
```

### Fixture-5：`GET /api/stats/drawer`

```json
{
  "streak_days": 23,
  "pages_total": 142,
  "words_this_year": 58234,
  "words_this_year_display": "58k"
}
```

### Fixture-6：`GET /api/stats/recent?limit=7`

```json
{
  "items": [
    {
      "date_slug": "2026-05-28",
      "day": "THU",
      "date_display": "05·28",
      "title": "Today",
      "memo_count": 2,
      "is_today": true
    },
    {
      "date_slug": "2026-05-27",
      "day": "WED",
      "date_display": "05·27",
      "title": "重访市区青旅旁精品咖啡馆",
      "memo_count": 1,
      "is_today": false
    }
  ]
}
```

---

## 25. References

### 25.1 设计源

- 设计 bundle：`/tmp/daypage-design/daypageapp/`（Claude Design handoff, 2026-05-28）
- 设计 chat 转录：`/tmp/daypage-design/daypageapp/chats/chat1.md`
- 核心 JSX 实现参考：
  - `app.jsx` — Today / WeekFeed / MemoCard / AISummary
  - `composer.jsx` — ComposerPill / RecordingSheet / DynamicIslandLive / useWaveform
  - `detail.jsx` — MemoDetail / Drawer / DrawerHeatmap / ShareCard / 5 个模板

### 25.2 现有 PRD（避免重复 / 冲突）

- `tasks/prd-daypage-v6-deep-experience.md`
- `tasks/prd-daypage-v7-deep-audit.md`
- `tasks/prd-today-composer-liquid-refinement.md`
- `tasks/design-watch-recording.md`
- `tasks/design-icloud-sync.md`

### 25.3 项目文档

- iOS 项目结构指南：`CLAUDE.md`（项目根）
- Web 端：`web/CLAUDE.md`（若存在）

### 25.4 外部规范

- WCAG 2.1 AA：https://www.w3.org/TR/WCAG21/
- iOS Human Interface Guidelines：https://developer.apple.com/design/human-interface-guidelines
- Apple ActivityKit：https://developer.apple.com/documentation/activitykit
- Web Vitals：https://web.dev/vitals/

---

## 26. Checklist before kickoff

- [ ] Eric 回答 Open Questions 1-10
- [ ] 同意 deployment target bump（如 Q1 为 yes）
- [ ] 切 base 分支 `v8/museum-aesthetic`
- [ ] 在 S1 开始前把 `/tmp/daypage-design/daypageapp/` 备份到 repo 内（`docs/design-handoffs/2026-05-28-v8/`）— bundle 在 /tmp 会过期
- [ ] 设计回归基线截图固定到 `docs/design-baseline/v8/`
- [ ] 开 issue tracker：每个 user story 一个 GitHub issue，label `v8` + `wave:A/B/C/D/E/F`
- [ ] 接入 PostHog / Sentry telemetry 事件（§10.3）
- [ ] 申请 Apple MapKit JS token（Web）/ 确认 iOS MapKit usage（已有）
- [ ] CI 加 `tokens:check` step（生成器 idempotent 验证）
- [ ] CI 加 Lighthouse / axe / Percy 集成
- [ ] Eric review §17 风险登记，确认缓解方案

---

**END of PRD v8 (Production-grade · Single-file · 1.0)**
