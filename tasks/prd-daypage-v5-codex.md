# PRD: DayPage V5 · Codex —— 终极形态产品蓝图

> **生成日期**：2026-05-10
> **作者**：Claude（与主理人 Xinwei 共同澄清）
> **来源**：Anthropic Claude Design 导出包 `daypage-system/`（Codex 原型 6 视图 + 1172 行 CSS）+ iOS V1-V4 PRD 演化历史 + 主理人对终极形态的口述
> **目标版本**：V5.0(跨端知识系统时代)
> **状态**：**主理人 review 中** —— 重大方向决策已锁定（见 §0），细节实现待 Wave 拆分
> **本文档与既有 PRD 关系**：
> - V1 = MVP 原型 / V2 = 功能补完 / V3 = 体验升级 / V4 = liquid-glass 视觉
> - **V5 = 平台跃迁**：从「iOS 单机日志工具」→「跨端 AI 知识系统 Codex」
> - V1-V4 的所有功能继续承袭，V5 新增 Web 端、AI 主动行动、多设备同步、终极形态愿景
> **本 PRD 不是工程实施排期**，是产品蓝图。具体技术方案见姊妹文档 `docs/web/PLAN.md`。

---

## 目录

- [§0 锁定决策](#0-锁定决策)
- [§1 产品愿景与价值主张](#1-产品愿景与价值主张)
- [§2 用户画像](#2-用户画像)
- [§3 终极形态全景图](#3-终极形态全景图)
- [§4 功能模块详述（24 个模块）](#4-功能模块详述)
- [§5 用户故事（72 条 US）](#5-用户故事)
- [§6 功能性需求（FR · 编号锁定）](#6-功能性需求-fr)
- [§7 AI Agent 主动行动模型](#7-ai-agent-主动行动模型)
- [§8 数据模型与跨端同步](#8-数据模型与跨端同步)
- [§9 多平台战略](#9-多平台战略)
- [§10 设计语言与品牌系统](#10-设计语言与品牌系统)
- [§11 Non-Goals（明确不做）](#11-non-goals)
- [§12 终极形态商业模型（描述，不实施）](#12-终极形态商业模型)
- [§13 隐私、安全、合规](#13-隐私安全合规)
- [§14 北极星与成功指标](#14-北极星与成功指标)
- [§15 Wave 拆分与里程碑](#15-wave-拆分与里程碑)
- [§16 风险登记册](#16-风险登记册)
- [§17 Open Questions](#17-open-questions)

---

## §0 锁定决策

主理人在 PRD 启动澄清环节明确确认：

| 决策维度 | 锁定方向 |
|---|---|
| **核心价值主张** | **三合一**：「思考的档案库」+「数字生命」+「习惯追踪/年度总结」—— 同一产品在不同**时间维度**与不同**用户成熟度**下的不同感知。三者共享底层 raw memo 数据 + AI 编译引擎，差异在编译产物的呈现层。 |
| **变现** | **本 PRD 不实施订阅/支付** —— 只在 §12 描述形态。所有 V5 wave 都按"无支付门槛"开发；功能边界按"全用户都能用全部功能"画。 |
| **范围** | **完整版** —— 终极形态全景图，含 iOS / Watch / macOS / Web / 企业版 / 公开 API。3 年路线图。 |
| **激进度** | **中等激进** —— 含 AI Agent 主动行动、多模态输入、跨设备无缝。**不含**：跨用户公共知识云 marketplace、用户间语义网络分享、第三方插件市场。 |
| **设计来源** | **Codex 原型为 Web 端的 1:1 视觉参考**（warm-archival 美学），但功能必须真实可生产 |
| **技术栈** | 见 `docs/web/PLAN.md`：Next.js 16 + Supabase + Auth.js v5 + Drizzle + Inngest + 后端代理 AI |
| **iOS** | 继续承袭 V1-V4 全部能力；新增云同步 + 卸载本地 AI key |

---

## §1 产品愿景与价值主张

### 1.1 一句话产品定义

> **DayPage 是一个把「你今天乱糟糟的输入」编译成「你将来能反向检索的自己」的跨端 AI 知识系统。**

### 1.2 三层价值主张（同一产品的不同感知层）

DayPage 终极形态在用户视角是**同一个产品**，但在不同使用阶段、不同人格、不同年龄段，会被感知为不同的东西：

#### 层 A · 「思考的档案库」（Thinking Archive）

**面向**：知识工作者、研究者、创作者、深度学习者
**心智**：我有大量碎片输入（论文 PDF、播客笔记、灵光一现、对话），我不想再用 Notion/Obsidian 手动整理。
**形态感知**：DayPage 像 Notion + Obsidian + Roam Research 的 **AI 自治版**——你只管丢，系统主动建 wiki、连 backlink、画 graph、抽 entity。
**核心使用动作**：Add（投喂）→ Wiki 浏览 → Chat（RAG 问答）→ Inbox（处理 AI 主动建议）
**对应 Codex 视图**：Add / Wiki / Chat / Inbox 是这层用户的主战场

#### 层 B · 「数字生命」（Digital Life Twin）

**面向**：所有重度长期用户（用了 1 年以上的人）
**心智**：DayPage 知道我去年这个时候在哪、说过什么、读过什么、心情如何——它**变成了我可以对话的过去**。
**形态感知**：On This Day、Year in Review、"问 2024 年的你怎么看这件事"、AI Persona（基于你历史输入训练的对话风格）。
**核心使用动作**：Home 页的「the system noticed」卡片、与"过去的自己"对话、年度/月度回顾、"那次去东京我说了什么？"地图检索
**对应 Codex 视图**：Home / Chat 是这层的主入口；这层在 V5 中通过 §7 AI Agent 显式触达

#### 层 C · 「习惯追踪 + 生活记录」（Lifelog）

**面向**：轻度用户、生活记录爱好者、Day One 老用户、心境日记用户
**心智**：我就想记一下今天去了哪、做了什么、心情如何，最好能定期看到"我这个月做得怎么样"。
**形态感知**：每天打开 Today 输入两句话 → 月底/年底自动出图文回顾报告 → 偶尔翻 archive。
**核心使用动作**：Today 输入 → Archive 月历视图 → Weekly Recap → On This Day
**对应**：iOS 端 V1-V4 已有完整支持；V5 增强是**自动报告分发**（每周日早上推送一份"上周的你"卡片）

### 1.3 三层之间的演化路径

```
新用户 → 层 C（轻量记录，1-2 周）
       → 层 A（开始投喂深度内容，AI 编译产生第一批 wiki page）
       → 层 B（积累 6 个月以上数据后，"过去的自己"具象化）
```

**关键洞察**：用户**不会自己跨越层级**。产品必须在合适时机**主动暴露下一层**：
- 第 14 天首次 Wiki 自动生成 → 推送「你已经有第一份知识网络了」 → 引导进入层 A
- 第 180 天首次 Year in Review 候选 → 推送「过去半年的你长这样」 → 引导进入层 B

### 1.4 与竞品的差异化（一句话定位）

| 竞品 | 它的强项 | DayPage 的差异点 |
|---|---|---|
| Day One | 漂亮的日记体验 | DayPage 比它**多 AI 编译**，碎片→结构化 |
| Notion | 全能数据库 | DayPage 比它**少手动**，AI 自治建 wiki |
| Obsidian | 双向链接 + 本地优先 | DayPage 比它**多移动端 + AI**，且 backlink 自动建 |
| Roam Research | 思维网络 | DayPage 比它**多多模态输入 + 跨端** |
| Notebook LM | RAG 问答 | DayPage 比它**多日常 capture + 长期演化** |
| Reflect / Mem | AI + 笔记 | DayPage 比它**多 nomad/位置/语音原生支持 + 跨端深度同步** |

**一句话**：**没有任何竞品同时具备 ① iOS-first 的低摩擦 capture + ② 真正的 AI 自治编译 + ③ 跨端无缝 + ④ 长期演化的"数字生命"叙事**。这四点的组合就是 DayPage 的护城河。

---

## §2 用户画像

### 2.1 P1 主画像 · "数字游民学者" Aria

- **基本信息**：32 岁，独立研究者 / 技术写作者，常驻清迈+东京+里斯本三地
- **设备**：iPhone 16 Pro + Apple Watch + MacBook Air M3 + iPad Pro
- **当前痛点**：
  - 每天读 5+ 篇论文 / 听 3 个播客 / 拍照若干，灵感丢一半
  - Notion 维护成本太高，Obsidian 在手机上烂
  - 在飞机上没法用 cloud 工具
- **使用场景**：
  - 早上散步：iPhone 语音记 30s 想法
  - 咖啡馆工作：Mac 上 paste 论文 URL → 一会儿出现在 wiki
  - 飞机上：iPhone 离线翻 wiki 找上次写过的某个概念
  - 月底：Mac 上跑 Year in Review，导出 PDF 给自己

### 2.2 P2 副画像 · "终身学习者" Felix

- **基本信息**：40 岁，产品经理，业余学量子计算
- **设备**：iPhone + Mac
- **使用频次**：每天 5-10 条 memo
- **核心需求**：把碎片学习变成"半年后还记得的知识"，而不是"读过就忘"

### 2.3 P3 副画像 · "生活记录人" Sky

- **基本信息**：28 岁，设计师，喜欢拍照、写日记、看心情曲线
- **设备**：iPhone + Watch
- **核心需求**：日记 + 照片 + 月度回顾，**几乎不关心 wiki/chat**，但喜欢 On This Day 给的惊喜

### 2.4 P4 终极画像 · "5 年用户" Aria-2031

- 已经积累 **3 万+** memo、**500+** wiki page、**80+** entity
- 每周要问"过去的自己"3-5 次
- 把 DayPage 当作"外部记忆"，遗忘内部记忆
- **新风险**：数据迁移恐惧、平台 lock-in 焦虑 → V5 必须解决（§13）

---

## §3 终极形态全景图

### 3.1 产品矩阵（5 端 + 1 平台）

```
                       ┌─────────────────────────────────┐
                       │   DayPage Cloud (Backend)       │
                       │   PostgreSQL + Inngest + R2 +   │
                       │   AI Engine (DashScope/Claude)  │
                       └────────────┬────────────────────┘
                                    │ /api/v1/*
        ┌──────────┬───────────────┼─────────────┬──────────────┐
        ▼          ▼               ▼             ▼              ▼
   ┌────────┐ ┌────────┐  ┌─────────────┐ ┌──────────┐  ┌──────────┐
   │  iOS   │ │ Watch  │  │  macOS App  │ │   Web    │  │ Public   │
   │ (主)   │ │ (语音) │  │ (深度工作)  │ │ (Codex)  │  │   API    │
   └────────┘ └────────┘  └─────────────┘ └──────────┘  └──────────┘
       ▲          ▲              ▲             ▲              ▲
       │          │              │             │              │
   capture     capture       work-mode      browse +       第三方
   on the go   wrist         long-form      share        integrations
```

### 3.2 五端功能矩阵

| 功能 | iOS | Watch | macOS | Web | API |
|---|:---:|:---:|:---:|:---:|:---:|
| Today Quick Capture（文字/语音/照片/位置） | ● | ◐ (语音) | ● | ● | ● |
| Archive 月历回看 | ● | ○ | ● | ● | ● |
| Wiki 浏览 | ● | ○ | ● | ●● (主) | ● |
| Wiki 编辑（annotation） | ● | ○ | ● | ●● (主) | ● |
| Graph 图谱视图 | ◐ | ○ | ●● (主) | ●● (主) | ● |
| Chat / RAG 问答 | ● | ◐ (Siri) | ●● | ●● | ● |
| Inbox 处理 AI 建议 | ● | ◐ (推送) | ● | ●● (主) | ● |
| AI Agent 主动行动 | ● | ● | ● | ● | – |
| 全局搜索 | ● | ○ | ●● (Spotlight) | ● | ● |
| Year in Review 报告 | ● | ○ | ●● (PDF 导出) | ●● (网页分享) | ● |
| Onboarding | ● | – | ● | ● | – |
| 实体页（Entity） | ● | ○ | ● | ● | ● |
| Settings / Account | ● | ◐ | ● | ●● (主) | – |
| 数据导出 / 删除账号 | ● | – | ● | ● | ● |
| Webhook / 第三方接入 | – | – | – | ● | ●● (主) |

图例：● 完整 / ●● 主战场 / ◐ 简化版 / ○ 不做 / – 不适用

### 3.3 终极形态的"完整一天"剧本

> **2027 年 11 月 15 日，Aria 在里斯本一家咖啡馆，距离 V5 上线 18 个月**

**07:32** 散步路上，iPhone 锁屏滑出 capture 卡片，按住 Watch 表冠说：「今天读 Henrik 的 Spanner 论文有个新理解——TrueTime 不是技术细节，是 Google 在赌"误差可量化"作为产品哲学」 → Watch 上传到 Cloud

**07:45** 早餐时打开 iPhone，**Home 页 AI Agent 卡片**：「我注意到这是你 14 天内第 3 次提到 TrueTime。已经把它从 'mention' 升级为独立 Concept Page，并把你 9 月那条 Spanner 笔记和 5 月的 Lamport 引用全连进来了。要不要看看？」

**09:15** 在 Mac 上打开 DayPage Web，**Wiki Graph** 视图，TrueTime 节点周围已经有 7 条边。点开看到完整 page，AI 已经给"误差可量化"那段做了 `important` 标记（基于 Aria 过去对类似句子的高亮模式）

**11:20** 在 Web 端 Add 框 paste 一个 PDF URL（Hennessy 的新书章节）→ 立即出现在 Compile Queue → 25 秒后变 done → Inbox 弹一条「这本书 Ch.4 与你已有的 'Replicated state machines' 页 5 处冲突——它说 leaderless 在 multi-region 才占优，你之前的笔记说 single-leader 永远更快。要不要把这条挂为 tracked contradiction？」

**14:00** 飞往清迈的航班起飞前，iPhone 自动拉取最新 wiki snapshot → 飞机上离线翻看 → Annotate 几句

**18:40** 落地后 Apple Watch 推送：「检测到你换了时区。已自动用清迈天气更新今天 location memo。要不要播放一段 'on this day in 2026' 的语音回顾？你去年同一天也在清迈。」

**22:30** 睡前 iPhone 推「**周报候选**」卡片 → 一键生成 → 分享给伴侣

**关键观察**：这一天里，Aria 主动操作 ≈ 6 次；AI 主动触达 ≈ 5 次。**主动:被动比例 = 1.2:1**。这是终极形态的核心设计准则：**AI 不再是工具，而是"住在数据里的同事"**。

---

## §4 功能模块详述

V5 终极形态共包含 **24 个功能模块**，分为 6 大类：

### 4.A · Capture 类（输入端，4 个）

#### M1 · Universal Quick Capture（万能速记）
- 入口：iOS Today 页 / Watch 表冠 / Mac 全局快捷键 ⌥Space / Web 顶栏 / Siri / Share Sheet / Email-to-DayPage
- 输入类型自动识别：文字 / 语音（自动转写）/ 照片（自动 OCR + EXIF）/ 视频（首帧+音频转写）/ URL（抓取+清洗）/ 文件（PDF/EPUB/Markdown 解析）/ 位置（自动捕获 + 反向地理编码）
- **每条 memo 强制嵌入元数据**：时间、位置、天气、设备、网络状态、电量（用于行为模式分析）
- 离线写入本地 → 联网自动同步
- **3 秒规则**：从想到记到的时间不超过 3 秒（含锁屏唤醒）

#### M2 · Voice-First Capture（语音优先）
- 长按发送键开始录 → 松手停止 → 自动转写显示在卡片
- 转写引擎：Whisper (短) / DashScope ASR (中) / 本地 Apple Speech (离线)
- 同时保留 m4a 原音频 → 后期可重听 / 重转写
- Watch 端支持 1 分钟以内语音，自动转 iPhone 同步队列
- AI 后处理：去口头禅、加标点、识别关键实体

#### M3 · Multimodal Capture（多模态输入，激进）
- **AR 标注**：iOS Camera 拍黑板 → AR 模式直接在画面上画箭头标注 → 保存为带标注的图像 memo
- **手势/手势库**：用户自定义 3D Touch 手势 → 一键调用某个 capture 模板（如"读书笔记"）
- **音频环境识别**：录音时检测背景音（咖啡馆/飞机/室外）→ 自动加 tag
- **眼动追踪笔记**（Vision Pro 适配，Post-V5）

#### M4 · Inbox-from-Anywhere（外部入口）
- **Email-to-DayPage**：用户拿到一个 `<userid>@in.daypage.io` 邮箱地址 → 转发任何邮件即入 Inbox
- **Webhook ingest**：第三方服务 POST `/api/v1/ingest` → 进 raw 队列
- **浏览器扩展**：Chrome/Safari 扩展，一键剪藏当前页（含选中文本/截图/URL）
- **iOS Share Sheet**：分享任何 App 内容到 DayPage
- **macOS Finder Quick Action**：右键文件 → "Send to DayPage"

### 4.B · Compile 类（AI 编译引擎，4 个）

#### M5 · Two-Tier Compile（双档编译）
- **LIGHT 模式**（默认 reading-only 内容）：
  - 仅生成摘要、关键词、可能 entity → 挂到 source page
  - 不创建 concept page、不更新 wiki
  - 用户在 Add 视图可一键 upgrade 为 FULL
- **FULL 模式**（默认 user-authored 内容）：
  - 召回相关 page top-K → 让 LLM 决定 patch 操作
  - 可能产生：更新现有 page / 新建 concept page / 抽取 entity / 创建 backlink / 触发 inbox（schema 建议、矛盾检测）
- **触发策略**：
  - 用户输入：默认 FULL
  - 抓取的 web 内容：默认 LIGHT，AI 评估"信号密度"决定是否升级
  - 用户可在 Settings 永久切换默认档

#### M6 · Compile Pipeline（编译流水线）

每个 memo 经历的 step（每步幂等、可单独重跑）：

```
1. NORMALIZE   清洗格式、提取纯文本
2. TRANSCRIBE  voice → text（如适用）
3. OCR         photo → text（如适用）
4. FETCH       URL → article body（如适用，readability 算法）
5. CHUNK       切段（按段落或固定 token 数）
6. EMBED       text-embedding-v3 → 1536-d vector
7. RECALL      向量召回 top-K 相关 page
8. COMPILE     LLM 生成 patch（JSON tool calling）
9. APPLY       事务性写入 page / link / source / annotation
10. INDEX      更新搜索索引、backlink count
11. NOTIFY     SSE 推前端 / push 通知
12. ACT        触发 §7 Agent 评估是否需主动行动
```

#### M7 · Schema Detection（自动建 cluster）
- 后台 worker 定期（每 50 条新 memo 跑一次）
- 用 HDBSCAN 在最近 N 条 memo 的 embedding 上做聚类
- 发现"明显但未命名"的 cluster → 推 inbox：「这 14 条都聊 X，要不要建一个新 domain 'X'？」
- 用户接受 → 自动创建 domain + 把这些 memo 关联

#### M8 · Conflict Detection（矛盾检测）
- 每次新 memo 编译时，LLM 检查与现有 page 的语义冲突
- 检测到冲突 → 写 inbox 的 CONTRADICTION 项，包含：
  - 旧表述 + 新表述对比
  - 4 个动作：Keep both as tracked / Use new / Keep mine / Open both pages
- 用户解决后，patch 应用到 page，并记录 `change_log` 表

### 4.C · Knowledge Surface（知识呈现，6 个）

#### M9 · Wiki Page System
- **页类型**：Concept / Source / Entity / Synthesis / Daily / Domain
- 每个 page 含：title、type、domain、status (live/draft/archived/cold)、body_md、metadata、source_count、backlink_count
- **Daily Page** 自动生成：每晚 00:30 把当日所有 memo + 编译产物聚合成一份 daily diary
- **Synthesis Page**：用户在 Chat 里"Save as synthesis page"产出
- **Cold Storage**：90 天无访问、无 backlink 的 page → 推 inbox 询问归档

#### M10 · Wiki Navigation
- 左侧分组导航（Concepts / Sources / Entities / Synthesis / Daily / Domains）
- 顶部搜索（`/` 快捷键全局聚焦）
- 列表 / Graph 双模式切换
- 每条带 meta（source 数 / 是否 draft / 是否含冲突）

#### M11 · Knowledge Graph（图谱）
- **三层视图**：
  - **Domain 视图**：node = page, edge = link（Codex 静态版）
  - **Entity 视图**：node = entity（人/组织/项目/地点），edge = co-mention
  - **Time 视图**：横轴时间，纵轴 domain，散点是 memo
- **交互**：拖拽、缩放、点击展开、按 type 过滤、按 domain 染色
- **物理引擎**：force-directed（节点 >100 时降级到分层 layout）
- macOS / Web 主战场；iOS 简化版（只看不编辑）

#### M12 · Annotation Layer（用户标注层）
- 用户在 page 上选中文本 → 弹 toolbar：标记为 important / questionable / 自定义 tag / 添加 note
- 标注存独立表，不修改 page body
- AI 重新编译时**读取**用户标注作为信号 → "用户标了 important 的句子，下次扩展这个 concept 时要保留"
- Annotation 在前端通过 `<mark>` 渲染，不同 tag 不同颜色

#### M13 · Provenance Trail（来源追溯）
- 每个 page 段落可点击 → 显示「这段来自 memo X、memo Y」
- 每条 memo 可反查 → "我贡献了哪些 page 的哪些段落"
- 时间机器：选某个时间点 → 看 page 在那时候长什么样
- Compile log：每次 LLM patch 都有完整 prompt + response + 决策 rationale 记录

#### M14 · Search & Discovery
- **混合搜索**：BM25（keyword）+ 向量（语义）+ metadata filter
- 搜索范围：page / memo / entity / annotation 四类切换
- 联想：边输入边显示「相似的过去 memo」「相关 page」
- **"模糊回忆"模式**：用户输入"我去年那个关于啥来着..." → AI 反向问 3 个澄清问题 → 定位

### 4.D · Conversation & Agent（对话与代理，4 个）

#### M15 · Wiki Chat（基于个人 wiki 的 RAG）
- 对话基础：仅基于用户自己的 wiki + memo（不引外部知识）
- 数字引用 `{n}` 强制格式 → 解析为 reference cards
- Suggested follow-ups（每答必给 3 条）
- "Save as synthesis page" → 把这个对话凝练成 page
- 多 thread 管理（左侧 thread 列表）
- 长对话自动 compaction

#### M16 · Past-Self Dialogue（与过去的自己对话）
- 选定时间段（"2024 年 9 月"）→ 系统用那段时间的 memo 作 context 训练 mini persona
- 用户问：「2024 年 9 月的我怎么看待远程工作？」
- AI 用第一人称回答，引用具体当时的 memo
- 极强情绪冲击力 → "层 B：数字生命"的核心体验

#### M17 · AI Agent · Observer（观察者代理）
- 长驻后台，定时（每天/每小时）扫描数据
- 输出 4 类 Inbox 项 + Home 页 observations 卡片
- 详见 §7

#### M18 · AI Agent · Actor（行动者代理）
- 用户授权后可执行的"动作"：
  - 自动归档冷 page
  - 自动 merge 重复 entity
  - 自动给新 memo 打 domain tag
  - 自动生成 weekly recap 草稿
  - 调用外部 API（如查 arXiv 补 reference）
- 所有 Actor 行动有 audit log，可逐条撤销
- 详见 §7

### 4.E · Reflection & Memory（反思与记忆，3 个）

#### M19 · On This Day（今日回顾）
- iOS V3 已实现简版；V5 升级：
  - 跨年回顾（"2024/2025/2026 同一天"）
  - 不仅看 memo，还看那天的 page diff（"那天你新建了 X concept"）
  - AI 写 1 段 "你那天" 的总结
  - 可设定时推送（早 7:00 / 午 12:00 / 晚 22:00）

#### M20 · Periodic Recap（周报/月报/年报）
- **Weekly Recap**：每周日 18:00 自动生成草稿 → 推送 → 用户编辑确认 → 保存为 page
- **Monthly Recap**：每月 1 日 → 含数据图（最常去的地点、最活跃的 domain、出现最多的 entity）
- **Year in Review**：每年 12/20 → 含整年所有维度的可视化 + AI 写的"年度叙事"+ 可分享网页 URL
- 用户可一键导出 PDF
- macOS 端有专门的 "Recap Builder" 编辑器

#### M21 · Memory Lane（记忆漫步）
- "随机漫步"按钮 → 系统随机选 5 条尘封 memo + 1 个被遗忘 page
- "情绪回放"：选定情绪标签 → 看历史上同类情绪的所有 memo
- "地图回放"：地图视图 → 点某个城市 → 看所有发生在那的 memo

### 4.F · System & Trust（系统与信任，3 个）

#### M22 · Cross-Device Sync（跨端同步）
- 后端 PostgreSQL = single source of truth
- iOS 用 vault `.md` 作离线缓存（仍是 V1-V4 的格式）
- Web/macOS 用 IndexedDB / SQLite 作离线缓存
- 同步协议：拉模型（device 主动 GET `/api/sync?since=cursor`）+ SSE 推（后端有更新立即推 push notification）
- 冲突策略：last-write-wins，但 user-edited annotation 永远优先于 AI patch

#### M23 · Privacy Vault（隐私保险箱）
- 任何 memo / page 可标记为 "private"
- Private 内容：不进 RAG context、不参与 cross-page link、不出现在 graph、AI 不能引用
- 用户主密码（独立于账号密码）解锁
- 详见 §13

#### M24 · Data Sovereignty（数据主权）
- 一键全量导出（ZIP 内含所有 raw markdown + 所有 page markdown + JSON 元数据 + 所有 attachment）
- 一键删除账号（GDPR 兼容，30 天内彻底清除，含 backup）
- 自托管选项（PRD V5 不实施，但架构预留）
- iOS vault 即"本地副本"，云端永远只是"加速器"，用户随时拔网线还能用

---

## §5 用户故事

> 共 **72 条 US**，按模块分组。每条 US 在 §15 Wave 拆分中归属到具体 Wave。
> Acceptance Criteria（AC）用 checklist 表达。
> 标记说明：
> - 🆕 = V5 全新功能
> - 🔄 = V1-V4 已有，V5 升级
> - 📱 = iOS / ⌚️ = Watch / 💻 = macOS / 🌐 = Web / 🔌 = API

### 5.A Capture 类（US-001 ~ US-014）

#### US-001 🆕 🌐 Web 端万能速记入口
**描述**：作为 Web 用户，我希望在任何页面都能快速调出 Add 输入框，让我能立即记录想法。
**AC**：
- [ ] 全局快捷键 `⌘K` 唤出 quick-capture 浮层
- [ ] 浮层支持 文字 / URL（自动检测） / 文件拖拽 / 录音（需麦克风权限）
- [ ] 提交后立即出现在 Compile Queue
- [ ] Esc 关闭，状态保留 5 分钟（防误关）
- [ ] 离线时入本地 IndexedDB 队列，恢复网络自动 push
- [ ] Verify in browser using dev-browser skill

#### US-002 🔄 📱 iOS 锁屏快速记录
**描述**：作为 iPhone 用户，我希望从锁屏控制中心一键打开 capture，长按发送键录音。
**AC**：
- [ ] iOS Control Center 添加 DayPage 快捷小组件
- [ ] 点开直达 Today，输入框自动聚焦
- [ ] 发送键长按 ≥0.3s 进入录音模式
- [ ] 录音过程中显示实时波形与时长
- [ ] 松手停止 + 自动转写 + 自动保存
- [ ] 录音中误触屏幕其他区域不停止
- [ ] 跑通 V3 PRD 已定的"语音转写完整率 100%"

#### US-003 🆕 ⌚️ Watch 表冠快速语音
**描述**：作为 Watch 用户，我希望按一下表冠侧键就能说话记一条。
**AC**：
- [ ] Watch App 主屏只有一个大按钮 + 当日 memo 数
- [ ] 长按表冠侧键启动 capture（可在 iPhone 端配置）
- [ ] 录音上限 60s（超时自动停止保存）
- [ ] 离线录制存本地 → 配对 iPhone 上线后自动同步
- [ ] Watch 显示「已同步 ✓」动画

#### US-004 🆕 🌐💻 全局快捷键速记
**描述**：作为桌面用户，我希望在任何应用里按快捷键唤出 DayPage 输入框。
**AC**：
- [ ] macOS 注册 `⌥Space`（可改）全局热键
- [ ] Web 端在 PWA 安装后注册 keyboard shortcut（Chromium API）
- [ ] 唤出的浮窗 max 480x320pt，固定屏幕中央
- [ ] 按 ⌘Enter 提交并关闭
- [ ] 提交后右上角显示 toast「Captured」3s

#### US-005 🆕 📱🌐 URL 智能抓取
**描述**：作为用户，我希望粘贴 URL 后系统自动抓取页面内容并整理。
**AC**：
- [ ] 输入框检测以 http/https 开头 → 显示 link 图标
- [ ] 提交后后端用 readability 算法抽正文（不抓导航/广告/侧栏）
- [ ] YouTube 链接 → 抽 transcript（如有字幕）
- [ ] 抓取失败 → 保存原 URL + 让用户手动粘贴正文
- [ ] 抓取成功后显示 word count、estimated read time
- [ ] AI 自动判断 LIGHT/FULL 档（reddit/twitter 默认 LIGHT，arxiv/wsj 默认 FULL）

#### US-006 🆕 🌐 文件拖拽上传
**描述**：作为 Web 用户，我希望直接把 PDF / 图片 / Markdown 拖到页面任何位置就能上传。
**AC**：
- [ ] 全页面支持 drop zone（拖入时显示半透明虚线框）
- [ ] 支持类型：PDF / DOCX / TXT / MD / JPG / PNG / HEIC / MP3 / M4A / WAV
- [ ] 单文件上限 50MB
- [ ] 多文件并行上传
- [ ] 上传中显示进度
- [ ] 上传完成后 PDF 自动 OCR + 切章节，每章节一条 memo
- [ ] Verify in browser using dev-browser skill

#### US-007 🆕 📱 iOS Share Sheet 接收
**描述**：作为用户，我希望从 Safari/Twitter/Apple Notes 一键分享内容到 DayPage。
**AC**：
- [ ] iOS Share Extension 显示 DayPage 图标
- [ ] 选择后展示精简 capture 表单（预填分享内容）
- [ ] 可选 LIGHT/FULL 档
- [ ] 不离开当前 App 即可保存
- [ ] 离线时入队列

#### US-008 🆕 🌐 浏览器扩展剪藏
**描述**：作为深度用户，我希望用浏览器扩展一键剪藏当前网页/选中文本。
**AC**：
- [ ] 提供 Chrome / Safari / Firefox 扩展
- [ ] 工具栏图标点击 → 弹小窗，预填页面 URL + 截图缩略图 + 选中文本
- [ ] 可加备注 + 选 tag
- [ ] 提交后扩展显示「Sent to DayPage ✓」

#### US-009 🆕 🔌 Email-to-DayPage
**描述**：作为用户，我希望转发任何邮件到我的专属 DayPage 邮箱即可保存。
**AC**：
- [ ] Settings 页显示用户专属地址 `<random>@in.daypage.io`
- [ ] 邮件标题作为 memo title
- [ ] 邮件正文清洗后作为 body
- [ ] 附件自动入 Storage，并关联到该 memo
- [ ] 防滥用：每个用户每天上限 100 封，超出告警

#### US-010 🆕 🔌 Webhook ingest
**描述**：作为开发者用户，我希望用 webhook 把第三方服务的内容打入 DayPage。
**AC**：
- [ ] Settings 生成 personal API token
- [ ] POST `/api/v1/ingest` 接受 `{type, body, metadata, attachments[]}` JSON
- [ ] 限流 60 req/min
- [ ] 返回 memo id + status
- [ ] 文档页有 curl 示例

#### US-011 🔄 📱 位置元数据自动嵌入
**描述**：作为 nomad，我希望每条 memo 自动带上当时的位置（已在 fix/location-embed-and-voice-scroll 分支修复，纳入 V5）。
**AC**：
- [ ] 任何 memo 创建时立即获取一次 GPS（5s 超时）
- [ ] 位置失败不阻塞保存
- [ ] 反向地理编码异步进行，结果回写 memo
- [ ] 用户在 Settings 可关闭位置采集

#### US-012 🔄 📱 天气元数据
**描述**：作为用户，我希望 memo 自动带上当时的天气，将来回看更有氛围。
**AC**：
- [ ] 每条 memo 带 weather 字段（如 `多云 22°C`）
- [ ] 同一小时内不重复请求 API（10 分钟缓存）
- [ ] 失败时字段为 null

#### US-013 🆕 📱 音频环境识别（中等激进）
**描述**：作为用户，我希望系统识别我录音时的环境（咖啡馆/室外/走路），自动加 tag。
**AC**：
- [ ] 录音过程中分析麦克风背景噪声（YAMNet 或类似 on-device 模型）
- [ ] 识别 5 类：silence / cafe / outdoor / vehicle / crowd
- [ ] 写入 memo 的 `environment` 字段
- [ ] 用户可在 Settings 关闭

#### US-014 🆕 📱 离线 capture 队列
**描述**：作为飞机/隧道用户，我希望离线时录的 memo 不会丢，联网自动同步。
**AC**：
- [ ] 离线创建的 memo 立即写入本地 vault
- [ ] 在 Today 顶部显示「3 条等待同步」灰色 badge
- [ ] 联网后自动 push，成功后 badge 消失
- [ ] 同步失败有重试 + 错误提示

### 5.B Compile 类（US-015 ~ US-024）

#### US-015 🆕 🌐 Compile Queue 实时进度
**描述**：作为用户，我希望在 Add 视图实时看到每条 memo 的编译进度。
**AC**：
- [ ] 每条 queue item 显示进度条 0-100%
- [ ] 通过 SSE 接收后端进度推送
- [ ] 完成后绿色 ✓ + 显示「3 pages updated」
- [ ] 失败显示红色 + 错误信息 + Retry 按钮
- [ ] Verify in browser using dev-browser skill

#### US-016 🆕 🌐 LIGHT / FULL 模式切换
**描述**：作为用户，我希望能在 queue 中点击 chip 切换某条的编译档位。
**AC**：
- [ ] 每条 queue item 有 LIGHT/FULL chip
- [ ] 点击 chip 立即切换 + 触发重编译
- [ ] FULL→LIGHT 不删除已生成的 page，只是不再深度更新
- [ ] LIGHT→FULL 触发完整流水线

#### US-017 🆕 🌐💻 Recompile 单条 memo
**描述**：作为用户，我希望对某条已编译的 memo 触发重编译（比如 LLM 升级了）。
**AC**：
- [ ] memo 详情页有 "Recompile" 按钮
- [ ] 重编译会撤销旧 patch（基于 change_log）再应用新 patch
- [ ] 期间 page 显示「being recompiled」
- [ ] 失败可回滚

#### US-018 🆕 🌐 Compile 历史时间机器
**描述**：作为用户，我希望看到一个 page 在过去某个时间点的样子。
**AC**：
- [ ] page 详情页右上角有时间轴 slider
- [ ] 拖动可显示该时刻的 page snapshot
- [ ] 用 change_log 表回放
- [ ] "Restore to this version" 按钮（创建新版本，不破坏历史）

#### US-019 🆕 🌐 Schema 检测建议
**描述**：作为用户，我希望系统发现新的 cluster 时主动建议建 domain。
**AC**：
- [ ] 后端 worker 每 50 条新 memo 跑一次聚类
- [ ] 检测到新 cluster 写入 inbox（kind=schema）
- [ ] inbox 卡片显示：cluster 中的代表 memo + 建议名称
- [ ] 用户可改名字 / 接受 / 拒绝

#### US-020 🆕 🌐 Conflict 处理流程
**描述**：作为用户，我希望系统检测到我的笔记与新 ingest 内容矛盾时显示对比，让我决策。
**AC**：
- [ ] inbox 显示矛盾卡片，左旧右新对比
- [ ] 4 个动作按钮：Keep both as tracked / Use new / Keep mine / Open both pages
- [ ] 决策后写 change_log，更新 page
- [ ] "tracked contradiction" 在 page 上以特殊样式渲染

#### US-021 🆕 🌐 编译失败可视化
**描述**：作为用户，我希望编译失败时知道具体哪一步挂了，能重试或人工介入。
**AC**：
- [ ] 失败 memo 在 queue 显示红色 + 失败步骤名
- [ ] 点击展开可见错误详情（DLQ 内容）
- [ ] 可选 "Retry only this step" / "Retry full pipeline" / "Skip and mark as raw-only"

#### US-022 🆕 🌐 Compile rationale 透明
**描述**：作为深度用户，我希望看到每个 page patch 背后 LLM 的"为什么这样改"。
**AC**：
- [ ] page 详情页 "Provenance" 侧栏可展开 compile rationale
- [ ] 显示触发该 patch 的 memo + LLM prompt 摘要 + 决策理由
- [ ] 每条 rationale 可点 thumbs up/down 反馈，用于后期 RLHF

#### US-023 🆕 🌐 LIGHT/FULL 默认档设置
**描述**：作为用户，我希望按内容类型设置默认档位。
**AC**：
- [ ] Settings → Compile defaults
- [ ] 5 类内容（user-typed / voice / web / file / email）每类可选默认 LIGHT/FULL
- [ ] 默认值合理（user-typed=FULL, web=LIGHT 由 AI 评估）

#### US-024 🆕 🌐 Cold storage 询问归档
**描述**：作为用户，我希望系统提示我归档 90 天没碰过的 page。
**AC**：
- [ ] 后端 cron 每天扫一次冷 page
- [ ] 推 inbox（kind=orphan）
- [ ] 用户可一次性 batch 接受/全部拒绝
- [ ] 归档后 page 移到 cold storage，不出现在 wiki nav，但仍可搜索

### 5.C Knowledge Surface（US-025 ~ US-039）

#### US-025 🆕 🌐 Wiki List 视图
**描述**：作为用户，我希望左侧分组导航能让我快速找到任何 page。
**AC**：
- [ ] 5 大分组（Concepts / Sources / Entities / Synthesis / Daily）可折叠
- [ ] 每组按更新时间排序
- [ ] 每条显示 title、sub-meta（source 数 / draft tag / conflict 警示）
- [ ] 当前选中 page 高亮
- [ ] 顶部 `/` 快捷键聚焦搜索框
- [ ] Verify in browser using dev-browser skill

#### US-026 🆕 🌐 Wiki Page Detail
**描述**：作为用户，我希望 page 详情页清晰呈现内容、来源、反链。
**AC**：
- [ ] 顶部 chip 显示 type / domain / 更新时间
- [ ] 大字号 title
- [ ] 正文支持 Markdown 全特性 + KaTeX 数学公式 + Mermaid 图
- [ ] 右侧栏 3 块：Sources / Backlinks / Provenance
- [ ] 每个 source 可点击 → 打开原 memo
- [ ] Verify in browser using dev-browser skill

#### US-027 🆕 🌐 Annotation 高亮
**描述**：作为用户，我希望选中 page 任何文本后能加高亮和 tag。
**AC**：
- [ ] 选中文本后弹 toolbar：important / questionable / 自定义 tag / 加 note
- [ ] 高亮持久化到 annotations 表
- [ ] 不同 tag 不同色（important=琥珀，questionable=红，自定义=用户选）
- [ ] 高亮可点击编辑/删除
- [ ] 重新编译时 LLM 把 annotation 作为重要信号

#### US-028 🆕 🌐💻 Knowledge Graph
**描述**：作为用户，我希望看到所有 page 与 entity 之间的网络。
**AC**：
- [ ] 默认渲染当前 domain 的所有 node
- [ ] 节点颜色按 type 区分（concept/draft/entity/source/synthesis）
- [ ] 边粗细按 link weight
- [ ] 节点点击 → 高亮该节点 + 1-hop 邻居 + 显示侧栏 detail
- [ ] 拖拽 / 滚轮缩放 / 双击居中
- [ ] 顶部过滤：按 type / domain / 时间范围
- [ ] >100 节点切换到 Canvas 渲染

#### US-029 🆕 💻 Graph 时间动画
**描述**：作为用户，我希望看到我的知识网络是怎么"长出来"的（时间动画）。
**AC**：
- [ ] Graph 视图右下角 "Play timeline" 按钮
- [ ] 从最早一条 memo 开始按月推进，新 node/edge 渐入
- [ ] 速度可调（1 月/秒 ~ 1 年/秒）
- [ ] 可暂停/拖动 timeline

#### US-030 🆕 🌐 Entity 实体页
**描述**：作为用户，我希望每个被 AI 识别的实体（人/组织/项目/地点）有独立页面。
**AC**：
- [ ] entity page 有：名称、类型、别名、相关 page、相关 memo、出现次数 timeline
- [ ] 用户可手动 merge 重复 entity
- [ ] 用户可改名 / 改类型
- [ ] 实体可以有 metadata（如 person 的 role / org）

#### US-031 🆕 🌐 Domain 视图
**描述**：作为用户，我希望点击侧栏 domain 直接看该 domain 的所有 page + 概览。
**AC**：
- [ ] domain 详情页显示：page 列表、本周/本月活动统计、graph 缩略图
- [ ] 顶部可改 domain 名/颜色
- [ ] 可拖拽改 domain 顺序

#### US-032 🆕 🌐 全局搜索
**描述**：作为用户，我希望一个搜索框能搜遍所有 page / memo / entity / annotation。
**AC**：
- [ ] `/` 全局快捷键
- [ ] 类型切换 chips（All / Pages / Memos / Entities / Annotations）
- [ ] 每条结果显示 type + 高亮匹配片段 + meta
- [ ] BM25 + 向量混合排序
- [ ] 结果点击直达对应详情页
- [ ] 历史搜索保存（可清除）

#### US-033 🆕 🌐 模糊回忆模式
**描述**：作为用户，我记不清某事的细节，希望 AI 反向问我问题帮我定位。
**AC**：
- [ ] Search 顶部有 "I half-remember..." 入口
- [ ] 用户输入模糊描述
- [ ] AI 问 3 轮澄清问题（地点/时间/相关人/相关 concept）
- [ ] 收敛到候选 3-5 条 memo

#### US-034 🆕 🌐 Synthesis Page 创建
**描述**：作为用户，我希望从 Chat 对话生成 synthesis page。
**AC**：
- [ ] Chat 顶部有 "Save as synthesis page" 按钮
- [ ] 点击后 LLM 把对话凝练为结构化 page
- [ ] 用户可在 page 编辑器修改 + 设 domain + 发布
- [ ] synthesis page 自动反链原 chat thread

#### US-035 🆕 🌐 Daily Page 自动生成
**描述**：作为用户，我希望每天自动生成一份 daily diary page。
**AC**：
- [ ] 每晚 00:30 把当日所有 memo 聚合
- [ ] 按主题分组、加 AI 总结、嵌入位置/天气/行程
- [ ] 生成的 page 可编辑
- [ ] 在 Wiki nav "Daily" 分组下按日期倒序

#### US-036 🆕 🌐 Page 草稿与发布
**描述**：作为用户，我希望 AI 新建的 page 先放草稿，我审完再发布。
**AC**：
- [ ] AI 新建的 concept page 默认 status=draft
- [ ] draft page 在 nav 显示 pulse 标记
- [ ] 顶部有 "Promote to live" 按钮
- [ ] 用户编辑过后自动 promote

#### US-037 🆕 🌐 Page 历史版本
**描述**：作为用户，我希望看到 page 的所有历史版本，能 diff 与回滚。
**AC**：
- [ ] page 顶部 "..." 菜单 → "Version history"
- [ ] 列表显示所有版本时间 + 触发原因（哪条 memo / 哪次 manual edit）
- [ ] diff view 高亮变更（增加=绿底，删除=红删除线）
- [ ] "Restore" 按钮创建新版本

#### US-038 🆕 🌐 Page 导出 / 分享
**描述**：作为用户，我希望把单个 page 导出为 PDF 或分享 URL。
**AC**：
- [ ] page 顶部 Share 按钮
- [ ] 选项：Export PDF / Export Markdown / Public link（仅管理员可生成）
- [ ] Public link 是 read-only 网页，含 page 内容 + DayPage 品牌 + "Powered by DayPage"
- [ ] 用户可随时撤销 public link

#### US-039 🆕 🌐 Provenance trail 段落级
**描述**：作为用户，我希望知道 page 中某段话来自哪条 memo。
**AC**：
- [ ] 鼠标悬停某段落，左侧出现 source 小标
- [ ] 点击展开显示来源 memo 列表
- [ ] 多 source 时显示贡献度百分比

### 5.D Conversation & Agent（US-040 ~ US-053）

#### US-040 🆕 🌐 Wiki Chat 基础对话
**描述**：作为用户，我希望像问 ChatGPT 一样问我自己的 wiki。
**AC**：
- [ ] Chat 视图含 thread list + thread detail + composer
- [ ] composer 支持 Enter 发送，Shift+Enter 换行
- [ ] AI 流式输出（SSE）
- [ ] 答案中的 `{n}` 渲染为可点击数字徽标，点击高亮右栏对应 reference card
- [ ] reference card 点击打开 source page

#### US-041 🆕 🌐 Suggested follow-ups
**描述**：作为用户，每个 AI 回答后希望系统建议 3 条相关后续问题。
**AC**：
- [ ] 每个 AI message 下显示 3 个 chip
- [ ] 点击 chip 直接发送
- [ ] chip 的内容根据 thread context 生成

#### US-042 🆕 🌐 Multi-thread chat
**描述**：作为用户，我希望开多个对话，按主题归档。
**AC**：
- [ ] Chat 左侧栏列出所有 thread
- [ ] 可按 active / archived / synthesized 过滤
- [ ] 可重命名 / 删除 / 归档
- [ ] thread 自动按内容生成标题

#### US-043 🆕 🌐 Chat 引用透明
**描述**：作为用户，我希望知道 AI 答案中每个事实从哪个 page 来的。
**AC**：
- [ ] 答案中所有事实必须有 `{n}` 引用
- [ ] 没有引用支撑的句子用斜体灰字显示并加 "[uncited]" 标记
- [ ] 系统 prompt 强制：「不能引用就说不知道」

#### US-044 🆕 🌐 "我不知道" 优先
**描述**：作为用户，我希望 AI 不会乱编。
**AC**：
- [ ] 当检索到的 page 不足以回答时，AI 直接回 "I don't know yet"
- [ ] 给出 "你可以先 add X 让我学习" 的建议
- [ ] 用户可在 Settings 调严格度（strict / balanced / creative）

#### US-045 🆕 🌐 Past-Self Dialogue
**描述**：作为用户，我希望选定时间段后能与"那时候的我"对话。
**AC**：
- [ ] Chat 顶部有 "Talk to past me" 按钮
- [ ] 弹出时间段选择器（默认 30 天前 / 1 年前 / 自定义）
- [ ] 系统创建特殊 thread，title 自动 "Past me · 2024-09"
- [ ] AI 答案使用第一人称，引用那段时间的 memo
- [ ] 答案有 emoji 与语气模拟，模仿用户当时风格（基于历史 memo 训练 prompt）

#### US-046 🆕 🌐 Persona 定制
**描述**：作为用户，我希望调整 AI 与我对话的语气。
**AC**：
- [ ] Settings → AI Persona
- [ ] 4 档：Neutral / Mentor / Friend / Skeptic
- [ ] 自定义 persona prompt（高级）

#### US-047 🆕 ⌚️📱 Siri 集成
**描述**：作为用户，我希望对 Siri 说「问 DayPage 我上周读了什么」就能得到答案。
**AC**：
- [ ] iOS App Intents 注册 "Ask DayPage" intent
- [ ] Siri 触发 → 调用 RAG → 用 AVSpeech 语音回复
- [ ] 同时弹通知，点开看完整答案 + reference

#### US-048 🆕 🌐 AI Agent 主动观察
**描述**：作为用户，我希望系统发现"有趣的模式"时主动通知我。
**AC**：
- [ ] Home 页 "What the system noticed" 卡片显示最新 observation
- [ ] observation 来自后端 worker（每天凌晨跑一次）
- [ ] 类型：cluster growing fast / new entity emerged / topic dormant / contradiction unresolved
- [ ] 每条 observation 有 2-3 个动作按钮
- [ ] Verify in browser using dev-browser skill

#### US-049 🆕 🌐 Agent Action 授权
**描述**：作为用户，我希望明确授权 AI 能做的"动作"，未授权动作不会自动执行。
**AC**：
- [ ] Settings → Agent Permissions 显示所有可授权 action（共 8 类，详见 §7）
- [ ] 默认只授权"低风险只读"（如 schema 检测）
- [ ] 高风险（如自动 merge entity）默认关闭
- [ ] 已授权的 action 可在 Activity log 查看

#### US-050 🆕 🌐 Agent Action 审计日志
**描述**：作为用户，我希望看到 AI 替我做了什么，能撤销。
**AC**：
- [ ] Settings → Activity log
- [ ] 显示所有 agent action，按时间倒序
- [ ] 每条 action 有 "Undo" 按钮（基于 change_log）
- [ ] 可按 action 类型 / 时间范围过滤

#### US-051 🆕 🌐 Inbox 处理流
**描述**：作为用户，我希望 inbox 显示所有待我决策的 AI 建议，按类型过滤。
**AC**：
- [ ] inbox 顶部 5 个 chip：All / Contradictions / Schema / Orphans / Compiled
- [ ] 每条卡片显示 kind / time / title / body / 1-4 个动作按钮
- [ ] CONTRADICTION 卡片含 old/new 对比 pane
- [ ] 处理后卡片消失（移到 resolved），sidebar inbox badge 数字更新

#### US-052 🆕 🌐 Snooze inbox 项
**描述**：作为用户，我希望某些 inbox 项稍后再处理。
**AC**：
- [ ] 每条 inbox 卡片右上角 "..."
- [ ] 选项：Snooze 1d / Snooze 1w / Dismiss / Resolve as...
- [ ] Snooze 后到期重新出现

#### US-053 🆕 🌐 Inbox 推送通知
**描述**：作为用户，我希望新的 inbox 项能在重要时弹通知。
**AC**：
- [ ] Settings → Notifications 可开关 4 类 inbox 推送
- [ ] CONTRADICTION 默认开启（重要决策）
- [ ] iOS / Web Push API
- [ ] 通知点击直达对应 inbox 项

### 5.E Reflection & Memory（US-054 ~ US-061）

#### US-054 🔄 📱 On This Day
**描述**：作为用户，我希望每天看到「去年/前年/N 年前的今天」我做了什么。
**AC**：
- [ ] iOS V3 已实现，V5 升级：跨年合并显示
- [ ] iOS Today 顶部 banner 出现
- [ ] 点击展开看完整时间线
- [ ] 每条可点击跳到 daily page

#### US-055 🆕 🌐 On This Day Web
**描述**：作为 Web 用户，我希望 Home 页有"今日回顾"模块。
**AC**：
- [ ] Home 页底部有 "On this day" section
- [ ] 横向 scrollable cards（每年一张）
- [ ] 点击跳到对应 daily page

#### US-056 🆕 📱🌐 Weekly Recap 自动生成
**描述**：作为用户，每周日希望系统给我推一份"这周的你"。
**AC**：
- [ ] 每周日 18:00 worker 跑生成
- [ ] 内容含：本周 memo 数 / 最活跃 domain / 新建 page / 去过的地方 / AI 写的 1 段叙事
- [ ] 推送到 iOS / Web 通知
- [ ] 用户可编辑后保存为 page

#### US-057 🆕 💻🌐 Monthly Recap
**描述**：作为用户，每月初希望看到上个月的可视化报告。
**AC**：
- [ ] 每月 1 日 00:30 生成
- [ ] 含 5 类图：地图（去过的地方）/ domain 活动柱图 / entity 出现频次 / 心情曲线（如有）/ 时间投入饼图
- [ ] 可导出 PDF
- [ ] macOS 端有交互式编辑器，调整图表样式

#### US-058 🆕 💻🌐 Year in Review
**描述**：作为用户，每年 12 月底希望系统给我一份"年度叙事"。
**AC**：
- [ ] 12/20 自动生成草稿
- [ ] 含整年所有维度可视化 + AI 写 3-5 段叙事
- [ ] 可生成可分享网页（带 OG 图）
- [ ] 可导出 PDF
- [ ] 高互动 onboarding 小动画

#### US-059 🆕 📱🌐 Memory Lane · Random Walk
**描述**：作为用户，我希望系统偶尔随机推一些尘封 memo 让我回忆。
**AC**：
- [ ] iOS Today 顶部偶尔出现 "A memory" 卡
- [ ] Web Home 有 "Random walk" 入口
- [ ] 推送频次每周 1-2 次（用户可调）
- [ ] 算法偏向 6 月以前 + 90 天没看过的 memo

#### US-060 🆕 🌐 Memory Lane · 地图回放
**描述**：作为用户，我希望地图视图上点某个城市能看所有那里的 memo。
**AC**：
- [ ] Wiki / Memory tab 下有 Map view
- [ ] 全球地图，每个 memo 是一个点
- [ ] 点击某点 → 弹卡片
- [ ] 可按时间范围筛选
- [ ] 城市级 cluster 自动合并

#### US-061 🆕 🌐 Memory Lane · 情绪回放
**描述**：作为用户，我希望按情绪标签翻历史 memo。
**AC**：
- [ ] 系统从 memo 文本自动抽情绪标签（5 类：joy / sad / anxious / proud / reflective）
- [ ] Memory tab 有情绪 timeline
- [ ] 点某个情绪 → 列出所有相关 memo

### 5.F System & Trust（US-062 ~ US-072）

#### US-062 🆕 ⚙️ Apple Sign-In 登录
**描述**：作为用户，我希望用 Apple ID 在 iOS / Web 用同一账号登录。
**AC**：
- [ ] iOS 集成 Sign in with Apple
- [ ] Web 用 Auth.js v5 + Apple OAuth provider
- [ ] 同一 Apple sub 自动关联同一用户
- [ ] 首次登录走 onboarding；之后直达 home

#### US-063 🆕 ⚙️ Email magic link 兜底
**描述**：作为非 Apple 用户，我希望用邮箱登录。
**AC**：
- [ ] Web 登录页有 "Continue with email" 按钮
- [ ] 输入邮箱 → 收到 magic link → 点击登录
- [ ] 链接 15 min 过期
- [ ] 同邮箱可绑定 Apple ID 后两种登录方式都能用

#### US-064 🆕 ⚙️ 跨端同步
**描述**：作为用户，我希望 iOS 写的内容立即在 Web 看到，反之亦然。
**AC**：
- [ ] iOS sync 间隔：前台 30s / 后台 15min / push wake-up 立即
- [ ] Web 后端有更新时通过 SSE 推到所有在线 device
- [ ] 同步状态指示器（左下角小点：绿=已同步 / 黄=同步中 / 红=失败）
- [ ] 冲突 last-write-wins，用户标注永远优先

#### US-065 🆕 ⚙️ 离线优先
**描述**：作为用户，我希望任何端离线都能继续使用基础功能。
**AC**：
- [ ] iOS：vault 即离线缓存（V1-V4 已有）
- [ ] Web：PWA + Service Worker，缓存 wiki + recent memo
- [ ] macOS：本地 SQLite 镜像
- [ ] 离线时所有写入入本地队列，上线自动 push

#### US-066 🆕 ⚙️ Privacy Vault
**描述**：作为用户，我希望某些 memo / page 标记为 private，AI 不读不引。
**AC**：
- [ ] memo / page 详情页右上角有 "Make private" 切换
- [ ] private 内容：不进 RAG context、不出现在 graph、不被 link
- [ ] 解锁需要主密码（独立于账号密码）
- [ ] 解锁状态超时 15 min 自动锁回

#### US-067 🆕 ⚙️ 全量数据导出
**描述**：作为用户，我希望一键导出所有数据为 ZIP。
**AC**：
- [ ] Settings → Data → Export all
- [ ] 后台生成 ZIP（含 raw .md / page .md / JSON metadata / Storage attachments）
- [ ] 完成后 email 链接（24h 有效）
- [ ] 用户可选择只导出某段时间

#### US-068 🆕 ⚙️ 删除账号
**描述**：作为用户，我希望能彻底删除账号与所有数据（GDPR）。
**AC**：
- [ ] Settings → Account → Delete account
- [ ] 二次确认（输入邮箱）
- [ ] 30 天内可恢复（保留 soft-delete）
- [ ] 30 天后所有数据 + backup 物理删除
- [ ] 删除后发确认邮件

#### US-069 🆕 ⚙️ 多设备管理
**描述**：作为用户，我希望看到所有登录的设备能远程登出。
**AC**：
- [ ] Settings → Devices 列出所有设备（platform / 最后活跃 / IP 地理位置）
- [ ] 每条 "Sign out" 按钮
- [ ] "Sign out all other devices" 一键操作

#### US-070 🆕 🔌 Public API
**描述**：作为开发者用户，我希望用 API 读写自己的 DayPage 数据。
**AC**：
- [ ] Settings → API tokens 生成 token（scope 控制）
- [ ] 文档站 docs.daypage.io 含完整 OpenAPI spec
- [ ] 端点：所有 CRUD + chat + search
- [ ] 限流 60 req/min per token
- [ ] 提供 TS / Python SDK

#### US-071 🆕 ⚙️ Settings 中心
**描述**：作为用户，我希望一个清晰的 Settings 页面控制所有偏好。
**AC**：
- [ ] 分组：Account / Notifications / Compile / Agent / Privacy / Data / Devices / API / Appearance / About
- [ ] 改动立即保存（无需点 Save）
- [ ] 有搜索框

#### US-072 🆕 ⚙️ Onboarding
**描述**：作为新用户，我希望前 3 步能让我立即看到产品的价值。
**AC**：
- [ ] Step 1：选 2-5 个 domain seed（"你想想清楚什么？"）
- [ ] Step 2：投喂 1 个种子内容（URL / 文本 / 跳过）
- [ ] Step 3：实时 compile 进度条 → 完成 → 进入 home，已有第 1 个 page
- [ ] 整体 ≤ 90s 完成
- [ ] 中途可跳过，进 home 后随时可重启

---

## §6 功能性需求 FR

> 以"系统必须……"形式声明，无歧义、可测试。
> FR 与 §5 US 的关系：US 是用户视角的故事，FR 是系统层面的硬约束。同一功能在两边各表述一次，FR 更适合工程实现 checklist。

### 6.A Capture & Storage

- **FR-1**：系统**必须**接受 7 种 memo 类型：text / voice / photo / video / location / url / file
- **FR-2**：系统**必须**为每条 memo 自动嵌入：created (ISO8601 ms) / location (GPS+geocode) / weather / device / origin
- **FR-3**：系统**必须**在用户离线时把 memo 写入本地队列，联网后自动重试 3 次
- **FR-4**：系统**必须**支持单文件 ≤50MB 的附件上传（Supabase Storage）
- **FR-5**：iOS 端**必须**继续使用 `vault/raw/YYYY-MM-DD.md` 作为本地真实存储（V1-V4 兼容）
- **FR-6**：后端**必须**用 PostgreSQL 作为云端 single source of truth，schema 见 `docs/web/PLAN.md` §4
- **FR-7**：每条 memo 在云端的 ID **必须**与 iOS 端 UUID 完全一致（避免 mapping）

### 6.B Compile Pipeline

- **FR-8**：系统**必须**实现 12-step compile pipeline（NORMALIZE / TRANSCRIBE / OCR / FETCH / CHUNK / EMBED / RECALL / COMPILE / APPLY / INDEX / NOTIFY / ACT）
- **FR-9**：每个 pipeline step **必须**幂等，可单独重跑
- **FR-10**：失败的 step **必须**进入 dead letter queue 并通知用户
- **FR-11**：所有 page mutation **必须**事务性 + 写 change_log 表
- **FR-12**：每条 LLM 调用**必须**记录 tokens_in / tokens_out / model / cost / latency
- **FR-13**：embeddings **必须**缓存 7 天（同 memo 内容不重复 embed）
- **FR-14**：编译失败**不得**删除原 memo

### 6.C Wiki & Page

- **FR-15**：page **必须**支持 6 种 type：concept / source / entity / synthesis / daily / domain
- **FR-16**：page **必须**支持 4 种 status：live / draft / archived / cold
- **FR-17**：所有 page mutation **必须**保留历史版本（可回滚 N 个版本，N 默认 50）
- **FR-18**：Daily page **必须**每晚 00:30 自动生成
- **FR-19**：page 渲染**必须**用 react-markdown + remark-gfm + rehype-sanitize（防 XSS）
- **FR-20**：annotation **必须**独立存储，不修改 page body
- **FR-21**：cold page（90 天无访问 + 无 backlink）**必须**触发 inbox orphan 项

### 6.D Chat & RAG

- **FR-22**：Chat 答案**必须**仅基于用户自己的 wiki 与 memo，不引外部知识
- **FR-23**：Chat 答案中所有事实**必须**有 `{n}` 引用；无引用支撑的句子用斜体灰字
- **FR-24**：检索不到足够 context 时**必须**回 "I don't know yet" + 引导用户 add
- **FR-25**：Chat 流式输出**必须**用 SSE（不用 WebSocket）
- **FR-26**：每个 chat thread **必须**支持 "Save as synthesis page"

### 6.E Agent

- **FR-27**：Observer agent **必须**每天 03:00 跑一次全量扫描
- **FR-28**：Actor agent 的所有动作**必须**先经过用户授权（Settings → Agent Permissions）
- **FR-29**：每个 agent action **必须**写 audit log，可逐条 undo
- **FR-30**：Schema 检测**必须**每 50 条新 memo 跑一次聚类
- **FR-31**：Conflict 检测**必须**在每次 FULL 编译时执行
- **FR-32**：Agent 不得在用户 sleep timezone（22:00-08:00）发推送

### 6.F Sync & Offline

- **FR-33**：所有端**必须**支持离线读 + 离线写
- **FR-34**：sync 协议**必须**用 cursor-based pagination（避免大 payload）
- **FR-35**：服务端有更新**必须**通过 SSE 立即推送已在线 device
- **FR-36**：Web 端**必须**实现 PWA + Service Worker
- **FR-37**：冲突解决策略：last-write-wins，但 user-edited annotation 永远优先于 AI patch

### 6.G Security & Privacy

- **FR-38**：所有 query **必须**强制带 `where user_id = current_user.id`
- **FR-39**：DashScope/Claude API key **不得**下发到任何客户端
- **FR-40**：Markdown 渲染**必须**经 sanitization（防 XSS）
- **FR-41**：所有 Storage 直传 URL **必须**带 mime/size/expiry 限制
- **FR-42**：所有 mutation **必须**带 CSRF token
- **FR-43**：每用户每天 chat tokens **必须**有上限（默认 100k tokens / day）
- **FR-44**：Rate limit：mutation 30 req/min / chat 60 req/min / ingest webhook 60 req/min
- **FR-45**：所有 attachment URL **必须**走 signed URL（不公开桶）
- **FR-46**：Private 内容**不得**进入 RAG context、不得在 graph 显示、不得被 link
- **FR-47**：删除账号**必须**在 30 天内彻底清除所有数据 + backup（GDPR）

### 6.H Observability

- **FR-48**：所有 API 调用**必须**记录 trace_id（OpenTelemetry）
- **FR-49**：所有 LLM 调用**必须**写 prompt_log 表（含完整 prompt 与 response）
- **FR-50**：所有 user action **必须**写 activity 表
- **FR-51**：错误**必须**上报 Sentry，关键错误自动开 Linear issue（沿用现有 pipeline）

---

## §7 AI Agent 主动行动模型

V5 的 AI 不仅是 RAG 后端，而是**长驻后台的"住户"**。这一节定义 Agent 的行为边界、触发条件、授权模型、审计机制。

### 7.1 Agent 分层

**两类 Agent**：

#### Observer（观察者）—— 默认全开
- **职责**：扫描数据、识别模式、产出 inbox 建议与 home observations
- **不修改任何用户数据**
- **风险**：低
- **示例**：发现新 cluster、检测矛盾、识别冷 page、追踪话题热度

#### Actor（行动者）—— 默认全关，需逐项授权
- **职责**：替用户执行具体动作（创建/合并/归档/调用外部 API）
- **修改用户数据**
- **风险**：中-高
- **示例**：自动 merge 重复 entity、自动归档冷 page、调 arXiv API 补 reference

### 7.2 Action Catalog（共 8 类）

| ID | 名称 | 风险 | 默认 | 描述 |
|---|---|:---:|:---:|---|
| ACT-1 | Auto-tag domain | 低 | ON | 给新 memo 自动打 domain tag |
| ACT-2 | Auto-archive cold pages | 中 | OFF | 90 天无访问 page 自动 archive |
| ACT-3 | Auto-merge duplicate entities | 中 | OFF | 高相似度 entity 自动合并 |
| ACT-4 | Auto-promote draft pages | 低 | OFF | 用户读了 draft page 5 次后自动 promote 为 live |
| ACT-5 | Auto-fetch external refs | 中 | OFF | 检测到论文标题 → 调 arXiv 自动补 BibTeX |
| ACT-6 | Auto-generate weekly recap | 低 | ON | 每周日生成草稿（用户审后再发布） |
| ACT-7 | Auto-cross-link similar pages | 中 | OFF | 检测到 2 个 page 高度相关时自动建 link |
| ACT-8 | Auto-send digest email | 低 | ON | 每周一 09:00 发 weekly digest 邮件 |

### 7.3 触发模型

```
                    ┌──────────────────┐
                    │  Trigger Source  │
                    └────────┬─────────┘
                             │
        ┌────────────────────┼────────────────────┐
        ▼                    ▼                    ▼
   ┌──────────┐         ┌────────┐          ┌──────────┐
   │ on-event │         │  cron  │          │ user-ask │
   │ (memo    │         │(daily  │          │  (chat)  │
   │ created) │         │ 03:00) │          │          │
   └─────┬────┘         └───┬────┘          └────┬─────┘
         │                  │                    │
         └──────────────────┼────────────────────┘
                            ▼
                  ┌──────────────────┐
                  │  Agent Engine    │
                  │  (Observer/Actor)│
                  └────────┬─────────┘
                           ▼
                  ┌──────────────────┐
                  │  Output Channel  │
                  └────────┬─────────┘
            ┌──────────────┼──────────────┐
            ▼              ▼              ▼
       ┌────────┐    ┌──────────┐   ┌────────┐
       │ Inbox  │    │   Home   │   │  Push  │
       │  Item  │    │  Banner  │   │  Notif │
       └────────┘    └──────────┘   └────────┘
```

### 7.4 安全栅栏

- **栅栏 1：默认安全** —— Actor 默认全关，用户主动开
- **栅栏 2：审计可见** —— 所有 action 写 audit log，Settings 可查
- **栅栏 3：可撤销** —— 所有 action 都基于 change_log，可逐条 undo
- **栅栏 4：通知节流** —— 同一 user 同一类型通知 1 天最多 3 条
- **栅栏 5：sleep 安静** —— 用户本地时区 22:00-08:00 不发推
- **栅栏 6：紧急停机** —— Settings 顶部 "Pause all AI agents" 一键开关

### 7.5 Agent Prompt 模板规范

所有 Agent prompt **必须**遵循结构：

```
[ROLE] You are a DayPage <observer|actor> agent.
[TASK] <one-sentence task>
[CONTEXT] <relevant data, max 8K tokens>
[CONSTRAINTS]
  - Do not invent facts
  - Cite memo/page IDs in every claim
  - If uncertain, say "uncertain" with reason
[OUTPUT FORMAT] Strict JSON matching schema X
```

所有 prompt 入版本控制（`web/lib/ai/prompts/*.md`），所有 response 落 prompt_log 表，便于回溯与 RLHF。

---

## §8 数据模型与跨端同步

详见 `docs/web/PLAN.md` §4（13 张核心表 + pgvector embedding）。

本节只补充与 PRD 强相关的几个**业务约束**：

### 8.1 ID 一致性

- 所有 memo 的 UUID 由 **iOS 端生成**，后端 upsert by ID
- 所有 page / entity / annotation 的 UUID 由**后端生成**，iOS 拉取后写入本地缓存
- 所有 ID 用 v4 UUID（不依赖时间，避免泄露）

### 8.2 时间戳约定

- 所有时间字段用 `TIMESTAMPTZ`（含时区）
- 所有客户端发送时间**必须**带 `Z`（UTC）
- 显示时由 client 转用户本地时区（i18n）

### 8.3 软删除策略

- memo / page / entity / inbox_item 删除走 soft-delete（加 `deleted_at`）
- soft-delete 30 天后由后台 worker 物理删除
- 删除账号触发立即软删 + 30 天后物理删

### 8.4 Sync 协议

```
GET /api/sync/cursor                                返回当前 device 的 sync cursor
GET /api/sync/pull?since={cursor}&types=memo,page   返回增量 + 新 cursor
POST /api/sync/push                                  上传本地 dirty 数据
SSE /api/stream/sync                                 服务端推送实时更新
```

### 8.5 跨端冲突解决

| 字段 | 冲突策略 |
|---|---|
| memo.body | 不允许编辑（append-only），无冲突 |
| memo.pinned_at | last-write-wins by `updated_at` |
| memo.location | 后端 wins（防止 iOS 重新地理编码覆盖云端正确数据） |
| page.body_md | last-write-wins，但若一边是 user-edit 一边是 AI-patch，user-edit 永远 wins |
| annotation | 不允许跨端编辑同一 annotation，按 ID 隔离 |

---

## §9 多平台战略

### 9.1 iOS（主端）

- 当前 V1-V4 已交付，V5 增量：
  - 接入云同步（vault → backend）
  - 卸载本地 AI key（改走后端代理）
  - 新增 Wiki / Chat / Inbox 简化版（main entry 仍是 Today / Archive）
  - 新增 AI Agent 推送通知
  - Watch 进一步增强（一键语音）
- 维持离线优先 + vault 文件为本地真实存储

### 9.2 Apple Watch

- 极简：1 个大按钮（语音 capture）+ 当日 memo 数 + 同步状态
- 配合 iPhone 解锁：表冠侧键长按直接录音
- 不展示 wiki / chat / graph

### 9.3 macOS（深度工作端）

- 用 SwiftUI（与 iOS 共享代码）或 Catalyst
- 主战场：long-form 编辑、Graph 大屏、Recap Builder、Spotlight 集成
- 全局快捷键 ⌥Space
- 菜单栏小图标（点击展开 mini quick capture）

### 9.4 Web（Codex）

- 主战场：Wiki 浏览、Inbox 处理、Chat 深度对话、Graph、Settings
- 桌面优先（≥1280px），1024-1280 自适应，<1024 简化版
- PWA + Service Worker + 离线缓存
- 浏览器扩展（Chrome/Safari/Firefox）

### 9.5 Public API

- REST + 完整 OpenAPI 文档
- TS / Python SDK
- 限流 + audit log
- 不开放写入到他人数据（仅自己 token 范围）

### 9.6 平台优先级（给开发资源排期）

V5 整体生命周期内的开发顺序：
1. **Web (Codex)** —— V5 第一交付，因为最缺、最能展示价值
2. **后端 API + iOS 同步改造** —— Web 完成后 iOS 必须能同步
3. **Public API 文档化** —— Web 端 API 即 Public API 的子集
4. **macOS** —— Web 成熟后 wrap 一层
5. **浏览器扩展** —— 工程量小，作为 V5 末期惊喜
6. **Watch 增强** —— 在已有基础上小迭代

---

## §10 设计语言与品牌系统

### 10.1 设计来源

- **Web 端**：Codex 原型（warm-archival 美学），见 §1 与 `daypage-system/project/src/tokens.css`
- **iOS 端**：继续 V4 的 liquid-glass + 暖色基调
- **共享品牌色**：`#5D3000` 琥珀棕（accent）、`#FAF8F6` 暖白底

### 10.2 设计原则（5 条）

1. **Archive Aesthetic** · 档案质感：暖色底、衬线/无衬线对比、ALL-CAPS 微排版
2. **Editorial Hierarchy** · 编辑式层级：大标题、长 leading、引文 italic
3. **Calm Typography** · 安静的排版：3 字体（Display/Body/Mono），不滥用粗体
4. **Generous Whitespace** · 留白慷慨：12px 圆角、24px 卡片间距、不挤
5. **Functional Glow** · 功能性光泽：仅在 active state / agent pulse 用 amber glow

### 10.3 颜色 Token

```
背景层：
  --bg-warm:        #FAF8F6   page background
  --surface-white:  #FFFFFF   cards
  --surface-sunken: #F3F0EB   inputs / wells

前景层：
  --fg-primary:     #2B2822
  --fg-muted:       #6B6560
  --fg-subtle:      #A39F99

主色：
  --accent:         #5D3000
  --accent-hover:   #7A3F00
  --accent-soft:    #F5EDE3
  --accent-border: #E8DCCA

语义色：
  --success: #4C7A3F  --success-soft: #EBF3E5
  --warning: #A66A00  --warning-soft: #F8ECD6
  --error:   #A23A2E  --error-soft:   #F5E1DC

热力图：
  --heatmap-empty/low/mid/high
```

### 10.4 字体系统

| 用途 | Family | Weight |
|---|---|---|
| Display / Headline | Space Grotesk | 500/600/700 |
| Body | Inter | 400/500/600/700 |
| Mono / Meta | JetBrains Mono | 400/500/700 |

### 10.5 组件原语（与 Codex 一致）

- Btn (primary/secondary/soft/ghost) × (sm/md) × (pill?)
- Chip (default/accent/success/warning/error/ghost)
- Card (default/sunken)
- Icon (lucide)
- Sparkline (mini SVG)
- SectionLabel (ALL-CAPS)
- Pulse (active dot)
- Heatmap (archive)

### 10.6 Motion

- 页面转场 140ms ease-out
- Hover 过渡 100ms
- Pulse 动画 1.6s ease-in-out infinite
- 严禁 bouncy spring（与 archive 美学冲突）

---

## §11 Non-Goals

明确**不做**的事，避免 scope creep：

### 11.1 V5 周期内不做

- ❌ **跨用户公共知识云**：不做"分享你的 wiki 给他人订阅"、不做 marketplace
- ❌ **多人协作 wiki**：不做 Notion/Confluence 式多人编辑
- ❌ **第三方插件市场**：不做 Obsidian-style plugin ecosystem
- ❌ **训练自定义 LLM**：不做用户数据训练个性化模型
- ❌ **支付/订阅系统**：本 PRD 只描述形态，不实施支付
- ❌ **企业 SSO / SAML**：等 Team 版（Post-V5）
- ❌ **iCloud Family Sharing**
- ❌ **Android App**：HTML5 PWA 兜底
- ❌ **Vision Pro 原生 App**：用 iPad 兼容版兜底

### 11.2 永远不做

- ❌ **广告**：DayPage 是付费产品，永不引入广告
- ❌ **数据销售**：用户数据永不出售给第三方
- ❌ **内容审查**：用户私人 vault 内容不做内容审查
- ❌ **强制云同步**：iOS vault 永远是用户的（可拒绝同步）

---

## §12 终极形态商业模型（描述，不实施）

> ⚠️ **本 PRD 不实施任何支付/订阅功能**。本节只描述终极形态愿景，供产品决策参考。
> 实际 V5 开发：所有功能对所有用户开放，不区分免费 / 付费。

### 12.1 三层定价（终极形态）

#### Free Tier（永久免费）
- 无限 raw memo（仅本地 + iCloud）
- 100 条/月 AI compile
- 不限 wiki page，但只 LIGHT 模式
- 不能用 Chat
- 不能用 Agent Actor
- iOS / Web 均可用
- **价值定位**：Day One 替代品

#### Pro $12 / 月 or $108 / 年
- 全部 capture 类型
- 不限 AI compile（fair-use cap，~3000 条/月）
- FULL compile 模式
- Chat + RAG（100k tokens / 天）
- 全部 Agent Action 可授权
- macOS 桌面 App
- 浏览器扩展
- Year in Review 高级模板
- 全量数据导出
- **价值定位**：知识工作者的「思考的档案库」

#### Team $25 / 人 / 月（Post-V5）
- Pro 全部
- 跨人共享 wiki
- 团队 Graph 视图
- Admin 控制台
- SSO / SAML
- 优先 support

### 12.2 转化漏斗假设（用于 PRD 设计取舍）

```
Anonymous landing visitor
     │ ↓ 8% 注册
Free user (D1)
     │ ↓ 35% 留存到 D7
Active free user
     │ ↓ 50% 用过 1 次 compile
Engaged free user
     │ ↓ 12% 撞到限额或被 Pro 功能吸引
Pro converter (LTV $144 if year)
     │ ↓ 5% 引荐到 Team
Team customer (LTV ~$3K/y)
```

### 12.3 付费触发点设计

虽然 V5 不实施，但功能设计上**保留付费触发点**位置：

| 触发点 | 现 V5 表现 | 终极形态付费墙 |
|---|---|---|
| Chat 用 100k tokens / 天 | 全开 | Free 无 chat / Pro 100k / Team 不限 |
| FULL compile | 全开 | Free LIGHT only / Pro FULL |
| Year in Review 高级模板 | 全开 | Free 基础模板 / Pro 全部 |
| Agent Actor 8 类 action | 全开 | Free 只 Observer / Pro 全部 |
| macOS App | 不发布（V5 周期内） | Pro only |
| 浏览器扩展 | 全开 | Pro only |

### 12.4 反向验证：哪些功能用户**不应**愿意付费

- Today / Archive 基础 capture：Day One 是 $35/年 一次性 + iCloud 同步，DayPage 必须**比 Day One 免费部分更好**
- 简单文字日记：用户已有 Apple Notes / Bear，付费门槛高
- 单纯地图回放：Apple Photos 已经免费

→ 所以**不能把核心 capture 功能锁在付费墙后**。付费的价值只能在「AI compile + 知识网络 + 跨端深度同步 + 数字生命叙事」上。

### 12.5 与 V5 实施的边界

V5 PRD 的**所有 US 都不带付费墙逻辑**。但 §6 FR-43（chat tokens 上限）等限制保留为"系统总闸"，未来加付费墙时只是改阈值，不需要重构。

---

## §13 隐私、安全、合规

### 13.1 隐私三原则

1. **数据归用户所有**：用户随时可一键导出全量数据 / 删除账号
2. **AI 不偷看 private**：标记 private 的内容不进 RAG、不进 graph、不被 link
3. **零数据销售**：永不出售用户数据给第三方

### 13.2 加密

- **传输层**：所有 API HTTPS（TLS 1.3）
- **静态层**：PostgreSQL 数据库由 Supabase 加密（AES-256）
- **敏感字段**：location 用 pgcrypto 字段级加密
- **Private vault**：用户主密码派生 key，server 无法解密 private 内容

### 13.3 合规

- **GDPR**：欧盟用户数据可一键导出/删除
- **CCPA**：加州用户同上
- **COPPA**：限制 13 岁以下用户注册
- **PIPL**：中国境内用户数据存中国区（Supabase 暂无中国 region → V5 不支持中国大陆，明示）

### 13.4 第三方数据共享

- **DashScope（阿里云）**：发送 memo / page text 用于 LLM 推理（不留存）
- **Apple**：iOS Sign-In sub
- **Sentry**：错误堆栈（自动 PII 脱敏）
- **PostHog**：匿名行为分析（用户可关）
- 所有第三方在 Privacy Policy 明示

### 13.5 滥用防护

- 注册验证邮件
- IP 频率限制（每 IP 注册 ≤3 账号 / 24h）
- 已知 disposable email 域名拒绝
- Webhook ingest 每用户每天上限 1000 条

### 13.6 数据保留

- Active 账号：永久
- Soft-deleted 账号：30 天
- Backup 滚动 90 天后过期
- 日志 / audit：12 个月

---

## §14 北极星与成功指标

### 14.1 北极星指标

> **Weekly AI-Compiled Memos per Active User (WCAU)**

定义：一周内 status=done 的 FULL compile memo 数（per active user）。

为什么这个指标：
- 反映用户**真实在投喂**（不是只来 capture）
- 反映 AI 编译**真实在产出价值**（不是 LIGHT 摆设）
- 与付费意愿强相关（重度用户 = 高 WCAU = 更可能 Pro）

目标：V5 上线 6 个月内 P50 用户 WCAU ≥ 15。

### 14.2 关键指标矩阵

| 类别 | 指标 | V5 上线 6 个月目标 |
|---|---|---|
| **Acquisition** | Web 注册转化率（landing → register） | ≥ 8% |
| **Activation** | D1 完成 onboarding | ≥ 70% |
| **Activation** | D7 创建 ≥3 条 memo | ≥ 50% |
| **Engagement** | WCAU (P50) | ≥ 15 |
| **Engagement** | Chat 使用率（D30 至少用 1 次） | ≥ 35% |
| **Engagement** | Inbox 处理率（D7 内处理） | ≥ 60% |
| **Retention** | D30 retention | ≥ 30% |
| **Retention** | D90 retention | ≥ 18% |
| **Quality** | AI compile 成功率 | ≥ 98% |
| **Quality** | RAG "I don't know" 率（应该高） | 5-15% 之间 |
| **Quality** | Inbox 用户接受率（resolved/total） | ≥ 50% |
| **Trust** | 数据导出请求率 | < 2% / month |
| **Trust** | 删除账号率 | < 1% / month |

### 14.3 体验质量指标

- **首屏 LCP**：≤ 1.5s（4G）
- **Wiki page 切换**：≤ 200ms（已缓存）
- **Compile 完成时间 P50**：≤ 30s
- **Sync 延迟 P95**：≤ 5s
- **WCAG 2.1 AA**：100% 合规

---

## §15 Wave 拆分与里程碑

> **本节不是承诺时间表，是工程节奏建议**。每个 Wave 跑完一轮 review，不强求全部跑完。

### Wave 0 · 准备（W0，~3 天）
- monorepo 改造（pnpm workspace + web/）
- Vercel + Supabase Cloud + Inngest Cloud 接入
- CI / CD pipeline
- Sentry + PostHog
- Auth.js v5 + Supabase Auth 接入
- **可见产出**：空壳 web 能跑 + 能登录

### Wave 1 · 后端骨架（W1，~5 天）
- Drizzle schema + 迁移（13 张表）
- /api/memos /api/pages /api/inbox /api/stats 基础 CRUD
- Supabase Storage 接入
- iOS sync API
- **覆盖 US**：US-014 部分、US-062~064、FR-1~7
- **可见产出**：iOS 能上传 vault 到云

### Wave 2 · vault 导入（W2，~3 天）
- 一次性 vault 导入脚本
- iOS 客户端 sync 改造
- vault-doctor 校验工具
- **覆盖 US**：US-064、US-067 部分
- **可见产出**：现有数据全在云上

### Wave 3 · Web 骨架 + Home（W3，~4 天）
- Next.js 16 shell + tokens.css 全套
- Sidebar / Topbar
- Home view 真数据
- 字体加载 + PWA manifest
- **覆盖 US**：US-001、US-025、US-048、US-054、US-055
- **可见产出**：Web home 能看到自己的 memo 数据

### Wave 4 · Add view + Compile worker（W4，~6 天）
- UnifiedInput
- Inngest worker 接入
- 12-step pipeline 落地（先简化版：只做 normalize / embed / compile / apply）
- SSE 进度推送
- LIGHT/FULL 切换
- **覆盖 US**：US-001、US-005~006、US-014~017、US-021、US-023、FR-8~14
- **可见产出**：端到端编译跑通

### Wave 5 · Wiki List 视图（W5，~5 天）
- WikiNav + Page detail + Sources/Backlinks/Provenance 侧栏
- Markdown 渲染
- Annotation 层（基础）
- **覆盖 US**：US-025~027、US-031、US-035~036、US-039
- **可见产出**：能浏览 + 标注 wiki

### Wave 6 · Wiki Graph 视图（W6，~3 天）
- react-force-graph-2d 集成
- 节点交互
- 时间轴 slider
- **覆盖 US**：US-028~029
- **可见产出**：可视化知识网络

### Wave 7 · Chat (RAG)（W7，~5 天）
- pgvector embedding pipeline
- 检索算法
- SSE 流式回答
- 引用解析 + reference cards
- Suggested follow-ups
- "I don't know" 兜底
- **覆盖 US**：US-040~044、FR-22~26
- **可见产出**：可问答自己的 wiki

### Wave 8 · Inbox + Observer Agent（W8，~5 天）
- 4 类 inbox item 生成器
- Observer agent worker
- Home 页 observation 卡片
- inbox 处理流（含 contradiction 对比）
- **覆盖 US**：US-019~020、US-024、US-048、US-051~053
- **可见产出**：AI 主动建议生效

### Wave 9 · Agent Actor + 安全栅栏（W9，~3 天）
- Settings → Agent Permissions
- 8 类 action 实现
- Audit log + Undo
- 全局停机开关
- **覆盖 US**：US-049~050、FR-27~32
- **可见产出**：Actor agent 可受控行动

### Wave 10 · Search + Memory（W10，~4 天）
- 全局搜索（混合 BM25 + vector）
- 模糊回忆模式
- Memory Lane（地图 / 情绪 / 随机漫步）
- On This Day Web
- **覆盖 US**：US-032~033、US-055、US-059~061
- **可见产出**：检索与回顾闭环

### Wave 11 · Recap System（W11，~4 天）
- Weekly Recap worker
- Monthly Recap
- Year in Review draft
- 可分享网页 + PDF 导出
- **覆盖 US**：US-056~058
- **可见产出**：自动报告系统

### Wave 12 · Past-Self Dialogue + Persona（W12，~3 天）
- Past-self prompt 模板
- Persona 自定义
- Time-window context 召回
- **覆盖 US**：US-045~046
- **可见产出**："数字生命"叙事激活

### Wave 13 · iOS 端融合（W13，~5 天）
- iOS Wiki / Chat / Inbox 简化版
- 卸载本地 AI key（改走后端代理）
- iOS Agent 推送
- iOS On This Day V5 升级
- **覆盖 US**：US-002、US-007、US-011~014、US-047、US-053、US-054
- **可见产出**：iOS 进入 V5 时代

### Wave 14 · Watch 增强（W14，~2 天）
- Watch 一键语音
- 表冠快捷
- 同步指示
- **覆盖 US**：US-003
- **可见产出**：Watch 端到端可用

### Wave 15 · macOS App（W15，~6 天）
- SwiftUI 版（与 iOS 共享）或 Catalyst
- 全局快捷键
- 菜单栏 mini capture
- Recap Builder
- Spotlight 集成
- **覆盖 US**：US-004、US-029、US-057~058
- **可见产出**：macOS 桌面端

### Wave 16 · 浏览器扩展（W16，~3 天）
- Chrome / Safari / Firefox
- 一键剪藏
- **覆盖 US**：US-008
- **可见产出**：扩展上架

### Wave 17 · 外部入口（W17，~3 天）
- Email-to-DayPage
- Webhook ingest
- Public API + OpenAPI 文档
- TS / Python SDK
- **覆盖 US**：US-009~010、US-070
- **可见产出**：API 生态启动

### Wave 18 · Privacy Vault（W18，~3 天）
- 主密码 + private flag
- Private 内容隔离
- **覆盖 US**：US-066、FR-46
- **可见产出**：隐私保险箱可用

### Wave 19 · Settings + Account（W19，~4 天）
- Settings 中心（10 个分组）
- Devices 管理
- 数据导出 / 删除账号
- API tokens
- **覆盖 US**：US-067~069、US-071
- **可见产出**：账号体系完整

### Wave 20 · 多模态升级（W20，~5 天）
- 音频环境识别
- AR 标注（iOS Camera）
- 高级 OCR / PDF 章节切分
- **覆盖 US**：US-013、US-006 升级
- **可见产出**："中等激进"多模态体验

### Wave 21 · 生产化（W21，~5 天）
- E2E（Playwright）覆盖 P0 流程
- a11y 全面审
- 性能（lighthouse ≥ 95）
- 文档（用户文档 + 开发者文档）
- 监控告警全套
- **覆盖**：全部 FR 验收
- **可见产出**：可公开发布

**总计**：~21 wave / ~85 工作日（单人投入）

---

## §16 风险登记册

| ID | 风险 | 影响 | 概率 | 缓解 |
|---|---|---|---|---|
| R1 | DashScope 长期限流或断供 | 高 | 中 | 抽象 LLM provider 层，可切 Claude / OpenAI / 自托管 |
| R2 | qwen 编译质量不达预期 | 高 | 中 | 关键 prompt 入版本控制，定期 eval；提供切到更强模型选项 |
| R3 | Vault 数据迁移导致 iOS 端数据丢失 | 高 | 低 | vault-doctor 工具反向校验 hash；强制 backup 提示 |
| R4 | Web 端 Graph 大节点性能崩 | 中 | 中 | >100 切 Canvas，>1000 切 web worker |
| R5 | Inngest 定价超预算 | 中 | 中 | 关键 worker 可降级到 Vercel Cron + Postgres queue |
| R6 | Supabase 中国不可访问 | 中 | 高 | 已在 §13.3 明示不支持中国大陆 |
| R7 | AI Agent 误操作引发用户数据混乱 | 高 | 中 | §7.4 六重栅栏；所有 action 可 undo |
| R8 | 用户主密码遗忘致 private 永久锁定 | 高 | 低 | 主密码不丢失也不能解；Settings 顶部明确警告 |
| R9 | iOS 老用户拒绝云同步 | 中 | 中 | iOS 同步可选；vault-only 模式继续支持 V1-V4 体验 |
| R10 | Auth.js v5 beta API 变更 | 低 | 中 | 锁版本，关注 milestone；最坏 fallback v4 |
| R11 | Next.js 16 Turbopack 出 bug | 低 | 低 | 可临时 fallback webpack |
| R12 | Apple Sign-In 审核被卡 | 中 | 低 | 同时支持 email magic link 兜底 |
| R13 | 多端冲突频繁 | 中 | 中 | 冲突时弹用户选择 UI；audit log 可回滚 |
| R14 | LLM 幻觉引用错误 page | 高 | 中 | system prompt 强制带 ID；后端做引用 ID 存在性校验，无效引用红框警示 |
| R15 | 单 user 数据增长致单租户性能崩 | 中 | 低 | 每用户有数据量监控；超阈值告警；准备 sharding 方案 |

---

## §17 Open Questions

> 写完 PRD 后剩余的、影响**实施细节**但不影响**整体方向**的问题。可分批回答。

### 17.A 模型与提示词
1. Compile 用 qwen-plus / qwen-max / qwen-vl-max？混合策略？
2. Embedding 用 DashScope text-embedding-v3 还是 OpenAI text-embedding-3-large？维度？
3. Chat 是否提供"切到 Claude" 选项给重度用户（自付 token）？
4. Past-Self Dialogue 用什么 persona prompt 模板？是否要让用户上传"语气样本"？

### 17.B AI Agent 边界
5. ACT-3（auto-merge entity）何时算"高相似度"？余弦 ≥0.92？
6. Observer 通知频率上限是不是 3/天/用户？太多会成骚扰
7. Agent 是否允许调用 web search（如查 arXiv）？还是仅用本地 wiki？

### 17.C 数据与同步
8. iOS vault `.md` 与后端的 reconciliation 跑频率？
9. 多设备同时编辑同一 page 时是否启用 OT/CRDT，还是 simple LWW？
10. 离线超过 30 天的设备重新上线时是 full re-sync 还是 incremental？

### 17.D 商业（即使本 PRD 不实施，但要预留）
11. 如果未来加付费墙，触发点用 hard limit 还是 soft nudge？
12. Pro 用户是否绑定 Apple ID Family Sharing？
13. Public API 是否限免费用户使用？

### 17.E 多平台
14. macOS 端用纯 SwiftUI / Catalyst / Tauri (Web wrap)？
15. 浏览器扩展是否做 Edge / Brave 单独发布？
16. Watch 是否支持 standalone（不依赖 iPhone）？

### 17.F 隐私
17. Private vault 主密码遗忘是否提供"销毁 private 数据后重置"的选项？
18. 是否提供 "Local-only mode"（完全不传云）的高级选项？

### 17.G 设计与品牌
19. DayPage 与 Codex 是否做品牌合并（统一叫 DayPage）还是双品牌（Web 叫 Codex by DayPage）？
20. 是否需要重新做 logo / 视觉识别 V5？

---

## 附录 A · 与既有 PRD 的关系

| PRD | 关系 |
|---|---|
| `prd-daypage-mvp.md` (V1) | V1 全部能力被 V5 承袭，不变 |
| `prd-daypage-v2-roadmap.md` (V2) | V2 的功能向 issue 在 V5 中按需融合 |
| `prd-daypage-v3-experience.md` (V3) | V3 的体验升级（On This Day / 视觉 / 编译反馈）继续生效，V5 增量 |
| `prd-daypage-v4-liquid-glass.md` (V4) | V4 的 iOS 视觉系统继续生效 |
| `prd-today-composer-liquid-refinement.md` | iOS 输入条精修，继续生效 |
| `prd-auth-login.md` | 登录方案被 V5 §6.G 覆盖，可归档 |
| `prd-sentry-linear-integration.md` | 已落地，V5 继续使用 |

V5 不替代任何既有 PRD，是**叠加**的更上层文档。

## 附录 B · 与技术方案的关系

- 本 PRD 描述**做什么、为什么、给谁**
- 姊妹文档 `docs/web/PLAN.md` 描述**怎么做**（架构、技术栈、API、表结构、Wave 工程细节）
- `docs/web/PLAN.md` §0 锁定决策 与 本 PRD §0 锁定决策 互相一致

---

## 附录 C · 文档维护

- 本 PRD 是 **living document**，随 Wave 推进可更新但 §0 锁定决策不轻易动
- 任何 §6 FR 的修改需在 commit message 注明 "FR-N changed: <reason>"
- 任何 §11 Non-Goals 的开放需经过主理人显式确认
- 每个 Wave 完成时在 §15 对应位置打 ✅

---

**END · DayPage V5 · Codex PRD · 2026-05-10**
