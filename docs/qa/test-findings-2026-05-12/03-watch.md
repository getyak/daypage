# DayPageWatch 测试报告

测试日期：2026-05-12
测试方式：代码静态审计（watchOS 模拟器不可用，详见"构建状态"）
代码版本：分支 `docs/feature-inventory`，HEAD `e7ec178`

---

## 一、构建状态

### Scheme / Target
- **Project**：`DayPage.xcodeproj`
- **Watch target**：`DayPageWatch`（`com.apple.product-type.application.watchapp2`）
- **Bundle ID**：`com.daypage.watchkitapp`
- **Watch schemes**（`xcodebuild -list` 输出）：
  - `DayPageWatch`
  - `DayPageWatch (Notification)`
- **Watch 共享 scheme**：**无**（`DayPage.xcodeproj/xcshareddata/xcschemes/` 只有 `DayPage.xcscheme`，两个 Watch scheme 都是 user-only）。这意味着 CI / `verify-daypage` skill / 任何 fresh checkout 都跑不到 Watch app。**[P1 见 V-1]**

### Build 配置
- `SDKROOT = watchos`
- `WATCHOS_DEPLOYMENT_TARGET = 9.0`
- `TARGETED_DEVICE_FAMILY = 4`（Watch）
- `SWIFT_VERSION = 5.0`
- `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`（**但 Assets.xcassets 是空的，没有 AppIcon — 见 V-2**）

### Build 结果
```
xcodebuild -scheme DayPageWatch -destination 'generic/platform=watchOS' build
→ error: watchOS 26.4 is not installed.
xcrun simctl list runtimes | grep -i watch  → (empty)
xcrun simctl list devices | grep -i watch   → (empty)
```

**结论**：本机完全没有 watchOS SDK / 模拟器 runtime。无法 build、无法跑端到端验证。需要在 Xcode → Settings → Components 里安装 watchOS 26.4 SDK 才能继续。

### 可用 watch 模拟器型号
**无**。建议安装：`Apple Watch Series 10 (46mm)` watchOS 26.x。

---

## 二、运行状态

未启动（无 SDK）。无截图。

---

## 三、问题清单（按优先级）

### P0 — Blocking

#### P0-1 Watch 录音落地后是死文件，没有任何消费者
**位置**：`DayPage/Services/WatchReceiveService.swift:65-78`，`DayPageWatch/Features/RecordingView.swift:146-154`

整条管线断了：
1. Watch 录音 → `WatchTransferService.transferAudioFile` 通过 `WCSession.transferFile` 发到 iPhone
2. iPhone 端 `WatchReceiveService.session(_:didReceive:)` 把文件移到 `vault/raw/assets/watch_<filename>.m4a`
3. ✅ 文件落地了
4. ❌ `lastReceivedFile` 是 `@Published`，但**全工程没有任何地方观察它**（`grep WatchReceiveService` 只命中 `DayPageApp.swift` 的初始化代码）
5. ❌ **没有调用 `VoiceAttachmentQueue.enqueue(...)`**，所以：
   - 不会触发 Whisper 转录
   - 不会创建任何 `Memo`
   - 不会写入 `vault/raw/YYYY-MM-DD.md`
   - 用户在 Today 页里**永远看不到 Watch 录的语音**

**影响**：Watch 端整个功能从用户视角看是 0 — 录了等于没录。

**建议修复**：在 `WatchReceiveService.session(_:didReceive:)` 文件移动成功后，调用 `VoiceAttachmentQueue.shared.enqueue(audioPath: destURL.path, memoDate: Date())`（或类似 API），让现有 iOS 端的语音管线接管。

---

### P1 — Critical

#### P1-1 没有共享 Watch scheme，CI / 自动化完全 bypass
**位置**：`DayPage.xcodeproj/xcshareddata/xcschemes/`

只有 `DayPage.xcscheme` 是 shared。两个 Watch scheme（`DayPageWatch`、`DayPageWatch (Notification)`）都是 user-only，存在某个用户的 `xcuserdata/` 里。`verify-daypage` skill、GitHub Actions、第二个开发者 clone 后都跑不到 Watch build。

**建议修复**：在 Xcode 里勾选 Manage Schemes → Shared，把 Watch scheme 共享出来并 commit `.xcscheme` 文件。

#### P1-2 Complication 完全没生效
**位置**：`DayPageWatch/Complications/ComplicationProvider.swift` 全文

代码里同时定义了两套互相不通的 API：
- `DayPageComplicationTimelineProvider: TimelineProvider`（**WidgetKit** API） — 但**没有任何 `@main struct ... : Widget`**，没有 widget extension target，所以 timeline provider 永远不会被注册到 watchOS。
- `DayPageComplicationConfigurator.modularDescriptor() / circularDescriptor() / utilitarianDescriptor()`（**ClockKit** API，自 watchOS 10 起 deprecated） — 这些 `CLKComplicationTemplate` 是被声明出来的纯静态函数，**没有任何调用者**，没有 `CLKComplicationDataSource` 实现，没有 `getComplicationDescriptors`。

**结果**：表盘 complication 永远不会出现。文件名 `ComplicationProvider.swift` + 注释会让人误以为它能工作。

**建议修复**：
- 二选一：要么改成正确的 WidgetKit Watch complication（`WidgetBundle` + 独立 extension target）；要么删掉这个文件，避免误导。

#### P1-3 StartRecordingIntent 无法被用户触发
**位置**：`DayPageWatch/Complications/StartRecordingIntent.swift`

代码里有一个 `StartRecordingIntent: AppIntent`，注释说"Triggered by the Watch Action Button"，但：
- **没有 `AppShortcutsProvider` 实现**，所以 Action Button / Siri / Spotlight 都看不到这个 intent
- 没有 entitlement、没有 Info.plist 注册
- `grep -r "AppShortcuts" DayPageWatch/` → 空

**结果**：Action Button 永远不会调用这个 intent。

**建议修复**：补一个 `struct DayPageWatchShortcuts: AppShortcutsProvider`，把 `StartRecordingIntent` 列进去。

#### P1-4 StartRecordingIntent 的 WKExtendedRuntimeSession 用法不对
**位置**：`DayPageWatch/Complications/StartRecordingIntent.swift:19-21,49-52`

```swift
let extSession = WKExtendedRuntimeSession()
extSession.start()
```

问题：
1. **没有设置 `extSession.delegate`** — 无法接收 `extendedRuntimeSession(_:didInvalidateWith:error:)`，session 失败会静默
2. **没有指定 session type**（应在 init 时通过 `WKExtendedRuntimeSession(reason:)` 或对 `.audioRecording` 走专门 API）。当前调用走的是通用前台扩展运行时，audioRecording 模式需要专门标记；注释说"audioRecording"但代码没设置
3. `Task.sleep(nanoseconds: 30_000_000_000)` 写死 30 秒，不可中途停止、不可取消、不响应用户抬起手腕、不响应 watchOS 节流
4. 没有 `try?` 包 `AVAudioRecorder(url:settings:)`，下面的 `recorder.record()` 也没 nil-check 录音是否真的开始
5. 录完即转传，没有用户确认

#### P1-5 Asset catalog 是空的，没有 AppIcon
**位置**：`DayPageWatch/Resources/Assets.xcassets/`

```
Assets.xcassets/
└── Contents.json   ← 只有这一个根 catalog 元数据
```

Build setting `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` 期待一个名为 `AppIcon` 的 `.appiconset`，但**不存在**。装到真机/模拟器后 Home 屏会看到默认占位图标。actool 会发警告甚至在严格模式下报错。

---

### P2 — Important

#### P2-1 WCSession 激活竞态
**位置**：`DayPageWatch/Services/WatchTransferService.swift:24-28`

```swift
guard WCSession.default.activationState == .activated else {
    print("[WatchTransferService] WCSession not activated")
    completion(false)
    return
}
```

`WatchSessionManager.shared.activate()` 在 `init` 里调用 `session.activate()`，但 activation 是异步的（要等 `activationDidCompleteWith` 回调）。如果用户冷启动 app 后立刻按录音键并停止上传，第一次 `transferAudioFile` 调用大概率走 guard fail 路径，UI 上显示 "Transfer failed"，**录音文件还会被 `removeItem` 删掉** — 没有，等等 — 实际上 `transferAudioFile` 早期返回时并不会清理 source file，只有 `handleTransferFinished` 才会。所以**文件不会丢，但用户必须重录**。

**建议修复**：在 guard 失败时 retry / 排队 / 等待 activation 完成。或者把 transferAudioFile 改成 `async`，内部 await session activation。

#### P2-2 RecordingView Timer 不会停在 `.done`/`.failed`
**位置**：`DayPageWatch/Features/RecordingView.swift:167-174`

```swift
timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
    Task { @MainActor in
        guard self?.state == .recording else { return }
        self?.elapsed += 1
    }
}
```

- Timer 在 `stopAndTransfer` 里通过 `stopTimer()` 主动停了，OK
- 但 `start()` 失败路径（`session.setCategory` / `AVAudioRecorder(url:...)` 抛错）**不会启动 timer**，OK
- 唯一问题：每次 `start()` 都新建 `WatchRecordingModel` 不会发生（`@StateObject`），所以 timer 的 `[weak self]` 永远不会自然释放 — 不过 `stopTimer()` 已经显式 invalidate，所以暂时没泄漏。**风险一般。**

#### P2-3 录音 30s 后 AVAudioSession 没真正释放（StartRecordingIntent）
**位置**：`DayPageWatch/Complications/StartRecordingIntent.swift:52`

```swift
try? AVAudioSession.sharedInstance().setActive(false)
```

`try?` 吃掉所有错误，但同时**没传 `notifyOthersOnDeactivation`**，watchOS 后续 audio 工作流（音乐、Siri）的恢复时机不确定。

#### P2-4 WatchSessionManager 的 `sessionDidDeactivate` 永远不会被调用
**位置**：`DayPageWatch/App/WatchApp.swift:53-58`

```swift
#if os(iOS)
func sessionDidBecomeInactive(_ session: WCSession) {}
func sessionDidDeactivate(_ session: WCSession) {
    WCSession.default.activate()
}
#endif
```

`#if os(iOS)` 在 watchOS target 永远 false。这段代码在 watchOS 永远不会编译进去。**没问题**（watchOS 上确实不需要这两个回调），但**注释/位置容易误导**，且 iOS 端的 `WatchReceiveService.sessionDidDeactivate` 才是该真正实现的（已经实现，OK）。

但**新问题**：`WatchSessionManager` 既然是 watch 端专用，**为什么要写 `#if os(iOS)`**？说明这个文件是从某处复制粘贴过来的，没清理。

#### P2-5 录音文件命名只有秒级时间戳
**位置**：`DayPageWatch/Features/RecordingView.swift:160-165`

```swift
return dir.appendingPathComponent("watch_\(stamp).m4a")
```

`watchFileStamp` 是 `yyyyMMdd_HHmmss`，秒级。极端情况下同一秒内启动两次录音（不太可能，但若 Action Button + 手动 UI 同时触发）会覆盖。建议加 UUID 后缀。

#### P2-6 文件清理仅在 transfer 完成回调里发生
**位置**：`DayPageWatch/Services/WatchTransferService.swift:54`

```swift
try? FileManager.default.removeItem(at: fileURL)
```

只在 `handleTransferFinished` 里清理。如果 transfer 永远不完成（Watch 进入低电量、用户卸载 iPhone app），文件会**永远卡在 `tmp/com.daypage.watch/`** 里。Watch 端的 tmp 目录虽然系统会回收，但有可能在 transfer 过程中、reboot 之间堆积。

**建议修复**：app 启动时扫一遍 `tmp/com.daypage.watch/`，对超过 24h 的孤儿文件清理。

---

### P3 — Polish

#### P3-1 print 调试日志没走统一 logger
**位置**：`DayPageWatch/App/WatchApp.swift:31,47,49`、`DayPageWatch/Services/WatchTransferService.swift:25,40,47,50`

全部用 `print(...)`，而 iOS 端用的是 `DayPageLogger`。Watch 端没复用 logger 系统（Watch 端确实没法导入 iOS 的 `DayPageLogger.swift`，因为它不在 Watch target 的 Sources 里），但至少应该用 `os.Logger`。

#### P3-2 UI 没适配 Digital Crown
RecordingView 里没有 `.focusable()` + `.digitalCrownRotation(...)`，意味着用户不能用旋钮调音量/选择。对录音 app 来说也许不是必需，但是 watchOS HIG 推荐至少在长列表/进度场景支持。

#### P3-3 没有 Always-On Display 优化
录音中 elapsed time 用 `font(.title3.monospacedDigit())` + `animation(.default, value: model.elapsed)`，**每秒一次动画**。Always-On 模式下应该用 `.privacySensitive(...)` 隐藏内容并降低刷新率，否则会显著耗电。

#### P3-4 RecordingView 缺少触觉反馈
开始/停止录音时没有 `WKHapticType.start / .stop` 触发 — 这是 Apple Watch HIG 强烈推荐的。

#### P3-5 状态机不闭环
`State` 枚举有 `.idle, .recording, .processing, .uploading, .done, .failed(...)` 共 6 个状态，但 UI 只处理了 `.idle` 和 `.recording` 两个分支（`handleTap` 里其他状态 fallthrough 到 `default: break`）。`.done` 和 `.failed` 状态下用户点击没有任何反应 — 需要点别处或等待自动复位，但**代码里没有任何自动复位 `.done → .idle` 的逻辑**，所以一次录完之后用户必须杀掉 app 才能重录。

**建议修复**：`.done` 后 2s 自动回 `.idle`；`.failed` 后点击直接回 `.idle`。

#### P3-6 没有 stop 提示音 / 显式确认
长按 / 误触很容易在 watchOS 上发生。建议在 `.recording → .processing` 之间加一次轻确认。

#### P3-7 Watch 端没有 Settings / 隐私说明入口
`NSMicrophoneUsageDescription = "DayPage uses the microphone to record voice memos."` 在 Info.plist OK，但 watchOS 用户首次拒绝麦克风权限后，**无法在 watch 端跳转设置**（watchOS 没有 `UIApplication.openSettingsURLString`）。需要在 RecordingView 里检测权限被拒并显示明确的"请在 iPhone Watch app 里启用"提示。

#### P3-8 没有可访问性 label
RecordingView 的按钮全是 SF Symbol，没 `accessibilityLabel`。VoiceOver 用户会听到 "stop circle fill" 而不是 "Stop recording"。

---

## 四、按维度分类

### 视觉
- 没有 AppIcon（P1-5）
- RecordingView 简洁、布局合理，对小屏 OK
- 录音中是红色 `waveform` + 红色 `stop.circle.fill`，颜色语义清晰
- 缺 Always-On 优化（P3-3）

### 交互
- 状态机不闭环，无法重录（P3-5）
- 缺触觉反馈（P3-4）
- 缺 Digital Crown 适配（P3-2）
- 缺无障碍 label（P3-8）

### 功能
- **Watch 录音根本不出现在 Today**（P0-1，最严重）
- Complication 不生效（P1-2）
- Action Button intent 不生效（P1-3 + P1-4）
- WCSession 冷启动竞态（P2-1）

### 性能
- 30s 硬编码 sleep（P1-4）
- 每秒 SwiftUI animation（P3-3）
- 临时录音文件可能堆积（P2-6）

### 可访问性
- 无 accessibilityLabel（P3-8）
- 无可设置的录音时长

### watchOS 平台规范
- 没用 WidgetKit 正确实现 complication（P1-2）
- 没用 AppShortcutsProvider 暴露 intent（P1-3）
- WKExtendedRuntimeSession 用法错误（P1-4）
- 没复用 Watch 触觉/Crown API（P3-2、P3-4）
- 没考虑 Always-On Display（P3-3）

---

## 五、代码审计发现

### 文件结构与行数
| 文件 | 行数 | 角色 |
|---|---|---|
| `DayPageWatch/App/WatchApp.swift` | 68 | `@main` + WCSession 管理器 |
| `DayPageWatch/App/RootView.swift` | 13 | 极简根视图，只包了 `NavigationStack + RecordingView` |
| `DayPageWatch/Features/RecordingView.swift` | 192 | 录音 UI + ViewModel（合理大小） |
| `DayPageWatch/Services/WatchTransferService.swift` | 56 | WCSession 文件传输封装 |
| `DayPageWatch/Complications/ComplicationProvider.swift` | 68 | **未生效的 complication**（P1-2） |
| `DayPageWatch/Complications/StartRecordingIntent.swift` | 63 | **未注册的 AppIntent**（P1-3） |
| **合计** | **460** | 6 个文件，规模合理 |

### 与 iOS app 的共享代码情况
**零共享**。Watch target 的 Sources 完全独立。iOS 端有 `VoiceService`、`VoiceAttachmentQueue`、`VoiceRecordingView`、`PressToTalkButton`、`RecordingOverlayView` 等 8+ 个录音相关组件，**没有一个被 Watch 复用**。这有合理的 watchOS API 限制理由（`UIKit` 不可用），但意味着两端的状态机会逐渐 diverge — 例如 iOS 端有 `VoiceAttachmentQueue` 处理 retry/persistence，Watch 端完全没有。

### Watch target Sources（PBX 检查）
确认 6 个 swift 文件全部正确归属 `DayPageWatch` target（PBX `4705AC05FAC24B4000886F57`）。**没有重复编译进 iOS target**。

### 潜在 bug / 反模式汇总
1. **P0-1**：iOS 端文件落地后没有任何 consumer（最严重）
2. **P1-2**：ComplicationProvider 是空壳
3. **P1-3 / P1-4**：StartRecordingIntent 是空壳 + WKExtendedRuntimeSession 误用
4. **P1-5**：AppIcon 缺失
5. **P2-1**：WCSession 冷启动 race
6. **P2-4**：`#if os(iOS)` 死代码（从 iOS 复制过来没清理）
7. **P3-5**：状态机不闭环（done 之后用户被卡死）

### 安全 / 密钥审计
- ✅ 没有 hardcoded secrets
- ✅ iOS 端 `WatchReceiveService` 已经对 `filename` 做了 `(rawFilename as NSString).lastPathComponent` 防 path traversal
- ✅ WCSession metadata 只包含元信息，没传敏感数据
- ⚠️ 麦克风权限描述 OK（`NSMicrophoneUsageDescription`）
- ⚠️ Watch Info.plist 没有 `NSAppleEventsUsageDescription`、`NSSpeechRecognitionUsageDescription`，但目前也不需要（转录在 iPhone 端发生）

---

## 六、改进建议（按优先级排序）

### 必须先修（unblock dogfood）
1. **修 P0-1**：`WatchReceiveService` 收到文件后调用 `VoiceAttachmentQueue.shared.enqueue(...)` 触发 Whisper 转录 + 创建 Memo。否则 Watch 功能在用户视角完全失效。
2. **修 P1-5**：补 AppIcon `appiconset`，否则装机后是占位图。

### 第二阶段（让"宣传"特性真的能用）
3. **修 P1-2**：决定 complication 是否要做。要做就用 WidgetKit + 独立 widget extension target；不做就删 `ComplicationProvider.swift` 避免误导。
4. **修 P1-3 / P1-4**：补 `AppShortcutsProvider`、正确使用 `WKExtendedRuntimeSession`（设 delegate、传 session type、错误处理）、把 30s 硬编码改成 stop button 或可配置。
5. **修 P1-1**：把 Watch scheme `Shared`，commit 进 git，让 CI 能跑。

### 第三阶段（polish）
6. **修 P2-1**：WCSession 激活竞态 — `transferAudioFile` 改 async + 等 activation。
7. **修 P3-5**：录音状态机闭环 — `.done` 2s 自动回 `.idle`。
8. **修 P3-4 + P3-2**：补触觉反馈、Crown 支持。
9. **修 P3-8**：补 accessibilityLabel。
10. **修 P2-4**：删 `#if os(iOS)` 死代码。
11. **修 P2-6**：启动时扫 `tmp/com.daypage.watch/` 清理孤儿文件。
12. **修 P3-3**：Always-On 优化。

### 长期
- 安装 watchOS 26.4 SDK，把 Watch 跑起来做真正的端到端测试
- 把 Watch scheme 加进 `verify-daypage` skill
- 考虑 Watch ↔ iPhone 双向同步（目前只能从 Watch 上传，无法在 Watch 上看到当日 memo 列表）

---

## 七、附录

### 我做不了什么
- **跑不起 Watch app**：本机没装 watchOS SDK（Xcode → Settings → Components → watchOS 26.4 没下载），`xcodebuild` 直接报 ineligible destination。
- **跑不了截图**：模拟器无法启动。
- **跑不了 unit / UI test**：项目里没有 Watch 测试 target，且 `DayPageTests` 也跑不到 Watch 代码。

### 建议下一步
1. 在 Xcode 里 install watchOS 26.4 SDK
2. 修 P0-1（最关键的功能 bug）
3. 共享 Watch scheme，触发 CI build
4. 等 SDK 装好后用 `verify-daypage` skill 跑一次完整端到端
