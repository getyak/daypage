import SwiftUI

// MARK: - TimeZonePickerView

struct TimeZonePickerView: View {

    let selected: TimeZone
    let onSelect: (TimeZone) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var allIdentifiers: [String] {
        TimeZone.knownTimeZoneIdentifiers.sorted()
    }

    private var filtered: [String] {
        guard !searchText.isEmpty else { return allIdentifiers }
        let q = searchText.lowercased()
        return allIdentifiers.filter { $0.lowercased().contains(q) }
    }

    var body: some View {
        List(filtered, id: \.self) { id in
            if let tz = TimeZone(identifier: id) {
                Button {
                    onSelect(tz)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(id)
                                .foregroundColor(.primary)
                            Text(tz.localizedLabel)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if tz.identifier == selected.identifier {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "搜索时区")
        .navigationTitle("选择时区")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - TimeZone helpers

extension TimeZone {
    /// Human-readable label: GMT offset + identifier abbreviation.
    var localizedLabel: String {
        let seconds = secondsFromGMT()
        let hours = seconds / 3600
        let minutes = abs((seconds % 3600) / 60)
        let sign = seconds >= 0 ? "+" : "-"
        let offset = String(format: "GMT%@%02d:%02d", sign, abs(hours), minutes)
        let abbrev = abbreviation() ?? identifier
        return "\(offset) · \(abbrev)"
    }
}
