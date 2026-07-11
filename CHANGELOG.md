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
- 真机体验实测审计（2026-07-11，模拟器全链路 dogfood：多条文本/中文粘贴/相册双图/按住说话逐一实测）：
  - 附件文件名秒级时间戳冲突 → 同一秒多选照片互相覆盖、第二张**永久丢失**（实测 2 张选图只落盘 1 个文件）；assetFilename 追加 4 位随机后缀
  - 照片卡片横向溢出屏幕：PhotoThumbnailView 的 `.fill` 图片把自身超宽尺寸上报穿透 `.clipped()`（AX frame x=-229/w=557），撑爆整卡 → 图片全出血 + 正文左移出屏"被裁"；改为 Color.clear 4:5 容器 + overlay 裁剪
  - 按住说话死锁：0.25s 长按阈值判定写在 DragGesture.onChanged 里，手指完全静止时 onChanged 不再触发 → 永远停在"再按住一下"（实测按住 10s 无法进入录音）；改为 touch-down 启动定时提交
  - 录音启动吃掉按压时长：AVAudioSession setCategory/setActive（冷启动秒级）同步跑在 MainActor → UI 冻结 + 按 4s 只录到 <1s"再说久一点"；移到 Task.detached
  - 多图 memo 只渲染第一张照片（查看器也只开第一张）→ ForEach 全部 photo 附件 + item-based 全屏查看器
  - 空态 orb 点击把时段引导语（"今天最终落在哪里了？"）写进 draftText → 引导语混入 memo 正文永久落盘；改为仅聚焦（与 InputBarV4 移除"记下此刻"预填同一设计准则）
  - EXIF 读取在卡片 body 里同步磁盘 I/O（每次重绘都读）→ 随缩略图解码移到后台
- 侧边栏抽屉面板自身无关闭手势：1:1 跟手 drag 只挂在 scrim 上而 scrim 被 280pt 面板盖住 → 从抽屉上起手左拉纹丝不动、松手才播动画（违反"输入直接驱动位移"）；面板追加水平主导 simultaneousGesture，实测 50%→70% 全程跟手
- 双 agent 深度审计第二轮（主线程 + 手势跟手性）：
  - compile() 准备段（读盘+YAML parse+SHA256+读旧 daily）跑在 @MainActor，20+ memo 的日子点"编译"卡数十 ms → Step 1 整段 Task.detached
  - WikiIndexService.rebuild() 编译尾部在主线程全量扫 wiki 目录逐文件解析 frontmatter（数百页 50–300ms）→ fire-and-forget detached + scan 函数 nonisolated 化
  - 录音波形 40 根 bar 各自 easeOut 隐式动画去追 30fps 电平（"触发动画去追"反模式）→ 删除逐 bar 动画，高度直接映射电平
  - Today/Archive 各挂一个 onEnded-only 左缘开抽屉手势，与 RootView 的 1:1 跟手版竞争仲裁（赢了就变成松手弹出）→ 删除，统一走 RootView
  - MemoDetailView 两处 EXIF 在 body 里同步 CGImageSource 磁盘 I/O（每次重绘都读）→ @State + .task 后台解析
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
- 侧边栏深度优化（2026-07-11）：热力图 16×7 网格 Canvas 化（≈800 视图节点 + 112 手势 → 单次绘制，网格数据缓存仅随 counts 变化重建，消除开抽屉/拖拽卡顿）；drawer 阴影前加 compositingGroup 让 20pt 模糊在栅格化层上合成；Recent 列表改默认收起的可展开行（@AppStorage 记忆偏好）
- 登录链路美术馆化（2026-07-11）：AuthView serif 词标 + mono kicker + 交错入场编排（尊重 Reduce Motion）、品牌区居中/CTA 底部锚定的确定性布局；Email 输入框 amber focus 环；OTP 激活格与光标改 amber accent；三页标题统一 serif
- 设计审计 R5（2026-07-10，评分 6.7→9.3）：图谱标签/点击/自动适配错位修复（过滤缓存只存节点 ID）、缩放控件面板不再全宽盖住画布、编译日记页双返回键与偶发空白修复（isEmbedded 拆嵌套栈）、日详情元数据卡改用当天真实数据（删除 28°/86% 假默认值）、日记正文 wikilink 显示为可读名称
- 设置页回归暖色品牌（浅/深色），API key 未配置改单一胶囊标注，「那年今日」中文化
- 录音页操作栏中文化（暂停/丢弃/保存）并圆角化；输入栏定位 chip 显示「解析地名中…」而非裸经纬度
- 归档总览统计加 ALL-TIME 范围词，与月度 TOTAL ENTRIES 口径区分；侧边栏 Recent 相对日期跟随界面语言
- Today 横幅下移至头部行以下不再遮挡导航；CJK 草稿计数器单一化（字符数）
- Wave 4 收尾：页面背景 token 三源合一（消除深色拼接接缝）、DSPicker 选项切换触感、侧边栏行 tapConfirm、Archive 派生集合缓存
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
