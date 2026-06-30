# ADR-0005 · 抽取 DayPageKit SwiftPM 包（M0）

- **状态**：Proposed（待 review，未实施）
- **日期**：2026-06-30
- **关联**：`docs/macos-agent-architecture.md` §3（Mac target + 代码共享）；后续 ADR-0006/0007/0008（Agent / Sandbox / LLM 路由）依赖本 ADR 落地
- **影响范围**：`DayPage.xcodeproj/`、`DayPage/Models/`、`DayPage/Storage/`、`DayPage/Services/`、`DayPage/Utilities/`、`DayPage/Config/`、新增 `DayPageKit/`、`DayPageTests/` 部分文件
- **不影响**：iOS 端任何用户可见行为；`Features/`、`App/`、`DesignSystem/`、`Components/`、`Intents/`、`Resources/`

---

## 1. 背景

`docs/macos-agent-architecture.md` §3.2 决定 DayPage macOS 走原生 SwiftUI Mac target，与
iOS 端**只共享 model / service / storage / utilities 四层**，UI 全分叉。该决策的硬性
前置条件是把现存于 `DayPage/` iOS app target 内的共享代码抽到一个独立的 SwiftPM 包
`DayPageKit`，让未来的 `DayPageMac` target 能在不复制代码的前提下复用。

### 1.1 当前现状（2026-06-30 摸底）

`DayPage/` 下与共享层相关的源文件分布：

| 目录 | 文件数 | 平台依赖概览 |
|---|---|---|
| `Models/` | 3 | 全部纯 `Foundation` |
| `Storage/` | 3 | `Foundation` + `WidgetKit` + `CryptoKit`（全部跨平台） |
| `Services/` | 49 | 大部分纯 `Foundation`/`Combine`/`Network`，少数依赖 `UIKit`/`PhotosUI`/`AVFoundation`/`Speech`/`WatchConnectivity`/`BackgroundTasks`/`UserNotifications`（iOS-only） |
| `Utilities/` | 2 | 全部纯 `Foundation` |
| `Config/` | 4 | `SecretsRuntime` 纯 `Foundation`；`AppSettings`/`FeatureFlags` 仅依赖 `SwiftUI`（`@AppStorage`），跨平台；`GeneratedSecrets` 由脚本生成、gitignored |
| `DesignSystem/` | 18 | `SwiftUI` + 部分 `UIKit`，按文档 §3.3 **不进 Kit** |
| `Components/` | 5 | `SwiftUI`，按文档 §3.3 **不进 Kit** |
| `Intents/` | 5 | `AppIntents` + `UIKit`，iOS-only，留 app |
| `Features/` | 大量 | UI 层，按文档 **不进 Kit** |

### 1.2 为什么是 SwiftPM 包而不是嵌套子项目 / static library

| 候选 | 选还是不选 | 理由 |
|---|---|---|
| **SwiftPM 本地包** | ✅ 选 | Xcode 原生 first-class 支持；`Package.swift` 是版本控制友好的纯文本；可声明 `platforms: [.iOS(.v16), .macOS(.v13)]`；test target 直接归口；零外部基础设施 |
| Xcode framework target | ❌ | pbxproj 复杂度高；`@testable import` 与可见性规则比 SPM 麻烦；混合 target 时 codesign 配置坑 |
| 嵌套 `.xcodeproj` | ❌ | 引用通过 pbxproj 间接路径，merge 冲突频繁；与 SwiftPM 模型相比是历史包袱 |
| 文件直接 `add to target` 双勾 | ❌ | 文件在两个 target 内"共享"但实际是 source membership 双写，IDE 索引混乱，平台条件编译只能靠 `#if os(...)` |

---

## 2. 决策

### 2.1 包结构

新增仓库根目录 `DayPageKit/`，作为 local SwiftPM 包：

```
DayPageKit/
├─ Package.swift               ← platforms: [.iOS(.v16), .macOS(.v13)]
├─ Sources/
│  ├─ DayPageModels/           ← 纯数据模型 (3 files)
│  ├─ DayPageStorage/          ← vault 文件系统 + 同步 (11 files)
│  └─ DayPageServices/         ← 跨平台业务服务 (32 files)
└─ Tests/
   ├─ DayPageModelsTests/
   ├─ DayPageStorageTests/
   └─ DayPageServicesTests/
```

三个 product target 而不是一个大包，原因：

1. **依赖关系清晰**：`DayPageServices` 依赖 `DayPageStorage` 依赖 `DayPageModels`，单向无环；分 target 让循环依赖在编译期就被挡住
2. **测试 target 一一对应**：保持现有 `DayPageTests` 的 suite 边界，迁移摩擦最小
3. **未来 `DayPageRAG`/`DayPageAgentKit`（M3/M5 引入）可作为同包内新增 target**，不动 app target 的依赖声明

### 2.2 Package.swift 草案

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DayPageKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "DayPageModels",   targets: ["DayPageModels"]),
        .library(name: "DayPageStorage",  targets: ["DayPageStorage"]),
        .library(name: "DayPageServices", targets: ["DayPageServices"]),
    ],
    dependencies: [
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "8.0.0"),
    ],
    targets: [
        .target(
            name: "DayPageModels"
        ),
        .target(
            name: "DayPageStorage",
            dependencies: ["DayPageModels"]
        ),
        .target(
            name: "DayPageServices",
            dependencies: [
                "DayPageModels",
                "DayPageStorage",
                .product(name: "Sentry", package: "sentry-cocoa"),
            ]
        ),
        .testTarget(
            name: "DayPageModelsTests",
            dependencies: ["DayPageModels"]
        ),
        .testTarget(
            name: "DayPageStorageTests",
            dependencies: ["DayPageStorage", "DayPageModels"]
        ),
        .testTarget(
            name: "DayPageServicesTests",
            dependencies: ["DayPageServices", "DayPageStorage", "DayPageModels"]
        ),
    ]
)
```

**Sentry 处理**：8 个 service 文件 `import Sentry`。Sentry SDK 同时支持 iOS 和 macOS。把
它声明为 `DayPageServices` 的依赖，避免在每个文件加 `#if canImport(Sentry)`。app target
继续从自己的依赖图引入 Sentry（Supabase / Sentry 是 app target 直接 SPM 依赖）。

**Supabase**：仅 `AuthService.swift` 用，该文件**不迁** Kit（见 §2.3），所以 Kit 不需要
声明 Supabase 依赖。

### 2.3 逐文件归属表

#### → `DayPageModels`（3 files）

| 文件 | 当前 import | 备注 |
|---|---|---|
| `Models/Memo.swift` | Foundation | 含 `yamlQuote` 等 YAML 工具 |
| `Models/FrontmatterParser.swift` | Foundation | |
| `Models/CJKTextPolish.swift` | Foundation | |

#### → `DayPageStorage`（11 files）

| 文件 | 当前 import | 备注 |
|---|---|---|
| `Storage/RawStorage.swift` | Foundation, WidgetKit, CryptoKit | vault 主入口 |
| `Storage/VaultInitializer.swift` | Foundation | |
| `Storage/VaultLocator.swift` | Foundation | |
| `Services/ConflictMerger.swift` | Foundation, Sentry | iCloud 冲突合并 |
| `Services/SyncQueueService.swift` | Foundation, Combine | 离线队列 |
| `Services/SyncQueueObserver.swift` | Foundation | |
| `Services/SyncSettings.swift` | Foundation | |
| `Services/NetworkMonitor.swift` | Foundation, Network | |
| `Services/iCloudConflictMonitor.swift` | Foundation, Combine | |
| `Services/iCloudSyncMonitor.swift` | Foundation, Combine | |
| `Services/MemoSyncUploader.swift` | Foundation | Supabase 上传占位 |

#### → `DayPageServices`（32 files）

| 文件 | 当前 import | 备注 |
|---|---|---|
| `Services/AuthRateLimiter.swift` | Foundation, CryptoKit | |
| `Services/CompilationService.swift` | Foundation | 现有 DashScope/DeepSeek 编译核心 |
| `Services/DayPageLogger.swift` | Foundation, Sentry | |
| `Services/EntityPageService.swift` | Foundation | |
| `Services/FeedbackService.swift` | Foundation | |
| `Services/GraphRetriever.swift` | Foundation | |
| `Services/HTTPClientHelper.swift` | Foundation | |
| `Services/HTTPTransport.swift` | Foundation | |
| `Services/KeychainHelper.swift` | Foundation, Security | |
| `Services/LLMClient.swift` | Foundation, Sentry | |
| `Services/LocationService.swift` | Foundation, CoreLocation | macOS 权限模型不同但 API 兼容 |
| `Services/MemoryChatService.swift` | Foundation | |
| `Services/OnThisDayIndex.swift` | Foundation | |
| `Services/OrphanedPhotoScanner.swift` | Foundation | |
| `Services/OrphanedVoiceScanner.swift` | Foundation | |
| `Services/PassiveLocationService.swift` | Foundation, CoreLocation | |
| `Services/RetryHelper.swift` | Foundation | |
| `Services/SampleDataSeeder.swift` | Foundation | |
| `Services/SearchService.swift` | Foundation | |
| `Services/SentryRedactor.swift` | Foundation | |
| `Services/SentryReporter.swift` | Foundation, Sentry | |
| `Services/TimelineIndex.swift` | Foundation | |
| `Services/TimelinePinService.swift` | Foundation, Combine | |
| `Services/TimelineService.swift` | Foundation | |
| `Services/VaultExportService.swift` | Foundation | |
| `Services/WeatherService.swift` | Foundation, CoreLocation, Sentry | |
| `Services/WeeklyCompilationService.swift` | Foundation | |
| `Services/WeeklyRecapService.swift` | Foundation | |
| `Utilities/DateFormatters.swift` | Foundation | |
| `Utilities/RelativeTimeFormatter.swift` | Foundation | |
| `Config/SecretsRuntime.swift` | Foundation | |
| `Config/AppSettings.swift` | Foundation, SwiftUI | `@AppStorage`，SwiftUI 跨平台 |
| `Config/FeatureFlags.swift` | Foundation, SwiftUI | 同上 |

#### 留在 app target（iOS-only 平台依赖，12 files）

| 文件 | 平台依赖 | 不迁原因 |
|---|---|---|
| `Services/AuthService.swift` | Supabase, AuthenticationServices, Sentry, Network | 依赖 Supabase；macOS auth 流程要重做，第二个 ADR 处理 |
| `Services/BackgroundCompilationService.swift` | BackgroundTasks, UserNotifications | iOS BGTaskScheduler，macOS 改 LaunchAgent（M4/M5） |
| `Services/ComposerContextProvider.swift` | UIKit | |
| `Services/HapticFeedback.swift` | UIKit | |
| `Services/MarkdownExportService.swift` | UIKit | `UIActivityViewController` 调用 |
| `Services/OnThisDayScheduler.swift` | UIKit | |
| `Services/PhotoService.swift` | PhotosUI, ImageIO | macOS 需替换 `NSImage`/`PHPicker` 不可用 |
| `Services/VaultMigrationService.swift` | SwiftUI + CryptoKit | 含 UI 触发逻辑，复杂，第二轮再拆 |
| `Services/VoiceAttachmentQueue.swift` | UIKit | |
| `Services/VoiceService.swift` | AVFoundation, Speech | macOS `AVAudioRecorder` 路径不同 |
| `Services/WatchReceiveService.swift` | WatchConnectivity | iOS-only API |
| `Config/GeneratedSecrets.swift` | （无 import） | gitignored，各 target 各一份 |

#### 不迁（UI / Features / Intents / Resources）

- `App/`、`Features/`、`DesignSystem/`、`Components/`、`Intents/`、`Resources/`：按
  `macos-agent-architecture.md` §3.3，UI 与 iOS 平台 entry 全部分叉，不进 Kit

### 2.4 access level 改动策略

SwiftPM 包的 `internal` 对 app target 不可见。所有迁入 Kit 的 public API 必须改为 `public`。

**策略**：
1. **Types**：`class` / `struct` / `enum` / `protocol` 顶层声明 → `public`
2. **Initializers**：所有 `init` 显式 `public init`
3. **Members**：被 app target 引用的 method/property → `public`；只在 Kit 内部使用的保持 `internal`
4. **Sentry / 第三方类型**：API 签名里出现的第三方类型必须自身 public（Sentry SDK 已是 public）
5. **`@MainActor`**：保持现状，跨模块仍生效

**验证方法**：迁完后 app target build，错误 `cannot find 'X' in scope` 或 `'X' is inaccessible due to 'internal' protection level` 就是漏改 public 的清单。

### 2.5 Xcode 接入步骤（需 GUI 操作）

由 maintainer 在 Xcode 里执行：

1. 打开 `DayPage.xcodeproj`
2. File → Add Package Dependencies… → Add Local… → 选 `DayPageKit/` 目录
3. Targets → DayPage → General → Frameworks, Libraries, and Embedded Content → `+`
   → 依次加 `DayPageModels`、`DayPageStorage`、`DayPageServices`
4. Build Phases → Compile Sources → 移除已迁出文件（pbxproj 应该自动同步，但建议人工核对）
5. ⌘B 验证编译

**预期 pbxproj diff**：
- 新增 `XCRemoteSwiftPackageReference` 或本地包引用
- 新增 `XCSwiftPackageProductDependency` 三项
- 删除约 49 项 `PBXFileReference` + `PBXBuildFile`
- `PBXSourcesBuildPhase` 内文件清单缩减

### 2.6 测试迁移

| 现有测试 | 测被迁代码 | 迁去 |
|---|---|---|
| `MemoYAMLTests` | Memo.swift | `DayPageModelsTests` |
| `RawStorageWriteFailedTests` | RawStorage.swift | `DayPageStorageTests` |
| `SyncQueueServiceTests` | SyncQueueService.swift | `DayPageStorageTests` |
| `NetworkMonitorTests` | NetworkMonitor.swift | `DayPageStorageTests` |
| `LocationServiceLRUTests` | LocationService.swift | `DayPageServicesTests` |
| `OnThisDayIntegrationTests` | OnThisDayIndex + Scheduler | **拆**：Index 部分迁 `DayPageServicesTests`；Scheduler 部分留 `DayPageTests`（Scheduler 不迁 Kit） |
| `WeeklyCompilationServiceTests` | WeeklyCompilationService.swift | `DayPageServicesTests` |
| `WeeklyRecapAutoTriggerTests` | WeeklyCompilationService + BackgroundCompilationService | **拆**：自动触发条件部分留 `DayPageTests`（依赖 BackgroundCompilationService） |
| `ArchiveViewModelGroupTests` | ArchiveView 内 view-model | 留 `DayPageTests`（ViewModel 不迁 Kit） |

---

## 3. 预见的 build 问题

| 错误类型 | 高发文件 | 解决 |
|---|---|---|
| `cannot find 'X' in scope` | 跨 Kit target 引用 | 把被引用类型标 `public` |
| `'init(...)' is inaccessible` | 任何被 app target 实例化的 type | 显式 `public init` |
| `cannot convert value of type 'X' to expected argument type` | 跨模块类型同名但 namespace 不同 | 检查是否两个模块各定义了一份 |
| `Cannot find type 'XX' in scope` (Sentry) | 8 个 Sentry 引用文件 | DayPageServices 已声明 Sentry 依赖；如仍报错检查 product 依赖配置 |
| 循环依赖 | `DayPageServices` 反向引用 `DayPageStorage` 不该有的内部类型 | 看是否需要把类型上提到 Models |
| `@MainActor` isolation 错 | 跨模块的 actor-isolated 调用 | 大多需要在调用站 `await`；不是迁移引入的真 bug，只是暴露了已有问题 |
| `WidgetKit` 在 macOS 缺 API | `RawStorage.swift` | macOS 13+ 支持 WidgetKit；如某 API 不可用，包 `#if os(iOS)` |

---

## 4. 回滚方案

迁移过程在独立分支 `feat/m0-daypagekit-extraction` 进行：

1. 若 build 不过且短期修不好 → `git reset --hard origin/main` 放弃
2. 若 build 过但运行时有回归 → revert merge commit
3. 由于 `git mv` 保留 history，文件 blame 不会断

---

## 5. iOS 端零行为变化验证清单

合并前必须全部通过（CLAUDE.md 硬性要求）：

- [ ] `xcodebuild -scheme DayPage -destination 'platform=iOS Simulator,name=iPhone 17' build` 成功
- [ ] 所有 `DayPageTests` + 新增三个 Kit testTarget 全绿
- [ ] Simulator 启动 → 写一条 memo → 关闭重启 → memo 仍在
- [ ] `vault/raw/2026-XX-XX.md` 的 YAML frontmatter + Markdown 结构与迁移前 byte-identical（diff 验证）
- [ ] 触发一次 AI 编译 → DashScope 调用成功 → `vault/wiki/daily/` 产物正确
- [ ] 离线 queue banner、OnThisDay 卡片、WeeklyRecap section 全部正常显示
- [ ] Sentry 上报通道仍通（人工触发一次 testError）

---

## 6. 实施顺序建议

下次会话由 maintainer + Claude 合作执行，按此顺序：

| 步 | 动作 | 谁 | 验证 |
|---|---|---|---|
| 1 | 创建 `DayPageKit/` 目录 + `Package.swift` 骨架 | Claude | `cd DayPageKit && swift package describe` 成功 |
| 2 | `git mv` Models 3 文件 | Claude | `swift build --package-path DayPageKit` 通过 |
| 3 | `git mv` Storage 11 文件 + 改 public | Claude | 同上 |
| 4 | `git mv` Services 32 文件 + 改 public | Claude | 同上 |
| 5 | Xcode GUI 接入 local package | **maintainer** | `xcodebuild -scheme DayPage build` 通过 |
| 6 | 修跨模块可见性错误（迭代） | Claude | 同上 |
| 7 | 迁移测试 | Claude | `xcodebuild test` 全绿 |
| 8 | iOS Simulator 端到端验证 | maintainer + Claude | §5 清单全过 |
| 9 | PR + review + merge | maintainer | — |

---

## 7. 范围外

明确**不在本 ADR 范围内**（留给后续 ADR）：

- 任何 macOS target / DayPageMac.xcodeproj / NavigationSplitView / MenuBarExtra（M1/M2 范围，ADR 待写）
- Agent 编排（M5 范围，ADR-0006）
- Sandbox / Tier 分级（ADR-0007）
- 本地 LLM 路由 / MLX（ADR-0008）
- `DayPageRAG` 模块（M3，未来 ADR）
- iOS-only 的 12 个 service 的拆分（第二轮 M0+ 处理）

---

## 8. Open questions

需 maintainer 决策：

1. **Sentry 作为 `DayPageServices` 的强依赖**还是用 `#if canImport(Sentry)` 软依赖？
   - 强依赖：代码干净，但 Kit 用户都被绑上 Sentry
   - 软依赖：保留可选性，但 8 处 `#if` 噪音
   - **推荐**：强依赖（DayPage 主 app 必带 Sentry，无场景不需要）

2. **`AuthService` 第二轮是否独立拆 `DayPageAuth` 模块**？
   - 它依赖 Supabase；macOS 端 auth 体验需重设计
   - 推荐 M0 不动，等 macOS 端 auth ADR 一并讨论

3. **`GeneratedSecrets.swift` 是否进 Kit**？
   - 该文件 gitignored、由脚本生成、含 API key
   - 推荐：**不迁**。每个 app target 自己生成一份 + Kit 内通过 `SecretsRuntime` 协议注入

4. **是否在本 PR 内同时升级 `swift-tools-version`**？
   - 推荐：用 5.9（与 Xcode 16 配套，无升级压力）

---

## 9. 参考

- `docs/macos-agent-architecture.md` §3 — 本 ADR 的上游决策
- Apple Developer, "Organizing your code with local packages" — SwiftPM local package 模型
- Swift Forums, "Best practices for shared code across iOS and macOS targets" — `#if canImport(...)` vs 多 target 拆分的取舍
