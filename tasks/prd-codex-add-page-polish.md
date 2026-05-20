# PRD: Codex `/add` 页面体验修复与打磨

> 基于 2026-05-20 `/add` 页面端到端测试报告整理。覆盖范围：**全量修复 + 未实现交互补齐 + 待定按钮的设计澄清**。

## 1. Introduction / Overview

Codex `web/` 的 `/add` 页面是用户的「内容投递入口」（输入区 + Compile Queue + Recently Compiled）。核心提交链路（输入 → `POST /api/memos` → SSE 编译）已稳定可用，但**辅助交互**层面存在 9 处缺陷，主要集中在四个方向：

1. **数据耐久性**：草稿刷新后丢失，直接造成用户内容损失（P0）。
2. **SSR/CSR 首帧不一致**：面包屑、QUEUED 状态在首帧错位，刷新后才正确。
3. **未实现的已规划交互**：⌘+Enter 提交、卡片中部跳详情、Photo/File 选择器。
4. **语义不明的入口按钮**：Bookmarklet 误附图、URL 按钮自动填当前页。

本 PRD 给出统一的修复方案、设计澄清，以及对应文件路径的实现指引。

## 2. Goals

- **零内容损失**：用户写过的草稿，在任何刷新 / 切页 / 关浏览器场景下都能恢复。
- **首帧即正确**：首屏渲染的面包屑、队列状态文本与最终状态一致，刷新前后视觉无跳变。
- **键盘可达性达标**：`⌘/Ctrl + Enter` 提交、卡片可点击跳详情成为默认交互。
- **入口按钮语义清晰**：每个模式按钮（URL / Photo / File / Voice / Bookmarklet）都有明确、可预期的行为，不再「点了像 bug」。
- **0 回归**：现有通过的 20 个用例继续通过，无新增 console error / warning。

## 3. User Stories

### US-001: 草稿本地持久化（BUG-01）
**Description:** 作为输入中的用户，我希望 Save draft 之后即便刷新页面，正在写的内容仍然回填到 textarea，避免内容丢失。

**Acceptance Criteria:**
- [ ] 点击 Save draft 后，草稿写入 `localStorage`，键名 `codex.add.draft.v1`，结构 `{ text: string, mode: 'text' | 'url' | 'photo' | 'file', attachmentRef?: string | null, savedAt: ISOString }`
- [ ] 刷新页面后，若 `localStorage` 内有非空草稿，textarea 自动回填，并显示「Restored draft · {savedAt 相对时间}」轻量提示
- [ ] 提交成功（`POST /api/memos` → 201）后，自动清除 `localStorage` 草稿
- [ ] 用户主动清空 textarea 并失焦超过 1s，自动清除草稿
- [ ] 草稿仅存在客户端，**不写入 cookie / Server Component**，避免 SSR/CSR 不一致
- [ ] 提供「Discard draft」按钮（仅在有草稿时显示）
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill（写文本 → Save draft → F5 → 草稿出现 → 提交 → 草稿消失）

### US-002: 草稿服务端同步（可选，feature-flagged）
**Description:** 作为多设备用户，我希望（在登录态下）草稿能跨设备同步。本 PRD 仅落地接口约定与开关，**默认关闭**。

**Acceptance Criteria:**
- [ ] 新增 `NEXT_PUBLIC_CODEX_DRAFT_SYNC` env，默认 `false`
- [ ] 开启时，草稿在本地变化后 debounce 1.5s 发起 `PUT /api/drafts/add`（payload 同 US-001 结构）
- [ ] 页面加载时若本地无草稿，则从 `GET /api/drafts/add` 拉取
- [ ] 本地草稿与远端草稿冲突时，以 `savedAt` 较新者为准，并在 UI 提示「Synced from another device」
- [ ] 默认关闭状态下，US-002 的代码路径完全 dead-code-eliminated，不影响 bundle
- [ ] API route 与 DB migration 仅作骨架，body 内 TODO 注释标明 Post-MVP
- [ ] Typecheck/lint passes

### US-003: ⌘/Ctrl + Enter 快捷键提交（BUG-02）
**Description:** 作为重度键盘用户，我希望在 textarea 内按 `⌘+Enter`（Mac）/ `Ctrl+Enter`（Win/Linux）直接触发 Add 提交。

**Acceptance Criteria:**
- [ ] textarea `onKeyDown` 监听：`(e.metaKey || e.ctrlKey) && e.key === 'Enter'` 时调用与 Add 按钮相同的 submit handler
- [ ] 当 Add 按钮处于 disabled（空内容 / 提交中）时，快捷键也不触发
- [ ] textarea 下方的 hint 文案补充：`⌘ + Enter to submit`，跨平台显示对应符号
- [ ] 不阻塞 `Shift+Enter` 换行
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

### US-004: Compile Queue 卡片可点击跳详情（BUG-03）
**Description:** 作为用户，我希望点击 Compile Queue / Recently Compiled 卡片正文区域即可跳转到该 memo 的详情页。

**Acceptance Criteria:**
- [ ] 卡片正文区域（除右上角 LIGHT/FULL 切换控件外）整体可点击，跳转 `/wiki/[slug]` 或既有详情路由（按当前实际路由约定）
- [ ] 整卡使用 `<Link>` 包裹或 `role="link" tabIndex={0}` + `onClick/onKeyDown(Enter|Space)`，键盘可达
- [ ] 右上角 LIGHT/FULL 标签的 `onClick` 必须 `stopPropagation()`，避免误触发跳转
- [ ] 悬浮 hover 高亮保留；新增 `cursor-pointer` 视觉提示
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill（点击正文跳详情、点 LIGHT 不跳转、Tab+Enter 可跳转）

### US-005: 首帧 SSR/CSR 一致性统一修复（BUG-04 + BUG-05）
**Description:** 作为用户，我希望进入 `/add` 时面包屑立即显示 `CODEX / Add`，新提交的条目立即显示 `QUEUED`，无需刷新页面。

**Acceptance Criteria:**
- [ ] **根因排查**：检查 `src/app/(app)/layout.tsx` 中面包屑取值来源，确认它通过 `usePathname()` / `useSelectedLayoutSegment()` 实时派生，而非从某个全局 store / cookie 读取
- [ ] 面包屑数据流改为：Server Component 读取 `headers()` 中的实际路径 → 作为初始 prop 传给 Client → Client 用 `usePathname()` 覆盖。两侧一致，无 hydration mismatch
- [ ] 乐观更新：`POST /api/memos` 触发后，本地 query cache 立即 prepend 一条 `{ ...payload, compile_status: 'pending', id: temp-uuid }`，UI 渲染时根据 `compile_status` 显示 `QUEUED`
- [ ] SSE `/api/stream/compile` 收到对应事件后，用真实 id / status 替换 temp 条目，无视觉跳变
- [ ] 无 React hydration warning（控制台保持 0 errors / 0 warnings）
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill（从 `/home` 跳 `/add`：面包屑立即正确；提交一条：立即出现 QUEUED 文字）

### US-006: Bookmarklet 按钮改为脚本指引 Modal（BUG-06）
**Description:** 作为想把网页快速捕获到 Codex 的用户，我希望点击 Bookmarklet 按钮看到「拖到书签栏」的脚本和说明，而不是被自动附加一个图片占位文件。

**Acceptance Criteria:**
- [ ] 移除「点击 Bookmarklet 自动附加 `IMG_3836.PNG` 占位文件」的 dev-only 行为（这是测试残留）
- [ ] 点击 Bookmarklet 打开 modal，包含：
  - 一行可拖拽的书签链接：`<a href="javascript:..."`，文案 `📎 Save to Codex`
  - `<pre>` 展示 bookmarklet 脚本源码 + 一键复制按钮
  - 一段简短说明：「拖到浏览器书签栏，在任意网页点击即可把当前页面发送到 Codex」
- [ ] Modal 可通过 Esc / 点遮罩 / 关闭按钮关闭
- [ ] 不向 textarea / attachment state 写入任何内容
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

### US-007: URL 按钮改为切换 URL 输入模式（BUG-07）
**Description:** 作为用户，我希望点击 URL 按钮把输入区切换到「URL 模式」（占位符变化、自动 URL 校验），而不是把当前页地址直接填进去。

**Acceptance Criteria:**
- [ ] 点击 URL 按钮：
  - 按钮 active 态高亮（与 Photo/File 一致）
  - textarea placeholder 改为 `https://… paste the link you want to save`
  - **不**自动填入 `window.location.href`
  - 提交前若内容不是合法 URL，按钮 disabled 并显示「Enter a valid URL」
- [ ] 再次点击 URL 按钮，回退到 default `text` 模式
- [ ] 已粘贴文本时切换模式不清空 textarea，只更新 placeholder/校验
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

### US-008: Photo / File 按钮补齐选择器（BUG-08）
**Description:** 作为用户，我希望点击 Photo 按钮唤起相机/相册选择，点击 File 按钮唤起文件选择，把附件挂到草稿上。

**Acceptance Criteria:**
- [ ] Photo 按钮：
  - 点击触发隐藏 `<input type="file" accept="image/*" capture="environment">`
  - 选中后在 textarea 下方展示缩略图卡片（含文件名、大小、✕ 移除）
- [ ] File 按钮：
  - 点击触发隐藏 `<input type="file">`（不限制 accept；单文件，多文件留作 Post-MVP）
  - 选中后展示通用附件卡片
- [ ] 附件信息（文件名、size、blobUrl）随表单 `multipart/form-data` 提交，或先 `POST /api/uploads` 拿到 ref 再提交 memo（按当前后端约定取一致路径）
- [ ] 移除附件后按钮 active 态自动取消
- [ ] 上传中显示 loading；上传失败 toast「Upload failed, try again」
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

### US-009: 输入交互性能稳定性（BUG-09）
**Description:** 作为通过 CDP / Playwright 高频驱动页面的自动化用户，我希望按钮点击响应时间稳定 < 300ms，不再偶发 30s 超时。

**Acceptance Criteria:**
- [ ] 用 React Profiler / `performance.measure` 定位 `UnifiedInput` 渲染开销，按钮 `onClick` 不在渲染期间执行同步重计算
- [ ] 移除任何 `onChange` 中对全表单的 deep-clone / `JSON.stringify` 之类 hot path
- [ ] 在 Playwright e2e（`web/e2e/`）新增一个高频点击模式按钮的稳定性测试，连续 50 次点击全部成功
- [ ] Typecheck/lint passes

### US-010: E2E 回归用例集
**Description:** 作为维护者，我希望本 PRD 涉及的修复都有 Playwright 测试守护，避免后续回归。

**Acceptance Criteria:**
- [ ] 在 `web/e2e/add.spec.ts`（沿用现有约定）补充：草稿回填、⌘+Enter 提交、卡片跳详情、面包屑首帧、QUEUED 即时显示、Bookmarklet modal、URL 模式切换、Photo/File 选择
- [ ] `pnpm e2e`（或项目实际命令）全部通过
- [ ] CI 中新增/已有的 e2e job 跑过

## 4. Functional Requirements

- **FR-1**：草稿在 `localStorage` 键 `codex.add.draft.v1` 下持久化；提交成功或主动清空后自动清除。
- **FR-2**：草稿同步到服务端由 env `NEXT_PUBLIC_CODEX_DRAFT_SYNC` 控制，默认关闭；API 路径预留 `GET/PUT /api/drafts/add`。
- **FR-3**：textarea 监听 `⌘/Ctrl + Enter`，等价于点击 Add；disabled 时不触发；`Shift+Enter` 不受影响。
- **FR-4**：Compile Queue / Recently Compiled 卡片正文整体可点击，跳转到详情路由；LIGHT/FULL 切换按钮 `stopPropagation`。
- **FR-5**：面包屑数据流由 `usePathname()` 派生，杜绝 SSR/CSR 不一致；初次进入 `/add` 即显示 `CODEX / Add`。
- **FR-6**：`POST /api/memos` 后立即在客户端 query cache 乐观插入一条 `compile_status: 'pending'` 的条目，UI 显示 `QUEUED`；SSE 到达后无视觉跳变地替换为真实数据。
- **FR-7**：Bookmarklet 按钮 → 打开「书签脚本指引」modal；不写任何 attachment / textarea 状态。
- **FR-8**：URL 按钮 → 切换 URL 输入模式（placeholder + 校验）；不自动填 `window.location.href`。
- **FR-9**：Photo 按钮 → 触发 `<input type="file" accept="image/*" capture="environment">`；File 按钮 → 触发 `<input type="file">`；选中后展示附件卡片，可 ✕ 移除。
- **FR-10**：所有 `onClick` 处理避开重型同步计算；高频点击模式按钮（≥50 次）稳定无超时。
- **FR-11**：测试报告中已通过的 20 个用例（基础输入、URL 自动识别、Save draft 提示、XSS 安全、侧栏导航等）全部保持通过。

## 5. Non-Goals (Out of Scope)

- ❌ Voice 录音功能（aria-label 已声明 "coming soon"，本 PRD 不实现录音/转写）。
- ❌ 多附件支持（仅单附件；多附件留作 Post-MVP）。
- ❌ 草稿历史版本 / 多草稿管理（仅单条 active 草稿）。
- ❌ 草稿服务端 schema 详细设计（仅留 API 骨架，DB migration 不在本 PRD）。
- ❌ Compile Queue 排序 / 过滤功能改造。
- ❌ Recently Compiled 区块的可视化升级。
- ❌ 移动端响应式 / 触控适配（默认沿用既有断点；额外打磨另立 PRD）。
- ❌ Wiki / Chat / Inbox 其他路由的修复。

## 6. Design Considerations

- **草稿恢复提示**：`Restored draft · 3 min ago` 使用浅灰色细字，紧贴 textarea 下方与「Discard draft」并排。
- **Bookmarklet Modal**：复用现有 `Card` / `Btn` / `Icon` 组件（`src/components/ui/`），避免引入新的 dialog 库；如缺乏 modal 原语，新增最简 `Dialog` 组件并标明可被复用。
- **卡片可点击的视觉反馈**：hover 高亮已存在；新增 `cursor-pointer` + 1px outline 焦点态以满足键盘可达。
- **快捷键 hint 跨平台**：用 `navigator.platform` / `userAgent` 区分 macOS 显示 `⌘ + Enter`，其他显示 `Ctrl + Enter`。
- **乐观更新视觉**：临时条目可用 0.6 opacity + 微旋转 spinner 区分「尚未确认」；SSE 回包后过渡到正常态。

## 7. Technical Considerations

- **核心文件**（沿用现有结构）：
  - `web/src/app/(app)/add/page.tsx`
  - `web/src/app/(app)/add/UnifiedInput.tsx`（输入区 + 模式按钮 + Save draft/Add）
  - `web/src/app/(app)/add/CompileQueue.tsx`
  - `web/src/app/(app)/add/RecentlyCompiled.tsx`
  - `web/src/app/(app)/layout.tsx`（面包屑数据流）
  - `web/src/app/(app)/_components/`（如需新增 Dialog / Toast）
  - `web/e2e/add.spec.ts`（新增 / 扩展）
- **状态层**：草稿建议放在 `UnifiedInput` 内部 + 一个独立 hook `useAddDraft()`（封装 LS 读写与可选同步）；不要污染全局 store。
- **乐观更新**：若已用 `@tanstack/react-query`（`QueryProvider.tsx` 存在），用 `queryClient.setQueryData(['memos','pending'], …)` 实现，SSE handler 内部 `invalidateQueries` 或 `setQueryData` 替换 temp id。
- **SSE 已经能跑通**，不动 `/api/stream/compile`。
- **不引入新依赖**；如必须，单独说明并讨论。
- **a11y**：所有新增可点击元素具备 keyboard focus 样式 + `aria-label`。

## 8. Success Metrics

- 测试报告里 9 个 bug 全部回归通过；新增 e2e 用例 ≥10 条全部 PASS。
- `pnpm dev` / 生产构建后，DevTools console 维持 0 errors / 0 warnings（含 hydration warning）。
- 草稿恢复率：在内部 dogfood 下「写过 → 刷新 → 草稿仍在」的成功率 100%。
- 高频点击 e2e（50 次/按钮）零超时。
- 整张 `/add` 页面在 1295×924 视窗下 TTI（Time To Interactive）不退化超过 +50ms。

## 9. Open Questions

- ❓ Compile Queue 卡片跳转的详情路由是 `/wiki/[slug]`、`/inbox/[id]` 还是新路由？需在实现前确认（grep 现有 `Link` 使用）。
- ❓ 附件上传走 `POST /api/uploads` 还是直接 `multipart` 嵌在 `POST /api/memos`？需对齐后端实际实现。
- ❓ Bookmarklet 脚本的最终 payload 形态（直接 `POST /api/memos` 还是先开 `/add?url=...`）？影响 modal 内复制的代码字符串。
- ❓ 草稿同步（US-002）是否需要在本里程碑里真的暴露 env，还是放到 Post-MVP？目前 PRD 已默认关闭。
- ❓ 是否需要把 ⌘+Enter / Esc 等快捷键写入全站 keymap，避免不同页面行为分裂？（建议在后续「全站 keymap」单 PRD 里收敛。）

---

**Source / 参考**：`/add` 页面端到端测试报告（2026-05-20，CODEX v0.4 PRIVATE，1295×924）。
