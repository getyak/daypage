import SwiftUI

// MARK: - AttachmentMenuPopover
//
// Capture v2 minimal design: single-color line icons + text label list,
// ultraThinMaterial background matching InputBarV4 capsule aesthetic.
// Uses SF Symbols thin variants (camera, photo, paperclip, mappin) unfilled.
// Subtle tap animation: depresses + micro-scale.

struct AttachmentMenuPopover: View {

    let onCapturePhoto: () -> Void
    let onPickPhoto: () -> Void
    let onAddFile: () -> Void
    let onAddLocation: () -> Void

    let isLocating: Bool
    let hasPendingLocation: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            RoundedRectangle(cornerRadius: 2)
                .fill(DSColor.borderDefault)
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 20)

            VStack(spacing: 0) {
                attachmentRow(icon: "camera", label: "拍照", action: onCapturePhoto)
                Divider().padding(.leading, 48).foregroundColor(DSColor.borderSubtle)
                attachmentRow(icon: "photo", label: "从相册选", action: onPickPhoto)
                Divider().padding(.leading, 48).foregroundColor(DSColor.borderSubtle)
                attachmentRow(icon: "paperclip", label: "附件", action: onAddFile)
                Divider().padding(.leading, 48).foregroundColor(DSColor.borderSubtle)
                attachmentRow(
                    icon: "mappin",
                    label: hasPendingLocation ? "更新位置" : "位置",
                    isLoading: isLocating,
                    action: onAddLocation
                )
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(DSColor.borderSubtle, lineWidth: 0.5)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity)
        .background(DSColor.backgroundWarm)
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.hidden)
        .modifier(AttachmentSheetPresentation())
    }

    // MARK: - Attachment Row

    @ViewBuilder
    private func attachmentRow(icon: String, label: String, isLoading: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    // Monochrome unfilled line icon
                    if isLoading {
                        ProgressView()
                            .tint(DSColor.onBackgroundMuted)
                            .scaleEffect(0.85)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(DSColor.onBackgroundMuted)
                    }
                }
                .frame(width: 28, height: 28)

                Text(label)
                    .font(.custom("Inter-Regular", size: 15))
                    .foregroundStyle(DSColor.onBackgroundPrimary)

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
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
