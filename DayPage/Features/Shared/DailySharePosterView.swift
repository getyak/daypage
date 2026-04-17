import SwiftUI

// MARK: - DailySharePosterView
//
// Offline-rendered brand card for sharing via UIHostingController + drawHierarchy.
// Uses system fonts only — custom fonts fail in off-screen render contexts.

struct DailySharePosterView: View {

    let monthTitle: String
    let totalEntries: Int
    let totalPhotos: Int
    let totalVoiceMinutes: Int
    let totalLocations: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // MARK: Header
            HStack(alignment: .center) {
                Text("DAYPAGE")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "1a1a1a"))
                    .kerning(2)
                Spacer()
                Text(monthTitle)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(Color(hex: "888888"))
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 20)

            Color(hex: "e0e0e0").frame(height: 1).padding(.horizontal, 24)

            // MARK: Stats Grid
            VStack(spacing: 1) {
                HStack(spacing: 1) {
                    statCell(label: "ENTRIES", value: "\(totalEntries)")
                    statCell(label: "PHOTOS", value: "\(totalPhotos)")
                }
                HStack(spacing: 1) {
                    statCell(label: "VOICE", value: "\(totalVoiceMinutes)", unit: "MIN")
                    statCell(label: "LOCATIONS", value: "\(totalLocations)")
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)

            Color(hex: "e0e0e0").frame(height: 1).padding(.horizontal, 24)

            // MARK: Footer
            HStack {
                Spacer()
                Text("daypage.app")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(Color(hex: "bbbbbb"))
                    .kerning(1)
                Spacer()
            }
            .padding(.vertical, 16)
        }
        .background(Color(hex: "f9f9f9"))
        .frame(width: 390)
    }

    private func statCell(label: String, value: String, unit: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(Color(hex: "888888"))
                .kerning(0.5)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(Color(hex: "8B6F4E"))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                if let unit {
                    Text(unit)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundColor(Color(hex: "888888"))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 20)
    }
}
