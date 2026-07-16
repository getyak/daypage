import SwiftUI
import DayPageStorage
import DayPageServices

// MARK: - SettingsAppearanceView

/// "外观" — theme, accent, type size, card density, plus the Today-view
/// display features (On This Day). Voice settings moved out to "AI 与语音";
/// they were never appearance.
@MainActor
struct SettingsAppearanceView: View {

    @ObservedObject private var appSettings = AppSettings.shared

    @State private var onThisDayEnabled: Bool = OnThisDayScheduler.shared.isEnabled
    @State private var onThisDayRefreshHour: Int = OnThisDayScheduler.shared.refreshHour

    var body: some View {
        List {
            Group {
                appearanceSection
            }
            .listRowBackground(DSColor.surfaceWhite)
        }
        .scrollContentBackground(.hidden)
        .background(DSColor.bgWarm.ignoresSafeArea())
        .tint(DSColor.primary)
        .navigationTitle(NSLocalizedString("settings.appearance.section", comment: "Appearance page title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var appearanceSection: some View {
        Section {
            // Live preview — re-renders as the pickers below change so the
            // abstract font-size / density / accent choices become tangible.
            appearancePreviewCard

            DSPicker(
                title: NSLocalizedString("settings.appearance.darkmode", comment: ""),
                selection: $appSettings.themeMode,
                options: ThemeMode.allCases.map { (value: $0, label: $0.label) }
            ) {
                SettingsLabel(title: NSLocalizedString("settings.appearance.darkmode", comment: ""), systemImage: "moon.fill")
            }
            .onChange(of: appSettings.themeMode) { _ in Haptics.soft() }

            DSPicker(
                title: NSLocalizedString("settings.appearance.accent", comment: ""),
                selection: $appSettings.accentColor,
                options: AccentColorOption.allCases.map { (value: $0, label: $0.label) }
            ) {
                SettingsLabel(title: NSLocalizedString("settings.appearance.accent", comment: ""), systemImage: "paintpalette")
            }
            .onChange(of: appSettings.accentColor) { _ in Haptics.soft() }

            DSPicker(
                title: NSLocalizedString("settings.appearance.fontsize", comment: ""),
                selection: $appSettings.fontSizeAdjust,
                options: FontSizeAdjust.allCases.map { (value: $0, label: $0.label) }
            ) {
                SettingsLabel(title: NSLocalizedString("settings.appearance.fontsize", comment: ""), systemImage: "textformat.size")
            }
            .onChange(of: appSettings.fontSizeAdjust) { _ in Haptics.soft() }

            DSPicker(
                title: NSLocalizedString("settings.appearance.density", comment: ""),
                selection: $appSettings.cardDensity,
                options: CardDensity.allCases.map { (value: $0, label: $0.label) }
            ) {
                SettingsLabel(title: NSLocalizedString("settings.appearance.density", comment: ""), systemImage: "rectangle.expand.vertical")
            }
            .onChange(of: appSettings.cardDensity) { _ in Haptics.soft() }

            // On This Day configuration
            Toggle(isOn: $onThisDayEnabled) {
                SettingsLabel(title: NSLocalizedString("settings.appearance.onthisday.title", comment: "On This Day toggle"), systemImage: "calendar.badge.clock")
            }
            .accessibilityIdentifier("onthisday-enabled-toggle")
            .onChange(of: onThisDayEnabled) { val in
                Haptics.selection()
                OnThisDayScheduler.shared.isEnabled = val
            }

            if onThisDayEnabled {
                Picker(NSLocalizedString("settings.appearance.onthisday.refresh_time", comment: ""), selection: $onThisDayRefreshHour) {
                    Text(NSLocalizedString("settings.appearance.onthisday.midnight", comment: "")).tag(0)
                    Text(NSLocalizedString("settings.appearance.onthisday.dawn", comment: "")).tag(6)
                    Text(NSLocalizedString("settings.appearance.onthisday.morning", comment: "")).tag(9)
                }
                .accessibilityIdentifier("onthisday-refresh-hour-picker")
                .onChange(of: onThisDayRefreshHour) { val in
                    OnThisDayScheduler.shared.refreshHour = val
                }
            }
        }
    }

    // MARK: Preview card

    /// A miniature memo card that mirrors the real card aesthetic and
    /// re-renders live as the appearance pickers change.
    private var appearancePreviewCard: some View {
        let accent = appSettings.accentColor.color
        return VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack(spacing: 6) {
                Circle()
                    .fill(accent)
                    .frame(width: 6, height: 6)
                Text(NSLocalizedString("settings.appearance.preview.kicker", comment: ""))
                    .font(DSType.mono10)
                    .tracking(1.0)
                    .textCase(.uppercase)
                    .foregroundColor(accent)
            }
            Text(NSLocalizedString("settings.appearance.preview.body", comment: ""))
                .bodyMDStyle()
                .foregroundColor(DSColor.onBackgroundPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(NSLocalizedString("settings.appearance.preview.hint", comment: ""))
                .bodySMStyle()
                .foregroundColor(DSColor.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .dpGlass(.panel, in: RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                .strokeBorder(accent.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
        .padding(.vertical, 2)
        .animation(Motion.fade, value: appSettings.fontSizeAdjust)
        .animation(Motion.fade, value: appSettings.cardDensity)
        .animation(Motion.fade, value: appSettings.accentColor)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NSLocalizedString("settings.appearance.preview.a11y", comment: "Appearance preview card accessibility label"))
    }
}

#Preview {
    NavigationStack { SettingsAppearanceView() }
}
