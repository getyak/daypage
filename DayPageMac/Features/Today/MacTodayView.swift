import SwiftUI
import DayPageModels
import DayPageStorage

// MARK: - MacTodayView

/// macOS Today view. Composer pinned at the top, then a scrollable feed of
/// memos. Visual language is intentionally close to Bear / Things 3 / flomo
/// Mac: hairline borders, generous whitespace, no heavy chrome. Focus is
/// signalled by a soft inner fill + ultra-thin shadow, never by a 2pt
/// coloured stroke.
struct MacTodayView: View {

    @State private var memos: [Memo] = []
    @State private var draft: String = ""
    @State private var saveError: String?
    @FocusState private var composerFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Composer(
                    text: $draft,
                    focused: $composerFocused,
                    onSubmit: save,
                    errorText: saveError
                )
                .padding(.horizontal, 32)
                .padding(.top, 24)

                if memos.isEmpty {
                    EmptyStateView()
                        .padding(.horizontal, 32)
                        .padding(.top, 32)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(memos.enumerated()), id: \.element.id) { index, memo in
                            MemoRow(memo: memo)
                                .padding(.horizontal, 32)
                                .padding(.vertical, 28)
                            if index < memos.count - 1 {
                                Rectangle()
                                    .fill(Color.primary.opacity(0.06))
                                    .frame(height: 1)
                                    .padding(.horizontal, 32)
                            }
                        }
                    }
                    .padding(.bottom, 48)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle("今天")
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .flomoFocusComposer)) { _ in
            composerFocused = true
        }
    }

    // MARK: - Actions

    private func refresh() {
        do {
            memos = try RawStorage.read(for: Date())
                .sorted(by: { $0.created > $1.created })
        } catch {
            saveError = "读取今天的 memo 失败：\(error.localizedDescription)"
        }
    }

    private func save() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let memo = Memo(type: .text, created: Date(), body: text)
        do {
            try RawStorage.append(memo)
            withAnimation(.easeOut(duration: 0.18)) {
                draft = ""
                saveError = nil
            }
            refresh()
        } catch {
            saveError = "保存失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - Composer

/// Capture card pinned at the top of Today. Feels like a sheet of paper
/// resting on the canvas: hairline border, soft fill that lifts a notch when
/// focused, ultra-subtle shadow. No accent-coloured stroke — the cursor
/// itself is the focus marker.
private struct Composer: View {

    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var onSubmit: () -> Void
    var errorText: String?

    /// Single-source-of-truth accent. Used only for the send button when armed
    /// and for the ⌘↩ hint — never for the card border.
    private static let accent = Color(red: 0.30, green: 0.78, blue: 0.55)

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            editor
            toolbar
        }
        .background(cardFill)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(focused.wrappedValue ? 0.12 : 0.08), lineWidth: 1)
        )
        .shadow(
            color: Color.black.opacity(focused.wrappedValue ? 0.06 : 0.0),
            radius: focused.wrappedValue ? 12 : 0,
            x: 0,
            y: focused.wrappedValue ? 4 : 0
        )
        .animation(.easeOut(duration: 0.18), value: focused.wrappedValue)
    }

    // MARK: Editor

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 14))
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)
                .frame(minHeight: 96, maxHeight: 280)
                .focused(focused)

            // Placeholder. Aligned to TextEditor's intrinsic ~5pt internal
            // horizontal inset so the placeholder sits exactly where the
            // cursor will land.
            if text.isEmpty {
                Text("What's on your mind?")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 21)
                    .padding(.top, 24)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 4) {
            ToolbarButton(icon: "number", tooltip: "插入标签") { insertInline("#") }
            ToolbarButton(icon: "photo", tooltip: "添加图片（待实装）") { /* TODO: photo */ }
            divider
            ToolbarButton(icon: "textformat.size", tooltip: "加粗") { wrapSelection(with: "**") }
            ToolbarButton(icon: "list.bullet", tooltip: "项目符号列表") { insertLinePrefix("- ") }
            ToolbarButton(icon: "list.number", tooltip: "编号列表") { insertLinePrefix("1. ") }
            divider
            ToolbarButton(icon: "at", tooltip: "提及（待实装）") { /* TODO: mention */ }

            Spacer(minLength: 8)

            if let err = errorText {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if focused.wrappedValue && canSubmit {
                Text("⌘↩ 发送")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
            }

            sendButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.05))
                .frame(height: 1)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 4)
    }

    private var sendButton: some View {
        Button(action: onSubmit) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(canSubmit ? Color.white : Color.primary.opacity(0.25))
                .frame(width: 28, height: 28)
                .background(canSubmit ? Self.accent : Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!canSubmit)
        .animation(.easeOut(duration: 0.15), value: canSubmit)
    }

    // MARK: Card fill — slightly warmer than canvas when focused

    private var cardFill: some View {
        Color(nsColor: .textBackgroundColor)
            .overlay(Color.primary.opacity(focused.wrappedValue ? 0.02 : 0.0))
    }

    // MARK: Text helpers

    private func insertInline(_ s: String) {
        text.append(text.isEmpty || text.hasSuffix("\n") || text.hasSuffix(" ") ? s : " \(s)")
        focused.wrappedValue = true
    }

    private func insertLinePrefix(_ s: String) {
        if text.isEmpty || text.hasSuffix("\n") {
            text.append(s)
        } else {
            text.append("\n\(s)")
        }
        focused.wrappedValue = true
    }

    private func wrapSelection(with marker: String) {
        // TextEditor exposes no selection API on macOS 12 → append a stub the
        // user can fill in. Cheap but predictable.
        text.append(text.isEmpty ? "\(marker)\(marker)" : " \(marker)\(marker)")
        focused.wrappedValue = true
    }
}

// MARK: - ToolbarButton

private struct ToolbarButton: View {
    let icon: String
    let tooltip: String
    var action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(hovered ? Color.primary.opacity(0.85) : Color.primary.opacity(0.55))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(hovered ? 0.06 : 0.0))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(tooltip)
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

// MARK: - EmptyStateView

private struct EmptyStateView: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
            Text("今天还没有记录。在上方写下一个念头吧。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - MemoRow

/// One memo row: monospaced timestamp + `···` overflow on the same line, then
/// markdown body. The row owns no background — page whitespace and the
/// parent's hairline rule do the separation.
private struct MemoRow: View {

    let memo: Memo

    @State private var menuHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(timestamp)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .tracking(0.2)
                Spacer()
                Menu {
                    Button("复制正文") { copyBody() }
                    Button("复制时间戳") { copyTimestamp() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(menuHovered ? .secondary : .tertiary)
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .onHover { menuHovered = $0 }
            }

            MarkdownText(memo.body)
                .font(.system(size: 14))
                .lineSpacing(7)
                .textSelection(.enabled)
        }
    }

    private var timestamp: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: memo.created)
    }

    private func copyBody() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(memo.body, forType: .string)
    }

    private func copyTimestamp() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(timestamp, forType: .string)
    }
}

// MARK: - MarkdownText

/// Lightweight markdown renderer for memo bodies. Splits on newlines and:
///   - lines starting with `- ` or `* ` → bullet row with `•` glyph
///   - line equal to `---` → Divider
///   - other lines → `Text(.init(line))` which renders **bold**, *italic*,
///     [link](url), inline code via SwiftUI's built-in AttributedString parser
private struct MarkdownText: View {

    let raw: String

    init(_ raw: String) { self.raw = raw }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { i in
                blocks[i].view
            }
        }
    }

    private enum Block: Identifiable {
        case paragraph(String)
        case bullet(String)
        case divider

        var id: String {
            switch self {
            case .paragraph(let s): return "p:\(s)"
            case .bullet(let s):    return "b:\(s)"
            case .divider:          return "d:divider"
            }
        }

        @ViewBuilder var view: some View {
            switch self {
            case .paragraph(let s):
                Text(.init(s))
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .bullet(let s):
                HStack(alignment: .top, spacing: 8) {
                    Text("•").foregroundStyle(.secondary)
                    Text(.init(s)).frame(maxWidth: .infinity, alignment: .leading)
                }
            case .divider:
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 1)
                    .padding(.vertical, 4)
            }
        }
    }

    private var blocks: [Block] {
        var out: [Block] = []
        for rawLine in raw.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line == "---" {
                out.append(.divider)
            } else if line.hasPrefix("- ") {
                out.append(.bullet(String(line.dropFirst(2))))
            } else if line.hasPrefix("* ") {
                out.append(.bullet(String(line.dropFirst(2))))
            } else {
                out.append(.paragraph(line))
            }
        }
        return out
    }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted by the ⌘N menu command in `MacRootView` → focuses the composer.
    static let flomoFocusComposer = Notification.Name("DayPageMac.flomoFocusComposer")
}
