# DayPage 官网（Landing / Marketing Site）设计 spec

**位置**：`web/src/app/(marketing)/`（与现有 `(app)` 并列的 Next.js route group）
**目标档位**：L1 + L2（丝滑感 + 滚动叙事），对标 claude.com / Linear / Stripe 的克制奢华
**完成口径**：Awwwards 入围水平、Lighthouse Performance ≥ 90、FCP < 1.5s、LCP < 2.5s、CLS < 0.05

---

## 1. 设计哲学

### 1.1 一句话定位
> "Your day, captured raw. Compiled by AI." — Today is for dumping. Tomorrow is for reading.

### 1.2 视觉气质（与 iOS 端一致）
- **warm-cream 底色**：`--bg-warm #FAF8F6` 是整站基底，不允许引入纯白/纯黑大块
- **奢华来自留白**：每个 section 至少 160px 上下 padding，桌面端单列内容最大宽 720–960px
- **衬线为锚点**：所有大标题用 Fraunces（已在 tokens），数字与代码用 JetBrains Mono
- **accent 克制**：`--accent #5D3000` 只用于 CTA、关键数字、active 状态；正文不用
- **不要 emoji，不要 gradient text 滥用**：渐变只出现在 Hero shader 背景一处

### 1.3 与 claude.com 的差异
| | claude.com | DayPage Landing |
|---|---|---|
| 主色 | 米白 + 橙红 | warm-cream + 深棕 accent（已有 token） |
| 字体调性 | Tiempos 衬线 | Fraunces 衬线（更圆润，更"日式手账"） |
| 滚动叙事 | "能力 → 案例 → 信任" | "捕捉 → 编译 → 网络"三幕剧 |
| 主视觉 | 抽象渐变 | iPhone 真机 mockup 演示真实产品 |
| 情绪 | 企业级、聪明 | 私人、温暖、有手写感 |

---

## 2. 信息架构（IA）

```
/                        (marketing)/page.tsx        — Landing 单页
/manifesto               (marketing)/manifesto/page.tsx — "为什么做 DayPage"
/changelog               (marketing)/changelog/page.tsx — 更新日志
/download                (marketing)/download/page.tsx  — App Store 跳转 + macOS waitlist
/login, /home, /today    保持在 (app) 内不变
```

### 2.1 Landing 单页骨架（自上而下 8 个 section）

```
[Nav]            sticky, 透明 → scroll 后 frosted glass
[1 Hero]         "Your day, captured raw." + iPhone mockup
[2 Problem]      "You forget. The day forgets you back." 黑屏反差
[3 Capture]      演示 Today 页输入（pinned scroll，三幕第一幕）
[4 Compile]      演示 AI 编译 raw → daily page（三幕第二幕）
[5 Wiki]         演示知识网络生成（三幕第三幕）
[6 Features]     bento grid，列举 8 个能力卡片
[7 Quote]        用户引言 + 创作者引言
[8 CTA]          "Start your first day." + Footer
```

### 2.2 滚动节奏（关键）
- **Section 1 → 3**：进入即播放（IntersectionObserver + Framer Motion）
- **Section 3-5**：pinned scroll，三幕剧靠 `useScroll` 把滚动进度 0→1 映射成 iPhone 内屏幕状态
- **Section 6-8**：常规 stagger 入场
- **整站使用 Lenis 平滑滚动**，scrollerProxy 给 GSAP/Framer

---

## 3. 技术栈选型

### 3.1 必装依赖（增量装在 `web/`）
```jsonc
{
  "dependencies": {
    "framer-motion": "^11.18.0",       // 声明式动画 + layout animation + useScroll
    "lenis": "^1.1.20",                // 平滑滚动（旧名 @studio-freight/lenis）
    "ogl": "^1.0.11"                   // 极轻量 WebGL，用于 Hero shader 背景（替代 three.js 节省 80KB）
  }
}
```

**不引入的库（理由）**：
- ❌ GSAP — 商业授权敏感 + Framer Motion 11 的 `useScroll`/`useTransform` 已能覆盖 95% pinned scroll
- ❌ Locomotive Scroll — 与 Next.js App Router 兼容差，Lenis 更轻
- ❌ Three.js — 仅 Hero shader 用 OGL 单文件 fragment shader 即可，省 200KB
- ❌ Lottie — 本次没有 AE 资源，三幕剧用真实 React 组件演示更可信

### 3.2 字体加载
- 已有 token：`Fraunces` `Space Grotesk` `Inter` `JetBrains Mono` `Caveat`
- 用 `next/font/google` 加载（self-hosted，不打 CDN），`display: swap`，仅子集化中英文常用字符
- Hero 大字必须用 `Fraunces` 的 `opsz` variable axis（72pt 大字与 14pt 正文走不同形态）

### 3.3 图像策略
- iPhone mockup：用 SVG 外壳 + Next/Image 内屏截图（WebP，<60KB/张）
- 三幕剧每帧用 `<video muted autoplay loop playsinline>` H.264 MP4（<800KB/段），fallback PNG sequence
- 全部走 `next/image` 的 placeholder=blur

---

## 4. 目录与文件清单

```
web/src/app/(marketing)/
├── layout.tsx                     # 独立 layout：不引 (app) 的侧边栏；引 Lenis Provider
├── page.tsx                       # 单页 Landing，组合下面所有 section
├── manifesto/page.tsx             # 静态长文，复用 prose 样式
├── _components/
│   ├── Nav.tsx                    # sticky nav，scroll-aware backdrop blur
│   ├── Footer.tsx
│   ├── LenisProvider.tsx          # 'use client' 全局 Lenis context
│   ├── ShaderBackground.tsx       # 'use client' OGL fragment shader（Hero 用）
│   ├── IPhoneFrame.tsx            # SVG 外壳 + children 内容窗
│   ├── ScrollScene.tsx            # 通用 pinned scroll 容器，封装 useScroll
│   ├── SplitText.tsx              # 字符级 stagger，Framer Motion 实现
│   ├── sections/
│   │   ├── HeroSection.tsx
│   │   ├── ProblemSection.tsx
│   │   ├── CaptureSection.tsx     # 三幕剧 Act 1
│   │   ├── CompileSection.tsx     # 三幕剧 Act 2
│   │   ├── WikiSection.tsx        # 三幕剧 Act 3
│   │   ├── BentoSection.tsx
│   │   ├── QuoteSection.tsx
│   │   └── CTASection.tsx
│   └── shaders/
│       └── warmFlow.frag.glsl     # Hero 背景 shader 源码（也可写成 TS 模板字符串）
└── _styles/
    └── marketing.css              # 仅本路由用的局部样式，import 到 layout.tsx
```

**为什么用 route group `(marketing)`**：
- 不影响 URL（`/` 直接对应 Landing）
- layout.tsx 独立，不继承 (app) 的鉴权/侧边栏
- Tailwind v4 + 现有 tokens 自动共享

---

## 5. 各 Section 详细 spec

### 5.1 Hero — "Your day, captured raw."

**布局**：
```
┌───────────────────────────────────────────────────────────┐
│  [Nav, transparent]                                       │
│                                                           │
│        Your day,                          [iPhone]        │
│        captured raw.                      mockup          │
│        Compiled by AI.                    Today screen    │
│                                            slow-pan       │
│        [Start your first day  →]                          │
│                                                           │
│              ↓ scroll cue (breathing chevron)             │
└───────────────────────────────────────────────────────────┘
       background: warmFlow shader (slow drift)
```

**动效时序**（page mount T0）：
| t (ms) | 事件 |
|---|---|
| 0 | Shader 开始渲染（已 mount） |
| 100 | "Your day," 字符 stagger 入场（每字 30ms delay，spring stiffness 120） |
| 400 | "captured raw." 入场 |
| 700 | "Compiled by AI." 入场（Fraunces italic accent） |
| 1100 | CTA 按钮 scale 0.95→1 + opacity 0→1 |
| 1300 | iPhone mockup 从右侧 slide-in（x: 40 → 0），spring damping 18 |
| 1500 | iPhone 内屏开始 slow-pan（Today 页 mock 内容 5s loop） |
| 2000 | scroll cue 开始呼吸（y: 0→8→0 infinite） |

**Shader 背景规格**（`warmFlow.frag.glsl`）：
- 基础色 `#FAF8F6`
- 两层 simplex noise 叠加，频率分别 0.3 / 0.7，速度 0.02 / 0.05
- accent 色 `#5D3000` 以 0.05 alpha 在 noise 高点呈现暖斑
- 60fps，1080p 下 GPU 占用 < 5%
- `prefers-reduced-motion: reduce` 时退化为静态噪声纹理 PNG

**性能预算**：
- Hero 全部资源（含 shader + 字体 + iPhone 图）< 250KB（gz）
- TTI < 2.5s on 4G simulated

---

### 5.2 Problem — "You forget."

**反差设计**：背景切到 `--fg-primary #2B2822` 深咖色，正文用 `--bg-warm`。
**单句大字**：`You forget. The day forgets you back.`（Fraunces italic, 72px）
**滚动触发**：进入视口时单词逐个透出（不是逐字，是逐 word stagger）。
**高度**：100vh，留白吸引专注。

---

### 5.3 三幕剧 Section 3-5（Pinned Scroll，核心戏份）

**总体布局**：
```
┌──────────────────────────────────────────────────────┐
│ [文字栏，左侧 sticky]      [iPhone, 右侧 pinned]     │
│                                                       │
│ Act 1 — Capture            内屏播放：                 │
│ 用语音、文字、照片，         - 用户说话录音            │
│ 一秒钟把碎片扔进 Today。      - 文字逐行打字           │
│                              - 照片拼贴入场           │
│ ─────────────────                                    │
│ Act 2 — Compile            内屏播放：                 │
│ 凌晨 2 点，AI 把今天          - raw 文字 morph 成     │
│ 重新编织成可读的日记。          markdown 卡片         │
│                                                       │
│ ─────────────────                                    │
│ Act 3 — Wiki               内屏播放：                 │
│ 同一个人名、地点、念头         - daily 节点 → entity →│
│ 跨日相连，长出你的二脑。         knowledge graph      │
│                              - 节点连线动效           │
└──────────────────────────────────────────────────────┘
        height: 300vh  (3 幕 × 100vh)
        iPhone position: sticky, top: 20vh
```

**实现要点**：
- 用 `<ScrollScene>` 包裹整个 300vh 容器
- `useScroll({ target, offset: ["start start", "end end"] })` 拿到 `scrollYProgress` (0–1)
- 用 `useTransform` 把 progress 划成三段：[0, 0.33] Act 1、[0.33, 0.66] Act 2、[0.66, 1] Act 3
- iPhone 内屏内容用 React state，根据 progress 切换组件树（不是切 video）
- 文字栏每幕用 `motion.div` 配 `whileInView`，自然 stagger

**Act 1 内屏动效**：
- 0.00–0.10：模拟点击底部录音键，红色波纹脉冲
- 0.10–0.20：transcript 文字一行行 fade-in（typewriter 效果用 `motion.span` 配 useTransform 控制字符数）
- 0.20–0.33：照片缩略图从底向上 spring-in，3 张

**Act 2 内屏动效**：
- 0.33–0.45：raw 文字（草稿感）逐渐"溶解"（opacity + blur）
- 0.45–0.55：daily markdown 卡片从中间渐入，标题 → 段落 → 列表分层 stagger
- 0.55–0.66：右下角时间戳 `02:14 AM compiled` 浮现

**Act 3 内屏动效**：
- 0.66–0.78：当前 daily 节点中心化，缩小为圆点
- 0.78–0.90：周边 entity（人名、地点）节点 spring-out
- 0.90–1.00：连线一根根 draw（SVG `pathLength` 0→1），整图轻微旋转

**降级**（`prefers-reduced-motion`）：
- iPhone 切换为静态 3 张截图垂直堆叠
- 文字栏正常显示

---

### 5.4 Bento Features

**布局**：12 列网格，4 行，8 个不等大卡片
```
[ Local-first (大) ][ Voice → text ][ Apple ]
[ Compile         ][ Entity link  ][ Offline ]
[       Graph (跨行)               ][ Privacy ]
```

**卡片样式**：
- 圆角 24px、`--surface-white` 底、`--border-subtle` 1px 描边、`shadow-card-rest`
- hover：`scale 1.02 + shadow-card-hover`，spring 200ms
- 每卡含一个小动效（icon spin、数字滚动、迷你 graph 节点弹跳）

---

### 5.5 Quote Section

**单引言中心式**：
```
              "I used to lose 80% of my day to the void.
                  Now my second brain remembers
                          even my coffee."

                            — Nomad in Lisbon
```
- Fraunces 60px italic
- 引言两侧装饰用极淡的 `"` SVG（150px，opacity 0.06）

---

### 5.6 CTA + Footer

**CTA**：
```
           Start your first day.

      [  Download on App Store  ]  [  macOS waitlist  →  ]

                  Free. No account required.
```
- 主按钮：accent 实心，hover 时背景从 accent → accent-hover spring 过渡
- 次按钮：ghost，hover 显示下划线 draw-in 动效

**Footer**：4 列（Product / Resources / Company / Legal）+ 底部 logo + © year + GitHub icon

---

## 6. 响应式策略

| 断点 | 行为 |
|---|---|
| ≥1280px | 完整三幕剧 + Bento 12 列 |
| 1024–1279 | Bento 退化为 8 列，iPhone 缩小 15% |
| 768–1023 | 三幕剧改为单列：文字在上、iPhone 在下（不 pin） |
| <768 | Shader 退为静态 PNG；所有 stagger 改为 200ms 简单 fade-in；CTA 全宽 |

---

## 7. 性能 / 可访问性 / SEO 验收清单

### 7.1 性能
- [ ] Lighthouse Mobile Performance ≥ 90
- [ ] LCP < 2.5s（Hero iPhone 截图是 LCP 元素）
- [ ] CLS < 0.05（所有 image/video 必须有显式宽高或 aspect-ratio）
- [ ] 首屏 JS < 180KB gz（不含 Lenis/Framer，含 marketing 自身代码）
- [ ] Shader 在 iPhone 12 上 60fps，Chrome DevTools CPU 4x throttle 仍 ≥ 30fps
- [ ] 全部图片 `loading="lazy"` 除 LCP 元素外

### 7.2 可访问性
- [ ] 所有交互元素键盘可达，焦点环 visible（`--accent` 2px outline）
- [ ] 三幕剧 pinned scroll 提供 "Skip animation" 链接（屏幕阅读器优先）
- [ ] 颜色对比 AA：accent on warm-cream 已是 11.2:1，正文 11.6:1
- [ ] `prefers-reduced-motion: reduce` 全站尊重
- [ ] iPhone mockup 内屏内容也需 alt 文本，描述当前演示状态

### 7.3 SEO
- [ ] `<title>` `<meta description>` 完整
- [ ] Open Graph + Twitter Card 图（1200×630）
- [ ] `application/ld+json` SoftwareApplication schema
- [ ] sitemap.xml 自动生成（Next 16 内置）
- [ ] robots.txt 允许除 `/api/*`

---

## 8. 实现里程碑（建议 PR 分包）

### PR #1 — Marketing scaffold + Lenis + Nav/Footer（~1 天）
- 建 `(marketing)/layout.tsx` `page.tsx`
- 装 framer-motion + lenis
- 写 `LenisProvider` `Nav` `Footer`
- Landing page 用占位 section 验证滚动丝滑度

### PR #2 — Hero + Shader 背景（~1.5 天）
- 写 `ShaderBackground` (OGL 接入)
- 写 `SplitText` `IPhoneFrame`
- 完成 Hero 入场时序

### PR #3 — Problem + Three-Act ScrollScene 框架（~2 天）
- 写 `ScrollScene` 通用容器
- 完成 Act 1 (Capture) 文字栏 + iPhone 内屏组件
- 验证 pinned scroll 在 macOS / iOS Safari / Chrome 一致

### PR #4 — Act 2 (Compile) + Act 3 (Wiki)（~2 天）
- 文字 morph 与 graph 节点动效
- SVG pathLength draw 动画

### PR #5 — Bento + Quote + CTA + Footer + 响应式（~1.5 天）
- 8 个 bento 卡片含微动效
- 全断点适配

### PR #6 — 性能调优 + a11y + SEO（~1 天）
- Lighthouse 报告达标
- 接入 reduced-motion 降级
- meta / OG / sitemap

**总计**：~9 个工作日，单人推进

---

## 9. 与现有代码的复用边界

| 复用 | 不复用 |
|---|---|
| `globals.css` 全部 design tokens | `(app)` 的 sidebar / auth guard |
| `lib/db` 完全无关 | `(app)` 的 React Query provider（marketing 是纯静态） |
| 截图素材：跑一次 `(app)/today` 截图作为 iPhone 内屏 mock | 不引入 `@tanstack/react-query` 到 marketing bundle |

---

## 10. 风险与对策

| 风险 | 对策 |
|---|---|
| Lenis 与 iOS Safari 100vh 抖动 | 用 `100dvh` + Lenis 配置 `smoothTouch: false`（移动端关闭，原生滚动） |
| Framer Motion useScroll 在 Next 16 RSC 报错 | 所有 scroll 组件 `'use client'`；layout 不强制 client |
| Shader 在低端 Android 卡 | 检测 `navigator.hardwareConcurrency < 4` 降级为静态 PNG |
| Fraunces 加载慢导致 CLS | `next/font` 预加载 + `font-display: swap` + `size-adjust` 调整 fallback |
| pinned scroll 让用户晕 | 提供 "Skip animation" + reduced-motion 完整降级 |

---

## 11. 验收 demo URL

- 开发：`http://localhost:13000/`
- 预发：`https://daypage-preview.vercel.app/`
- 正式：`https://daypage.app/`

---

**文档状态**：v1.1 — PR #1 已落地（marketing scaffold + Lenis + Nav/Footer + placeholder sections）；PR #2 进行中（Shader + SplitText + iPhone mockup）。

---

## 12. 动效架构深度推演（对齐用户提出的 5 层技术栈）

用户原话把网站动效拆成 5 层：**渲染层 / 动画引擎 / 滚动驱动 / 物理与交互 / 高级合成**。下面把每一层映射到 DayPage landing 的具体决策，并标注与 claude.com 的取舍差异。

### 12.1 层 1 — 渲染层（决定 60fps 的物理基础）

| 用户列出的技术 | 我们用在哪里 | 不用的理由 |
|---|---|---|
| **CSS transform + opacity** | 全站 95% 动画（Hero 入场、iPhone slide、卡片 hover、scroll cue 呼吸） | — 走 GPU compositor thread，零 layout/paint 成本，是 60fps 的物理保证 |
| **WebGL fragment shader** | Hero 背景 `warmFlow.frag`（暖色 simplex noise 流动） | claude.com 用 CSS conic-gradient 静态橙红云团 + 鼠标 parallax；我们用 shader 是因为 warm-cream + 深棕的双色噪声 CSS 难以做出有机感 |
| **Canvas 2D** | 不用 | 三幕剧靠真实 DOM 组件 + Framer Motion；Canvas 失去 a11y 与 SEO |
| **SVG + CSS** | Act 3 知识图谱节点连线（pathLength draw 动画）、Hero 装饰引号、scroll cue chevron | 矢量描边动画唯一合理选项；postprocessing 复杂图形也比 Canvas 强 |
| **WebGPU** | 不用 | 兼容性还差（Safari 17 后才稳定），对 landing 收益不抵风险 |

**关键纪律**：任何动画属性只能是 `transform` `opacity` `filter` `backdrop-filter` 之一。出现 `width/height/top/left/margin` 的动画 = bug，CR 阶段一律打回。

### 12.2 层 2 — 动画引擎（控制时间与缓动）

| 用户列出的引擎 | 决策 | 理由 |
|---|---|---|
| **GSAP** | ❌ 不用 | 商业授权（SplitText/ScrollTrigger 在 Club GreenSock 后变 MIT，但企业策略仍需评估）；React 生态下 Framer Motion 11 的 `useScroll/useTransform` + `motion.span` 已够用 |
| **Framer Motion 11** | ✅ 主引擎 | 声明式 + layout animation（FLIP）+ spring 物理 + useScroll。本次落地版本 `11.18.2` |
| **Motion One / Anime.js** | ❌ | 重复造轮子，Framer Motion 已覆盖 |
| **CSS @keyframes** | ✅ 补位 | scroll cue 呼吸、按钮 active scale —— 这种不需要 JS 控制的简单循环用 CSS 更便宜 |
| **WAAPI** | ⚠️ 候选 | 如果 Framer Motion bundle 后期过重（>30KB），可逐步替换简单组件 |

**Easing 哲学**：所有"物体出现/移动"类动画用 spring（damping 18-22，stiffness 100-160），不用贝塞尔；只有"颜色/透明度过渡"才用 `cubic-bezier(0.16, 1, 0.3, 1)` (expo-out)。claude.com 用的是经典 expo-out 大量过渡，更"丝滑但冷"；我们用 spring 是为了更"温暖、像纸"的手感。

### 12.3 层 3 — 滚动驱动（最核心的"高级感"来源）

| 技术 | 用在哪里 |
|---|---|
| **IntersectionObserver** | 通过 Framer Motion `whileInView` 隐式调用 —— Bento 卡片、Quote、CTA 入场 |
| **Framer `useScroll`** | 三幕剧 pinned scroll（Section 3-5，共 300vh）—— 把 scrollYProgress 0→1 映射到 iPhone 内屏三幕状态切换 |
| **CSS Scroll-driven Animations** (`animation-timeline: scroll()`) | ❌ 不用 | Safari 26+ 才支持，Chrome 115+。覆盖率不够，等 2027 再考虑 |
| **Lenis** | ✅ 全站平滑滚动（已落地 PR #1） | 给 Framer useScroll 提供"丝滑的"输入信号；移动端 `syncTouch: false` 保留原生触摸滚动避免眩晕 |
| **Locomotive Scroll** | ❌ | 与 Next.js App Router 兼容差，Lenis 是当下最优解 |

**与 claude.com 的关键差异**：
- claude.com **没有**全局平滑滚动（用浏览器原生），靠 section snap + transform parallax 营造节奏感
- 我们启用 Lenis 是因为 DayPage 的"日式美术馆"调性需要更柔的滚动感，更像翻一本厚纸册子
- 但 Lenis 在 macOS 触控板上"惯性会冲过头"——已用 `duration: 1.2` + expo-out 缓动收敛

### 12.4 层 4 — 物理与交互

| 技术 | 决策 |
|---|---|
| **Framer spring** | ✅ 主交互引擎，所有"按钮 hover"、"卡片悬停"、"iPhone slide-in" 都走 spring |
| **React Spring** | ❌ Framer Motion 内置 spring 已够，避免重复依赖 |
| **Three.js / R3F** | ❌ 本次不引（spec 第 3.1 节决策） |
| **Rapier / Cannon** | ❌ landing 无物理仿真需求 |

### 12.5 层 5 — 高级合成

| 技术 | 决策 |
|---|---|
| **WebGL postprocessing**（bloom/glitch/distortion） | ❌ 本次不上 | 与 DayPage "克制温暖" 调性相反；只有当未来要做"知识图谱 3D 场景"时才考虑 R3F + bloom |
| **Shader 渐变背景** | ✅ Hero 一处 | warmFlow simplex noise —— 这是整站唯一的"高级合成"投入 |
| **Lottie** | ❌ | 没 AE 资源；三幕剧用 React 组件可信度更高 |

### 12.6 参考 claude.com 的具体动效模式（实战拆解）

我把 claude.com landing 拆成 8 个可命名的动效模式，每个都给出 DayPage 的对应实现：

| # | claude.com 模式 | 技术本质 | DayPage 对应 |
|---|---|---|---|
| 1 | **Hero 衬线大字 + italic accent** ("Build the future with Claude") | 静态 typography + `font-feature-settings: 'ss01'` | ✅ 已实现 (PR #1)：Fraunces + italic "Compiled by AI." 用 `--accent` |
| 2 | **大字逐词淡入** (页面 mount T0-600ms) | Framer Motion stagger，每词 50ms delay | 🔜 PR #2 `<SplitText>` |
| 3 | **Hero 背景流体橙红云团** | CSS conic-gradient + 鼠标 parallax | ✅ 升级版：warmFlow fragment shader（更有机） |
| 4 | **Section 间软淡入**（滚到才出现） | IntersectionObserver + opacity/translateY spring | 🔜 PR #3 `<motion.div whileInView>` 统一封装 |
| 5 | **Pinned product showcase**（功能区滚动时模型旋转 + 文字切换） | GSAP ScrollTrigger pin + scrub | 🔜 PR #3-4 用 Framer `useScroll` + `useTransform` 替代 |
| 6 | **Code/产品 mockup 浮起**（带柔和投影） | CSS `transform: translateY(-N) scale(1.02) + box-shadow scale` | 🔜 PR #2 IPhoneFrame hover/scroll |
| 7 | **CTA 按钮 hover 微缩 + 颜色过渡** | `scale(0.98)` on active + bg color transition | ✅ 已实现 (PR #1) |
| 8 | **Frosted nav** (scroll 后变毛玻璃) | `backdrop-filter: blur` + bg/border 切换 | ✅ 已实现 (PR #1) Nav 组件 |

### 12.7 性能预算（每一层的硬约束）

- 渲染层：动画属性只能是 transform/opacity/filter
- 动画引擎：Framer Motion bundle ≤ 35KB gz（用 `LazyMotion + domAnimation`，不要 `domMax`）
- 滚动驱动：useScroll handler 内禁止任何 setState（必须走 useTransform/useMotionValue）
- 物理：spring 配置统一从 `motionTokens.ts` 取，禁止散落各组件
- 高级合成：Hero shader GPU 占用 < 5% on M1，移动端 < 10%；低端设备（hardwareConcurrency<4）自动降级 PNG

### 12.8 渐进增强降级矩阵

| 场景 | 默认 | 降级 |
|---|---|---|
| `prefers-reduced-motion: reduce` | 全动画 | Lenis 关闭 / SplitText 一次性淡入 / shader → 静态 PNG / iPhone slide-in 改即时显示 |
| 低端 GPU（hardwareConcurrency < 4） | shader 60fps | shader → 静态 noise PNG |
| Safari < 17 | backdrop-filter blur | 退化为半透明 solid bg |
| 旧浏览器无 IntersectionObserver | whileInView 触发 | 永远显示（依赖 Framer Motion 内置 polyfill） |
| JS 关闭 | 全交互 | 服务端 HTML 直出 = 仍可读、可点 CTA、可访问所有 section（SEO 安全） |

---

**v1.1 落地状态**：
- ✅ PR #1：marketing scaffold + Lenis + Nav/Footer + 7 个 placeholder section
- 🔜 PR #2：Section 12.1 的 shader + Section 12.6 模式 #2 的 SplitText + 模式 #6 的 IPhoneFrame
