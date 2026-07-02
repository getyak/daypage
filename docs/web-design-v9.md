# DayPage Web — Design v9 「CLAUDE 之家」

> 日期:2026-07-02 · 承接:`design-tokens/tokens.json` v8.0.0 + `docs/web-design-vNext.md`
> 定位:v9 只管**视觉与交互的收敛**;`web-design-vNext.md` 管"编织成网"是否发生。两份文档正交,互不覆盖。
> 一句话:把当前已经七成正确的「日式美术馆」再拧一档,让 web 端从"对的方向"到"CLAUDE 会做的样子"。

---

## 0. TL;DR

现状打 72/100 — 色温对、圆角对、字体族对,但**元素散、层级乱、无签名**。
v9 要拧的 6 处:tokens 单源化、elevation 三档、motion 二曲线、Fraunces 仪式化、卡片瘦身、glass drawer。
外加 1 处「签名动作」— `/today` 顶部 Fraunces 日期 hero 的 360ms island spring 淡入。

---

## 1. 与 v8 的差距诊断

| # | 现状 | v9 目标 | 影响面 |
|---|---|---|---|
| 1 | Fraunces 只零星出现在 hero | 明确进入「仪式感场景」:`/today` 日期头、memo 详情标题、weekly recap 引言、wiki concept 页标题 | Typography ritual |
| 2 | dark mode 手写在 `globals.css:153-219` | 迁入 `tokens.json` 的 `dark:` 分支,由生成器统一产出 | Tokens 单源 |
| 3 | 卡面信息密度偏高(时间/正文/照片/标签平铺) | 卡面只留时间+正文+首图,元数据(天气/地点/标签)进 glass drawer 左滑揭示 | `MemoCard` |
| 4 | 阴影是"card 一档 + composer/attach/recording/drawer 硬编码" | 语义化到 3 档:`--elev-flat / --elev-raise / --elev-float`,所有 sheet 走这三档 | Elevation 层级 |
| 5 | `globals.css:1707` reduce-motion workaround 让 HomeStream 动画静默失效 | 修 Lightning CSS 兼容性,恢复 keyframes | Motion 可用性 |
| 6 | 无 UI 回归 & tokens drift 靠人 | 加 tokens drift CI check + Playwright 视觉快照(today/home/wiki) | 稳定性 |

---

## 2. 5 条 CLAUDE 原则 → v9 落地映射

| CLAUDE 原则 | v9 落地 |
|---|---|
| ① 日式美术馆克制美学 | elevation 三档取代散阴影;所有卡片默认 `--elev-flat`;section 分隔用 hairline + mono caps |
| ② 暖棕色统一 | 所有阴影 rgba 从 `(0,0,0,x)` 迁到 `(60,40,15,x)`;dark mode 底色仍用暖调深棕 `#1A1613` 而非纯黑 |
| ③ Glassmorphism 逐层透明 | Drawer 组件从实心 sheet 升级到 backdrop-filter blur(20px) + 0.78 opacity;Safari fallback 走 `@supports` |
| ④ 数据优先隐藏 | `MemoCard` 卡面瘦身;元数据全部左滑揭示;`/wiki` 默认只展示 live,draft 收进侧栏 |
| ⑤ Spring 仪式感 | motion 收敛到 spring + ease-out 两条曲线;签名动作:`/today` 日期 hero 360ms island spring 淡入 |

---

## 3. Tokens 变更(v8 → v9)

### 3.1 新增

```json
{
  "version": "9.0.0",
  "elevation": {
    "flat":  "0 1px 2px rgba(60,40,15,0.04)",
    "raise": "0 2px 6px rgba(60,40,15,0.08), 0 12px 24px -12px rgba(60,40,15,0.14)",
    "float": "0 2px 6px rgba(60,40,15,0.10), 0 24px 48px -16px rgba(60,40,15,0.28)"
  },
  "spacing": {
    "ma-week-feed": 40   // 30 → 40,加大「間」
  },
  "dark": {
    "colors": {
      "bg-warm":         "#1A1613",
      "surface-white":   "#231D17",
      "surface-sunken":  "#1F1914",
      "fg-primary":      "#F0EBE3",
      "fg-muted":        "#B0A89D",
      "fg-subtle":       "#7A7269",
      "accent":          "#E8C39A",
      "accent-hover":    "#F0D2B0",
      "accent-soft":     "#2A2118",
      "accent-border":   "#3B2E22",
      "border-subtle":   "#2C231C",
      "border-default":  "#3B2E22"
    },
    "elevation": {
      "flat":  "0 1px 2px rgba(0,0,0,0.20)",
      "raise": "0 2px 6px rgba(0,0,0,0.30), 0 12px 24px -12px rgba(0,0,0,0.40)",
      "float": "0 2px 6px rgba(0,0,0,0.36), 0 24px 48px -16px rgba(0,0,0,0.55)"
    }
  }
}
```

### 3.2 迁移

- `shadows.card` → 保留(向后兼容),但所有页面代码改用 `elevation.flat`
- `shadows.composer / attach / recording` → 弃用,改用 `elevation.float`
- `shadows.drawer` → 保留(有独立方向语义)

### 3.3 弃用

- 不再新增裸 shadow token — 任何新场景先问「flat / raise / float 够不够」

---

## 4. 签名动作 — HomeHero(在 `/home`)

**为什么放 `/home`,不放 `/today`**:vNext 已定位 `/home` 是桌面知识工作台,是用户每天开机的入口;`/today` 是移动捕获流,标题已经写"Today"了,再放日期是重复。签名动作应该在**入口页**,一开门就说"欢迎来到你的知识 gallery"。

**为什么它是签名**:第一眼看到 `/home` 顶部,一个 Fraunces 34px 的日期(如 "2026 · Jul 02")从上方 12px 慢速 spring 淡入,持续 360ms(用 motion.island 时长),下方 mono caps 一行 `"WED · 14 SOURCES · 5 PAGES · 8 THIS WEEK"`(接入 vNext 的 stats 数据源)。这一下告诉用户:这不是新增 memo 那么随便,是一个被认真组织的知识空间。

**规格**:

```tsx
// web/src/app/(app)/home/HomeHero.tsx
<motion.header
  initial={{ opacity: 0, y: 12 }}
  animate={{ opacity: 1, y: 0 }}
  transition={{
    duration: 0.36,                     // motion.island
    ease: [0.2, 0.8, 0.2, 1],           // motion.spring
  }}
  className="flex flex-col gap-2 px-6 pt-10 pb-8"
>
  <h1 className="font-serif text-[clamp(28px,4vw,34px)] leading-[1.05] tracking-[-0.7px] text-fg-primary">
    2026 · Jul 02
  </h1>
  <p className="font-mono text-[11px] uppercase tracking-[0.14em] text-fg-muted">
    WED · 14 SOURCES · 5 PAGES · 8 THIS WEEK
  </p>
</motion.header>
```

**约束**:
- 只在**每次进入 `/home` 时播一次**(用 `sessionStorage` key `home-hero-played`,同 tab 内 SPA 切走再回来不重播)
- `prefers-reduced-motion` 时直接 `opacity: 1, y: 0`,零延迟
- 桌面 34px,移动端自适应到 28px(clamp)
- stats 数据来自 vNext 的 home 页现有 fetch,不新起接口

---

## 5. 页面级 before → after

### 5.1 `/home`(签名页)

| 元素 | Before | After |
|---|---|---|
| 页首 | 4 联 stats 直接开 | `<HomeHero>` 签名动作(§4),stats 融入 hero 的 mono caps 行 |
| 三 lane 卡阴影 | 各种 shadow-card / 无 | 统一 `--elev-flat`,交互态 hover 到 `--elev-raise` |
| Insights 卡 | 密堆积 | 每张卡前面加 `<SectionLabel>` mono caps,section-gap 24 → 32 |
| Section 分隔 | 无 | hairline `border-t border-border-subtle` + 上下 mono caps 标签 |

### 5.2 `/today`

| 元素 | Before | After |
|---|---|---|
| 页首 | 直接进 WeekFeedSpine | 保持不变(签名动作在 `/home`,`/today` 不重复) |
| WeekFeedSpine | 纵向间距 30px(ma-week-feed) | 40px |
| MemoCard 正面 | 时间+正文+照片+标签+天气+地点 | 时间+正文+首图。其它元数据进 glass drawer |
| MemoCard 阴影 | `--shadow-card` | `--elev-flat` |
| 卡片左滑 | 露出实心 action 按钮 | 露出 glass drawer(§7),操作按钮在 drawer 里 |

### 5.3 `/wiki` + `/wiki/[...slug]`

| 元素 | Before | After |
|---|---|---|
| 页面标题 | Space Grotesk title-lg | Fraunces title-xl(concept/entity 页专用);source 页仍用 Space Grotesk |
| 正文 | body 16 | body-lg 16.5 + line-height 1.72(报纸感) |
| 侧栏"原料区" | 无 | 承接 vNext:draft source 收进右侧栏 collapse |

### 5.4 memo detail(`/memos/[id]`)

| 元素 | Before | After |
|---|---|---|
| 顶部时间 | Space Grotesk subhead | Fraunces title-md + mono caps 元数据(天气/地点)一行 |
| 正文 line-height | 1.62 | 1.72 |
| 底部空白 | 40px | 32px(和 iOS 端 memo detail 对齐) |

### 5.5 `/settings`

| 元素 | Before | After |
|---|---|---|
| 分组卡 | 各种 shadow | 统一 `--elev-flat` + `border border-border-subtle` |
| Section 标题 | 无统一样式 | `<SectionLabel>` mono caps 10px |

### 5.6 `/insights`

| 元素 | Before | After |
|---|---|---|
| 图表卡阴影 | shadow-card | `--elev-flat` |
| 数据字体 | mixed | 大数字统一 JetBrains Mono + tabular-nums |

---

## 6. Elevation 三档使用规则

| 档位 | 场景 | 用法 |
|---|---|---|
| `--elev-flat` | 所有卡片默认态 | MemoCard, InsightCard, SettingsGroup, Wiki page card |
| `--elev-raise` | Hover / focus 态 | 卡片 hover 时 transition 到 raise |
| `--elev-float` | 悬浮层 | Composer 浮动状态、Attach sheet、Recording sheet、Dialog |

**禁令**:
- 不再手写 rgba(0,0,0,...) 阴影
- 不再直接引用 `--shadow-composer / --shadow-attach / --shadow-recording`(它们保留是为迁移期兼容,新代码禁用)

---

## 7. Glass Drawer 规格

替换现有 `Drawer` 组件的视觉,交互不变:

```css
.drawer-panel {
  background: rgba(255, 255, 255, 0.78);
  backdrop-filter: blur(20px) saturate(140%);
  -webkit-backdrop-filter: blur(20px) saturate(140%);
  box-shadow: var(--shadow-drawer);
  border-left: 0.5px solid var(--color-border-subtle);
}

@supports not (backdrop-filter: blur(20px)) {
  .drawer-panel {
    background: rgba(255, 255, 255, 0.94);
  }
}

/* dark */
.dark .drawer-panel {
  background: rgba(35, 29, 23, 0.72);
  border-left-color: var(--color-border-default);
}
```

Safari 上 Playwright 视觉快照必须覆盖 fallback 分支。

---

## 8. Motion 收敛

**只有两条曲线**:

- `--motion-spring: cubic-bezier(0.2, 0.8, 0.2, 1)` — 用户启动的交互
- `--motion-ease-out: ease-out` — UI 关闭 / 淡出

代码里全站 grep,除生成块外任何其他 cubic-bezier / ease-in-out 都要移除。

**时长四档**:`fast 220 / medium 280 / slow 320 / island 360`。新代码不允许出现裸数字 duration。

---

## 9. Reduce-motion 修复

`globals.css:1707` 的 workaround(nested `@keyframes` in `@media` 被 Lightning CSS 静默丢弃)修复方案:

```css
/* 之前 */
@media (prefers-reduced-motion: reduce) {
  @keyframes homestream-scroll { /* ... */ }  /* Lightning CSS drops */
}

/* 之后 */
@keyframes homestream-scroll { /* ... */ }    /* 提到 media 外 */

@media (prefers-reduced-motion: reduce) {
  .homestream-scroll {
    animation-duration: 0.01ms !important;    /* 只覆盖属性,不重定义 keyframes */
  }
}
```

---

## 10. 验收清单

**代码级**:
- [ ] `tokens.json` version 9.0.0,含 dark + elevation 分支
- [ ] `pnpm tokens:build` 输出 `globals.css` 的 @tokens 块 + `DSTokens.swift` 无 diff(生成后 git diff 空)
- [ ] `globals.css:153-219` 硬编码 dark 移除
- [ ] `globals.css:1707` reduce-motion 修复,HomeStream 动画正常
- [ ] 全站 grep 无裸 rgba(0,0,0 阴影(生成块除外)
- [ ] 全站 grep 无 ease-in-out / 裸 cubic-bezier(生成块除外)
- [ ] `<TodayDateHero>` 在 `/today` 顶部,首次进入播放 360ms spring 淡入

**视觉级**(Playwright 快照):
- [ ] `/today` 桌面 + 移动 viewport
- [ ] `/home` 桌面
- [ ] `/wiki` list + slug detail
- [ ] MemoCard 左滑露出 glass drawer(移动 viewport)
- [ ] dark mode 三个页面各截一张

**手感级**(dev server 自测):
- [ ] TodayDateHero 淡入不卡、不闪
- [ ] MemoCard hover 从 flat 到 raise 平滑
- [ ] Drawer 打开背景可透过看到内容(glass 生效)
- [ ] `prefers-reduced-motion` 开启后所有动画瞬间到位

---

## 11. 落地顺序

```
Task #43 Spec (this doc)           ← 你在读
Task #44 tokens.json v9
Task #45 rerun generator
Task #46 fix reduce-motion CSS
Task #51 upgrade Drawer            ← 47 blocked-by 它
Task #47-50 页面重构(可并行)
Task #52 CI + visual snapshot
Task #53 dev server 自测 + PR
```

不在 PR #800 中提交,起单独 PR:`feat(web/design): v9 CLAUDE-aesthetic refinement`。

---

## 附录 A:关键文件锚点

- Tokens 源:`design-tokens/tokens.json`
- Tokens 生成器:`design-tokens/generators/to-css.ts`, `to-swift.ts`
- 生成目标:`web/src/app/globals.css:3-91`(web), `DayPage/App/DSTokens.swift`(iOS)
- Reduce-motion bug:`web/src/app/globals.css:1707`
- Dark mode 手写块:`web/src/app/globals.css:153-219`
- Drawer 组件:`web/src/components/ui/Drawer.tsx`(待查实际路径)
- MemoCard:`web/src/app/(app)/today/MemoCard.tsx`(待查实际路径)

## 附录 B:与 vNext 的关系

`web-design-vNext.md` 讲**编织成网如何发生**(P0 冷启动死锁、weave-graph、MCP);
`web-design-v9.md` 讲**发生了之后长什么样**。
两份文档正交:v9 不管数据链,vNext 不管视觉。落地时序建议:v9 可先行(视觉不依赖 P0),vNext P0 完成后再补 v9 的空状态引导。
