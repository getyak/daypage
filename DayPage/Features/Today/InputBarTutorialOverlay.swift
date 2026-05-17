import SwiftUI

// MARK: - InputBarTutorialOverlay (US-010)

/// Three-step coach-mark tutorial shown on first launch.
/// Completion is stored in UserDefaults so it only shows once.
struct InputBarTutorialOverlay: View {

    @Binding var isPresented: Bool
    @State private var step: Int = 0

    private let steps: [(icon: String, title: String, body: String)] = [
        ("keyboard", "Tap to type", "Tap the text area to start writing your memo."),
        ("mic.fill", "Hold mic to record", "Press and hold the mic button for quick voice capture."),
        ("arrow.left.and.right", "Swipe for quick actions", "Swipe left to cancel, right to transcribe your voice memo.")
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture { advance() }

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 20) {
                    // Step indicator dots
                    HStack(spacing: 6) {
                        ForEach(0..<steps.count, id: \.self) { i in
                            Circle()
                                .fill(i == step ? DSColor.amberAccent : DSColor.inkFaint)
                                .frame(width: 6, height: 6)
                                .animation(.easeInOut(duration: 0.2), value: step)
                        }
                    }

                    Image(systemName: steps[step].icon)
                        .font(.system(size: 32, weight: .medium))
                        .foregroundColor(DSColor.amberAccent)
                        .frame(height: 44)

                    VStack(spacing: 6) {
                        Text(steps[step].title)
                            .font(DSFonts.inter(size: 17, weight: .semibold))
                            .foregroundColor(DSColor.inkPrimary)
                        Text(steps[step].body)
                            .font(DSFonts.inter(size: 14))
                            .foregroundColor(DSColor.inkMuted)
                            .multilineTextAlignment(.center)
                    }

                    Button(action: advance) {
                        Text(step < steps.count - 1 ? "Next" : "Got it")
                            .font(DSFonts.inter(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(DSColor.amberAccent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(24)
                .background(DSColor.bgWarm)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal, 24)
                .padding(.bottom, 140)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: step)
    }

    private func advance() {
        if step < steps.count - 1 {
            step += 1
        } else {
            UserDefaults.standard.set(true, forKey: "inputBarTutorialCompleted")
            withAnimation { isPresented = false }
        }
    }
}

// MARK: - Convenience

extension InputBarTutorialOverlay {
    static var shouldShow: Bool {
        !UserDefaults.standard.bool(forKey: "inputBarTutorialCompleted")
    }
}
