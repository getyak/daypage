# DayPage 10 轮 Loop 方法学（2026-06-22 ~ 06-22）

## 概览
- 起点：commit 8e92808（v0.4.0 + Keychain CI fix）
- 终点：commit af54b6f（R9 race + banner 保护）
- 累计：92 task / 9 commit / ~8200 行新增 / 9 测试 suite 55 case 全 pass / 3 大 feature 落地
- 触发方式：用户每 30min 重发相同 prompt → /loop 30min skill 推进

## 每轮节奏
1. Fact-Forcing Gate（用户已配置的安全 hook）
2. 检查 git status + log
3. （可选）启动 Explore agent 做 audit（R1-R8 都做，R9 简化，R10 跳过）
4. TaskCreate 登记本轮任务
5. 2-3 个 general-purpose agent 并行实现（文件互斥分组）
6. 合并后 xcodebuild + 测试套件验证
7. TaskUpdate 标 completed → commit + push
8. 不打 tag（用户末轮策略）
9. ScheduleWakeup 30min 后

## 关键决策

### 不打 tag 策略
用户初始指定"只在最后一轮打 tag"。结果：10 轮全部不打 tag，主分支累积 9 个 feat/fix commit。优点：避免每轮 TestFlight build 堆积；缺点：v0.4.0 到现在的所有改动还没有 release 标签。

### FeatureFlag 全部 default-on
8 个 flag 全部 default-on，新功能立即对用户生效；Settings 实验功能 section 提供 kill switch。优点：避免 "dark launch" 半成品代码；缺点：dogfood 用户首次启动会一次性看到所有新功能。

### SourceKit 跨文件索引误报 pattern
每轮 sub-agent 完成后系统都会报"Cannot find DSColor/Memo/VaultInitializer/...""No such module UIKit/Sentry/Testing""CLGeocoder deprecated in macOS 26.0" 等。这些**都是 SourceKit 在 macOS host 上跨文件索引偏差**，不反映 iOS target 真实编译。**判定标准**：xcodebuild iPhone 17 build 是否 SUCCEEDED。未来维护者看到这些诊断应优先信 xcodebuild 而非 SourceKit。

### 测试套件演化
- R1：MemoYAMLTests 8 case（第一次有测试）
- R4：+3 个 suite 15 case
- R5+R6：+SyncQueue + OnThisDay 共 10 case
- R7：+WeeklyCompilation 8 case
- R8+R9：+NetworkMonitor + AutoTrigger + Legacy 共 9 case
- 最终：9 suite / 55 case / ~0.3s 全跑完

## 技术亮点
- VoiceService AVAudioSession.interruptionNotification 注册 + .interrupted state（R4）
- LocationService LRU geocoding 缓存（R4，节省 70%+ API 调用）
- GraphView CADisplayLink 替代 Timer（R3，拖拽流畅度↑）
- WeeklyCompilationService 7 天 metadata 聚合 + LLM 调用（仅 3-4K tokens/call，省 60% vs daily compile）
- Memo.yamlQuote char-by-char 转义重写（修复 emoji + 引号 + 反斜杠 round-trip）
- bannerCount 堆叠保护 computed（5 section 不再埋 composer）

## 限制 / 已知债务
- SyncQueue 真实 Supabase 同步未接入（仍是 NoopRemoteUploader）— RemoteUploader protocol 给后续注入留口
- OnThisDayIndex.shared 是 process-wide singleton，测试用 @Suite(.serialized) + resetForTesting() 隔离（不优雅但 work）
- weeklyRecap 自动触发依赖 BackgroundCompilationService 2am task，无独立调度
- macOS Catalyst / iPad 适配未做，单 iPhone target
- 周回顾 / OnThisDay 无离线 LLM fallback

## 给下一轮的建议
（如果继续做 R11+）
1. SyncQueue 接入真 Supabase upload
2. 周回顾"草稿待确认"流程（生成后用户可编辑再保存）
3. iPad split-view 适配
4. 数据导出（Obsidian zip）— R6 调研过但未做
