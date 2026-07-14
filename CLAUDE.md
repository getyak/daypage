# DayPage — Claude Code Project Guidelines

## Overview

DayPage: a personal logging tool centered on daily raw data capture. Users dump, AI compiles into structured diary entries and a knowledge network each day. Target users: nomads / digital nomads.

## Tech Stack

### Client

| Layer | Choice | Notes |
|---|---|---|
| Platform | **iOS 16.0+**, Swift 5 | Single Xcode target `DayPage.app`; SPM deps: Supabase, Sentry |
| UI | **SwiftUI** (pure) | UIKit only via `UIViewControllerRepresentable` wrappers (ShareSheet, CameraPicker, DocumentPicker) and `UITabBarAppearance` in `RootView.swift` |
| Navigation | **Sidebar** | Left drawer (280pt) — Today / Archive / Graph; no bottom TabBar |
| State | `ObservableObject` + `@Published` + `@StateObject`, `@MainActor` services | No `@Observable` macro (Swift 5 constraint) |
| Persistence | **File system** — YAML front-matter + Markdown | `vault/raw/YYYY-MM-DD.md`, multi-memo separated by `\n\n---\n\n`. Atomic writes via `FileManager.replaceItem`. No Core Data / SwiftData |
| YAML / Markdown | Hand-written parser in `Models/Memo.swift` | No external Markdown library |
| Voice | `AVAudioRecorder` → M4A under `vault/raw/assets/`; transcription via **OpenAI Whisper API** (`VoiceService.swift`) | |
| Camera / photos | **PhotosUI** + `PHPicker` | EXIF extraction; originals saved, thumbnails for UI |
| Location / Weather | CoreLocation + reverse geocoding; OpenWeatherMap (10-min cache) | |
| Fonts | Space Grotesk / Inter / JetBrains Mono (bundled TTF) | Registered via `DSFonts.registerAll()` at launch |

### AI Compilation Engine

| Feature | Choice | Notes |
|---|---|---|
| Provider | **Aliyun DashScope** (OpenAI-compatible) | `CompilationService.swift`, model `qwen3.5-plus` |
| API key | `Config/GeneratedSecrets.swift` (generated from env, gitignored) | Never hardcode in source |
| Schedule | **BGTaskScheduler** `com.daypage.daily-compilation`, 02:00 daily + backfill | `BackgroundCompilationService.swift` |
| Input | Text only — no raw audio / image bytes sent | |

## Project Structure

```
DayPage/
  App/              RootView, DayPageApp, Fonts, Typography
  Features/         Today / Archive / Graph
  Models/           Memo, Attachment, YAML parser
  Services/         RawStorage, Location, Weather, Photo, Voice, Compilation, BackgroundCompilation, SyncQueue, OnThisDay, WeeklyCompilation
  Config/           GeneratedSecrets (gitignored), FeatureFlags
```

**Web frontend**: `web/` (Next.js, `localhost:3000`). Its env vars (e.g. `DASHSCOPE_API_KEY`) go in `web/.env.local`, not the iOS-side `GeneratedSecrets.swift`.

**Pipeline**: Today (raw input) → AI compilation → Daily Page (structured diary) → Entity Pages → Graph (knowledge graph view).

## Key Invariants (not derivable from code alone)

- **编译触发模型**：打开 App 不自动编译当天；一天只在结束后编译一次（0 点 BGTask 编译昨天 + 前台补编 + backfill 兜底）；手动编译保留。
- **source_hash 去重**：`CompilationService.sourceHash` 刻意排除 mood/entityMentions（编译后会回写进 raw，纳入会造成无限重编环）。无 hash 的历史 daily 视为最新，防 backfill 重编全史。
- **FeatureFlags**：`Config/FeatureFlags.swift` enum + `FeatureFlagStore`（UserDefaults），Settings「实验功能」自动列出所有 case；Widget target 共享同一文件。新增可开关功能走这里。
- **Notification.Name**：集中声明在各 owner service 文件里，跨页跳转用 `.openMemo` / `.openEntityPage` / `.openArchiveAt`。新增前先 grep 复用。

## Coding Conventions

- SwiftUI views: value types; extract subviews when a `body` exceeds ~80 lines
- Services: `@MainActor final class`, singletons where shared state is required
- View models: `@MainActor final class: ObservableObject` with `@Published`
- `MARK: -` section comments for navigation
- No force-unwraps in production paths; prefer `guard let` / `throws`
- No external dependencies without discussion — prefer Apple frameworks

## UI Design

**Use the current source code as the authoritative reference for UI design** — read `RootView.swift`, `TodayView.swift`, etc. directly (design assets have been removed).

For design decisions: think it through deeply, hand the user an **artifact link to review**; once agreed, implement directly — no GitHub issue step.

## Testing

`DayPageTests` target uses **Swift Testing**. Add new test files there.

- **Default simulator**: iPhone 17 (`xcodebuild -scheme DayPage -destination 'platform=iOS Simulator,name=iPhone 17'`)
- **Simulator launch**: always in the background (`open -a Simulator &` or `run_in_background: true`) — never block the terminal

Before marking any task complete:
1. Build the `DayPage` scheme
2. Run existing tests
3. Storage changes: inspect the actual `.md` written under `vault/raw/` and verify YAML front-matter + Markdown structure
4. UI changes: launch in Simulator and verify visually — SwiftUI preview alone is not sufficient

## Skill routing

When the user's request matches an available skill, invoke it via the Skill tool as your FIRST action:

- Product ideas, brainstorming → office-hours
- Bugs, errors, "why is this broken" → investigate
- Ship, deploy, push, create PR → ship
- QA, test the site → qa
- Code review, check my diff → review
- Update docs after shipping → document-release
- Weekly retro → retro
- Design system, brand → design-consultation
- Visual audit, design polish → design-review
- Architecture review → plan-eng-review
- Code quality, health check → health
