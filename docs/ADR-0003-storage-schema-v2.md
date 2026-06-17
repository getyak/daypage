# ADR-0003 · Front-matter v2 与 vault 目录结构

- **状态**：Proposed
- **日期**：2026-06-17
- **关联**：`docs/research-2026-06-storage-and-capture.md` 第 1 节；ADR-0001（CRDT 同步）、ADR-0002（MCP）
- **影响范围**：`DayPage/Models/Memo.swift`、`DayPage/Services/MarkdownExportService.swift`、`DayPage/Storage/RawStorage.swift`、`vault/raw/*.md`（迁移）、`web/lib/markdown/`

---

## 1. 背景

调研报告 §1 给出的"agent-friendly Markdown vault"模式（引用 [10][11]）——`_agent / projects / sessions / entities / concepts / procedures` 顶层目录——已被多个开源项目验证。

当前 DayPage front-matter 字段（来自 `DayPage/Models/Memo.swift`）：

```yaml
id, type, created, pinnedAt, location, weather, device,
attachments, mood, entityMentions, body
```

问题：

1. **没有 provenance**：Agent 看不出哪段是用户原话、哪段是 AI 提炼、哪段是 Whisper 转写。错误传染风险。
2. **附件用相对路径**：同一图片被两条 memo 引用 = 两份磁盘 + 同步两份。
3. **session 维度缺失**：连续 30 分钟内的多条 memo 应该被识别为同一会话，便于 Agent 按 session 检索。
4. **wikilink 没显式声明**：导出虽用 `![[…]]`，但 schema 没说明这是 Obsidian 兼容承诺。
5. **AI 抽取产物没去处**：`vault/entities/`、`vault/concepts/`、`vault/sessions/` 都不存在；编译产物现在塞在编译日报内。

## 2. 决策：Front-matter v2 三层

```yaml
---
# Layer 1 — semantic (给人 + 导出)
title: 京都的某个雨天          # 可选，AI 在编译时回填
tags: [travel, japan, kyoto]

# Layer 2 — episodic (给 Agent 的"会话/事件"维度)
id: 0192-aa…                  # UUID v7 时序友好；旧 UUID v4 继续兼容
type: text|voice|photo|location|mixed
created: 2026-06-17T14:32:18+09:00
session_id: 2026-06-17-001    # 同一连续会话内多 memo 共享
pinned_at: null
location: { name, lat, lng }
weather: 雨, 18°C, 京都
device: iPhone 17 Pro

# Layer 3 — provenance (给 Agent 判断信度)
provenance:
  kind: human|extracted|inferred|ambiguous   # 引用 [10]
  source: user|whisper-1|qwen3.5-plus|apple-nl
  extracted_at: 2026-06-17T02:00:00+09:00    # AI 抽取时间戳；user 输入时省略
  confidence: 0.92                            # 0.0–1.0；user=1.0

# Layer 4 — attachments（CAS 引用，见 §4）
attachments:
  - cid: sha256:abcdef…
    kind: photo|audio
    duration: 12.4              # audio only
    transcript: …               # audio only
    transcription_status: pending|done|failed
    exif: { aperture, shutter, iso, focal_length, gps, captured_at }  # photo only

# 旧字段向后兼容（v1 → v2 迁移期保留读取）
mood: 平静
entity_mentions: [京都, 雨, 哲学之道]
---

正文 Markdown，带 [[wikilink]] 双向链接（Obsidian 兼容）。
```

## 3. vault 目录结构

```
vault/
  raw/                    # 信源，唯一可信
    YYYY-MM-DD.md         # 一天一文件，多 memo 用 \n\n---\n\n 分隔
    assets/
      sha256/ab/cdef…m4a  # CAS 内容寻址（见 §4）

  # 以下三个目录均为 AI 编译产物，可一键全删重建
  entities/{slug}.md
  concepts/{slug}.md
  sessions/{date}-{n}.md

  # 索引层，可丢弃（ADR-0002 §3.4 契约）
  _agent/
    vectors.sqlite        # SQLiteVec
    sync/
      log.sqlite          # CRDT 增量 log（ADR-0001）
```

`vault/entities/` 等编译产物的 front-matter **必须**带 `provenance.kind: extracted` + `source` + `extracted_at`，否则同步层会拒收。

## 4. 附件 CAS 化

### 4.1 路径策略

- 原始：`vault/raw/assets/IMG_1234.jpg`
- v2：`vault/raw/assets/sha256/ab/cdef…/IMG_1234.jpg`（外层目录是 SHA-256 hex 前 2 字节，避免单目录 inode 爆炸）
- front-matter 引用：`cid: sha256:abcdef…`，**保留原文件名作为 metadata** 便于 Obsidian/Finder 可读。

### 4.2 去重

- 写入时：先算 SHA-256 → 查 CAS 目录 → 已存在 = 跳过物理拷贝，只写引用。
- 删除时：reference counting 由 `AttachmentCAS.swift` 维护（lazy GC，启动时扫所有 `cid:` 引用）。

### 4.3 同步

- 上传：AES-256-GCM 加密整文件 → Supabase Storage object（key = `${vault_id}/${sha256}`，IV = first 12B of SHA-256，保证可幂等）。
- 下载：另一端见 `cid:` 不存在本地 → 拉密文 → 解密 → 落到本地 CAS。

## 5. 向后兼容与迁移

- `Memo.swift` 的 YAML 解析器对 v1 字段（无 `provenance`、`session_id`）**保持读取兼容**，在内存中补默认值：`provenance.kind = human`、`source = user`、`session_id = nil`。
- 提供 `scripts/migrate_frontmatter_v2.py`：
  1. 扫描 `vault/raw/*.md`
  2. 给每条 memo 补 v2 字段（`provenance.kind = human` if 没有 `attachments[].transcript`，否则按 attachment 推断）
  3. **dry-run 模式 + diff 输出**给用户确认
  4. 写入是原子操作（rename），失败可回滚
- 提供 `scripts/migrate_assets_cas.py`：把现有 `assets/*.{jpg,m4a}` 重定位到 `assets/sha256/*/*`，更新所有引用。

## 6. Obsidian 兼容承诺

- 写入侧默认 `[[wikilink]]` 语法（已落地于 `MarkdownExportService.swift`）。
- 不引入 Logseq 块引用 `((blockid))`（语义偏离过大）。
- `vault/` 目录可被 Obsidian 直接打开为 vault，**无需 `.obsidian/` 配置**（避免污染 git）。
- front-matter v2 的额外字段 Obsidian 不识别会忽略，不影响阅读。

## 7. 落地分阶段

| 阶段 | 内容 | 依赖 |
|---|---|---|
| Phase 0 | 本 ADR | — |
| Phase 1 | `Memo.swift` v2 字段 + 向后兼容解析 | — |
| Phase 2 | `migrate_frontmatter_v2.py` 迁移脚本 + dry-run UI | Phase 1 |
| Phase 3 | `AttachmentCAS.swift` + `migrate_assets_cas.py` | Phase 1 |
| Phase 4 | `MarkdownExportService.swift` 走 v2 字段 | Phase 1 |
| Phase 5 | `web/lib/markdown/parser.ts` v2 兼容 | Phase 1 |
| Phase 6 | `vault/entities/`、`vault/concepts/`、`vault/sessions/` 目录创建 + 编译产物写入 | ADR-0002 Phase 3 |

## 8. 风险

| 风险 | 缓解 |
|---|---|
| v2 字段太多 = front-matter 体积膨胀 | 大部分字段可选；`provenance` 仅 AI 产物必填；附件 `exif` 已在 v1 落到附件级，不重复 |
| 用户改了 front-matter 破坏 v2 schema | 解析器宽容失败 → fallback 到 raw body 显示；不丢数据 |
| 迁移脚本误删 | 强制 dry-run + atomic rename + 自动备份 vault tarball |
| 编译产物目录 `entities/` 被用户手改 | 写明 `provenance.kind=extracted`；同步层在见到 user mutation 时降级为 `ambiguous` 而非覆盖 |

**退路**：若 v2 字段过于复杂，最小可行集 = 只加 `provenance` 字段，其他 v1 全保留。

## 9. 引用

- [10] [r0b0tlab/llm-wiki obsidian hermes](https://github.com/r0b0tlab/llm-wiki_obsidian_hermes_r0b0tlabbra1n) — agent vault 顶层目录（vote 2-1）
- [11] 同上 — "Indexes are disposable"（vote 2-0, 1 abstain）

> 推翻（参考报告 §1.4 末段）：obsidian-wiki 的"暂存 + manifest 增量"路线在 deep-research workflow 里 4 条 claim 均 abstain，未采纳。
