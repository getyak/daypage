import SwiftUI

// MARK: - AuthView

struct AuthView: View {

    var onSkip: (() -> Void)? = nil

    @EnvironmentObject private var authService: AuthService
    @State private var showEmailAuth = false
    @GestureState private var applePressed = false
    @GestureState private var emailPressed = false

    var body: some View {
        ZStack {
            // Background
            Color(hex: "0A0A0A")
                .ignoresSafeArea()

            // Grain texture overlay
            Canvas { context, size in
                let cols = Int(size.width / 3)
                let rows = Int(size.height / 3)
                for _ in 0..<(cols * rows / 4) {
                    let x = CGFloat.random(in: 0..<size.width)
                    let y = CGFloat.random(in: 0..<size.height)
                    let dot = Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1))
                    context.fill(dot, with: .color(.white.opacity(0.04)))
                }
            }
            .ignoresSafeArea()
            .blendMode(.overlay)
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                // Wordmark — upper third
                Spacer()
                    .frame(minHeight: 0)

                VStack(spacing: 8) {
                    Text("DayPage")
                        .font(.custom("SpaceGrotesk-Bold", size: 32))
                        .foregroundColor(Color(hex: "F5F0E8"))

                    Text("Every day, captured.")
                        .font(.custom("SpaceGrotesk-Regular", size: 15))
                        .foregroundColor(Color(hex: "6B6B6B"))
                }
                .frame(maxWidth: .infinity)

                Spacer()

                // Error message
                if let errorText = authService.error?.errorDescription {
                    Text(errorText)
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "E05A5A"))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 12)
                }

                // Buttons + skip
                VStack(spacing: 0) {
                    buttonStack

                    Button {
                        onSkip?()
                    } label: {
                        Text("Skip for now")
                            .font(.custom("Inter-Regular", size: 13))
                            .foregroundColor(Color(hex: "4A4A4A"))
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 32)
                }
                .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 0) }
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Loading overlay
            if authService.isLoading {
                ProgressView()
                    .tint(.white)
            }
        }
        .transition(.opacity.animation(.easeOut(duration: 0.4)))
        .sheet(isPresented: $showEmailAuth) {
            EmailAuthView()
        }
    }

    // MARK: - Button Stack

    private var buttonStack: some View {
        VStack(spacing: 12) {
            // Continue with Apple
            authButton(
                icon: "apple.logo",
                label: "Continue with Apple",
                iconColor: .white,
                labelColor: .white,
                background: Color(hex: "1A1A1A"),
                border: Color(hex: "2A2A2A"),
                isPressed: applePressed
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($applePressed) { _, state, _ in state = true }
                    .onEnded { _ in
                        Task { try? await authService.signInWithApple() }
                    }
            )

            // Continue with Email
            authButton(
                icon: "envelope",
                label: "Continue with Email",
                iconColor: Color(hex: "A0A0A0"),
                labelColor: Color(hex: "A0A0A0"),
                background: Color(hex: "0A0A0A"),
                border: Color(hex: "222222"),
                isPressed: emailPressed
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($emailPressed) { _, state, _ in state = true }
                    .onEnded { _ in showEmailAuth = true }
            )
        }
    }

    // MARK: - Auth Button

    private func authButton(
        icon: String,
        label: String,
        iconColor: Color,
        labelColor: Color,
        background: Color,
        border: Color,
        isPressed: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(iconColor)
                .font(.system(size: 17))
            Text(label)
                .font(.custom("SpaceGrotesk-Medium", size: 16))
                .foregroundColor(labelColor)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .background(background)
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(border, lineWidth: 1)
        )
        .scaleEffect(isPressed ? 0.97 : 1.0)
        .animation(.easeOut(duration: 0.1), value: isPressed)
    }
}
