import SwiftUI

// MARK: - AttachmentMenuSheet
//
// 附件菜单的底部弹出版本，替代 InputBarV3 的 AttachmentMenuPopover。
// 通过 .sheet(isPresented:) 呈现，由 iOS 自动处理遮罩层、
// 下滑关闭和键盘避让。
//
// 采用 2×2 图标网格（相机 | 照片 | 文件 | 位置）而非
// 垂直列表——图标在移动端更容易点击，且符合现代应用
// 惯例（Telegram、Instagram）。

struct AttachmentMenuSheet: View {

    let onCapturePhoto: () -> Void
    let onPickPhoto: () -> Void
    let onAddFile: () -> Void
    let onAddLocation: () -> Void

    let isLocating: Bool
    let hasPendingLocation: Bool

    var body: some View {
        VStack(spacing: 0) {
            sheetHandle

            Text("添加")
                .font(.custom("Inter-Medium", size: 15))
                .foregroundColor(DSColor.onSurface)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 16)

            iconGrid

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .background(DSColor.surfaceContainerLowest)
    }

    // MARK: - 弹出页手柄

    private var sheetHandle: some View {
        RoundedRectangle(cornerRadius: 2.5)
            .fill(DSColor.outlineVariant)
            .frame(width: 36, height: 5)
            .padding(.top, 10)
            .padding(.bottom, 12)
    }

    // MARK: - 图标网格

    private var iconGrid: some View {
        HStack(spacing: 0) {
            iconCell(
                systemName: "camera.fill",
                label: "拍照",
                action: onCapturePhoto
            )
            iconCell(
                systemName: "photo.on.rectangle",
                label: "相册",
                action: onPickPhoto
            )
            iconCell(
                systemName: "paperclip",
                label: "文件",
                action: onAddFile
            )
            iconCell(
                systemName: isLocating ? "mappin.and.ellipse" : "mappin.circle.fill",
                label: hasPendingLocation ? "更新位置" : "位置",
                spinner: isLocating,
                action: onAddLocation
            )
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func iconCell(
        systemName: String,
        label: String,
        spinner: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(DSColor.surfaceContainerHigh)
                        .frame(width: 56, height: 56)
                    if spinner {
                        ProgressView()
                            .tint(DSColor.onSurfaceVariant)
                    } else {
                        Image(systemName: systemName)
                            .font(.system(size: 22, weight: .regular))
                            .foregroundColor(DSColor.onSurface)
                    }
                }
                Text(label)
                    .font(.custom("Inter-Regular", size: 12))
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
