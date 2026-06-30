import SwiftUI
import DayPageModels
import DayPageStorage

// MARK: - MacTodayView

/// Minimal macOS Today view. A header showing today's date, a multi-line
/// input field, and a chronological list of memos already written today.
/// Saves to vault/raw/YYYY-MM-DD.md through the same RawStorage call iOS uses.
struct MacTodayView: View {

    @State private var memos: [Memo] = []
    @State private var draft: String = ""
    @State private var saveError: String?
    @FocusState private var inputFocused: Bool

    private let today = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 16)

            Divider()

            if memos.isEmpty {
                emptyState
            } else {
                memoList
            }

            Divider()

            composer
                .padding(20)
        }
        .navigationTitle("今天")
        .onAppear(perform: refresh)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(weekdayString)
                .font(.title2.weight(.semibold))
            Text(dateString)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var weekdayString: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "EEEE"
        return f.string(from: today)
    }

    private var dateString: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy 年 M 月 d 日"
        return f.string(from: today)
    }

    // MARK: - Empty / list

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("今天还没有记录")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("在下面写一条试试。")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var memoList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(memos) { memo in
                    memoRow(memo)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    private func memoRow(_ memo: Memo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(memo.body)
                .font(.body)
                .textSelection(.enabled)
            Text(timeString(memo.created))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 80, maxHeight: 160)
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .focused($inputFocused)

            HStack {
                if let err = saveError {
                    Text(err).font(.callout).foregroundStyle(.red)
                }
                Spacer()
                Button("保存", action: save)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - Actions

    private func refresh() {
        do {
            memos = try RawStorage.read(for: today)
                .sorted(by: { $0.created < $1.created })
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
