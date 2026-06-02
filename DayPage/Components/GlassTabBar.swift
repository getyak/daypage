import SwiftUI

// MARK: - AppSection

/// Top-level navigation sections shown in GlassTabBar.
enum AppSection: String, CaseIterable, Equatable {
    case today   = "Today"
    case archive = "Archive"
    case graph   = "Graph"
#if DEBUG
    case search  = "Search"
#endif

    var icon: String {
        switch self {
        case .today:   return "square.and.pencil"
        case .archive: return "archivebox"
        case .graph:   return "point.3.connected.trianglepath.dotted"
#if DEBUG
        case .search:  return "magnifyingglass"
#endif
        }
    }

    var label: String { rawValue }
}

// MARK: - GlassTabBar

/// Top-right glass pill nav that expands on tap into a vertical menu.
/// Anchored at top: 54, trailing: 16 via the `.glassTabBar()` overlay modifier.
struct GlassTabBar: View {

    @Binding var active: AppSection
    @State private var isExpanded: Bool = false

    // Sections to display — search hidden behind DEBUG flag
    private var sections: [AppSection] {
#if DEBUG
        AppSection.allCases
#else
        [.today, .archive, .graph]
#endif
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Full-screen tap-outside dismiss target when expanded
            if isExpanded {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(Motion.spring) {
                            isExpanded = false
                        }
                    }
            }

            // Pill / panel anchored top-trailing
            VStack(alignment: .trailing, spacing: 0) {
                if isExpanded {
                    expandedMenu
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.85, anchor: .topTrailing).combined(with: .opacity),
                            removal: .scale(scale: 0.85, anchor: .topTrailing).combined(with: .opacity)
                        ))
                } else {
                    collapsedPill
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.85, anchor: .topTrailing).combined(with: .opacity),
                            removal: .scale(scale: 0.85, anchor: .topTrailing).combined(with: .opacity)
                        ))
                }
            }
            .padding(.top, 54)
            .padding(.trailing, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    // MARK: - Collapsed Pill

    private var collapsedPill: some View {
        Button {
            withAnimation(Motion.spring) {
                isExpanded = true
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: active.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DSColor.amberDeep)
                    .accessibilityHidden(true)

                Text(active.label)
                    .font(DSType.labelSM)
                    .foregroundColor(DSColor.inkPrimary)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DSColor.inkMuted)
                    .accessibilityHidden(true)
            }
            .padding(.top, 6)
            .padding(.leading, 12)
            .padding(.bottom, 6)
            .padding(.trailing, 10)
            .liquidGlassPill()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Navigation, currently \(active.label)")
        .accessibilityHint("Opens the section menu")
        .accessibilityIdentifier("glass-tabbar-pill")
    }

    // MARK: - Expanded Menu

    private var expandedMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sections, id: \.self) { section in
                menuRow(section)
            }
        }
        .padding(4)
        .frame(minWidth: 140, alignment: .leading)
        .liquidGlassPanel()
    }

    @ViewBuilder
    private func menuRow(_ section: AppSection) -> some View {
        let isActive = active == section

        Button {
            withAnimation(Motion.spring) {
                active = section
                isExpanded = false
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .font(.system(size: 14, weight: isActive ? .semibold : .regular))
                    .foregroundColor(isActive ? Color.white.opacity(0.92) : DSColor.inkPrimary)
                    .frame(width: 18)
                    .accessibilityHidden(true)

                Text(section.label)
                    .font(isActive ? DSType.labelSM.weight(.semibold) : DSType.labelSM)
                    .foregroundColor(isActive ? Color.white.opacity(0.92) : DSColor.inkPrimary)

                Spacer()
            }
            .padding(.top, 9)
            .padding(.leading, 12)
            .padding(.bottom, 9)
            .padding(.trailing, 12)
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(DSColor.amberDeep)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.label)
        .accessibilityHint("Switches to the \(section.label) section")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("glass-tabbar-row-\(section.rawValue.lowercased())")
    }
}

// MARK: - View extension

extension View {
    /// Overlays a GlassTabBar anchored at top:54 trailing:16.
    func glassTabBar(active: Binding<AppSection>) -> some View {
        overlay(GlassTabBar(active: active))
    }
}
