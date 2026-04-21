import SwiftUI

// MARK: - EmailAuthView

/// Two-stage email sign-in:
/// 1. Email entry → `sendOTP(email:)`
/// 2. On success, pushes `OTPVerificationView` which owns resend, verify, and error state.
///
/// State lives in `@StateObject EmailAuthViewModel` so dismissing the sheet
/// doesn't silently lose in-flight data. The VM also debounces network
/// activity and exposes a single error channel.
struct EmailAuthView: View {

    @EnvironmentObject private var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @StateObject private var viewModel = EmailAuthViewModel()
    @FocusState private var emailFocused: Bool

    var body: some View {
        ZStack {
            Color(hex: "0A0A0A").ignoresSafeArea()
            grainOverlay

            Group {
                switch viewModel.stage {
                case .email:
                    emailStage
                case .otp:
                    OTPVerificationView(
                        email: viewModel.email,
                        onVerified: { dismiss() },
                        onBack: { viewModel.backToEmailStage() }
                    )
                }
            }
            .environmentObject(authService)
            .animation(.easeOut(duration: 0.25), value: viewModel.stage)
        }
        .task {
            // Hook the VM to the shared AuthService once the view is alive.
            viewModel.bind(authService: authService)
        }
    }

    // MARK: - Email Stage

    private var emailStage: some View {
        VStack(alignment: .leading, spacing: 0) {
            backButton

            Spacer().frame(height: 32)

            Text("Enter your email")
                .font(.custom("SpaceGrotesk-Bold", size: 24))
                .foregroundColor(Color(hex: "F5F0E8"))

            Spacer().frame(height: 8)

            Text("We'll send you a 6-digit code.")
                .font(.custom("Inter-Regular", size: 14))
                .foregroundColor(Color(hex: "6B6B6B"))

            Spacer().frame(height: 24)

            TextField("", text: $viewModel.email, prompt: Text("you@domain.com").foregroundColor(Color(hex: "4A4A4A")))
                .font(.custom("Inter-Regular", size: 17))
                .foregroundColor(Color(hex: "F5F0E8"))
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .focused($emailFocused)
                .onSubmit {
                    Task { await viewModel.sendCode() }
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(Color(hex: "1E1E1E"))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(hex: "2A2A2A"), lineWidth: 1)
                )

            Spacer().frame(height: 16)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "E05A5A"))
                    .padding(.bottom, 8)
            }

            Button {
                Task { await viewModel.sendCode() }
            } label: {
                ZStack {
                    Text("Send Code")
                        .font(.custom("SpaceGrotesk-Medium", size: 16))
                        .foregroundColor(viewModel.isValidEmail ? Color(hex: "0A0A0A") : Color(hex: "4A4A4A"))
                        .opacity(viewModel.isSending ? 0 : 1)

                    if viewModel.isSending {
                        ProgressView()
                            .tint(Color(hex: "0A0A0A"))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(viewModel.isValidEmail ? Color(hex: "F5F0E8") : Color(hex: "1A1A1A"))
                .cornerRadius(14)
            }
            .disabled(!viewModel.isValidEmail || viewModel.isSending)

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .onAppear { emailFocused = true }
    }

    // MARK: - Pieces

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
            dismiss()
        } label: {
            Image(systemName: "chevron.left")
                .foregroundColor(Color(hex: "6B6B6B"))
                .font(.system(size: 18, weight: .medium))
                .padding(.vertical, 6)
        }
    }
}

// MARK: - EmailAuthViewModel

@MainActor
final class EmailAuthViewModel: ObservableObject {

    enum Stage: Equatable {
        case email
        case otp
    }

    @Published var email: String = ""
    @Published var stage: Stage = .email
    @Published var isSending: Bool = false
    @Published var errorMessage: String?

    private weak var authService: AuthService?

    var isValidEmail: Bool {
        let regex = #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#
        return email.range(of: regex, options: .regularExpression) != nil
    }

    func bind(authService: AuthService) {
        self.authService = authService
    }

    func sendCode() async {
        guard isValidEmail, !isSending else { return }
        guard let authService else { return }
        errorMessage = nil
        isSending = true
        defer { isSending = false }
        do {
            try await authService.sendOTP(email: email)
            stage = .otp
            // Clear any stale AuthService.error left over from a previous attempt.
            authService.error = nil
        } catch let err as DPAuthError {
            errorMessage = err.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func backToEmailStage() {
        stage = .email
        authService?.error = nil
        errorMessage = nil
    }
}
