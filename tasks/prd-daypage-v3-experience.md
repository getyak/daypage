# PRD: DayPage v3 体验升级（从 Demo 到产品）

> **生成日期**：2026-04-17
> **来源**：用户反馈（"流程多余 / 视觉像 demo / 编译一直出错 / 语音转写丢数据 / 不够懂我"）+ 代码深度审计 + 设计对标（Bear / Notion / Flomo）
> **目标版本**：DayPage v3.0（与 v2 roadmap 并行推进，v3 聚焦"体验"，v2 聚焦"功能完整"）
> **状态**：**待主理人拍板 Open Questions 后进入 Wave 拆分**

---

## 1. 为什么要有这份 PRD（背景）

DayPage v2 roadmap（`tasks/prd-daypage-v2-roadmap.md`）覆盖了 24 个**功能向** issue（修死链、补接线、加实体图谱）。但用户实际使用后反馈的核心痛点**不是功能缺失，而是体验不顶级**：

- **"很多流程多余"** —— 输入流要点 5 次按钮才能记一条语音；附件要经过 5 步
- **"视觉像 demo 不像产品"** —— Brutalist 极简被做成了"信息窒息"：2 级字号、纯黑、0 圆角、无呼吸感
- **"编译一直出错，不知道为什么"** —— CompilationService 错误类型齐全但 **Today View 没有任何 user-facing 反馈**
- **"语音转写有 bug"** —— 录 5 秒只显示前 3 秒（根因已锁定到行号）
- **"不够懂我、没惊喜时刻"** —— 没有 On This Day、没有随机漫步、没有位置/天气/时间联动洞察

这份 PRD **不是** v2 roadmap 的替代，而是 **正交的 v3 主线**，回答一个问题：

> 怎么让一个 nomad 用户打开 DayPage 时，觉得"这是我的日志"，而不是"这是个工具"？

---

## 2. Goals

### 产品目标
- **G1（去摩擦）**：核心记录动作（文字/语音/照片）从"5 步"压缩到"2 步"
- **G2（有温度）**：配色、字体、留白、微交互达到 Bear / Flomo 同级视觉质感
- **G3（可信任）**：编译失败、语音失败、网络失败 **永远有 user-facing 反馈和重试路径**
- **G4（语音可靠）**：语音转写 100% 完整，不再丢后半段
- **G5（有惊喜）**：引入 3 个"懂我时刻"：On This Day、Random Walk、环境模式识别

### 量化目标
| 指标 | 基线 | 目标 |
|---|---|---|
| 文字记录操作步数 | 3 步（聚焦输入框→打字→发送） | 保持 2-3 步 |
| 语音记录操作步数 | 5 步（点麦→弹模态→录→保存→返回） | 2 步（长按发送键录音→松手保存） |
| 语音转写完整率 | 约 60%（3/5 秒） | 100%（Whisper 保底） |
| 编译失败静默率 | 100% | 0 |
| 编译自动重试覆盖 | 仅后台 | 前台 + 后台均覆盖 |
| 字号层级 | 2 级 | 5 级（Display/H1/H2/Body/Caption）|
| 硬编码颜色数 | 12 处 | 0 处（全部走 DSColor token）|
| On This Day 触发率 | 0 | ≥ 15%（有历史数据时）|

---

## 3. 五条主线 & Wave 划分

| Wave | 主线 | Issue 数 | 估时 | 核心价值 |
|---|---|---|---|---|
| **V3-W1** | 🔴 **可信任地基**（编译反馈 + 语音修复） | 5 | 1 周 | 让用户敢用 |
| **V3-W2** | 🟠 **流程精简**（输入栏重构 + 语音重做） | 4 | 1-2 周 | 记录无摩擦 |
| **V3-W3** | 🟡 **视觉升级**（配色 / 字体 / 留白 / 微交互） | 6 | 2 周 | 从 demo 到产品 |
| **V3-W4** | 🟢 **懂我时刻**（On This Day / Random Walk / 模式洞察） | 4 | 2-3 周 | 产生情绪价值 |
| **V3-W5** | 🔵 **空状态 + 首次体验**（引导 + 示例 memo） | 3 | 1 周 | 首次打开不陌生 |

**排序依据**：先修信任（W1）→ 再去摩擦（W2）→ 再提质感（W3）→ 最后造惊喜（W4-W5）。任何一步跳过前置都会被用户投诉"还是老问题"。

---

## 4. User Stories + 验证标准

### 🌊 V3-W1：可信任地基（最优先）

#### V3-001: 语音转写数据丢失根治（Critical）

**现象**：录 5 秒，实时转写只显示前 3 秒，保存后最终结果也只有前 3 秒。

**根因**（已通过代码审计锁定到行号）：
- `VoiceService.swift:193-205` — `recognitionTask` 一旦触发 error（SFSpeechRecognizer 对中文/静音易触发中间 error），立刻 `stopLiveTranscription()`。**但 AVAudioRecorder 仍在录音**，后续音频不再进识别器。
- `VoiceService.swift:270-276` — `stopAndTranscribe()` 里只要 `liveTranscript` 非空就**不回退到 Whisper**，直接用这个**残缺的**实时转写作为最终结果。
- `VoiceService.swift:264` — `capturedLiveTranscript` 在 `stopLiveTranscription()` 之前捕获，最终 `recognitionTask` 回调可能未执行完。

**期望行为**（✅ 已确认方案 A）：
- **去掉实时转写**：录音界面只显示波形 + 时长 + "松手发送 / 上滑取消"文案。停止后 **100% 走 Whisper API**。
- 删除 `VoiceService.swift` 中的 SFSpeechRecognizer / AVAudioEngine 相关代码（约 80 行，line 74-78, 156-217, 236, 252, 264）。
- 删除 `liveTranscript` @Published 属性及其在 `VoiceRecordingView` 里的 UI 绑定。
- 移除 `Info.plist` 中的 `NSSpeechRecognitionUsageDescription`（不再需要这个权限）。
- `stopAndTranscribe()` 只有一个路径：`await transcribeAudio(at: fileURL)`。
- Whisper 请求超时和重试沿用现状（60s / 3 次）。

**验证标准**：
- [ ] 录 5 秒中英混合（"今天我去了 coffee shop"）→ 最终 memo body 包含完整 5 秒内容
- [ ] 录 30 秒连续说话 → 最终 memo body 完整
- [ ] 录音中途点暂停再恢复，最终内容不丢失
- [ ] 离线录音 → 音频文件保存、transcript 为 nil、memo body 显示"离线录音，连网后将自动转写"+ 待转写队列可见
- [ ] 真机验证（Simulator 的 SFSpeechRecognizer 行为与真机差异大）

**技术备注**：
- 录音按钮松手后，Today 列表里**立刻插入一张 pending memo 卡片**（skeleton 样式，显示"转写中..."），Whisper 返回后替换 transcript。用户不用等在模态里。
- 离线录音的处理见 V3-004（队列）。
- 真机验证必做：iOS 模拟器 AVAudioRecorder 行为与真机不同，Whisper 请求时延也不一样。

---

#### V3-002: 编译错误必有反馈（Critical · 主场景：网络连接失败）

**现象**：用户反馈"编译一直出错，不知道为什么"。✅ 已确认主场景是**网络连接问题**——请求 DashScope 时超时 / 连接失败 / 间歇性不稳定。

**根因**：
- `CompilationService.swift:460-489` 定义了 6 种 `CompilationError`（含 `networkError`），都有 `localizedDescription`。
- 但 Today View **没有错误 Banner 组件**。`networkError` 抛出后只进 `log.md`（还是用 `try?` 吞掉的），用户完全看不到，只看到"什么都没发生"。
- 前台手动编译**无重试**（`CompilationService.swift:269-309`），一次网络抖动直接失败。
- `URLSession.shared` 默认 60s 超时，在弱网下用户以为卡死。
- `appendLog` / `updateHotCache` 用 `try?` 吞异常（line 162 / 397）。

**期望行为**（针对"网络问题"重点设计）：

1. **编译前先预检网络**（轻量）：
   - 调 DashScope 前先用 `NWPathMonitor` 判断网络状态
   - 完全离线 → 直接蓝色 Banner "当前离线，已加入队列，联网后自动编译"（进入 V3-004 队列），**不发请求**
   - 在线 → 正常发请求

2. **编译中反馈**（进度透明）：
   - Today View 顶部**蓝色横幅**："正在编译你的今天..."+ 进度点动画
   - 耗时 > 5s → 追加副文案 "网络较慢，请稍候..."
   - 耗时 > 15s → 出现"取消"按钮
   - 横幅**不阻塞**输入（可继续记 memo）

3. **网络失败自动重试**（最重要）：
   - 捕获 `networkError` / `URLError.timedOut` / `URLError.notConnectedToInternet` / 429 / 5xx
   - 前台自动重试 **2 次**（backoff：2s、6s），参考 `BackgroundCompilationService.swift:137`
   - 每次重试横幅文案更新："正在重试（2/3）..."
   - 重试期间保持蓝色（不闪红）

4. **最终失败才显红**：
   - 3 次都失败 → 红色横幅 "编译失败：网络不稳定" + **两个**按钮：[立即重试] [稍后自动重试]
   - "稍后自动重试" → 加入 V3-004 的重试队列，联网自动重跑
   - 点 [立即重试] → 走一次完整流程

5. **非网络错误区分显示**：
   - `missingApiKey` → 红色横幅 "DashScope API Key 未配置"，按钮 [前往设置] → Settings
   - `parseError` → 红色横幅 "AI 返回格式异常，已记录日志" + [查看日志] 按钮（超小概率，不给重试）
   - `apiError(401)` → 红色横幅 "API Key 无效或过期" + [前往设置]

6. **成功反馈**：
   - 绿色横幅 "今日 Daily Page 已生成" + 副文案 "点击查看" → 3s 自动消失
   - 点击跳转 Daily Page

7. **try? 全清**：
   - `appendLog` (line 162) / `updateHotCache` (line 397) 改为 `do { try } catch { DayPageLogger.error(...) }`

**验证标准**：
- [ ] **飞行模式开启** → 点编译 → 立即蓝色 Banner "当前离线，已加入队列..."（不看到任何网络请求日志）
- [ ] **弱网（Charles 限速 3G）** → 点编译 → 蓝色 Banner → 5s 后追加"网络较慢" → 可能重试 1 次 → 最终成功或 3 次失败红色 Banner
- [ ] **断网（编译中拔网）** → 自动重试 2 次（横幅显示"正在重试（2/3）"）→ 失败显红 → 恢复网络后点 [立即重试] 成功
- [ ] **API Key 留空** → 红色 Banner "未配置" → 点击跳 Settings
- [ ] **编译中横幅不阻塞输入**，可继续记新 memo
- [ ] **后台编译失败通知**（v2 US-201）与**前台横幅**不双重打扰（前台有横幅时后台静默）
- [ ] 3 次重试全失败的日志在 `vault/logs/app.log` 完整（含状态码 / 错误描述 / 请求耗时）

---

#### V3-003: API Key 全局健康检查 Banner

**期望行为**：
- App 启动检查 DashScope / OpenAI / OpenWeather 三个 key
- 任一缺失 → Today View 顶部灰色 Banner "X 个功能未配置 → 前往设置"
- 点击跳转 Settings，缺失项红色徽章
- 所有都配置好 → Banner 自动消失

**验证标准**：
- [ ] 删除 `GeneratedSecrets.swift` 中任一 key，启动 → Banner 出现
- [ ] 点 Banner → 跳转 Settings 正确分区
- [ ] 配好后重启 → Banner 消失

---

#### V3-004: 语音/网络离线队列

**期望行为**：
- 离线录音 → 音频保存到 `vault/raw/assets/`，memo 写入但 `transcript` 为 nil + `pendingTranscription: true`
- Today View 顶部灰色 Banner "你有 N 条待转写"
- 网络恢复 → 后台自动轮询转写队列，转写成功后写回 memo 并更新 UI

**验证标准**：
- [ ] 飞行模式录 1 条语音 → memo 卡片显示"离线录音，转写中..."
- [ ] 关闭飞行模式 → 30s 内 memo 卡片 transcript 出现
- [ ] 3 次失败的 memo 进入"失败队列"，Settings 中可手动重试

---

#### V3-005: 修复 try? 吞异常

**期望行为**：
- 所有 `try?` 替换为 `do { try ... } catch { log.error(...) }`
- 新建 `DayPageLogger.swift`，落盘到 `vault/logs/app.log`
- Settings 添加 "查看最近错误日志"（最后 100 行）

**验证标准**：
- [ ] 代码扫描：`try?` 出现次数 ≤ 2（仅用于"真正不 care 的场景"，如清理临时文件）
- [ ] 触发一次编译失败 → `vault/logs/app.log` 包含完整错误
- [ ] Settings "最近错误日志" 页可见本次错误

---

### 🌊 V3-W2：流程精简

#### V3-101: 输入栏按钮合并到 `/` 浮窗

**现状**：`InputBarView.swift:87-126` 输入框右侧挂了 4 个按钮（麦克风 / 相机 / 文件 / 位置 / 发送），视觉噪音，首次用户不知道长按还是短按。

**对标**：Flomo 只有一个输入框 + 发送；Notion 用 `/` 唤起 command palette。

**期望行为**：
- 输入栏默认只有**一个文本框 + 一个发送按钮**（状态：空时灰，有字时 accent）
- 在输入框开头敲 `/` → 浮现 CommandPalette：[🎙️ 语音] [📷 相机] [🖼️ 相册] [📎 文件] [📍 位置]
- 或：**长按发送按钮 → 语音录制**（最高频场景直通）
- 或：从键盘上方 QuickBar 提供同样 5 项（可选实现）

**验证标准**：
- [ ] 输入栏视觉上只有 1 个文本框 + 1 个发送按钮
- [ ] 输入 "/" 触发 palette，选项顺序按使用频率（可记忆）
- [ ] 长按发送按钮 300ms → 进入语音录制
- [ ] 键盘上方 QuickBar 可选开启（Settings）

---

#### V3-102: 语音录制改"按住说话"模式（废弃全屏模态）

**现状**：`VoiceRecordingView.swift` 是全屏 sheet，打断当前输入焦点。

**对标**：微信 / iMessage 的"按住发送按钮说话"。

**期望行为**：
- 长按发送按钮（300ms+）→ 发送按钮变红、扩大；整个屏幕底部**上浮**一个半屏浮窗，只显示波形 + 时长 + "松手发送 / 上滑取消"
- 松手 → 立即 Whisper 转写；UI 回到输入栏、pending memo 卡片以 skeleton 形式立即出现，transcript 流式填入
- 上滑取消 → 丢弃录音

**验证标准**：
- [ ] 长按 300ms 触发录音，有触觉反馈（haptic light impact）
- [ ] 录音中不覆盖 Today 列表（半屏浮窗 + 列表仍可见但 dim）
- [ ] 松手发送 → 500ms 内 memo 卡片出现（即使 transcript 还在转）
- [ ] 上滑取消 → 无音频文件残留

---

#### V3-103: 附件预览从"占位卡"改"行内 chip"

**现状**：附件选完后出现占位卡片，发送后才变 memo，导致状态二阶。

**期望行为**：
- 选完附件 → 输入框**上方**出现一排 chip（可删除 × ）：🖼️ photo.jpg / 📎 file.pdf / 📍 上海
- 发送 → chips + 文本一起作为一条 memo 写入

**验证标准**：
- [ ] 多个附件同时 chip 展示，可独立删除
- [ ] chip 高度 ≤ 32pt，不挤占输入框

---

#### V3-104: Archive 日期导航合并为"统一详情页"

**现状**：日历点日期 → 判断"已编译 / 未编译 / 空白" → 分别跳转。用户心智负担重（v2 已修，但架构仍分裂）。

**期望行为**：
- 所有日期点击 → 进入 `DayDetailView`
- 页面内部用 segment control 切换：[Daily Page] [原始 memo]
- 未编译日期：Daily Page tab 显示 "点击编译" CTA；原始 memo tab 直接可看
- 空白日期：显示 "这一天没有记录" + 附近可记录日期链接

**验证标准**：
- [ ] 所有日期无论状态都能点
- [ ] 导航栈一致（无"有时 push，有时 modal"）
- [ ] 返回按钮保留滚动位置

---

### 🌊 V3-W3：视觉升级（从 Demo 到产品）

> 整体思路：**不是推翻 Brutalist，是给它加温度**。保留 Space Grotesk 标题 + 全大写的克制感，但底色、留白、层级、微交互全面升级。

#### V3-201: 配色系统升级到"暖白 + 克制 accent"（✅ 已确认暖白方向）

**现状**（`DSColor.swift` 审计）：纯白背景 + 纯黑文字 + 琥珀褐 accent 仅用于 wikilink；12 处硬编码颜色。

**对标**：Bear 暖米白（#F8F5F2）。用户已确认**偏暖、有温度**的方向。

**期望 token**（完整设计系统）：
```
# 背景层（三层递进）
background:        #FAF8F6   页面底 — 奶油白，替代纯白
surface:           #FFFFFF   卡片底 — 与背景形成 2-3% 对比
surfaceElevated:   #FFFFFF   + shadow(0 1 3 0 rgba(0,0,0,0.04))
surfaceSunken:     #F3F0EB   凹陷区（输入框、disabled 状态）

# 文字层（高对比、不刺眼）
onBackground:      #2B2822   正文 — 深棕灰，不是纯黑（对比度 15.3:1，超 AAA）
onBackgroundMuted: #6B6560   元信息（时间戳、chip 文字）
onBackgroundSubtle:#A39F99   placeholder、disabled
onAccent:          #FAF8F6   accent 之上的文字

# 品牌色（保留琥珀褐）
accent:            #5D3000   核心 CTA、wikilink、highlight
accentHover:       #7A3F00   按下态
accentSoft:        #F5EDE3   accent 10% 底色（chip / banner）
accentBorder:      #E8DCCA   accent 虚线 / 边框

# 状态色（暖系化，不要纯红纯绿）
success:           #4C7A3F   柔和绿（而非 iOS 系统绿）
successSoft:       #EBF3E5
warning:           #A66A00   暖橘（编译中 banner）
warningSoft:       #F8ECD6
error:             #A23A2E   红棕（不是纯红）
errorSoft:         #F5E1DC

# Archive 热力图（4 级）
heatmapEmpty:      #F0EBE3
heatmapLow:        #E6D9C3
heatmapMid:        #C9A677
heatmapHigh:       #5D3000

# 边框 / 分割线
borderSubtle:      #EDE8DF
borderDefault:     #D6CEC0
```

**执行清单**：
- [ ] `DSColor.swift` 新增上述 token，删除 / 标记 @deprecated 旧 token
- [ ] 全项目扫描 `Color(hex:` / `.black` / `.white`，替换为 token（12 处硬编码）
- [ ] `Info.plist` 设 `UIUserInterfaceStyle = Light`（暂锁浅色，深色留 v3.1）
- [ ] 更新 `design/stitch/` 设计稿底色（与 Stitch 同步时用新背景）

**验证标准**：
- [ ] 代码扫描 `\.black|\.white|Color\(hex:` → 硬编码颜色 = 0
- [ ] Today View / Daily Page 截图贴在一起：背景**有温度、不刺眼**、卡片有层次（不是"一张纸"）
- [ ] 文本对比度 ≥ 4.5:1（用 Stark / Contrast 插件验证主页面）
- [ ] 与 Bear 截图并排对比：气场同档（不要求复刻）
- [ ] 所有 Banner（V3-002）配色一致，成功/失败/进行中 分辨明显但不刺眼

---

#### V3-202: 字体层级从 2 级扩展到 5 级

**现状**（`Typography.swift` 审计）：DisplayLG 56pt 和 BodyMD 16pt 之间没有中间层级。

**期望 scale**：
```
Display    56pt / Space Grotesk Bold / letterSpacing +0.04em / 用于日期大标题
H1         32pt / Space Grotesk Bold / 用于 Daily Page 标题
H2         22pt / Space Grotesk SemiBold / 用于卡片/section 标题
Body       16pt / Inter Regular / 行高 1.6 / 用于正文
Caption    13pt / Inter Medium / 用于时间戳/元信息
Label      11pt / Space Grotesk Bold 全大写 / 用于 tab/chip
```

**验证标准**：
- [ ] `Typography.swift` 新增 3 个 style
- [ ] 所有硬编码 `.custom("...")` 替换为 DSType token（3 处：VoiceRecordingView:129 / InputBarView:102）
- [ ] Daily Page 视觉上一眼看出"日期 > 标题 > 段落 > 元信息" 4 个层次

---

#### V3-203: 留白 & 行距系统化

**现状**：`MemoCardView.swift:106-210` 卡片内部 padding 12pt，行距 4pt。

**期望**：
- 卡片外边距 20pt / 内边距 20pt / 卡片间距 16pt
- Body 行高 = 字号 × 1.6（16 × 1.6 = 25.6pt line height）
- Daily Page 段落间距 = 16pt
- 圆角：全局引入 12pt（卡片）/ 8pt（小元素）—— **放弃 0 圆角**，保留"硬朗"字体即可

**验证标准**：
- [ ] 8 寸截图对比前后：密度明显降低，阅读压力小
- [ ] Bear 并列对比：气场相近（不要求复刻）

---

#### V3-204: 时间表达情绪化

**现状**（`TodayView.swift:319`）：`"yyyy.MM.dd // HH:mm"` 代码风冷冰冰。

**期望**：
- 当天卡片：左上角 `TODAY  ·  14:23`（"TODAY" 用 Label 样式）
- 昨天：`YESTERDAY  ·  14:23`
- 一周内：`3 DAYS AGO  ·  APR 14`
- 更早：`APR 14, 2026`
- Daily Page 头部大标题：`APRIL 14` + 副标题 "Sunday, 2026"

**验证标准**：
- [ ] 新建 `RelativeTimeFormatter.swift`
- [ ] 覆盖 Today / Archive / Daily Page / Entity Page
- [ ] 英文（用户习惯）保持全大写，Label 样式

---

#### V3-205: 微交互三件套

**现状**：`.animation` / `withAnimation` 全项目仅 6 处。

**期望**：
- **卡片按下**：scaleEffect 0.98 + 深色 overlay（haptic light impact）
- **展开/折叠**：spring(response: 0.4, dampingFraction: 0.8)
- **发送 memo**：发送键 checkmark 动画 + 列表新卡片淡入 + haptic soft impact
- **页面转场**：Today → Daily Page 用 matched geometry（日期文字从 header 飞到标题）

**验证标准**：
- [ ] 关键路径（记录、发送、跳转）都有触觉/视觉反馈
- [ ] 无卡顿（60fps 验证，真机 Instruments）

---

#### V3-206: 空状态重做（附图示）

**现状**（`TodayView.swift:147-151`）：纯文字 "今天还没有记录"。

**期望**：
- Today 空：手绘 icon（羽毛笔）+ "记下今天的第一个观察" + 3 个示例 chip（"今天天气""在哪""在想什么"）→ 点击 chip 自动填入输入框
- Archive 空：日历图 icon + "还没有 Daily Page，随便记几条试试"
- Graph 空：网络图 icon + "记录更多，知识网络会自动生成"

**验证标准**：
- [ ] 3 个 Tab 的空状态都有图形 icon + 引导文案 + CTA
- [ ] 点击示例 chip 真的能跳转

---

### 🌊 V3-W4：懂我时刻

> 这是让用户觉得"这 app 活的"的关键。每一条要**刚好出现在用户需要的时候**，而不是刷屏。

#### V3-301: On This Day（去年的今天）· ✅ 已锁定为 W4 首发

**触发时机**（已确认）：
- **自动触发**：每天按**用户本地时区 00:00** 统一刷新一次（用 `Calendar.current` + `TimeZone.current`）
- **默认时间可在 Settings 配置**：Settings > 外观 / 行为 > "On This Day 刷新时间"，选项：午夜 00:00（默认）/ 清晨 06:00 / 上午 09:00 / 关闭
- **手动触发（隐蔽入口）**：Today View 顶部大日期标题**长按 1.5s**（无可见按钮、无提示文案）→ 触觉反馈 + 立即尝试加载 On This Day；如当日无历史数据则 haptic warning + 不显示任何 UI；**不在任何地方暴露"On This Day 按钮"**
- 一天内只展示一次：自动触发或手动触发过后当日不再自动出现；但手动长按可无限触发（用户主动要）

**期望行为**：
- Today View 顶部出现 "ON THIS DAY · 1 year ago" 卡片（Label 样式标题 + memo 预览 + 时间戳）
- 数据源优先级：
  1. 去年同月同日（365 天前）
  2. 若无 → 半年前同日（180 天前）
  3. 若无 → 两年前同日
  4. 全都无 → 不显示
- 展示内容：该日最长的 memo 预览（body 前 120 字符）+ 原日期 + "Tap to open" 提示
- 点击 → 跳转到对应 Daily Page（未编译则跳原始 memo 视图）
- 右上角小 × 可收起（当天不再自动出现，但手动长按仍可触发）
- Daily Page 不重复出现（只在 Today 顶部一个入口）

**Settings 配置**：
```
On This Day
├─ 自动刷新时间   [午夜 00:00 ▼]
├─ 启用手动长按触发  [开]
└─ 关闭该功能       [关]
```

**数据源**：扫 `vault/raw/YYYY-MM-DD.md` 找同月同日历史文件。
建议启动时异步建索引 `vault/wiki/index.json`（日期 → memo 数 / 最长 memo preview），避免每次扫全量。

**技术备注**：
- 长按入口实现：在 `TodayView` 的大日期文字上加 `.onLongPressGesture(minimumDuration: 1.5)` + `UIImpactFeedbackGenerator(.medium)`
- 时区处理：存下次触发时间戳到 UserDefaults；启动时/进入前台时检查 `Date() >= nextFireAt`，触发后推到明天同一时间
- 用户切时区（出差）：`UIApplication.significantTimeChangeNotification` 监听，重算 nextFireAt

**验证标准**：
- [ ] 人造 2025-04-17 数据 → 今日 Today 顶部自动出现卡片
- [ ] 点击卡片 → 跳转到 2025-04-17 Daily Page
- [ ] 收起后当天不自动出现
- [ ] **长按今日大日期 1.5s** → 触觉反馈 + 立即重新显示（无历史则 haptic warning 且不显示任何 UI）
- [ ] 长按入口**不在 UI 上有任何暗示**（icon / 下划线 / tooltip 都不能有）
- [ ] Settings 里切换刷新时间 → 第二天按新时间触发
- [ ] 飞机上切时区 → 下次触发时间按新时区重算
- [ ] Settings 关闭该功能 → 卡片再也不出现（长按也不触发）

---

#### V3-302: Random Walk（随机漫步）

**期望行为**：
- Archive Tab 右上角新增 🎲 按钮
- 点击 → 随机跳转到一个 7 天前以上的 Daily Page，带 "Random Walk · N days ago" 头部
- 无日期数据时按钮 disabled

**对标**：Flomo "随机漫步" / Day One "Random"。

**验证标准**：
- [ ] 按钮存在且样式与 Archive 其他按钮协调
- [ ] 随机分布合理（不重复最近 3 次结果）
- [ ] 7 天内刚记的不出现（避免"昨天刚看过"）

---

#### V3-303: 环境联动洞察（首版：位置 × 时间）

**期望行为**（MVP 版，先做一条规则）：
- 扫描最近 90 天 location memo：如果"咖啡馆"类地点 ≥ 5 次且时间集中在上午 → Daily Page 底部出现 "💡 你已连续 N 天在 咖啡馆 / 早晨 记录"
- 出现频率：每周最多 1 条洞察

**验证标准**：
- [ ] 造 5 条"上海某咖啡馆"memo 横跨 5 天 → 第 5 天 Daily Page 底部出现洞察
- [ ] 无足够数据时不出现（不要硬塞假洞察）

---

#### V3-304: 智能输入建议 Chip

**期望行为**：
- Today 输入框为空且最近 30min 没记录时，显示 3 个建议 chip：
  - 根据时间：`今天天气` / `现在在哪` / `吃了什么`（早/中/晚不同）
  - 根据位置：`刚到【XXX】` / `离开【XXX】`
  - 根据天气：`今天下雨了` / `难得晴天`
- 点击 chip → 填入输入框（可继续编辑）

**验证标准**：
- [ ] 9:00 打开显示"今天计划"相关建议
- [ ] 到达新地点 15 分钟内显示"刚到 XXX"
- [ ] 点击后不立即发送，进入编辑状态

---

### 🌊 V3-W5：首次体验

#### V3-401: 首次启动引导（3 屏）

**期望**：
- 屏 1：欢迎 + 核心价值一句话
- 屏 2：3 个权限申请（麦克风 / 位置 / 通知）+ 各自用途说明
- 屏 3：填 API Key（跳过也行，后续 Banner 提醒）

**验证标准**：
- [ ] 删除 App 重装后走完引导
- [ ] 每屏可跳过
- [ ] 完成后写入 UserDefaults "hasOnboarded"

---

#### V3-402: 示例 memo（打动人心）

**期望**：
- 首次进入 Today 时，预置 3 条示例 memo（昨天日期），内容温暖具体：
  - "咖啡店角落的位置，窗外在下小雨。" + 伪位置
  - 语音 memo（预置音频 + 转写）
  - 一张示例照片
- 可一键清除

**验证标准**：
- [ ] 首次打开看到示例，体验完整功能
- [ ] Settings 有"清除示例数据"

---

#### V3-403: Settings 重构

**期望**：
- 分区：`API Keys` / `权限` / `外观（暗色模式预留）` / `数据（导出/备份/清除）` / `关于`
- 每个 API Key 有"测试连接"按钮
- API Key 未配置显示红色徽章

**验证标准**：
- [ ] 5 个分区完整
- [ ] 测试连接按钮实际 ping API
- [ ] 徽章颜色逻辑正确

---

## 5. Functional Requirements（汇总）

### FR-Reliability（可信任）
- FR-1: 所有编译错误 → user-facing Banner（错误/进行中/成功 三态）
- FR-2: 前台编译自动重试 2 次（429 / 网络）
- FR-3: 语音转写 100% 完整（Whisper 保底）
- FR-4: 离线录音队列 + 网络恢复后自动转写
- FR-5: 消除 `try?` 异常吞噬，全局错误日志

### FR-Simplicity（去摩擦）
- FR-6: 输入栏 ≤ 1 个文本框 + 1 个发送按钮
- FR-7: `/` 唤起命令面板
- FR-8: 语音改"长按发送键说话"
- FR-9: Archive 日期统一进入 DayDetailView

### FR-Visual（顶级视觉）
- FR-10: 暖白底色系统（DSColor token 升级）
- FR-11: 5 级字号层级
- FR-12: 圆角 12/8pt + 微阴影
- FR-13: 相对时间 + TODAY/YESTERDAY/N DAYS AGO
- FR-14: 微交互（haptic + spring 动画）
- FR-15: 空状态带插图 + CTA

### FR-Intelligence（懂我）
- FR-16: On This Day 卡片
- FR-17: Random Walk 随机漫步
- FR-18: 环境联动洞察（首版：位置 × 时间规则）
- FR-19: 智能输入建议 Chip

### FR-Onboarding（首次体验）
- FR-20: 3 屏引导
- FR-21: 示例 memo
- FR-22: Settings 重构

---

## 6. Non-Goals（明确不做）

- ❌ 深色模式（token 预留，实现放 v3.1）
- ❌ 跨设备同步
- ❌ 多用户协作
- ❌ 富文本 / markdown 预览（保持 plain + 简单 wikilink）
- ❌ iPad / Mac Catalyst 适配
- ❌ AI 模型本地化
- ❌ 实时协同
- ❌ 自定义主题（配色用户不可改）
- ❌ PDF 导出（v3 不做，保留 Markdown）

---

## 7. Technical Considerations

### 架构影响
- **DSColor 全面重构**：涉及 TodayView / ArchiveView / DailyPageView / MemoCardView / InputBarView 等约 12 个文件
- **VoiceService 重写**：如果选方案 A（去掉实时转写），需要删除约 80 行 SFSpeechRecognizer 相关代码；如果选方案 B 只改 50 行逻辑优先级
- **CompilationService 重试**：参考 `BackgroundCompilationService.swift:137` 已有模式，抽出公共 retry 函数
- **DailyPageView 拆分**：当前 1265 行，拆成 5-6 个子 view（Header / Timeline / Entities / Metadata / CompilePrompt / OnThisDay）

### 性能
- On This Day 查询：vault 扫描 O(一年 365 文件)，启动时异步建索引 `vault/wiki/index.json`
- Archive 日历：已有的 heatmap 性能可接受
- 微交互动画：Instruments 验证 60fps

### 测试债务
- 补 `DayPageTests` target（Swift Testing）
- 优先覆盖：VoiceService 时序 / CompilationService 重试 / RelativeTimeFormatter / On This Day 查询

### 数据迁移
- DSColor token 改动不影响本地数据
- 示例 memo 预置时创建日期 = 昨天（装仿真）

---

## 8. Design Considerations

### 必须设计的新页面 / 组件
1. **ErrorBanner / ProgressBanner / SuccessBanner**（V3-002）
2. **CommandPalette** 浮窗（V3-101）
3. **按住说话录音浮窗**（V3-102）
4. **DayDetailView**（V3-104）
5. **OnThisDayCard**（V3-301）
6. **InsightCard**（V3-303）
7. **InputSuggestionChip**（V3-304）
8. **OnboardingView**（V3-401）
9. **空状态插图**（V3-206，至少 3 张）

### 复用现有
- Today 卡片 → DayDetailView 的原始 memo 视图
- Daily Page 卡片 → Archive 列表

### 设计工具
- Stitch 新页面同步到 `design/stitch/`
- 暖白色系需要在 Stitch 里先定义 theme 再拉

---

## 9. Open Questions

### ✅ 已拍板（2026-04-17）

- **Q1 实时转写** → 方案 A：**去掉**。录音界面只显示波形 + 时长，停止后 100% 走 Whisper。详见 V3-001。
- **Q2 编译错误场景** → 主场景：**网络连接问题**。V3-002 已按此重写：预检网络 / 自动重试 2 次 / 离线进队列 / 网络错误文案明确。
- **Q3 视觉方向** → **暖白**（#FAF8F6 + 深棕灰 #2B2822 正文 + 琥珀褐 #5D3000 accent）。详见 V3-201。

### ✅ 已拍板（2026-04-17 追加）

- **Q4 On This Day 触发** → **每天本地时区定时触发一次（默认 00:00，Settings 可配置）+ 大日期长按 1.5s 隐蔽手动触发**。详见 V3-301。
- **Q5 W4 先做哪一条** → **只做 On This Day**。Random Walk / 环境洞察后延。

### 🟡 仍可讨论（不阻塞开工）

#### Q6. Wave 排序：W1 → W2 → W3 → W4 → W5，OK？
可信任 → 去摩擦 → 视觉 → 懂我 → 首次体验。如无异议按此走。

---

## 10. Success Metrics

| 指标 | 基线 | 目标 | 如何测 |
|---|---|---|---|
| 语音转写完整率 | ~60% | 100% | 手动跑 20 条不同长度 |
| 编译失败无提示率 | 100% | 0 | 制造失败 → 是否有 Banner |
| 文字记录操作步数 | 3 | 2-3 | 数点击 |
| 语音记录操作步数 | 5 | 2 | 数点击 |
| 硬编码颜色数 | 12 | 0 | grep |
| 字号层级数 | 2 | 5 | Typography.swift 检查 |
| 空状态有 CTA 的 Tab 数 | 0 | 3 | 人工验证 |
| On This Day 日触发次数 | 0 | ≥ 0.15（当有历史数据时）| 埋点 |
| 用户主观"高级感"评分（1-10）| ? | ≥ 7 | 你自己打 |

---

## 11. 附录：证据映射（每个 issue 的代码证据）

| Story | 证据文件 | 行号 |
|---|---|---|
| V3-001 语音 bug | VoiceService.swift | 193-205, 264, 270-276 |
| V3-002 编译反馈 | CompilationService.swift | 52-54, 162, 269-309, 397, 460-489 |
| V3-005 try? 吞异常 | CompilationService.swift | 162, 397 |
| V3-101 输入栏按钮 | InputBarView.swift | 87-126 |
| V3-102 语音模态 | VoiceRecordingView.swift | 8-82 |
| V3-201 配色硬编码 | ArchiveView.swift | 61-64 (heatmap) |
| V3-202 字体硬编码 | VoiceRecordingView.swift / InputBarView.swift | 129 / 102 |
| V3-203 卡片密度 | MemoCardView.swift | 106-210, 177 |
| V3-204 时间格式 | TodayView.swift | 319 |
| V3-206 空状态 | TodayView.swift | 147-151 |

---

## 12. 下一步（你拍板后）

1. 回答 Open Questions（尤其 Q1 / Q2）→ 我更新 PRD
2. 建 GitHub Issue（22 个 story → 22 个 issue），用本 PRD 作 body 引用
3. 从 V3-001（语音修复）开始，走 Ralph prd.json 路线
4. 每个 Wave 结束出 TestFlight build，你实测

**开工前必读**：
- v2 roadmap（`tasks/prd-daypage-v2-roadmap.md`）仍然有效，v3 不替换它。v3 完成后 v2 的剩余 issue 继续做。
- 有些 v2 story 和 v3 story 触达同一文件，实施时需要先看 v2 进度（progress.txt），避免冲突。

---
