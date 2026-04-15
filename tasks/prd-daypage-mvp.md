# PRD: DayPage MVP — 每日原始数据采集与 AI 编译系统

**版本:** 1.0 MVP
**日期:** 2026-04-15
**状态:** 草案（待 UI 设计稿补充）

---

## 1. 介绍 / 概述

DayPage 是一个以"每日原始数据采集"为核心的 iOS 个人记录应用。用户以最低摩擦的方式（文字、语音、照片、位置）倾倒一天中的生活碎片，AI 每日凌晨将散落的 memo 编译成结构化日记（Daily Page）和跨时间累积的知识网络（Entity Page）。目标用户是旅居者、数字游民和长期旅行者——需要记录但不愿花时间整理。

**核心价值主张：** 用户只管输入（Raw 层），AI 负责整理（Wiki 层）。所有数据以纯 Markdown 本地存储，Obsidian 兼容，格式永久可读。

## 2. 目标

- **低摩擦输入**：App 启动到可输入 < 2 秒；每条 memo 输入耗时 < 30 秒
- **零整理负担**：用户永远不需要手动分类、打标签或组织笔记
- **AI 自动编译**：每日将原始碎片编译成可读日记和跨时间知识积累
- **数据主权**：本地 Markdown 存储，可直接用 Obsidian 打开，永不绑定
- **旅居场景优化**：自动采集位置、天气、EXIF，为"在路上"的记录补齐上下文

## 3. User Stories

### US-001: 初始化 Vault 目录结构与配置
**Description:** 作为开发者，我需要在 App 首次启动时初始化 Vault 目录结构并加载环境变量，以便后续所有读写操作有统一的文件系统基础。

**Acceptance Criteria:**
- [ ] 在 App Sandbox 的 Documents 目录下创建 `vault/raw/assets/`、`vault/wiki/daily/`、`vault/wiki/places/`、`vault/wiki/people/`、`vault/wiki/themes/` 子目录
- [ ] 首次启动时写入初始 `SCHEMA.md`、`wiki/index.md`、`wiki/hot.md`、`wiki/log.md`
- [ ] `.env` 文件模板（`.env.example`）包含 `DASHSCOPE_API_KEY`、`OPENAI_WHISPER_API_KEY`、`OPENWEATHER_API_KEY` 三个占位键
- [ ] `.gitignore` 包含 `.env`、`*.xcuserstate`、`vault/`（用户数据不入仓库）
- [ ] 密钥从 `.env` 加载到内存，不写入 UserDefaults 或 Keychain 以外的明文位置
- [ ] Typecheck / SwiftLint 通过

### US-002: 统一输入栏 — 文字输入
**Description:** 作为用户，我希望打开 App 后立刻看到输入框，可以直接打字记录想法，无需任何导航操作。

**Acceptance Criteria:**
- [ ] Today Flow 主屏下方固定输入栏，键盘聚焦后光标立即可用
- [ ] 输入框支持多行文本和 Markdown 语法（粗体、斜体、列表原样保存）
- [ ] 提交按钮点击后 memo 立即出现在时间轴顶部（< 1 秒）
- [ ] 文字 memo 自动附加时间戳 + GPS + 天气 + 设备信息的 YAML frontmatter
- [ ] 追加写入 `vault/raw/YYYY-MM-DD.md`，与当日已有 memo 之间用 `\n\n---\n\n` 分隔
- [ ] Typecheck / SwiftLint 通过
- [ ] 在 iOS 模拟器中验证主屏交互

### US-003: 统一输入栏 — 语音录制与转写
**Description:** 作为用户，我希望点击麦克风图标后能快速录音并自动转写为文字，音频文件本地保留作为原始数据。

**Acceptance Criteria:**
- [ ] 点击麦克风图标触发底部上滑半屏的录音浮层（屏幕 S2）
- [ ] 首次使用请求 iOS 麦克风权限，被拒绝时显示明确引导
- [ ] 录音过程显示实时波形或计时器，支持暂停/继续/取消
- [ ] 停止录音后音频保存为 `vault/raw/assets/voice_YYYYMMDD_HHMMSS.m4a`（AAC 编码）
- [ ] 调用 OpenAI Whisper API 转写音频，使用 `.env` 中的 `OPENAI_WHISPER_API_KEY`
- [ ] 转写结果作为 memo 正文，原始音频作为 attachment 附加在 frontmatter 中（含 duration、file 路径、transcript 全文）
- [ ] 网络失败时音频仍完整保存，转写字段为空并显示"稍后重试"提示
- [ ] Typecheck / SwiftLint 通过
- [ ] 在真机或模拟器中验证完整录制→转写→入库流程

### US-004: 统一输入栏 — 照片采集
**Description:** 作为用户，我希望能快速拍照或从相册选照片，附带可选文字说明作为一条 memo。

**Acceptance Criteria:**
- [ ] 点击相机图标弹出 ActionSheet，提供"拍照"和"从相册选择"两个选项
- [ ] 拍照和相册选择使用 iOS 原生 `UIImagePickerController` 或 `PHPickerViewController`
- [ ] 照片原图（保留 EXIF）保存到 `vault/raw/assets/IMG_YYYYMMDD_HHMMSS.jpg`，不做压缩不去色
- [ ] 提取 EXIF：光圈、快门、ISO、焦距、GPS（若有）、拍摄时间，写入 frontmatter `attachments` 字段
- [ ] 照片附带的文字说明（可选）作为 memo 正文
- [ ] 时间轴中照片 memo 显示缩略图，点击可全屏查看
- [ ] Typecheck / SwiftLint 通过
- [ ] 在模拟器中验证拍照和相册两种来源

### US-005: 统一输入栏 — 位置标记
**Description:** 作为用户，我希望一键标记当前位置，自动获取可读地名（如"Joma Coffee, Setthathirath Rd"）。

**Acceptance Criteria:**
- [ ] 点击地图图标触发 iOS 原生 `CLLocationManager` 获取当前坐标
- [ ] 首次使用请求"使用 App 期间"定位权限
- [ ] 使用 iOS 原生 `CLGeocoder` 做反向地理编码（不出境，无需 Google API）
- [ ] 地名解析结果填入 frontmatter `location.name`，经纬度填入 `location.lat/lng`
- [ ] 位置采集在 3 秒内完成，超时降级为仅坐标无地名
- [ ] 位置可作为独立 memo 提交（签到式），也可作为其他 memo 的附加元数据
- [ ] Typecheck / SwiftLint 通过
- [ ] 在模拟器模拟位置或真机验证反向地理编码

### US-006: 自动元数据采集 — 天气
**Description:** 作为用户，我希望每条 memo 自动附带当时的天气信息，无需手动输入。

**Acceptance Criteria:**
- [ ] 提交 memo 时，基于当前 GPS 调用 OpenWeatherMap API（`https://api.openweathermap.org/data/2.5/weather`）
- [ ] API Key 从 `.env` 加载（`OPENWEATHER_API_KEY=REDACTED_OPENWEATHER_KEY`）
- [ ] 天气信息格式化为 `"32°C, 多云"` 写入 frontmatter `weather` 字段
- [ ] 天气结果缓存 10 分钟，同一位置连续多条 memo 不重复调用 API
- [ ] 网络失败或无位置权限时跳过天气字段，不阻塞 memo 提交
- [ ] Typecheck / SwiftLint 通过

### US-007: 混合 memo — 多类型组合输入
**Description:** 作为用户，我希望一条 memo 能同时包含照片 + 文字 + 位置标记，一次性记录完整场景。

**Acceptance Criteria:**
- [ ] 输入栏支持在一次提交前依次添加多个附件（照片、音频、位置）
- [ ] 已添加的附件在输入栏上方以小预览卡片形式展示，支持单独移除
- [ ] 提交时将所有附件合并到同一条 memo 的 frontmatter `attachments` 数组中
- [ ] memo 的 `type` 字段根据组合自动设为 `text | voice | photo | location | mixed`
- [ ] Typecheck / SwiftLint 通过
- [ ] 在模拟器验证混合提交

### US-008: Today Flow 时间轴展示
**Description:** 作为用户，我希望主屏上方展示今天所有已提交的 memo，按时间倒序排列，可滚动浏览。

**Acceptance Criteria:**
- [ ] 主屏（S1）上方 75% 区域为时间轴，按 `created` 字段倒序
- [ ] 每条 memo 卡片显示：时间（`HH:mm`）、内容预览、附件缩略图、位置标签
- [ ] 时间轴顶部：若当日 Daily Page 已编译，显示入口卡片（带摘要副标题）
- [ ] 未编译时显示"今日还未编译"的占位提示，附"立即编译"按钮
- [ ] 滚动流畅（60 FPS），长内容自动截断，点击卡片展开完整内容
- [ ] Typecheck / SwiftLint 通过
- [ ] 在模拟器中验证时间轴渲染与滚动

### US-009: Raw 文件读写 — Markdown 序列化
**Description:** 作为开发者，我需要实现 memo 与 Markdown 文件之间的序列化/反序列化逻辑。

**Acceptance Criteria:**
- [ ] 定义 `Memo` Swift 结构体，对应 PRD 2.1 节的数据结构
- [ ] 写入：将 `Memo` 序列化为 YAML frontmatter + Markdown body，追加到 `vault/raw/YYYY-MM-DD.md`
- [ ] 多条 memo 之间用 `\n\n---\n\n` 分隔；当天文件不存在则创建
- [ ] 读取：解析指定日期文件，按 `---` 分割，逐块解析 frontmatter + body 为 `Memo` 数组
- [ ] YAML 解析使用 Swift 原生方案（Yams 库或自写简易解析器，MVP 阶段只需支持本 PRD 列出的字段）
- [ ] 原子写入：使用临时文件 + rename，避免写入中断导致文件损坏
- [ ] Typecheck / SwiftLint 通过
- [ ] 单元测试覆盖写入、读取、多条 memo 往返

### US-010: AI 编译引擎 — Daily Page 生成
**Description:** 作为开发者，我需要实现调用 LLM 将当天 raw memo 编译成结构化 Daily Page 的逻辑。

**Acceptance Criteria:**
- [ ] 编译服务读取 `vault/raw/YYYY-MM-DD.md` 全部 memo + `wiki/hot.md` 上下文
- [ ] 调用阿里云 DashScope API：`https://coding.dashscope.aliyuncs.com/v1/chat/completions`，模型 `qwen3.5-plus`，使用 OpenAI 兼容接口协议
- [ ] API Key 从 `.env` 加载（`DASHSCOPE_API_KEY`）
- [ ] System prompt 使用 PRD 附录 B 的模板，user message 包含当天所有 memo 的完整内容（含元数据）
- [ ] 产出写入 `vault/wiki/daily/YYYY-MM-DD.md`，包含 frontmatter（type、date、location_primary、mood、entries_count、voice_minutes、photos）+ 时段化正文 + 今日地点 + AI 追问
- [ ] 若目标文件已存在（手动重编译场景），覆盖前备份到 `vault/wiki/daily/.trash/YYYY-MM-DD_TIMESTAMP.md`
- [ ] 编译操作记录到 `wiki/log.md`（时间、触发方式、耗时、memo 数量、token 消耗）
- [ ] 网络失败时保留原文件不变，显示错误提示
- [ ] Typecheck / SwiftLint 通过
- [ ] 在模拟器中用真实 memo 数据走通一次完整编译

### US-011: AI 编译引擎 — Entity Page 更新
**Description:** 作为开发者，编译时需要识别地点、人物、主题，创建或增量更新对应的 Entity Page。

**Acceptance Criteria:**
- [ ] LLM 编译请求返回结构化产物：Daily Page 正文 + Entity 更新指令数组（每项包含 `entity_type`、`entity_slug`、`section`、`content`）
- [ ] 对每个 Entity 更新指令：若 `wiki/{places|people|themes}/{slug}.md` 不存在则新建，存在则在对应 section 追加新内容
- [ ] Entity Page 包含 frontmatter（type、name、first_seen、last_updated、occurrence_count）+ 分段正文（如"感知印记"、"关联 memo"、"相关日期"）
- [ ] 新增 Entity 同步更新 `wiki/index.md`（按类型分组的索引列表）
- [ ] Daily Page 正文中的实体以 `[[slug]]` 格式链接
- [ ] Typecheck / SwiftLint 通过
- [ ] 单元测试覆盖：新建 Entity、增量更新、多日引用同一 Entity

### US-012: AI 编译引擎 — Hot Cache 更新
**Description:** 作为开发者，每次编译完成后需要刷新 `wiki/hot.md`，作为下一次编译的短期记忆上下文。

**Acceptance Criteria:**
- [ ] 编译完成后 LLM 追加生成 hot cache 摘要（约 500 字，中文）
- [ ] 内容包含：当前所在城市、最近 3-5 天情绪基调、活跃主题线索、值得关注的模式
- [ ] 直接覆盖写入 `vault/wiki/hot.md`，保留 frontmatter（updated_at、covers_dates）
- [ ] 下一次编译调用时 hot.md 作为上下文一并传入 LLM
- [ ] Typecheck / SwiftLint 通过

### US-013: 每日自动编译 — 定时触发
**Description:** 作为用户，我希望每天凌晨 2:00（设备本地时间）自动编译前一天的 memo，醒来就能看到日记。

**Acceptance Criteria:**
- [ ] 使用 iOS `BGAppRefreshTask`（BackgroundTasks 框架）注册每日后台任务
- [ ] 后台任务触发时检查：前一天 raw 文件存在且 Daily Page 尚未生成 → 执行编译
- [ ] 编译完成后发送本地通知："昨天的 Daily Page 已编译完成"
- [ ] 若后台任务未被系统调度，下次 App 启动时检查并补充编译
- [ ] 编译期间失败不重试（下次 App 启动时再判断）
- [ ] Typecheck / SwiftLint 通过

### US-014: 手动触发编译
**Description:** 作为用户，我希望能随时点击按钮立即编译今天已有的 memo，不必等到凌晨。

**Acceptance Criteria:**
- [ ] Today Flow 顶部"立即编译"按钮，点击后进入 loading 状态
- [ ] 编译期间禁用按钮，显示进度提示（"正在编译 N 条 memo..."）
- [ ] 编译成功后时间轴顶部出现 Daily Page 入口卡片
- [ ] 编译失败弹出错误 toast（网络、API Key 缺失、LLM 返回格式错误分别有不同文案）
- [ ] Typecheck / SwiftLint 通过
- [ ] 在模拟器中走通手动编译路径

### US-015: Daily Page 视图
**Description:** 作为用户，我希望点击入口卡片后看到一篇完整的 AI 编译日记，包含时段叙事、地点汇总、AI 追问。

**Acceptance Criteria:**
- [ ] 屏幕 S3 渲染 `wiki/daily/YYYY-MM-DD.md`，Markdown 原生渲染（标题、段落、列表、引用）
- [ ] 顶部 segmented control 提供 `DIGEST` / `TIMELINE` 两个 Tab：DIGEST 显示编译后日记，TIMELINE 切换为该日 raw memo 时间轴只读视图
- [ ] 日期主标题用 Space Grotesk 56px uppercase；副标题为星期（如 `TUESDAY`）
- [ ] 一句话副标题（来自 frontmatter `summary` 字段）使用左 2px 黑色边框 + Inter 18px
- [ ] 顶部元数据 chips 行渲染 `N entries` / `N locations` / `N min voice`（基于 frontmatter 数据，Mono 11px uppercase）
- [ ] 时段标题（MORNING / AFTERNOON / EVENING）使用 Space Grotesk 12px tracking-[0.2em] uppercase + 右侧横线
- [ ] `[[wiki 链接]]` 渲染为 `#5D3000` 颜色，前后显示 opacity 0.4 的 `[[` `]]` 双括号；点击跳转对应 Entity Page
- [ ] "Places Today" 模块以 `bg-surface-container p-8` 块呈现，每项含黑底白字时间 chip + wiki-link + 灰色斜体注解
- [ ] AI 追问以 "Threads" bento grid 呈现，单卡片 `bg-surface-container-high p-6`，底部 CTA 行 `#5D3000` Mono 10px uppercase + 箭头图标
- [ ] 点击 Thread 卡片：跳回 Today Flow 输入栏并预填该追问文本作为新 memo 草稿
- [ ] Footer 显示 `Compiled from N raw entries` + `View original flow →` 链接（点击切换到 TIMELINE Tab）
- [ ] 支持下拉返回 / 系统 swipe-back 手势
- [ ] Typecheck / SwiftLint 通过
- [ ] 在模拟器中验证完整渲染与跳转

### US-016: Entity Page 视图
**Description:** 作为用户，我希望点击 wiki 链接后查看该地点/人物/主题的累积页面。

**Acceptance Criteria:**
- [ ] 渲染 `wiki/places/*.md`、`wiki/people/*.md`、`wiki/themes/*.md`
- [ ] Markdown 原生渲染 + 内嵌 `[[链接]]` 跳转
- [ ] 页面底部显示"相关 memo"列表（按时间倒序），点击跳转对应日期的 Flow 视图
- [ ] 不存在的 wiki 链接点击后显示"该实体页尚未生成"提示
- [ ] Typecheck / SwiftLint 通过

### US-017: Archive 视图 — 日历模式
**Description:** 作为用户，我希望以月历视图浏览过往记录，通过格子颜色深浅快速看出哪些天记录密集。

**Acceptance Criteria:**
- [ ] 屏幕 S4a 日历 Tab：月度 7 列网格，星期表头 Mono 10px on_surface_variant
- [ ] 格子热力填充规则：0 条 → `#F9F9F9`，1-2 条 → `#E8E8E8`，3-5 条 → `#474747`，6+ 条 → `#000000`
- [ ] 当日格子有 1px 黑色额外描边
- [ ] 网格下方 Legend 显示 4 个色块 + 标签：`EMPTY` / `LOW` / `MEDIUM` / `HIGH DENSITY`（Mono 10px）
- [ ] 月份导航栏：左右箭头 + 月份名（Space Grotesk 居中）+ 右侧 `CALENDAR / LIST` segmented control
- [ ] 月历下方显示 "MONTHLY SUMMARY" 模块（`bg-surface-container p-6`），含 4 个统计单元（TOTAL ENTRIES / VOICE RECORDING DURATION / PHOTOS CAPTURED / UNIQUE LOCATIONS），数字用 Space Grotesk 36px
- [ ] 当前月份默认展开，左右滑动切换月份
- [ ] 点击某天格子跳转该日 Flow 视图（只读模式，不可新增当天之外的 memo）
- [ ] Typecheck / SwiftLint 通过
- [ ] 在模拟器中验证多月数据下的渲染

### US-018: Archive 视图 — 列表模式
**Description:** 作为用户，我希望以列表形式浏览过往日期，每条显示当日 AI 摘要和元数据统计。

**Acceptance Criteria:**
- [ ] Archive 顶部 segmented control 切换"CALENDAR / LIST"，LIST 选中时为黑底白字
- [ ] 列表按日期倒序，每项 `bg-surface-container p-6`，左侧 4px 黑色边框（`border-l-4 border-primary`）
- [ ] 每项布局：日期标题（Space Grotesk 700 uppercase）+ 右上角状态徽章 + 一行 italic 摘要 + 元数据图标行
- [ ] 状态徽章规则：已编译且查看过 → `VERIFIED`（黑底白字 Mono 9px chip）；未编译或仅元数据 → `Metadata Only`（灰底灰字 chip）
- [ ] 元数据行用 3 个图标 + Mono 11px 计数（条目数 / 照片数 / 语音分钟数）
- [ ] 点击行跳转当日 Flow 视图（只读模式）
- [ ] Typecheck / SwiftLint 通过
- [ ] 在模拟器中验证多日数据下的渲染

### US-019: 底部 Tab 导航
**Description:** 作为用户，我希望底部 Tab 栏提供 Today / Archive / Graph 三个入口，Graph 在 MVP 阶段灰置。

**Acceptance Criteria:**
- [ ] `UITabBarController` 或 SwiftUI `TabView` 实现三 Tab
- [ ] Today 和 Archive 可点击切换
- [ ] Graph Tab 显示为灰色，点击后显示"敬请期待"占位页（不崩溃）
- [ ] Tab 切换保持各自栈的浏览状态
- [ ] Typecheck / SwiftLint 通过
- [ ] 在模拟器中验证 Tab 切换

### US-020a: 设计系统 Token 落地
**Description:** 作为开发者，我需要将 Archival Brutalist 设计系统的颜色、字体、间距 token 在 Swift/SwiftUI 中实现为可复用的常量与样式修饰器，确保所有屏幕严格遵循设计规范。

**Acceptance Criteria:**
- [ ] 创建 `DesignSystem/Colors.swift`，定义 PRD §6.1.2 表中所有 token（含 `amberArchival = #5D3000`），用 `Color(hex:)` 扩展实现
- [ ] 创建 `DesignSystem/Typography.swift`，定义 9 个排版 level（Display-LG / Headline-MD / Headline-Caps / Section-Label / Title-SM / Body-MD / Body-SM / Label-SM / Label-XS），每个 level 是 SwiftUI `ViewModifier` 或 `Font` 扩展
- [ ] 引入字体文件：Space Grotesk、Inter、JetBrains Mono（三档全字重），通过 `Info.plist` `UIAppFonts` 注册
- [ ] 创建 `DesignSystem/Components.swift`：按钮（Primary Stamp / Secondary Outline）、Field Chip、Time Chip、Section Heading（带横线）、Wikilink Text 等基础组件
- [ ] 创建 `DesignSystem/HapticButton.swift`：封装 `active:translate-y-0.5` 与 `active:invert` 的两种反馈样式
- [ ] 全局禁用圆角：所有自定义视图 `cornerRadius(0)`；UIKit 桥接控件统一移除默认圆角
- [ ] SwiftLint 自定义规则禁止直接使用 hex 字符串颜色（必须走 `Color.surface` 等命名 token）
- [ ] Typecheck / SwiftLint 通过

### US-020: 环境变量与密钥管理
**Description:** 作为开发者，所有第三方 API 密钥需要通过 `.env` 文件注入，不得硬编码入源码。

**Acceptance Criteria:**
- [ ] 项目根目录 `.env` 文件（被 `.gitignore`）包含：
  - `DASHSCOPE_API_KEY=REDACTED_DASHSCOPE_KEY`
  - `DASHSCOPE_BASE_URL=https://coding.dashscope.aliyuncs.com/v1`
  - `DASHSCOPE_MODEL=qwen3.5-plus`
  - `OPENAI_WHISPER_API_KEY=sk-proj-VMv9rn6aSt2zTgRxSdCGjcs3-...`
  - `OPENWEATHER_API_KEY=REDACTED_OPENWEATHER_KEY`
- [ ] 构建脚本（Xcode Run Script Phase）在编译时将 `.env` 转为 `GeneratedSecrets.swift`（被 `.gitignore`），作为 `enum Secrets` 静态常量暴露
- [ ] `.env.example` 提交入仓库，列出所有必需键名但不含真实值
- [ ] `.gitignore` 至少包含：`.env`、`GeneratedSecrets.swift`、`vault/`、`*.xcuserstate`、`DerivedData/`、`build/`
- [ ] 代码中所有 API Key 引用均通过 `Secrets.xxx`，grep 搜索不到明文密钥
- [ ] Typecheck / SwiftLint 通过

## 4. 功能需求（Functional Requirements）

### 输入与数据采集
- **FR-1:** App 启动即展示 Today Flow 主屏，输入栏始终可见，无需导航。
- **FR-2:** 输入栏支持文字、语音、照片、位置、附件五种输入类型的任意组合。
- **FR-3:** 每条 memo 提交时必须自动采集：ISO 8601 时间戳（含时区）、GPS 坐标、反向地理编码地名、天气、设备型号。
- **FR-4:** 照片必须保存原图（不压缩、不去色），提取并存储 EXIF（光圈、快门、ISO、焦距、GPS）。
- **FR-5:** 语音录制为 AAC 格式 `.m4a`，采样率 44.1kHz 单声道，存储在 `vault/raw/assets/`。
- **FR-6:** 语音转写调用 OpenAI Whisper API，结果作为 memo 正文，原音频作为 attachment。
- **FR-7:** 同一天的多条 memo 追加到 `vault/raw/YYYY-MM-DD.md` 同一文件，之间用 `\n\n---\n\n` 分隔。
- **FR-8:** Raw 层文件一旦写入由 App 视为只读，AI 编译与后续功能均不得修改。

### 存储与格式
- **FR-9:** 所有数据以标准 Markdown + YAML frontmatter 存储在本地文件系统。
- **FR-10:** Vault 根目录位于 App Sandbox 的 `Documents/vault/`，可通过 iOS 文件共享导出。
- **FR-11:** Vault 目录结构必须与 PRD 2.2 节一致，作为 Obsidian Vault 打开后 wiki 链接能正确跳转。

### AI 编译
- **FR-12:** 每日凌晨 2:00（设备本地时间）触发后台编译任务，编译前一天的 memo。
- **FR-13:** Today Flow 提供"立即编译"按钮，允许用户手动触发当天编译。
- **FR-14:** 编译调用阿里云 DashScope 的 OpenAI 兼容接口（`baseUrl: https://coding.dashscope.aliyuncs.com/v1`，模型 `qwen3.5-plus`）。
- **FR-15:** 编译输入包含当天所有 raw memo（含元数据） + `wiki/hot.md` 上下文 + 相关 Entity Page 摘要。
- **FR-16:** 编译产出：`wiki/daily/YYYY-MM-DD.md`（Daily Page）+ Entity Page 新建/更新 + `wiki/hot.md` 刷新 + `wiki/log.md` 追加。
- **FR-17:** Daily Page 结构必须包含：frontmatter、一句话副标题、时段叙事（上午/下午/晚上）、今日地点、AI 追问（2-3 条）。
- **FR-18:** Entity Page 类型包含 `places`、`people`、`themes` 三类，slug 使用 kebab-case 英文或拼音。
- **FR-19:** 重复编译同一天时，原 Daily Page 备份到 `wiki/daily/.trash/YYYY-MM-DD_TIMESTAMP.md` 后覆盖。

### 显示与导航
- **FR-20:** Today Flow 时间轴按时间倒序显示当日 memo，顶部可能展示 Daily Page 入口卡片。
- **FR-21:** Daily Page 视图支持 `[[wiki 链接]]` 点击跳转到 Entity Page。
- **FR-22:** Archive Tab 提供日历视图和列表视图两种模式，用 segmented control 切换。
- **FR-23:** AI 追问点击后跳回 Today Flow 输入栏并预填追问文本，用户回应成为新 memo。
- **FR-24:** 底部 Tab 栏三个入口：Today、Archive、Graph（Graph 灰置占位）。

### 密钥与配置
- **FR-25:** 所有第三方 API 密钥通过 `.env` 文件注入，编译期生成 `GeneratedSecrets.swift` 常量。
- **FR-26:** `.env`、`GeneratedSecrets.swift`、`vault/` 必须在 `.gitignore` 中。
- **FR-27:** `.env.example` 须提交入仓库作为配置模板。

## 5. Non-Goals（明确不做）

- **NG-1:** 多设备同步 —— 用户自行通过 iCloud Drive / Git / Syncthing 同步 Vault 目录
- **NG-2:** Android / Web / macOS 客户端 —— MVP 仅 iOS
- **NG-3:** 知识图谱可视化 Graph Tab —— 仅占位灰置
- **NG-4:** 社区分享 / 发布功能
- **NG-5:** AI 来电 / 主动提醒录入
- **NG-6:** 视频输入
- **NG-7:** 导出为 PDF / Word 等格式
- **NG-8:** 协作、多用户、评论
- **NG-9:** 设备端 Whisper 本地转写（MVP 使用 Whisper API）
- **NG-10:** 修改或删除已提交的 memo（Raw 层严格只读；文件级手动编辑不在 App 内暴露）
- **NG-11:** Daily Page 的人工编辑（AI 产出即成品，重新编译是唯一的刷新方式）

## 6. 设计考虑

> **设计系统名称：** Archival Brutalist（"The Digital Curator"）
> **来源：** Stitch 项目 `DayPage Today Flow`（ID `6404909232718143042`），HTML/截图存档于 `design/stitch/`
> **核心北极星：** "数字策展人"——拒绝 SaaS 的友善软调，转向冷峻的高保真档案美学；像田野研究员的日志，功利、致密、永久。

### 6.1 设计语言

#### 6.1.1 三大原则
1. **No-Line Rule（去描边）：** 禁止用 1px 描边做布局分区。区块分隔通过 **Value-Based Zoning**（不同灰度的背景色块）实现。仅当容器与底色相同时使用 `outline_variant` (#c6c6c6) 作为 Ghost Border。
2. **Zero-Radius Mandate（零圆角）：** 所有元素 `border-radius: 0`，包括按钮、输入框、checkbox、Tab 高亮、波形条。无例外。
3. **Tonal Stacking（色调堆叠）：** 不使用阴影（shadow / elevation）。深度感通过灰度递进（surface → surface_container → surface_container_high → surface_container_highest）实现。

#### 6.1.2 颜色 Token（严格遵循）

| Token | Hex | 用途 |
|-------|-----|-----|
| `surface` / `background` | `#F9F9F9` | 全局基础底色 |
| `surface_container_low` | `#F3F3F3` | 次级容器（极少用） |
| `surface_container` | `#EEEEEE` | 标准 memo 卡片背景、地点签到块 |
| `surface_container_high` | `#E8E8E8` | 语音 memo 块、Threads 卡片底色 |
| `surface_container_highest` | `#E2E2E2` | 选中态 / Threads hover |
| `surface_container_lowest` | `#FFFFFF` | 输入栏背景 |
| `primary` | `#000000` | 主行动色（CTA 按钮、Daily Page 顶卡、当前 Tab、Segmented Control 选中） |
| `on_primary` | `#E2E2E2` | primary 上的文字色（注意不是纯白） |
| `primary_container` | `#3B3B3B` | primary hover/active 反相 |
| `on_surface` | `#1B1B1B` | 主体正文 |
| `on_surface_variant` | `#474747` | "Field Ink" 元数据色（时间、坐标、标签） |
| `outline` | `#777777` | 输入框 1px 描边 |
| `outline_variant` | `#C6C6C6` | 时间轴竖线、Ghost Border |
| `secondary_container` | `#D6D4D3` | Field Chip 背景（filing-system 标签） |
| `error` | `#BA1A1A` | 仅用于破坏性操作 |
| **`amber_archival`** | **`#5D3000`** | **唯一彩色点缀**——录音中（计时器、波形、停止按钮、当前转写行左边框）、Daily Page 中的 `[[wikilink]]` 文字、Threads 卡片的 "View analysis →" 链接 |

> **强调色范围限定：** `#5D3000` 仅用于"正在采集数据"或"知识图谱跳转"两类语义，不得扩展到普通按钮、徽章、装饰元素。

#### 6.1.3 排版（Editorial Scale）

| Level | Font | Size | 字重 | 字距 | 用途 |
|-------|------|------|-----|-----|------|
| Display-LG | Space Grotesk | 56px (3.5rem) | 700 | -0.02em | Daily Page 日期标题（如 "APRIL 14, 2026"） |
| Headline-MD | Space Grotesk | 28px (1.75rem) | 700 | 0.02em | 内容大类锚点（archive、设置等页面标题） |
| Headline-Caps | Space Grotesk | 18-20px | 700 | tracking-widest | App Bar 标题（如 "DAYPAGE"、"ARCHIVE"），全大写 |
| Section-Label | Space Grotesk | 12px (0.75rem) | 700 | 0.2em | 时段标题（"MORNING ─────"），全大写 + 横线分隔 |
| Title-SM | Inter | 16px (1rem) | 700 | normal | 卡片标题、字段标签 |
| Body-MD | Inter | 14-15px (0.875-0.9375rem) | 400 | normal | Daily Page 正文叙事 |
| Body-SM | Inter | 14px (0.875rem) | 400 | normal | 时间轴 memo 卡片正文 |
| Label-SM | JetBrains Mono | 11px (0.6875rem) | 500 | tracking-wider | 时间戳、坐标、ID、计数 chips |
| Label-XS | JetBrains Mono | 10px | 500 | tracking-widest | Tab 标签、Bottom Nav 文字、Header 时间戳 |

**铁则：**
- Header 大字（≥18px）必须 `letter-spacing: 0.02em`
- 所有数字（时间、坐标、计数、时长、文件名）必须 JetBrains Mono
- Tab 导航和 Bottom Nav 全部用大写 Label-XS（不用图标作为导航主标签——图标 + 文字共存）
- 全大写标签字体禁用 Inter，统一 Space Grotesk

#### 6.1.4 间距与栅格

- 主屏内边距：`px-4`（16px）水平，`pt-20 pb-40`（80/160px）垂直
- 时间轴条目间距：`space-y-8`（32px）
- memo 内容块内边距：`p-4`（16px）
- Daily Page 主区内边距：`px-6`（24px）
- 时间轴左侧时间戳列宽：约 60px（含右侧 `gap-4` 16px）

#### 6.1.5 Haptic 交互反馈

由于无圆角无阴影，按钮按下反馈通过两种方式传达：
- **Translate：** `active:translate-y-0.5`（向下推 1-2px，模拟按键）
- **Invert：** `active:invert` 或反相为 `primary_container` (#3B3B3B)，模拟印章

不使用 opacity 渐变或 scale 缩放（除 Threads 卡片 `active:scale-[0.98]` 外）。

### 6.2 屏幕清单（基于设计稿）

| 编号 | 屏幕 | Stitch ID | 类型 | 对应 User Story |
|-----|------|-----------|-----|-----------------|
| S1 | Today Flow（Refined Layout） | `11aa0471...` | 主屏 | US-002/003/004/005/007/008/014 |
| S2 | Voice Recording Overlay | `761eec6a...` | 底部浮层 60% | US-003 |
| S3 | Daily Page（Fixed Navigation） | `856607e7...` | 页面 | US-015 |
| S4a | Archive – Calendar View | `d5c62950...` | 页面 | US-017 |
| S4b | Archive – List View | `541c1afa...` | 页面 | US-018 |
| S5 | Entity Page | （继承 S3 排版） | 页面 | US-016 |

### 6.3 屏幕详细规格

#### S1 · Today Flow（主屏）

**Top App Bar**（fixed，h-14）：
- 左：汉堡菜单图标 + `DAYPAGE`（Space Grotesk 700, tracking-widest, uppercase, 18-20px）
- 右：当前时间戳 chip（`bg-surface-container px-2 py-1`，Mono 10px，格式 `YYYY.MM.DD // HH:mm`）+ 设置图标

**Daily Page 入口卡片**（条件展示 — 仅当当日已编译）：
- 全宽，黑底（`bg-primary`），`p-6`
- 标题："TODAY'S PAGE COMPILED"（Space Grotesk 700, uppercase, 0.02em）
- 副标题：`14 logged entries curated into a daily digest.`（Inter 14px, opacity-80）
- 右侧 `arrow_forward` 图标，hover 时右移 4px
- 点击进入 S3

**时间轴条目（4 种类型）：**

| 类型 | 容器底色 | 内容元素 |
|-----|---------|---------|
| 文字 memo | `surface_container` (#EEEEEE) | 纯文本，Inter 14px, leading-relaxed |
| 语音 memo | `surface_container_high` (#E8E8E8) | 黑色播放按钮 (40×40) + 静态波形条（黑色 3px 宽，间距 2px）+ 时长 Mono 10px |
| 照片 memo | `surface_container` 容器 + 全宽图片（**注意：原型 grayscale 处理；本 PRD 决策保留原色**）+ 底部 `p-3` Mono 10px 的文件元数据（如 `IMG_9942.RAW // FOCUS: INFINITY`） |
| 位置 memo | `surface_container` + **左边框 4px 黑色**（`border-l-4 border-primary`）+ 标题（Space Grotesk uppercase）+ Mono 11px 坐标 + 右上角 `location_on` 图标 |

**条目左侧时间戳列：** Mono 10px 加粗（如 `08:30`）+ 1px 灰色竖线（`bg-outline-variant`）连接到下条。

**底部输入栏**（fixed bottom-16，浮在 Bottom Nav 上方 16px）：
- 容器：`bg-surface-container-lowest` + 1px outline 边框
- 顺序：mic / camera / 文本输入框 / location / attach / send
- 文本占位符 placeholder：`LOG NEW OBSERVATION...`（Mono uppercase, tracking-wider）
- send 按钮：`bg-primary text-on-primary`（黑底白字 40×40），按下 `active:scale-95`
- 其余图标按钮：透明背景 hover 时变 `surface_container`

**Bottom Nav**（fixed bottom-0，h-16）：
- 三 Tab：TODAY / ARCHIVE / GRAPH
- 当前 Tab：`bg-zinc-200`（深灰底）+ 黑色文字 + 图标 FILL=1
- 非当前：透明底 + `text-zinc-400`（灰文字）
- 标签：Space Grotesk 10px uppercase tracking-tighter font-bold
- GRAPH 在 MVP 中显示但点击仅显示占位

#### S2 · Voice Recording Overlay（底部浮层）

**结构：** 底部浮层占屏幕 60% 高度，背后 Today Flow 内容 grayscale + opacity-40 + 黑色 50% 蒙层。

**布局自上而下：**
1. **Handle Bar：** 顶部居中 48×4px 灰色拖拽条（#777）+ 右上角 close 图标
2. **计时器：** `00:04:21` 格式，Mono 5xl (~48px) `text-amber-archival` (#5D3000)
3. **波形可视化：** h-16 区域，居中 25 根 amber 波形条，宽 3px 间距 2px，高度从 h-4 到 h-16 不规则跳动（实时根据音量更新）
4. **录制/停止按钮：** 80×80 正方形 `bg-amber-archival text-white`，居中，停止图标 (FILL=1) 4xl，按下 `translate-y-[1px]`
5. **实时转写区：** 占剩余空间 `bg-surface-container p-4`，文字底部对齐，历史行 opacity 30%/50%/80% 渐显，最新行加粗 + 左 2px amber 边框，italic
6. **底部操作栏：** `p-6` 左右两端 — 左侧 `DISCARD`（无背景，Space Grotesk 加粗 widest，灰色字）+ 右侧 `SAVE`（黑底白字 `px-10 py-4`，Space Grotesk）

#### S3 · Daily Page

**Top App Bar：** 左侧 `arrow_back` + `DAYPAGE_PROTOCOL`（Space Grotesk 700 uppercase tracking-tighter），右侧 `history_edu` 图标

**Segmented Control：** 全宽 `border-2 border-primary` 黑色硬边框；内嵌两个 Tab：`DIGEST`（默认选中，黑底白字）/ `TIMELINE`（透明）。Mono 11px uppercase tracking-widest。
> **新增功能（来自设计稿）：** Daily Page 顶部允许在"摘要视图（Digest）"和"原始流视图（Timeline）"间切换，取代之前 PRD 中底部的"查看原始记录 →"链接。

**日期标题区：**
- 主标题：`APRIL 14, 2026`（Space Grotesk 56px font-bold tracking-tight uppercase）
- 副标题（星期）：`TUESDAY`（Space Grotesk 20px tracking-widest uppercase, on_surface_variant）
- 一句话副标题：左 2px 黑边框 + `pl-6`，Inter 18px leading-relaxed
- 元数据 chips 行：`bg-surface-container px-2 py-1`，Mono 11px uppercase；包含 `7 entries` / `3 locations` / `12 min voice`

**叙事正文：**
- 时段 section 标题（MORNING / AFTERNOON / EVENING）：Space Grotesk 12px font-bold tracking-[0.2em] uppercase + 右侧 1px outline_variant 横线占满剩余宽度
- 段落正文：Inter 15px leading-relaxed `text-on-surface`
- Wikilink：CSS 类 `wiki-link`，颜色 `#5D3000` font-medium，前后伪元素 `[[` `]]`（opacity 0.4 灰显双括号）
- 嵌入照片：全宽 `aspect-[16/7]`，object-cover，**原型为 grayscale + contrast-125；本 PRD 决策为保留原色**

**Places Today 模块：** `bg-surface-container p-8`
- 标题 `PLACES TODAY` 同 section heading 样式
- 列表项：左侧时间 chip（黑底白字 Mono 10px `px-1.5 py-0.5`）+ wiki-link 名称 + 灰色斜体注解（如 `— breakfast meeting`）

**Threads（追问/线程）模块：**
- 标题 `THREADS`
- 卡片网格（mobile 单列，md+ 双列）`gap-4`
- 单卡片：`bg-surface-container-high p-6`，hover `bg-surface-container-highest`，active `scale-[0.98]`
- 主文：Inter 14px font-medium leading-snug
- 底部 CTA 行：`text-wikilink` (#5D3000) + Mono 10px uppercase font-bold + 14px arrow_forward 图标（如 `View analysis →`、`Extract metadata →`）
> 点击 Thread 卡片对应 US-015：跳回 Today Flow 输入栏并预填该追问文本

**Footer：**
- 顶部 1px `surface_container_highest` 横线
- 左：`Compiled from 7 raw entries`（Mono 10px uppercase tracking-widest, on_surface_variant）
- 右：`View original flow →`（Mono 10px font-bold uppercase 黑色，下划线 underline-offset-4）
- 最底部：`Protocol v.4.0.1 // Vientiane // Archival Grade` 居中（Mono 9.6px outline_variant uppercase tracking-widest）

#### S4a · Archive – Calendar View

**Top App Bar：** 左 `arrow_back` + `ARCHIVE`（Space Grotesk 700 uppercase）+ 右搜索图标

**月份导航：** 左右箭头 + `APRIL 2026`（Space Grotesk 标题，居中）+ 右侧 `CALENDAR / LIST` segmented control

**日历网格：** 7 列网格，星期表头 Mono 10px on_surface_variant；每格正方形 `aspect-square`：
- **热力填充规则**（基于当日 memo 总数）：
  - 0 条：`surface` (#F9F9F9)
  - 1-2 条：`surface_container_high` (#E8E8E8)
  - 3-5 条：`primary_fixed_dim` (#474747)
  - 6+ 条：`primary` (#000000)
- 日期数字 Mono 11px，灰格中黑字、深格中白字
- 当日格子有 1px 黑色额外描边

**Legend：** 网格下方 4 个色块 + Mono 10px 标签：`EMPTY` / `LOW` / `MEDIUM` / `HIGH DENSITY`

**Monthly Summary 模块：** `bg-surface-container p-6`，标题 `APRIL SUMMARY`
- 4 个统计单元：每单元 Mono 10px 标签 + Space Grotesk 36px 大数字
  - `TOTAL ENTRIES`：142
  - `VOICE RECORDING DURATION`：48 MIN
  - `PHOTOS CAPTURED`：24
  - `UNIQUE LOCATIONS`：2
- 底部一张全宽月度精选照片 + 元数据底栏（如 `SYSTEM STATUS: SYNCHRONIZED ...`）

#### S4b · Archive – List View

**月份导航 + Segmented Control：** 同 S4a，但 LIST 选中

**列表项：** `bg-surface-container p-6`，间距 `space-y-4`
- 每项布局：
  - 左侧 4px 黑色边框（`border-l-4 border-primary`）
  - 上方一行：日期 Space Grotesk 700 uppercase（如 `APRIL 14`）+ 右上角状态徽章
    - `VERIFIED`：黑底白字 Mono 9px chip（已完成编译且经用户查看）
    - `Metadata Only`：灰底灰字 Mono 9px chip（仅有元数据，未编译或无内容）
  - 一句话摘要：Inter 14px italic（直接复用 Daily Page 副标题）
  - 元数据行：3 个图标 + Mono 11px 计数（`📄 7 entries`、`📷 3 photos`、`🎙 12 min voice`）

#### S5 · Entity Page（继承 S3 排版规则）

由于设计稿未单独提供 Entity Page，复用 Daily Page 的视觉系统：
- 顶部：`arrow_back` + 实体名（Space Grotesk uppercase）
- 主标题：实体名（Display-LG），副标题：`PLACE / PERSON / THEME`（tracking-widest）
- 元数据 chips：`first seen 2026-03-12` / `12 mentions` / `Vientiane`
- 正文：Markdown 渲染，wikilink 同 S3 规则
- 底部模块：`RELATED MEMOS`（按时间倒序的列表，每项 = 时间 chip + 摘录）

### 6.4 设计稿存档

所有 Stitch 设计资产已下载到仓库：
- `design/stitch/screenshots/` — 5 个屏幕的 PNG 截图
- `design/stitch/html/` — 5 个屏幕的完整 HTML/Tailwind 源码（含颜色 token 定义）
- 实施时如有歧义以 HTML 源码为准（精确像素值、类名、Material Symbols 名）

### 6.5 与原型的两处不同（已决策）

1. **照片处理：** 原型对所有照片应用 `grayscale + contrast-125` 滤镜营造档案感。**本 MVP 决策：保留原色**（与 PRD §6.3 "颜色本身是重要原始数据"一致）。Daily Page 中的嵌入照片亦不去色。
2. **`amber-archival` 范围：** 原型在 Daily Page wikilink 也用此色。**本 PRD 沿用**——`#5D3000` 同时承担"采集中"和"知识跳转"两类语义，不再扩展。

### 6.6 交互原则

- 输入永不跳转页面（语音为浮层 60% 高，不是独立路由）
- memo 提交后即时出现在时间轴顶部，无需等待 API
- 照片保留原色（颜色本身是重要原始数据）
- AI 编译结果以被动方式呈现（顶部黑色卡片），不打断用户输入流
- 按钮反馈用 translate / invert，禁用 scale（除 Threads 卡片）和 opacity 渐变
- 任何"列表项分隔"用 `gap` 而非 1px 描边

## 7. 技术考虑

### 7.1 平台与技术栈

- **目标平台：** iOS 16+（原生优先）
- **开发语言：** Swift 5.9+
- **UI 框架：** SwiftUI 为主，UIKit 补充（`PHPickerViewController`、`UIImagePickerController` 等原生控件直接复用）
- **最低部署：** iOS 16.0

### 7.2 iOS 原生能力依赖

| 能力 | 原生 API | 用途 |
|-----|---------|-----|
| 定位 | CoreLocation `CLLocationManager` | GPS 坐标 |
| 反向地理编码 | CoreLocation `CLGeocoder` | 地名解析（不出境） |
| 麦克风 / 录音 | AVFoundation `AVAudioRecorder` | 语音采集 |
| 相机 / 相册 | PhotosUI `PHPickerViewController` | 照片输入 |
| EXIF 读取 | ImageIO `CGImageSource` | 照片元数据 |
| 后台任务 | BackgroundTasks `BGAppRefreshTask` | 凌晨自动编译 |
| 本地通知 | UserNotifications | 编译完成提醒 |
| 文件系统 | FileManager + Documents 目录 | Vault 存储 |
| 文件共享 | Info.plist `UIFileSharingEnabled`、`LSSupportsOpeningDocumentsInPlace` | 让用户导出 Vault |

### 7.3 外部依赖

| 服务 | 用途 | 接入方式 |
|-----|-----|---------|
| 阿里云 DashScope (`qwen3.5-plus`) | 每日编译 | OpenAI 兼容接口，POST `/chat/completions` |
| OpenAI Whisper API | 语音转文字 | POST `https://api.openai.com/v1/audio/transcriptions` |
| OpenWeatherMap | 天气采集 | GET `/data/2.5/weather?lat={lat}&lon={lon}` |

### 7.4 Swift 依赖包（建议）

- **Yams**（或自写简易 YAML 解析）—— frontmatter 解析
- **MarkdownUI** 或原生 `AttributedString` —— Markdown 渲染
- 其余能用系统 API 就不引第三方

### 7.5 密钥管理方案

- `.env` 文件位于项目根目录（被 `.gitignore`）
- Xcode Build Phase 运行脚本读取 `.env` → 生成 `Config/GeneratedSecrets.swift`（亦 gitignore）
- 生成的 Swift 文件形如：
  ```swift
  enum Secrets {
      static let dashscopeApiKey = "sk-sp-..."
      static let dashscopeBaseURL = "https://coding.dashscope.aliyuncs.com/v1"
      static let dashscopeModel = "qwen3.5-plus"
      static let openaiWhisperApiKey = "sk-proj-..."
      static let openweatherApiKey = "REDACTED_OPENWEATHER_KEY"
  }
  ```
- `.env.example` 提交入仓库，列出所有键名但值为占位
- CI / 新开发者拉代码后 `cp .env.example .env` 填入真实值

### 7.6 性能目标

- App 启动到可输入：< 2 秒（冷启动）
- Memo 提交到出现在时间轴：< 1 秒
- 每日编译（20 条 memo 平均情况）：< 3 分钟
- 时间轴滚动：60 FPS 无卡顿

### 7.7 隐私与数据边界

- 位置、照片原图、音频文件仅存储在本地
- 调用 Whisper API 时音频需上传（网络依赖是已知取舍）
- 调用 DashScope 时上传的是 memo 文本内容 + 元数据，不上传原始音频和图片
- 调用 OpenWeather 时上传的是 GPS 坐标
- 反向地理编码使用 iOS 原生 `CLGeocoder`（Apple 隐私策略保护范围内）

## 8. 成功指标

| 指标 | 目标 |
|-----|-----|
| 日均输入 memo 数 | ≥ 5 条 |
| 每条 memo 输入耗时 | < 30 秒 |
| 周留存率（连续 7 天有输入记录） | ≥ 60% |
| AI 追问点击率 | ≥ 20% |
| Daily Page 查看率（编译后次日查看） | ≥ 70% |
| App 启动到可输入时间 | < 2 秒 |
| 每日编译成功率 | ≥ 95% |

## 9. Open Questions

1. **多天补编译策略**：用户连续几天未打开 App，期间的后台任务未触发，次日打开时是一次性把所有缺失天数都编译，还是只编译最近一天？（当前倾向：批量补编译，但按时间顺序串行，避免并发打爆 API 配额。）
2. **Daily Page 编译失败重试**：LLM 返回格式错误或超时，是否自动重试？重试几次？（当前倾向：最多重试 1 次，再失败则记录到 `log.md` 等待用户手动触发。）
3. **Entity Page slug 冲突**：同名但不同实体怎么区分（比如两个叫"Joma Coffee"的店）？（建议：由 LLM 在 slug 中附加城市后缀，如 `joma-coffee-vientiane`。）
4. **`.env` 密钥轮换**：当前密钥已明文记录在本 PRD 中，MVP 上线前是否需要轮换？
5. **iCloud Drive 存储**：MVP 是否把 Vault 直接放在 iCloud Drive 容器里实现"免同步"，还是留在 App Sandbox 让用户手动导出？（当前决策：App Sandbox，不绑定 iCloud；用户自行用外部工具同步。）
6. **DashScope 成本控制**：单次编译 token 消耗需要实测，必要时引入 `log.md` 中的累计消耗统计与月度预算提醒。
7. **首次启动引导**：是否需要权限请求引导页（麦克风、定位、通知、照片）？还是按需触发？（当前倾向：按需触发，减少前置摩擦。）

---

## 附录 A：Daily Page 编译 Prompt 模板

```
你是 DayPage 的每日编译引擎。你的任务是将用户今天的所有原始 memo 编译成一篇结构化的日记页。

输入：
1. 今天的所有 raw memo（带元数据）
2. hot.md（最近 3-5 天的上下文缓存）
3. 相关的 Entity Page 列表

编译规则：
- 按时段组织叙事（上午/下午/晚上），不要逐条复述 memo
- 识别地点、人物、主题，创建 [[wiki 链接]]
- 生成一句话的当日摘要作为副标题
- 列出今日去过的所有地点
- 在底部生成 2-3 条追问，基于：今日内容、位置信息、跨时间模式
- 追问应该具体、个人化，不要泛泛而谈
- 保持用户的原始语气和用词，不要过度润色
- 所有内容用中文书写（除非用户原文用了其他语言）

输出格式（严格 JSON）：
{
  "daily_page": "完整的 Markdown 正文（含 frontmatter）",
  "entity_updates": [
    {"entity_type": "places|people|themes", "entity_slug": "...", "section": "...", "content": "..."}
  ],
  "hot_cache": "更新后的 hot.md 全文"
}
```

## 附录 B：Memo 数据结构示例

```yaml
---
id: memo_20260414_084200
type: mixed
created: 2026-04-14T08:42:00+07:00
location:
  name: "Joma Coffee, Setthathirath Rd"
  lat: 17.9632
  lng: 102.6132
weather: "32°C, 多云"
device: "iPhone 15 Pro"
attachments:
  - type: image
    file: assets/IMG_4021.jpg
    exif: {aperture: 2.8, shutter: "1/250", iso: 100}
  - type: audio
    file: assets/voice_084200.m4a
    duration: 45s
    transcript: "..."
---

早上来 Joma Coffee 试试，之前路过好几次了。今天空气特别湿。
```

多条 memo 在同一天文件中的分隔：

```markdown
---
id: memo_20260414_084200
...
---

早上来 Joma Coffee 试试...

---

---
id: memo_20260414_123015
...
---

湄公河边吃午饭，烤鱼配糯米饭...
```
