import SwiftUI

// MARK: - OTPVerificationView

/// 6 位邮箱 OTP 输入页面。使用一个不可见的 TextField 来
/// 持有焦点/输入，同时 6 个可见的"单元格"渲染当前状态。这是
/// Apple Messages 验证码 UI 使用的模式 — 它允许 iOS 快速输入
/// 显示短信/邮箱验证码（通过 `.oneTimeCode`），并将
/// 底层数据保存在一个 String 中。
struct OTPVerificationView: View {

    // MARK: Inputs

    let email: String
    /// 验证成功后调用，传入 6 位验证码。父视图可以做出反应
    /// （关闭、导航等）。Session 状态由
    /// `AuthService.session` 通过 `authStateChanges` 发布。
    var onVerified: (() -> Void)? = nil
    /// 返回按钮。退回到 EmailAuthView 以便用户编辑邮箱。
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
    /// 视图出现时从剪贴板检测到的 6 位验证码。
    /// 驱动 "Paste 123456" 胶囊按钮。一旦使用或关闭后置为 nil。
    @State private var clipboardCode: String?
    /// 边框已变为成功绿色的最高单元格索引。
    /// -1 表示动画尚未开始；5 表示所有单元格均为绿色。
    @State private var successStagger: Int = -1
    @FocusState private var codeFieldFocused: Bool

    private let codeLength = 6
    private let successGreen = Color(hex: "6EBE71")

    /// 当用户用完本地 OTP 预算后锁定。禁用
    /// 6 格输入框和重新发送按钮，直到锁定结束。
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

    /// 六个可见单元格，反映 `code` 的值。点击行中任意位置
    /// 重新聚焦隐藏的 TextField 以使键盘重新出现。
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

    /// 当剪贴板中有新的 6 位验证码时，在 OTP 单元格下方显示。
    /// 点击接受 → 自动验证。用户输入任何内容后、
    /// 锁定生效后或验证码被使用后隐藏。
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

    /// 不可见的 TextField，实际持有焦点和输入。其值
    /// 绑定到 `code`；可见 UI 镜像它。`.oneTimeCode` 是
    /// 唯一能让 iOS 快速输入短信/邮箱自动填充生效的方式。
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

    /// 当服务器告知验证码已过期时，冷却倒计时
    /// 不再相关 — 允许立即重新发送。
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

    /// 优先使用我们自己的本地错误；其次回退到
    /// 服务发布的错误（例如在此视图出现之前
    /// 触发的持久速率限制）。
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
            // 对于过期的验证码：保持输入框可编辑，以便用户可以点击
            // 重新发送而不必返回邮箱页面。
            // 对于锁定：输入框通过 isLocked 自行禁用。
            // 对于不匹配：清空数字以便用户重新输入。
            switch err {
            case .otpExpired:
                // 不要清除 — 用户需要重新发送，而不是重新输入相同的验证码。
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

    /// 在视图出现时检查剪贴板中是否有 6 位验证码，只检查一次。
    /// 保持同步（不使用 `detectPatterns`）以避免 Apple 的"粘贴"提示
    /// — 在 iOS 16+ 上，当值在编辑操作之外读取时，
    /// 读取 `pasteboard.string` 不会触发该提示。
    private func detectClipboardCode() {
        #if canImport(UIKit)
        guard !isLocked, code.isEmpty else { return }
        guard let raw = UIPasteboard.general.string else { return }
        let digits = raw.filter(\.isNumber)
        guard digits.count == codeLength else { return }
        clipboardCode = digits
        #endif
    }

    /// 350ms "胜利"动画：单元格逐个变为成功绿色，每个
    /// 单元格 50ms，然后父视图关闭。这种交错效果让用户在
    /// 表单关闭之前有片刻时间看到成功状态。
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
            // 绕过客户端冷却，当服务器确认已过期时：
            // 用户已经知道验证码无效，所以不要让他们等待。
            if canResendImmediately {
                // 重置已存储的发送时间戳，以便 sendOTP 冷却通过。
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

    /// 从服务的持久状态初始化重新发送倒计时，
    /// 这样关闭并重新进入此视图不会重置为全新的 60 秒。
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
