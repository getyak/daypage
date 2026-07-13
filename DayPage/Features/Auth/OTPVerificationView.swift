import SwiftUI
import DayPageServices

// MARK: - OTPVerificationView

/// 6-digit email OTP input screen. Uses an invisible TextField to hold focus/input
/// while 6 visible "cells" render current state — the same pattern iOS Messages
/// uses for verification codes. `.oneTimeCode` enables iOS QuickType autofill.
struct OTPVerificationView: View {

    // MARK: Inputs

    let email: String
    /// Called when verification succeeds. Parent handles dismiss/navigation.
    var onVerified: (() -> Void)? = nil
    /// Back-button callback: returns the user to EmailAuthView to edit their email.
    var onBack: (() -> Void)? = nil

    // MARK: Environment

    @EnvironmentObject private var authService: AuthService

    // MARK: State

    @StateObject private var viewModel = OTPVerificationViewModel()
    @FocusState private var codeFieldFocused: Bool

    private let codeLength = 6
    // Adaptive DS success token (was hardcoded #6EBE71, tuned for the old
    // near-black palette and illegible on the light warm-cream background).
    private let successGreen = DSColor.statusSuccess

    // MARK: Body

    var body: some View {
        ZStack {
            DSColor.bgWarm.ignoresSafeArea()
            GrainOverlay()

            VStack(alignment: .leading, spacing: 0) {
                backButton
                Spacer().frame(height: 32)
                heading
                Spacer().frame(height: 8)
                subheading
                Spacer().frame(height: 32)

                otpCells
                    .padding(.horizontal, 4)
                    .overlay(hiddenCodeField)

                if viewModel.shouldShowPasteCapsule {
                    Spacer().frame(height: 10)
                    pasteCapsule
                }

                Spacer().frame(height: 20)

                if let errorMessage = viewModel.displayedErrorMessage {
                    Text(errorMessage)
                        .font(DSType.bodySM)
                        .foregroundColor(DSColor.statusError)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 4)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: viewModel.displayedErrorMessage)
                }

                Spacer().frame(height: 12)
                resendButton

                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            if viewModel.isVerifying {
                ProgressView()
                    .tint(DSColor.inkPrimary)
            }
        }
        .task {
            viewModel.email = email
            viewModel.onVerified = onVerified
            viewModel.onBack = onBack
            viewModel.bind(authService: authService)
        }
        .onAppear {
            codeFieldFocused = !viewModel.isLocked
            viewModel.onAppear()
        }
        .onDisappear {
            viewModel.onDisappear()
        }
        .onChange(of: viewModel.isLocked) { locked in
            if locked { codeFieldFocused = false }
        }
    }

    // MARK: - Sections

    private var backButton: some View {
        Button {
            onBack?()
        } label: {
            Image(systemName: "chevron.left")
                .foregroundColor(DSColor.inkSecondary)
                .font(.system(size: 18, weight: .medium))
                .padding(.vertical, 6)
        }
        .accessibilityLabel(NSLocalizedString("a11y.back_to_email", comment: "Back to email"))
    }

    private var heading: some View {
        Text("Enter verification code")
            .font(DSFonts.serif(size: 26, weight: .semibold, relativeTo: .title))
            .foregroundColor(DSColor.inkPrimary)
    }

    private var subheading: some View {
        (
            Text("We sent a 6-digit code to\n")
                .foregroundColor(DSColor.inkSecondary)
            + Text(email)
                .foregroundColor(DSColor.inkPrimary)
        )
        .font(.custom("Inter-Regular", size: 14))
        .lineSpacing(4)
        .accessibilityLabel("Verification code sent to \(email)")
    }

    private var otpCells: some View {
        HStack(spacing: 10) {
            ForEach(0..<codeLength, id: \.self) { index in
                otpCell(for: index)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { codeFieldFocused = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Enter the \(codeLength)-digit code")
        .accessibilityValue(viewModel.code.isEmpty ? "No digits entered" : "\(viewModel.code.count) of \(codeLength) digits entered")
    }

    private func otpCell(for index: Int) -> some View {
        let digit = digitAt(index)
        let isActive = codeFieldFocused && index == viewModel.code.count && viewModel.code.count < codeLength
        let isSuccess = index <= viewModel.successStagger
        let strokeColor: Color = {
            if isSuccess { return successGreen }
            // Active cell carries the DS amber accent — same focus language
            // as the email field one step earlier in the flow.
            return isActive ? DSColor.accentOnBg : DSColor.inkFaint
        }()
        return ZStack {
            RoundedRectangle(cornerRadius: DSRadius.sm)
                .fill(DSColor.surfaceWhite)
            RoundedRectangle(cornerRadius: DSRadius.sm)
                .stroke(strokeColor, lineWidth: isActive && !isSuccess ? 1.5 : 1)
            if let digit = digit {
                Text(String(digit))
                    .font(.custom("JetBrainsMono-Regular", size: 24))
                    .foregroundColor(isSuccess ? successGreen : DSColor.inkPrimary)
            } else if isActive {
                Rectangle()
                    .fill(DSColor.accentOnBg)
                    .frame(width: 1, height: 22)
                    .opacity(0.8)
            }
        }
        .frame(height: 56)
        .frame(maxWidth: .infinity)
    }

    private var pasteCapsule: some View {
        Button {
            viewModel.applyClipboardCode()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 12, weight: .medium))
                Text("Paste \(viewModel.clipboardCode ?? "")")
                    .font(.custom("SpaceGrotesk-Medium", size: 13))
            }
            .foregroundColor(DSColor.inkPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(DSColor.surfaceWhite)
                    .overlay(Capsule().stroke(DSColor.inkFaint, lineWidth: 1))
            )
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityLabel("Paste code \(viewModel.clipboardCode ?? "")")
    }

    /// Invisible TextField that captures focus and input. Its value mirrors
    /// `viewModel.code`; the visible cells render the same data.
    private var hiddenCodeField: some View {
        TextField("", text: Binding(
            get: { viewModel.code },
            set: { viewModel.handleCodeInput($0) }
        ))
        .keyboardType(.numberPad)
        .textContentType(.oneTimeCode)
        .focused($codeFieldFocused)
        .foregroundColor(.clear)
        .accentColor(.clear)
        .tint(.clear)
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .opacity(0.02)
        .disabled(viewModel.isLocked)
        .accessibilityHidden(true)
    }

    private var resendButton: some View {
        HStack(spacing: 6) {
            Text("Didn't get it?")
                .font(.custom("Inter-Regular", size: 13))
                .foregroundColor(DSColor.inkSecondary)
            Button {
                Task { await viewModel.triggerResend() }
            } label: {
                let blocked = (!viewModel.canResendImmediately && viewModel.resendCountdown > 0) || viewModel.isLocked
                Text(
                    (!viewModel.canResendImmediately && viewModel.resendCountdown > 0)
                        ? "Resend in \(viewModel.resendCountdown)s"
                        : "Resend code"
                )
                .font(.custom("SpaceGrotesk-Medium", size: 13))
                // Enabled resend is a tappable text link — accentOnBg (amber
                // ink) gives it the DS link affordance in both schemes.
                .foregroundColor(blocked ? DSColor.inkMuted : DSColor.accentOnBg)
            }
            .disabled(
                (!viewModel.canResendImmediately && viewModel.resendCountdown > 0)
                    || viewModel.resendInFlight
                    || viewModel.isLocked
            )
            .accessibilityLabel(
                viewModel.resendCountdown > 0 && !viewModel.canResendImmediately
                    ? "Resend code available in \(viewModel.resendCountdown) seconds"
                    : "Resend verification code"
            )
        }
    }

    // MARK: - Helpers

    private func digitAt(_ index: Int) -> Character? {
        guard index < viewModel.code.count else { return nil }
        let stringIndex = viewModel.code.index(viewModel.code.startIndex, offsetBy: index)
        return viewModel.code[stringIndex]
    }
}
