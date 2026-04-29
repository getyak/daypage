# Design: iCloud Drive 同步方案

**Issue**: #64  
**状态**: 设计评审中  
**里程碑**: v3.1  
**决策日期**: 2026-04-17  
**作者**: @cubxxw + Claude  

---

## 0. 执行摘要

DayPage 当前所有数据存放在 App Sandbox 的 `Documents/vault/`，仅本地可用。本文档设计一套**零账号、零服务器、本地优先**的多设备同步方案，核心技术路线：

- **主路径**：iCloud Drive Ubiquity Container 同步整个 `vault/`
- **抽象层**：引入 `VaultLocator` 协议，将存储路径与业务代码解耦
- **扩展点**：`SyncBackend` 协议预留 Supabase / Google Drive 后端，供 v4+ 接入
- **降级**：用户未开启 iCloud → 无感知回退本地模式，App 不 crash

---

## 1. 背景与决策

### 1.1 现状

```
Documents/vault/
├── raw/
│   ├── assets/              # 音频 m4a + 照片 jpg，每条附件 1-10 MB
│   └── YYYY-MM-DD.md        # 每日 raw memo 汇总文件
├── wiki/
│   ├── daily/YYYY-MM-DD.md  # AI 编译后的 Daily Page
│   ├── places/ people/ themes/  # 实体页面
│   ├── index.md             # 实体索引（EntityPageService 维护）
│   ├── hot.md               # AI 短期记忆（每次编译覆盖写）
│   └── log.md               # 编译日志（append-only）
└── drafts/
    ├── visits.json          # 被动位置访问草稿
    └── voice_queue.json     # 待转录语音队列
```

**单一入口**：`VaultInitializer.vaultURL` — 静态计算属性，返回 `Documents/vault/`。经代码扫描共有 **37 处引用**（分布在 Services / Features / Storage 三层），但全部通过这一属性获取根路径。

**迁移成本低**：改变 `vaultURL` 的实现即可改变所有 37 处的数据来源，无需逐一修改调用点。

### 1.2 方案决策矩阵

| 维度 | 方向 A: iCloud Drive ✅ | 方向 B: CloudKit | 方向 C: 自建服务器 |
|---|---|---|---|
| 开发成本 | 低（1 entitlement + 1 URL 变更）| 高（CKRecord 模型重建）| 极高（后端 + 运维）|
| 运维成本 | 零（Apple 托管）| 零 | 高 |
| 用户身份 | Apple ID（隐式）| Apple ID | 需注册账号 |
| 离线能力 | 完整（本地文件始终可用）| 部分 | 部分 |
| 文件可搬运性 | ✅ 标准 Markdown，可手动打开 | ❌ 专有格式 | ❌ 依赖服务器 |
| 跨平台 | 仅 Apple 生态 | 仅 Apple 生态 | 全平台 |
| Google Drive | ❌ 本期不支持 | ❌ | ✅ 可接入 |

**决策**：方向 A（iCloud Drive），理由：符合"vault 是可搬运 Markdown"核心价值观，零运维，低摩擦。

### 1.3 评论区需求补充（@cubxxw）

1. **Google Drive / 外部存储扩展**：本期不实施，但 `SyncBackend` 协议预留接入点；外部工具（MCP / AI Agent）可通过 Google Drive API 读取同步后的 Markdown 数据
2. **可配置定时增量同步**：iCloud 系统托管不支持手动控制，本期 iCloud 路径依赖系统自动同步；定时增量同步计划在 Supabase 后端（v4）实现
3. **与登录模块的关系**：iCloud 同步无需 Auth（Apple ID 即身份）；Auth 模块（`prd-auth-login.md`）定义的 Supabase 身份系统作为独立 SyncBackend，与 iCloud 路径解耦共存

---

## 2. 架构设计

### 2.1 VaultLocator 抽象层

```swift
// MARK: - VaultLocator Protocol (新增)
protocol VaultLocator {
    /// 当前有效的 vault 根 URL（本地 or Ubiquity Container）
    var vaultURL: URL { get }
    /// 是否正在使用 iCloud 存储
    var isUsingiCloud: Bool { get }
}

// MARK: - LocalVaultLocator（当前实现，改造为结构体）
struct LocalVaultLocator: VaultLocator {
    var vaultURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("vault", isDirectory: true)
    }
    var isUsingiCloud: Bool { false }
}

// MARK: - iCloudVaultLocator（新增，v3.1）
struct iCloudVaultLocator: VaultLocator {
    // Container ID: iCloud.com.daypage.app
    private let containerID = "iCloud.com.daypage.app"
    
    var vaultURL: URL? {
        FileManager.default
            .url(forUbiquityContainerIdentifier: containerID)?
            .appendingPathComponent("Documents/vault", isDirectory: true)
    }
    
    var isUsingiCloud: Bool {
        FileManager.default.url(forUbiquityContainerIdentifier: containerID) != nil
    }
}

// MARK: - VaultInitializer（改造）
enum VaultInitializer {
    /// 运行时自动选择 Locator。
    /// 优先 iCloud；用户未开启时 fallback 本地。
    static var shared: VaultLocator = {
        let icloud = iCloudVaultLocator()
        return icloud.isUsingiCloud ? icloud : LocalVaultLocator()
    }()
    
    // 保留测试用 override
    static var testOverrideURL: URL?
    
    static var vaultURL: URL {
        if let override = testOverrideURL { return override }
        return shared.vaultURL ?? LocalVaultLocator().vaultURL
    }
}
```

**影响范围**：37 处调用点全部通过 `VaultInitializer.vaultURL` 获取，无需逐一修改。

### 2.2 SyncBackend 扩展协议（未来扩展预留）

```swift
// 未来扩展点 — 本期不实现，只定义接口
protocol SyncBackend {
    var displayName: String { get }          // "iCloud Drive" / "Supabase" / "Google Drive"
    var status: SyncStatus { get }
    func sync() async throws
    func resolveConflict(local: URL, remote: URL) async throws -> URL
}

enum SyncStatus {
    case notConfigured
    case connected(pendingFiles: Int)
    case syncing(progress: Double)
    case error(message: String)
}
```

### 2.3 文件协调层（NSFileCoordinator）

iCloud 环境下，多设备可能同时读写同一文件。需要在原子写入之上增加文件协调：

```swift
// RawStorage.atomicWrite 改造
private func coordinatedAtomicWrite(string: String, to url: URL) throws {
    let coordinator = NSFileCoordinator()
    var coordinationError: NSError?
    var writeError: Error?
    
    coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writingURL in
        do {
            // 现有原子写入逻辑保持不变
            let tempURL = writingURL.deletingLastPathComponent()
                .appendingPathComponent(".\(writingURL.lastPathComponent).tmp")
            try string.write(to: tempURL, atomically: false, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(writingURL, withItemAt: tempURL)
        } catch {
            writeError = error
        }
    }
    
    if let error = coordinationError ?? writeError { throw error }
}
```

**只需改造 `RawStorage.atomicWrite` 一处**；其他文件写入路径评估后逐步接入。

---

## 3. 路径迁移方案

### 3.1 iCloud Container 配置

**Entitlements** (`DayPage.entitlements`)：
```xml
<key>com.apple.developer.icloud-container-identifiers</key>
<array>
    <string>iCloud.com.daypage.app</string>
</array>
<key>com.apple.developer.ubiquity-container-identifiers</key>
<array>
    <string>iCloud.$(TeamIdentifierPrefix)com.daypage.app</string>
</array>
<key>com.apple.developer.icloud-services</key>
<array>
    <string>CloudDocuments</string>
</array>
```

**物理路径变更**：
```
旧: ~/Documents/vault/
新: ~/Library/Mobile Documents/iCloud~com~daypage~app/Documents/vault/
```

**App Groups 不需要**：iCloud Drive 不依赖 App Group，Ubiquity Container 由 Apple 管理。

### 3.2 老用户迁移流程（单向，不可逆）

迁移在用户首次开启 iCloud 时触发（在 `VaultMigrationService` 中实现）：

```
[检测到 iCloud 可用] 
    │
    ▼
[读取本地 vault 文件列表]
    │
    ▼
[创建 iCloud vault 目录结构]
    │
    ▼
[逐文件复制（保留修改时间）]
    │          ├── 成功 → 记录到 migration.log
    │          └── 失败 → 标记为 failed，继续其他文件
    │
    ▼
[校验：比较文件数量 + 关键文件 SHA-256]
    │          ├── 通过 → 更新 UserDefaults: vaultLocation = .iCloud
    │          └── 不通过 → 报错，保留本地 vault，不修改 UserDefaults
    │
    ▼
[本地 vault 保留 30 天作兜底]
（30 天后 Settings 提示"清理本地备份"）
```

**回滚机制**：Settings > 数据 > "切换到本地存储"按钮（仅在 30 天窗口内可用）。

```swift
enum VaultLocation: String {
    case local = "local"
    case iCloud = "iCloud"
}

extension AppSettings {
    var vaultLocation: VaultLocation {
        get { VaultLocation(rawValue: UserDefaults.standard.string(forKey: "vaultLocation") ?? "local") ?? .local }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "vaultLocation") }
    }
}
```

---

## 4. 冲突处理策略

### 4.1 冲突场景分析

| 文件类型 | 冲突概率 | 冲突方式 | 严重程度 |
|---|---|---|---|
| `raw/YYYY-MM-DD.md` | 中（两设备同日记录）| iCloud 产生 conflict copy | 高（可能丢 memo）|
| `wiki/daily/YYYY-MM-DD.md` | 低（只有编译触发写入）| conflict copy | 中（可重编译）|
| `wiki/hot.md` | 高（每次编译都覆写）| conflict copy | 低（可丢弃旧版）|
| `wiki/log.md` | 高（append-only）| conflict copy | 低（合并即可）|
| `wiki/index.md` / 实体页 | 低 | conflict copy | 中 |
| `drafts/voice_queue.json` | 低 | conflict copy | 中 |

### 4.2 Raw Memo 冲突合并（最关键）

iCloud 产生 conflict copy 文件名格式：`2026-04-17 (Conflict from iPhone 14 Pro).md`

**合并算法**（`ConflictMerger.mergeRawMemos`）：

```swift
func mergeRawMemos(original: [Memo], conflict: [Memo]) -> [Memo] {
    var seen = Set<UUID>()
    var merged: [Memo] = []
    
    // 合并两个列表，按 UUID 去重，按 created 时间排序
    for memo in (original + conflict).sorted(by: { $0.created < $1.created }) {
        guard seen.insert(memo.id).inserted else { continue }
        merged.append(memo)
    }
    return merged
}
```

**执行流程**：
1. `NSMetadataQuery` 检测到 conflict copy 出现
2. `ConflictMerger` 解析两个文件的 memo 列表
3. UUID 去重 + 时间排序 → 合并结果写入主文件
4. 删除 conflict copy
5. 发送 Banner 通知用户

**为什么 UUID 去重有效**：每条 memo 在创建时生成全局唯一 `id`（UUID v4），即使两台设备同时录入相同文字，`id` 不同 → 保留两条（不丢失）。

### 4.3 其他文件冲突策略

| 文件 | 策略 | 理由 |
|---|---|---|
| `wiki/hot.md` | 保留较新的（mod time 最大）| 短期记忆，旧版无价值 |
| `wiki/log.md` | append 合并（去重 timestamp 行）| 日志天然可合并 |
| `wiki/daily/*.md` | 保留较新的 + 标记 stale → 重编译 | 编译幂等，可重新生成 |
| `wiki/index.md` | 保留较新的 + EntityPageService 重建 | 索引可重建 |
| `drafts/voice_queue.json` | 合并 entries（按 UUID 去重）| 队列不丢条目 |
| `drafts/visits.json` | 合并 entries（按 UUID 去重）| 同上 |

### 4.4 用户可见 Banner

```swift
// 合并完成后发送通知
NotificationCenter.default.post(
    name: .vaultConflictResolved,
    object: ConflictResolutionInfo(
        date: conflictDate,
        mergedMemoCount: mergedCount,
        sourceDevice: conflictDeviceName
    )
)

// TodayView / ArchiveView 监听并显示 Banner
// "2026-04-17 在另一台设备上有 3 条记录，已合并"
```

---

## 5. 状态可见性

### 5.1 NSMetadataQuery 监听

```swift
@MainActor
final class iCloudSyncMonitor: ObservableObject {
    @Published var status: SyncStatus = .notConfigured
    @Published var pendingUploadCount: Int = 0
    @Published var pendingDownloadCount: Int = 0
    
    private var metadataQuery: NSMetadataQuery?
    
    func startMonitoring(vaultURL: URL) {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K BEGINSWITH %@", 
                                       NSMetadataItemPathKey, vaultURL.path)
        
        NotificationCenter.default.addObserver(
            self, selector: #selector(queryDidUpdate),
            name: .NSMetadataQueryDidUpdate, object: query
        )
        query.start()
        self.metadataQuery = query
    }
    
    @objc private func queryDidUpdate() {
        // 统计上传中/下载中文件数量
        var uploading = 0, downloading = 0
        for item in metadataQuery?.results as? [NSMetadataItem] ?? [] {
            if item.value(forAttribute: NSMetadataUbiquitousItemIsUploadingKey) as? Bool == true {
                uploading += 1
            }
            if item.value(forAttribute: NSMetadataUbiquitousItemIsDownloadingKey) as? Bool == true {
                downloading += 1
            }
        }
        pendingUploadCount = uploading
        pendingDownloadCount = downloading
        status = (uploading + downloading > 0) ? .syncing(progress: 0.5) : .connected(pendingFiles: 0)
    }
}
```

### 5.2 Settings 面板（iCloud 状态区块）

在 `SettingsView.swift` 的 **数据** 区块中新增 **"iCloud 同步"** 子区块：

```
┌─ iCloud 同步 ────────────────────────────────────┐
│  ● 已连接                    iCloud Drive        │
│  上次同步: 今天 14:32                             │
│  ∙ 3 个文件待上传…                               │
│                                                  │
│  [切换到本地存储] ← 30天窗口内可见               │
└──────────────────────────────────────────────────┘
```

状态枚举：
- `未开启` → 显示引导卡片（见 5.3）
- `已连接` → 绿色圆点 + 上次同步时间
- `同步中` → 旋转图标 + "N 个文件待传"
- `错误` → 红色 + 错误描述 + "查看详情"

### 5.3 首次开启引导卡片

未开启 iCloud Drive 的用户（检测到 `iCloudVaultLocator.vaultURL == nil`）在 `SettingsView` 顶部显示引导卡片：

```
┌─────────────────────────────────────────────────┐
│  ☁️  开启多设备同步                              │
│  在 iPhone 与 iPad 之间同步你的日记             │
│                                                 │
│  [前往 iOS 设置开启 iCloud Drive]               │
│                                                 │
│  需要：设置 > Apple ID > iCloud > iCloud Drive  │
└─────────────────────────────────────────────────┘
```

点击按钮：`UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)`

---

## 6. 降级路径（iCloud 未开启）

### 6.1 运行时判断

```swift
// VaultInitializer.shared 在 App 启动时初始化一次
// 如果 iCloud 不可用，返回 LocalVaultLocator
// 后续 37 处 vaultURL 调用透明获得正确路径
```

### 6.2 降级时的 UI 状态

- Settings > iCloud 同步：显示引导卡片（见 5.3）
- TodayView / ArchiveView：正常显示本地数据，无额外提示
- 无 Banner、无 Alert，**App 不 crash**

### 6.3 中途切换（开→关→开）

| 操作 | 结果 |
|---|---|
| 开→关 | App 检测到 `vaultURL` 变为 nil，切换 LocalVaultLocator；本地数据不丢失（iCloud 文件仍在系统缓存中）|
| 关→开 | App 重启时重新检测 iCloud，切换 iCloudVaultLocator；触发冲突检查 |
| 本地有新数据 + 重新开启 | `VaultMigrationService` 执行增量合并（与冲突策略相同）|

---

## 7. 大文件（附件）处理

### 7.1 默认策略：按需下载

iCloud Drive 对大文件默认使用 `evict`（仅保留占位符，按需下载）。

`raw/assets/` 目录下的音频（1-5 MB）和照片（2-10 MB）遵循此策略。

### 7.2 Timeline 滚动时的占位符处理

```swift
// MemoCardView 中检查附件是否已下载
func isAttachmentDownloaded(_ url: URL) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]) else {
        return true // 本地文件，直接可用
    }
    return values.ubiquitousItemDownloadingStatus == .current
}

// 未下载时显示占位符 + 触发下载
func startDownload(_ url: URL) {
    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
}
```

Timeline 滚动时：
- 附件已下载 → 正常渲染图片 / 音频
- 附件未下载 → 灰色占位符 + 旋转加载圆圈 → 触发下载 → 完成后刷新

### 7.3 Settings 可配置"始终保留本地"

```
Settings > iCloud 同步 > 附件策略
  ○ 按需下载（节省设备空间，默认）
  ● 始终保留本地副本（需要更多存储空间）
```

"始终保留本地"实现：在 `VaultInitializer.initializeIfNeeded()` 中对 `raw/assets/` 调用 `NSFileCoordinator` + `URLResourceValues.ubiquitousItemDownloadingStatusKey = .current` 强制下载。

### 7.4 附件不参与 Supabase 同步（设计预留）

参考 Issue #64 Non-Goals：当 Supabase 后端（v4）实现时，`raw/assets/` 目录仅走 iCloud，不上传到 Supabase（避免存储成本）。

---

## 8. 与 Auth 模块的协作关系

### 8.1 身份层解耦

| 场景 | 身份来源 | 存储后端 |
|---|---|---|
| 仅 iCloud（本期）| Apple ID（隐式）| iCloud Drive |
| 登录 + 云备份（v4）| Supabase JWT | Supabase Storage |
| 未来：Google Drive | Google OAuth | Google Drive API |

iCloud 同步**不依赖** `AuthService.session`，独立运行。

### 8.2 Settings 页面整合

现有 Auth PRD（`prd-auth-login.md`）计划的 `AccountSheet` 可升级为"账号 & 同步"统一面板：

```
账号 & 同步
├── Apple ID（iCloud）
│   ├── 状态：已连接 / 未开启 / 同步中
│   └── 上次同步时间
└── Supabase 账号（v4，需登录）
    ├── [登录] → Apple Sign-In / Magic Link
    └── 云备份开关
```

### 8.3 Google Drive 扩展（预留，v4+）

@cubxxw 提到希望外部 AI 工具（MCP / Agent）能读取数据：

**设计思路**：
1. iCloud sync 完成后，vault 内 Markdown 文件对第三方 AI 工具天然可读（标准格式）
2. Google Drive 扩展点：`GoogleDriveVaultLocator` 实现 `VaultLocator`，需单独 Google OAuth 流程
3. MCP 工具可通过 `vault/wiki/index.md` + `vault/wiki/daily/*.md` 获取结构化数据，无需特殊适配

### 8.4 SyncBackend 协议（代码预留）

iCloud 同步由 OS 的 NSUbiquitousContainer 管理，不需要显式 push/pull；但未来的 Supabase 或 Google Drive 后端需要应用层主动上传/下载。为此在 `VaultLocator.swift` 中预留 `SyncBackend` 协议：

```swift
protocol SyncBackend {
    var displayName: String { get }        // Settings 显示名，如 "Supabase"
    var isAvailable: Bool { get }          // 是否已登录、网络可达等
    func upload(fileAt localURL: URL, relativePath: String) async throws
    func download(relativePath: String, to localURL: URL) async throws
    func listRemoteFiles() async throws -> [(relativePath: String, modifiedAt: Date)]
}
```

**与 VaultLocator 的关系**：`VaultLocator` 决定本地写入路径；`SyncBackend` 决定写入后是否需要额外的远端同步操作。两者独立，iCloud 路径只需 `VaultLocator`，Supabase 路径需要 `VaultLocator`（本地缓存）+ `SyncBackend`（远端同步）。

**v4 预计实现**：`SupabaseSyncBackend: SyncBackend`，依赖 `AuthService.session` 中的 JWT，实现增量 diff（基于 `updated_at`）+ `BGTaskScheduler` 定时同步。

### 8.5 数据迁移优先级（单向升级路径）

```
本地存储 (LocalVaultLocator)
    │  升级：用户首次开启 iCloud → VaultMigrationService.migrateToiCloud()
    ▼
iCloud Drive (iCloudVaultLocator)
    │  升级：用户登录 Supabase 并开启云备份 → SupabaseSyncBackend 增量同步
    ▼
Supabase 云备份 (SupabaseSyncBackend)   [v4]
    │  预留：Google Drive OAuth 接入
    ▼
Google Drive (GoogleDriveSyncBackend)   [v4+]
```

**原则**：
- 升级路径**单向**，不允许降级时丢失数据
- 每一步升级都先写本地、再同步远端（本地优先原则不变）
- 降级（关闭 iCloud）→ App 回退本地模式，本地数据完整，不做删除

---

## 9. 测试矩阵

| 场景 | 预期结果 | 测试方法 |
|---|---|---|
| iPhone + iPad 同日 append → 合并 | 所有 memo 保留，按时间排序 | 双设备手动测试 |
| 同一 memo 在两设备编辑后同步 | UUID 去重，两设备最终一致 | 单测：`ConflictMerger.mergeRawMemos` |
| 离线 1 小时 → 联网同步 | iCloud 自动同步，无数据丢失 | 手动：飞行模式测试 |
| 老用户升级（已有本地 vault）| 迁移脚本成功，iCloud vault 完整 | Xcode Simulator 迁移测试 |
| 新用户 + 关闭 iCloud | 降级本地模式，App 正常运行 | 模拟器关闭 iCloud |
| 开→关→开 切换 | 数据完整，无重复 memo | 手动切换测试 |
| 附件未下载时滚动 Timeline | 占位符显示，点击触发下载 | Simulator 网络限速 |
| `ConflictMerger` UUID 去重 | 单测覆盖，去重逻辑正确 | Swift Testing 单测 |
| 迁移失败（磁盘满）| 保留本地 vault，不破坏现有数据 | 单测 Mock FileManager |
| 迁移成功后 30 天窗口 | 本地 vault 仍存在，Settings 显示"清理"选项 | 时间偏移测试 |

---

## 10. Non-Goals

- ❌ 账号密码登录（本期同步无需登录）
- ❌ Android / Web 客户端
- ❌ 跨 Apple ID 共享（需 CloudKit Public Database，非本期）
- ❌ 选择性同步（全量同步 or 不同步，不支持按目录选择）
- ❌ 端到端加密（iCloud Drive 已提供用户级加密，不额外加密）
- ❌ 可配置定时增量同步（iCloud 系统托管，不支持手动控制周期；此需求在 Supabase 后端实现）
- ❌ 附件上传到 Supabase（避免存储成本，附件仅走 iCloud）
- ❌ Google Drive 本期实现（预留扩展点，v4+）

---

## 11. 风险与缓解

| 风险 | 概率 | 影响 | 缓解措施 |
|---|---|---|---|
| 老用户迁移失败（磁盘满/网络断）| 低 | 高 | 校验通过后才切换，本地保留 30 天；`migration.log` 记录每文件状态 |
| `hot.md` 频繁冲突 | 高 | 低 | 保留 mod time 最大版本，无业务影响 |
| 冲突合并 bug 导致丢 memo | 低 | 极高 | UUID 去重单测覆盖；最坏情况保留重复 memo 不丢失 |
| iCloud 配额爆（免费 5GB）| 中 | 中 | 仅同步 Markdown（<1 KB/条），附件按需下载；Settings 显示 vault 大小 |
| 苹果审核：iCloud 用途声明 | 低 | 高 | App Privacy：声明"用于同步用户自己的日记内容" |
| `NSMetadataQuery` 性能影响 | 低 | 中 | 限制搜索范围为 vault 目录；查询在后台线程执行 |
| 附件按需下载影响 Timeline 体验 | 中 | 中 | 占位符 + 异步下载；Settings 可切换"始终本地" |

---

## 12. 后续实施 issue 拆分（设计评审通过后建）

| 编号 | Issue 标题 | 工作量 | 依赖 |
|---|---|---|---|
| #A | VaultLocator 抽象层 + LocalVaultLocator 默认实现 | S（2-4h）| 无 |
| #B | Ubiquity Container 接入 + Entitlements + iCloudVaultLocator | M（4-8h）| #A |
| #C | 冲突合并逻辑（ConflictMerger）+ Swift Testing 单测 | M（4-8h）| #B |
| #D | Settings iCloud 状态面板 + 引导卡片 | M（4-8h）| #B |
| #E | 老用户迁移脚本（VaultMigrationService）+ 回滚按钮 | L（8-16h）| #B, #C |

**执行顺序**: #A → #B → #C + #D 并行 → #E

---

## 13. 决策记录

| 日期 | 决策 | 决策者 | 理由 |
|---|---|---|---|
| 2026-04-17 | 选择方向 A（iCloud Drive）| @cubxxw | 零运维，符合"可搬运 Markdown"核心价值 |
| 2026-04-17 | 不加登录模块（本期）| @cubxxw | Apple ID 即身份，零摩擦体验 |
| 2026-04-17 | 导出增强独立推进，与同步解耦 | @cubxxw | 降低耦合，可独立发布 |
| 2026-04-22 | SyncBackend 协议预留 Google Drive / Supabase 扩展 | @cubxxw + Claude | 评论区需求，避免架构锁死 |
| 2026-04-22 | 附件按需下载，不强制 iCloud 存储 | Claude 建议 | 保护 5 GB 免费配额，UX 仍可接受 |
| 2026-04-22 | 定时增量同步推迟到 Supabase 后端（v4）| Claude 建议 | iCloud 系统托管不支持，强行实现成本高 |

---

## 14. 验收标准（本 Design Issue）

- [x] 覆盖 6 个核心章节：路径迁移 / 冲突处理 / 状态可见性 / 降级路径 / 大文件处理 / 测试矩阵
- [x] Non-Goals 明确（10 项）
- [x] 风险与缓解措施（7 项）
- [x] 5 个后续实施 issue 的拆分清单（#A - #E）
- [x] 与 Auth 模块关系章节（第 8 节）
- [x] Google Drive / Supabase 扩展点设计（SyncBackend 协议）
- [ ] 与 @cubxxw review，确认方案可实施

---

*文档版本: v1.0 | 生成于 2026-04-22 | 作者: @cubxxw + Claude*
