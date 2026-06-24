# iOS → Web Memo 同步设计方案

> 状态：草案 / 待评审
> 作者：Claude Code
> 日期：2026-06-24
> 关联分支：（开 issue 后创建）

## 1. 背景与问题

DayPage 有两个客户端：

- **iOS App**：本地真相是 `vault/raw/YYYY-MM-DD.md`（YAML front-matter + Markdown），用 Supabase 做账号登录。
- **Web（Next.js）**：本地真相是 PostgreSQL（`memos` 表 + Drizzle），用 NextAuth 做账号登录。

用户诉求：**「App 发送的内容能在 web 端同步」**。

### 现状（已核实，非推测）

| 层 | 状态 |
|---|---|
| Web 存储 | ✅ PostgreSQL + Drizzle，`/api/memos` CRUD + `/api/memos/bulk`（专为 iOS 设计的 last-write-wins upsert）已存在且完整 |
| Web 鉴权基建 | ✅ `api_keys` 表 + `authenticateApiKey()` + `hasScope()` + Settings 生成 UI（`/api/keys`）；`/api/ingest`、`/api/v1/*` 已用 `Authorization: Bearer <key>` 范式 |
| iOS 写入 | ✅ `RawStorage.append()` 写 vault，并 `SyncQueueService.enqueue(memoID)` |
| iOS 同步队列 | ✅ `SyncQueueService`（元数据队列）+ `SyncQueueObserver`（监听 flush）已就绪 |
| iOS 真实上传 | ❌ **完全断掉**——只有 `NoopRemoteUploader`（sleep 300ms 假上传），从不发真实网络请求 |

**结论：** 不是「从零实现存储」，而是**接通 iOS 端那条空转的同步链路**——实现一个真实的 `RemoteUploader`，把 vault 里的 memo POST 到 web 已经准备好的 `/api/memos/bulk`。

## 2. 鉴权方案：API Key Bearer（模仿 flomo）

### 决策

不桥接 Supabase ↔ NextAuth（两套独立 auth，桥接成本高）。改用 **API Key Bearer**，与 flomo 的同步 token 模式一致：

> flomo 给每个用户一个专属 API 地址 `https://flomoapp.com/iwh/<id>/<token>/`，客户端用 token 往里发内容。

DayPage 复刻：用户在 **web Settings → API Keys** 生成一个 `write` scope 的 key，填进 **iOS Settings → 同步**。iOS 上传时带 `Authorization: Bearer <key>`。

### 为什么这是最优解

1. **零新增基建**：web 已有 `authenticateApiKey()`、`api_keys` 表、生成 UI、`/api/keys` 路由。
2. **身份自动绑定**：`api_keys.user_id → users.id`。iOS 用某 key，memo 就落到那个 web 用户，**无需 email 桥接**。
3. **已验证范式**：`/api/ingest`（浏览器剪藏）已是同款 Bearer 鉴权 + CORS。
4. **安全边界清晰**：key 可吊销、有 scope、记 `last_used_at`、可设 `expires_at`。

### 改动点

`/api/memos/bulk/route.ts`：在现有 NextAuth session 之外，**额外**接受 API Key Bearer。

```ts
// 伪代码
async function resolveAuthUserId(req): Promise<{ userId: string } | { error: Response }> {
  // 1) 优先 API Key（iOS / 第三方）
  const apiAuth = await authenticateApiKey(req);
  if (apiAuth) {
    if (!hasScope(apiAuth, "write")) return { error: forbidden("write scope required") };
    return { userId: apiAuth.userId };
  }
  // 2) 回退 NextAuth session（web 自身调用）
  const session = await auth();
  if (session?.user?.email) {
    const userId = await resolveUserId(session.user.email);
    if (userId) return { userId };
  }
  return { error: unauthorized() };
}
```

保留 session 路径不动，只「补」API Key 分支——对 web 现有行为零影响。

## 3. 字段映射：iOS Memo → Bulk JSON

Web `BulkMemoItemSchema`（`web/src/lib/schemas/memo.ts`）要求：`id`(UUID)、`body`(非空)、可选 `type/created_at/updated_at/location/weather/device/origin/ingest_mode/vault_path/idempotency_key/mood/attachments`。

| iOS `Memo` 字段 | Bulk JSON 字段 | 映射规则 |
|---|---|---|
| `id: UUID` | `id` | `uuidString.lowercased()` |
| `type: MemoType` | `type` | `voice→voice`、`photo→photo`、`text→text`、`location→text`、`mixed→text`（web 无 location/mixed 枚举） |
| `body: String` | `body` | 直接；**若为空**（纯语音/照片）→ 填占位（如 transcript 或 `"(无文字)"`），因 schema 要求 `min(1)` |
| `created: Date` | `created_at` | ISO8601（含毫秒，UTC） |
| `pinnedAt`/修改时间 | `updated_at` | 取 `pinnedAt ?? created` 的 ISO8601；用于 LWW 比较 |
| `location: Location?` | `location` | `{lat, lng, address: name}`（web `.passthrough()` 容忍多余字段） |
| `weather: String?` | `weather` | **包装**为 `{condition: weatherString}`（iOS 是字符串，web schema 是 object） |
| `device: String?` | `device` | 直接 |
| `mood: String?` | `mood` | 直接 |
| — | `origin` | 固定 `"ios"` |
| `vault/raw/YYYY-MM-DD.md` | `vault_path` | memo 所在文件相对路径，便于追溯 |
| `id` | `idempotency_key` | = memoID，防重复 upsert |
| `attachments[]` | `attachments[]` | 见下，**只传元数据** |

### 附件（第一期：只传元数据）

不传文件字节。`attachments[]` 映射：

| iOS `Attachment` | Bulk attachment | 规则 |
|---|---|---|
| `kind` | `kind` | `audio/photo/file`（已对齐） |
| `file`（相对路径） | `storage_key` | 直接传路径字符串（web 仅存引用，第一期不解析文件） |
| `duration` | `duration_sec` | 直接 |
| `transcript`（音频转录 / 照片 EXIF 串） | `transcript` 或 `exif` | 音频→`transcript`；照片 EXIF→可放 `exif`/`ocr_text` |

> 文件字节上传（multipart → `/api/upload`，让 web 能播放音频/看原图）作为**后续 issue**。

## 4. 上传流程

```
SyncQueueObserver.flush()           （已存在，监听 .syncQueueFlushRequested）
  └─ for memoID in pendingMemoIDs:
       uploader.upload(memoID:)      （RemoteUploader 协议，已存在注入点）
                ↓  ← 本方案实现 BulkSyncUploader
   1. memoID → 扫 vault/raw/*.md 找到对应 Memo（复用 estimateMemoSize 的扫描思路）
   2. Memo → bulk JSON（§3 映射）
   3. POST {baseURL}/api/memos/bulk
      Authorization: Bearer <api key>
      Body: { memos: [item] }
   4. 解析响应 { accepted, skipped }
       - accepted 含本 memoID → 返回字节数（成功）
       - skipped → 抛错（让 observer 中断本轮）
```

- **批量**：当前 observer 逐条调 `upload(memoID:)`。第一期保持逐条（每次 `memos:[单条]`）；后续可改批量（schema 支持 ≤100 条/请求）。
- **复用** `HTTPTransport`（`HTTPTransports.shared`），便于测试注入假响应。

## 5. 冲突与幂等

- **服务端**：bulk 已是 **last-write-wins by `updated_at`**（`onConflictDoUpdate` + `setWhere user_id`）。同一 memoID 重复上传安全。
- **客户端**：`SyncQueueService` 用 Set 去重；上传成功才 `markSynced`，失败保留待重试（网络恢复/手动触发自动重发）。
- **幂等键**：`idempotency_key = memoID`。

## 6. 错误处理

| 场景 | 行为 |
|---|---|
| 未配置 baseURL / key | uploader 降级为 noop（不报错，不入队失败）；Settings 提示「未配置同步」 |
| 401（key 无效/过期） | 中断本轮 + breadcrumb；Settings 标记 key 失效，提示重新生成 |
| 403（无 write scope） | 同上，提示 key 权限不足 |
| 429（限流） | 读 `Retry-After`，延迟下轮 flush |
| 网络错误 | `SyncQueueObserver` 现有逻辑：breadcrumb + break，下次 flush 重试 |
| 5xx | 同网络错误，保留队列 |
| memoID 在 vault 找不到 | 跳过并 `markSynced`（已删除的 memo 不该卡住队列）+ breadcrumb |

## 7. iOS 配置 UI

Settings 新增「同步」section：

- **Web 地址**（baseURL）：默认空；dogfood 可填 `http://<mac-ip>:3000`，生产填正式域名。
- **API Key**：粘贴 web 生成的 key，存 **Keychain**（不存 UserDefaults，避免 PII/凭证泄露）。
- **状态**：显示上次同步时间 / 待同步条数（复用 `SyncQueueService.pendingCount`）/ 失败原因。
- **手动同步**按钮：触发 `flushIfOnline()`。

配置读取：新建 `SyncConfig`（Keychain 封装），`BulkSyncUploader` 启动时读；为空 → `SyncQueueObserver.setUploader(NoopRemoteUploader())` 保持空转。

## 8. 安全考量

- API key 走 Keychain，不落 UserDefaults / 日志 / Sentry。
- baseURL 仅允许 `https://`（dogfood 例外允许局域网 `http://`，用 `#if DEBUG` 或显式开关守护）。
- bulk 端点对 API key 路径同样跑 `checkMutationRateLimit`（按 key/user 维度）。
- key 泄露可在 web Settings 一键吊销（已有 DELETE `/api/keys/:id`）。

## 9. 任务拆解

1. **web**：`/api/memos/bulk` 接受 API Key Bearer（复用 `authenticateApiKey` + `hasScope("write")`）+ 测试。
2. **iOS**：`SyncConfig`（Keychain）+ Settings 同步 section。
3. **iOS**：`BulkSyncUploader: RemoteUploader`（vault 查找 + 映射 + POST）+ 注入。
4. **iOS**：`Memo → BulkItem` 映射单元测试（Swift Testing）。
5. **联调**：本地 web（dev login → 生成 write key）↔ iOS 模拟器写 memo → 验证 `/today` 可见。

## 10. 非目标（后续 issue）

- web → iOS 反向同步（`GET /api/memos?since=` 拉取并写回 vault）。
- 附件文件字节上传（multipart → `/api/upload`）。
- 多设备冲突的 body 级合并（当前 LWW 足够）。
