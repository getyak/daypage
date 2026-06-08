import SwiftUI

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
//   • 0.5px hairline
//   • textarea — 18pt serif, italic placeholder「此刻在想什么？」, accent caret,
//     auto-grow (lineLimit 3…10)
//   • 0.5px hairline
//   • footer rail — camera/photo/location/tag icons · spacer · mono「N 字」·
//     accent「保存」pill (disabled when empty) with checkmark
//   • mono caption「SAVED TO  VAULT / YYYY-MM-DD.md」(real date)
//
// Entrance: sheet-up via timingCurve(.2,.8,.2,1) ~320ms — mirrors
// composer.jsx:219 `sheet-up 320ms cubic-bezier(.2,.8,.2,1)`. The icon rail is
// presentation-only in this round (no wiring) to match the design's quiet rail;
// the inline composer remains the full multimodal capture surface.

private struct SavePillPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect((!reduceMotion && configuration.isPressed) ? 0.96 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct WriteSheetView: View {

    /// Live draft text — bound to the same `draftText` the inline composer uses
    /// so save flows through the existing `submitCombinedMemo` path.
    @Binding var text: String
    /// Save — commits the current text via the parent's existing persistence.
    let onSave: () -> Void
    /// Close — dismiss the sheet without saving.
    let onClose: () -> Void
    /// Location attached to the memo being written; nil when none.
    var pendingLocation: Memo.Location? = nil
    /// True while a location fetch is in flight.
    var isLocating: Bool = false
    /// Toggle location: fetch if nil, clear if already set.
    var onToggleLocation: () -> Void = {}

    @FocusState private var isFocused: Bool
    @State private var appeared: Bool = false
    @State private var lastMilestone: Int = 0
    @GestureState private var dragOffset: CGFloat = 0
    @State private var committedClose: Bool = false
    @State private var saveReadyPulse: Bool = false
    @State private var confirmingDiscard: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppSettings.Keys.writeSheetRailHintShown) private var railHintShown: Bool = false
    /// Snapshot taken at open time so the hint stays visible for the whole first session.
    @State private var showRailHint: Bool = false

    /// Sheet-up easing — composer.jsx:219 `cubic-bezier(.2,.8,.2,1)` @ 320ms.
    private static let sheetUp = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.32)

    /// CJK-aware word count: each CJK/Hiragana/Katakana ideograph = 1 word;
    /// consecutive non-CJK non-whitespace scalars = 1 Latin word per run.
    private var wordCount: Int {
        Self.wordCount(in: text)
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

    private var charCount: Int { text.count }

    private var readingMinutes: Int {
        max(1, Int(ceil(Double(wordCount) / 200.0)))
    }

    private var showReadingTime: Bool { wordCount >= 50 }

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Counter color: interpolates from fgMuted → accentAmber as wordCount grows from 100…200.
    private var wordCountColor: Color {
        guard !reduceMotion, wordCount > 0 else {
            return wordCount > 0 ? DSTokens.Colors.fgMuted : DSTokens.Colors.fgSubtle
        }
        guard wordCount > 100 else { return DSTokens.Colors.fgMuted }
        let t = CGFloat(min(wordCount - 100, 100)) / 100.0
        return Self.lerpColor(from: DSColor.inkMuted, to: DSColor.accentAmber, t: t)
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

    private static let isoFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Captured once so the stamp doesn't reshuffle while the sheet is open.
    private let now = Date()

    /// Full weekday, e.g. "Thursday" (design composer.jsx:236).
    private var weekday: String { Self.weekdayFmt.string(from: now) }

    /// Mono stamp "MAY 28 · 15:47" (design composer.jsx:239).
    private var stamp: String { Self.stampFmt.string(from: now).uppercased() }

    /// ISO date for the vault caption "YYYY-MM-DD" (design composer.jsx:340).
    private var isoDate: String { Self.isoFmt.string(from: now) }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            // Backdrop scrim — composer.jsx:206-209 rgba(30,24,18,0.34).
            // Fades proportionally as the sheet is dragged down.
            DSTokens.Colors.recordingBg.opacity(0.34)
                .ignoresSafeArea()
                .opacity(appeared ? Double(max(CGFloat.zero, CGFloat(1) - dragOffset / CGFloat(400))) : 0)
                .onTapGesture { attemptClose() }
                .accessibilityHidden(true)

            sheet
                .offset(y: (appeared ? 0 : sheetTravel) + (dragOffset < 0 ? dragOffset / 6 : dragOffset))
                .gesture(swipeToDismiss)
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : Self.sheetUp, value: appeared)
        .onAppear {
            appeared = true
            confirmingDiscard = false
            // Let the sheet-up settle before raising the keyboard.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                isFocused = true
            }
        }
    }

    /// Off-screen travel distance for the sheet-up entrance.
    private var sheetTravel: CGFloat { reduceMotion ? 0 : 420 }

    /// Swipe-down-to-dismiss gesture attached to the whole sheet.
    private var swipeToDismiss: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($dragOffset) { value, state, _ in
                state = value.translation.height
            }
            .onEnded { value in
                if value.translation.height > 120 || value.predictedEndTranslation.height > 240 {
                    attemptClose()
                }
            }
    }

    // MARK: - Sheet

    private var sheet: some View {
        VStack(spacing: 0) {
            dragHandle
            header
            hairline
            textArea
            hairline
            footerRail
            if showRailHint && pendingLocation == nil {
                railHintCaption
            }
            if confirmingDiscard {
                discardConfirmBar
                    .transition(.opacity)
            } else {
                savedCaption
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : Motion.spring, value: confirmingDiscard)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity)
        .onAppear {
            // Capture first-visit before flipping the UserDefaults flag so
            // the hint renders during the current open (not just future ones).
            showRailHint = !railHintShown
            railHintShown = true
        }
        .background(
            DSColor.glassHi
                .background(.ultraThinMaterial)
        )
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
                .fill(DSTokens.Colors.borderSubtle)
                .frame(height: 0.5)
        }
        .shadow(color: DSTokens.Colors.recordingBg.opacity(0.32), radius: 30, x: 0, y: -16)
    }

    // MARK: - Drag handle (composer.jsx:222-225)

    private var dragHandle: some View {
        let progress = min(max(dragOffset, 0) / 120, 1.0)
        return Capsule()
            .fill(DSTokens.Colors.borderDefault.opacity(0.6 + 0.4 * progress))
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
                    attemptClose()
                } else if !reduceMotion {
                    withAnimation(Motion.spring) { }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { }
                }
            }
    }

    // MARK: - Header (composer.jsx:227-249)

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(weekday)
                    .font(DSFonts.serif(size: 18, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundColor(DSTokens.Colors.fgPrimary)

                Text(stamp)
                    .font(DSFonts.jetBrainsMono(size: 10, weight: .bold))
                    .tracking(1.6)
                    .foregroundColor(DSTokens.Colors.fgSubtle)
            }

            Spacer()

            // Close button — 30pt sunken circle (composer.jsx:241-248).
            Button(action: attemptClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DSTokens.Colors.fgMuted)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(DSTokens.Colors.surfaceSunken))
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

    // MARK: - 0.5px hairline (composer.jsx:252 / 279)

    private var hairline: some View {
        Rectangle()
            .fill(DSTokens.Colors.borderSubtle)
            .frame(height: 0.5)
            .padding(.horizontal, 22)
    }

    // MARK: - Textarea (composer.jsx:255-276)

    private var textArea: some View {
        // 18pt serif body, accent caret, auto-grow (lineLimit 3…10 ≈ min 90 /
        // max 280pt of the design). The placeholder is italic serif at fgSubtle.
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(NSLocalizedString("write.sheet.placeholder", comment: "此刻在想什么？"))
                    .font(DSFonts.serif(size: 18, italic: true))
                    .foregroundColor(DSTokens.Colors.fgSubtle.opacity(0.6))
                    .allowsHitTesting(false)
            }

            TextField("", text: $text, axis: .vertical)
                .font(DSFonts.serif(size: 18))
                .tracking(0.2)
                .lineSpacing(6) // ≈ lineHeight 1.7 on 18pt
                .foregroundColor(DSTokens.Colors.fgPrimary)
                .tint(DSTokens.Colors.accent)
                .lineLimit(3...10)
                .focused($isFocused)
                .accessibilityIdentifier("write-sheet-input")
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        keyboardToolbarContent
                    }
                }
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 18)
        .frame(minHeight: 90, alignment: .topLeading)
    }

    // MARK: - Footer rail (composer.jsx:282-330)

    private var footerRail: some View {
        HStack(spacing: 2) {
            railIcon("camera", label: NSLocalizedString("write.sheet.icon.camera", comment: "拍照"))
            railIcon("photo", label: NSLocalizedString("write.sheet.icon.photo", comment: "相册"))
            locationRailIcon
            railIcon("tag", label: NSLocalizedString("write.sheet.icon.tag", comment: "标签"))

            Spacer()

            // Word + char counter — mono10/inkSubtle, milestones every 100 words.
            let wordsLabel = wordCount == 1
                ? NSLocalizedString("writesheet.count.words.one", comment: "1 word")
                : String(format: NSLocalizedString("writesheet.count.words.other", comment: "%d words"), wordCount)
            let readLabel = String(format: NSLocalizedString("writesheet.count.read", comment: "~%d min read"), readingMinutes)
            HStack(spacing: 0) {
                Text("\(wordsLabel) · \(charCount) \(NSLocalizedString("writesheet.count.chars", comment: "chars"))")
                    .modifier(NumericTextContentTransition(value: Double(wordCount), reduceMotion: reduceMotion))
                    .animation(reduceMotion ? nil : Motion.fade, value: wordCount)
                    .animation(reduceMotion ? nil : Motion.spring, value: wordCount)
                if showReadingTime {
                    Text(" · \(readLabel)")
                        .modifier(NumericTextContentTransition(value: Double(readingMinutes), reduceMotion: reduceMotion))
                        .animation(reduceMotion ? nil : Motion.fade, value: readingMinutes)
                        .animation(reduceMotion ? nil : Motion.spring, value: readingMinutes)
                        .transition(.opacity)
                }
            }
            .font(DSType.mono10)
            .tracking(1.0)
            .textCase(.uppercase)
            .monospacedDigit()
            .foregroundColor(wordCountColor)
            .animation(reduceMotion ? nil : Motion.spring, value: showReadingTime)
            .padding(.trailing, 10)
            .accessibilityLabel(showReadingTime
                ? "\(wordsLabel), \(charCount) \(NSLocalizedString("writesheet.count.chars", comment: "chars")), \(readLabel)"
                : "\(wordsLabel), \(charCount) \(NSLocalizedString("writesheet.count.chars", comment: "chars"))")
            .onChange(of: wordCount) { newCount in
                let milestone = newCount / 100
                if milestone > lastMilestone {
                    lastMilestone = milestone
                    if newCount > 0 { Haptics.soft() }
                } else if milestone < lastMilestone {
                    lastMilestone = milestone
                }
            }

            savePill
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    private func railIcon(_ systemName: String, label: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .regular))
            .foregroundColor(DSTokens.Colors.fgSubtle.opacity(0.4))
            .frame(width: 40, height: 40)
            .allowsHitTesting(false)
            .accessibilityLabel(
                NSLocalizedString("write.sheet.icon.disabled.hint", comment: "在主输入栏添加")
            )
    }

    /// Live location icon — active, tappable, amber when a location is attached.
    @ViewBuilder
    private var locationRailIcon: some View {
        Button(action: {
            Haptics.soft()
            onToggleLocation()
        }) {
            ZStack {
                if isLocating {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.7)
                        .tint(DSTokens.Colors.fgMuted)
                } else {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(
                            pendingLocation != nil
                                ? DSColor.accentAmber
                                : DSColor.inkMuted
                        )
                }
            }
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("write.sheet.icon.location", comment: "位置"))
        .accessibilityValue(
            pendingLocation != nil
                ? (pendingLocation?.name ?? NSLocalizedString("write.sheet.location.attached", comment: "已附加位置"))
                : NSLocalizedString("write.sheet.location.none", comment: "未附加位置")
        )
    }

    // MARK: - Save pill (composer.jsx:312-329)

    private var savePill: some View {
        Button(action: handleSave) {
            HStack(spacing: 6) {
                Text(NSLocalizedString("write.sheet.save", comment: "保存"))
                    .font(DSFonts.inter(size: 13.5, weight: .semibold))
                    .tracking(0.2)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundColor(canSave ? DSTokens.Colors.accentSoft : DSTokens.Colors.fgSubtle)
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(
                Capsule().fill(canSave ? DSTokens.Colors.accent : DSTokens.Colors.surfaceSunken)
                    .shadow(
                        color: DSColor.accentAmber.opacity(saveReadyPulse ? 0.5 : 0),
                        radius: saveReadyPulse ? 16 : 0
                    )
                    .animation(.easeOut(duration: 0.6), value: saveReadyPulse)
            )
            .scaleEffect(saveReadyPulse ? 1.06 : 1.0)
            .animation(reduceMotion ? nil : Motion.spring, value: saveReadyPulse)
        }
        .buttonStyle(SavePillPressStyle())
        .disabled(!canSave)
        .animation(.easeOut(duration: 0.18), value: canSave)
        .accessibilityIdentifier("write-sheet-save")
        .accessibilityLabel(NSLocalizedString("write.sheet.save", comment: "保存"))
        .onChange(of: canSave) { newValue in
            guard newValue, !reduceMotion else { return }
            saveReadyPulse = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                saveReadyPulse = false
            }
        }
    }

    // MARK: - Saved-to caption (composer.jsx:333-341)

    private var savedCaption: some View {
        HStack(spacing: 8) {
            Text("SAVED TO")
                .foregroundColor(DSTokens.Colors.fgSubtle)
            Text("VAULT / \(isoDate).md")
                .foregroundColor(DSTokens.Colors.fgMuted)
        }
        .font(DSFonts.jetBrainsMono(size: 9, weight: .semibold))
        .tracking(1.4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .accessibilityHidden(true)
    }

    // MARK: - Discard confirm bar

    private var discardConfirmBar: some View {
        HStack(spacing: 8) {
            Text(NSLocalizedString("write.sheet.discard.prompt", comment: "Discard this draft?"))
                .font(DSFonts.jetBrainsMono(size: 9, weight: .semibold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundColor(DSTokens.Colors.fgMuted)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Keep pill
            Button {
                withAnimation(Motion.spring) { confirmingDiscard = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { isFocused = true }
            } label: {
                Text(NSLocalizedString("write.sheet.discard.keep", comment: "Keep"))
                    .font(DSFonts.inter(size: 12, weight: .semibold))
                    .tracking(0.2)
                    .foregroundColor(DSTokens.Colors.fgMuted)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule().fill(DSTokens.Colors.surfaceSunken))
            }
            .buttonStyle(.plain)

            // Discard pill
            Button {
                Haptics.soft()
                isFocused = false
                onClose()
            } label: {
                Text(NSLocalizedString("write.sheet.discard.confirm", comment: "Discard"))
                    .font(DSFonts.inter(size: 12, weight: .semibold))
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
            .font(DSFonts.jetBrainsMono(size: 9, weight: .semibold))
            .tracking(1.4)
            .textCase(.uppercase)
            .foregroundColor(DSTokens.Colors.fgSubtle.opacity(0.7))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 4)
            .accessibilityHidden(true)
    }

    // MARK: - Keyboard accessory toolbar

    @ViewBuilder
    private var keyboardToolbarContent: some View {
        // Done — collapses keyboard, reveals footer rail and saved caption.
        Button(NSLocalizedString("write.sheet.done", comment: "完成")) {
            isFocused = false
        }
        .font(DSFonts.inter(size: 14, weight: .medium))
        .foregroundColor(DSTokens.Colors.fgMuted)
        .accessibilityLabel(NSLocalizedString("write.sheet.done", comment: "完成"))

        // Live word / char counter — reuses footer-rail mono10 style.
        let wordsLabel = wordCount == 1
            ? NSLocalizedString("writesheet.count.words.one", comment: "1 word")
            : String(format: NSLocalizedString("writesheet.count.words.other", comment: "%d words"), wordCount)
        let readLabel = String(format: NSLocalizedString("writesheet.count.read", comment: "~%d min read"), readingMinutes)
        HStack(spacing: 0) {
            Text("\(wordsLabel) · \(charCount) \(NSLocalizedString("writesheet.count.chars", comment: "chars"))")
                .modifier(NumericTextContentTransition(value: Double(wordCount), reduceMotion: reduceMotion))
                .animation(reduceMotion ? nil : Motion.spring, value: wordCount)
            if showReadingTime {
                Text(" · \(readLabel)")
                    .modifier(NumericTextContentTransition(value: Double(readingMinutes), reduceMotion: reduceMotion))
                    .animation(reduceMotion ? nil : Motion.spring, value: readingMinutes)
                    .transition(.opacity)
            }
        }
        .font(DSType.mono10)
        .tracking(1.0)
        .textCase(.uppercase)
        .monospacedDigit()
        .foregroundColor(wordCountColor)
        .animation(reduceMotion ? nil : Motion.spring, value: showReadingTime)
        .accessibilityLabel(showReadingTime
            ? "\(wordsLabel), \(charCount) \(NSLocalizedString("writesheet.count.chars", comment: "chars")), \(readLabel)"
            : "\(wordsLabel), \(charCount) \(NSLocalizedString("writesheet.count.chars", comment: "chars"))")

        Spacer()

        // Accent save button — same path as the footer-rail pill.
        Button(action: handleSave) {
            Text(NSLocalizedString("write.sheet.save", comment: "保存"))
                .font(DSFonts.inter(size: 14, weight: .semibold))
                .tracking(0.2)
                .foregroundColor(canSave ? DSTokens.Colors.accentSoft : DSTokens.Colors.fgSubtle)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(
                    Capsule().fill(canSave ? DSTokens.Colors.accent : DSTokens.Colors.surfaceSunken)
                )
        }
        .buttonStyle(.plain)
        .disabled(!canSave)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: canSave)
        .accessibilityLabel(NSLocalizedString("write.sheet.save", comment: "保存"))
        .accessibilityIdentifier("write-sheet-keyboard-save")
    }

    // MARK: - Actions

    private func attemptClose() {
        if canSave && !confirmingDiscard {
            Haptics.warn()
            withAnimation(Motion.spring) { confirmingDiscard = true }
            isFocused = false
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                withAnimation(Motion.spring) { confirmingDiscard = false }
            }
        } else {
            Haptics.soft()
            isFocused = false
            onClose()
        }
    }

    private func handleSave() {
        guard canSave else { return }
        Haptics.medium()
        isFocused = false
        onSave()
    }
}

// MARK: - NumericTextContentTransition

private struct NumericTextContentTransition: ViewModifier {
    let value: Double
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content
                .contentTransition(reduceMotion ? .identity : .numericText(value: value))
        } else {
            content
                .contentTransition(.identity)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct WriteSheetView_Previews: PreviewProvider {
    struct Harness: View {
        @State private var text = ""
        var body: some View {
            ZStack {
                DSTokens.Colors.bgWarm.ignoresSafeArea()
                WriteSheetView(text: $text, onSave: {}, onClose: {})
            }
        }
    }

    static var previews: some View {
        Harness()
    }
}
#endif
