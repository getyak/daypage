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

struct WriteSheetView: View {

    /// Live draft text — bound to the same `draftText` the inline composer uses
    /// so save flows through the existing `submitCombinedMemo` path.
    @Binding var text: String
    /// Save — commits the current text via the parent's existing persistence.
    let onSave: () -> Void
    /// Close — dismiss the sheet without saving.
    let onClose: () -> Void

    @FocusState private var isFocused: Bool
    @State private var appeared: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Sheet-up easing — composer.jsx:219 `cubic-bezier(.2,.8,.2,1)` @ 320ms.
    private static let sheetUp = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.32)

    /// Non-whitespace character count (design composer.jsx:201).
    private var words: Int {
        text.filter { !$0.isWhitespace }.count
    }

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Date / time strings (museum-tag style)

    /// Captured once so the stamp doesn't reshuffle while the sheet is open.
    private let now = Date()

    /// Full weekday, e.g. "Thursday" (design composer.jsx:236).
    private var weekday: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEEE"
        return f.string(from: now)
    }

    /// Mono stamp "MAY 28 · 15:47" (design composer.jsx:239).
    private var stamp: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMM d · HH:mm"
        return f.string(from: now).uppercased()
    }

    /// ISO date for the vault caption "YYYY-MM-DD" (design composer.jsx:340).
    private var isoDate: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: now)
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            // Backdrop scrim — composer.jsx:206-209 rgba(30,24,18,0.34).
            DSTokens.Colors.recordingBg.opacity(0.34)
                .ignoresSafeArea()
                .opacity(appeared ? 1 : 0)
                .onTapGesture { onClose() }
                .accessibilityHidden(true)

            sheet
                .offset(y: appeared ? 0 : sheetTravel)
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : Self.sheetUp, value: appeared)
        .onAppear {
            appeared = true
            // Let the sheet-up settle before raising the keyboard.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                isFocused = true
            }
        }
    }

    /// Off-screen travel distance for the sheet-up entrance.
    private var sheetTravel: CGFloat { reduceMotion ? 0 : 420 }

    // MARK: - Sheet

    private var sheet: some View {
        VStack(spacing: 0) {
            dragHandle
            header
            hairline
            textArea
            hairline
            footerRail
            savedCaption
        }
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity)
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
        Capsule()
            .fill(DSTokens.Colors.borderDefault)
            .frame(width: 36, height: 4)
            .padding(.top, 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
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
            Button(action: onClose) {
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
            railIcon("mappin.and.ellipse", label: NSLocalizedString("write.sheet.icon.location", comment: "位置"))
            railIcon("tag", label: NSLocalizedString("write.sheet.icon.tag", comment: "标签"))

            Spacer()

            // Word count — mono, brightens once the user has typed.
            Text("\(words) \(NSLocalizedString("write.sheet.words_unit", comment: "字"))")
                .font(DSFonts.jetBrainsMono(size: 10, weight: .semibold))
                .tracking(1.3)
                .monospacedDigit()
                .foregroundColor(words > 0 ? DSTokens.Colors.fgMuted : DSTokens.Colors.fgSubtle)
                .padding(.trailing, 10)

            savePill
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    private func railIcon(_ systemName: String, label: String) -> some View {
        // Presentation-only quiet rail (design parity); capture flows live in
        // the inline composer. Tapping closes to the dock so the user reaches
        // the full multimodal surface rather than a dead control.
        Button {
            Haptics.soft()
            onClose()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(DSTokens.Colors.fgMuted)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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
            )
        }
        .buttonStyle(.plain)
        .disabled(!canSave)
        .animation(.easeOut(duration: 0.18), value: canSave)
        .accessibilityIdentifier("write-sheet-save")
        .accessibilityLabel(NSLocalizedString("write.sheet.save", comment: "保存"))
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

    // MARK: - Actions

    private func handleSave() {
        guard canSave else { return }
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
