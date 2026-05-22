import SwiftUI

// MARK: - DSBanner
//
// Single unified banner surface. Replaces the local implementations
// scattered across `AppBanner`, `GlassErrorBanner`, `CompilationFailedBanner`,
// and the header of `LocationDraftCard`. Use the appropriate kind:
//
//   .info    — neutral notice (sync prompt, draft restored)
//   .success — green tick (saved, compiled)
//   .warning — amber alert (rate limit, weak signal)
//   .error   — red blocker (compilation failed, upload error)
//   .loading — neutral with spinner (background task running)

enum DSBannerKind {
    case info
    case success
    case warning
    case error
    case loading

    fileprivate var systemImage: String? {
        switch self {
        case .info:    return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        case .loading: return nil
        }
    }

    fileprivate var tint: Color {
        switch self {
        case .info:    return DSColor.amberAccent
        case .success: return DSColor.successGreen
        case .warning: return DSColor.warningAmber
        case .error:   return DSColor.errorRed
        case .loading: return DSColor.amberAccent
        }
    }

    fileprivate var background: Color {
        switch self {
        case .info, .loading: return DSColor.glassStd
        case .success:        return DSColor.successSoft
        case .warning:        return DSColor.warningSoft
        case .error:          return DSColor.errorSoft
        }
    }
}

struct DSBanner: View {
    let kind: DSBannerKind
    let title: String
    var subtitle: String? = nil
    var primaryAction: (label: String, action: () -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: DSSpacing.md) {
            leadingIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DSType.bodySM)
                    .foregroundColor(DSColor.inkPrimary)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(DSType.caption)
                        .foregroundColor(DSColor.inkMuted)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let primaryAction {
                Button(primaryAction.label, action: primaryAction.action)
                    .font(DSType.caption)
                    .foregroundColor(kind.tint)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DSColor.inkMuted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("关闭")
            }
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.md)
        .background(kind.background)
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                .strokeBorder(DSColor.glassRim, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
        .elevation(.glass)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        switch kind {
        case .loading:
            ProgressView()
                .tint(kind.tint)
                .frame(width: 18, height: 18)
        default:
            if let sym = kind.systemImage {
                Image(systemName: sym)
                    .font(.system(size: 16))
                    .foregroundColor(kind.tint)
                    .frame(width: 18, height: 18)
            }
        }
    }
}
