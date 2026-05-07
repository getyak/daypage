import Foundation
import CryptoKit

// MARK: - AuthRateLimiter

/// Manages client-side OTP rate-limiting and lockout state.
/// All sensitive data is stored in Keychain (not UserDefaults) to prevent
/// extraction via device backup or inter-process reads.
///
/// Keys are keyed on SHA-256(normalised-email) so the Keychain never stores PII directly.
@MainActor
final class AuthRateLimiter {

    // MARK: Singleton

    static let shared = AuthRateLimiter()

    // MARK: Constants

    let resendCooldown: TimeInterval = 60
    let otpFailureLimit: Int = 5
    let otpLockDuration: TimeInterval = 30 * 60  // 30 min

    // MARK: Init

    private init() {}

    // MARK: - Resend Cooldown

    /// Seconds remaining before the caller may request a new OTP for `email`.
    /// Returns 0 when the cooldown has expired or was never set.
    func resendCooldownRemaining(email: String) -> Int {
        let key = resendKey(for: email)
        guard let raw = KeychainHelper.get(forKey: key),
              let last = Double(raw), last > 0 else { return 0 }
        let elapsed = Date().timeIntervalSince1970 - last
        let remaining = resendCooldown - elapsed
        return remaining > 0 ? Int(remaining.rounded(.up)) : 0
    }

    /// Records that an OTP was just sent for `email`, starting the cooldown window.
    func recordOTPSent(email: String) {
        let key = resendKey(for: email)
        KeychainHelper.set(String(Date().timeIntervalSince1970), forKey: key)
    }

    /// Clears the resend cooldown for `email`.
    /// Call when the server confirms the current code has expired so the user
    /// can immediately request a new one without waiting.
    func resetResendCooldown(email: String) {
        KeychainHelper.delete(forKey: resendKey(for: email))
    }

    // MARK: - OTP Failure / Lockout

    /// If the email is currently locked out, returns the remaining lock seconds.
    /// Lazily clears expired locks so stale entries don't accumulate.
    func otpLockRemaining(email: String) -> Int? {
        let key = lockUntilKey(for: email)
        guard let raw = KeychainHelper.get(forKey: key),
              let lockUntil = Double(raw), lockUntil > 0 else { return nil }
        let remaining = lockUntil - Date().timeIntervalSince1970
        if remaining <= 0 {
            KeychainHelper.delete(forKey: key)
            KeychainHelper.delete(forKey: failureCountKey(for: email))
            return nil
        }
        return Int(remaining.rounded(.up))
    }

    /// Increments the failure count and applies a lockout if the limit is reached.
    func incrementOTPFailures(email: String) {
        let key = failureCountKey(for: email)
        let current = Int(KeychainHelper.get(forKey: key) ?? "0") ?? 0
        let next = current + 1
        KeychainHelper.set(String(next), forKey: key)
        if next >= otpFailureLimit {
            let unlockAt = Date().timeIntervalSince1970 + otpLockDuration
            KeychainHelper.set(String(unlockAt), forKey: lockUntilKey(for: email))
        }
    }

    /// Clears both the failure counter and any active lock for `email`.
    func resetOTPFailures(email: String) {
        KeychainHelper.delete(forKey: failureCountKey(for: email))
        KeychainHelper.delete(forKey: lockUntilKey(for: email))
    }

    // MARK: - Keychain Key Helpers

    /// SHA-256 hashes the email so Keychain entries never contain raw PII.
    private func emailHash(_ email: String) -> String {
        let normalized = email.lowercased().trimmingCharacters(in: .whitespaces)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func resendKey(for email: String) -> String {
        "auth.otp.lastSentAt.\(emailHash(email))"
    }

    private func failureCountKey(for email: String) -> String {
        "auth.otp.failureCount.\(emailHash(email))"
    }

    private func lockUntilKey(for email: String) -> String {
        "auth.otp.lockUntil.\(emailHash(email))"
    }
}
