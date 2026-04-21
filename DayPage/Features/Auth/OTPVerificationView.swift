import SwiftUI

// MARK: - OTPVerificationView

/// 6-digit email OTP entry screen. Uses a single invisible TextField that
/// owns focus/input while 6 visible "cells" render the current state. This
/// is the pattern Apple's Messages code UI uses — it lets iOS QuickType
/// surface SMS/email verification codes (via `.oneTimeCode`) and keeps the
/// backing data in one String.
struct OTPVerificationView: View {

    // MARK: Inputs

    let email: String
    /// Called with the 6-digit code after successful verification. The parent
    /// view can react (dismiss, navigate, etc.). Session state itself is
    /// published by `AuthService.session` via `authStateChanges`.
    var onVerified: (() -> Void)? = nil
    /// Back button. Pops to EmailAuthView so user can edit the email.
    var onBack: (() -> Void)? = nil

    // MARK: Environment

    @EnvironmentObject private var authService: AuthService

    // MARK: State

    @State private var code: String = ""
    @State private var isVerifying: Bool = false
    @State private var localError: DPAuthError?
    @State private var resendCountdown: Int = 0
    @State private var resendTimer: Timer?
    @State private var resendInFlight: Bool = false
    /// 6-digit code we detected on the clipboard when the view appeared.
    /// Drives the "Paste 123456" capsule. Nil once consumed or dismissed.
    @State private var clipboardCode: String?
    /// Highest cell index whose stroke has flipped to the success-green color.
    /// -1 means animation hasn't started; 5 means all cells are green.
    @State private var successStagger: Int = -1
    @FocusState private var codeFieldFocused: Bool

    private let codeLength = 6
    private let successGreen = Color(hex: "6EBE71")

    /// Locked when the user has exhausted their local OTP budget. Disables
    /// the 6-cell field and the Resend button until the lockout ends.
    private var isLocked: Bool {
        if case .otpLocked = localError { return true }
        if case .otpLocked = authService.error { return true }
        return false
    }

    // MARK: Body

    var body: some View {
        ZStack {
            Color(hex: "0A0A0A").ignoresSafeArea()
            grainOverlay

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

                if shouldShowPasteCapsule {
                    Spacer().frame(height: 10)
                    pasteCapsule
                }

                Spacer().frame(height: 20)

                if let errorMessage = displayedErrorMessage {
                    Text(errorMessage)
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "E05A5A"))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 4)
                }

                Spacer().frame(height: 12)
                resendButton

                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            if isVerifying {
                ProgressView()
                    .tint(.white)
            }
        }
        .onAppear {
            codeFieldFocused = !isLocked
            startResendCountdown()
            detectClipboardCode()
        }
        .onDisappear {
            stopResendCountdown()
        }
    }

    // MARK: - Sections

    private var grainOverlay: some View {
        Canvas { context, size in
            for _ in 0..<800 {
                let x = CGFloat.random(in: 0..<size.width)
                let y = CGFloat.random(in: 0..<size.height)
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)),
                    with: .color(.white.opacity(0.04))
                )
            }
        }
        .ignoresSafeArea()
        .blendMode(.overlay)
        .allowsHitTesting(false)
    }

    private var backButton: some View {
        Button {
            onBack?()
        } label: {
            Image(systemName: "chevron.left")
                .foregroundColor(Color(hex: "6B6B6B"))
                .font(.system(size: 18, weight: .medium))
                .padding(.vertical, 6)
        }
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
    }

    /// Six visible cells that reflect `code`. Tapping anywhere in the row
    /// re-focuses the hidden TextField so the keyboard reappears.
    private var otpCells: some View {
        HStack(spacing: 10) {
            ForEach(0..<codeLength, id: \.self) { index in
                otpCell(for: index)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { codeFieldFocused = true }
    }

    private func otpCell(for index: Int) -> some View {
        let digit = digitAt(index)
        let isActive = codeFieldFocused && index == code.count && code.count < codeLength
        let isSuccess = index <= successStagger
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

    /// Shown under the OTP cells when the clipboard holds a fresh 6-digit
    /// code. Tapping accepts → auto-verifies. Hidden once the user types
    /// anything, once the lockout kicks in, or once the code is consumed.
    private var pasteCapsule: some View {
        Button {
            guard let digits = clipboardCode else { return }
            code = digits
            clipboardCode = nil
            Task { await triggerVerify() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 12, weight: .medium))
                Text("Paste \(clipboardCode ?? "")")
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
    }

    private var shouldShowPasteCapsule: Bool {
        guard let digits = clipboardCode, digits.count == codeLength else { return false }
        return code.isEmpty && !isLocked && successStagger == -1
    }

    /// Invisible TextField that actually owns focus and input. Its value is
    /// bound to `code`; visible UI mirrors it. `.oneTimeCode` is the ONLY
    /// way to opt into iOS QuickType SMS/email autofill.
    private var hiddenCodeField: some View {
        TextField("", text: Binding(
            get: { code },
            set: { newValue in
                guard !isLocked else { return }
                let digits = newValue.filter(\.isNumber)
                code = String(digits.prefix(codeLength))
                if code.count == codeLength {
                    Task { await triggerVerify() }
                }
            }
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
        .disabled(isLocked)
    }

    /// When the server tells us the code has expired, the cooldown countdown
    /// becomes irrelevant — allow an immediate resend regardless.
    private var canResendImmediately: Bool {
        if case .otpExpired = localError { return true }
        return false
    }

    private var resendButton: some View {
        HStack(spacing: 6) {
            Text("Didn't get it?")
                .font(.custom("Inter-Regular", size: 13))
                .foregroundColor(Color(hex: "6B6B6B"))
            Button {
                Task { await triggerResend() }
            } label: {
                let blocked = (!canResendImmediately && resendCountdown > 0) || isLocked
                Text((!canResendImmediately && resendCountdown > 0) ? "Resend in \(resendCountdown)s" : "Resend code")
                    .font(.custom("SpaceGrotesk-Medium", size: 13))
                    .foregroundColor(blocked ? Color(hex: "4A4A4A") : Color(hex: "F5F0E8"))
            }
            .disabled((!canResendImmediately && resendCountdown > 0) || resendInFlight || isLocked)
        }
    }

    // MARK: - Logic

    /// Prefer our own typed local error first; fall back to whatever the
    /// service published (e.g. a persistent rate limit triggered before
    /// this view ever appeared).
    private var displayedErrorMessage: String? {
        (localError ?? authService.error)?.errorDescription
    }

    private func digitAt(_ index: Int) -> Character? {
        guard index < code.count else { return nil }
        let stringIndex = code.index(code.startIndex, offsetBy: index)
        return code[stringIndex]
    }

    private func triggerVerify() async {
        guard code.count == codeLength, !isVerifying, !isLocked else { return }
        localError = nil
        isVerifying = true
        do {
            try await authService.verifyOTP(email: email, token: code)
            isVerifying = false
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif
            await animateSuccess()
            onVerified?()
        } catch let err as DPAuthError {
            isVerifying = false
            localError = err
            // On expired code: keep the field editable so the user can tap
            // Resend without being forced back to the email screen.
            // On lockout: the field disables itself via isLocked.
            // On mismatch: clear digits so the user types fresh.
            switch err {
            case .otpExpired:
                // Don't clear — user needs to resend, not retype the same code.
                code = ""
                codeFieldFocused = false
            case .otpLocked:
                code = ""
                codeFieldFocused = false
            default:
                code = ""
                codeFieldFocused = true
            }
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            #endif
        } catch {
            isVerifying = false
            localError = .unknown(message: error.localizedDescription)
            code = ""
            codeFieldFocused = true
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            #endif
        }
    }

    /// Sniff the clipboard exactly once, on view appear, for a 6-digit code.
    /// Kept synchronous (no `detectPatterns`) to avoid Apple's "Paste" toast
    /// — reading `pasteboard.string` doesn't surface it on iOS 16+ when the
    /// value is read outside an edit action.
    private func detectClipboardCode() {
        #if canImport(UIKit)
        guard !isLocked, code.isEmpty else { return }
        guard let raw = UIPasteboard.general.string else { return }
        let digits = raw.filter(\.isNumber)
        guard digits.count == codeLength else { return }
        clipboardCode = digits
        #endif
    }

    /// 350ms "win" animation: cells flip to success green one-by-one, 50ms
    /// per cell, then the parent dismisses. The stagger gives the eye a
    /// moment to register success before the sheet collapses.
    private func animateSuccess() async {
        clipboardCode = nil
        for index in 0..<codeLength {
            withAnimation(.easeOut(duration: 0.15)) {
                successStagger = index
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    private func triggerResend() async {
        guard (resendCountdown == 0 || canResendImmediately), !resendInFlight, !isLocked else { return }
        resendInFlight = true
        localError = nil
        defer { resendInFlight = false }
        do {
            // Bypass client-side cooldown when server-confirmed expiry: the
            // user already knows their code is dead, so don't make them wait.
            if canResendImmediately {
                // Reset the stored send timestamp so sendOTP cooldown passes.
                authService.resetResendCooldown(email: email)
            }
            try await authService.sendOTP(email: email)
            code = ""
            codeFieldFocused = true
            startResendCountdown()
        } catch let err as DPAuthError {
            localError = err
            if case .rateLimited(let seconds) = err {
                resendCountdown = seconds
                restartTickingTimer()
            }
        } catch {
            localError = .unknown(message: error.localizedDescription)
        }
    }

    /// Initialize the resend countdown from the service's persistent state
    /// so dismissing and re-entering this view never resets to a fresh 60s.
    private func startResendCountdown() {
        stopResendCountdown()
        resendCountdown = authService.resendCooldownRemaining(email: email)
        guard resendCountdown > 0 else { return }
        restartTickingTimer()
    }

    private func restartTickingTimer() {
        resendTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { t in
            Task { @MainActor in
                if resendCountdown > 0 {
                    resendCountdown -= 1
                } else {
                    t.invalidate()
                }
            }
        }
        resendTimer = timer
    }

    private func stopResendCountdown() {
        resendTimer?.invalidate()
        resendTimer = nil
    }
}
