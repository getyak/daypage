import SwiftUI

// MARK: - RawMemoView

/// Displays all raw memos for a given date, sorted chronologically.
/// Used when a date has memos but no compiled Daily Page.
struct RawMemoView: View {

    let dateString: String

    @State private var memos: [Memo] = []
    @State private var isLoading: Bool = true
    @Environment(\.dismiss) private var dismiss

    private var formattedDate: String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parser.date(from: dateString) else { return dateString }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date).uppercased()
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DSColor.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    Divider().background(DSColor.outline)
                    content
                }
            }
            .navigationBarHidden(true)
        }
        .onAppear { loadMemos() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(DSColor.onSurface)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text("RAW MEMOS")
                    .font(.custom("SpaceGrotesk-Bold", size: 16))
                    .foregroundColor(DSColor.onSurface)
                    .kerning(2)
                Text(formattedDate)
                    .font(.custom("JetBrainsMono-Regular", fixedSize: 10))
                    .foregroundColor(DSColor.onSurfaceVariant)
            }

            Spacer()

            StatusBadge(label: "UNCOMPILED", style: .metadata)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            Spacer()
            ProgressView()
                .tint(DSColor.onSurfaceVariant)
            Spacer()
        } else if memos.isEmpty {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "tray")
                    .font(.system(size: 32))
                    .foregroundColor(DSColor.onSurfaceVariant.opacity(0.5))
                Text("该日无记录")
                    .font(.custom("SpaceGrotesk-Bold", size: 14))
                    .foregroundColor(DSColor.onSurfaceVariant)
            }
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(memos.enumerated()), id: \.element.id) { idx, memo in
                        TimelineRow(
                            memo: memo,
                            isLast: idx == memos.count - 1
                        )
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
        }
    }

    // MARK: - Data Loading

    private func loadMemos() {
        isLoading = true
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        let date = parser.date(from: dateString) ?? Date()
        let loaded = (try? RawStorage.read(for: date)) ?? []
        memos = loaded.sorted { $0.created < $1.created }
        isLoading = false
    }
}
