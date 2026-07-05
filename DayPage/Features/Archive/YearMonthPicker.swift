import SwiftUI
import DayPageServices

// MARK: - YearMonthPicker
//
// Fast jump-to-month overlay for the Archive. Replaces the "tap chevron 20
// times" friction for nomad users with months/years of history: a year stepper
// plus a 3×4 grid of the 12 months. Months that already hold entries carry an
// amber dot (sourced from the Archive's pre-scanned raw/daily date sets — no
// extra disk I/O), so the sheet doubles as a year-at-a-glance activity map.
//
// Presented as a custom overlay (scrim + card) rather than a system `.sheet`
// so it can sit lightly over the calendar and animate with the app's own
// Motion curves. Selecting a month calls `onSelect(year, month)` and dismisses.

struct YearMonthPicker: View {

    /// The year currently being browsed in the picker (independent of the
    /// year that is committed — the user can scrub years before picking).
    @State private var browseYear: Int

    /// The month/year that is currently shown in the Archive (highlighted).
    let selectedYear: Int
    let selectedMonth: Int

    /// Set of "yyyy-MM" strings that contain at least one entry. Used to mark
    /// months with an activity dot. Derived once by the caller from the
    /// already-pre-scanned vault date sets.
    let monthsWithEntries: Set<String>

    /// Called with the chosen (year, month) when the user taps a month.
    let onSelect: (Int, Int) -> Void
    /// Called to dismiss without selecting (scrim tap / close button).
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The real current year/month — used to ring "today's" month and to gate
    /// future months (journaling is retrospective; you can't browse ahead).
    private let realYear: Int
    private let realMonth: Int

    /// Earliest year the stepper can reach: the earliest year that holds an
    /// entry, but never later than the currently-selected year (so the picker
    /// can always represent where the user already is). Prevents the user from
    /// scrubbing endlessly into empty past years.
    private var minYear: Int {
        let entryYears = monthsWithEntries.compactMap { Int($0.prefix(4)) }
        let earliestEntry = entryYears.min() ?? selectedYear
        return min(earliestEntry, selectedYear)
    }

    init(
        selectedYear: Int,
        selectedMonth: Int,
        monthsWithEntries: Set<String>,
        onSelect: @escaping (Int, Int) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.selectedYear = selectedYear
        self.selectedMonth = selectedMonth
        self.monthsWithEntries = monthsWithEntries
        self.onSelect = onSelect
        self.onClose = onClose
        _browseYear = State(initialValue: selectedYear)
        let now = Calendar.current.dateComponents([.year, .month], from: Date())
        self.realYear = now.year ?? selectedYear
        self.realMonth = now.month ?? selectedMonth
    }

    var body: some View {
        ZStack {
            // Dim scrim — tap to dismiss.
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }
                .accessibilityLabel(NSLocalizedString("archive.picker.dismiss", comment: "Dismiss month picker"))
                .accessibilityAddTraits(.isButton)

            card
                .padding(.horizontal, 32)
        }
    }

    // MARK: - Card

    private var card: some View {
        VStack(spacing: 20) {
            yearStepper
            monthGrid
        }
        .padding(20)
        // #771: year/month picker card → glass engine (.panel). Engine owns rim.
        .dpGlass(.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.black.opacity(0.18), radius: 24, y: 10)
        // Stop scrim taps from falling through the card.
        .contentShape(Rectangle())
        .onTapGesture { }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Year Stepper

    private var yearStepper: some View {
        HStack(spacing: 0) {
            stepperButton(systemName: "chevron.left", forward: false)
                .accessibilityLabel(NSLocalizedString("archive.picker.prev_year", comment: "Previous year"))
                .opacity(browseYear <= minYear ? 0.3 : 1.0)
                .disabled(browseYear <= minYear)

            Spacer()

            Text(verbatim: String(browseYear))
                .font(DSType.serifDisplay28)
                .foregroundColor(DSColor.inkPrimary)
                .monospacedDigit()
                .animation(reduceMotion ? nil : Motion.fade, value: browseYear)
                .accessibilityLabel(String(format: NSLocalizedString("archive.picker.year_label", comment: "Year %d"), browseYear))

            Spacer()

            stepperButton(systemName: "chevron.right", forward: true)
                .accessibilityLabel(NSLocalizedString("archive.picker.next_year", comment: "Next year"))
                // Never browse a year wholly in the future.
                .opacity(browseYear >= realYear ? 0.3 : 1.0)
                .disabled(browseYear >= realYear)
        }
    }

    private func stepperButton(systemName: String, forward: Bool) -> some View {
        Button {
            Haptics.soft()
            withAnimation(reduceMotion ? nil : Motion.spring) {
                browseYear += forward ? 1 : -1
            }
        } label: {
            Image(systemName: systemName)
                .font(DSType.bodyMD)
                .foregroundColor(DSColor.inkMuted)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Month Grid

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    private var monthGrid: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(1...12, id: \.self) { month in
                monthCell(month)
            }
        }
    }

    @ViewBuilder
    private func monthCell(_ month: Int) -> some View {
        let isSelected = (browseYear == selectedYear && month == selectedMonth)
        let isRealMonth = (browseYear == realYear && month == realMonth)
        let isFuture = browseYear > realYear || (browseYear == realYear && month > realMonth)
        let hasEntries = monthsWithEntries.contains(String(format: "%04d-%02d", browseYear, month))

        Button {
            guard !isFuture else { return }
            Haptics.tapConfirm()
            onSelect(browseYear, month)
        } label: {
            VStack(spacing: 5) {
                Text(Self.monthShortSymbol(month))
                    .monoLabelStyle(size: 11)
                    .foregroundColor(monthTextColor(isSelected: isSelected, isFuture: isFuture))

                // Activity dot — present only when the month holds entries.
                Circle()
                    .fill(isSelected ? Color.white : DSColor.accentOnBg)
                    .frame(width: 4, height: 4)
                    .opacity(hasEntries ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                    .fill(isSelected ? DSColor.amberDeep : DSColor.glassLo)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                    .strokeBorder(
                        isRealMonth ? DSColor.amberAccent : DSColor.glassRim,
                        lineWidth: isRealMonth ? 1.5 : 0.5
                    )
            )
            .opacity(isFuture ? 0.3 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
        .accessibilityLabel(Self.monthFullSymbol(month))
        .accessibilityValue(monthAccessibilityValue(hasEntries: hasEntries, isFuture: isFuture))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func monthTextColor(isSelected: Bool, isFuture: Bool) -> Color {
        if isSelected { return .white }
        if isFuture { return DSColor.inkSubtle }
        return DSColor.inkPrimary
    }

    private func monthAccessibilityValue(hasEntries: Bool, isFuture: Bool) -> String {
        if isFuture { return NSLocalizedString("archive.picker.future_unavailable", comment: "Future month, unavailable") }
        return hasEntries
            ? NSLocalizedString("archive.picker.has_entries", comment: "Has entries")
            : NSLocalizedString("archive.picker.no_entries", comment: "No entries")
    }

    // MARK: - Month Symbols

    /// Localized short month symbol (e.g. "JAN" / "1月"), uppercased for the
    /// app's mono label aesthetic. Uses standalone symbols so they read
    /// correctly out of a date context.
    private static func monthShortSymbol(_ month: Int) -> String {
        let symbols = shortFormatter.shortStandaloneMonthSymbols ?? shortFormatter.shortMonthSymbols
        guard let symbols, month >= 1, month <= symbols.count else { return String(month) }
        return symbols[month - 1].uppercased()
    }

    private static func monthFullSymbol(_ month: Int) -> String {
        let symbols = shortFormatter.standaloneMonthSymbols ?? shortFormatter.monthSymbols
        guard let symbols, month >= 1, month <= symbols.count else { return String(month) }
        return symbols[month - 1]
    }

    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        return f
    }()
}
