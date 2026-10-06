import SwiftUI
import DayPageServices

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
        TimeZoneSearchResults(identifiers: filtered, selected: selected) { timeZone in
            onSelect(timeZone)
            dismiss()
        }
        .searchable(text: $searchText, prompt: NSLocalizedString("settings.timezone.search", comment: "Time zone picker search"))
        .navigationTitle(NSLocalizedString("settings.timezone.select", comment: "Time zone picker title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}


// Search actions must be read below the searchable modifier, where SwiftUI
// installs their environment. Keep selection and navigation in that order.
private struct TimeZoneSearchResults: View {
    let identifiers: [String]
    let selected: TimeZone
    let onSelect: (TimeZone) -> Void

    @Environment(\.dismissSearch) private var dismissSearch

    var body: some View {
        List(identifiers, id: \.self) { id in
            if let tz = TimeZone(identifier: id) {
                Button {
                    // End the borrowed search field before the picker leaves its
                    // navigation stack. Reading this action above .searchable
                    // would have no effect.
                    dismissSearch()
                    onSelect(tz)
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
