import SwiftUI
import UIKit

/// The established DayPage warm-paper palette. The local storage boundary does
/// not imply a new visual system; keep the same reading scale and amber actions.
enum NotebookTheme {
  static let paper = adaptive(0xFAF8F6, 0x1A1814)
  static let card = adaptive(0xFFFFFF, 0x1F1C18)
  static let ink = adaptive(0x241B10, 0xF0E8DC)
  static let secondary = ink.opacity(0.75)
  static let muted = adaptive(0x79736C, 0xB7AFA3)
  static let faint = ink.opacity(0.28)
  static let line = ink.opacity(0.09)
  static let accent = adaptive(0xA8541B, 0xE5A16A)
  static let accentSoft = adaptive(0xF2E8E0, 0x30251D)
  static let readingAccent = adaptive(0x5D3000, 0xD9975A)
  static let gold = accent
  static let spine = adaptive(0xEEE8E2, 0x24211C)
  static let spineTop = spine
  static let spineInk = ink
  static let spineMuted = muted
  static let spineSelection = accent.opacity(0.10)

  static func reading(_ size: CGFloat = 17, text: String? = nil) -> Font {
    let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
      || text?.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) == true
    return .custom(chinese ? "SourceHanSerifSC-Regular" : "SourceSerif4-Regular",
                   size: size, relativeTo: .body)
  }

  static func mono(_ size: CGFloat = 11) -> Font {
    .custom("Menlo-Regular", size: size, relativeTo: .caption)
  }

  private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
    func value(_ rgb: UInt32) -> UIColor {
      UIColor(red: CGFloat((rgb >> 16) & 255) / 255,
              green: CGFloat((rgb >> 8) & 255) / 255,
              blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
    return Color(UIColor { $0.userInterfaceStyle == .dark ? value(dark) : value(light) })
  }
}

struct NotebookCircleButton: View {
  let icon: String
  let label: LocalizedStringKey
  var action: () -> Void
  var body: some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: 18, weight: .regular))
        .foregroundStyle(NotebookTheme.muted)
        .frame(width: 44, height: 44)
        .background(NotebookTheme.accentSoft.opacity(0.8), in: Circle())
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }
}

extension View {
  func notebookSurface() -> some View {
    background(NotebookTheme.paper.ignoresSafeArea())
      .foregroundStyle(NotebookTheme.ink)
  }
}

enum NotebookDate {
  static func day(_ date: Date) -> String {
    date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).locale(Locale(identifier: "sv_SE")))
  }
  static func title(_ day: String) -> String {
    guard let date = date(day) else { return day }
    return date.formatted(.dateTime.month(.wide).day())
  }
  static func date(_ day: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: day)
  }
}
