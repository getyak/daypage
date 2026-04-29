# PRD: Sentry + Linear 错误监控与自动同步

## Introduction

为 DayPage iOS 客户端及后台编译服务（AI 调用链路）集成 Sentry，实现崩溃捕获、性能监控、API 错误追踪。所有新错误通过 Sentry Webhook → GitHub Actions 中转 → Linear API 的方式自动创建 Linear Issue，并附带完整的上下文信息（堆栈、用户影响、环境）供 AI 时代的开发流程直接消费。

**架构选型理由**（方案 A 变体）：Sentry Webhook + GitHub Actions 中转，而非 no-code 工具或 Sentry 官方插件。原因：
- GitHub Actions 脚本可版本化、可 code review、可被 AI agent 修改
- 中转逻辑（去重、过滤、富化）完全自控
- 零额外付费服务依赖
- 与现有 `.github/workflows/` CI/CD 体系统一管理

---

## Goals

- 客户端崩溃、未处理异常在 5 分钟内出现在 Linear
- 后台编译链路（DashScope / Whisper API）的网络错误、超时自动上报
- Linear Issue 包含足够上下文（堆栈摘要、受影响用户数、发生环境、Sentry 链接），开发者无需跳转即可开始修复
- 重复错误不重复创建 Issue（基于 Sentry fingerprint 去重）
- 现有 `DayPageLogger` 日志系统与 Sentry breadcrumb 打通，错误发生前的操作轨迹可见

---

## User Stories

### US-001: 集成 Sentry iOS SDK
**Description:** As a developer, I need the Sentry SDK initialized at app launch so that all unhandled crashes and errors are automatically captured.

**Acceptance Criteria:**
- [ ] 通过 Swift Package Manager 添加 `Sentry` 依赖（`https://github.com/getsentry/sentry-cocoa`，版本 ≥ 8.x）
- [ ] `DayPageApp.swift` 启动时调用 `SentrySDK.start`，DSN 从 `GeneratedSecrets.swift` 读取（key: `SENTRY_DSN`）
- [ ] `generate_secrets.sh` 脚本新增 `SENTRY_DSN` 变量支持
- [ ] `.env.example` 新增 `SENTRY_DSN=` 占位注释
- [ ] 构建成功，`xcodebuild -scheme DayPage build` 无错误

### US-002: 性能监控 — 启动时间与 API 追踪
**Description:** As a developer, I want Sentry to trace app launch performance and outbound API calls so that slow compilations and Whisper timeouts are visible.

**Acceptance Criteria:**
- [ ] `SentrySDK.start` 配置 `tracesSampleRate = 0.2`（生产）/`1.0`（debug）
- [ ] `CompilationService.swift` 的 DashScope 请求包裹在 Sentry span 中，span name: `compilation.dashscope`
- [ ] `VoiceService.swift` 的 Whisper 请求包裹在 Sentry span 中，span name: `voice.whisper`
- [ ] `WeatherService.swift` 的 OpenWeatherMap 请求包裹在 Sentry span，span name: `weather.fetch`
- [ ] 构建成功

### US-003: DayPageLogger 与 Sentry Breadcrumb 打通
**Description:** As a developer, I want existing log entries to appear as Sentry breadcrumbs so that I can see what the user did before a crash without changing all call sites.

**Acceptance Criteria:**
- [ ] `DayPageLogger.error()` 同时调用 `SentrySDK.capture(error:)` 并附加 `level: .error`
- [ ] `DayPageLogger.warn()` 添加 Sentry breadcrumb，`level: .warning`
- [ ] `DayPageLogger.info()` 添加 Sentry breadcrumb，`level: .info`
- [ ] Breadcrumb message 格式与现有日志格式一致（`file:line — message`）
- [ ] 现有所有 `DayPageLogger.error()` 调用无需修改即自动上报
- [ ] 构建成功

### US-004: 用户上下文注入
**Description:** As a developer, I want Sentry events to include user ID and app version so I can filter errors by user cohort and build.

**Acceptance Criteria:**
- [ ] 用户登录后（`AuthService` 认证成功时）调用 `SentrySDK.setUser(SentryUser(userId: ...))`
- [ ] 用户登出时调用 `SentrySDK.setUser(nil)`
- [ ] Sentry event 自动包含 `app.version`、`app.build`、`device.model`、`os.version`
- [ ] 构建成功

### US-005: GitHub Actions Webhook 中转服务
**Description:** As a developer, I need a GitHub Actions workflow that receives Sentry webhooks and creates Linear issues so the pipeline is version-controlled and auditable.

**Acceptance Criteria:**
- [ ] 新建 `.github/workflows/sentry-to-linear.yml`，触发方式：`repository_dispatch`，event type: `sentry_issue`
- [ ] Workflow 接收 payload：`issue_id`, `title`, `culprit`, `url`, `count`, `userCount`, `environment`, `fingerprint`
- [ ] 使用 Linear API（GraphQL mutation `issueCreate`）在指定项目创建 Issue
- [ ] Linear Issue title 格式：`[Sentry] {title}` 
- [ ] Linear Issue description 包含：错误摘要、受影响用户数、发生次数、环境、Sentry 链接
- [ ] Linear Issue label 自动设置为 `bug`，priority 根据 `userCount` 映射（≥10 → Urgent, ≥3 → High, else → Medium）
- [ ] `SENTRY_WEBHOOK_SECRET`、`LINEAR_API_KEY`、`LINEAR_PROJECT_ID` 存储在 GitHub Secrets
- [ ] Workflow 有去重检查：同一 `fingerprint` 在 Linear 中已存在 open issue 则跳过创建（通过 Linear GraphQL query 检查）
- [ ] Workflow 执行日志可审计，失败时 GitHub Actions 发送通知

### US-006: Sentry Webhook 配置
**Description:** As a developer, I need Sentry configured to send new issue alerts to the GitHub Actions endpoint so the pipeline is triggered automatically.

**Acceptance Criteria:**
- [ ] Sentry Project Settings → Integrations → Webhooks 中添加 GitHub Actions `repository_dispatch` endpoint URL
- [ ] Webhook 仅触发 "New Issue" 事件（不触发每次发生）
- [ ] Webhook payload 包含 `fingerprint` 字段（通过 Sentry Alert Rule 的 payload 模板配置）
- [ ] `tasks/runbook-sentry-linear.md` 记录 Sentry Webhook 配置步骤（截图或文字说明）

### US-007: 端到端验证
**Description:** As a developer, I want to verify the full pipeline works before going live so I don't miss real errors after launch.

**Acceptance Criteria:**
- [ ] 在 Simulator debug build 中通过 `SentrySDK.crash()` 触发测试崩溃
- [ ] Sentry Dashboard 5 分钟内出现该事件
- [ ] GitHub Actions `sentry-to-linear` workflow 被触发并成功执行
- [ ] Linear 对应项目中出现新 Issue，title 以 `[Sentry]` 开头
- [ ] Linear Issue description 包含 Sentry 链接
- [ ] 再次触发同一崩溃，Linear 不重复创建 Issue（去重生效）
- [ ] `tasks/runbook-sentry-linear.md` 更新测试验证结果

---

## Functional Requirements

- **FR-1**: Sentry iOS SDK 通过 SPM 引入，DSN 通过 `GeneratedSecrets.swift` 注入，不硬编码
- **FR-2**: 崩溃上报覆盖范围：Swift/ObjC 崩溃、未处理 Swift Error、SwiftUI 渲染异常
- **FR-3**: 性能追踪覆盖三条 API 链路：DashScope（编译）、Whisper（语音转文字）、OpenWeatherMap
- **FR-4**: `DayPageLogger` 保持现有接口不变，内部新增 Sentry 副作用，所有调用方零改动
- **FR-5**: GitHub Actions workflow 以 `repository_dispatch` 为入口，支持 curl / Sentry Webhook 两种触发方式
- **FR-6**: Linear Issue 优先级映射：`userCount ≥ 10` → Urgent, `≥ 3` → High, `< 3` → Medium
- **FR-7**: 去重策略基于 Sentry `fingerprint`，通过 Linear GraphQL query `issues(filter: {title: {startsWith: "[Sentry]"}, state: {type: {in: ["unstarted", "started"]}}})` 检查
- **FR-8**: 所有密钥（`SENTRY_DSN`, `LINEAR_API_KEY`, `LINEAR_PROJECT_ID`, `SENTRY_WEBHOOK_SECRET`）均通过环境变量注入，不出现在代码中
- **FR-9**: `BackgroundCompilationService.swift` 的后台任务错误同样上报（后台任务失败是最难察觉的 bug 类型）

---

## Non-Goals

- 不集成 Sentry Performance UI（React Native / Web SDK）— 纯 iOS
- 不实现 Sentry → Linear 的双向同步（Linear Issue 关闭不回写 Sentry）
- 不实现 Sentry Alert on Regression（仅 New Issue）
- 不实现自定义 Sentry Dashboard — 使用 Sentry 默认 UI
- 不修改现有错误枚举（`LocationError`, `CompilationError` 等）的定义
- 不集成 Slack 通知（Linear 本身有通知机制）

---

## Technical Considerations

### Sentry SDK 配置示例
```swift
// DayPageApp.swift
SentrySDK.start { options in
    options.dsn = GeneratedSecrets.sentryDSN
    options.tracesSampleRate = ProcessInfo.processInfo.environment["DEBUG"] != nil ? 1.0 : 0.2
    options.enableCrashHandler = true
    options.enableNetworkTracking = true  // 自动追踪 URLSession 请求
    options.attachScreenshot = true       // 崩溃时截图
    options.attachViewHierarchy = true    // 崩溃时 SwiftUI 视图树
}
```

### GitHub Actions Workflow 核心逻辑
```yaml
# .github/workflows/sentry-to-linear.yml
on:
  repository_dispatch:
    types: [sentry_issue]

jobs:
  create-linear-issue:
    runs-on: ubuntu-latest
    steps:
      - name: Check duplicate
        # GraphQL query Linear for existing open issue with same fingerprint
      - name: Create Linear Issue
        # GraphQL mutation issueCreate with mapped priority
```

### Sentry Webhook → GitHub Actions 桥接
Sentry 原生 Webhook 不能直接触发 `repository_dispatch`。需要一个轻量中间层：
- **推荐方案**：Sentry Alert Rule → Webhook URL = GitHub Actions `repository_dispatch` API endpoint，使用 GitHub PAT 签名
- **端点**：`https://api.github.com/repos/{owner}/{repo}/dispatches`
- **签名验证**：在 workflow 中验证 `SENTRY_WEBHOOK_SECRET`

### GeneratedSecrets 扩展
```swift
// GeneratedSecrets.swift（自动生成）
static let sentryDSN = "{{ SENTRY_DSN }}"
```
```bash
# .env
SENTRY_DSN=https://xxx@oXXX.ingest.sentry.io/XXXX
LINEAR_API_KEY=lin_api_xxxxx
LINEAR_PROJECT_ID=xxxxx
```

### 依赖版本
- `sentry-cocoa` ≥ 8.36.0（最新稳定，支持 SwiftUI 视图层级捕获）
- Linear API: GraphQL endpoint `https://api.linear.app/graphql`

---

## Design Considerations

无 UI 改动。这是纯基础设施集成，对用户不可见。

---

## Success Metrics

- 崩溃捕获率：首次发布后 7 天内，Sentry 中出现至少 1 个真实事件（验证 SDK 工作）
- 端到端延迟：从 Sentry 检测到新 Issue → Linear Issue 创建 ≤ 10 分钟
- 去重准确率：同一错误在 Linear 中不出现重复 open Issue
- 零性能回归：集成后 app 启动时间增加 ≤ 100ms（Sentry SDK 冷启动开销）
- 后台编译错误可见性：`BackgroundCompilationService` 失败率在 Sentry 中可查

---

## Open Questions

1. **Linear 项目 ID**：需要确认目标 Linear 项目名称/ID（PRD 执行前需在 GitHub Secrets 中配置 `LINEAR_PROJECT_ID`）
2. **Sentry 组织/项目**：需创建 Sentry 账号并新建 iOS project，获取 DSN
3. **GitHub PAT 权限**：触发 `repository_dispatch` 需要 `repo` scope 的 PAT，需确认是否使用现有 token
4. **`tracesSampleRate` 生产值**：0.2（20%）是初始建议值，实际应基于用户量和 Sentry 配额决定
5. **后台任务错误的 Sentry flush**：`BGAppRefreshTask` 结束时需显式调用 `SentrySDK.flush(timeout:)` 确保事件发送完成，需在 `BackgroundCompilationService` 中处理
