import SwiftUI

// MARK: - Global Corner Radius Override
// All DS components use cornerRadius(0). UIKit bridging views should also
// have their layer.cornerRadius set to 0 at init.

// MARK: - Primary Stamp Button

struct PrimaryStampButton: View {
    let title: String
    let action: () -> Void
    var isEnabled: Bool = true

    var body: some View {
        Button(action: action) {
            Text(title)
                .sectionLabelStyle()
                .foregroundColor(DSColor.onPrimary)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(isEnabled ? DSColor.primary : DSColor.onSurfaceVariant)
                .cornerRadius(0)
        }
        .disabled(!isEnabled)
    }
}

// MARK: - Secondary Outline Button

struct SecondaryOutlineButton: View {
    let title: String
    let action: () -> Void
    var isEnabled: Bool = true

    var body: some View {
        Button(action: action) {
            Text(title)
                .sectionLabelStyle()
                .foregroundColor(isEnabled ? DSColor.primary : DSColor.onSurfaceVariant)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(DSColor.surface)
                .cornerRadius(0)
                .overlay(
                    Rectangle()
                        .stroke(isEnabled ? DSColor.primary : DSColor.outlineVariant, lineWidth: 1)
                )
        }
        .disabled(!isEnabled)
    }
}

// MARK: - Field Chip

struct FieldChip: View {
    let label: String
    let value: String
    var onTap: (() -> Void)?

    var body: some View {
        Button(action: { onTap?() }) {
            HStack(spacing: 4) {
                Text(label)
                    .monoLabelStyle(size: 9)
                    .foregroundColor(DSColor.onSurfaceVariant)
                Text(value)
                    .monoLabelStyle(size: 9)
                    .foregroundColor(DSColor.onSurface)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(DSColor.surfaceContainerHigh)
            .cornerRadius(0)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Time Chip

struct TimeChip: View {
    let time: String

    var body: some View {
        Text(time)
            .monoLabelStyle(size: 10)
            .foregroundColor(DSColor.onSurfaceVariant)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(DSColor.surfaceContainer)
            .cornerRadius(0)
    }
}

// MARK: - Section Heading with Horizontal Rule

struct SectionHeading: View {
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .sectionLabelStyle()
                .foregroundColor(DSColor.onSurface)
                .fixedSize()
            Rectangle()
                .fill(DSColor.outlineVariant)
                .frame(height: 1)
        }
    }
}

// MARK: - Wikilink Text

struct WikilinkText: View {
    let text: String
    var onTap: (() -> Void)?

    var body: some View {
        Text(text)
            .bodySMStyle()
            .foregroundColor(DSColor.amberArchival)
            .underline(false)
            .onTapGesture { onTap?() }
    }
}

// MARK: - Status Badge

enum BadgeStyle {
    case verified    // black bg / white text
    case metadata    // gray bg / gray text
}

struct StatusBadge: View {
    let label: String
    let style: BadgeStyle

    var body: some View {
        Text(label)
            .monoLabelStyle(size: 9)
            .foregroundColor(style == .verified ? DSColor.onPrimary : DSColor.onSurfaceVariant)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(style == .verified ? DSColor.primary : DSColor.surfaceContainerHigh)
            .cornerRadius(0)
    }
}

// MARK: - Card Container (surface-container with optional left border)

struct CardContainer<Content: View>: View {
    let content: () -> Content
    var leadingBorderColor: Color?

    var body: some View {
        HStack(spacing: 0) {
            if let borderColor = leadingBorderColor {
                Rectangle()
                    .fill(borderColor)
                    .frame(width: 4)
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(DSColor.surfaceContainer)
        }
        .cornerRadius(0)
    }
}
