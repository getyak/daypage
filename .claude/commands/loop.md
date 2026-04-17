---
allowed-tools: [Bash, Read, Grep, Glob, Edit]
description: "批量迭代执行任务（Loop 模式），完成后自动推进语义版本 tag"
argument-hint: "[任务描述，如 \"fix all P2 issues\"]"
---

# /loop — 批量迭代执行 + 版本 Tag 发布

## 用户意图
循环执行一批任务（如修多个 issue、批量重构、UI 对齐），每轮完成后验证，最终整体完成后**打一个语义化 git tag 并推送**，触发 CI 自动发布到 TestFlight。

## 执行流程

### Phase 1 — 任务准备
- 读取 `$ARGUMENTS`，明确本次 loop 的目标范围
- `git status` 确认工作区状态
- `git tag --sort=-version:refname | head -5` 查看当前最新 tag

### Phase 2 — 迭代执行
按任务列表逐一执行，每轮：
1. 实现改动
2. `xcodebuild -scheme DayPage build`（快速验证编译）
3. 标记该子任务完成
4. 继续下一个，直到所有任务完成

### Phase 3 — 完成后打 Tag（**必须执行**）

#### 3.1 确定下一个版本号
```bash
# 读取最新 tag
LATEST=$(git tag --sort=-version:refname | grep -E '^v[0-9]+\.[0-9]+' | head -1)
echo "当前最新 tag: $LATEST"
```

版本号递增规则（语义化版本 SemVer）：

| 本次改动类型 | 递增哪一位 | 示例 |
|---|---|---|
| 新功能（feat） | MINOR | v1.0.0 → v1.1.0 |
| Bug 修复（fix） | PATCH | v1.0.0 → v1.0.1 |
| 重大 breaking change | MAJOR | v1.0.0 → v2.0.0 |
| 多个 fix | PATCH | v1.0.3 → v1.0.4 |
| 多个 feat | MINOR | v1.1.0 → v1.2.0 |

无 tag 时从 `v0.1.0` 开始。

#### 3.2 提交所有改动
```bash
# 用具体文件名 add，不用 git add -A
git add <file1> <file2> ...
git commit -m "$(cat <<'EOF'
<type>: <本次 loop 改动摘要>

Loop 完成：<简述做了什么>
EOF
)"
```

#### 3.3 打 tag 并推送
```bash
# 创建 annotated tag，附上本次改动说明
git tag -a v<NEW_VERSION> -m "$(cat <<'EOF'
DayPage v<NEW_VERSION>

<本次 loop 完成的改动列表，每条一行>
EOF
)"

# 先推 commit，再推 tag（tag push 会触发 TestFlight CI）
git push origin <当前分支>
git push origin v<NEW_VERSION>
```

推送 tag 后，GitHub Actions `testflight.yml` 会自动：
1. 读取 tag 作为 `MARKETING_VERSION`（例如 `v1.2.0` → `1.2.0`）
2. 用 git commit 总数作为 `CURRENT_PROJECT_VERSION`（Build Number）
3. 构建并上传到 TestFlight
4. 在 GitHub 创建 Release，附上 IPA 和 changelog

### Phase 4 — 收尾确认
- 展示新 tag 和触发的 CI 链接
- `git log --oneline -5` 确认 commit 和 tag 正确
- 告知用户：TestFlight 构建预计 10~15 分钟后出现在 App Store Connect

## 版本号计算示例

```
当前 tag: v1.0.3
本次做了 2 个 fix + 1 个 feat → MINOR 递增
新 tag: v1.1.0
```

```
当前 tag: v1.1.0
本次只做了 3 个 fix → PATCH 递增
新 tag: v1.1.1
```

```
无任何 tag
→ 新 tag: v0.1.0
```

## 红线
- ❌ 不要跳过 Phase 3 的 tag 步骤——没有 tag 就不会触发 TestFlight 发布
- ❌ 不要用轻量 tag（`git tag v1.0.0`）——必须用 annotated tag（`git tag -a`）才有完整 changelog
- ❌ 不要在 tag 里用 `v` 以外的前缀（CI 匹配的是 `v*`）
- ❌ 不要先推 tag 再推 commit——顺序是先 commit、再 push branch、最后 push tag

$ARGUMENTS
