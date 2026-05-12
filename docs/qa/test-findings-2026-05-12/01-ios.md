# DayPage iOS 深度测试报告

测试设备：iPhone 17 (iOS 26.4 Simulator, UDID `0E035415-6A85-49B7-BE8C-009EC3E0AB00`)
测试日期：2026-05-12
报告类型：基于已有 23 张截图 + 源码静态审计 + Vault 文件实测的补写报告
报告人：iOS QA agent (接力补写)

---

## 一、构建状态

| 项目 | 结果 |
|---|---|
| 命令 | `xcodebuild -scheme DayPage -destination 'platform=iOS Simulator,name=iPhone 17' build` |
| 结果 | **BUILD SUCCEEDED** ✅ |
| Xcode SDK | iPhoneSimulator26.4 |
| 警告 | 未在 tail 输出中暴露（pipeline 末尾正常） |
| 错误 | 无 |
| SPM 依赖 | swift-clocks / swift-concurrency-extras / swift-http-types / xctest-dynamic-overlay / Sentry / Supabase — 项目实际引入了 SPM，与 `CLAUDE.md` "no SPM dependencies" 描述**不一致**，文档需更新 |

Vault sandbox 实测（路径 `~/Library/Developer/CoreSimulator/Devices/0E035415-.../data/Containers/Data/Application/ABE582AB-.../Documents/vault/raw/`）：
- `2025-05-12.md`（907B，On This Day fixture）
- `2026-05-04.md`（旧种子）
- `2026-05-12.md`（1120B，4-memo 测试 fixture）
- `assets/`（空）

`2026-05-12.md` 包含 3 个 `<!-- daypage-memo-separator -->` 标记（即 4 条 memo）和 8 个独立 `---` 行（YAML front-matter 边界）。

---

## 二、问题清单

### 🚨 P0 — 阻塞

**P0-1 / Today 视图在多次截图中渲染为空白（仅状态栏）**
- 证据：`04-today-fresh-launch.png` (11:18)、`05-today-with-memos.png` (11:19)、`07-today-clean-data.png` (11:21)、`13-today-with-onthisday.png` (11:36)、`18-system-light.png` (11:40) — 5/23 张整屏只有 iOS 状态栏（时间 + Dynamic Island + WiFi/电池），DayPage 内容区无像素。
- 文件大小线索：这些"空白"PNG 都只有 ~74KB，正常截图 1.2–2.2MB → 不是裁剪问题，SwiftUI 真没画。
- 复现：fresh launch / 清数据 / deeplink 切换后回到 Today 都可能触发。
- 源码线索：`RootView.swift:34-78` 用了 3 个 fullScreenCover（auth / welcome）+ 多个 `@State` 同步从 UserDefaults 初始化，注释提到曾经发生 transient nil session（issue #221 / RC1/RC3 修复）。这套 cover 链路在 fresh launch 路径下仍有概率把 mainContent 卡在透明态。
- 影响：用户开 app 看到空白屏 → 直接卸载。

**P0-2 / Memo parser 在某些时序下崩坏，YAML front-matter 泄漏到正文**
- 证据：`06-today-after-wait.png`、`08-today-wait-more.png`（11:19–11:21，状态为 1 NOTE）卡片正文中肉眼可见：
  ```
  简单文字 memo — 测试普通短文本。
  ---
  ---
  id: 22222222-2222-2222-2222-222222222222
  type: text
  created: 2026-05-12T04:00:00.000Z
  device: "iPhone"
  attachments: []
  ---
  包含 emoji 的测试...
  ```
  4 条 memo 被合并成 1 条，第 2–4 条的 YAML header 当成 Markdown 正文渲染。
- vault 实测：磁盘上 `2026-05-12.md` 包含 3 个 `<!-- daypage-memo-separator -->` → 分隔符**已正确写入**，UI 却只识别为 1 NOTE。
- 源码定位：`DayPage/Storage/RawStorage.swift:115-131` 中 `parse(fileContent:)` 优先检查 `contains(memoSeparator)`，分支理论 ok；但同帧还出现 `empty.compile_locked.*` 文案（1<3 触发 compile-gate），说明该帧 memo count 真的等于 1。怀疑写入完成与文件 reload 之间存在窗口，`splitAndParse` 在窗口内把整个文件当成单条 memo 处理（trimmed 单分支提前返回）。
- 影响：用户看到自己的存档变成乱码 → 数据看似损坏 → 严重信任损失。

**P0-3 / 整套 i18n key 在多个屏幕上原文裸露**
- 证据：
  - `01-launch.png` / `02-today-empty.png` / `02b-today-iphone17.png` / `03-today-dark.png`：`empty.today.no_signals.title` + `empty.today.no_signals.subtitle`
  - `06-today-after-wait.png` / `08-today-wait-more.png`：`empty.compile_locked.title` + `empty.compile_locked.subtitle`
- 文件确认：`DayPage/Resources/zh-Hans.lproj/Localizable.strings:9-14` 和 `en.lproj/Localizable.strings:9-14` 都有对应翻译。`L10n.swift:13-19` 混用 `LocalizedStringKey(...)` 与 `NSLocalizedString(...)`。
- 根因怀疑：
  1. `.lproj` 文件夹未被注册为 Localization，或没加入 Copy Bundle Resources phase；
  2. 或 `knownRegions` 在 project.pbxproj 配置不完整，导致 fallback 不到 base；
  3. en 版也漏 → 至少 `.strings` 根本没进 bundle。
- 影响：所有空状态屏 / 空数据屏的文案直接是 key 字符串 — **unshippable**。

### 🔴 P1 — 严重

**P1-1 / 深浅色模式完全失效**
- 证据：`03-today-dark.png` 号称 dark 但渲染为浅色；`15-today-dark.png` / `16-today-dark-wait.png` / `17-system-dark-app-dark.png`（系统+app 都 dark）全部仍是浅米色。
- 源码：`RootView.swift:25-32, 79` `resolvedColorScheme` 从 `AppSettings.themeMode` 取，通过 `.preferredColorScheme(...)` 应用；但 `TodayView.swift:53` 的 `AmbientBackground()` 可能没有 dark token；`DSColor` 是否对 inkPrimary / glassStd / glassRim 提供 dark variant 需排查。
- 影响：dark 模式用户视觉违和；接入系统主题失败。

**P1-2 / 启动时序导致 Today 首帧只显示 loading spinner**
- 证据：`15-today-dark.png` 11:38 — 标题区正常但中部 hero 只显示一个小 loading 圈，"Today's Page Compiled" 卡片缺失。一分钟后 `16-today-dark-wait.png` 11:39 同视图完整。
- 根因：`TodayViewModel` 的 vault 异步读取 + AI 编译卡片加载 + On This Day 调度可能没合并 loading state，初次渲染只显示部分组件。
- 影响：用户首屏看到不完整状态 → 误以为没数据。

**P1-3 / Onboarding 中英文文案混排**
- 证据：`12-onboarding-fresh.png` — 标题 "DayPage" + slogan "Dump today, let AI compile tomorrow"（英文）+ 按钮 "开始"（中文）。
- 影响：品牌信号混乱。

**P1-4 / 顶部 chrome 残留系统返回链 "◀ Settings"**
- 证据：`09-today-newsep.png` / `09-top-zoom*.png` / `10-after-deeplink.png` 顶部紧贴 iOS 状态栏出现 "◀ Settings"，同时 app 自己也有 header → 双标题双返回。
- 影响：信息架构混乱。

**P1-5 / 时区/时间戳显示不一致**
- 证据：`09-today-newsep.png` 中 voice memo 33333333 在 vault 是 `2026-05-12T05:30:00Z`（北京 13:30），但卡片右上角显示 `TODAY · 11:30`，而底部 "11:30 voice" 标签又一致 — 多个 timestamp 渲染规则混用，且与 ISO 时间不对应。
- 影响：用户对时间记录的信任受损。

### 🟡 P2 — 重要

- **P2-1 / 双 "Tuesday" 标题**：`01-launch.png` 左上角 serif "Tuesday / MAY 12 · 11:05"，正中又有大字 "Tuesday / 12 MAY · 0 SIGNALS" — 视觉冗余。
- **P2-2 / 输入栏底部 copy 质量差**：`01-launch.png` "单击打开滑音盘  ·  长按发送语音"，"滑音盘"翻译怪异；与中央 mic 按钮挤压。
- **P2-3 / Header subline 缺时间制信息**："MAY 12 · 11:05" 看不出 24h/AM。
- **P2-4 / 详情页 metadata 字段语言混杂**：`10-after-deeplink.png` CREATED/KIND 英文风格，PLACE/WEATHER 中文 — 区域不统一。
- **P2-5 / 详情页 "Open in Apple Maps" 仍英文**：同图，i18n 不彻底。
- **P2-6 / "正在编辑 4 条 memo" pill 语义不清**：`09-today-newsep.png` 底部 pill 像 banner 又像 toast，用户不知为何 4 条全在"编辑"。

### 🔵 P3 — 优化

- **P3-1** Hero orb "0 / SIGNALS TODAY" 在 0 memo 状态视觉权重过重，可换 empty illustration（`02-today-empty.png`）。
- **P3-2** `09-top-zoom.png` 与 `09-top-zoom2.png` 二进制完全相同（133335 bytes）— 测试脚本重复采集。
- **P3-3** 详情页地图占 ≈1/3 屏（`10-after-deeplink.png`），可折叠或缩小默认高度。
- **P3-4** `state.png` 与 `10-after-deeplink.png` 二进制相同（1386912 bytes）— 测试残留临时文件。
- **P3-5** 输入条 +/🎙/Aa 按钮视觉重量差异大，可加 hover/pressed 反馈。
- **P3-6** Settings 齿轮 28pt 在浅色背景下几乎看不见，加深 stroke / 阴影。
- **P3-7** `CLAUDE.md` "no SPM dependencies" 与实际依赖矛盾，需更新。

---

## 三、按维度分类

### 视觉 / 样式
- P1-1 dark/light 失效
- P2-1 双 "Tuesday"
- P2-3 时间显示
- P3-1/P3-5/P3-6 hero、按钮、settings 齿轮

### 交互
- P0-1 fresh launch 空白屏（cover stacking）
- P1-2 首帧 loading 不完整
- P1-4 系统 "◀ Settings" 与 app header 共存
- P2-6 "正在编辑 4 条 memo" 语义不清

### 功能（持久化 / AI 编译 / 定位天气语音 / 后台任务）
- P0-2 memo parser 时序崩坏，YAML 泄漏
- P1-5 timestamp 时区不一致
- 正面：vault YAML front-matter 写入符合 `Memo.swift` schema（cat 已验证）
- 正面：Memo 详情页 LOCATION 反向地理 + WEATHER 缓存 + Coordinate 正常
- 正面：Today's Page Compiled 卡片在编译完成后正常显示（14/16/17）

### 性能
- P1-2 启动到内容完整可见 ≈ 60s（15 → 16 时间差），过长
- 多张 ~74KB 空白截图暗示渲染管线偶发 stall

### 可访问性
- `TodayView.swift:76-77` 已 `accessibilityLabel("Open navigation")` + identifier — good
- P0-3 i18n 失败时 VoiceOver 会读 raw key → 灾难

### 深浅色模式
- P1-1 全部 dark 截图都是 light 渲染
- 17 系统暗+app 暗双重设置仍 light → 完全失效

### Onboarding 流程
- P1-3 中英混排
- `11-onboarding.png` 实为 iOS 系统 "Open in DayPage?" 对话框，非 app 内容
- `12-onboarding-fresh.png` 真正的 onboarding 第 1 页可用

---

## 四、改进建议（按优先级）

1. **【立即】修复 i18n bundle 注册（P0-3）**
   - 验证 `project.pbxproj` `knownRegions = ["en", "zh-Hans", "Base"]`
   - 确认 `*.lproj/Localizable.strings` 加入 Copy Bundle Resources phase
   - 测试 `xcrun simctl get_app_container booted com.daypage.DayPage app` 进 .app 看 `en.lproj/Localizable.strings` 是否存在
   - 长期：写 unit test 枚举所有 `LocalizedStringKey`，缺 key 报错

2. **【立即】排查 fresh launch 空白屏（P0-1）**
   - 在 `RootView.swift` mainContent 外加 debug Color 背景验证 ZStack 是否参与布局
   - log onAppear 时 hasOnboarded / showAuthSheet / hasSeenWelcome 三个 State 取值
   - 把 cover binding 改成单一 enum-driven state，避免三个 bool 互相干扰

3. **【立即】修复 memo parser（P0-2）**
   - 读 `RawStorage.swift:131+` `splitAndParse` 完整实现
   - 加 unit test：4-memo + 3-separator fixture，断言 `parse` 返回 4 条
   - 排查 reload 与 write 的并发性

4. **【高】恢复 dark mode（P1-1）**
   - 排查 `DSColor` 是否对 inkPrimary / glassStd / glassRim 提供 dark variant
   - 用 SwiftUI `_printChanges()` 验证 `.preferredColorScheme` 传到 children

5. **【高】统一 onboarding 语言（P1-3）+ 顶部 chrome 清理（P1-4）**

6. **【中】统一 timestamp / 时区（P1-5、P2-3、P2-4）**

7. **【低】文档同步（P3-7）**

8. **【流程】补 UI 截图 baseline + diff**
   - Today/Archive/Graph × light/dark × empty/with-memos × en/zh = 24 张 baseline，每 PR diff

---

## 五、截图清单（23 张）

| # | 文件 | 时间 | 内容 | 关键问题 |
|---|------|------|------|---------|
| 01 | 01-launch.png | 11:06 | Today 空状态 + i18n key 裸露 | P0-3 |
| 02 | 02-today-empty.png | 11:11 | 同 01 | P0-3 |
| 02b | 02b-today-iphone17.png | 11:11 | iPhone 17 Today 空状态 | P0-3 |
| 03 | 03-today-dark.png | 11:15 | 号称 dark 实际 light + i18n key | P0-3 + P1-1 |
| 04 | 04-today-fresh-launch.png | 11:18 | **全屏空白** | P0-1 |
| 05 | 05-today-with-memos.png | 11:19 | **全屏空白** | P0-1 |
| 06 | 06-today-after-wait.png | 11:19 | 1 NOTE，YAML 泄漏 + compile_locked key | P0-2 + P0-3 |
| 07 | 07-today-clean-data.png | 11:21 | **全屏空白** | P0-1 |
| 08 | 08-today-wait-more.png | 11:21 | 同 06 | P0-2 + P0-3 |
| 09 | 09-today-newsep.png | 11:30 | 4 NOTES 正常列表 + "◀ Settings" 顶链 | P1-4 + P2-6 |
| 09z | 09-top-zoom.png | 11:31 | 顶部 "◀ Settings" 放大 | P1-4 |
| 09z2 | 09-top-zoom2.png | 11:31 | 同 zoom（二进制相同） | P3-2 |
| 09z3 | 09-top-zoom3.png | 11:31 | 顶部 chrome 缩略 | 验证 |
| 10 | 10-after-deeplink.png | 11:33 | Memo 详情页：map + metadata | P2-4 + P2-5 |
| 11 | 11-onboarding.png | 11:34 | 系统 "Open in DayPage?" 对话框 | 非 app 内容 |
| 12 | 12-onboarding-fresh.png | 11:35 | 真正的 onboarding 第 1 页 | P1-3 |
| 13 | 13-today-with-onthisday.png | 11:36 | **全屏空白** | P0-1 |
| 14 | 14-today-wait6.png | 11:37 | 4 NOTES + Today's Page Compiled 卡片 | 正常 |
| 15 | 15-today-dark.png | 11:38 | 号称 dark 实际 light + 只显示 loading spinner | P1-1 + P1-2 |
| 16 | 16-today-dark-wait.png | 11:39 | 等 1 min 内容完整（仍 light） | P1-1 |
| 17 | 17-system-dark-app-dark.png | 11:40 | 系统+app 都 dark 但渲染仍 light | P1-1 |
| 18 | 18-system-light.png | 11:40 | **全屏空白** | P0-1 |
| - | state.png | 11:33 | 同 10（二进制相同） | P3-4 |

正常渲染：02、09、10、14、16；
空白渲染：04、05、07、13、18（5 张，P0-1）；
i18n key 暴露：01、02、02b、03、06、08；
渲染样式异常：03、15、17（dark 失效）。

---

## 六、Summary

构建通过（BUILD SUCCEEDED），无错误。
功能层共发现 **3 个 P0** + **5 个 P1** + **6 个 P2** + **7 个 P3** = 21 个问题，
最危险两点：**i18n 整体失效** 与 **fresh launch 偶发空白屏** — 用户拿起手机第一眼即可见的灾难级问题，
**dogfood 前必须修复 P0-1 / P0-2 / P0-3 / P1-1**。
