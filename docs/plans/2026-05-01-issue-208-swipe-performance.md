# Issue #208 — Optimize Swipe Gesture Smoothness for Voice/Image Cards

> **For Hermes:** Delegate implementation tasks to Claude Code (`claude -p`) with full file context.

**Goal:** Eliminate frame drops and gesture latency when swiping voice/photo memo cards, making swipe feel as responsive as native OS gestures.

**Architecture:** Three-phase optimization: (1) move heavy work off the main thread that blocks gesture frames, (2) eliminate gesture recognition conflicts between PressableCardModifier and SwipeableMemoCard, (3) reduce per-frame layout computation inside swiped cards.

**Tech Stack:** SwiftUI, AVFoundation, CGImageSource, iOS 16.0+

---

## Root Cause Analysis

When a voice/photo memo card is swiped, SwiftUI's DragGesture `.updating()` fires at display refresh rate (60-120 Hz). Each frame triggers body re-evaluation of the subtree. Voice/image cards have heavyweight subviews that choke this hot path:

| Culprit | File:Line | Impact |
|---------|-----------|--------|
| `loadThumbnailAsync` runs on `@MainActor`, does `Data(contentsOf:)` synchronously | MemoCardView.swift:884-897 | Blocks main thread, drops frames during swipe |
| `PressableCardModifier` uses `LongPressGesture(minDuration: 0.01, maxDistance: 10)` that competes with parent DragGesture | Interactions.swift:24 | ~10ms hit-testing latency on initial touch |
| `VoiceMemoPlayerRow` has `GeometryReader` + 30-waveform-bars recomputed every frame | MemoCardView.swift:586-597 | Per-frame layout pass for 30 rectangles |
| SwipeableMemoCard offset changes force full subtree layout on every drag frame | SwipeableMemoCard.swift:62 | Heavy subviews re-layout at 120Hz |

---

## Phase 1: Main Thread Deblocking

### Task 1: Move thumbnail loading off @MainActor

**Objective:** Photo thumbnail data loading (`Data(contentsOf:)`, `CGImageSourceCreateThumbnailAtIndex`) must run off the main thread so it doesn't block swipe gesture frames.

**Files:**
- Modify: `DayPage/Features/Today/MemoCardView.swift:843-898` (PhotoThumbnailView + loadThumbnailAsync)

**Step 1: Rewrite `loadThumbnailAsync` to run off main thread**

Replace the current `@MainActor` function with a non-isolated async function that does the heavy IO elsewhere:

```swift
// Current (MemoCardView.swift:883-897)
@MainActor
private func loadThumbnailAsync(from fileURL: URL) async -> UIImage? {
    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    ...
    return UIImage(data: data)
}

// New — runs IO off main thread, only UI update on MainActor
private func loadThumbnailAsync(from fileURL: URL) async -> UIImage? {
    let url = fileURL  // capture local copy
    return await Task.detached(priority: .userInitiated) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: 600
        ]
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) {
            return UIImage(cgImage: cgThumb)
        }
        return UIImage(data: data)
    }.value
}
```

**Step 2: Also fix the synchronous `loadThumbnail` in MemoCardView (line 351-364)**

This is also called synchronously from the main thread for location card thumbnails:

```swift
// Current (MemoCardView.swift:351-364 — synchronous on main thread)
private func loadThumbnail(from fileURL: URL) -> UIImage? {
    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    ...
}
```

Replace with async version on `@State`:

```swift
// Add to MemoCardView
@State private var locationThumbnail: UIImage?

// Replace the synchronous call in locationCard with .task
.task(id: memo.id) {
    locationThumbnail = await loadThumbnailAsync(from: fileURL)
}
```

**Verification:**
- Code compiles: `xcodebuild -scheme DayPage build`
- Thumbnails still appear correctly for photo cards
- No "Modifying state during view update" warnings

---

### Task 2: Pre-compute VoiceMemoPlayerRow waveform heights

**Objective:** Eliminate per-frame bit-shift computation of 30 waveform bar heights inside `GeometryReader` during swipe drag.

**Files:**
- Modify: `DayPage/Features/Today/MemoCardView.swift:558-699` (VoiceMemoPlayerRow)

**Step 1: Cache waveform heights as a constant array**

```swift
// Current (MemoCardView.swift:636-647)
private func waveformBars(count: Int, color: Color) -> some View {
    let seed = abs(fileURL.hashValue)
    return HStack(spacing: 2) {
        ForEach(0..<count, id: \.self) { i in
            let h = CGFloat(4 + ((seed >> i) & 0x1F) % 24)
            ...
        }
    }
}

// New — pre-compute heights once
private var waveformHeights: [CGFloat] {
    let seed = abs(fileURL.hashValue)
    return (0..<30).map { i in
        CGFloat(4 + ((seed >> i) & 0x1F) % 24)
    }
}

private func waveformBars(count: Int, color: Color) -> some View {
    HStack(spacing: 2) {
        ForEach(Array(waveformHeights.prefix(count).enumerated()), id: \.offset) { _, h in
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 3, height: h)
        }
    }
}
```

**Step 2: Replace `GeometryReader` with simpler layout**

The `GeometryReader` + clipped progress overlay forces a layout pass every frame. Replace with a fixed-width approach:

```swift
// Remove GeometryReader; use fixed frame + overlay clipping by playbackProgress
// The waveform stays static width; only the progress color changes
HStack(spacing: 12) {
    // Play/Pause button (unchanged)
    ...

    // Waveform — single ZStack with progress clipping
    ZStack(alignment: .leading) {
        waveformBars(count: 30, color: DSColor.outlineVariant)
        waveformBars(count: 30, color: DSColor.primary)
            .mask(alignment: .leading) {
                Rectangle()
                    .frame(width: playbackProgress > 0 ? nil : 0)
                    .animation(.linear(duration: 0.1), value: playbackProgress)
            }
    }
    .frame(height: 28)
    ...
}
```

Note: The mask approach is lighter than `GeometryReader + .clipped()` because it avoids measuring the container on every frame.

**Verification:**
- Code compiles
- Waveform bars render identically (deterministic from fileURL hash)
- Playback progress overlay still works

---

## Phase 2: Gesture Conflict Resolution

### Task 3: Eliminate PressableCardModifier gesture competition during swipe

**Objective:** The `PressableCardModifier`'s `onLongPressGesture(minimumDuration: 0.01, maximumDistance: 10)` still creates a ~10ms gesture recognition window where the parent DragGesture can't start. Remove this conflict.

**Files:**
- Modify: `DayPage/DesignSystem/Interactions.swift:1-45` (PressableCardModifier)
- Modify: `DayPage/Features/Today/SwipeableMemoCard.swift:18-170` (SwipeableMemoCard)

**Step 1: Make PressableCardModifier swipe-aware**

Add a `minimumDistance: 0` + shorter `minimumDuration` so the press feedback starts instantly without delaying the parent DragGesture:

```swift
// Current (Interactions.swift:24)
.onLongPressGesture(minimumDuration: 0.01, maximumDistance: 10) {
    // no-op
} onPressingChanged: { pressing in ... }

// New — immediate press, no gesture competition with parent DragGesture
.onLongPressGesture(minimumDuration: 0.0, maximumDistance: .infinity) {
    // no-op — tap is handled by .onTapGesture in MemoCardView
} onPressingChanged: { pressing in
    if pressing {
        if !isPressed {
            isPressed = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    } else {
        isPressed = false
    }
}
```

Key change: `minimumDuration: 0.0` means the `onPressingChanged` fires immediately on touch-down with no delay. `maximumDistance: .infinity` removes the distance constraint entirely, preventing the LongPressGesture from competing with the DragGesture.

**Step 2: Ensure press state resets on swipe cancellation**

The `onPressingChanged` with `pressing = false` callback already handles this — when the parent DragGesture takes over, the LongPressGesture is cancelled and `pressingChanged` fires `false`.

**Verification:**
- Code compiles
- Press-down visual feedback (scale 0.98 + dark overlay) appears instantly on touch
- Swiping the card cancels the press visual
- Tap-to-expand still works on memo cards
- No gesture conflicts (both press and swipe work)

---

### Task 4: Add `.drawingGroup()` to offload swipe rendering

**Objective:** Offload the card's compositing during drag to a Metal offscreen buffer, preventing SwiftUI from re-compositing every subview on every offset change frame.

**Files:**
- Modify: `DayPage/Features/Today/SwipeableMemoCard.swift:50-67` (body)

**Step 1: Apply `.drawingGroup()`**

```swift
// In SwipeableMemoCard.body, wrap the card content:
MemoCardView(memo: memo, onDelete: onDelete)
    .offset(x: currentOffset)
    .drawingGroup()  // Rasterizes the card into a Metal texture
    .highPriorityGesture(swipeGesture)
    .onTapGesture { if revealedSide != nil { snapClose() } }
```

Note: Apply `.drawingGroup()` BEFORE the gesture modifier so gesture coordinates are unaffected.

**Step 2: Remove `.drawingGroup()` when not swiping to keep text sharp**

```swift
// Only rasterize during active drag; keep native rendering when idle
MemoCardView(memo: memo, onDelete: onDelete)
    .offset(x: currentOffset)
    .drawingGroup(opaque: false, colorMode: .extendedLinear)  // Linear for correct blending
    .highPriorityGesture(swipeGesture)
```

If `.drawingGroup()` causes text blur at rest (since it rasterizes to a bitmap), scope it conditionally:

```swift
@State private var isDragging: Bool = false

// In swipeGesture .updating(), add isDragging = true
// In swipeGesture .onEnded(), reset isDragging = false
// Then:
.drawingGroup(opaque: false, colorMode: .extendedLinear)
.compositingGroup()  // Fallback: lighter compositing boundary
```

**Verification:**
- Code compiles
- Swipe feels noticeably smoother on voice/photo cards
- Text readability at rest is unaffected
- No visual artifacts (clipping, color shifts)

---

## Phase 3: List Transitition Optimization

### Task 5: Stabilize LazyVStack identity during memo insertion

**Objective:** When a new voice/photo memo is inserted, the `.transition(.move(edge: .bottom))` animation causes the entire LazyVStack to re-layout, competing with any in-flight swipe gesture.

**Files:**
- Modify: `DayPage/Features/Today/TodayView.swift:202-218` (ForEach in timeline)

**Step 1: Add stable `.id()` to ForEach items**

```swift
// Current (TodayView.swift:202-203)
ForEach(Array(viewModel.memos.enumerated()), id: \.element.id) { idx, memo in

// Already has stable id — good.
// Add explicit animation scope to prevent implicit animation propagation:
ForEach(Array(viewModel.memos.enumerated()), id: \.element.id) { idx, memo in
    TimelineRow(...)
        .padding(...)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: viewModel.memos.count)
}
```

**Step 2: Reduce animation contention by disabling implicit animations during swipe**

In `SwipeableMemoCard`, wrap snap animations in explicit `withAnimation` and prevent implicit propagation:

```swift
// The snapOpen/snapClose already use explicit withAnimation — good.
// Add: disable default animation on the card's offset
.offset(x: currentOffset)
    .animation(.interactiveSpring(), value: currentOffset)
```

Wait — this would animate every drag frame. Better approach: only animate the snap, not the drag:

```swift
.offset(x: currentOffset) // No animation on offset — drag is 1:1
// snapOpen/snapClose use explicit withAnimation — the @State change
// triggers animated transition to settled position. This is correct.
```

The current code is already correct here — the offset is driven by derived `currentOffset` which includes the gesture state drag delta. The `withAnimation` in `snapOpen`/`snapClose` only fires when the gesture ends. 

**Verification:**
- Code compiles
- New memo insertion animation is smooth
- Swiping a card while a new memo is animating in doesn't cause stutter
- No regression: pin/unpin animations still work

---

## Execution Order

1. **Task 1** — Move thumbnail loading off @MainActor (highest impact)
2. **Task 2** — Pre-compute waveform heights
3. **Task 3** — Fix gesture competition
4. **Task 4** — Add drawingGroup
5. **Task 5** — Stabilize list transitions

Each task is independent and can be committed separately.

---

## Verification Checklist

- [ ] `xcodebuild -scheme DayPage build` succeeds
- [ ] CI (ci.yml) passes — unit tests + build: `gh workflow run ci.yml --repo getyak/daypage`
- [ ] Voice memo cards: swipe left/right feels snappy, no frame drops
- [ ] Photo memo cards: swipe left/right feels snappy, no frame drops  
- [ ] Text memo cards: no regression (still snappy)
- [ ] Press-down visual feedback still works on all card types
- [ ] Tap-to-expand long text still works
- [ ] Pin/unpin still works
- [ ] Delete still works
- [ ] iCloud thumbnails still load correctly
