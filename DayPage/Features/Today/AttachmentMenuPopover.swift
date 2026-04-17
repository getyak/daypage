import SwiftUI

// MARK: - AttachmentMenuPopover
//
// 4-item menu shown above the InputBarV2 `+` button.
// Maps each item to an existing TodayViewModel handler — no new plumbing.
// The parent controls visibility via a Binding<Bool>; tap-outside dismissal is
// handled in InputBarV2's overlay wrapping.

struct AttachmentMenuPopover: View {

    // MARK: Callbacks

    let onCapturePhoto: () -> Void
    let onPickPhoto: () -> Void
    let onAddFile: () -> Void
    let onAddLocation: () -> Void

    let isLocating: Bool
    let hasPendingLocation: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            menuRow(
                icon: "camera",
                title: "拍照",
                action: onCapturePhoto
            )
            Divider().background(DSColor.outlineVariant)
            menuRow(
                icon: "photo",
                title: "从相册选",
                action: onPickPhoto
            )
            Divider().background(DSColor.outlineVariant)
            menuRow(
                icon: "paperclip",
                title: "附件",
                action: onAddFile
            )
            Divider().background(DSColor.outlineVariant)
            menuRow(
                icon: isLocating ? "mappin.and.ellipse" : "mappin.circle",
                title: hasPendingLocation ? "更新位置" : "位置",
                trailingSpinner: isLocating,
                action: onAddLocation
            )
        }
        .frame(width: 200)
        .background(DSColor.surfaceContainerLowest)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(DSColor.outlineVariant, lineWidth: 1)
        )
        .cornerRadius(12)
        .surfaceElevatedShadow()
    }

    @ViewBuilder
    private func menuRow(
        icon: String,
        title: String,
        trailingSpinner: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(DSColor.onSurface)
                    .frame(width: 20)
                Text(title)
                    .font(.custom("Inter-Regular", size: 14))
                    .foregroundColor(DSColor.onSurface)
                Spacer()
                if trailingSpinner {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(DSColor.onSurfaceVariant)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
