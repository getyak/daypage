import DayPageCore
import SwiftUI

/// A date choice stays in this sheet until Done commits the exact canonical day.
struct NotebookCalendar: View {
  @EnvironmentObject private var notebook: NotebookModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.calendar) private var calendar
  @Environment(\.locale) private var locale
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ScaledMetric(relativeTo: .body) private var dayFontSize: CGFloat = 17
  @Binding var selectedDay: String
  var onSelect: () -> Void

  @State private var draftDay: String
  @State private var month: NotebookCalendarMonth?
  @State private var noteCounts: [String: Int] = [:]

  init(selectedDay: Binding<String>, onSelect: @escaping () -> Void) {
    _selectedDay = selectedDay
    self.onSelect = onSelect
    _draftDay = State(initialValue: selectedDay.wrappedValue)
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        if let month {
          VStack(spacing: 20) {
            monthHeader(month)
              .padding(.horizontal, 20)
            monthGrid(month)
              .padding(.horizontal, 4)
            selectedDateSummary
              .padding(.horizontal, 20)
          }
          .padding(.vertical, 20)
        }
      }
      .accessibilityIdentifier("notebook-date-picker")
      .notebookSurface()
      .navigationTitle("Choose date")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .accessibilityIdentifier("calendar-cancel")
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            selectedDay = draftDay
            onSelect()
            dismiss()
          }
          .disabled(NotebookCalendarMonth.date(for: draftDay, timeZone: calendar.timeZone) == nil)
          .accessibilityIdentifier("calendar-done")
        }
      }
    }
    .tint(NotebookTheme.accent)
    .onAppear {
      if NotebookCalendarMonth.date(for: draftDay, timeZone: calendar.timeZone) == nil {
        draftDay = today
      }
      showMonth(containing: draftDay)
    }
    .onReceive(notebook.$entries) { entries in
      // Recount when records change, not once per cell or on each month page.
      noteCounts = entries.reduce(into: [:]) { counts, entry in
        counts[entry.day, default: 0] += 1
      }
    }
    .onChange(of: locale.identifier) { _ in refreshMonth() }
    .onChange(of: calendar) { _ in refreshMonth() }
    .accessibilityAction(.escape) { dismiss() }
  }

  private var today: String {
    NotebookCalendarMonth.dayKey(for: Date(), timeZone: calendar.timeZone)
  }

  private func monthHeader(_ month: NotebookCalendarMonth) -> some View {
    VStack(spacing: 8) {
      Text(month.title)
        .font(NotebookTheme.reading(24))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("calendar-month-title")
      HStack(spacing: 16) {
        Button { self.month = month.addingMonths(-1) } label: {
          Image(systemName: "chevron.backward")
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(month.monthKey == "0001-01")
        .accessibilityLabel("Previous month")
        .accessibilityIdentifier("calendar-previous-month")

        Spacer(minLength: 0)
        Button {
          draftDay = today
          showMonth(containing: draftDay)
        } label: {
          Text("Today")
            .font(.body)
            .frame(minHeight: 44)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(NotebookTheme.accent)
        .accessibilityIdentifier("calendar-today")
        Spacer(minLength: 0)

        Button { self.month = month.addingMonths(1) } label: {
          Image(systemName: "chevron.forward")
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(month.monthKey == "9999-12")
        .accessibilityLabel("Next month")
        .accessibilityIdentifier("calendar-next-month")
      }
    }
  }

  private func monthGrid(_ month: NotebookCalendarMonth) -> some View {
    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 0), count: 7), spacing: 4) {
      ForEach(Array(month.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
        Text(symbol)
          .font(.caption)
          .foregroundStyle(NotebookTheme.muted)
          .frame(maxWidth: .infinity, minHeight: 24)
          .accessibilityHidden(true)
      }
      ForEach(month.days.indices, id: \.self) { index in
        if let day = month.days[index] {
          dayButton(day)
        } else {
          Color.clear
            .frame(height: cellHeight)
            .accessibilityHidden(true)
        }
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: draftDay)
  }

  private var cellHeight: CGFloat { max(52, min(dayFontSize, 28) + 28) }

  private func dayButton(_ day: NotebookCalendarMonth.Day) -> some View {
    let count = noteCounts[day.key, default: 0]
    let selected = day.key == draftDay
    let isToday = day.key == today
    return Button {
      draftDay = day.key
    } label: {
      VStack(spacing: 5) {
        Text(day.number.formatted(.number.locale(locale)))
          // Seven columns remain legible at large accessibility sizes; the
          // full date and record count are also available to VoiceOver.
          .font(.system(size: min(dayFontSize, 28), weight: isToday ? .semibold : .regular))
          .foregroundStyle(selected ? NotebookTheme.readingAccent : NotebookTheme.ink)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
        Circle()
          .fill(count > 0 ? NotebookTheme.readingAccent : .clear)
          .frame(width: 5, height: 5)
          .accessibilityHidden(true)
      }
      .frame(maxWidth: .infinity)
      .frame(height: cellHeight)
      .background(selected ? NotebookTheme.accentSoft : .clear)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(selected ? NotebookTheme.accent : .clear, lineWidth: 1.5)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(day.title), \(NotebookTheme.noteCount(count))")
    .accessibilityValue(isToday ? Text("Today") : Text(""))
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityIdentifier("calendar-day-\(day.key)")
  }

  private var selectedDateSummary: some View {
    VStack(spacing: 6) {
      Text(selectedDateTitle)
        .font(NotebookTheme.reading(18))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      Text(NotebookTheme.noteCount(noteCounts[draftDay, default: 0]))
        .font(.subheadline)
        .foregroundStyle(NotebookTheme.secondary)
        .accessibilityIdentifier("calendar-selected-count")
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 12)
    .padding(.bottom, 8)
    .overlay(alignment: .top) { Rectangle().fill(NotebookTheme.line).frame(height: 1) }
  }

  private var selectedDateTitle: String {
    guard let date = NotebookCalendarMonth.date(for: draftDay, timeZone: calendar.timeZone) else {
      return draftDay
    }
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = calendar.timeZone
    formatter.dateStyle = .full
    return formatter.string(from: date)
  }

  private func showMonth(containing day: String) {
    month = NotebookCalendarMonth(containing: day, calendar: calendar, locale: locale)
  }

  private func refreshMonth() {
    showMonth(containing: month?.days.compactMap { $0 }.first?.key ?? draftDay)
  }
}
