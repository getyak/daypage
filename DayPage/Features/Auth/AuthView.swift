import SwiftUI
import DayPageServices

// MARK: - AuthButtonStyle

/// Press-scale style for auth sign-in buttons.
/// Replaces DragGesture so VoiceOver and Switch Control work correctly.
private struct AuthButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - AuthView

struct AuthView: View {

    var onSkip: (() -> Void)? = nil

    @EnvironmentObject private var authService: AuthService
    @StateObject private var viewModel = AuthViewModel()
    @State private var showEmailAuth = false

    var body: some View {
        ZStack {
            DSColor.bgWarm
                .ignoresSafeArea()

            GrainOverlay()

            VStack(spacing: 0) {
                Spacer()
                    .frame(minHeight: 0)

                VStack(spacing: 8) {
                    Text("DayPage")
                        .font(.custom("SpaceGrotesk-Bold", size: 32))
                        .foregroundColor(DSColor.inkPrimary)

                    Text(NSLocalizedString("auth.tagline", comment: "AuthView brand tagline under DayPage logo"))
                        .font(.custom("SpaceGrotesk-Regular", size: 15))
                        .foregroundColor(DSColor.inkSecondary)
                }
                .frame(maxWidth: .infinity)

                Spacer()

                if let errorText = viewModel.errorMessage {
                    Text(errorText)
                        .font(.system(size: 14))
                        .foregroundColor(DSColor.statusError)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 12)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: viewModel.errorMessage)
                }

                VStack(spacing: 0) {
                    buttonStack

                    Button {
                        onSkip?()
                    } label: {
                        Text(NSLocalizedString("auth.skip", comment: "AuthView Skip-login button"))
                            .font(.custom("Inter-Regular", size: 13))
                            .foregroundColor(DSColor.inkMuted)
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 32)
                    .accessibilityLabel(NSLocalizedString("auth.skip.a11y", comment: "VoiceOver label for Skip login"))
                }
                .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 0) }
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if viewModel.isLoading {
                ProgressView()
                    .tint(DSColor.inkPrimary)
            }
        }
        .task {
            viewModel.bind(authService: authService)
        }
        .transition(.opacity.animation(.easeOut(duration: 0.4)))
        .sheet(isPresented: $showEmailAuth) {
            EmailAuthView()
        }
    }

    // MARK: - Button Stack

    private var buttonStack: some View {
        VStack(spacing: 12) {
            Button {
                Task { await viewModel.signInWithApple() }
            } label: {
                authButtonLoadingLabel(
                    icon: "apple.logo",
                    label: "Continue with Apple",
                    iconColor: DSColor.onAmber,
                    labelColor: DSColor.onAmber,
                    background: DSColor.amberDeep,
                    border: DSColor.amberRim,
                    isLoading: viewModel.isLoading
                )
            }
            .buttonStyle(AuthButtonStyle())
            .disabled(viewModel.isLoading)
            .accessibilityLabel(viewModel.isLoading ? "Signing in with Apple" : "Continue with Apple")
            .accessibilityHint("Sign in using your Apple ID")

            Button {
                showEmailAuth = true
            } label: {
                authButtonLabel(
                    icon: "envelope",
                    label: "Continue with Email",
                    iconColor: DSColor.inkSecondary,
                    labelColor: DSColor.inkSecondary,
                    background: DSColor.surfaceWhite,
                    border: DSColor.inkFaint
                )
            }
            .buttonStyle(AuthButtonStyle())
            .disabled(viewModel.isLoading)
            .accessibilityLabel(NSLocalizedString("a11y.continue_email", comment: "Continue with email"))
            .accessibilityHint(NSLocalizedString("a11y.continue_email.hint", comment: "Email OTP sign-in hint"))
        }
    }

    // MARK: - Auth Button Labels

    /// Standard auth button with no loading indicator.
    private func authButtonLabel(
        icon: String,
        label: String,
        iconColor: Color,
        labelColor: Color,
        background: Color,
        border: Color
    ) -> some View {
        authButtonLoadingLabel(
            icon: icon, label: label,
            iconColor: iconColor, labelColor: labelColor,
            background: background, border: border,
            isLoading: false
        )
    }

    /// Auth button that shows an inline ProgressView when `isLoading` is true.
    private func authButtonLoadingLabel(
        icon: String,
        label: String,
        iconColor: Color,
        labelColor: Color,
        background: Color,
        border: Color,
        isLoading: Bool
    ) -> some View {
        ZStack {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                    .font(.system(size: 17))
                Text(label)
                    .font(.custom("SpaceGrotesk-Medium", size: 16))
                    .foregroundColor(labelColor)
            }
            .opacity(isLoading ? 0 : 1)

            if isLoading {
                // Loading spinner sits on the amber-filled CTA — use onAmber
                // (near-white in both schemes) so it stays legible on the fill.
                ProgressView()
                    .tint(DSColor.onAmber)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .background(background)
        .cornerRadius(DSRadius.md)
        .overlay(
            RoundedRectangle(cornerRadius: DSRadius.md)
                .stroke(border, lineWidth: 1)
        )
    }
}
