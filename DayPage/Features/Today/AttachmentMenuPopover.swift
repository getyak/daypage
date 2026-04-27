import SwiftUI

// MARK: - AttachmentMenuPopover
//
// Capture v2 STREAM "more tray" — translated from VariationStream.jsx's
// AttachItem grid. Four equal-weight tiles in a single row:
//
//   拍照 · 相册 · 位置 · 附件
//
// Each tile is a 56×56 rounded square in surfaceSunken with a monochrome
// SF Symbol; below it a 12pt muted label. The whole tray sits on a small
// rounded card with a subtle warm border — no full-height list, no big
// dividers, no drag handle clutter. Matches the design's "elegant,
// uncluttered" brief from chat round 4 ("没有必要占满啊，优雅美观简洁就可以").

struct AttachmentMenuPopover: View {

    let onCapturePhoto: () -> Void
    let onPickPhoto: () -> Void
    let onAddFile: () -> Void
    let onAddLocation: () -> Void

    let isLocating: Bool
    let hasPendingLocation: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Slim drag handle (Apple-style; sheet still draggable)
            Capsule()
                .fill(DSColor.borderDefault)
                .frame(width: 36, height: 4)
                .padding(.top, 8)
                .padding(.bottom, 22)

            // 4-up tile row, evenly distributed
            HStack(spacing: 0) {
                tile(icon: "camera",     label: "拍照",
                     action: onCapturePhoto)
                tile(icon: "photo.on.rectangle", label: "相册",
                     action: onPickPhoto)
                tile(icon: hasPendingLocation ? "mappin.circle.fill" : "mappin",
                     label: hasPendingLocation ? "更新位置" : "位置",
                     isLoading: isLocating,
                     action: onAddLocation)
                tile(icon: "paperclip",  label: "附件",
                     action: onAddFile)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.6), lineWidth: 0.5)
            )
            .shadow(color: DSColor.accentAmber.opacity(0.08), radius: 16, x: 0, y: 8)
            .padding(.horizontal, 16)

            Spacer(minLength: 28)
        }
        .frame(maxWidth: .infinity)
        .background(DSColor.backgroundWarm)
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.hidden)
        .modifier(AttachmentSheetPresentation())
    }

    // MARK: - Tile (icon square + label)

    @ViewBuilder
    private func tile(
        icon: String,
        label: String,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(DSColor.surfaceSunken)
                        .frame(width: 56, height: 56)
                    if isLoading {
                        ProgressView()
                            .tint(DSColor.onBackgroundMuted)
                            .scaleEffect(0.9)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(DSColor.onBackgroundMuted)
                    }
                }

                Text(label)
                    .font(.custom("Inter-Regular", size: 12))
                    .foregroundStyle(DSColor.onBackgroundMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(AttachmentRowButtonStyle())
    }
}

// MARK: - AttachmentRowButtonStyle

private struct AttachmentRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .offset(y: configuration.isPressed ? 0.5 : 0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - AttachmentSheetPresentation

private struct AttachmentSheetPresentation: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content
                .presentationBackground(DSColor.backgroundWarm)
                .presentationCornerRadius(20)
        } else {
            content
        }
    }
}
