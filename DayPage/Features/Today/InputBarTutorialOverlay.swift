import SwiftUI

// MARK: - InputBarTutorialOverlay (US-010)

/// Three-step coach-mark tutorial shown on first launch.
/// Completion is stored in UserDefaults so it only shows once.
struct InputBarTutorialOverlay: View {

    @Binding var isPresented: Bool
    @State private var step: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let steps: [(icon: String, title: String, body: String)] = [
        ("keyboard",
         NSLocalizedString("tutorial.input.step1.title", comment: "Step 1 title"),
         NSLocalizedString("tutorial.input.step1.body",  comment: "Step 1 body")),
        ("mic.fill",
         NSLocalizedString("tutorial.input.step2.title", comment: "Step 2 title"),
         NSLocalizedString("tutorial.input.step2.body",  comment: "Step 2 body")),
        ("arrow.left.and.right",
         NSLocalizedString("tutorial.input.step3.title", comment: "Step 3 title"),
         NSLocalizedString("tutorial.input.step3.body",  comment: "Step 3 body")),
    ]

    private var contentTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture { advance() }

            VStack(spacing: 0) {
                // Skip button — top-right, hidden on final step
                HStack {
                    Spacer()
                    if step < steps.count - 1 {
                        Button(action: { Haptics.soft(); complete() }) {
                            Text(NSLocalizedString("tutorial.skip", comment: "Skip tutorial"))
                                .font(DSFonts.inter(size: 15, weight: .medium))
                                .foregroundColor(DSColor.inkMuted)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 32)
                        .padding(.top, 16)
                    }
                }

                Spacer()

                VStack(spacing: 20) {
                    // Step indicator dots — tappable for direct navigation
                    HStack(spacing: 6) {
                        ForEach(0..<steps.count, id: \.self) { i in
                            Circle()
                                .fill(i == step ? DSColor.amberAccent : DSColor.inkFaint)
                                .frame(width: 6, height: 6)
                                .animation(Motion.respectReduceMotion(.easeInOut(duration: 0.2)), value: step)
                                .contentShape(Rectangle().size(CGSize(width: 44, height: 44)).offset(x: -19, y: -19))
                                .onTapGesture {
                                    withAnimation(Motion.respectReduceMotion(Motion.slide)) {
                                        step = i
                                    }
                                    Haptics.soft()
                                }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityLabel(String(format: NSLocalizedString("tutorial.step.indicator", comment: "Step N"), i + 1))
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(String(format: NSLocalizedString("tutorial.step.of", comment: "Step N of M"), step + 1, steps.count))

                    // Animated content block — slides left/right on step change
                    VStack(spacing: 20) {
                        Image(systemName: steps[step].icon)
                            .font(.system(size: 32, weight: .medium))
                            .foregroundColor(DSColor.amberAccent)
                            .frame(height: 44)
                            .accessibilityHidden(true)

                        VStack(spacing: 6) {
                            Text(steps[step].title)
                                .font(DSFonts.inter(size: 17, weight: .semibold))
                                .foregroundColor(DSColor.inkPrimary)
                            Text(steps[step].body)
                                .font(DSFonts.inter(size: 14))
                                .foregroundColor(DSColor.inkMuted)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .id(step)
                    .transition(contentTransition)

                    Button(action: advance) {
                        Text(step < steps.count - 1
                             ? NSLocalizedString("tutorial.next", comment: "Next step")
                             : NSLocalizedString("tutorial.gotIt", comment: "Done"))
                            .font(DSFonts.inter(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(DSColor.amberAccent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(step < steps.count - 1
                                       ? NSLocalizedString("tutorial.next.hint", comment: "Advances to next tip")
                                       : NSLocalizedString("tutorial.dismiss.hint", comment: "Dismisses tutorial"))
                }
                .padding(24)
                .background(DSColor.bgWarm)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal, 24)
                .padding(.bottom, 140)
                .gesture(
                    DragGesture(minimumDistance: 30)
                        .onEnded { value in
                            if value.translation.width < -40 {
                                withAnimation(Motion.respectReduceMotion(Motion.slide)) { advance() }
                            } else if value.translation.width > 40 {
                                withAnimation(Motion.respectReduceMotion(Motion.swipeBack)) { retreat() }
                            }
                        }
                )
            }
        }
        .animation(Motion.respectReduceMotion(.easeInOut(duration: 0.22)), value: step)
    }

    private func advance() {
        if step < steps.count - 1 {
            Haptics.soft()
            step += 1
        } else {
            Haptics.success()
            complete()
        }
    }

    private func retreat() {
        if step > 0 {
            Haptics.soft()
            step -= 1
        }
    }

    private func complete() {
        UserDefaults.standard.set(true, forKey: "inputBarTutorialCompleted")
        withAnimation(Motion.respectReduceMotion(.easeInOut(duration: 0.22))) {
            isPresented = false
        }
    }
}

// MARK: - Convenience

extension InputBarTutorialOverlay {
    static var shouldShow: Bool {
        !UserDefaults.standard.bool(forKey: "inputBarTutorialCompleted")
    }
}
