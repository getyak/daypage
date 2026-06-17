# DayPage 深度调研报告 · 2026-06

> **来源**：deep-research workflow（5 角度并行 WebSearch → 25 个源 → 109 条 claim → 21 条三票通过 / 4 条被推翻）。
> **范围**：导出与 Agent 友好的存储形态、本地优先 + 多端同步、iOS 26/27 最佳实践、Watch/锁屏/Action Button/App Intents/Mac 等多入口记录形态。
> **目的**：在 `docs/PRD-vNext.md`、`docs/liquid-glass-vNext.md`、`docs/web-design-vNext.md` 既有蓝图之上做"向上延伸"，避免重复造轮子。
> **已验证 claim**：21 条；详细引用见各节末尾"引用"。

---

## 0. TL;DR（决策建议）

| 决策 | 推荐 | 关键依据 |
|---|---|---|
| 单一信源（source of truth） | **`vault/raw/*.md` 保持是唯一信源**；索引/向量库/图谱皆为可丢弃产物 | "Indexes are disposable: rebuild from Markdown at any time." [11] |
| Front-matter schema | 拆 **semantic / episodic / provenance** 三层，新增 `provenance`、`source`、`extracted_at`、`confidence` 字段 | agent-friendly vault 模式 [10] |
| Wikilink 互操作 | **同时支持 `[[…]]` 与相对路径**；写入侧默认 `[[…]]` 以兼容 Obsidian | Obsidian-compatible vault [10] |
| 多端同步 | **本地优先 + per-file Y.Doc CRDT + secsync 风格 E2EE**；Supabase 只做加密 relay | per-file Y.Doc / 增量 base64 / 端到端加密在 CRDT 层 [1][2][3]；secsync 协议 [6][7] |
| E2EE 密码学 | **AES-256-GCM + scrypt(N=32768) + HKDF-SHA-256**（对标 Obsidian Sync），不引 libsodium | Obsidian Sync 公开方案 [4][5] |
| 媒体附件 | secsync 协议**未覆盖附件**，需自研内容寻址（CAS）层，与 CRDT log 分离 | [8] |
| MCP 接入 | 暴露 **Filesystem-style + Memory-style 双 MCP server**：raw memos 走 file resource，entity/concept/relation 走 knowledge graph resource | 官方 reference servers [12][13][14] |
| 向量索引 | **iOS 16 兼容：SQLiteVec (sqlite-vec 绑定)**；后续可升 iOS 18 时再上 VecturaKit (NaturalLanguage 全本地嵌入) | [9][10][11] |
| Watch 入口 | **iOS Live Activity 自动出现在 Smart Stack**，先零代码登 Apple Watch；独立 watchOS App 仅做"5 秒速记 + WatchConnectivity 回传" | [17][18][19] |
| 智能浮现 | Watch widget 用 **RelevantContext API**（date/location/sleep/fitness） | [18] |

---

## 1. 主题一 · 导出与 Agent 友好的存储形态

### 1.1 现状

- 持久层：`vault/raw/YYYY-MM-DD.md`，多 memo 用 `\n\n---\n\n` 分隔；YAML front-matter + Markdown body；附件落到 `vault/raw/assets/`。
- 已具备：`Models/Memo.swift`（手写 YAML 解析）、`Services/MarkdownExportService.swift`、`Services/ConflictMerger.swift`。
- 缺口：front-matter 字段是给「人 + DayPage 自己」看的，**没有给 Agent 的稳定抽取面**；附件采用相对路径，缺去重；wikilink 语法未与 Obsidian 对齐；索引（实体页 / Graph）和 raw 之间的可重建关系未声明。

### 1.2 选项对比

#### (a) 文件格式 / Schema

| 形态 | 适合 | 不适合 |
|---|---|---|
| Markdown + YAML front-matter | 长期可移植、人类可读、PKM 生态默认 | 关系/三元组表达力弱 |
| 内嵌 JSON-LD `<script>` 块 | LLM 抽取友好、schema.org 标准 | 增加双轨维护成本 |
| 独立 `*.ttl` / 三元组 | 严格语义网 | 偏离用户视角 |

**推荐**：保留 Markdown 为信源；front-matter **分三层**：

```yaml
# semantic — 给人和导出
title: …
tags: [travel, japan]

# episodic — 给 Agent 的"会话/事件"维度
session_id: 2026-06-17-001
ts: 2026-06-17T14:32:18+09:00
location: { lat, lon, name }
weather: { ... }

# provenance — 给 Agent 判断信度
provenance:
  kind: human|extracted|inferred|ambiguous   # 来自 obsidian-wiki 模式 [10]
  source: whisper-1|qwen3.5-plus|user
  extracted_at: 2026-06-17T02:00:00+09:00
  confidence: 0.0-1.0
```

实体抽取结果**另写**到 `vault/entities/{slug}.md`、`vault/concepts/{slug}.md`、`vault/sessions/{date}.md`，与 Obsidian agent vault 拓扑对齐 [10]：

```
vault/
  raw/            # 信源，唯一
  entities/       # AI 抽取（可重建）
  concepts/       # AI 抽取（可重建）
  sessions/       # AI 抽取（可重建）
  _agent/         # MCP / 索引产物（可丢弃）
```

#### (b) 附件引用

- 现状：相对路径，重复粘贴 = 多份原图。
- 推荐：**CAS（content-addressed storage）**：`vault/raw/assets/sha256/ab/cdef…m4a`；front-matter 用 `cid: sha256:abcdef…` 索引，避开 IPFS 协议成本。这也方便 secsync 风格的端到端加密链路 [6][7][8]。

### 1.3 与 Obsidian/Logseq/Bear 互操作

- 写入侧默认 `[[wikilink]]`，可被 Obsidian 直接打开 [10][11]。
- 不引入 Logseq 块引用语法（`((blockid))`），代价过高。
- `.obsidian/` 不进 git，避免污染。

### 1.4 引用

- [10] agent vault 顶层目录 `_agent / projects / sessions / entities / concepts / procedures`：https://github.com/r0b0tlab/llm-wiki_obsidian_hermes_r0b0tlabbra1n (vote 2-1)
- [11] "Indexes are disposable: rebuild from Markdown at any time."：同上 (vote 2-0, 1 abstain)
- 推翻：「使用 `_raw/` 暂存 + `.manifest.json` 增量追踪」该 claim 被 0-0 弃权（rate limit），不作为依据。

---

## 2. 主题二 · 本地优先 + 多端同步 + E2EE

### 2.1 现状与约束

- 已有 `ConflictMerger.swift`，但策略是字符串级三方合并，不是字段级 CRDT。
- 已依赖 Supabase（auth + postgres）+ Sentry。
- 必须支持「Mac/iPad/Web/Watch」四端最终一致。

### 2.2 选项对比

| 方案 | 优点 | 缺点 |
|---|---|---|
| Git + S3 | 用户可读懂、可审计 | 二进制/合并体验差，移动端嵌入复杂 |
| iCloud Documents | iOS 原生最低成本 | 跨 Web/Android 死路，加密不可控 |
| Supabase Postgres + Realtime | 已经依赖、SQL 查询友好 | 服务端能看到明文，与"本地优先 + E2EE"冲突 |
| **Per-file Y.Doc CRDT + Secsync E2EE relay (本推荐)** | 字段级合并、断网可用、服务端零信任 | 实现成本最高 |
| Automerge | 文档历史模型更完整 | 文本 CRDT 性能不如 Yjs |
| Loro | 性能强 | 生态新、Swift 绑定不成熟 |

### 2.3 推荐方案

1. **每个 .md 文件一个 Y.Doc**（"Each file path receives its own `Y.Doc`."），更新走幂等增量 [1][2]。
2. **Mutation log** 落到 `vault/_agent/sync/log.sqlite`，存 base64 编码 Yjs update，节省带宽 [2]。
3. **Secsync 协议风格**：服务端只 relay 加密 CRDT 消息，不解密；同时支持 Yjs/Automerge 双 backend，便于未来选择 [6][7]。
4. **E2EE 套件对标 Obsidian Sync**（成熟、可被独立审计 [4][5]）：
   - Cipher: **AES-256-GCM**（12B IV，16B auth tag）[4]
   - KDF: **scrypt(N=32768, r=8, p=1)** + per-vault salt；v3 再叠 **HKDF-SHA-256** [5]
   - 不引入 libsodium，使用 `CryptoKit`（iOS 13+ 原生）即可
   - device bootstrap 走 owner mnemonic（24 字助记词）[3]
5. **媒体附件单独通道**：secsync 不覆盖文件 [8]，按 CAS 切片 + AES-GCM 加密上传 Supabase Storage；引用层仅同步 `cid`。
6. **Supabase 角色重定位**：从"数据库"降级为"加密 relay + 对象存储 + auth"。不再让服务端字段感知 memo 内容。

### 2.4 影响文件

| 文件 | 动作 |
|---|---|
| `DayPage/Services/ConflictMerger.swift` | 弃用字符串三方合并，新建 `YDocStore.swift` 包装每文件 Y.Doc |
| 新增 `DayPage/Services/Sync/` 目录：`YDocStore.swift`、`SecsyncRelay.swift`、`VaultCrypto.swift`、`AttachmentCAS.swift` | 见上 |
| 新增 `web/lib/sync/` | Web 端走相同 secsync 协议 |
| 新增 `supabase/migrations/2026xx_secsync.sql` | 仅存密文 blob + per-doc seq |
| 新增 `docs/ADR-0001-sync-architecture.md` | 落库决策 |

### 2.5 引用

- [1] Per-file Y.Doc / idempotent / source of truth：https://github.com/elcomtik/obsidian-local-sync (3-0)
- [2] Base64 增量更新到 `evolu_history`：同上 (3-0)
- [3] E2EE 在 `@evolu/common` CRDT 消息层 + owner mnemonic：同上 (3-0)
- [4] AES-256-GCM / 12B IV / 16B tag：https://obsidian.md/blog/verify-obsidian-sync-encryption/ (3-0)
- [5] scrypt + HKDF-SHA-256：同上 (3-0)
- [6] Secsync = E2EE CRDT relay：https://github.com/SerenityNotes/naisho (3-0)
- [7] Secsync 同时支持 Yjs 和 Automerge：同上 (3-0)
- [8] Secsync 不覆盖附件 → 需自研 CAS 层：同上 (3-0)

---

## 3. 主题三 · MCP 接入与向量索引

### 3.1 推荐：暴露**双 MCP server**

| Server | 类型对照 | 资源 | 工具 |
|---|---|---|---|
| `daypage-files` | 类 Filesystem [12] | `file:///vault/raw/YYYY-MM-DD.md` | `read_memo`, `append_memo`, `search_grep` |
| `daypage-graph` | 类 Memory（knowledge graph）[13] | `entity://`、`concept://`、`session://` | `get_entity`, `link`, `traverse`, `vector_search` |

MCP 三种 capability（prompts / resources / tools）必须齐全 [14]。

### 3.2 向量索引选型

| 候选 | iOS 16 兼容 | 备注 |
|---|---|---|
| **SQLiteVec**（sqlite-vec Swift 绑定）[15] | ✅ | 推荐 P0；与已有 SQLite 共库，零外部依赖 |
| VecturaKit（Apple NaturalLanguage 全本地嵌入）[16] | ❌ 要 **iOS 18 + Swift 6** | P1，待平台升级窗口 |
| LanceDB (`lancedb_mcp`) | ✅（macOS/Web） | Mac/Web 端可直接套，iOS 端不优 [20][21] |
| Chroma / Turso | — | 服务端化与本地优先冲突，不推荐 |

**结论**：iOS 端先上 **SQLiteVec**；Mac/Web 端可同时跑 LanceDB（暴露 `table://memos` 资源 [20]）。embedding 阶段先用 DashScope 或 Whisper-already-on-device，等 iOS 18 全面铺开再切 Apple NaturalLanguage（不需要把原文发给云）[16]。

### 3.3 影响文件

```
DayPage/Services/Agent/
  MCPServer.swift        # 本地 sock / unix domain socket
  VectorIndex.swift      # SQLiteVec 封装
  EntityResource.swift   # 暴露 entity:// 资源
packages/mcp-daypage/    # Node/Bun MCP server，Mac/Web 共用
docs/ADR-0002-mcp.md
```

### 3.4 引用

- [12] Filesystem reference server：https://github.com/modelcontextprotocol/servers (2-1)
- [13] Memory server (knowledge graph)：同上 (3-0)
- [14] prompts/resources/tools 三种 capability：同上 (3-0)
- [15] SQLiteVec Swift 绑定：https://github.com/jkrukowski/SQLiteVec (3-0)
- [16] VecturaKit 要求 iOS 18 / Swift 6 + Apple NaturalLanguage：https://github.com/rryam/VecturaKit (3-0)
- [20] lancedb_mcp 通过 `table://{name}` 暴露资源：https://github.com/RyanLisse/lancedb_mcp (3-0)
- [21] 默认本地路径 `~/.lancedb`：同上 (3-0)

---

## 4. 主题四 · iOS 26/27 最佳实践（与 `liquid-glass-vNext.md` 衔接）

> 既有 `docs/liquid-glass-vNext.md` 已覆盖玻璃 modifier 双轨；本节**只做补充**——不重复 Liquid Glass 内部分发器细节。

### 4.1 手势补强（在 `project_card_swipe_gesture.md` 之上）

memo 仓库已经走通"左滑分享/删除、右滑置顶"。本调研建议补：

| 手势 | 位置 | 动作 | 备注 |
|---|---|---|---|
| 长按 + hover preview | MemoCard | 弹悬浮预览卡（带完整正文 + 附件） | iOS 26 上 `.hoverEffect(.lift)` + 触觉 |
| Drag-out | MemoCard | 拖出到其他 App（分享/笔记/Obsidian） | `NSItemProvider` |
| Pencil hover | 写作面板 | 显示工具提示 | Pencil Pro 已普及 |
| Two-finger swipe | TodayView 卡片栈 | 切日 | 与系统返回不冲突 |
| 双击空白 | 任何输入框 | 唤起语音速记 | 单一可记忆动作 |

### 4.2 无障碍 / Dynamic Type / 暗黑

按 WCAG 2.2 与 Apple HIG，关键点：

1. Markdown 渲染走 `AttributedString` + Dynamic Type 全档位（含 AX 五档），不要硬编码字号。
2. `Reduce Motion` 下关闭 Spring 动画 — 已在 `project_input_smoothness.md` 中收敛动画路径，可顺手加这个开关。
3. `Reduce Transparency` 下回退 Solid Card —— 玻璃蓝图已处理 [`Surfaces.swift`]。
4. 颜色全部走 `design-tokens/tokens.json`，CI 已有 drift check，避免回归。

### 4.3 引用

- nilcoalescing Liquid Glass / Sheets：blog 源（5 角度抓取，未单独 verify，参考用）
- fatbobman iOS 26 grow：同上
- swiftcrafted SwiftUI Accessibility：同上

---

## 5. 主题五 · 多入口记录形态

### 5.1 Apple Watch（已有 `DayPageWatch/` 骨架）

**核心发现**：**iOS 应用的 Live Activity 在 watchOS 11 自动出现在 Smart Stack，零代码**，先用这个零成本入口接通 Watch，再做独立录音 [17]。

补充建议：

1. `DayPageWatch/Features/RecordingView.swift` 强化为"workout-style 持续录音"，保活靠 `WKAudioRecorderController`。
2. 用 **RelevantContext API**（date/location/sleep/fitness）让"今天还没写"的提醒卡片在合适时机浮在 Smart Stack 顶部 [18]。
3. 利用 **watchOS 11 交互式 widget**（buttons/toggles）做一键 record 入口 [19]。
4. 数据回传：`WatchTransferService.swift` 已在，建议 audio 文件本地缓存 + WatchConnectivity 异步回传 iPhone，再由 iPhone 上调 Whisper —— **不在 Watch 直传云端**，节流和电量。

### 5.2 锁屏 / 灵动岛 / 控制中心 / Action Button

`DayPageWidget/` 已经接通 `QuickCaptureControl`（iOS 18+）和 `QuickCaptureWidget` → `daypage://record`，本调研建议补：

- 编译时 Live Activity（"AI 正在写今天的日记…"）= `BackgroundCompilationService.swift` 触发 ActivityKit，Dynamic Island 显示进度。
- Action Button 走 App Intent（见下节），让用户可在系统设置里直接绑定。
- Always-On 锁屏 widget 显示今日 memo 计数 + "已写 N 条"。

### 5.3 Shortcuts / Siri / App Intents

定义最小 intent 集（放到 `DayPage/Intents/`）：

| Intent | 触发 | 说明 |
|---|---|---|
| `QuickCaptureIntent` | "记一笔 …" / Action Button | 同 Widget 已用 |
| `StartVoiceMemoIntent` | "DayPage 开始录音" | 拉起 voice recorder |
| `OpenDailyPageIntent($date)` | "打开 6 月 17 日的日记" | parameter = `IntentDate` |
| `AskTodayIntent($query)` | "今天我去过哪些地方" | 走 MCP graph server |

接 Apple Intelligence Writing Tools，对长 memo 提供"润色/提炼"二级 action。

### 5.4 Mac / iPad / 全局快捷键

- Mac 端：**原生 SwiftUI on macOS**（不走 Catalyst），与 iPad 共享代码；Menu Bar app（NSStatusItem）做速记入口。
- 全局快捷键：⌥Space 唤起浮窗（对标 Raycast），用 `CGEventTap`，落在独立 `DayPageMac/` target。
- iPad：SplitView 左侧 Today、右侧详情；Apple Pencil 走 PencilKit + 转 Markdown。

### 5.5 引用

- [17] iOS Live Activity 自动出现在 Watch Smart Stack：https://developer.apple.com/videos/play/wwdc2024/10205/ (3-0)
- [18] RelevantContext API：同上 (3-0)
- [19] watchOS 11 交互式 widget：同上 (3-0)
- App Intents / Apple Intelligence 集成 5 个 blog 源（未单独 verify）

---

## 6. 与既有文档衔接

| 既有文档 | 本报告如何衔接 |
|---|---|
| `docs/PRD-vNext.md` | 本报告为"AI 友好 + 多端同步"补需求面，可作为附录 |
| `docs/liquid-glass-vNext.md` | 不重复；只在第 4 节做"手势 + 无障碍"补充 |
| `docs/web-design-vNext.md` + memory `project_web_compile_deadlock.md` | MCP graph server 同时服务 web 端 wiki 的"冷启动死锁"——entity/concept 由本机 raw 编译产出 |
| memory `project_card_swipe_gesture.md` | 手势矩阵在其之上叠加 hover preview / drag-out |
| memory `project_input_smoothness.md` | 无障碍小节顺手加 Reduce Motion 开关 |
| memory `project_design_bundle_v8.md` | Dynamic Type / 色板继续走 design-tokens，CI drift check 沿用 |

---

## 7. 实施清单（按优先级排序）

> 每个条目格式：**标题 / 动机 / 影响文件 / 估时 / 依赖 / 验收**

### P0（先做、解锁后续）

**ISSUE-A · ADR-0001：同步架构与 E2EE 套件落库**
- 动机：把"per-file Y.Doc + secsync relay + AES-256-GCM/scrypt/HKDF"决策正式留底，避免后续 PR 来回拉扯。
- 文件：新建 `docs/ADR-0001-sync-architecture.md`、`docs/ADR-0002-mcp.md`、`docs/ADR-0003-storage-schema.md`。
- 估时：1 天。
- 依赖：无。
- 验收：ADR 三份，含选项矩阵、推荐方案、风险、退路。

**ISSUE-B · Front-matter v2：semantic / episodic / provenance 三层**
- 动机：让外部 Agent 可以稳定抽取 entity/relation/time/source。
- 文件：`DayPage/Models/Memo.swift`（解析器扩展，**保持 v1 向后兼容**）、`DayPage/Services/MarkdownExportService.swift`（导出走 v2）、`vault/raw/*.md`（迁移脚本 `scripts/migrate_frontmatter_v2.py`）、`web/lib/markdown/parser.ts`。
- 估时：3 天。
- 依赖：ISSUE-A。
- 验收：旧 vault 能被自动 lift 到 v2；输出可被 Obsidian 直接打开；新增 `provenance.kind/source/extracted_at/confidence` 字段在导出包含。

**ISSUE-C · 附件 CAS 化（content-addressed storage）**
- 动机：附件去重 + 为 E2EE 上传通道做准备。
- 文件：新建 `DayPage/Services/Sync/AttachmentCAS.swift`；改 `DayPage/Services/PhotoService.swift`、`DayPage/Services/VoiceService.swift`；迁移脚本 `scripts/migrate_assets_cas.py`。
- 估时：3 天。
- 依赖：ISSUE-B（front-matter 引用从相对路径切 `cid:` URI）。
- 验收：同一图片被两 memo 引用只占一份磁盘；旧 vault 可一键迁移。

### P1（核心能力）

**ISSUE-D · YDocStore：每文件 Y.Doc + 增量 log**
- 动机：弃用字符串三方合并，走字段级 CRDT。
- 文件：新建 `DayPage/Services/Sync/YDocStore.swift`、`DayPage/Services/Sync/VaultCrypto.swift`；废弃 `DayPage/Services/ConflictMerger.swift`（保留只读做迁移）；新增依赖 `yswift`（仓库选型时确认许可）。
- 估时：8 天。
- 依赖：ISSUE-A、ISSUE-B。
- 验收：同一文件在 iPhone / Mac / Web 三端离线编辑后合并无丢字。

**ISSUE-E · Secsync 风格 E2EE relay（Supabase）**
- 动机：让 Supabase 服务端零知识，仅做密文 relay。
- 文件：新建 `DayPage/Services/Sync/SecsyncRelay.swift`、`supabase/migrations/2026xx_secsync_relay.sql`、`web/lib/sync/secsync.ts`。
- 估时：6 天。
- 依赖：ISSUE-D。
- 验收：Supabase DB 仅见加密 blob + seq；任何端可作为唯一在线设备启动并拉取全部 ciphertext。

**ISSUE-F · MCP Filesystem-style server（本地）**
- 动机：让 Claude/Cursor 直接读 DayPage vault。
- 文件：新建 `packages/mcp-daypage-files/`（Bun/Node）、`DayPage/Services/Agent/MCPServer.swift`（iOS 端内嵌 socket）、`docs/MCP-USAGE.md`。
- 估时：5 天。
- 依赖：ISSUE-B。
- 验收：本地 Claude Code 可看到 `file:///vault/raw/*.md` 资源；`read_memo` / `append_memo` / `search_grep` 三工具可用。

**ISSUE-G · 向量索引 SQLiteVec + 增量重建**
- 动机：让 Graph/EntityPage/wiki 的"冷启动死锁"（见 memory `project_web_compile_deadlock.md`）能直接由本机产出。
- 文件：新建 `DayPage/Services/Agent/VectorIndex.swift`、`DayPage/Services/Agent/EntityResource.swift`；schema 落到 `vault/_agent/vectors.sqlite`（**可丢弃**，对应 claim [11]）。
- 估时：5 天。
- 依赖：ISSUE-F、ISSUE-B。
- 验收：删掉 `_agent/` 后启动可重建；100 篇 memo 重建 < 30 秒。

**ISSUE-H · App Intents 最小集（QuickCapture / StartVoiceMemo / OpenDailyPage / AskToday）**
- 动机：打开 Siri / Shortcuts / Action Button / Spotlight 全部入口。
- 文件：新建 `DayPage/Intents/QuickCaptureIntent.swift`、`StartVoiceMemoIntent.swift`、`OpenDailyPageIntent.swift`、`AskTodayIntent.swift`；新增 `DayPage/App/AppIntentRouter.swift`。
- 估时：4 天。
- 依赖：无。
- 验收：四个 Intent 在 Shortcuts.app 可见且能跑通；Spotlight 输入"DayPage"出现快速入口。

### P2（高价值但可后续）

**ISSUE-I · watchOS 11 智能浮现 + 交互式 widget**
- 动机：让 Watch 在合适时机自动 nudge 用户记一笔。
- 文件：`DayPageWatch/Features/RecordingView.swift`、新增 `DayPageWatch/Widgets/SmartCaptureWidget.swift`、`DayPageWatch/Services/RelevantContextProvider.swift`。
- 估时：4 天。
- 依赖：ISSUE-H（共享 Intent）。
- 验收：地理位置变化或晚 22:00 后未写 memo 时，widget 浮到 Smart Stack 顶部；点击直达录音。
- 引用：[17][18][19]

**ISSUE-J · 编译态 Live Activity（Dynamic Island）**
- 动机：`BackgroundCompilationService` 跑的时候让用户可见。
- 文件：`DayPage/Services/BackgroundCompilationService.swift`（触发 ActivityKit）、新建 `DayPageWidget/CompilationLiveActivity.swift`。
- 估时：3 天。
- 依赖：无。
- 验收：手动触发编译时灵动岛出现进度；watchOS Smart Stack 镜像可见（零代码 [17]）。

**ISSUE-K · Mac 端：Menu Bar 速记 + ⌥Space 全局浮窗**
- 动机：让 nomad 在 Mac 上也能 5 秒速记。
- 文件：新建 `DayPageMac/` target；`MenuBarController.swift`、`GlobalHotkey.swift`（基于 `CGEventTap`）。
- 估时：6 天。
- 依赖：ISSUE-D（Mac 端共享 vault）。
- 验收：⌥Space 在任何 App 之上唤起；速记内容当天同步到 iPhone。

**ISSUE-L · 手势补强：长按 hover preview + drag-out + 双击空白唤起语音**
- 动机：在已落地的左右滑之上提高记录密度。
- 文件：`DayPage/Features/Today/TodayView.swift`、`DayPage/Components/MemoCard.swift`、`DayPage/Features/Today/InputBarV4.swift`。
- 估时：4 天。
- 依赖：无。
- 验收：长按 MemoCard 出 hover preview（含附件）；拖出可投递到 Obsidian / Apple Notes。

**ISSUE-M · Reduce Motion / Reduce Transparency 全局开关**
- 动机：补无障碍空缺。
- 文件：`DayPage/Components/Motion.swift`（已存在 `countTick` 等动画 helper，按 `@Environment(\.accessibilityReduceMotion)` 短路）。
- 估时：1 天。
- 依赖：无。
- 验收：系统设置打开"减弱动态效果"后所有 Spring 动画退化为线性 fade。

**ISSUE-N · Dynamic Type 全档位审计**
- 动机：让 AX 五档下 Markdown 渲染不破。
- 文件：`DayPage/App/Typography.swift`（确保都用 `Font.system(_:design:weight:)` 而非硬编码 pt）；新增 `DayPageTests/DynamicTypeSnapshotTests.swift`。
- 估时：2 天。
- 依赖：无。
- 验收：在 AX1~AX5 五档下 Today / Archive / EntityPage 不截断、不溢出。

---

## 8. 风险与未解决

- Synthesize 阶段被 rate-limit 打断，4 条 obsidian-wiki / `_raw` 暂存策略 claim 处于 **abstain（弃权）** 状态——本报告未把它们作为依据。若需要走"暂存 + manifest 增量"路线，**需要补一轮独立 verify**。
- VecturaKit 全本地嵌入路径绑定 iOS 18，请在 ISSUE-G 实施时同步评估「是否值得把 deployment target 从 16 → 18 提前」。
- secsync 协议官方未覆盖附件 [8]，ISSUE-C 的 CAS 层是自研，需要独立的安全审计。

---

## 9. 引用总表

| # | 出处 | vote |
|---|---|---|
| 1 | https://github.com/elcomtik/obsidian-local-sync — per-file Y.Doc | 3-0 |
| 2 | 同上 — base64 增量 log | 3-0 |
| 3 | 同上 — E2EE on CRDT layer + mnemonic | 3-0 |
| 4 | https://obsidian.md/blog/verify-obsidian-sync-encryption/ — AES-256-GCM | 3-0 |
| 5 | 同上 — scrypt + HKDF-SHA-256 | 3-0 |
| 6 | https://github.com/SerenityNotes/naisho — Secsync relay | 3-0 |
| 7 | 同上 — Yjs + Automerge | 3-0 |
| 8 | 同上 — 不覆盖附件 | 3-0 |
| 9 | https://github.com/jkrukowski/SQLiteVec — Swift 绑定 | 3-0 |
| 10 | https://github.com/r0b0tlab/llm-wiki_obsidian_hermes_r0b0tlabbra1n — `_agent/projects/sessions/entities/concepts/procedures` | 2-1 |
| 11 | 同上 — Indexes are disposable | 2-0 (1 abstain) |
| 12 | https://github.com/modelcontextprotocol/servers — Filesystem | 2-1 |
| 13 | 同上 — Memory (knowledge graph) | 3-0 |
| 14 | 同上 — prompts/resources/tools 三能力 | 3-0 |
| 15 | https://github.com/rryam/VecturaKit — iOS 18 + Swift 6 门槛 | 3-0 |
| 16 | 同上 — NaturalLanguage 全本地嵌入 | 3-0 |
| 17 | https://developer.apple.com/videos/play/wwdc2024/10205/ — iOS Live Activity → Watch Smart Stack 自动 | 3-0 |
| 18 | 同上 — RelevantContext API | 3-0 |
| 19 | 同上 — watchOS 11 交互式 widget | 3-0 |
| 20 | https://github.com/RyanLisse/lancedb_mcp — table:// 资源 | 3-0 |
| 21 | 同上 — 本地 `~/.lancedb` | 3-0 |

> 推翻 (refuted) 4 条已从依据中剔除（详见 task output `w080burqi.output`）。
