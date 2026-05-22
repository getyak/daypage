import SwiftUI

// MARK: - DSNavRow
//
// A horizontal row used in side drawers (Sidebar) and grouped lists
// (Settings). It owns the left amber accent strip pattern that
// Sidebar's `navItem` invented, the icon + label layout, and an
// optional trailing accessory (badge / count / chevron).
//
//   DSNavRow(
//       icon: "archivebox",
//       label: "Archive",
//       isActive: nav.selectedTab == .archive,
//       trailing: .chevron,
//       action: { nav.navigate(to: .archive) }
//   )

enum DSNavRowTrailing {
    case none
    case chevron
    case badge(String)
    case count(Int)
}

struct DSNavRow: View {
    let icon: String
    let label: String
    var isActive: Bool = false
    var isDisabled: Bool = false
    var trailing: DSNavRowTrailing = .none
    let action: () -> Void

    var body: some View {
        Button(action: { guard !isDisabled else { return }; action() }) {
            HStack(spacing: DSSpacing.md) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(isActive ? DSColor.amberAccent : Color.clear)
                    .frame(width: 2, height: 20)

                Image(systemName: icon)
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 20)
                    .foregroundColor(iconColor)

                Text(label)
                    .font(isActive ? DSType.titleSM : DSType.bodyMD)
                    .foregroundColor(labelColor)

                Spacer(minLength: 0)

                trailingView
            }
            .padding(.leading, 0)
            .padding(.trailing, DSSpacing.lg)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive ? DSColor.amberSoft : Color.clear)
            .contentShape(Rectangle())
        }
        .disabled(isDisabled)
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    @ViewBuilder
    private var trailingView: some View {
        switch trailing {
        case .none:
            EmptyView()
        case .chevron:
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DSColor.inkSubtle)
        case .badge(let text):
            DSChip(label: text, kind: isDisabled ? .ghost : .active)
        case .count(let value):
            Text("\(value)")
                .font(DSType.mono10)
                .foregroundColor(DSColor.inkMuted)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(DSColor.amberSoft, in: Capsule())
        }
    }

    private var iconColor: Color {
        if isDisabled { return DSColor.inkSubtle }
        return isActive ? DSColor.amberAccent : DSColor.inkMuted
    }

    private var labelColor: Color {
        if isDisabled { return DSColor.inkSubtle }
        return isActive ? DSColor.inkPrimary : DSColor.inkMuted
    }
}
