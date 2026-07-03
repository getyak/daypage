import SwiftUI

// MARK: - AppError

/// Issue #6 · 错误提示可操作化 (2026-07-03).
///
/// The 3-part error contract from the product-experience backlog:
///
///   发生了什么 → 为什么 → 用户可以怎么做
///
/// Existing surfaces present errors as ad-hoc `Alert(title:message:)`
/// blobs where the message is either "Something went wrong" or a raw
/// interpolated network error. Neither shape gives the user a next step,
/// so they bounce off and re-try blindly.
///
/// `AppError` codifies the shape so any surface can render an error the
/// same way. The payload is view-agnostic — it can drive an `Alert`,
/// an inline banner, or a toast; each surface picks which fields fit.
/// `title` + `reason` are always mandatory; the two actions are
/// optional so a caller can express "informational-only" (both nil),
/// "retry-able" (primary only), or "dual choice" (primary + secondary).

struct AppError: Identifiable, Equatable {

    let id: UUID
    /// One-line "发生了什么" — 4-8 Chinese chars. Shown as headline.
    let title: String
    /// One or two lines "为什么" — user-understandable, not a stack trace.
    let reason: String
    /// Primary CTA — the recommended next step. Nil = no action row.
    let primary: Action?
    /// Secondary CTA — usually "取消 / 稍后再说 / 复制详情".
    let secondary: Action?

    init(
        id: UUID = UUID(),
        title: String,
        reason: String,
        primary: Action? = nil,
        secondary: Action? = nil
    ) {
        self.id = id
        self.title = title
        self.reason = reason
        self.primary = primary
        self.secondary = secondary
    }

    struct Action: Equatable {
        let label: String
        /// Stored via reference-type wrapper so the containing struct can
        /// synthesize Equatable (needed for SwiftUI alert(item:) rebind).
        let handler: ActionHandler
        var perform: () -> Void { handler.perform }

        init(label: String, perform: @escaping () -> Void) {
            self.label = label
            self.handler = ActionHandler(perform: perform)
        }

        static func == (lhs: Action, rhs: Action) -> Bool {
            lhs.label == rhs.label && lhs.handler === rhs.handler
        }
    }

    final class ActionHandler {
        let perform: () -> Void
        init(perform: @escaping () -> Void) { self.perform = perform }
    }
}

// MARK: - View modifier

extension View {
    /// `.appErrorAlert($appError)` — bind an optional `AppError` and get a
    /// consistent title / message / two-button alert for free.
    func appErrorAlert(_ error: Binding<AppError?>) -> some View {
        alert(
            error.wrappedValue?.title ?? "",
            isPresented: Binding(
                get: { error.wrappedValue != nil },
                set: { if !$0 { error.wrappedValue = nil } }
            ),
            presenting: error.wrappedValue,
            actions: { err in
                if let primary = err.primary {
                    Button(primary.label) {
                        primary.perform()
                        error.wrappedValue = nil
                    }
                }
                if let secondary = err.secondary {
                    Button(secondary.label, role: .cancel) {
                        secondary.perform()
                        error.wrappedValue = nil
                    }
                } else if err.primary == nil {
                    Button("好") { error.wrappedValue = nil }
                }
            },
            message: { err in
                Text(err.reason)
            }
        )
    }
}

// MARK: - Factories

extension AppError {
    /// AI compile failed because the device is offline.
    /// Primary CTA: retry now. Secondary: dismiss.
    static func compileOfflineRetry(_ retry: @escaping () -> Void) -> AppError {
        AppError(
            title: "AI 服务不可达",
            reason: "网络断开了。今天的记录已经安全存在本地，等回到网络时会自动重编译。",
            primary: Action(label: "现在重试", perform: retry),
            secondary: Action(label: "稍后再说", perform: {})
        )
    }

    /// AI compile failed for reasons other than offline (usually LLM 4xx/5xx).
    static func compileServerError(detail: String, retry: @escaping () -> Void) -> AppError {
        AppError(
            title: "AI 编译失败",
            reason: "服务端返回了错误：\(detail.prefix(120))。已经记住原文，你可以现在再试一次。",
            primary: Action(label: "重试", perform: retry),
            secondary: Action(label: "先跳过", perform: {})
        )
    }

    /// Voice transcript upload/API failure.
    static func voiceTranscribeFailed(retry: @escaping () -> Void) -> AppError {
        AppError(
            title: "语音转写失败",
            reason: "音频已完整保存，只是 Whisper 那一步没走通。可以立刻再试，或者晚点让 App 自动补。",
            primary: Action(label: "再试一次", perform: retry),
            secondary: Action(label: "稍后自动重试", perform: {})
        )
    }
}
