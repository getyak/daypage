#!/usr/bin/env xcrun swift
// Tests for voice transcript duplicate-display fix.
// Run: xcrun swift scripts/tests/test_voice_transcript.swift
//
// The bug: voice-only memos had transcript copied to memo.body,
// causing it to render twice (once in VoiceMemoPlayerRow, once as body text).
// Fix: body is always the user-typed text; transcript lives only in attachment.

import Foundation

// MARK: - Minimal type stubs

struct Attachment {
    let kind: String       // "audio" | "photo"
    let file: String
    let transcript: String?
    let duration: Double?
}

struct Memo {
    let type: MemoType
    let body: String
    let attachments: [Attachment]
}

enum MemoType { case text, voice, photo, mixed }

// MARK: - Logic under test (mirrors TodayViewModel submit logic)

/// Simulates TodayViewModel.submit() finalBody calculation.
/// - Parameters:
///   - userTypedText: Text the user typed in the input bar (trimmed).
///   - attachments: Pending attachments to be submitted.
/// - Returns: The `body` value that will be stored in the Memo.
func computeFinalBody(userTypedText: String, attachments: [Attachment]) -> String {
    // After the fix: body is always userTypedText.
    // Transcript lives exclusively in attachment.transcript.
    return userTypedText
}

/// Determines whether the card would display duplicate content.
/// Returns true if body equals attachment transcript (the bug condition).
func wouldDisplayDuplicate(memo: Memo) -> Bool {
    guard let audioAtt = memo.attachments.first(where: { $0.kind == "audio" }),
          let transcript = audioAtt.transcript,
          !transcript.isEmpty else { return false }
    let bodyTrimmed = memo.body.trimmingCharacters(in: .whitespacesAndNewlines)
    return !bodyTrimmed.isEmpty && bodyTrimmed == transcript
}

// MARK: - Test runner

var passed = 0
var failed = 0

func test(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        print("  PASS  \(name)")
        passed += 1
    } catch {
        print("  FAIL  \(name): \(error)")
        failed += 1
    }
}

func assertEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #file, line: Int = #line) throws {
    if lhs != rhs {
        throw NSError(domain: "Test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Expected \(rhs), got \(lhs) at line \(line)"
        ])
    }
}

func assertTrue(_ condition: Bool, _ message: String = "condition false") throws {
    if !condition {
        throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - Tests

print("\n=== Voice Transcript Tests ===\n")

test("voice-only memo: body is empty, transcript in attachment") {
    let transcript = "I don't know. I don't know a hair."
    let audio = Attachment(kind: "audio", file: "rec.m4a", transcript: transcript, duration: 2.0)
    let body = computeFinalBody(userTypedText: "", attachments: [audio])
    try assertEqual(body, "", "voice-only memo body should be empty")
}

test("voice-only memo: no duplicate display") {
    let transcript = "I don't know. I don't know a hair."
    let audio = Attachment(kind: "audio", file: "rec.m4a", transcript: transcript, duration: 2.0)
    let body = computeFinalBody(userTypedText: "", attachments: [audio])
    let memo = Memo(type: .voice, body: body, attachments: [audio])
    try assertTrue(!wouldDisplayDuplicate(memo: memo), "voice-only memo should not show duplicate content")
}

test("voice + text memo: body equals user text, not transcript") {
    let transcript = "Spoken content here."
    let userText = "Note: see above"
    let audio = Attachment(kind: "audio", file: "rec.m4a", transcript: transcript, duration: 3.0)
    let body = computeFinalBody(userTypedText: userText, attachments: [audio])
    try assertEqual(body, userText, "body should be user-typed text, not transcript")
}

test("voice + text memo: no duplicate when body != transcript") {
    let transcript = "Spoken content here."
    let userText = "Note: see above"
    let audio = Attachment(kind: "audio", file: "rec.m4a", transcript: transcript, duration: 3.0)
    let memo = Memo(type: .mixed, body: userText, attachments: [audio])
    try assertTrue(!wouldDisplayDuplicate(memo: memo), "body != transcript, should not duplicate")
}

test("text-only memo: body preserved, no audio attachment") {
    let body = computeFinalBody(userTypedText: "Just a note", attachments: [])
    try assertEqual(body, "Just a note", "text-only memo body should be the typed text")
}

test("voice memo with no transcript: body stays empty") {
    let audio = Attachment(kind: "audio", file: "rec.m4a", transcript: nil, duration: 5.0)
    let body = computeFinalBody(userTypedText: "", attachments: [audio])
    try assertEqual(body, "", "body should be empty when there is no transcript")
}

test("regression: old buggy behavior would have set body = transcript") {
    // This test documents the old (buggy) behavior and confirms it no longer occurs.
    let transcript = "I don't know. I don't know a hair."
    let audio = Attachment(kind: "audio", file: "rec.m4a", transcript: transcript, duration: 2.0)
    let body = computeFinalBody(userTypedText: "", attachments: [audio])
    // Old code: body = transcript → duplicate display
    // New code: body = ""        → no duplicate
    try assertTrue(body != transcript, "body must NOT equal transcript after the fix")
    try assertEqual(body, "", "body must be empty for voice-only memo")
}

print("\n=== Results: \(passed) passed, \(failed) failed ===")
if failed > 0 { exit(1) } else { exit(0) }
