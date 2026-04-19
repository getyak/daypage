import SwiftUI

// MARK: - EmailAuthView

struct EmailAuthView: View {

    @EnvironmentObject private var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var sent = false

    private var isValidEmail: Bool {
        let regex = #"^[^@]+@[^@]+\.[^@]+$"#
        return email.range(of: regex, options: .regularExpression) != nil
    }

    var body: some View {
        ZStack {
            Color(hex: "0A0A0A").ignoresSafeArea()

            // Grain overlay
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

            VStack(alignment: .leading, spacing: 0) {
                // Back button
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .foregroundColor(Color(hex: "6B6B6B"))
                        .font(.system(size: 18, weight: .medium))
                }
                .padding(.top, 16)

                Spacer().frame(height: 32)

                // Heading
                Text("Enter your email")
                    .font(.custom("SpaceGrotesk-Bold", size: 24))
                    .foregroundColor(Color(hex: "F5F0E8"))
                    .padding(.bottom, 24)

                if sent {
                    // Success state
                    Text("Check your inbox — a magic link is on its way.")
                        .font(.custom("SpaceGrotesk-Regular", size: 16))
                        .foregroundColor(Color(hex: "A0A0A0"))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                } else {
                    // Email field
                    TextField("", text: $email)
                        .font(.custom("Inter-Regular", size: 17))
                        .foregroundColor(Color(hex: "F5F0E8"))
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 16)
                        .frame(height: 52)
                        .background(Color(hex: "1E1E1E"))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(hex: "2A2A2A"), lineWidth: 1)
                        )

                    Spacer().frame(height: 16)

                    // Error
                    if let error = authService.error {
                        Text(error)
                            .font(.system(size: 14))
                            .foregroundColor(Color(hex: "E05A5A"))
                            .padding(.bottom, 8)
                    }

                    // Send button
                    Button {
                        Task {
                            do {
                                try await authService.signInWithMagicLink(email: email)
                                sent = true
                            } catch {
                                // error published by AuthService
                            }
                        }
                    } label: {
                        Text("Send Magic Link")
                            .font(.custom("SpaceGrotesk-Medium", size: 16))
                            .foregroundColor(isValidEmail ? Color(hex: "0A0A0A") : Color(hex: "4A4A4A"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(isValidEmail ? Color(hex: "F5F0E8") : Color(hex: "1A1A1A"))
                            .cornerRadius(14)
                    }
                    .disabled(!isValidEmail || authService.isLoading)
                }

                Spacer()
            }
            .padding(.horizontal, 24)
        }
    }
}
