# DayPage V5 Codex Web — 深度 E2E 测试报告

测试日期：2026-05-12
被测分支：`docs/feature-inventory`（最近改动：`5abda55 V5 Codex web — full visual redesign + dev login bypass`、`f368e2e V5 Codex Web — 50/50 stories complete`）
测试基线：`http://localhost:3000`（Next.js 16.2.6 + Turbopack，已运行 dev 进程 PID 96325）
测试工具：Playwright (Chromium 1217, headless) + curl + dev 日志
截图目录：`/tmp/daypage-web-screenshots/`（共 24 张）
原始数据：`/tmp/daypage-web-qa-findings.json`、`/tmp/daypage-web-qa2-findings.json`

---

## 一、启动状态

| 项目 | 数值 |
|---|---|
| Dev 端口 | 3000（另一次 pnpm dev 实例占了 3001，已自动让位） |
| 首次 / 编译 | OK，没有阻塞性编译错误 |
| `/home` 首屏（已登录） | DOMContentLoaded ≈ 1.3 s，FCP ≈ 1.45 s，loadEvent ≈ 1.5 s |
| `/home` networkidle 等待 | ≈ 5.6 s — 暗示有长轮询/streaming 持续连接 |
| `/login` 首屏 | ≈ 13.9 s 才到 networkidle（首次冷编译） |
| JS 传输量（dev）| 755 KB（开发未压缩，仅供参考） |
| 字体传输量 | 103 KB（3 个 woff2 并发预加载） |

dev 服务器日志关键告警：
- `Inngest API Error: 401 Event key not found` — Inngest event key 未配置，导致写入流程功能性失败（见 P0-1）。
- 多条 React Hydration mismatch 错误（见 P1-1）。
- `○ Compiling /_not-found/page ...` —— 触达 Next 默认 404 而非品牌化 404（见 P1-3）。

---

## 二、问题清单（按优先级）

### P0 — 阻塞 / 功能性

#### P0-1 ｜ 写入功能完全不可用：Inngest 401 Event key not found
- **现象**：`/add` 输入内容点击 "Add" 后，按钮立刻变成 "Adding..." 且永远不返回；compile queue 和 recently compiled 始终为空。
- **证据**：
  - 截图 `60-add-before-submit.png` → `61-add-after-submit.png`（按钮卡在 "Adding…"）。
  - dev 日志：`{"timestamp":"18:25:40.010","level":"ERROR","message":"⨯ Error: Inngest API Error: 401 Event key not found"}`
- **影响**：MVP 主路径 "memo → compile → page" 全断；任何 memo 都不会出现在 wiki/inbox。整个 V5 web 故事的可演示性几乎归零。
- **复现**：`/login` → Dev login → `/add` → 输入任意文本 → 点击 Add。
- **建议**：`.env.local` 提供 `INNGEST_EVENT_KEY`（开发模式可用 `npx inngest-cli dev` 自动给的本地 key，已在 `package.json` 里有 `dev:inngest` 脚本但默认 README 没强调要并行起），或在 dev bypass 模式短路 Inngest 改本地同步 mock。

#### P0-2 ｜ "New domain" 入口指向不存在的路由
- **现象**：侧边栏 `DOMAINS / + New domain` 是 `<a href="/settings/domains">`。点击后进入 `/settings/domains` —— 没有对应的 `page.tsx`，被 (app) layout 接住，渲染为 "404 This page could not be found."（带 app shell）。
- **证据**：截图 `43-after-new-domain-click.png`；`findings.qa2.interactions.newDomainElHref = "/settings/domains"`、`urlAfterNewDomain = "/settings/domains"`；`find web/src/app -path '*settings*'` 无结果。
- **影响**：用户无法创建 domain；产品故事 "domain 卡片 → 实体页" 没有入口。
- **建议**：要么补 `/settings/domains` 页面，要么把侧边栏改成 `<button>` 触发 modal/inline 创建。

#### P0-3 ｜ `/domain/[slug]` 动态路由空态都是 404
- **现象**：访问 `/domain/test`、`/domain/new` 均返回 "404 This page could not be found."（带 app shell）。
- **证据**：截图 `09-desktop-domain-stub.png`、`42-domain-new.png`；dev 日志：`○ Compiling /domain/[slug] ...` 后立即 `Compiling /_not-found/page`。
- **可能原因**：`(app)/domain/[slug]/page.tsx` 在 slug 不存在时主动 `notFound()`。但 dev bypass 全新账号下无 seed，整个 domain 路径无法预览。
- **建议**：dev bypass 账号 seed 一份样例 domain，或在空态显示 "domain 不存在 + 跳到创建页" 而不是裸 404。

#### P0-4 ｜ 移动端布局完全断裂（375 px）
- **现象**：在 iPhone 标准宽 375 px 下，左侧 `<aside>` 仍保留 248 px（约 66% 视口），主内容被挤到右边并产生水平滚动（`scrollWidth = 1348`）。无 hamburger / drawer / 折叠按钮。
- **证据**：截图 `21..25-mobile-*.png`、`50-mobile-home-loggedin.png`；`findings.qa2.mobileNav.horizontalScroll = true`、`scrollWidth = 1348`、`asides[0].w = 248`、`position = "sticky"`。
- **影响**：移动端完全不可用 —— 所有页面需水平滚动才能看到内容；Inbox/Wiki 还套了第二层 panel，文字被裁到屏幕外。
- **建议**：(app) layout 在 < md 断点应 (a) 隐藏 `<aside>`，(b) 加 hamburger 触发 drawer overlay，(c) 让主内容 100vw。

### P1 — 严重

#### P1-1 ｜ `/login` 持续 React Hydration Mismatch
- **现象**：每次访问 `/login` 控制台和 dev 日志都打印 "A tree hydrated but some attributes of the server rendered HTML didn't match the client properties."
- **根因**：dev 日志 diff 行显示 `<input type="email">` 服务端多了 `style={{caret-color:"transparent"}}` 而客户端没有。看似是浏览器扩展 inject（截图左下角红色 "1 Issue" 徽章），但**也可能是组件本身**。需源码确认。
- **建议**：检查 `app/login/page.tsx` 是否有 effect 改 input style；若无，加 `suppressHydrationWarning`。即便生产构建不报错，SEO 抓取仍会感知到差异。

#### P1-2 ｜ /home 长时间不到 networkidle（5.6 s）
- **现象**：DCL / FCP ≤ 1.5 s，但 networkidle 要 5.6 s。
- **可能原因**：streaming 端点（看到目录有 `/api/stream`）或 `/api/activities` 在等 Inngest。
- **影响**：4G/3G 下骨架切换感慢；E2E 等 idle 易超时。
- **建议**：streaming 用 EventSource 走 transient socket 不影响 idle，或空数据时尽快关闭连接。

#### P1-3 ｜ 全局 404 与 (app) 404 视觉不一致
- **现象**：
  - `/this-route-does-not-exist`（无 app shell）→ 完全空白 + Next 默认 404（截图 `10-desktop-404.png`）。
  - `/settings/domains`、`/domain/test`（落入 (app) layout）→ 带 app shell 但内容区是同款裸 404。
- **影响**：用户在两种 404 之间切换会迷路，无 "回 Home" 链接。
- **建议**：写 `app/not-found.tsx` 和 `(app)/not-found.tsx`，提供品牌化引导。

#### P1-4 ｜ `/_design-demo` 路由 404（但源码有 page.tsx）
- **现象**：`web/src/app/_design-demo/page.tsx` 存在，但 `GET /_design-demo` 返回 404（无 app shell）。
- **根因**：Next 16 App Router 把 `_` 开头的目录视为私有，整个目录被路由忽略。
- **建议**：要么改名 `design-demo`（公开），要么放到 `(internal)/design-demo` + admin guard。

### P2 — 重要

#### P2-1 ｜ `Cmd+N` 快捷键不工作
- **现象**：侧边栏每项右侧都标了快捷键（`⌘1`、`⌘N`、`⌘K`、`⌘W`），按下 `Cmd+N` 时被 macOS/浏览器拦截（"New Window"），URL 仍停在 `/home`。
- **证据**：`findings.qa2.interactions.urlAfterCmdN = http://localhost:3000/home`。
- **影响**：UI 在 advertising 一个不存在的功能。
- **建议**：换不冲突组合（`Alt+N` / `g a` 系列），或直接去掉徽章。⌘W（"关闭标签"）几乎肯定也被吞，应核验其余三个。

#### P2-2 ｜ 无主导航语义 `<nav>`
- 登录后 /home `nav = 0`、`main = 1`、`aside = 1`。侧边栏用了 `<aside>` 没嵌 `<nav>`。
- 屏幕阅读器找不到 navigation landmark；建议在 `<aside>` 内包 `<nav aria-label="Main navigation">`。

#### P2-3 ｜ 顶栏 "Ask" 按钮行为未知
- 顶部右上 `Ask`（淡 outline）与 `Add`（实色棕）并列。点击 Ask 未捕到模态/抽屉变化。
- 建议：核验 Ask 应该触发 chat overlay 或跳 /chat。

#### P2-4 ｜ Secondary action 文本对比度低
- /home "What the system noticed" 卡片下 "OPEN IN INBOX / KEEP THINKING" 是米色字 + 米色底（截图 `02-desktop-home.png`）；可能 WCAG AA 不达标（< 4.5:1）。
- 建议：Stark / aXe 实测，给 secondary 加 outline 或加深颜色。

#### P2-5 ｜ Dev 账号无 seed，多个空态被迫一起呈现
- `/inbox`、`/chat`、`/wiki`、`/add` 在 dev bypass 下全部空态；只有 `/home` 是 hard-coded 占位数据（147 signals、84 raw notes 等）—— 与真实数据脱钩。
- 建议：dev bypass 登录时 seed 一组示例 memos / pages / domains 让 dogfood 演示连贯。

### P3 — 优化

- **P3-1** /home 有 1 个 input 没有 label（可能是 wiki 搜索框 placeholder 但无 `aria-label`）。
- **P3-2** Heading 等级断层：只有 1 个 H1，其余大标题（"WHAT THE SYSTEM NOTICED"、"RECENT ACTIVITY"、"DOMAINS AT A GLANCE"）应为 H2/H3 而当前是普通 div。
- **P3-3** Chat 桌面三栏布局：中间 "Conversations" 列固定 280 px，右侧的 "Ask your wiki anything" 介绍被挤到约 280 px，文字断行难看（`04-desktop-chat.png`）。
- **P3-4** 预加载 3 个 woff2（103 KB），可裁剪 subset。
- **P3-5** 侧边栏 `Sign out` 文案紧贴 viewport 底边，无 padding。

---

## 三、按维度汇总

### 视觉 / 样式
- ✅ 桌面整体 "Codex 像素艺术 + 米色" 风格统一，hero 大字 + 红/棕色块出色。
- ❌ **Mobile**：sidebar 强制 248px，无 drawer，水平滚动 —— 最严重。
- ⚠️ 顶栏 breadcrumb 与右上日期 (`TUE · 12 MAY 2026 · 11:15`) 在桌面就拥挤；mobile 日期断成两行。
- ⚠️ Secondary action 对比度偏低。
- ⚠️ Inbox/Chat 二级面板在窄宽下崩坏。

### 交互
- ✅ Dev login 工作；跳 /home。
- ✅ /add 文本框可输入。
- ❌ /add 提交：UI 卡 "Adding..." 永不返回（Inngest 401）。
- ❌ Cmd+N 被浏览器拦截，无备选快捷键。
- ❌ "New domain" 进入死链。
- ⚠️ 未测：拖拽 (bookmarklet)、文件上传、Voice 录音、Wiki search、Chat send —— 因核心写入断链，进一步交互无法验证。

### 功能
- 路由：Login / Home / Inbox / Chat / Wiki / Add 均加载；Domain 详情 / Settings / 设计 demo 均 404。
- API：未鉴权 `/api/*` 返回 401（正确）；但写入路径触达 Inngest 401。
- 编译流水：**完全跑不通**。
- Auth：dev bypass 工作；Sign out 路径未深入验证。

### 性能（dev 模式，仅参考）
- DCL 1.3 s、FCP 1.45 s、JS 755 KB（dev 未压缩）。
- networkidle 5+ s（streaming 长连接拖累）。
- 字体并发 3 个 woff2 / 103 KB。

### 可访问性
- `<main>` 1、`<aside>` 1、`<nav>` 0（需补 nav 语义）。
- 1 个 input 无 label。
- Heading 层级断层（只有 H1）。
- Login 页持续 hydration mismatch。

### 移动适配
- **完全未做响应式断点**。Sidebar、二级面板、breadcrumb 时间戳全部按桌面塞进 375 px。

### 控制台清洁度
- /login: 1 类 hydration error 重复打印。
- /home: 3 个 404 资源（具体 URL 未抓到但和路由相关）。
- /add 提交：服务端 Inngest 401。
- 其他页面控制台干净。

---

## 四、改进建议（优先级排序）

1. **修 Inngest event key** —— `.env.local` 注释 + dogfood 提示同时跑 `pnpm dev:inngest`；或 dev bypass 模式短路 Inngest 改本地同步 mock，让 add → compile → page 链路至少能演示。
2. **实现 mobile responsive** —— `(app)/layout.tsx` 加 lg 断点；`<aside>` 改 `hidden lg:flex` + Sheet drawer 给小屏。
3. **补 /settings/domains 和 /domain/[slug] 空态** —— 否则 sidebar 两个 domain 入口都死。
4. **统一 404** —— `app/not-found.tsx` + `(app)/not-found.tsx` 带回家链接。
5. **修 /login hydration** —— 定位 caret-color 来源；加 `suppressHydrationWarning` 或改 CSS class。
6. **删除或重命名 `/_design-demo`** —— 单下划线在 App Router 是私有，访问就 404。
7. **快捷键徽章与实际对齐** —— ⌘N 在 macOS 浏览器几乎都吞，换 ⌥N 或 g 序列；⌘W 同样核验。
8. **a11y 补 `<nav>` 语义和 input label**。
9. **dev seed 数据** —— 让 dogfood 看到的不只是 home 一屏。
10. **secondary action 颜色对比** —— Stark 测一遍。

---

## 五、截图清单（24 张，均在 `/tmp/daypage-web-screenshots/`）

桌面 1440×900：
- `01-desktop-login.png` — login 页 + 红色 "1 Issue" 浏览器扩展徽章
- `02-desktop-home.png` — home 全屏（OK）
- `03-desktop-inbox.png` — inbox 空态
- `04-desktop-chat.png` — chat 空态，三栏布局
- `05-desktop-wiki.png` — wiki 空态（Concepts / Synthesis / Entities / Sources）
- `07-desktop-add.png` — add 页空态
- `08-desktop-add-typed.png` — add 输入后
- `09-desktop-domain-stub.png` — `/domain/test` 404
- `10-desktop-404.png` — 全局 404（无 app shell）
- `11-desktop-design-demo.png` — `/_design-demo` 404
- `30-desktop-home-tab-focus.png` — login 上 Tab 焦点（该 ctx 未登录）
- `40-home-tab3.png` — 已登录 /home Tab 焦点
- `41-after-cmd-n.png` — 按 ⌘N 后（URL 没变）
- `42-domain-new.png` — `/domain/new` 404
- `43-after-new-domain-click.png` — 点击 "New domain" 后落到 /settings/domains 404
- `60-add-before-submit.png` / `61-add-after-submit.png` — 提交前/后，按钮卡 Adding…

移动 375×812：
- `20-mobile-login.png` — login，OK
- `21-mobile-home.png` — home，横向滚动断裂
- `22-mobile-inbox.png` — inbox，二级面板挤爆
- `23-mobile-chat.png` — chat，三栏强行塞 375
- `24-mobile-wiki.png` — wiki，右栏被裁
- `25-mobile-add.png` — add，sidebar 占主屏
- `50-mobile-home-loggedin.png` — loggedin 状态下移动布局仍破

---

## 六、未覆盖（如要继续测）

- Wiki 详情页 (`/wiki/[slug]`)：因 wiki 为空未触发。
- Chat 对话流 (`/chat/[id]`)：未创建对话。
- 拖拽文件 / Voice 录音 / Bookmarklet 流程。
- 真实 Inngest dev 服务器连接后的 compile loop（推荐 `pnpm dev:inngest` 后回测）。
- Lighthouse 真实跑分（dev 不准；建议 `pnpm build && pnpm start` 后跑）。
- Dark mode（如果有）。
- 真实 Apple OAuth 登录路径。
