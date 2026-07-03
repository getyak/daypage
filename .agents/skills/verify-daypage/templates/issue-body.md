<!-- 自动生成 by verify-daypage skill。请勿手动编辑标题的 [{{STORY_ID}}] 前缀，否则去重会失效。 -->

## 来源

- **验证 Run**：`{{RUN_ID}}`
- **PRD**：`tasks/prd-daypage-v3-experience.md` — `{{STORY_ID}}`
- **Wave**：{{WAVE}}
- **触发方式**：`/verify-daypage` 自动化验证

## 现象

见下方 `result.json` 的 `acceptanceCriteria` 和 `notes` 字段。未通过的验收点会在 `passed: false` 上标注。

## 复现

见 `result.json` 的 `reproSteps`。

## 证据

截图 / 日志 / vault 文件路径见 `result.json` 的 `evidence`，本地存放于：

```
.claude/skills/verify-daypage/runs/{{RUN_ID}}/{{STORY_ID}}/
```

> 这些产物是**验证运行时的临时快照**，仓库不会常驻保存。需要调查时基于 run-id 重新跑一遍。

## 建议修复路径

- 先按 PRD `{{STORY_ID}}` 的"期望行为"对照现象定位
- 如果是 Critical/用户可感知的 regression，插队到当前 Wave
- 修完后重跑 `/verify-daypage --wave {{WAVE}}`，通过后本 issue 自动维持 open → 人工 close
