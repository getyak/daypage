import SwiftUI
import DayPageServices

// MARK: - ThreadConversationView

/// Expandable card that renders a single AI follow-up thread.
/// Shows the question header, the message history, a streaming indicator,
/// and (after the first AI reply) an input row for follow-up questions.
struct ThreadConversationView: View {

    @ObservedObject var vm: ThreadConversationViewModel

    @State private var followUpDraft: String = ""
    @FocusState private var inputFocused: Bool

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            questionHeader
                .padding(.horizontal, DSSpacing.lg)
                .padding(.top, 14)
                .padding(.bottom, DSSpacing.md)

            if vm.isExpanded {
                expandedContent
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(DSColor.surfaceContainerHigh)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
        // Expand/collapse shifts content position (`.move` transition above) —
        // route through the shared `expand` token so it honors Reduce Motion.
        .dsAnimation(Motion.expand, value: vm.isExpanded)
    }

    // MARK: - Question header

    private var questionHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(DSColor.accentOnBg)
                .frame(width: 3, height: 20)

            Text(vm.question ?? "自由追问")
                .font(DSType.serifBody16)
                .foregroundColor(DSColor.inkPrimary)
                .lineLimit(vm.isExpanded ? nil : 2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: toggleExpanded) {
                Image(systemName: vm.isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DSColor.inkMuted)
                    .frame(width: 28, height: 28)
                    .background(DSColor.amberSoft, in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Expanded content

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(DSColor.glassRimD)
                .frame(height: 0.5)
                .padding(.horizontal, DSSpacing.lg)
                .padding(.bottom, DSSpacing.sm)

            if !vm.messages.isEmpty {
                messagesScrollView
                    .padding(.bottom, DSSpacing.xs)
            }

            if vm.isStreaming {
                streamingRow
                    .padding(.horizontal, DSSpacing.lg)
                    .padding(.bottom, DSSpacing.sm)
                    .transition(.opacity)
            }

            if let err = vm.error {
                Text(err)
                    .font(DSType.bodySM)
                    .foregroundColor(DSColor.error)
                    .padding(.horizontal, DSSpacing.lg)
                    .padding(.bottom, DSSpacing.sm)
            }

            let hasReply = vm.messages.contains { $0.role == "assistant" }
            if hasReply && !vm.isStreaming {
                followUpInputRow
                    .padding(.horizontal, DSSpacing.md)
                    .padding(.bottom, DSSpacing.md)
                    .transition(.opacity)
                    .animation(.easeIn(duration: 0.2), value: hasReply)
            }
        }
    }

    // MARK: - Messages scroll view

    private var messagesScrollView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: DSSpacing.sm) {
                ForEach(vm.messages) { msg in
                    MessageBubble(message: msg)
                }
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, DSSpacing.sm)
        }
        .frame(maxHeight: 280)
    }

    // MARK: - Streaming row

    private var streamingRow: some View {
        HStack(alignment: .top, spacing: DSSpacing.sm) {
            aiBadge

            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                if !vm.streamingText.isEmpty {
                    Text(vm.streamingText)
                        .font(DSType.serifBody16)
                        .foregroundColor(DSColor.inkPrimary)
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                TypingIndicator()
            }
        }
    }

    // MARK: - Follow-up input row

    private var followUpInputRow: some View {
        HStack(spacing: 6) {
            TextField("继续追问…", text: $followUpDraft)
                .font(DSType.bodySM)
                .foregroundColor(DSColor.inkPrimary)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { sendFollowUp() }
                .padding(.horizontal, DSSpacing.md)
                .padding(.vertical, DSSpacing.sm)
                .background(DSColor.amberSoft.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            InlineMicButton { transcript in followUpDraft = transcript }

            Button(action: sendFollowUp) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(canSend ? DSColor.accentOnBg : DSColor.inkSubtle)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
    }

    // MARK: - Helpers

    private var canSend: Bool {
        !followUpDraft.trimmingCharacters(in: .whitespaces).isEmpty && !vm.isStreaming
    }

    private var aiBadge: some View {
        Text("AI")
            .font(DSFonts.jetBrainsMono(size: 9, weight: .medium))
            .foregroundColor(DSColor.accentOnBg)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(DSColor.amberSoft)
            .clipShape(Capsule())
    }

    private func toggleExpanded() {
        withAnimation(Motion.respectReduceMotion(Motion.expand)) {
            vm.isExpanded.toggle()
        }
    }

    private func sendFollowUp() {
        let text = followUpDraft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        followUpDraft = ""
        inputFocused = false
        Task { await vm.send(userMessage: text) }
    }
}

// MARK: - MessageBubble

private struct MessageBubble: View {
    let message: ThreadConversationViewModel.Message

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 44) }

            Text(message.text)
                .font(DSType.serifBody16)
                .foregroundColor(isUser ? DSColor.accentOnBg : DSColor.inkPrimary)
                .lineSpacing(5)
                .padding(.horizontal, DSSpacing.md)
                .padding(.vertical, DSSpacing.sm)
                .background(
                    isUser ? DSColor.amberSoft : DSColor.surfaceContainerLowest,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            isUser ? DSColor.amberRim : DSColor.glassRim,
                            lineWidth: 0.5
                        )
                )

            if !isUser { Spacer(minLength: 44) }
        }
    }
}

// MARK: - TypingIndicator

/// Three-dot bounce animation shown while the AI is streaming.
private struct TypingIndicator: View {

    @State private var phase: Int = 0

    private let animationTimer = Timer.publish(every: 0.28, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(DSColor.accentOnBg.opacity(i == phase ? 1.0 : 0.3))
                    .frame(width: 5, height: 5)
                    .scaleEffect(i == phase ? 1.3 : 1.0)
                    .animation(.easeInOut(duration: 0.22), value: phase)
            }
        }
        .onReceive(animationTimer) { _ in phase = (phase + 1) % 3 }
    }
}
