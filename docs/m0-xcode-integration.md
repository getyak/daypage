# M0 — Xcode GUI Integration Guide

> 时间预估：3–5 分钟
> 前置：当前分支 `feat/m0-daypagekit-extraction`、PR #796、Kit 已 swift build 通过、app target 端 import 已注入。
> 风险：低（local SwiftPM 包接入是 Xcode 标准动作，可随时 git revert）。

按顺序执行以下 4 步，遇到任何阻塞**先停下**告诉我，不要继续。

---

## Step 1 — 关闭并重开 Xcode

确保 Xcode 没有打开过旧版本的 `DayPage.xcodeproj`：

```
⌘Q Xcode           # 完全退出
open DayPage.xcodeproj
```

如果 Xcode 提示 "Open Anyway" / "Trust", 选 Trust（项目根 = git 仓库根，已知安全）。

---

## Step 2 — Add Local Package

1. 顶部菜单 **File** → **Add Package Dependencies…**
2. 对话框左下角点 **Add Local…**
3. 在 finder 里选 **`DayPageKit/` 目录**（不是 `Package.swift`，而是它所在的目录）
4. 点 **Add Package**
5. 在 "Choose Package Products" 表格里，**3 个 library 都加到 `DayPage` target**：
   - ✅ `DayPageModels` → Target: `DayPage`
   - ✅ `DayPageStorage` → Target: `DayPage`
   - ✅ `DayPageServices` → Target: `DayPage`
6. 点 **Add Package**

**验证**：左侧 Project Navigator → **DayPage**（蓝色项目图标）→ **Package Dependencies** 区域应该出现 `DayPageKit` 折叠组，下面是 sentry-cocoa（间接依赖）。

---

## Step 3 — 验证 framework 已链接

1. Project Navigator → **DayPage**（蓝色图标）→ **TARGETS** → **DayPage**
2. 顶部 tab 选 **General**
3. 找到 **Frameworks, Libraries, and Embedded Content** 区域
4. 应该看到：
   - `DayPageModels`
   - `DayPageStorage`
   - `DayPageServices`
   - `Sentry`
   - `Supabase`（以及它的依赖）

如果**少了任何一个 DayPage* 库**，点 **`+`** → 搜 `DayPageModels` / `DayPageStorage` / `DayPageServices` → Add。

---

## Step 4 — 移除已迁出的旧文件引用

App target 的 `Compile Sources` 列表里可能还有指向 `DayPage/Models/Memo.swift` / `DayPage/Services/*.swift` 等已 git-mv 走的文件的 **"missing file" 红色引用**。Xcode 不会自动同步 git mv。

1. Project Navigator → 展开 **DayPage** 文件夹
2. 找出**显示为红色**的 .swift 文件名（被 git mv 走的）
3. 选中所有红色文件 → 右键 → **Delete** → 选 **Remove Reference**（**不要**选 Move to Trash —— 文件已经被 git 搬走了，物理删除会丢真文件）

红色文件清单（参考 — 实际以 Xcode 显示为准）：

```
DayPage/Models/Memo.swift
DayPage/Models/FrontmatterParser.swift
DayPage/Models/CJKTextPolish.swift
DayPage/Storage/RawStorage.swift
DayPage/Storage/VaultInitializer.swift
DayPage/Storage/VaultLocator.swift
DayPage/Services/ConflictMerger.swift
DayPage/Services/SyncQueueService.swift
DayPage/Services/SyncQueueObserver.swift
DayPage/Services/SyncSettings.swift
DayPage/Services/NetworkMonitor.swift
DayPage/Services/iCloudConflictMonitor.swift
DayPage/Services/iCloudSyncMonitor.swift
DayPage/Services/MemoSyncUploader.swift
DayPage/Services/SentryReporter.swift
DayPage/Services/DayPageLogger.swift
DayPage/Services/KeychainHelper.swift
DayPage/Services/HTTPClientHelper.swift
DayPage/Services/HTTPTransport.swift
DayPage/Services/AuthRateLimiter.swift
DayPage/Services/CompilationService.swift
DayPage/Services/EntityPageService.swift
DayPage/Services/FeedbackService.swift
DayPage/Services/GraphRetriever.swift
DayPage/Services/LLMClient.swift
DayPage/Services/LocationService.swift
DayPage/Services/MemoryChatService.swift
DayPage/Services/OnThisDayIndex.swift
DayPage/Services/OrphanedPhotoScanner.swift
DayPage/Services/OrphanedVoiceScanner.swift
DayPage/Services/PassiveLocationService.swift
DayPage/Services/RetryHelper.swift
DayPage/Services/SampleDataSeeder.swift
DayPage/Services/SearchService.swift
DayPage/Services/SentryRedactor.swift
DayPage/Services/TimelineIndex.swift
DayPage/Services/TimelinePinService.swift
DayPage/Services/TimelineService.swift
DayPage/Services/VaultExportService.swift
DayPage/Services/WeatherService.swift
DayPage/Services/WeeklyCompilationService.swift
DayPage/Services/WeeklyRecapService.swift
DayPage/Utilities/DateFormatters.swift
DayPage/Utilities/RelativeTimeFormatter.swift
DayPage/Config/AppSettings.swift
DayPage/Config/FeatureFlags.swift
```

---

## Step 5 — Build (⌘B)

⌘B 触发编译。**预期结果有两种**：

### 情况 A：编译成功 ✓
告诉我 "build 绿了"。我接下来跑 Simulator 验证（Step 8）。

### 情况 B：还有编译错误
**正常**，因为我没法在自己端跑 xcodebuild 验证 import 完整性。把 Build navigator (⌘9) 里**第一屏**的错误截图或粘贴给我（前 10 条就够），我接着修。

预期可能出现的错误类型：
- "Cannot find 'X' in scope" — 某个文件漏 import，我补
- "'shared' is inaccessible due to internal protection level" — Kit 内某个 .shared 漏 public
- "Type 'X' has no member 'Y'" — 跨模块时 Storage / Services 同名冲突，需要消除

---

## 如果中途出错 / 想回滚

```
git reset --hard origin/feat/m0-daypagekit-extraction
```
回到当前 commit `e77e1cd`，所有改动保留但 working tree 重置。

或者完全放弃 M0：
```
git checkout main
git branch -D feat/m0-daypagekit-extraction       # 慎用，会丢本地分支
```

---

## 完成后

告诉我 "build 绿了" 或贴出第一屏错误。我下一步做：
- 跑 iOS Simulator (iPhone 17) 启动 app
- 写一条 memo 验证 vault/raw/YYYY-MM-DD.md 输出正确
- Step 7 测试 suite 迁移
- 然后开始 M1（macOS target 创建 + 最小可用桌面 app）
