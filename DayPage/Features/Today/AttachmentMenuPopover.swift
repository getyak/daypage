import SwiftUI
import DayPageServices

// MARK: - AttachmentMenuPopover
//
// Capture v2 STREAM "more tray" — five equal-weight tiles in one row:
//
//   拍照 · 相册 · 位置 · 附件 · 链接
//
// Each tile is a 56×56 rounded square in surfaceSunken with a monochrome
// SF Symbol; below it a 12pt muted label. The whole tray sits on a small
// rounded card with a subtle warm border — no full-height list, no big
// dividers, no drag handle clutter. Matches the design's "elegant,
// uncluttered" brief from chat round 4 ("没有必要占满啊，优雅美观简洁就可以").
//
// Issue #3 (2026-07-03): 增加"链接"tile — 从剪贴板抓 URL 一键写入草稿。
// 补齐 backlog "统一导入中心" 里六种输入之一，与文本（TextField）、语音
// （mic hero）合起来达到 6 入口：文本 / 语音 / 拍照 / 相册 / 位置 / 附件 / 链接。

struct AttachmentMenuPopover: View {

    let onCapturePhoto: () -> Void
    let onPickPhoto: () -> Void
    let onAddFile: () -> Void
    let onAddLocation: () -> Void
    /// Issue #3: 触发链接采集 — 通常从 UIPasteboard.string 里抓 URL。
    /// 如果剪贴板无 URL，callee 应给用户一个 alert 让手输。
    let onAddURL: () -> Void

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

            // 5-up tile row, evenly distributed.
            // Issue #3 (2026-07-03): 增加 "链接" 让统一导入中心
            // 六入口齐全（文本 + 语音在主输入栏，这里补齐 5 个附件类）。
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
                tile(icon: "link",       label: "链接",
                     action: onAddURL)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            // #771: attachment menu → glass engine (.panel). Drops the cold
            // white rim (the "old-version" look) for the warm engine hairline.
            .dpGlass(.panel, in: RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous))
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
                    RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
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
        .pressScale(scale: 0.97, offsetY: 0.5,
                    animation: .spring(response: 0.2, dampingFraction: 0.7),
                    respectsReduceMotion: false)
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
