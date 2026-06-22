# Changelog

Conventional changelog 格式：日期倒序，每个 release 标题 + 分类列表。

## [Unreleased] — v0.5.0 candidate

### Features
- Settings 视觉统一：themeMode / accentColor / cardDensity / attachmentPolicy 4 处原生 Picker → DSPicker amber-rim glass，与日式美术馆设计语言一致
- 离线同步队列：网络受限时暂存 memo，恢复后自动 flush（SyncQueueService + Today banner + Settings "模拟离线" 调试）
- 时光胶囊（On This Day）：每天打开自动显示"1 年前的今天"/"6 个月前"，点击跳归档
- 周回顾（Weekly Recap）：周一 02:00 后台自动 LLM 编译上周日记成 keyword + mood + places + highlights；Today preview + Archive 详情入口
- Settings 实验功能 section：8 个 FeatureFlag toggle，dogfood 用户可选择性启用/关闭新功能
- 录音中断处理：电话/Siri 打断录音时自动暂停 + 结束后 .shouldResume 自动恢复
- Widget 加 systemMedium 尺寸 + 最近 memo 摘要
- Entity 页 backlinks "被 N 个 memo 引用"区块
- 2am 编译成功本地通知 + Settings 开关

### Bug Fixes (CRITICAL)
- RawStorage replaceItemAt 静默写入失败 → 错误传播
- LocationService 双 resume 卡死 / group.next()! 崩溃
- VoiceService AVAudioSession 未释放 → defer 释放
- CompilationService.applyMemoUpdates 吞错 → 返回 (updated, failed) + Sentry breadcrumb
- Onboarding 权限页不会重新轮询 → scenePhase=.active 实时 poll
- Submit 失败 draftText 丢失 → 错误 toast + retry + 保留草稿
- App kill 时 draftText 丢失 → SceneStorage + UserDefaults 双写持久化
- GraphView 30fps Timer → CADisplayLink（拖拽流畅度提升）
- LocationService 反向地理编码 LRU 缓存（10/30min/~1km bucket）

### UX Polish
- Memo 滑动操作单次左滑同时露出 SHARE+DELETE + contextMenu 兜底
- Graph 搜索 0 结果 glass toast 反馈
- WriteSheet 自动聚焦（80ms 后 isFocused=true）
- API key Settings 显示加 mask + eye toggle
- 录音界面 25+ Color.white → DSColor.recordingSurface/onRecording/warnAmber token
- PosterTemplates 5 套调色板 dynamicProvider 暗色适配
- Archive 月度 Section 分页（首次滚动从 1-2s 冻结优化）
- Memo.yamlQuote 转义重写（emoji + 引号 + 反斜杠 round-trip）
- Today 顶部 banner 堆叠保护（bannerCount<2/3 避免埋 composer）

### Internal / Engineering
- FeatureFlag 框架（UserDefaults 后端 + Settings 实验功能 section）
- SwiftLint 接入 CI（非阻塞 baseline）
- Sentry breadcrumb level 全量纠正（37 处 audit + 3 处新增上报点）
- i18n 累计补 90+ 个 key（zh + en parity 595/595）
- a11y label/hint 全覆盖（SwipeAction / AI banner / Graph 节点 / Entity backlinks）
- 9 个测试套件 55 个 case 全 pass

## [v0.4.0] — 2026-06-20
已有的旧 changelog 或 commit 历史。
