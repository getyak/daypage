```markdown
# daypage Development Patterns

> Auto-generated skill from repository analysis

## Overview
This skill teaches the core development patterns and conventions used in the `daypage` Swift codebase. You'll learn about file naming, import/export styles, commit message conventions, and how to structure and run tests. This guide is designed to help you quickly onboard and contribute effectively to the project.

## Coding Conventions

### File Naming
- Use **PascalCase** for all file names.
  - Example: `DayPageView.swift`, `UserManager.swift`

### Import Style
- Use **relative imports** to reference files within the project.
  - Example:
    ```swift
    import "../Models/User"
    ```

### Export Style
- Use **named exports** to expose specific types, functions, or classes.
  - Example:
    ```swift
    public struct DayPage { ... }
    ```

### Commit Messages
- Follow the **Conventional Commits** format.
- Use prefixes such as `chore`.
- Keep commit messages concise, around 68 characters.
  - Example:
    ```
    chore: update dependencies and fix minor warnings in UserManager
    ```

## Workflows

### Committing Changes
**Trigger:** When you are ready to commit your code changes.
**Command:** `/commit-changes`

1. Stage your changes:
    ```
    git add .
    ```
2. Write a commit message using the conventional format:
    ```
    git commit -m "chore: describe your change here"
    ```
3. Push your changes:
    ```
    git push
    ```

### Adding a New Swift File
**Trigger:** When you need to add a new component or module.
**Command:** `/add-swift-file`

1. Name your file using PascalCase, e.g., `NewFeature.swift`.
2. Use relative imports for dependencies.
    ```swift
    import "../Models/Dependency"
    ```
3. Export your types or functions using named exports.
    ```swift
    public struct NewFeature { ... }
    ```

### Writing Tests
**Trigger:** When you add new functionality or fix bugs.
**Command:** `/write-test`

1. Create a test file matching the pattern `*.test.*`, e.g., `DayPage.test.swift`.
2. Place your test cases in this file.
3. Use the project's preferred (unknown) testing framework.

## Testing Patterns

- Test files follow the `*.test.*` naming convention, such as `UserManager.test.swift`.
- Place test files alongside the code they test or in a dedicated test directory.
- The specific testing framework is not detected; follow existing patterns in the repository.

**Example:**
```swift
// DayPage.test.swift

import "../DayPage"

func testDayPageInitialization() {
    // Test implementation here
}
```

## Commands
| Command           | Purpose                                      |
|-------------------|----------------------------------------------|
| /commit-changes   | Commit your staged changes using conventions |
| /add-swift-file   | Add a new Swift file following conventions   |
| /write-test       | Create a new test file for your code         |
```