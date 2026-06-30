import SwiftUI
import DayPageModels
import DayPageStorage

// MARK: - MacTodayView (flomo-inspired layout)

/// macOS Today view. Composer pinned at the top (flomo-style — "What's on your
/// mind?" is always the first thing you see), then a scrollable feed of memos
/// below. No card chrome — memos separate by whitespace + hairline divider,
/// which keeps reading density flomo-light.
struct MacTodayView: View {

    @State private var memos: [Memo] = []
    @State private var draft: String = ""
    @State private var saveError: String?
    @FocusState private var composerFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                FlomoComposer(
                    text: $draft,
                    focused: $composerFocused,
                    onSubmit: save,
                    errorText: saveError
                )
                .padding(.horizontal, 32)
                .padding(.top, 24)

                if memos.isEmpty {
                    Text("还没有记录。在上面写一条吧。")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 48)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(memos.enumerated()), id: \.element.id) { index, memo in
                            FlomoMemoRow(memo: memo)
                                .padding(.horizontal, 32)
                                .padding(.vertical, 20)
                            if index < memos.count - 1 {
                                Divider()
                                    .padding(.horizontal, 32)
                            }
                        }
                    }
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
            // Newest first — the freshly written memo lands at the top so the
            // user sees their thought immediately after pressing send.
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
            draft = ""
            saveError = nil
            refresh()
        } catch {
            saveError = "保存失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - FlomoComposer

/// "What's on your mind?" composer pinned at the top. Border lights up green
/// when focused — mirrors the flomo Mac client's focus affordance.
private struct FlomoComposer: View {

    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var onSubmit: () -> Void
    var errorText: String?

    private let accent = Color(red: 0.30, green: 0.78, blue: 0.55)  // flomo-ish green

    var body: some View {
        VStack(spacing: 0) {
            // Text area
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 96, maxHeight: 240)
                .focused(focused)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("What's on your mind?")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 20)
                            .padding(.leading, 17)
                            .allowsHitTesting(false)
                    }
                }

            // Toolbar — visual placeholders for now. Wired in a follow-up.
            HStack(spacing: 14) {
                ToolbarIcon(systemName: "number")
                ToolbarIcon(systemName: "photo")
                Divider().frame(height: 14)
                ToolbarIcon(systemName: "textformat.size")
                ToolbarIcon(systemName: "list.bullet")
                ToolbarIcon(systemName: "list.number")
                Divider().frame(height: 14)
                ToolbarIcon(systemName: "at")

                Spacer()

                if let err = errorText {
                    Text(err)
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                Button(action: onSubmit) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? Color.secondary.opacity(0.3)
                                    : accent)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    focused.wrappedValue ? accent : Color.secondary.opacity(0.25),
                    lineWidth: focused.wrappedValue ? 2 : 1
                )
        )
        .animation(.easeInOut(duration: 0.15), value: focused.wrappedValue)
    }
}

// MARK: - ToolbarIcon

private struct ToolbarIcon: View {
    let systemName: String
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
    }
}

// MARK: - FlomoMemoRow

/// One memo row in the flomo style: full ISO-8601 timestamp + `···` overflow
/// in a single header row, then markdown-rendered body. No background, no
/// rounded corners — separation comes from page whitespace + the hairline
/// Divider provided by the parent.
private struct FlomoMemoRow: View {

    let memo: Memo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(timestamp)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                Menu {
                    Button("复制正文") { copyBody() }
                    Button("复制时间戳") { copyTimestamp() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            MarkdownText(memo.body)
                .font(.body)
                .lineSpacing(6)
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
                Divider().padding(.vertical, 4)
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
