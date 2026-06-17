# ADR-0001 · 同步架构与 E2EE 套件

- **状态**：Proposed
- **日期**：2026-06-17
- **关联**：`docs/research-2026-06-storage-and-capture.md` 第 2 节、第 9 节引用 [1]–[8]
- **影响范围**：`DayPage/Services/Sync/`、`web/lib/sync/`、`supabase/migrations/`、未来所有跨端写入路径

---

## 1. 背景

DayPage vault 的存储信源是 `vault/raw/YYYY-MM-DD.md`（YAML front-matter + Markdown + `\n\n---\n\n` 多 memo 分隔），目标用户是数字游民——会在 iPhone、iPad、Mac、Watch、Web 五端之间漂移，弱网与离线是常态。

当前同步层只有 `DayPage/Services/ConflictMerger.swift`，做字符串级三方合并。问题：

1. **字段无感**：写入 `mood`、`pinnedAt` 等结构化字段在另一端被覆盖整段文本时会丢失。
2. **离线累积爆炸**：一周离线 + 上百条 memo 时，三方合并人工成本高。
3. **服务端可读明文**：当前 Supabase Postgres + Realtime 路径假定服务端能看见原文，与"日记"这个内容形态的隐私默认不符。
4. **附件不在 vault 协议内**：媒体文件靠"巧合恰好同步"。

## 2. 选项矩阵

| 方案 | 字段级合并 | 离线优先 | 端到端加密 | 跨平台（Web/Watch） | 复杂度 |
|---|:-:|:-:|:-:|:-:|:-:|
| Git + S3 | ❌ | ✅ | 手动 | 移动端嵌入难 | 中 |
| iCloud Documents | ❌ | ✅ | Apple 托管 | Web/Android = 死路 | 低 |
| Supabase Postgres + Realtime | ❌ | 部分 | ❌ | ✅ | 低（已就绪） |
| **Per-file Y.Doc CRDT + Secsync E2EE relay** | ✅ | ✅ | ✅ | ✅ | **高** |
| Automerge + 自研 relay | ✅ | ✅ | ✅ | ✅ | 高（文本性能不如 Yjs） |
| Loro | ✅ | ✅ | ✅ | iOS 绑定不成熟 | 高 |

## 3. 决策

**采用「Per-file Y.Doc CRDT + Secsync 风格 E2EE relay over Supabase」**，分阶段实施。

### 3.1 存储层

- 每个 `vault/raw/*.md` 文件对应一个独立 `Y.Doc`（来自 [obsidian-local-sync](https://github.com/elcomtik/obsidian-local-sync) 验证模式，引用 [1]）。
- Mutation 增量以 **base64 编码 Yjs update** 落到 `vault/_agent/sync/log.sqlite`，不重传整文件（引用 [2]）。
- 文件路径就是 doc 标识，幂等可回放。

### 3.2 同步协议

- 采用 [Secsync](https://github.com/SerenityNotes/naisho) 风格：**服务端只做加密 CRDT 消息 relay，不解密**（引用 [6]）。
- 服务端记录 per-doc 递增 seq，客户端通过 `lastSeq` 增量拉取。
- Secsync 协议同时支持 Yjs 与 Automerge 后端，给我们将来切换 CRDT 库留出口（引用 [7]）。

### 3.3 端到端加密套件（对标 Obsidian Sync）

- Cipher：**AES-256-GCM**，IV 12B，auth tag 16B（引用 [4]）。
- KDF：**scrypt(N=32768, r=8, p=1)** + per-vault 随机 salt；v3 再叠 **HKDF-SHA-256** 派生子密钥（引用 [5]）。
- **使用 Apple CryptoKit**（iOS 13+ 原生），不引入 libsodium / NaCl。CryptoKit 原生支持 AES-GCM 与 HKDF；scrypt 暂用纯 Swift 实现（如 `swift-crypto` 旁路）或现成 SPM 包，待评估。
- **device bootstrap**：24 字 owner mnemonic（BIP-39 词表），用户首次开 vault 时显示一次；首次添加新设备走 mnemonic verify（引用 [3]）。

### 3.4 媒体附件 — 独立 CAS 通道

Secsync 协议**显式不覆盖附件**（引用 [8]）。附件单走一条 pipeline：

- 本地路径：`vault/raw/assets/sha256/ab/cdef…m4a`。
- front-matter 引用切换为 `cid: sha256:abcdef…`。
- 上传：AES-GCM 加密整文件 → Supabase Storage（per-vault key + per-file IV）。
- 同步：只同步 cid，下载用 cid 还原本地相对路径。
- 见 ADR-0003 第 4 节。

### 3.5 Supabase 角色重定位

| 旧角色 | 新角色 |
|---|---|
| 业务数据库（明文 memo） | 加密 CRDT relay（密文 blob + seq） |
| 业务对象存储（明文媒体） | 加密对象存储（AES-GCM 密文） |
| Auth | Auth（不变） |
| Realtime（明文广播） | Realtime（仅 `new-update` 通知，payload 密文） |

服务端在任何时刻都看不到 memo 内容、附件原文、用户位置。

## 4. 落地分阶段

| 阶段 | 内容 | 依赖 |
|---|---|---|
| Phase 0 | 本 ADR + ADR-0003（schema v2） | — |
| Phase 1 | `YDocStore.swift` 包装每文件 Y.Doc + 本地增量 log | ADR-0003 |
| Phase 2 | `VaultCrypto.swift`（CryptoKit AES-GCM + scrypt）+ mnemonic 流程 | — |
| Phase 3 | `SecsyncRelay.swift` + `supabase/migrations/2026xx_secsync_relay.sql` | Phase 1/2 |
| Phase 4 | `AttachmentCAS.swift` + 旧 vault 一键迁移脚本 | Phase 2 |
| Phase 5 | `web/lib/sync/secsync.ts` Web 端 | Phase 3 |

`ConflictMerger.swift` 在 Phase 1 落地后保留只读模式，仅用于旧 vault 一次性迁移；之后下线。

## 5. 风险与退路

| 风险 | 缓解 |
|---|---|
| Yjs 没有官方 Swift 绑定 | 现有 `yswift` 不算成熟；先做 PoC，必要时走 Y.js bridge via JSContext，或评估 Automerge Swift（Automerge 有官方 swift 包，但文本性能略差） |
| Secsync 协议官方不覆盖附件 | 本 ADR 自研 CAS 层；需独立安全审计（计入 Phase 4 验收） |
| Owner mnemonic 丢失 = 数据永久丢失 | 在 UI 强提示用户写下助记词；可选加云端"加密助记词备份"（密码派生加密） |
| scrypt N=32768 在低端设备首次解锁慢（~1s） | 接受；只在首次解锁与设备 bootstrap 时触发；之后 in-memory cache session key |
| 与 ConflictMerger 并存期可能出 bug | Phase 1 默认禁用 YDocStore，Feature flag 灰度开启 |

**退路**：若 CRDT + secsync 落地遇到不可接受的复杂度，**退回 Supabase Postgres + 字段加密**（client 加密单字段，服务端只见密文），保留 E2EE 本质但放弃字段级合并能力。

## 6. 引用

- [1] [obsidian-local-sync](https://github.com/elcomtik/obsidian-local-sync) — Per-file Y.Doc 模式（vote 3-0）
- [2] 同上 — base64 增量 log（vote 3-0）
- [3] 同上 — E2EE 在 CRDT 消息层 + owner mnemonic（vote 3-0）
- [4] [Obsidian Sync encryption](https://obsidian.md/blog/verify-obsidian-sync-encryption/) — AES-256-GCM（vote 3-0）
- [5] 同上 — scrypt + HKDF-SHA-256（vote 3-0）
- [6] [Secsync](https://github.com/SerenityNotes/naisho) — E2EE CRDT relay（vote 3-0）
- [7] 同上 — Yjs + Automerge 双 backend（vote 3-0）
- [8] 同上 — 协议不覆盖附件（vote 3-0）
