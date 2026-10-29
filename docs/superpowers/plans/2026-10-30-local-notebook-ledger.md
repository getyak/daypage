# GET-326 implementation ledger

- User confirmed iOS first; no changes to Web, Android, macOS or Watch product behavior.
- Source archive release published and read back at archive/cloud-2026-10-30, pointing to 4cb0fced8265809648f1b0d952b86bc8a111b8c7.
- Linear GET-326 and GitHub issue #942 linked. Existing task worktree is isolated; historical worktrees untouched.
- Independent builder check added explicit iCloud Vault copy import, unknown-header preservation, origin-bound keys and untrusted note context.
- Ruling: use a separate iOS project rather than rewiring the legacy project. Evidence: Xcode still resolved globally referenced cloud packages for other targets. The old project was restored byte-for-byte; the new project references DayPageCore only.
- Figma Starter allows three pages; place scoped editable frames beside existing screens instead of adding a page. SF Pro cloud rendering was invisible, so Figma uses verified Noto CJK fonts; native app uses existing platform/reading fonts.
- Initial core contracts were run red, then 20 tests passed. Independent review found chat editor revision reset, reserved-separator encoding, HTTP numeric-domain bypass and malformed import publication. Added red regressions; all 25 core tests passed after fixes, including nested exported-import restoration.
- First iOS compilation found an error-shadowing assignment and an oversized SwiftUI expression. Corrected the receiver and split the chat view into context/messages/composer subviews. Runtime verification follows successful rebuild.
- No real model request, user key, real Vault, cloud database or TestFlight upload has been used.
- Latest core suite: 29/29. Latest Primary iPhone UI suite: 6/6, including explicit anonymous loopback chat. An unsigned Simulator cannot establish signed-device Keychain acceptance; anonymous mode now skips Keychain entirely while credential mode refuses missing keys.
- File Sharing coordination regression reproduced a lost-update failure between two store instances. Full NSFileCoordinator transaction coordination fixed it; 80 parallel appends passed.
- QA reset is now confined to an explicit task session subfolder and separate preference suite, in addition to the isolated Debug bundle.
- Compact follow-up was refused by the device-session safety check because Primary was already booted before this task. No borrowed device was shut down. Record this as an unverified secondary surface, not a passed gate.
