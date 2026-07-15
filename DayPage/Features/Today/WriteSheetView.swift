import SwiftUI
import PhotosUI
import CoreLocation
import DayPageModels
import DayPageServices

// MARK: - WriteSheetView
//
// Elegant text composer presented as a bottom sheet — the v8 「日式美术馆」 write
// surface (composer.jsx:183-345, web WriteSheet.tsx). It slides up from the
// Today dock's text affordance and routes its saved text through the SAME
// persistence path the inline composer uses (submitCombinedMemo via draftText).
//
// Layout, top → bottom (design composer.jsx:222-341):
//   • drag handle — 36×4 capsule, centered
//   • header — Fraunces weekday (18pt) + JetBrains Mono "MAY 28 · 15:47" stamp
//     (real now), trailing close button
//   • textarea — 18pt serif, italic placeholder「此刻在想什么？」, accent caret,
//     auto-grow (lineLimit 3…10)
//   • footer rail — camera/photo/location(-name chip) icons · spacer · mono
//     counter · trailing action: mic when empty, ghost「取消」+ amber ↑ send
//     circle once the draft is dirty
//   • mono caption「SAVED TO  VAULT / YYYY-MM-DD.md」(folds while keyboard up)
//
// Interaction model (vNext 2026-07): "close" is two different verbs.
//   收起(keep) — scrim tap / swipe-down: silent, the draft survives in the
//   parent's SceneStorage and resurfaces in the dock composer.
//   放弃(destroy) — ✕ or ghost cancel: inline confirm bar, then onDiscard.
//   Dirty = text OR attachments; an auto-attached location never counts.
//
// Entrance: sheet-up via timingCurve(.2,.8,.2,1) ~320ms — mirrors
// composer.jsx:219 `sheet-up 320ms cubic-bezier(.2,.8,.2,1)`.

struct WriteSheetView: View {

    /// Live draft text — bound to the same `draftText` the inline composer uses
    /// so save flows through the existing `submitCombinedMemo` path.
    @Binding var text: String
    /// Save — commits the current text via the parent's existing persistence.
    let onSave: () -> Void
    /// Close — hide the sheet. The draft is NOT touched: `text` is the parent's
    /// SceneStorage-backed draft, so a plain close means "collapse and keep".
    let onClose: () -> Void
    /// Discard — the user explicitly abandoned the draft (✕ / cancel, then the
    /// inline confirm). The parent clears the draft text and staged attachments.
    var onDiscard: () -> Void = {}
    /// Location attached to the memo being written; nil when none.
    var pendingLocation: Memo.Location? = nil
    /// True while a location fetch is in flight.
    var isLocating: Bool = false
    /// Toggle location: fetch if nil, clear if already set.
    var onToggleLocation: () -> Void = {}

    /// CoreLocation authorization. Used to decide whether to silently
    /// pre-fetch a location on open (only when already authorized — never
    /// triggers the system permission alert on first open).
    var locationAuthStatus: CLAuthorizationStatus = .notDetermined
    /// Pending attachments (photo / voice / file). Shown as chips above the
    /// text area when non-empty.
    var pendingAttachments: [PendingAttachment] = []
    /// Remove a pending attachment by id (xmark button on each chip).
    var onRemoveAttachment: (String) -> Void = { _ in }
    /// Photo library picker tile.
    var onAddPhoto: ([PhotosPickerItem]) -> Void = { _ in }
    /// In-app camera capture (uses CameraPickerView via the parent VM).
    var onCapturePhoto: () -> Void = {}
    /// Press-to-talk: long-press records, release sends a voice memo.
    var onPressToTalkSend: (VoiceRecordingResult) -> Void = { _ in }
    /// Press-to-talk: short-tap opens the persistent voice recorder.
    var onStartVoiceRecording: () -> Void = {}
    /// Press-to-talk: release-transcribe inserts transcript into the draft.
    var onPressToTalkTranscribe: (String) -> Void = { _ in }
    /// Submit the composed memo when text + attachments are flushed inline
    /// (used by the send-arrow when there's text or attachments).
    var onSubmit: () -> Void = {}

    @FocusState private var isFocused: Bool
    @State private var appeared: Bool = false
    @State private var lastMilestone: Int = 0
    /// PhotosPicker plumbing — flipped by the photo rail icon.
    @State private var showPhotosPicker: Bool = false
    @State private var photosPickerItems: [PhotosPickerItem] = []
    /// Press-to-talk phase mirrored from PressToTalkButton for the overlay.
    @State private var pressToTalkPhase: PressToTalkPhase = .idle
    /// One-shot guard so the auto-location fetch only fires on first open.
    @State private var didAutoFetchLocation: Bool = false
    @StateObject private var voiceService = VoiceService.shared
    /// Cached counts. These were computed properties that re-ran an O(n)
    /// full-text scan on EVERY SwiftUI body re-render — and a single keystroke
    /// triggers several re-renders. Recomputing only inside `onChange(of: text)`
    /// removes the per-keystroke O(n) cost that compounds into typing lag on
    /// long drafts. All downstream readers keep using `wordCount`/`charCount`.
    @State private var cachedWordCount: Int = 0
    @State private var cachedCharCount: Int = 0
    /// Sheet drag offset. `resetTransaction` springs the offset back to rest
    /// when the gesture ends below the dismiss threshold — `@GestureState`
    /// auto-resets to 0 on release, and without a transaction that reset snaps
    /// instantly (the old empty `withAnimation(Motion.spring){}` couldn't
    /// animate the framework's own reset). Near-instant under Reduce Motion.
    @GestureState(resetTransaction: Transaction(animation: Motion.respectReduceMotion(Motion.spring)))
    private var dragOffset: CGFloat = 0
    @State private var committedClose: Bool = false
    @State private var saveReadyPulse: Bool = false
    @State private var confirmingDiscard: Bool = false
    /// Mirrors the system keyboard. While it's up, vertical space is scarce:
    /// the bottom padding tightens (the sheet sits flush on the keyboard, no
    /// home-indicator inset needed) and the SAVED TO VAULT caption folds away.
    @State private var keyboardVisible: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppSettings.Keys.writeSheetRailHintShown) private var railHintShown: Bool = false
    /// Snapshot taken at open time so the hint stays visible for the whole first session.
    @State private var showRailHint: Bool = false

    /// Sheet-up easing — composer.jsx:219 `cubic-bezier(.2,.8,.2,1)` @ 320ms.
    private static let sheetUp = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.32)

    /// CJK-aware word count: each CJK/Hiragana/Katakana ideograph = 1 word;
    /// consecutive non-CJK non-whitespace scalars = 1 Latin word per run.
    /// Reads the cached count (recomputed once per text change, not per render).
    private var wordCount: Int { cachedWordCount }

    /// Recompute cached counts. Called once when `text` actually changes.
    private func recomputeCounts() {
        cachedWordCount = Self.wordCount(in: text)
        cachedCharCount = text.count
    }

    static func wordCount(in text: String) -> Int {
        var count = 0
        var inLatinRun = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF,  // CJK Unified Ideographs
                 0x3400...0x4DBF,  // CJK Extension A
                 0x3040...0x309F,  // Hiragana
                 0x30A0...0x30FF:  // Katakana
                if inLatinRun { inLatinRun = false }
                count += 1
            case _ where scalar.properties.isWhitespace:
                inLatinRun = false
            default:
                if !inLatinRun {
                    inLatinRun = true
                    count += 1
                }
            }
        }
        return count
    }

    private var charCount: Int { cachedCharCount }

    private var readingMinutes: Int {
        max(1, Int(ceil(Double(wordCount) / 200.0)))
    }

    private var showReadingTime: Bool { wordCount >= 50 }

    /// True when the user has authored content: text or attachments. Location
    /// deliberately does NOT count — it is auto-attached ambient metadata, not
    /// something the user wrote. Counting it made every fresh sheet "dirty":
    /// the mic never appeared and closing an empty sheet raised the discard
    /// prompt. This single predicate drives both the send button and the
    /// discard-confirmation gate.
    private var isDirty: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || !pendingAttachments.isEmpty
    }

    /// Counter color: interpolates from fgMuted → accentAmber as wordCount grows from 100…200.
    private var wordCountColor: Color {
        guard !reduceMotion, wordCount > 0 else {
            return wordCount > 0 ? DSColor.inkMuted : DSColor.inkSubtle
        }
        guard wordCount > 100 else { return DSColor.inkMuted }
        let t = CGFloat(min(wordCount - 100, 100)) / 100.0
        return Self.lerpColor(from: DSColor.inkMuted, to: DSColor.accentOnBg, t: t)
    }

    private static func lerpColor(from a: Color, to b: Color, t: CGFloat) -> Color {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        UIColor(a).getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        UIColor(b).getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return Color(
            red: r1 + (r2 - r1) * t,
            green: g1 + (g2 - g1) * t,
            blue: b1 + (b2 - b1) * t,
            opacity: a1 + (a2 - a1) * t
        )
    }

    // MARK: - Date / time strings (museum-tag style)

    private static let weekdayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEEE"
        return f
    }()

    private static let stampFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMM d · HH:mm"
        return f
    }()

    /// Captured once so the stamp doesn't reshuffle while the sheet is open.
    private let now = Date()

    /// Full weekday, e.g. "Thursday" (design composer.jsx:236).
    private var weekday: String { Self.weekdayFmt.string(from: now) }

    /// Mono stamp "MAY 28 · 15:47" (design composer.jsx:239).
    private var stamp: String { Self.stampFmt.string(from: now).uppercased() }

    /// ISO date for the vault caption "YYYY-MM-DD" (design composer.jsx:340).
    private var isoDate: String { DateFormatters.isoDate.string(from: now) }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            // Backdrop scrim — composer.jsx:206-209 rgba(30,24,18,0.34).
            // Fades proportionally as the sheet is dragged down.
            DSTokens.Colors.recordingBg.opacity(0.34)
                .ignoresSafeArea()
                .opacity(appeared ? Double(max(CGFloat.zero, CGFloat(1) - dragOffset / CGFloat(400))) : 0)
                .onTapGesture { dismissKeepingDraft() }
                .accessibilityHidden(true)

            sheet
                .offset(y: (appeared ? 0 : sheetTravel) + (dragOffset < 0 ? dragOffset / 6 : dragOffset))
                .gesture(swipeToDismiss)
        }
        // Bleed the whole stack to the physical bottom edge so the sheet surface
        // is continuous with it (flomo-style panel). Anchoring inside the safe
        // area instead would float the sheet up and expose its bottom corners —
        // which are rounded on the assumption they sit off-screen.
        //
        // `.container` ONLY: the bare `.ignoresSafeArea(edges:)` default region
        // is `.all`, which also opts out of the KEYBOARD safe area — so when
        // the keyboard rose, the whole footer rail (camera/photo/location/send)
        // stayed pinned to the physical bottom, buried under the keyboard.
        // Ignoring just the container keeps SwiftUI's built-in keyboard
        // avoidance, which lifts the sheet on the system's own curve.
        .ignoresSafeArea(.container, edges: .bottom)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : Self.sheetUp, value: appeared)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: 0.25)) {
                keyboardVisible = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: 0.25)) {
                keyboardVisible = false
            }
        }
        // Recompute the cached word/char counts ONCE per real text change,
        // instead of on every body re-render. This is the single source of
        // truth for both counters and keeps typing off the O(n) scan path.
        .onChange(of: text) { _ in recomputeCounts() }
        .onAppear {
            appeared = true
            confirmingDiscard = false
            recomputeCounts()
            // Focus IMMEDIATELY so the system keyboard rises in-frame with
            // the sheet-up animation instead of trailing it by 80ms. The old
            // 80ms delay was there because a bare `isFocused = true` in the
            // same tick as `.onAppear` sometimes fired BEFORE the UITextField
            // was attached; scheduling it via `DispatchQueue.main.async` gives
            // SwiftUI one runloop cycle to attach the field, which is enough
            // in practice and removes the visible lag the user reported.
            DispatchQueue.main.async { isFocused = true }
            // Auto-embed location on first open when CoreLocation is already
            // authorized — silent UX, never raises the system permission
            // alert. Users who haven't granted access still see the grey
            // mappin and can tap to opt in explicitly.
            if !didAutoFetchLocation
                && pendingLocation == nil
                && !isLocating
                && (locationAuthStatus == .authorizedWhenInUse
                    || locationAuthStatus == .authorizedAlways)
            {
                didAutoFetchLocation = true
                onToggleLocation()
            }
        }
    }

    /// Off-screen travel distance for the sheet-up entrance.
    private var sheetTravel: CGFloat { reduceMotion ? 0 : 420 }

    /// Home-indicator inset of the active window — 0 on devices without one.
    /// The sheet bleeds through the bottom safe area, so it has to re-add this
    /// itself to keep the caption clear of the indicator.
    private var bottomSafeInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?
            .safeAreaInsets.bottom ?? 0
    }

    /// Swipe-down-to-dismiss gesture attached to the whole sheet.
    private var swipeToDismiss: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($dragOffset) { value, state, _ in
                state = value.translation.height
            }
            .onEnded { value in
                if value.translation.height > 120 || value.predictedEndTranslation.height > 240 {
                    dismissKeepingDraft()
                }
            }
    }

    // MARK: - Sheet

    private var sheet: some View {
        VStack(spacing: 0) {
            dragHandle
            header
            if !pendingAttachments.isEmpty {
                attachmentPreviewRow
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            textArea
            footerRail
            if showRailHint && pendingLocation == nil {
                railHintCaption
            }
            if confirmingDiscard {
                discardConfirmBar
                    .transition(.opacity)
            } else if !keyboardVisible {
                // The archival caption is a "quiet moment" flourish — while the
                // keyboard is up every point of height belongs to the draft.
                savedCaption
                    .transition(.opacity)
            }
        }
        .photosPicker(
            isPresented: $showPhotosPicker,
            selection: $photosPickerItems,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: photosPickerItems) { newItems in
            guard !newItems.isEmpty else { return }
            onAddPhoto(newItems)
            photosPickerItems = []
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : Motion.spring, value: confirmingDiscard)
        // Resting: 28pt of breathing room below the caption plus the
        // home-indicator inset the surface bleeds through. Keyboard up: the
        // sheet sits flush on the keyboard, so both allowances collapse to a
        // tight 12pt.
        .padding(.bottom, keyboardVisible ? 12 : 28 + bottomSafeInset)
        .frame(maxWidth: .infinity)
        .onAppear {
            // Capture first-visit before flipping the UserDefaults flag so
            // the hint renders during the current open (not just future ones).
            showRailHint = !railHintShown
            railHintShown = true
        }
        // Liquid Glass vNext (#769): route the sheet surface through the same
        // dual-track engine as the dock/composer instead of the hand-built
        // glassHi + ultraThinMaterial stack. iOS 26 → native `.glassEffect`,
        // iOS 16–25 → warm faux-glass fallback, Reduce Transparency → opaque
        // warm fill. The engine paints a full RoundedRectangle (bottom edge is
        // off-screen behind the safe area); the UnevenRoundedRectangle clip
        // below still reveals only the top corners so the sheet reads correctly.
        .dpGlass(.panel, in: RoundedRectangle(cornerRadius: DSTokens.Radii.sheet, style: .continuous))
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: DSTokens.Radii.sheet,
                topTrailingRadius: DSTokens.Radii.sheet,
                style: .continuous
            )
        )
        .overlay(alignment: .top) {
            // 0.5px top hairline (composer.jsx:217 borderTop var(--border-subtle)).
            Rectangle()
                .fill(DSColor.inkFaint)
                .frame(height: 0.5)
        }
        .shadow(color: DSTokens.Colors.recordingBg.opacity(0.32), radius: 30, x: 0, y: -16)
    }

    // MARK: - Drag handle (composer.jsx:222-225)

    private var dragHandle: some View {
        let progress = min(max(dragOffset, 0) / 120, 1.0)
        return Capsule()
            .fill(DSColor.inkSubtle.opacity(0.6 + 0.4 * progress))
            .frame(width: 36 + 8 * progress, height: 4)
            .scaleEffect(1 + 0.08 * progress)
            .padding(.top, 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(swipeDownGesture)
            .accessibilityHidden(true)
    }

    private var swipeDownGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($dragOffset) { value, state, _ in
                state = value.translation.height
                // Resign focus on the main thread so the keyboard collapses
                // alongside the sheet during the drag.
                DispatchQueue.main.async { isFocused = false }
            }
            .onEnded { value in
                let shouldDismiss = value.translation.height > 120
                    || value.predictedEndTranslation.height > 260
                if shouldDismiss {
                    dismissKeepingDraft()
                }
                // Below the threshold we do nothing here: `dragOffset` is a
                // @GestureState, so it auto-resets to 0 on release and springs
                // back via its `resetTransaction`. (The old empty
                // `withAnimation` blocks couldn't animate that reset anyway.)
            }
    }

    // MARK: - Header (composer.jsx:227-249)

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(weekday)
                    .font(DSFonts.serif(size: 18, weight: .semibold, relativeTo: .headline))
                    .tracking(-0.2)
                    .foregroundColor(DSColor.inkPrimary)

                Text(stamp)
                    .font(DSFonts.jetBrainsMono(size: 10, weight: .bold, relativeTo: .caption2))
                    .tracking(1.6)
                    .foregroundColor(DSColor.inkMuted)
            }

            Spacer()

            // Close button — 30pt sunken circle (composer.jsx:241-248).
            // Semantics: explicit CANCEL. Dirty drafts confirm inline first;
            // soft dismissal (keep draft) lives on the scrim / swipe-down.
            Button(action: attemptDiscard) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DSColor.inkMuted)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(DSColor.surfaceSunken))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("write.sheet.close", comment: "Close write sheet"))
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .contentShape(Rectangle())
        .gesture(swipeDownGesture)
    }

    // MARK: - Textarea (composer.jsx:255-276)

    private var textArea: some View {
        // 18pt serif body, accent caret, auto-grow (lineLimit 3…10 ≈ min 90 /
        // max 280pt of the design). The placeholder is italic serif at fgSubtle.
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(NSLocalizedString("write.sheet.placeholder", comment: "此刻在想什么？"))
                    .font(DSFonts.serif(size: 18, italic: true, relativeTo: .headline))
                    .foregroundColor(DSColor.inkSubtle.opacity(0.6))
                    .allowsHitTesting(false)
            }

            TextField("", text: $text, axis: .vertical)
                .font(DSFonts.serif(size: 18, relativeTo: .headline))
                .tracking(0.2)
                .lineSpacing(6) // ≈ lineHeight 1.7 on 18pt
                .foregroundColor(DSColor.inkPrimary)
                .tint(DSColor.accentOnBg)
                .lineLimit(3...10)
                .focused($isFocused)
                .accessibilityIdentifier("write-sheet-input")
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 18)
        .frame(minHeight: 90, alignment: .topLeading)
    }

    // MARK: - Footer rail (composer.jsx:282-330)

    private var footerRail: some View {
        HStack(spacing: 2) {
            cameraRailIcon
            photoRailIcon
            locationRailIcon
            // The decorative tag icon yields its 40pt once the trailing side
            // needs room for cancel + send (it is dead weight at 0.4 opacity;
            // the location name chip + counter must not get squeezed).
            if !isDirty {
                railIcon("tag", label: NSLocalizedString("write.sheet.icon.tag", comment: "标签"))
            }

            Spacer(minLength: 6)

            // Single counter — for CJK drafts the segmenter counts ~1 word per
            // character, so "10 个词 · 10 字符" said the same number twice
            // (FINDING-013). Show characters for CJK-dominant text, words for
            // latin text; milestones every 100 words either way.
            let wordsLabel = wordCount == 1
                ? NSLocalizedString("writesheet.count.words.one", comment: "1 word")
                : String(format: NSLocalizedString("writesheet.count.words.other", comment: "%d words"), wordCount)
            let isCJKDominant = charCount > 0 && wordCount * 10 >= charCount * 8
            let countLabel = isCJKDominant
                ? "\(charCount) \(NSLocalizedString("writesheet.count.chars", comment: "chars"))"
                : wordsLabel
            let readLabel = String(format: NSLocalizedString("writesheet.count.read", comment: "~%d min read"), readingMinutes)
            HStack(spacing: 0) {
                // Counter text updates instantly per keystroke — no per-character
                // numericText/spring (those stacked 0.35s animations under the
                // typing cadence and starved the main thread). monospacedDigit
                // keeps the digits from reflowing as they change.
                Text(countLabel)
                if showReadingTime {
                    Text(" · \(readLabel)")
                        .transition(.opacity)
                }
            }
            .font(DSType.mono10)
            .tracking(1.0)
            .textCase(.uppercase)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundColor(wordCountColor)
            // Only the reading-time chip's appear/disappear gets a soft tick.
            .animation(reduceMotion ? nil : Motion.countTick, value: showReadingTime)
            .padding(.trailing, 10)
            .accessibilityLabel(showReadingTime ? "\(countLabel), \(readLabel)" : countLabel)
            .onChange(of: wordCount) { newCount in
                let milestone = newCount / 100
                if milestone > lastMilestone {
                    lastMilestone = milestone
                    if newCount > 0 { Haptics.soft() }
                } else if milestone < lastMilestone {
                    lastMilestone = milestone
                }
            }

            // Trailing action: when the draft is empty, show a press-to-talk
            // mic (long-press = voice memo, short tap = open recorder). The
            // moment authored content exists, the same 38pt amber circle
            // swaps its symbol to ↑ send, and a quiet ghost "cancel" fades in
            // beside it — the only explicit discard affordance besides ✕.
            if isDirty {
                HStack(spacing: 8) {
                    cancelGhostButton
                    sendButton
                }
                .transition(.opacity)
            } else {
                writeSheetMicButton
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isDirty)
    }

    /// Camera capture — opens the in-app CameraPickerView via the parent VM.
    private var cameraRailIcon: some View {
        Button {
            Haptics.soft()
            onCapturePhoto()
        } label: {
            Image(systemName: "camera")
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(DSColor.inkMuted)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("write.sheet.icon.camera", comment: "拍照"))
    }

    /// Photo library — flips the local PhotosPicker flag.
    private var photoRailIcon: some View {
        Button {
            Haptics.soft()
            showPhotosPicker = true
        } label: {
            Image(systemName: "photo")
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(DSColor.inkMuted)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("write.sheet.icon.photo", comment: "相册"))
    }

    /// Empty-draft press-to-talk button. Short tap opens the persistent
    /// voice recorder; long-press records and sends a voice memo inline.
    /// Mirrors the dock's mic semantics so users keep one mental model.
    private var writeSheetMicButton: some View {
        PressToTalkButton(
            onPressStart: { Task { await voiceService.startRecording() } },
            onReleaseSend: handleMicReleaseSend,
            onReleaseCancel: { voiceService.cancelRecording() },
            onReleaseTranscribe: handleMicReleaseTranscribe,
            onPhaseChange: { pressToTalkPhase = $0 },
            onTapShortRelease: {
                Haptics.soft()
                onStartVoiceRecording()
            },
            size: 38,
            idleBackgroundColor: DSColor.amberAccent,
            idleIconColor: .white
        )
        .frame(width: 44, height: 38)
        .accessibilityLabel(NSLocalizedString("input.a11y.mic", comment: ""))
    }

    private func handleMicReleaseSend() {
        // Same send floor as the dock (#826): a sub-3s hold is an accidental
        // touch — discard it instead of shipping a meaningless clip. The two
        // press-to-talk surfaces must stay behaviorally identical or users
        // get a memo from one mic and silence from the other.
        if RecordingLimits.isBelowSendFloor(voiceService.elapsedSeconds) {
            Haptics.warningNotification()
            voiceService.cancelRecording()
            return
        }
        // Send path: audio is saved instantly, transcription runs in the
        // background via VoiceAttachmentQueue and patches the memo later.
        if let result = voiceService.stopAndSaveAudio() {
            onPressToTalkSend(result)
        }
    }

    private func handleMicReleaseTranscribe() {
        // Same floor as the send path — a sub-3s clip would burn a Whisper
        // call and return nothing useful (#826).
        if RecordingLimits.isBelowSendFloor(voiceService.elapsedSeconds) {
            Haptics.warningNotification()
            voiceService.cancelRecording()
            // The transcribe branch in PressToTalkButton.onEnded early-returns
            // past the unconditional `.idle` reset — without this the button
            // stays mounted in `.transcribing` until the next gesture.
            pressToTalkPhase = .idle
            return
        }
        Task {
            if let result = await voiceService.stopAndTranscribe(),
               let transcript = result.transcript,
               !transcript.isEmpty {
                onPressToTalkTranscribe(transcript)
            }
        }
    }

    /// Horizontal chip strip showing pending attachments (photos / voice /
    /// files) above the text area. Each chip has an inline xmark to remove.
    private var attachmentPreviewRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingAttachments) { att in
                    attachmentChip(att)
                }
            }
            .padding(.horizontal, 22)
            // Extra headroom on top so the photo-thumb remove badge (offset
            // -6pt past the tile corner) isn't clipped by the ScrollView.
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func attachmentChip(_ att: PendingAttachment) -> some View {
        // Photos render as real 52pt thumbnails (the PhotoPickerResult has
        // carried a ready-made `thumbnail` all along) — a filename chip like
        // "IMG_2043.jpg" says nothing about which picture it is. Voice and
        // file attachments keep the capsule: they have no visual body.
        if case .photo(let result) = att, let thumb = result.thumbnail {
            photoThumbChip(id: att.id, image: thumb)
        } else {
            capsuleChip(att)
        }
    }

    private func photoThumbChip(id: String, image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(DSColor.inkFaint, lineWidth: 0.5)
            )
            .overlay(alignment: .topTrailing) {
                Button {
                    Haptics.light()
                    onRemoveAttachment(id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        // Static ink over photo content — badge legibility is
                        // governed by the image beneath it, not by the theme.
                        .foregroundColor(.white)
                        .frame(width: 17, height: 17)
                        .background(Circle().fill(Color.black.opacity(0.62)))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .accessibilityLabel(NSLocalizedString("write.sheet.attachment.remove", comment: "移除附件"))
            }
            .accessibilityLabel(NSLocalizedString("write.sheet.attachment.photo", comment: "照片附件"))
    }

    private func capsuleChip(_ att: PendingAttachment) -> some View {
        let (icon, label) = chipContent(att)
        return HStack(spacing: 4) {
            Image(systemName: icon)
                .font(DSType.mono11)
                .foregroundStyle(DSColor.inkMuted)
            Text(label)
                .font(DSType.labelSM)
                .foregroundStyle(DSColor.inkMuted)
                .lineLimit(1)
            Button {
                Haptics.light()
                onRemoveAttachment(att.id)
            } label: {
                Image(systemName: "xmark")
                    .font(DSType.mono9)
                    .foregroundStyle(DSColor.inkSubtle)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(DSColor.glassLo, in: Capsule())
    }

    private func chipContent(_ att: PendingAttachment) -> (icon: String, label: String) {
        switch att {
        case .photo(let r): return ("photo", r.fileURL.lastPathComponent)
        case .voice(let r): return ("mic",   r.filePath.split(separator: "/").last.map(String.init) ?? "Voice")
        case .file(let r):  return ("doc",   r.fileName)
        }
    }

    private func railIcon(_ systemName: String, label: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .regular))
            .foregroundColor(DSColor.inkSubtle.opacity(0.4))
            .frame(width: 40, height: 40)
            .allowsHitTesting(false)
            .accessibilityLabel(
                NSLocalizedString("write.sheet.icon.disabled.hint", comment: "在主输入栏添加")
            )
    }

    /// Live location affordance. Detached: a quiet mappin icon (tap to fetch).
    /// Attached: the icon expands into a Notion-property-style chip carrying
    /// the actual place name — "带上了地址" becomes a readable fact instead of
    /// a tinted pin the user has to decode. Tapping the chip detaches.
    @ViewBuilder
    private var locationRailIcon: some View {
        let placeName = pendingLocation?.name?.trimmingCharacters(in: .whitespaces) ?? ""
        let showsChip = pendingLocation != nil && !placeName.isEmpty
        Button(action: {
            Haptics.soft()
            onToggleLocation()
        }) {
            HStack(spacing: 4) {
                if isLocating {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.7)
                        .tint(DSColor.inkMuted)
                } else {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: showsChip ? 12 : 18, weight: .regular))
                        .foregroundColor(
                            pendingLocation != nil
                                ? DSColor.accentOnBg
                                : DSColor.inkMuted
                        )
                }
                if showsChip {
                    Text(placeName)
                        .font(DSFonts.jetBrainsMono(size: 9, weight: .semibold, relativeTo: .caption2))
                        .tracking(0.4)
                        .foregroundColor(DSColor.accentOnBg)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, showsChip ? 9 : 0)
            .frame(width: showsChip ? nil : 40, height: showsChip ? 26 : 40)
            .frame(maxWidth: showsChip ? 128 : 40)
            .background(
                Capsule().fill(DSColor.accentOnBg.opacity(showsChip ? 0.12 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: showsChip)
        .accessibilityLabel(NSLocalizedString("write.sheet.icon.location", comment: "位置"))
        .accessibilityValue(
            pendingLocation != nil
                ? (pendingLocation?.name ?? NSLocalizedString("write.sheet.location.attached", comment: "已附加位置"))
                : NSLocalizedString("write.sheet.location.none", comment: "未附加位置")
        )
    }

    // MARK: - Send button + ghost cancel (vNext, replaces the Save pill)

    /// Circular ↑ send — same 38pt amber circle as the mic, so the mic → send
    /// swap reads as a symbol replacement inside one stable shape rather than
    /// a control being torn down and rebuilt. `amberAccent`, not `amberDeep`:
    /// the archival dark brown read as a heavy ink blot against the cream
    /// footer; the brighter interactive amber matches the dock's mic.
    private var sendButton: some View {
        Button(action: handleSave) {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 38, height: 38)
                .background(
                    Circle().fill(DSColor.amberAccent)
                        .shadow(
                            color: DSColor.amberAccent.opacity(saveReadyPulse ? 0.45 : 0),
                            radius: saveReadyPulse ? 14 : 0
                        )
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.6), value: saveReadyPulse)
                )
                .scaleEffect(saveReadyPulse ? 1.06 : 1.0)
                .animation(reduceMotion ? nil : Motion.spring, value: saveReadyPulse)
        }
        .pressScale(scale: 0.96, animation: .easeInOut(duration: 0.12))
        .accessibilityIdentifier("write-sheet-save")
        .accessibilityLabel(NSLocalizedString("write.sheet.send", comment: "发送"))
        .onAppear {
            // The button only mounts once the draft turned dirty — greet the
            // first character with the same soft amber pulse the pill had.
            guard !reduceMotion else { return }
            saveReadyPulse = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                saveReadyPulse = false
            }
        }
    }

    /// Quiet discard affordance beside send. Bare text, no capsule: the
    /// filled pill next to the filled circle made two competing shapes and
    /// read heavy — a destructive action must never fight the primary one
    /// for visual weight. The 38pt frame keeps a full-size touch target.
    private var cancelGhostButton: some View {
        Button(action: attemptDiscard) {
            Text(NSLocalizedString("write.sheet.cancel", comment: "取消"))
                .font(DSFonts.inter(size: 13, weight: .medium, relativeTo: .caption))
                .tracking(0.2)
                .foregroundColor(DSColor.inkMuted)
                .padding(.horizontal, 8)
                .frame(height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("write-sheet-cancel")
        .accessibilityLabel(NSLocalizedString("write.sheet.cancel", comment: "取消"))
    }

    // MARK: - Saved-to caption (composer.jsx:333-341)

    private var savedCaption: some View {
        HStack(spacing: 8) {
            Text("SAVED TO")
                .foregroundColor(DSColor.inkMuted)
            Text("VAULT / \(isoDate).md")
                .foregroundColor(DSColor.inkMuted)
        }
        .font(DSFonts.jetBrainsMono(size: 9, weight: .semibold, relativeTo: .caption2))
        .tracking(1.4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .accessibilityHidden(true)
    }

    // MARK: - Discard confirm bar

    private var discardConfirmBar: some View {
        HStack(spacing: 8) {
            // Warm warning ink + slightly larger type: the previous 9pt muted
            // caption was invisible next to the X the user just tapped, so the
            // "tap again to discard" affordance went unnoticed within its 4s
            // window.
            Text(NSLocalizedString("write.sheet.discard.prompt", comment: "Discard this draft?"))
                .font(DSFonts.jetBrainsMono(size: 10, weight: .semibold, relativeTo: .caption2))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundColor(DSColor.statusWarning)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Keep pill
            Button {
                withAnimation(Motion.spring) { confirmingDiscard = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { isFocused = true }
            } label: {
                Text(NSLocalizedString("write.sheet.discard.keep", comment: "Keep"))
                    .font(DSFonts.inter(size: 12, weight: .semibold, relativeTo: .caption))
                    .tracking(0.2)
                    .foregroundColor(DSColor.inkMuted)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule().fill(DSColor.surfaceSunken))
            }
            .buttonStyle(.plain)

            // Discard pill
            Button {
                performDiscard()
            } label: {
                Text(NSLocalizedString("write.sheet.discard.confirm", comment: "Discard"))
                    .font(DSFonts.inter(size: 12, weight: .semibold, relativeTo: .caption))
                    .tracking(0.2)
                    .foregroundColor(DSTokens.Colors.accentSoft)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule().fill(DSTokens.Colors.accent))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Rail hint caption (one-time, gated by writeSheetRailHintShown)

    private var railHintCaption: some View {
        Text(NSLocalizedString("write.sheet.rail.hint", comment: "Tap the dock to attach media"))
            .font(DSFonts.jetBrainsMono(size: 9, weight: .semibold, relativeTo: .caption2))
            .tracking(1.4)
            .textCase(.uppercase)
            .foregroundColor(DSColor.inkSubtle.opacity(0.7))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 4)
            .accessibilityHidden(true)
    }

    // MARK: - Actions
    //
    // "Close" is two different verbs now:
    //   • dismissKeepingDraft — scrim tap / swipe-down. The draft is sacred:
    //     collapse silently, keep every character. The text lives in the
    //     parent's SceneStorage-backed draft and reappears in the dock
    //     composer, which is itself the visible proof nothing was lost.
    //   • attemptDiscard — ✕ / ghost cancel. Destroying content is the ONLY
    //     action in the sheet that asks for confirmation (inline bar, 4s).

    /// Soft dismissal: hide the sheet, keep the draft. Never prompts.
    private func dismissKeepingDraft() {
        Haptics.soft()
        isFocused = false
        onClose()
    }

    /// Explicit cancel: confirm before destroying a dirty draft; a clean
    /// sheet (empty, or location-only — location is ambient, not content)
    /// closes silently. A second ✕ while the bar is up counts as "confirm".
    private func attemptDiscard() {
        if isDirty && !confirmingDiscard {
            Haptics.warn()
            withAnimation(Motion.spring) { confirmingDiscard = true }
            isFocused = false
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                withAnimation(Motion.spring) { confirmingDiscard = false }
            }
        } else if isDirty {
            performDiscard()
        } else {
            dismissKeepingDraft()
        }
    }

    /// Confirmed discard: actually destroy the draft, then close. The old
    /// "Discard" pill only hid the sheet — the SceneStorage draft survived,
    /// so the destructive path silently wasn't (#see design vNext).
    private func performDiscard() {
        Haptics.soft()
        isFocused = false
        onDiscard()
        onClose()
    }

    private func handleSave() {
        guard isDirty else { return }
        Haptics.medium()
        isFocused = false
        onSave()
    }
}

// MARK: - Preview

#if DEBUG
struct WriteSheetView_Previews: PreviewProvider {
    struct Harness: View {
        @State private var text = ""
        var body: some View {
            ZStack {
                DSColor.bgWarm.ignoresSafeArea()
                WriteSheetView(text: $text, onSave: {}, onClose: {})
            }
        }
    }

    static var previews: some View {
        Harness()
    }
}
#endif
