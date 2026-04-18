# CI/CD — GitHub Actions → TestFlight

## 工作流触发条件

| 触发 | 说明 |
|------|------|
| push to `main`（通常是 PR 合并） | 自动 patch +1 → 打 tag → 构建并上传 TestFlight |
| 手动 `workflow_dispatch` | 可选 `beta`（TestFlight）/ `release`（App Store），可传 `version_override` 跳过自动 patch |

纯文档/设计稿改动（`design/`、`**.md`、`scripts/ralph/**`、`tasks/**`、`.gitignore`）**不会**触发构建。

### 版本号规则

1. **首次发布**：仓库无 `v*.*.*` tag，从 `DayPage.xcodeproj/project.pbxproj` 的 `MARKETING_VERSION` 读取（目前是 `0.0.1`）。
2. **后续发布**：读取最近的 `v*.*.*` tag，patch 段 +1（如 `v0.0.1` → `v0.0.2`）。
3. **手动覆盖**：`workflow_dispatch` 传 `version_override=0.1.0`，workflow 会打 `v0.1.0` tag。

tag 只在 TestFlight 上传成功后才会被 push 到 origin，失败不留脏 tag。

### Changelog 来源

按优先级：

1. 从合并的 PR 取 `title + body`（通过 commit message 里的 `(#123)` 定位 PR）。
2. 没有 PR 引用（例如直接 push 到 main）：用 head commit 的完整 message。
3. 本地 fastlane 手动跑：回退到最近 10 条 commit message。

内容会被截到 3800 字符（TestFlight "What to Test" 上限 4000）。

---

## 需要配置的 GitHub Secrets

进入 `Settings → Secrets and variables → Actions → New repository secret`，逐一添加以下 8 个 Secret：

### 必填 Secrets

| Secret 名称 | 说明 | 获取方式 |
|-------------|------|---------|
| `DEVELOPMENT_TEAM` | Apple Team ID（10位字母数字） | [developer.apple.com/account](https://developer.apple.com/account) → Membership |
| `ENV_FILE` | 完整的 `.env` 文件内容（多行） | 复制本地 `.env` 文件的全部内容 |
| `BUILD_CERTIFICATE_BASE64` | 发行版签名证书（.p12）的 base64 | 见下方「导出证书」 |
| `P12_PASSWORD` | .p12 证书的密码 | 导出时自己设置的密码 |
| `KEYCHAIN_PASSWORD` | CI 临时 keychain 密码（随机字符串即可） | 自己设定，例如：`ci-keychain-2024` |
| `BUILD_PROVISION_PROFILE_BASE64` | Provisioning Profile 的 base64 | 见下方「导出 Profile」 |
| `APP_STORE_CONNECT_API_KEY_ID` | ASC API Key 的 Key ID | App Store Connect → Users → Keys |
| `APP_STORE_CONNECT_ISSUER_ID` | ASC API Key 的 Issuer ID | 同上页面顶部 |
| `APP_STORE_CONNECT_API_KEY_CONTENT` | ASC API Key 的 .p8 文件内容 | 下载 .p8 文件后 `cat` 出来 |

---

## 操作步骤

### 第一步：Apple 开发者后台 — 创建 App

1. 登录 [App Store Connect](https://appstoreconnect.apple.com)
2. 点击「My Apps」→「+」→「New App」
3. Bundle ID 填：`com.daypage.app`
4. 记录 App ID

### 第二步：创建签名证书（Distribution Certificate）

```bash
# 方法一：Xcode 自动管理（推荐）
# Xcode → Settings → Accounts → 选择你的 Apple ID
# → Manage Certificates → + → Apple Distribution

# 方法二：手动创建
# developer.apple.com → Certificates → + → Apple Distribution
```

**导出 .p12 文件：**

```bash
# Keychain Access → 我的证书 → 右键 "Apple Distribution: ..." → 导出
# 格式选 .p12，设置密码（就是 P12_PASSWORD）

# 转成 base64：
base64 -i Certificates.p12 | pbcopy
# 复制结果粘贴到 GitHub Secret: BUILD_CERTIFICATE_BASE64
```

### 第三步：创建 Provisioning Profile

```bash
# developer.apple.com → Profiles → + 
# → App Store → 选择 App ID: com.daypage.app → 选择证书 → 下载

# 转成 base64：
base64 -i DayPage_AppStore.mobileprovision | pbcopy
# 粘贴到 GitHub Secret: BUILD_PROVISION_PROFILE_BASE64
```

### 第四步：创建 App Store Connect API Key

```bash
# App Store Connect → Users and Access → Keys → +
# 角色选 App Manager（或 Developer）
# 下载 .p8 文件（只能下载一次！）

# Key ID 和 Issuer ID 在页面上直接显示

# .p8 文件内容：
cat AuthKey_XXXXXXXXXX.p8 | pbcopy
# 粘贴到 GitHub Secret: APP_STORE_CONNECT_API_KEY_CONTENT
```

### 第五步：填写 ENV_FILE Secret

```bash
# 本地复制 .env 文件内容：
cat .env | pbcopy
# 粘贴到 GitHub Secret: ENV_FILE
```

### 第六步：更新 project.pbxproj 中的 DEVELOPMENT_TEAM

打开 Xcode → 选择 Target DayPage → Signing & Capabilities
→ Team 选择你的开发者账号 → Xcode 会自动写入 DEVELOPMENT_TEAM

---

## 本地验证

配置完成后，先在本地跑一次确认没问题：

```bash
# 安装依赖
bundle install

# 只构建（不上传，验证证书和 scheme）
bundle exec fastlane build_only

# 上传 TestFlight
bundle exec fastlane beta
```

---

## 常见问题

**Q: `No signing certificate found`**
A: 确认 BUILD_CERTIFICATE_BASE64 对应的是 Distribution（不是 Development）证书。

**Q: `Provisioning profile doesn't include the currently selected device`**  
A: App Store 类型的 Profile 不包含具体设备，这是正常的，CI 环境不需要设备。

**Q: Build number 冲突**  
A: Fastfile 用 `git rev-list --count HEAD` 作 build number，保证单调递增，一般不会冲突。

**Q: 第一次上传后 TestFlight 一直 Processing**  
A: 正常现象，Apple 需要 15-30 分钟处理。workflow 里设置了 `skip_waiting_for_build_processing: true`，不会等待。
