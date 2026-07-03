---
name: verify-daypage
description: DayPage iOS App 端到端自动验证。构建 App、在 Simulator 里按 PRD V3 的 User Story 逐条跑端到端验证（UI + 存储 + AI 管线），发现问题自动在 GitHub 建 issue（带 label 去重）。适用于 dogfood 前的回归验证、每个 Wave 结束的验收、以及日常的冒烟测试。触发词：verify daypage、验证 daypage、跑端到端、dogfood 验证。
---

# verify-daypage — DayPage 端到端自动验证

## 这个 Skill 是什么

一个针对 DayPage iOS App 的自动化验证管道：

1. **构建** — `xcodebuild` 编译 Debug 包
2. **启动** — `xcrun simctl` 启动指定 Simulator、装 App、launch
3. **执行** — 按 PRD v3 的 User Story 逐条跑，每个 story 一个 shell 脚本
4. **观察** — 截图 + 读 vault 文件 + 读 App 日志
5. **判定** — 对照 PRD 验收标准给 pass/fail
6. **上报** — fail 时 `gh` 自动建 issue（按 `story-id` 去重）

所有产物落在 `.Codex/skills/verify-daypage/runs/<run-id>/`。

## 何时触发

- 用户说"verify daypage / 跑端到端 / 自动验证 / dogfood 验证"
- 每个 Wave 代码 merge 后主理人要做回归
- 主理人说"我要看看这一 Wave 做完到底稳不稳"

不要用于：单元测试（那是 `DayPageTests` target 的事）、纯 UI 预览检查。

## 参数约定

调用时从用户意图推断，或解析 `$ARGUMENTS`：

| 参数 | 含义 | 默认 |
|---|---|---|
| `--wave w1|w2|w3|w4|w5|all` | 跑哪个 Wave 的 story | `all` |
| `--smoke` | 每个 Wave 只跑最关键的 1 个 | 开启 |
| `--mock-ai` | 跳过真实 AI 调用（**v0 未实现**，传了就报错） | off |
| `--dry-run-issues` | 不真建 issue，把 draft 打印出来 | off |
| `--device "iPhone 15"` | 指定 Simulator 设备 | 已 booted 的第一个 |
| `--keep-vault` | 跑完不还原真实 vault（调试用） | off |

默认行为（无参数）：`--wave all --smoke`，真 AI，真建 issue。约 15 分钟。

## 执行协议

**Codex 的职责**：编排 + 判定 + 建 issue。**不要**试图直接用 SwiftUI 点屏幕——全部委托给 `lib/` 里的 shell 脚本。

### Step 1：环境预检

```bash
bash .Codex/skills/verify-daypage/lib/preflight.sh
```

检查：`xcodebuild` 版本、`xcrun simctl` 可用、`gh auth status`、`jq` 已装、DashScope key（除非 `--mock-ai`）。

**失败就停**，直接报给用户缺什么。不要硬跑。

### Step 2：隔离 vault（护栏 1）

```bash
bash .Codex/skills/verify-daypage/lib/vault-isolate.sh backup
```

这一步会把真实 `Documents/vault/` 从 sandbox 备份到 `/tmp/daypage-vault-backup-<run-id>/`，并且在脚本里注册 `trap` 确保崩溃也能还原。**关键**：不做这一步就跑验证 = 污染用户真实日记。

### Step 3：build + boot + install + launch

```bash
bash .Codex/skills/verify-daypage/lib/build-and-boot.sh "<device>"
```

输出 sandbox data 路径到 `runs/<run-id>/env.json`，后续 story 脚本从这里读。

### Step 4：跑 story

按参数选出 story 列表（见 `stories/_registry.tsv`），逐条跑：

```bash
bash .Codex/skills/verify-daypage/stories/V3-001.sh <run-id>
```

每个 story 脚本返回：
- exit 0 = pass
- exit 1 = fail（`runs/<run-id>/<story-id>/result.json` 带详情）
- exit 2 = skip（环境不满足，不计 fail）

### Step 5：判定 + 建 issue

Codex 读 `runs/<run-id>/<story-id>/result.json`（格式见下），fail 的调用：

```bash
bash .Codex/skills/verify-daypage/lib/issue-create.sh <story-id> <run-id> [--dry-run]
```

issue-create.sh 内部：
1. `gh issue list --label verify-daypage --search "[<story-id>]" --state open` 找同类
2. 找到 → 追加评论 + 新截图
3. 没找到 → `gh issue create` 用 `templates/issue-body.md`，打 label：`verify-daypage`、`wave-<w>`、`auto-generated`、`story-<id>`

### Step 6：还原 + 汇总

```bash
bash .Codex/skills/verify-daypage/lib/vault-isolate.sh restore
```

然后在 `runs/<run-id>/report.md` 里写总表（story / pass|fail / issue 链接 / 耗时），最后用聊天把这份 report 的摘要贴给用户。

## result.json 契约

每个 story 脚本必须写这个文件，Codex 按它建 issue：

```json
{
  "storyId": "V3-001",
  "storyTitle": "语音转写数据丢失根治",
  "wave": "w1",
  "status": "fail",
  "durationSec": 12.3,
  "acceptanceCriteria": [
    { "desc": "录 5 秒 → transcript 非空", "passed": true },
    { "desc": "transcript 字符数 ≥ 10", "passed": false, "actual": "3 chars" }
  ],
  "evidence": {
    "screenshots": ["01-recording.png", "02-saved.png"],
    "vaultFiles": ["vault-verify/raw/2026-04-17.md"],
    "logs": ["app.log"]
  },
  "reproSteps": [
    "1. Boot Simulator + launch DayPage",
    "2. 点击输入框右侧麦克风按钮",
    "3. 用 simctl push 注入 5 秒中文音频",
    "4. 停止录音",
    "5. 读取 vault-verify/raw/<today>.md"
  ],
  "notes": "transcript 只捕获到 '你好吗'，应为 '你好吗我在北京今天天气真好'"
}
```

## Story 注册表

见 `stories/_registry.tsv`（TSV：`story-id`、`wave`、`is-smoke`、`title`、`script-path`）。

v0 首发只实现 V3-001（语音转写完整性）作为样板。其他 story 后续迭代补齐。

## 不要做的事

- ❌ 不要跳过 vault-isolate，哪怕用户说"没事"
- ❌ 不要在真实 `vault/` 下留测试 memo
- ❌ 不要在 `--dry-run-issues` 时调 `gh issue create`
- ❌ 不要一个 story 建多个 issue（用 `[<story-id>]` 前缀去重）
- ❌ 不要把 DashScope key 打进日志或 issue body

## 相关文件

- PRD：`tasks/prd-daypage-v3-experience.md`
- 项目指南：`AGENTS.md`
- Command 入口：`.Codex/commands/verify-daypage.md`
