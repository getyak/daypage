import DayPageCore
import SwiftUI

struct NotebookSidebar: View {
  @EnvironmentObject private var notebook: NotebookModel
  @Environment(\.dynamicTypeSize) private var typeSize
  @AccessibilityFocusState private var closeFocused: Bool
  @State private var allMonths = false
  let destination: NotebookDestination
  let selectedDay: String
  let onHome: () -> Void
  let onNavigate: (NotebookDestination) -> Void
  let onMonth: (String) -> Void
  let onRediscover: () -> Void
  let onClose: () -> Void

  private var months: [NotebookMonthSummary] {
    allMonths ? notebook.catalog.months : Array(notebook.catalog.months.prefix(4))
  }
  private var canRediscover: Bool {
    notebook.catalog.dayCounts.keys.contains { $0 < NotebookDate.day(Date()) }
  }

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          masthead
          summary
          VStack(spacing: 5) {
            row("Diary", icon: "text.book.closed", selected: destination == .today,
                identifier: "notebook-home", action: onHome)
            row("Archive", icon: "books.vertical", selected: destination == .archive,
                identifier: "sidebar-archive") { onNavigate(.archive) }
          }
          if !months.isEmpty { monthDirectory }
          if canRediscover { rediscover }
          Spacer(minLength: 8)
          VStack(spacing: 2) {
            Rectangle().fill(NotebookTheme.line).frame(height: 1).padding(.bottom, 12)
            row("Feedback", icon: "paperplane", selected: destination == .feedback,
                identifier: "sidebar-feedback") { onNavigate(.feedback) }
            row("Settings", icon: "gearshape", selected: destination == .settings,
                identifier: "sidebar-settings") { onNavigate(.settings) }
          }
          Label("On this device", systemImage: "lock")
            .font(.caption).foregroundStyle(NotebookTheme.muted)
            .padding(.horizontal, 14)
        }
        .frame(minHeight: max(0, geometry.size.height - 48), alignment: .topLeading)
        .padding(.horizontal, 20).padding(.vertical, 24)
      }
      .scrollIndicators(.hidden)
      .background(NotebookTheme.spine.ignoresSafeArea())
      .accessibilityIdentifier("notebook-sidebar")
      .accessibilityAction(.escape, onClose)
      .task { closeFocused = true }
    }
  }

  private var masthead: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: "book.closed")
        .font(.system(size: 23, weight: .light))
        .foregroundStyle(NotebookTheme.readingAccent)
        .frame(width: 48, height: 54)
        .background(NotebookTheme.card.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
          UnevenBookmark().fill(NotebookTheme.accent.opacity(0.75))
            .frame(width: 7, height: 17).padding(.trailing, 9)
        }
        .accessibilityHidden(true)
      Text("DayPage").font(NotebookTheme.reading(26))
        .lineLimit(1).minimumScaleFactor(0.8)
      Spacer(minLength: 0)
      NotebookCircleButton(icon: "xmark", label: "Close sidebar", action: onClose)
        .accessibilityIdentifier("close-sidebar")
        .accessibilityFocused($closeFocused)
    }
  }

  private var summary: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(NotebookTheme.noteCount(notebook.entries.count))
        .font(NotebookTheme.reading(30))
      Text(NotebookTheme.dayCount(notebook.catalog.dayCounts.count))
        .font(.subheadline).foregroundStyle(NotebookTheme.muted)
    }
    .padding(.horizontal, 14).padding(.vertical, 4)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("sidebar-summary")
  }

  private var monthDirectory: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("By month").font(.caption.weight(.medium))
        .foregroundStyle(NotebookTheme.muted).padding(.horizontal, 14)
        .accessibilityAddTraits(.isHeader)
      LazyVStack(spacing: 0) {
        ForEach(months) { month in
          Button { onMonth(month.latestDay) } label: {
            HStack(spacing: 13) {
              Circle().fill(isSelected(month) ? NotebookTheme.accent : NotebookTheme.faint)
                .frame(width: 5, height: 5)
              Text(NotebookDate.monthTitle(month.latestDay))
                .font(.subheadline).multilineTextAlignment(.leading)
              Spacer(minLength: 6)
              Text(month.noteCount.formatted()).font(NotebookTheme.mono())
                .foregroundStyle(NotebookTheme.muted)
            }
            .foregroundStyle(isSelected(month) ? NotebookTheme.readingAccent : NotebookTheme.secondary)
            .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 44)
            .contentShape(Rectangle())
          }
          .buttonStyle(NotebookPressStyle())
          .accessibilityLabel(NotebookDate.monthTitle(month.latestDay) + ", " + NotebookTheme.noteCount(month.noteCount))
          .accessibilityIdentifier("sidebar-month-" + month.id)
          .accessibilityAddTraits(isSelected(month) ? .isSelected : [])
        }
      }
      if notebook.catalog.months.count > 4 {
        Button { allMonths.toggle() } label: {
          Label(allMonths ? "Fewer months" : "All months", systemImage: allMonths ? "chevron.up" : "chevron.down")
            .font(.caption).frame(minHeight: 44, alignment: .leading)
            .padding(.horizontal, 32)
        }
        .buttonStyle(NotebookPressStyle()).foregroundStyle(NotebookTheme.readingAccent)
        .accessibilityIdentifier("sidebar-all-months")
      }
    }
  }

  private var rediscover: some View {
    Button(action: onRediscover) {
      HStack(spacing: 12) {
        Image(systemName: "shuffle").font(.system(size: 18, weight: .light))
          .frame(width: 24)
        VStack(alignment: .leading, spacing: 5) {
          Text("A note to rediscover").font(NotebookTheme.reading(17))
          Text("Let an earlier thought find you.").font(.caption)
            .foregroundStyle(NotebookTheme.muted)
        }
        Spacer(minLength: 0)
        if !typeSize.isAccessibilitySize {
          Image(systemName: "arrow.up.right").font(.caption)
        }
      }
      .foregroundStyle(NotebookTheme.readingAccent)
      .padding(14).frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
      .background(NotebookTheme.card.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
      .contentShape(Rectangle())
    }
    .buttonStyle(NotebookPressStyle())
    .accessibilityIdentifier("sidebar-rediscover")
  }

  private func isSelected(_ month: NotebookMonthSummary) -> Bool {
    destination == .today && selectedDay.hasPrefix(month.id)
  }

  private func row(_ title: LocalizedStringKey, icon: String, selected: Bool,
                   identifier: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 14) {
        Image(systemName: icon).font(.system(size: 19, weight: .regular)).frame(width: 24)
        Text(title).font(.body.weight(selected ? .medium : .regular))
          .multilineTextAlignment(.leading)
        Spacer(minLength: 0)
        if selected {
          RoundedRectangle(cornerRadius: 2).fill(NotebookTheme.accent).frame(width: 3, height: 18)
        }
      }
      .foregroundStyle(selected ? NotebookTheme.readingAccent : NotebookTheme.secondary)
      .padding(.horizontal, 14).padding(.vertical, 12).frame(minHeight: 50)
      .background(selected ? NotebookTheme.spineSelection : .clear,
                  in: RoundedRectangle(cornerRadius: 12))
      .contentShape(Rectangle())
    }
    .buttonStyle(NotebookPressStyle())
    .accessibilityIdentifier(identifier)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

private struct UnevenBookmark: Shape {
  func path(in rect: CGRect) -> Path {
    Path { path in
      path.move(to: .zero)
      path.addLine(to: CGPoint(x: rect.maxX, y: 0))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - 3))
      path.addLine(to: CGPoint(x: 0, y: rect.maxY))
      path.closeSubpath()
    }
  }
}
