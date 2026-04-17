import SwiftUI

// MARK: - DayDetailView

/// Unified detail view for a calendar date in Archive.
/// Shows a segment switcher between compiled Daily Page and raw memos.
struct DayDetailView: View {

    let dateString: String

    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable {
        case daily = "Daily Page"
        case raw = "原始 Memo"
    }

    @State private var selectedTab: Tab = .daily

    private var isDailyCompiled: Bool {
        let url = VaultInitializer.vaultURL
            .appendingPathComponent("wiki/daily/\(dateString).md")
        return FileManager.default.fileExists(atPath: url.path)
    }

    private var hasMemos: Bool {
        let url = VaultInitializer.vaultURL
            .appendingPathComponent("raw/\(dateString).md")
        return FileManager.default.fileExists(atPath: url.path)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Segment control
                Picker("Tab", selection: $selectedTab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(DSColor.surfaceContainerLow)

                Divider().background(DSColor.outline)

                // Content
                Group {
                    switch selectedTab {
                    case .daily:
                        dailyContent
                    case .raw:
                        rawContent
                    }
                }
            }
            .navigationTitle(formattedTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(DSColor.onSurface)
                    }
                }
            }
            .background(DSColor.background)
            .onAppear {
                // Default to raw tab when not compiled
                if !isDailyCompiled {
                    selectedTab = .raw
                }
            }
        }
    }

    // MARK: - Daily Content

    @ViewBuilder
    private var dailyContent: some View {
        if isDailyCompiled {
            DailyPageView(dateString: dateString)
        } else {
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "doc.text")
                    .font(.system(size: 40))
                    .foregroundColor(DSColor.onSurfaceVariant.opacity(0.5))
                Text("这一天还没编译")
                    .headlineCapsStyle()
                    .foregroundColor(DSColor.onSurfaceVariant)
                if hasMemos {
                    Button(action: { selectedTab = .raw }) {
                        Text("查看原始 Memo")
                            .font(.custom("JetBrainsMono-Regular", fixedSize: 13))
                            .foregroundColor(DSColor.primary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(DSColor.primary, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Raw Content

    @ViewBuilder
    private var rawContent: some View {
        if hasMemos {
            RawMemoView(dateString: dateString)
        } else {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "tray")
                    .font(.system(size: 40))
                    .foregroundColor(DSColor.onSurfaceVariant.opacity(0.5))
                Text("这一天没有记录")
                    .headlineCapsStyle()
                    .foregroundColor(DSColor.onSurfaceVariant)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Helpers

    private var formattedTitle: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        guard let date = fmt.date(from: dateString) else { return dateString }
        let out = DateFormatter()
        out.dateFormat = "MM.dd"
        out.locale = Locale(identifier: "zh_CN")
        return out.string(from: date)
    }
}
