import SwiftUI

// MARK: - InputBarView

/// Fixed bottom input bar for composing and submitting text memos.
/// Provides a multiline TextEditor with a submit button.
/// Auto-captures device info in YAML frontmatter on submit.
struct InputBarView: View {

    // MARK: Binding

    /// The draft text the user is composing.
    @Binding var text: String

    /// Whether a submission is currently in progress.
    var isSubmitting: Bool

    /// Callback invoked when the user taps the submit button.
    var onSubmit: () -> Void

    // MARK: Private State

    @FocusState private var isFocused: Bool

    // Height of the TextEditor grows with content (clamped)
    @State private var textEditorHeight: CGFloat = 44

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .background(DSColor.outline)

            HStack(alignment: .bottom, spacing: 12) {
                // Multiline text input
                ZStack(alignment: .topLeading) {
                    // Placeholder text
                    if text.isEmpty {
                        Text("记录想法…")
                            .bodyMDStyle()
                            .foregroundColor(DSColor.onSurfaceVariant)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $text)
                        .bodyMDStyle()
                        .foregroundColor(DSColor.onSurface)
                        .focused($isFocused)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .frame(minHeight: 44, maxHeight: 140)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 2)
                }
                .background(DSColor.surfaceContainerLow)

                // Submit button
                Button(action: {
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          !isSubmitting else { return }
                    onSubmit()
                }) {
                    if isSubmitting {
                        ProgressView()
                            .tint(DSColor.onPrimary)
                            .frame(width: 44, height: 44)
                            .background(DSColor.onSurfaceVariant)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(
                                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? DSColor.onSurfaceVariant
                                    : DSColor.onPrimary
                            )
                            .frame(width: 44, height: 44)
                            .background(
                                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? DSColor.surfaceContainerHigh
                                    : DSColor.primary
                            )
                    }
                }
                .disabled(
                    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting
                )
                .cornerRadius(0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(DSColor.surfaceContainerLow)
        }
    }
}
