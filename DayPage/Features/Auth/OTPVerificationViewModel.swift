import SwiftUI

// MARK: - OTPVerificationViewModel

/// Owns all mutable state and async logic for the OTP verification screen.
/// Extracted from OTPVerificationView to keep the view a pure render function
/// and to make the timer lifecycle testable.
@MainActor
final class OTPVerificationViewModel: ObservableObject {

    // MARK: Published

    @Published var code: String = ""
    @Published var isVerifying: Bool = false
    @Published var localError: DPAuthError?
    @Published var resendCountdown: Int = 0
    @Published var resendInFlight: Bool = false
    @Published var clipboardCode: String?
    /// Index of the last cell that turned success-green (-1 = not started, 5 = all done).
    @Published var successStagger: Int = -1

    // MARK: Inputs (set once by the view)

    var email: String = ""
    var onVerified: (() -> Void)?
    var onBack: (() -> Void)?

    // MARK: Private

    private weak var authService: AuthService?
    private var resendTimer: Timer?
    private let codeLength = 6

    // MARK: Derived

    var isLocked: Bool {
        if case .otpLocked = localError { return true }
        if case .otpLocked = authService?.error { return true }
        return false
    }

    var canResendImmediately: Bool {
        if case .otpExpired = localError { return true }
        return false
    }

    var displayedErrorMessage: String? {
        (localError ?? authService?.error)?.errorDescription
    }

    var shouldShowPasteCapsule: Bool {
        guard let digits = clipboardCode, digits.count == codeLength else { return false }
        return code.isEmpty && !isLocked && successStagger == -1
    }

    // MARK: - Binding

    func bind(authService: AuthService) {
        self.authService = authService
    }

    // MARK: - Lifecycle

    func onAppear() {
        startResendCountdown()
        detectClipboardCode()
    }

    func onDisappear() {
        stopResendCountdown()
    }

    // MARK: - Code Input

    /// Called by the hidden TextField binding whenever the user types a digit.
    func handleCodeInput(_ newValue: String) {
        guard !isLocked else { return }
        let digits = newValue.filter(\.isNumber)
        code = String(digits.prefix(codeLength))
        if code.count == codeLength {
            Task { await triggerVerify() }
        }
    }

    // MARK: - Verify

    func triggerVerify() async {
        guard let authService else { return }
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
            clearCode()
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            #endif
        } catch {
            isVerifying = false
            localError = .unknown(message: "")
            clearCode()
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            #endif
        }
    }

    private func clearCode() {
        code = ""
    }

    // MARK: - Resend

    func triggerResend() async {
        guard let authService else { return }
        guard (resendCountdown == 0 || canResendImmediately), !resendInFlight, !isLocked else { return }
        resendInFlight = true
        localError = nil
        defer { resendInFlight = false }
        do {
            if canResendImmediately {
                authService.resetResendCooldown(email: email)
            }
            try await authService.sendOTP(email: email)
            code = ""
            startResendCountdown()
        } catch let err as DPAuthError {
            localError = err
            if case .rateLimited(let seconds) = err {
                resendCountdown = seconds
                restartTickingTimer()
            }
        } catch {
            localError = .unknown(message: "")
        }
    }

    // MARK: - Paste Capsule

    func applyClipboardCode() {
        guard let digits = clipboardCode else { return }
        code = digits
        clipboardCode = nil
        Task { await triggerVerify() }
    }

    func dismissPasteCapsule() {
        clipboardCode = nil
    }

    // MARK: - Clipboard Detection

    func detectClipboardCode() {
        guard !isLocked, code.isEmpty else { return }
        guard let raw = UIPasteboard.general.string else { return }
        let digits = raw.filter(\.isNumber)
        guard digits.count == codeLength else { return }
        clipboardCode = digits
    }

    // MARK: - Success Animation

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

    // MARK: - Resend Timer

    private func startResendCountdown() {
        stopResendCountdown()
        resendCountdown = authService?.resendCooldownRemaining(email: email) ?? 0
        guard resendCountdown > 0 else { return }
        restartTickingTimer()
    }

    private func restartTickingTimer() {
        resendTimer?.invalidate()
        resendTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            Task { @MainActor [weak self] in
                guard let self else { t.invalidate(); return }
                if self.resendCountdown > 0 {
                    self.resendCountdown -= 1
                } else {
                    t.invalidate()
                }
            }
        }
    }

    private func stopResendCountdown() {
        resendTimer?.invalidate()
        resendTimer = nil
    }
}
