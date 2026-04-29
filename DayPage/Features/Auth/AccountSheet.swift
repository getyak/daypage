import SwiftUI

// MARK: - AccountSheet
//
// Redesigned as account list: current account, historical accounts for switching,
// add another account. Sign Out moved to secondary position.

struct AccountSheet: View {

    @EnvironmentObject private var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    /// Placeholder — historical accounts would come from AuthService or Keychain.
    /// For now we show a single "current account" view with demo data.
    /// Replace `mockHistoricalAccounts` with real stored accounts once
    /// multi-account support is wired in.
    private let mockHistoricalAccounts: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(DSColor.outline)
                .frame(width: 36, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 8)

            // Title
            Text("账户")
                .font(.custom("Inter-SemiBold", size: 16))
                .foregroundColor(DSColor.onSurface)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

            // Current account
            currentAccountRow

            if !mockHistoricalAccounts.isEmpty {
                Divider()
                    .padding(.leading, 20)
                    .padding(.vertical, 4)

                // Historical accounts header
                Text("其他账户")
                    .font(.custom("Inter-Medium", size: 13))
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 2)

                ForEach(mockHistoricalAccounts, id: \.self) { email in
                    accountRow(email: email, isCurrent: false)
                }
            }

            Divider()
                .padding(.leading, 20)
                .padding(.vertical, 4)

            // Add another account
            addAccountRow

            Spacer(minLength: 0)

            // Sign Out — secondary position
            signOutRow
                .padding(.bottom, 16)
        }
        .presentationDetents([.fraction(0.55)])
        .presentationDragIndicator(.hidden)
    }

    // MARK: - Current Account

    private var currentAccountRow: some View {
        let email = authService.session?.user.email ?? "—"
        let initial = email.first.map { String($0).uppercased() } ?? "?"
        let provider = authService.loginProvider
        let providerLabel: String = {
            switch provider {
            case .apple: return "Apple 登录"
            case .emailOTP: return "邮箱登录"
            case .unknown: return "当前账户"
            }
        }()
        return HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(DSColor.accentSoft)
                    .frame(width: 40, height: 40)
                Text(initial)
                    .font(.custom("Inter-SemiBold", size: 16))
                    .foregroundColor(DSColor.accentAmber)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(email)
                    .font(.custom("Inter-Medium", size: 14))
                    .foregroundColor(DSColor.onSurface)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Image(systemName: provider == .apple ? "applelogo" : "envelope")
                        .font(.system(size: 11))
                        .foregroundColor(DSColor.onSurfaceVariant)
                    Text(providerLabel)
                        .font(.custom("Inter-Regular", size: 12))
                        .foregroundColor(DSColor.onSurfaceVariant)
                }
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(.green)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(DSColor.surfaceContainerLowest)
    }

    // MARK: - Account Row (for switching)

    private func accountRow(email: String, isCurrent: Bool) -> some View {
        let initial = email.first.map { String($0).uppercased() } ?? "?"
        return Button {
            // Switch account — placeholder
            dismiss()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(DSColor.surfaceSunken)
                        .frame(width: 40, height: 40)
                    Text(initial)
                        .font(.custom("Inter-Medium", size: 14))
                        .foregroundColor(DSColor.onBackgroundMuted)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(email)
                        .font(.custom("Inter-Regular", size: 14))
                        .foregroundColor(DSColor.onBackgroundPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DSColor.onBackgroundSubtle)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Add Another Account

    private var addAccountRow: some View {
        Button {
            // Present sign-in flow — placeholder
            dismiss()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(DSColor.borderDefault, lineWidth: 1.5)
                        .frame(width: 40, height: 40)
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(DSColor.onBackgroundMuted)
                }

                Text("添加另一个账户")
                    .font(.custom("Inter-Regular", size: 14))
                    .foregroundColor(DSColor.onBackgroundMuted)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sign Out

    private var signOutRow: some View {
        Button(role: .destructive) {
            Task {
                try? await authService.signOut()
                UserDefaults.standard.set(false, forKey: "authSkipped")
                dismiss()
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color(hex: "E05A5A"))
                Text("退出登录")
                    .font(.custom("Inter-Regular", size: 14))
                    .foregroundColor(Color(hex: "E05A5A"))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
