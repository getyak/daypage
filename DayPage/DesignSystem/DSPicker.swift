import SwiftUI
import DayPageServices

// MARK: - DSPicker
//
// 日式美术馆风格 picker — amber-rimmed glass panel that expands inline,
// replacing the SwiftUI native `Picker` whose default look fights the
// warm-cream surface palette. Use case: SettingsView 字号 / 时区选择 /
// 颜色主题 — places where a compact, in-form chooser feels right.
//
// Behaviour:
// - Tap the header row to expand a list of options anchored beneath it.
// - The currently-selected value is shown trailing the title until expanded.
// - Selecting an option dismisses the expansion with a soft spring.
// - Visuals lean on existing semantic colors (DSColor.amberAccent / inkMuted
//   / inkPrimary) so dark-mode and tint changes apply for free.
//
// Note: This is a manual, hand-rolled component — DSTokens.swift's
// AUTO-GENERATED block is intentionally untouched.

/// Drop-in replacement for SwiftUI's `Picker` that matches DayPage's
/// 日式美术馆 visual language. Expand/collapse animates with a spring; the
/// active option is checked with an amber `✓`.
struct DSPicker<Value: Hashable, Label: View>: View {

    // MARK: Inputs

    let title: String
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    let label: () -> Label

    // MARK: Private State

    @State private var isExpanded = false

    // MARK: Init

    init(
        title: String,
        selection: Binding<Value>,
        options: [(value: Value, label: String)],
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.title = title
        self._selection = selection
        self.options = options
        self.label = label
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            // Header row — tappable, surfaces the selected value.
            Button {
                withAnimation(Motion.spring) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    label()
                    Spacer()
                    Text(selectedLabel)
                        .foregroundColor(DSColor.inkMuted)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(DSColor.inkMuted)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(selectedLabel))

            // Expanded option list.
            if isExpanded {
                ForEach(options, id: \.value) { option in
                    Button {
                        selection = option.value
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                            isExpanded = false
                        }
                    } label: {
                        HStack {
                            Text(option.label)
                                .foregroundColor(DSColor.inkPrimary)
                            Spacer()
                            if option.value == selection {
                                Image(systemName: "checkmark")
                                    .foregroundColor(DSColor.accentOnBg)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        option.value == selection
                            ? DSColor.amberAccent.opacity(0.08)
                            : Color.clear
                    )
                }
            }
        }
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(DSColor.accentOnBg.opacity(0.25), lineWidth: 0.75)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Helpers

    /// Label text for the currently-selected value, or empty string when
    /// the binding does not match any option (treated as "no selection").
    private var selectedLabel: String {
        options.first(where: { $0.value == selection })?.label ?? ""
    }
}
