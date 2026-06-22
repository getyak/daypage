import SwiftUI

// MARK: - WeeklyRecapDetailView
//
// Detail screen pushed from ArchiveView's weekly recap entry card.
// Loads the cached weekly recap if present, otherwise triggers a fresh
// AI compile. Three states — loading / error / success — are surfaced
// inline rather than via overlay so the screen stays scrollable.
//
// Why a dedicated view (not a sheet): the recap is a first-class artifact
// alongside Daily Page detail screens; reading + recompile should feel
// like a navigated page, not a transient modal.
struct WeeklyRecapDetailView: View {

    let referenceDate: Date

    @State private var output: WeeklyRecapOutput?
    @State private var isLoading: Bool = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if isLoading {
                    loadingState
                } else if let err = error {
                    errorState(message: err)
                } else if let output = output {
                    sections(output: output)
                    refreshButton
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .background(DSColor.backgroundWarm.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(NSLocalizedString("weekly.recap.title", comment: ""))
        .task {
            await loadInitial()
        }
    }

    // MARK: - Header

    private var header: some View {
        let rangeText = output?.dateRange
            ?? Self.fallbackDateRange(for: referenceDate)
        let isoWeek = output?.isoWeek
            ?? WeeklyCompilationService.isoWeekKey(for: referenceDate)

        return VStack(alignment: .leading, spacing: 6) {
            Text("📅 \(NSLocalizedString("weekly.recap.title", comment: ""))")
                .font(DSType.headlineMD)
                .foregroundColor(DSColor.inkPrimary)
            Text("\(isoWeek) · \(rangeText)")
                .font(DSType.mono11)
                .foregroundColor(DSColor.inkSubtle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(NSLocalizedString("weekly.recap.title", comment: "")), \(isoWeek), \(rangeText)")
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
            Text(NSLocalizedString("weekly.recap.loading", comment: ""))
                .font(DSType.bodyMD)
                .foregroundColor(DSColor.inkMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(NSLocalizedString("weekly.recap.loading", comment: ""))
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(DSColor.statusError)
            Text(NSLocalizedString("weekly.recap.error.body", comment: ""))
                .font(DSType.bodyMD)
                .foregroundColor(DSColor.inkPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(DSType.bodySM)
                .foregroundColor(DSColor.inkMuted)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button {
                Task { await reload(forceRefresh: true) }
            } label: {
                Text(NSLocalizedString("weekly.recap.refresh", comment: ""))
                    .font(DSType.labelSM)
                    .foregroundColor(DSColor.amberAccent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(DSColor.amberRim, lineWidth: 1)
                    )
            }
            .accessibilityHint(NSLocalizedString("weekly.recap.refresh.hint", comment: ""))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("weekly.recap.error.body", comment: ""))
    }

    @ViewBuilder
    private func sections(output: WeeklyRecapOutput) -> some View {
        keywordsSection(output.keywords)
        moodSection(output.moodNotes)
        placesSection(output.placeNotes)
        highlightsSection(output.highlights)
    }

    // MARK: - Sections

    private func keywordsSection(_ keywords: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel(NSLocalizedString("weekly.recap.section.keywords", comment: ""))
            keywordChipFlow(keywords)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("weekly.recap.section.keywords.a11y", comment: ""))
    }

    private func keywordChipFlow(_ keywords: [String]) -> some View {
        // Wrap-around HStack via VStack rows of ~3 chips — simple and
        // dependency-free; flow layout was excessive for the current
        // 3-5-chip case.
        let rows = Self.chunk(keywords, size: 3)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<rows.count, id: \.self) { rowIdx in
                HStack(spacing: 8) {
                    ForEach(rows[rowIdx], id: \.self) { kw in
                        Text(kw)
                            .font(DSType.bodyMD)
                            .foregroundColor(DSColor.amberAccent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(DSColor.amberAccent.opacity(0.14))
                            )
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func moodSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel(NSLocalizedString("weekly.recap.section.mood", comment: ""))
            Text(text.isEmpty ? "—" : text)
                .font(DSType.bodyMD)
                .foregroundColor(DSColor.inkPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(DSColor.amberAccent.opacity(0.06))
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("weekly.recap.section.mood.a11y", comment: ""))
    }

    private func placesSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel(NSLocalizedString("weekly.recap.section.places", comment: ""))
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "mappin")
                    .font(.system(size: 16))
                    .foregroundColor(DSColor.amberAccent)
                    .padding(.top, 2)
                Text(text.isEmpty ? "—" : text)
                    .font(DSType.bodyMD)
                    .foregroundColor(DSColor.inkPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("weekly.recap.section.places.a11y", comment: ""))
    }

    private func highlightsSection(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(NSLocalizedString("weekly.recap.section.highlights", comment: ""))
            ForEach(0..<items.count, id: \.self) { idx in
                HStack(alignment: .top, spacing: 8) {
                    Text("✦")
                        .font(DSType.bodyMD)
                        .foregroundColor(DSColor.amberAccent)
                    Text(items[idx])
                        .font(DSType.bodyMD)
                        .foregroundColor(DSColor.inkPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("weekly.recap.section.highlights.a11y", comment: ""))
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(DSType.sectionLabel)
            .foregroundColor(DSColor.inkMuted)
            .tracking(1.2)
    }

    private var refreshButton: some View {
        HStack {
            Spacer()
            Button {
                Task { await reload(forceRefresh: true) }
            } label: {
                Text(NSLocalizedString("weekly.recap.refresh", comment: ""))
                    .font(DSType.labelSM)
                    .foregroundColor(DSColor.amberAccent)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(DSColor.amberRim, lineWidth: 1)
                    )
            }
            .accessibilityHint(NSLocalizedString("weekly.recap.refresh.hint", comment: ""))
            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: - Loading logic

    private func loadInitial() async {
        if let cached = WeeklyCompilationService.shared.loadCached(for: referenceDate) {
            self.output = cached
            return
        }
        await reload(forceRefresh: false)
    }

    private func reload(forceRefresh: Bool) async {
        isLoading = true
        error = nil
        do {
            let result = try await WeeklyCompilationService.shared.compileWeekly(
                for: referenceDate,
                forceRefresh: forceRefresh
            )
            self.output = result
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Helpers

    private static func fallbackDateRange(for date: Date) -> String {
        let cal = WeeklyCompilationService.weekCalendar
        guard let interval = cal.dateInterval(of: .weekOfYear, for: date) else {
            return ""
        }
        let start = cal.startOfDay(for: interval.start)
        guard let end = cal.date(byAdding: .day, value: 6, to: start) else { return "" }
        let f = WeeklyCompilationService.dateFormatter
        return "\(f.string(from: start)) to \(f.string(from: end))"
    }

    private static func chunk<T>(_ array: [T], size: Int) -> [[T]] {
        guard size > 0, !array.isEmpty else { return [] }
        var result: [[T]] = []
        var i = 0
        while i < array.count {
            let end = min(i + size, array.count)
            result.append(Array(array[i..<end]))
            i = end
        }
        return result
    }
}
