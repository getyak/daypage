# DayPage — Claude Code Project Guidelines

## Overview

DayPage: a personal logging tool centered on daily raw data capture. Users dump, AI compiles into structured diary entries and a knowledge network each day. Target users: nomads / digital nomads.

## Tech Stack

### Client

| Layer | Choice | Notes |
|---|---|---|
| Platform | **iOS 16.0+**, Swift 5 | Single Xcode target `DayPage.app`, no SPM dependencies |
| UI | **SwiftUI** (pure) | `UITabBarAppearance` is the only UIKit touchpoint (`RootView.swift`) |
| Navigation | **Sidebar** | Left drawer (280pt) — Today / Archive / Graph (disabled, Post-MVP); no bottom TabBar |
| State | `ObservableObject` + `@Published` + `@StateObject`, `@MainActor` services | No `@Observable` macro (Swift 5 constraint) |
| Persistence | **File system** — YAML front-matter + Markdown | `vault/raw/YYYY-MM-DD.md`, multi-memo separated by `\n\n---\n\n`. Atomic writes via `FileManager.replaceItem`. No Core Data / SwiftData |
| YAML / Markdown | Hand-written parser in `Models/Memo.swift` | No external Markdown library |
| Voice recording | **AVFoundation** `AVAudioRecorder` → M4A | Stored under `vault/raw/assets/` |
| Speech-to-text | **OpenAI Whisper API** (`whisper-1`) | `VoiceService.swift`; transcript saved to `Attachment.transcript` |
| Camera / photos | **PhotosUI** + `PHPicker` | EXIF extraction (aperture, shutter, ISO, focal length, GPS, timestamp); originals saved, thumbnails for UI |
| Location | **CoreLocation** + reverse geocoding | `LocationService.swift` |
| Weather | **OpenWeatherMap API** (free tier) | 10-min cache, `zh_cn` locale (`WeatherService.swift`) |
| Fonts | Space Grotesk / Inter / JetBrains Mono (TTF in bundle) | Registered via `DSFonts.registerAll()` at app launch |

### AI Compilation Engine

| Feature | Choice | Notes |
|---|---|---|
| Provider | **Aliyun DashScope** (OpenAI-compatible) | `CompilationService.swift`, model `qwen3.5-plus`, base URL `https://dashscope.aliyuncs.com/compatible-mode/v1` |
| API key | `Config/GeneratedSecrets.swift` (auto-generated from env, not committed) | Never hardcode in source |
| Schedule | **BGTaskScheduler** (`BGAppRefreshTask`) | Identifier `com.daypage.daily-compilation`, 02:00 local daily, with backfill + local notification (`BackgroundCompilationService.swift`) |
| Input | Text only — no raw audio / image bytes sent | ~2k–5k tokens per day for 20 memos |

## Project Structure

```
DayPage/
  App/              RootView, DayPageApp, Fonts, Typography
  Features/
    Today/          TodayView + TodayViewModel (268 lines)
    Archive/        ArchiveView (655 lines, calendar + list)
    Graph/          GraphView (18-line placeholder — Post-MVP, see PRD NG-3)
  Models/           Memo, Attachment, YAML parser
  Services/         RawStorage, Location, Weather, Photo, Voice, Compilation, BackgroundCompilation
  Config/           GeneratedSecrets (gitignored)
```

**Pipeline**: Today (raw input) → AI compilation → Daily Page (structured diary) → Entity Pages → Graph (Post-MVP knowledge network).

## Coding Conventions

- SwiftUI views: value types; extract subviews when a `body` exceeds ~80 lines
- Services: `@MainActor final class`, singletons where shared state is required
- View models: `@MainActor final class: ObservableObject` with `@Published`
- `MARK: -` section comments for navigation
- No force-unwraps in production paths; prefer `guard let` / `throws`
- No external dependencies without discussion — prefer Apple frameworks
- For design-related issues, they should be deeply designed and discussed clearly with me. Then, submit a GitHub issue first. Use the appropriate branch to solve this issue. Finally, after testing and verification, create a PR. Remember to link this issue according to the PR guidelines.

## UI Design

Design assets have been removed. **Use the current source code as the authoritative reference for UI design** — read `DayPage/App/RootView.swift`, `DayPage/Features/Today/TodayView.swift`, etc. directly.

- Navigation: left sidebar drawer (`RootView.swift`), no bottom TabBar
- For new design decisions, discuss with the user first, then open a GitHub issue, implement on a branch, and PR

Graph Tab has **no design** (Post-MVP, PRD NG-3) — keep the placeholder.

## Testing

No test target exists yet. When adding tests, create a `DayPageTests` target using **Swift Testing** (iOS 16+ supports it via the `Testing` package on Xcode 16+) or XCTest if the project stays on older Xcode.

**Default simulator**: use **iPhone 17** for all builds, runs, and UI verification (e.g. `xcodebuild -scheme DayPage -destination 'platform=iOS Simulator,name=iPhone 17'`).

**Simulator launch**: always start the Simulator in the background to avoid blocking the terminal session — use `open -a Simulator &` or run `xcodebuild` with `run_in_background: true`. Never let the Simulator occupy the foreground terminal.

Before marking any task complete:
1. Build the `DayPage` scheme (`xcodebuild -scheme DayPage build`)
2. Run any existing tests
3. For storage-related changes, inspect the actual `.md` file written under `vault/raw/` (use `get_app_container` to locate the sandbox) and verify YAML front-matter + Markdown structure
4. For UI changes, launch the app in Simulator (iPhone 17) and verify visually — SwiftUI preview alone is not sufficient

## Skill routing

When the user's request matches an available skill, ALWAYS invoke it using the Skill
tool as your FIRST action. Do NOT answer directly, do NOT use other tools first.
The skill has specialized workflows that produce better results than ad-hoc answers.

Key routing rules:
- Product ideas, "is this worth building", brainstorming → invoke office-hours
- Bugs, errors, "why is this broken", 500 errors → invoke investigate
- Ship, deploy, push, create PR → invoke ship
- QA, test the site, find bugs → invoke qa
- Code review, check my diff → invoke review
- Update docs after shipping → invoke document-release
- Weekly retro → invoke retro
- Design system, brand → invoke design-consultation
- Visual audit, design polish → invoke design-review
- Architecture review → invoke plan-eng-review
- Save progress, checkpoint, resume → invoke checkpoint
- Code quality, health check → invoke health
