import SwiftUI

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
    private let successGreen = Color(hex: "6EBE71")

    // MARK: Body

    var body: some View {
        ZStack {
            Color(hex: "0A0A0A").ignoresSafeArea()
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
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "E05A5A"))
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
                    .tint(.white)
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
                .foregroundColor(Color(hex: "6B6B6B"))
                .font(.system(size: 18, weight: .medium))
                .padding(.vertical, 6)
        }
        .accessibilityLabel("Back to email input")
    }

    private var heading: some View {
        Text("Enter verification code")
            .font(.custom("SpaceGrotesk-Bold", size: 24))
            .foregroundColor(Color(hex: "F5F0E8"))
    }

    private var subheading: some View {
        (
            Text("We sent a 6-digit code to\n")
                .foregroundColor(Color(hex: "6B6B6B"))
            + Text(email)
                .foregroundColor(Color(hex: "F5F0E8"))
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
            return isActive ? Color(hex: "F5F0E8") : Color(hex: "2A2A2A")
        }()
        return ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(hex: "1A1A1A"))
            RoundedRectangle(cornerRadius: 10)
                .stroke(strokeColor, lineWidth: isActive && !isSuccess ? 1.5 : 1)
            if let digit = digit {
                Text(String(digit))
                    .font(.custom("JetBrainsMono-Regular", size: 24))
                    .foregroundColor(isSuccess ? successGreen : Color(hex: "F5F0E8"))
            } else if isActive {
                Rectangle()
                    .fill(Color(hex: "F5F0E8"))
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
            .foregroundColor(Color(hex: "F5F0E8"))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color(hex: "1A1A1A"))
                    .overlay(Capsule().stroke(Color(hex: "2A2A2A"), lineWidth: 1))
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
                .foregroundColor(Color(hex: "6B6B6B"))
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
                .foregroundColor(blocked ? Color(hex: "4A4A4A") : Color(hex: "F5F0E8"))
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
